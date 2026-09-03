#!/usr/bin/env bash
# Builds MLX and mlx-c into the four files a Rust build links, and says
# what it made. Runs the same way on a workstation and on CI; the workflow
# beside it adds only the Metal toolchain and the release.
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
MLX_C_REF="${MLX_C_REF:-v0.4.1}"
OUT="${OUT:-$PWD/dist}"

WANTED=(libmlx.a libmlxc.a libgguflib.a mlx.metallib)
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "==> mlx-c ${MLX_C_REF}"
git clone --quiet --depth 1 --branch "${MLX_C_REF}" \
  https://github.com/ml-explore/mlx-c.git "$work/mlx-c"
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

# Found rather than named: the layout under _deps is CMake's, and it has
# moved before. A missing file is a failure here rather than a surprise in
# whatever links this.
mkdir -p "$OUT"
for name in "${WANTED[@]}"; do
  found="$(find "$work/build" -name "$name" -type f | head -1)"
  if [ -z "$found" ]; then
    echo "!! $name was not built. The tree holds:" >&2
    find "$work/build" \( -name '*.a' -o -name '*.metallib' \) >&2
    exit 1
  fi
  cp "$found" "$OUT/$name"
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
(cd "$OUT" && shasum -a 256 "${WANTED[@]}" | tee SHA256SUMS)
ls "$OUT"
