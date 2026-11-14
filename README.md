# zemu

A multi-system emulator written in [Odin](https://odin-lang.org), with an
interface in the style of the classic DOS-era emulators: a pixel font, bevelled
gradient windows you can drag around, a top menu bar and a falling-snow
desktop. The whole interface is drawn directly with the SDL3 renderer. There
is no GUI library, and the font is an original one made for this project.

| System | Status |
| --- | --- |
| Nintendo Entertainment System | Complete. Mappers 0-5, 7, 9, 10, 11, 21-26 (Konami VRC2/4/6 with VRC6 audio), 34, 66, 69 (Sunsoft FME-7), 71, 79, 87, 140, 180, 206, 232. Passes `nestest` and the blargg CPU, APU, MMC3 and VBL suites listed in `nes_test.odin`. |
| Super Nintendo | 65816, PPU modes 0–7 (mode 7, offset-per-tile, hi-res, windows, color math, mosaic), DMA/HDMA, SPC700 and DSP audio. LoROM/HiROM/ExHiROM with battery saves. Matches every reference screen of PeterLemon's SNES CPU suite. |
| Game Boy / Color | SM83 CPU, PPU with full CGB support (VRAM banks, color palettes, HDMA, double speed), APU, MBC1/2/3 (with clock)/5, battery saves. Passes blargg's `cpu_instrs`, `instr_timing`, `mem_timing` and most of `dmg_sound`, and renders dmg-acid2 and cgb-acid2 correctly. |
| PlayStation | R3000A, GTE, software GPU, DMA, timers, CD-ROM (CUE/BIN/ISO, CD-DA, XA audio), SPU with reverb, pads, memory cards, MDEC video. Needs a BIOS for discs; homebrew `.exe` files also run without one. |

PlayStation 2 and 3 are not supported. Emulating them needs recompiling
CPU cores and GPU-accelerated graphics on a scale far beyond these
interpreters.

## Building

You need the Odin compiler (a 2026 build or newer) and SDL 3.4. zemu uses
Odin's vendored SDL3 bindings (`vendor:sdl3`).

* **Windows:** Odin ships `SDL3.dll`; `build.bat` copies it next to the executable.
* **Linux / macOS:** install the SDL3 3.4 development package (`libsdl3-dev`,
  `brew install sdl3`, …) or build SDL from source.

```sh
./build.sh            # release build -> build/zemu
./build.sh debug      # bounds checks, debug info, leak tracking
./build.sh test       # unit and regression tests
build.bat             # Windows
```

## Using it

```sh
build/zemu                         # opens the menu
build/zemu game.sfc                # starts a game straight away
build/zemu --help                  # all options
```

Press **Esc** to bring up the menu over the paused game, and Esc again to go
back. You can also drag a file onto the window to load it.

| Key | Action |
| --- | --- |
| Esc | menu / back to game / close window |
| Tab (hold) | fast forward |
| P | pause |
| F2 / F4 | save / load state |
| F3 | next save state slot (0-9) |
| F12 | screenshot (native resolution BMP) |
| Ctrl+O | load game |
| Ctrl+R | reset |
| Alt+Enter, F11 | fullscreen |

Default controls for player 1 are the arrow keys, **Z X A S** for B A Y X,
**Q W** for L R, **E R** for L2 R2, **Enter** for Start and **Right Shift**
for Select. You can remap them in *CONFIG > Input*. Gamepads work
automatically with SDL's standard mapping. On a PlayStation pad, Cross is B,
Circle is A, Square is Y and Triangle is X.

### Video

Games are always letterboxed with black bars and never stretched. The
*CONFIG > Video* window has these options:

* **Aspect**: *Original (TV)* uses each console's real pixel shape (8:7 for
  Nintendo, 4:3 for PlayStation), *4:3* forces a 4:3 picture, and *Square
  pixels* shows the raw framebuffer.
* **Integer scaling** keeps the vertical scale a whole number.
* **Smooth filter** turns on bilinear filtering (off by default).

The interface has its own scale (*CONFIG > Interface*, 1x–8x) and a choice of
color themes. It does not resize itself to fit the window: a bigger window
simply shows more desktop, and windows stay where you put them.

### Files

Configuration, saves and screenshots go in SDL's per-user preference
directory, for example `~/.local/share/zemu/zemu/` on Linux or
`%APPDATA%\zemu\zemu\` on Windows.

* `zemu.cfg`: settings, key bindings and recent games
* `saves/<game>.srm`: NES/SNES battery RAM
* `saves/<game>.mcr`: PlayStation memory card (slot 1), written only once a game saves
* `saves/<game>.st0`–`.st9`: save states. They are tied to the exact game and
  zemu build that made them, and anything else is refused.

For PlayStation games, point *CONFIG > Paths* at a BIOS image (512 KiB, for
example `SCPH1001.BIN`). zemu does not include a BIOS.

## Project layout

```
src/
  main.odin, app.odin, ui.odin, ...   package main: the frontend
  emu/                                shared types: input, frames, audio, save states
  gui/                                immediate-mode widget toolkit on the SDL renderer
  systems/nes/                        package nes
  systems/snes/                       package snes
  systems/psx/                        package psx
```

The cores don't depend on SDL or on each other. Each one exposes `create`,
`run_frame`, `frame`, `reset`, `save_ram` and `save_state`, and the frontend
dispatches over a tagged union (`Machine` in `machine.odin`).

## Testing

The NES, SNES, Game Boy and PlayStation tests run freely redistributable test ROMs. They
are not included, so clone the suites and point the tests at them:

```sh
git clone https://github.com/christopherpow/nes-test-roms
git clone https://github.com/PeterLemon/SNES
git clone https://github.com/PeterLemon/PSX
mkdir gbtests && git clone https://github.com/retrio/gb-test-roms gbtests/gb-test-roms
# plus the dmg-acid2 and cgb-acid2 release ROMs and repositories, as
# gbtests/dmg-acid2/dmg-acid2.gb and gbtests/cgb-acid2/cgb-acid2.gbc
ZEMU_NES_TESTS=nes-test-roms ZEMU_SNES_TESTS=SNES ZEMU_PSX_TESTS=PSX ZEMU_GB_TESTS=gbtests ./build.sh test
```

`./build.sh test` also runs the interface tests, which drive the real app
headlessly with synthetic mouse and keyboard input.

The test runner skips tests whose ROMs aren't available. The frontend also
has headless options for debugging (`--frames`, `--dump-frame`,
`--dump-audio`, `--screenshot`).

### Memory safety

* Every core addresses its memory through masks, or through slices whose
  sizes were checked at load, and Odin's bounds checks stay on in release
  builds.
* ROM, disc, executable and save-state loaders reject malformed input. The
  code has been run under AddressSanitizer and fuzzed with corrupt and random
  images.
* Debug builds use a tracking allocator that reports leaks and bad frees on exit.

## Known limitations

* NES: a few dot-exact PPU timing tests (VBL/NMI edge races, open-bus decay) still fail.
* SNES: no enhancement chips (Super FX, SA-1, DSP-1, …); such games are
  refused at load. Interlaced 448/478-line modes show one field.
* PlayStation: GPU polygon edges can differ by one pixel from hardware on
  some slopes.

## License

GNU AGPL v3, see `LICENSE`. The SPC700 boot ROM is an original program that
implements the documented upload protocol; it is not Nintendo's IPL.
