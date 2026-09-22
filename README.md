# mlx-prebuilt

MLX and mlx-c, built for macOS arm64 and for Linux x86_64 with CUDA,
published as archives with their digests.

## Why

MLX's Metal kernels need Apple's Metal toolchain, so a machine without it
cannot build MLX at all. Its CUDA backend needs the CUDA toolkit and
cuDNN, which a Mac does not have and a training box may not want to spend
half an hour on. Rust bindings (`mlx-sys`) accept a pre-built directory
through `MLX_PREBUILT_PATH`, and download somebody's with `curl -L -f` if
nobody supplies one, checking nothing beyond TLS.

This is the alternative: stated inputs, a hashed output, and a release
channel belonging to whoever depends on it.

## The archives

One per platform, each an install prefix rather than a bag of files:

```
mlx/lib/      libmlx.a libmlxc.a libgguflib.a   and, on macOS, mlx.metallib
mlx/include/  MLX's and mlx-c's headers
mlx/share/    cmake/MLX and cmake/MLXC, the exported packages
LICENSE.mlx  LICENSE.mlx-c   taken from the sources that were built
MANIFEST.txt                 versions, platform, date, and the toolchain
SHA256SUMS                   of the libraries in mlx/lib/
```

The CUDA archive carries two things the Metal one does not.
`mlx/include/cccl`, `mlx/include/cute` and `mlx/include/cutlass` are
NVIDIA's headers, installed by MLX for the kernels it compiles at run time
through NVRTC rather than for anyone to include; without them a run fails
on the machine doing the running. `LICENSE.cccl` and `LICENSE.cutlass`
travel with them.

That serves both ways of consuming it, from one copy of the bytes:

- **`mlx/lib/` is a `MLX_PREBUILT_PATH`**, which is what a Rust build
  wants when its bindings are already generated.
- **`mlx/` is a `CMAKE_PREFIX_PATH`**, so `find_package(MLX)` finds it.
  That is how mlx-c's `MLX_C_USE_SYSTEM_MLX` builds against an MLX it did
  not compile, which is what lets a machine with neither toolchain use the
  published `mlx-rs` rather than a fork of it.

The prefix is nested rather than unpacked at the root because `lib` is
cmake's name for that directory and a bare `lib/` at the top of an
archive reads like somebody else's. Renaming it is not on offer: the
exported package records paths relative to the prefix, so a directory
moved after the install is one `find_package` can no longer follow.

Its own SHA-256 is published beside it. Record that digest and refuse
anything else: a release asset can be replaced without the URL changing.

## Versions

`mlx-c` pins the MLX it fetches, and the bindings that link these are
generated from mlx-c's headers, so the pair has to be the one the consumer
expects. `build.sh` reads the MLX tag out of mlx-c rather than being told
it twice.

The CUDA archive is named after the CUDA that built it, read from `nvcc`.
That is not decoration: the runtime and cuDNN are linked by soname, and 12
and 13 do not share theirs.

## What is not in the CUDA archive, on purpose

**NCCL.** MLX links it when cmake finds it, and a library holding NCCL
symbols wants `-lnccl` on the consumer's link line, which `mlx-sys` does
not emit. A single GPU needs none of it, so the builder simply does not
install it.

**Every architecture.** `MLX_CUDA_ARCHITECTURES` decides which cards the
ahead-of-time half is compiled for, and defaults to `80;86;89;90a`
(Ampere through Hopper). MLX JITs the rest, so this is a floor rather
than the whole story, but a card outside the list fails at run time
rather than here. Pass a different list to build for a different one.

## Building

```
./build.sh                                   # into dist/
MLX_C_REF=v0.4.1 ./build.sh                  # a different mlx-c, and whatever MLX it pins
MLX_CUDA_ARCHITECTURES=90a ./build.sh        # one card rather than four
```

The platform is whatever the machine is. macOS needs Xcode and the Metal
toolchain (`xcodebuild -downloadComponent MetalToolchain`); Linux needs
the CUDA toolkit and cuDNN, though **not a GPU** — compiling for a card is
not the same as having one. Everything else it fetches.

The workflow does the same on `macos-15` and `ubuntu-22.04` and attaches
both archives to a release when a tag is pushed. It can also be run by
hand, which builds and keeps the archives as artifacts without releasing
anything.

**The Linux half has never run.** The first dispatch is what establishes
that the toolkit installs on the image, that the image has room for it,
that a static MLX comes out of a CUDA build at all, and that the JIT
headers land where `build.sh` looks for them.

## Licences

`build.sh` and the workflow are MIT (LICENSE). They are the only original
work here.

The archives are MLX and mlx-c compiled, both MIT, copyright ml-explore
and Apple. The CUDA one also ships NVIDIA's CCCL (Apache-2.0 with the
LLVM exception) and CUTLASS (BSD-3-Clause) headers. Every licence text is
copied out of the sources at build time and ships inside the archive, so
what is distributed carries its own notices.
