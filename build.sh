#!/usr/bin/env bash
# Builds MLX and mlx-c, and installs them as one prefix that says what it
# holds. Runs the same way on a workstation and on CI; the workflow beside
# it adds only the toolchain of the day and the release.
#
# The prefix answers two questions at once. `mlx/lib/` holds the files a
# Rust build links, which is what `MLX_PREBUILT_PATH` wants. The tree
# `mlx/` is what `find_package(MLX)` looks for, which is how a consumer
# builds mlx-c against an MLX it did not compile
# (`MLX_C_USE_SYSTEM_MLX`). One copy of the bytes, either way in.
#
# Under `mlx/` rather than at the root because `lib` is cmake's name for
# it (GNUInstallDirs), and a bare `lib/` at the top of an archive reads
# like somebody else's `lib` to whoever unpacks it. Renaming it is not an
# option: the exported package bakes the path in, so a directory moved
# afterwards is a package `find_package` can no longer follow.
#
# Two platforms, and the backend is what separates them.
#
# On macOS, Metal is not optional. MLX probes the Metal compiler fatally
# when configuring with MLX_BUILD_METAL=ON, and its library target depends
# on a metallib it compiles itself, so a machine without the toolchain
# cannot produce these no matter what it is handed.
#
# On Linux it is CUDA, which needs the CUDA toolkit and cuDNN on the
# builder but not a GPU, and which changes what ends up in the box:
# no metallib, and headers that are not there for compiling against.
set -euo pipefail

# What to build. These are not free choices: mlx-c pins the MLX it fetches
# (FetchContent GIT_TAG), and whatever consumes these links against
# bindings generated from mlx-c's headers. The pair has to be the pair the
# consumer expects, or the headers describe one library and the archive is
# another.
MLX_C_REF="${MLX_C_REF:-c74db5307cc8ce122f48d97ef951b30578674e7f}"
OUT="${OUT:-$PWD/dist}"

# Which archive this run is making. Everything that differs between the
# two platforms is decided here and nowhere else.
#
# `MLX_CUDA_ARCHITECTURES` is a knob because a builder is not the machine
# that will run the result, and MLX otherwise reads the architecture off
# an installed GPU and stops when there is none to read. MLX compiles some
# of its CUDA sources ahead of time and JITs the rest through NVRTC, so
# this list governs the first half; the headers below are what the second
# half needs. A card the list does not name fails at run time, not here,
# which is the failure to expect if this value is ever wrong.
#
# NCCL is deliberately absent from the builder. MLX links it when cmake
# finds it, and a library with NCCL symbols in it needs `-lnccl` on the
# consumer's link line, which mlx-sys does not emit. One GPU needs none of
# it; leaving it uninstalled is what keeps the archive linkable.
case "$(uname -s)" in
Darwin)
  PLATFORM="macos-$(uname -m)"
  BACKEND=(-DMLX_BUILD_METAL=ON)
  WANTED=(libmlx.a libmlxc.a libgguflib.a mlx.metallib)
  HEADERS=()
  JOBS="$(sysctl -n hw.ncpu)"
  ;;
Linux)
  # Named after the CUDA that built it, because that is what the result
  # is bound to: the runtime and cuDNN are linked by soname, and 12 and 13
  # do not share theirs. Read from nvcc rather than assumed, and demanded
  # here so that a missing toolkit is an error with a name on it rather
  # than a failure somewhere inside cmake.
  if ! command -v nvcc > /dev/null; then
    echo "!! nvcc is not on PATH: MLX's CUDA backend needs the CUDA toolkit" >&2
    echo "   and cuDNN on this machine, though not a GPU." >&2
    exit 1
  fi
  cuda="$(nvcc --version | sed -n 's/.*release \([0-9]*\).*/\1/p')"
  PLATFORM="linux-$(uname -m)-cuda${cuda}"
  BACKEND=(
    -DMLX_BUILD_METAL=OFF
    -DMLX_BUILD_CUDA=ON
    "-DMLX_CUDA_ARCHITECTURES=${MLX_CUDA_ARCHITECTURES:-80;86;89;90a}"
  )
  WANTED=(libmlx.a libmlxc.a libgguflib.a)
  # What MLX installs for its own runtime compiler rather than for a
  # caller to include. Without these, kernels that are JIT-compiled fail
  # on the machine that runs them, which is a long way from here.
  HEADERS=(cccl cute cutlass)
  JOBS="$(nproc)"
  ;;
*)
  echo "!! $(uname -s) is not a platform this builds for" >&2
  exit 1
  ;;
esac

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
  "${BACKEND[@]}" \
  -DMLX_BUILD_TESTS=OFF \
  -DMLX_BUILD_EXAMPLES=OFF \
  -DMLX_BUILD_BENCHMARKS=OFF \
  -DMLX_BUILD_PYTHON_BINDINGS=OFF
cmake --build "$work/build" -j "$JOBS"

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

# Spelled `${a[@]+"${a[@]}"}` rather than `"${a[@]}"` because macOS ships
# bash 3.2, where the second form of an empty array is an unbound variable
# and `set -u` ends the run. HEADERS is empty on exactly that platform.
for name in ${HEADERS[@]+"${HEADERS[@]}"}; do
  if [ ! -d "$PREFIX/include/$name" ]; then
    echo "!! include/$name is not in the install tree, so kernels that are" >&2
    echo "   compiled at run time would fail on the machine that runs them." >&2
    ls "$PREFIX/include" >&2
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

# The headers installed above are NVIDIA's, not MLX's, and shipping them
# carries their notices too: CCCL is Apache-2.0 with the LLVM exception,
# CUTLASS is BSD-3-Clause. Taken from what was fetched, for the same
# reason the two above are.
for name in ${HEADERS[@]+"${HEADERS[@]}"}; do
  [ "$name" = "cute" ] && continue # cute ships inside CUTLASS
  src="$(find "$work/build/_deps" -maxdepth 1 -type d -name "${name}-src" | head -1)"
  licence="$(find "${src:-/nonexistent}" -maxdepth 1 -iname 'LICENSE*' | head -1)"
  if [ -z "$licence" ]; then
    echo "!! no licence found for the ${name} headers this archive ships;" >&2
    echo "   it may not be redistributed without one" >&2
    exit 1
  fi
  cp "$licence" "$OUT/LICENSE.${name}"
done

# What is in it, beside it. A consumer that pins the digest still wants to
# know what the digest is of.
{
  echo "mlx-c    ${MLX_C_REF}"
  echo "mlx      ${mlx_tag}"
  echo "platform ${PLATFORM}"
  echo "built    $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [ "$(uname -s)" = Darwin ]; then
    echo "macos    $(sw_vers -productVersion)"
    echo "xcode    $(xcodebuild -version | head -1)"
  else
    echo "distro   $(. /etc/os-release && echo "$PRETTY_NAME")"
    echo "cuda     $(nvcc --version | sed -n 's/.*release \([0-9.]*\).*/\1/p')"
    echo "arch     ${MLX_CUDA_ARCHITECTURES:-80;86;89;90a}"
  fi
} > "$OUT/MANIFEST.txt"
cat "$OUT/MANIFEST.txt"
if [ "$(uname -s)" = Darwin ]; then
  (cd "$PREFIX/lib" && shasum -a 256 "${WANTED[@]}" | tee "$OUT/SHA256SUMS")
else
  (cd "$PREFIX/lib" && sha256sum "${WANTED[@]}" | tee "$OUT/SHA256SUMS")
fi
echo "==> what was made, headers aside:"
find "$OUT" -maxdepth 3 -not -path "*/include/*" | sort
