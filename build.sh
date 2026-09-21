#!/usr/bin/env bash
# Builds MLX and mlx-c, and installs them as one prefix that says what it
# holds. Runs the same way on a workstation and on CI; the workflow beside
# it adds only the Metal toolchain and the release.
#
# The prefix answers two questions at once. `mlx/lib/` holds the four
# files a Rust build links, which is what `MLX_PREBUILT_PATH` wants. The
# tree `mlx/` is what `find_package(MLX)` looks for, which is how a
# consumer builds mlx-c against an MLX it did not compile
# (`MLX_C_USE_SYSTEM_MLX`). One copy of the bytes, either way in.
#
# Under `mlx/` rather than at the root because `lib` is cmake's name for
# it (GNUInstallDirs), and a bare `lib/` at the top of an archive reads
# like somebody else's `lib` to whoever unpacks it. Renaming it is not an
# option: the exported package bakes the path in, so a directory moved
# afterwards is a package `find_package` can no longer follow.
#
# Metal is not optional here. MLX probes the Metal compiler fatally when
# configuring with MLX_BUILD_METAL=ON, and its library target depends on a
# metallib it compiles itself, so a machine without the toolchain cannot
# produce these no matter what it is handed.
set -euo pipefail

# What to build. These are not free choices: mlx-c pins the MLX it fetches
# (FetchContent GIT_TAG), and whatever consumes these links against
# bindings generated from mlx-c's headers. The pair has to be the pair the
# consumer expects, or the headers describe one library and the archive is
# another.
MLX_C_REF="${MLX_C_REF:-c74db5307cc8ce122f48d97ef951b30578674e7f}"
OUT="${OUT:-$PWD/dist}"

WANTED=(libmlx.a libmlxc.a libgguflib.a mlx.metallib)
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "==> mlx-c ${MLX_C_REF}"
git init --quiet "$work/mlx-c"
git -C "$work/mlx-c" remote add origin https://github.com/ml-explore/mlx-c.git
git -C "$work/mlx-c" fetch --quiet --depth 1 origin "${MLX_C_REF}"
git -C "$work/mlx-c" checkout --quiet FETCH_HEAD

mlx_tag="$(grep -A 3 'FetchContent_Declare' "$work/mlx-c/CMakeLists.txt" |
  grep 'GIT_TAG' | head -1 | tr -d ' )' | cut -d' ' -f2 | sed 's/GIT_TAG//')"
echo "==> which pins MLX ${mlx_tag}"

cmake -S "$work/mlx-c" -B "$work/build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF \
  -DMLX_BUILD_METAL=ON \
  -DMLX_BUILD_TESTS=OFF \
  -DMLX_BUILD_EXAMPLES=OFF \
  -DMLX_BUILD_BENCHMARKS=OFF \
  -DMLX_BUILD_PYTHON_BINDINGS=OFF
cmake --build "$work/build" -j "$(sysctl -n hw.ncpu)"

# Installed rather than gathered: both projects have install rules, and
# what they write is a prefix another build can find. MLX puts its archive
# and its metallib in lib/, mlx-c puts its archive there too, and both
# export a CMake package into share/cmake. So one tree answers two
# questions: `lib/` holds the four files a Rust build links, and the tree
# itself is what `find_package(MLX)` looks for when a consumer would
# rather not compile MLX at all (mlx-c's MLX_C_USE_SYSTEM_MLX).
PREFIX="$OUT/mlx"
mkdir -p "$PREFIX"
cmake --install "$work/build" --prefix "$PREFIX"

# Except gguflib, which MLX vendors and does not install, and which its
# GGUF support needs at link time.
gguf="$(find "$work/build" -name libgguflib.a -type f | head -1)"
[ -n "$gguf" ] && cp "$gguf" "$PREFIX/lib/"

for name in "${WANTED[@]}"; do
  if [ ! -f "$PREFIX/lib/$name" ]; then
    echo "!! $name is not in the install tree. mlx/lib/ holds:" >&2
    ls -l "$PREFIX/lib" >&2
    exit 1
  fi
done

# The licences of what was built, taken from the sources that were built
# rather than kept as copies here: the archive is MLX and mlx-c compiled,
# and MIT asks whoever passes that on to carry the notice. Copying them at
# build time means the notice always belongs to the version in the box.
cp "$work/mlx-c/LICENSE" "$OUT/LICENSE.mlx-c"
mlx_src="$(find "$work/build" -type d -name 'mlx-src' | head -1)"
if [ -z "$mlx_src" ] || [ ! -f "$mlx_src/LICENSE" ]; then
  echo "!! MLX's LICENSE was not found; the archive may not be redistributed without it" >&2
  exit 1
fi
cp "$mlx_src/LICENSE" "$OUT/LICENSE.mlx"

# What is in it, beside it. A consumer that pins the digest still wants to
# know what the digest is of.
cat > "$OUT/MANIFEST.txt" <<EOF
mlx-c    ${MLX_C_REF}
mlx      ${mlx_tag}
built    $(date -u +%Y-%m-%dT%H:%M:%SZ)
macos    $(sw_vers -productVersion)
xcode    $(xcodebuild -version | head -1)
EOF
cat "$OUT/MANIFEST.txt"
(cd "$PREFIX/lib" && shasum -a 256 "${WANTED[@]}" | tee "$OUT/SHA256SUMS")
echo "==> what was made, headers aside:"
find "$OUT" -maxdepth 3 -not -path "*/include/*" | sort
