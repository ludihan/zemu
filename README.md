# ZEMU

A libretro frontend written in [Odin](https://odin-lang.org) with a GUI in the
style of ZSNES. It runs on desktop (Linux, Windows, macOS), Android and the web,
using SDL3 for windowing, audio and input.

## Building

```sh
./build.sh desktop   # debug build -> build/zemu
./build.sh release   # optimized build
./build.sh run       # build and run
```

Requires the Odin compiler and SDL3.
