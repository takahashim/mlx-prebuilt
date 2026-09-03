# mlx-prebuilt

MLX and mlx-c, built for macOS arm64, published as one archive with its
digest.

## Why

MLX's Metal kernels need Apple's Metal toolchain, so a machine without it
cannot build MLX at all. Rust bindings (`mlx-sys`) accept a pre-built
directory through `MLX_PREBUILT_PATH`, and download somebody's with
`curl -L -f` if nobody supplies one, checking nothing beyond TLS.

This is the alternative: stated inputs, a hashed output, and a release
channel belonging to whoever depends on it.

## The archive

```
libmlx.a  libmlxc.a  libgguflib.a  mlx.metallib   what mlx-sys links
LICENSE.mlx  LICENSE.mlx-c                        taken from the sources built
MANIFEST.txt                                      versions, date, macOS, Xcode
SHA256SUMS                                        of the four
```

Its own SHA-256 is published beside it. Record that digest and refuse
anything else: a release asset can be replaced without the URL changing.

## Versions

`mlx-c` pins the MLX it fetches, and the bindings that link these are
generated from mlx-c's headers, so the pair has to be the one the consumer
expects. `build.sh` reads the MLX tag out of mlx-c rather than being told
it twice. mlx-c `v0.4.1` pins MLX `v0.32.0`.

## Building

```
./build.sh                    # into dist/
MLX_C_REF=v0.4.1 ./build.sh   # a different mlx-c, and whatever MLX it pins
```

Needs a Mac with Xcode and the Metal toolchain
(`xcodebuild -downloadComponent MetalToolchain`). Everything else it
fetches. The workflow does the same on a `macos-15` runner and attaches
the archive to a release when a tag is pushed.

**Nothing here has run on CI yet.** The first run is what establishes that
the toolchain installs on the image and that the four files land where
`build.sh` looks, which is why it searches rather than hardcoding paths.

## Licences

`build.sh` and the workflow are MIT (LICENSE). They are the only original
work here.

The archive is MLX and mlx-c compiled, both MIT, copyright ml-explore and
Apple. Their licence texts are copied out of the sources at build time and
ship inside the archive, so what is distributed carries its own notices.
