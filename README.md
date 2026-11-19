# ZEMU

A [libretro](https://www.libretro.com/) frontend written in [Odin](https://odin-lang.org),
with a GUI in the style of ZSNES. It runs on desktop (Linux, Windows, macOS),
Android and the web, using SDL3 for windowing, audio and input.

- **ZSNES look.** Pixel font, blue gradient windows, the menu bar
  (GAME, CONFIG, CORES, CHEAT, NETPLAY, MISC), falling snow and the load
  dialog with type-to-jump. Window colours are adjustable in MISC > GUI OPTS.
- **Adapts to the screen.** The GUI is drawn at a low resolution and scaled by
  whole pixels. Bigger windows get more room rather than just bigger pixels.
- **Touch UI on phones.** Bottom tabs, big scrollable rows, action sheets and
  an on-screen multitouch gamepad that lays itself out for portrait or
  landscape. You can switch interfaces in GUI OPTS or SETTINGS.
- **Easy cores.** CORES lists everything on the libretro buildbot for your
  platform. Search by name, system or file extension, then download, update
  or remove cores. Opening a file no installed core can handle takes you
  straight to the cores that can.
- **The usual.** Save RAM, 10 save state slots, fast forward, core options,
  cheats, gamepads (with Guide or Back+Start to open the GUI), rumble, and
  rebindable keys.

## Building

All targets need the Odin compiler (a recent `dev-2026-xx` release).

| Target | Command | Output | Needs |
|---|---|---|---|
| Desktop | `./build.sh desktop` (debug) or `./build.sh release` | `build/zemu` | SDL3 |
| Android | `./build.sh android` | `build/zemu.apk` | `ANDROID_HOME`, `ANDROID_NDK_HOME` (r30), a JDK, cmake, ninja |
| Web | `./build.sh web` | `build/web/site/` | emsdk, cmake, ninja |

`./build.sh run [core] [game]` builds and runs the desktop version.

The Android and web builds download the SDL3 source into `third_party/` and
build it themselves. For Android, `ZEMU_ANDROID_ABIS="arm64-v8a x86_64"`
also builds for the emulator. The APK is signed with your Android debug key,
or with `ZEMU_KEYSTORE` and `ZEMU_KEYSTORE_PASS` if you set them.

## Using it

Open **CORES** and download a core for the system you want. Then use
**GAME > LOAD** to pick a game. On phones, tap **+ ADD** to import game files
from the system file picker.

| Key | Action |
|---|---|
| Esc | open/close the GUI |
| F2 / F4 | save / load state |
| F3 | next state slot |
| ` (hold) / F9 | fast forward / toggle fast forward |
| P | pause |
| F11, Alt+Enter | fullscreen |

The default player 1 layout follows ZSNES: arrows, Z/X/A/S for B/A/Y/X, D/C
for L/R, Enter for Start and Right Shift for Select. Rebind under
CONFIG > INPUT.

Data (cores, saves, states, settings) lives in SDL's per-user folder, for
example `~/.local/share/zemu/zemu/` on Linux. The path is shown in MISC > ABOUT.

## The web version

Browsers can't load native cores, so the web build loads cores compiled to
WebAssembly side modules with `dlopen`. The buildbot doesn't publish those, so
`scripts/build_web_cores.sh` builds a set from source into
`build/web/site/cores/` in the same layout as the buildbot. CI does this and
deploys the site to GitHub Pages. To enable it, set Pages to "GitHub Actions"
under the repository settings.

Saves and imported games are kept in IndexedDB. Games can also be dropped on
the page. `index.html?arg=<core>&arg=<game>` starts a game directly.

`tests/testcore/` is a tiny libretro core with no content. It's handy for
checking that the frontend works end to end on each platform.

## Layout

```
src/                  the frontend (package zemu)
  libretro/           libretro API bindings
  main.odin           SDL main callbacks, hotkeys
  core.odin           loading cores and games, save RAM, states, core options
  environment.odin    the environment callback
  video/audio/input/timing.odin
  gui*.odin           ZSNES-style desktop GUI, widgets, dialogs, touch UI
  downloader.odin     buildbot catalog and core installs
  http_*.odin         downloads per platform (curl, JNI, fetch)
android/              manifest, resources, ZemuActivity.java
web/                  Emscripten shell, JS glue, C entry
scripts/              web core builder
.github/workflows/    CI for every platform
```
