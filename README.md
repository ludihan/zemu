# zemu

A multi-system emulator written in [Odin](https://odin-lang.org), with an
interface in the style of the classic DOS-era emulators: a pixel font, bevelled
gradient windows you can drag around, a top menu bar and a falling-snow
desktop. The whole interface is drawn directly with the SDL3 renderer. There
is no GUI library, and the font is an original one made for this project.

| System | Status |
| --- | --- |
| Nintendo Entertainment System | Complete. Mappers 0-5, 7, 9, 10, 11, 21-26 (Konami VRC2/4/6 with VRC6 audio), 34, 66, 69 (Sunsoft FME-7), 71, 79, 87, 140, 180, 206, 232. Master-clock CPU/PPU alignment and a cycle-accurate DMA unit. Passes `nestest` and the blargg CPU, interrupt, reset, APU, PPU VBL/NMI, open-bus, OAM and MMC3 suites listed in `nes_test.odin`. |
| Super Nintendo | 65816, PPU modes 0–7 (mode 7, offset-per-tile, hi-res, interlace, windows, color math, mosaic), DMA/HDMA, SPC700 and DSP audio. LoROM/HiROM/ExHiROM with battery saves, Super FX (GSU) cartridges and MSU-1 (data and CD-quality audio tracks for ROM hacks and translations). Matches every reference screen of PeterLemon's SNES CPU suite and 55 of his Super FX tests. |
| Game Boy / Color | SM83 CPU, PPU with full CGB support (VRAM banks, color palettes, HDMA, double speed), APU, MBC1/2/3 (with clock)/5, battery saves, the DMG OAM corruption bug. Passes blargg's `cpu_instrs`, `instr_timing`, `mem_timing(-2)`, `halt_bug`, `interrupt_time`, every `dmg_sound` and `cgb_sound` test and most of `oam_bug`, and renders dmg-acid2 and cgb-acid2 correctly. |
| Game Boy Advance | ARM7TDMI (ARM and Thumb, with the prefetch pipeline), all six video modes with affine backgrounds and sprites, windows and blending, DMA, timers, Game Boy sound plus Direct Sound, SRAM/Flash/EEPROM saves, the cartridge clock (Pokémon, Boktai). The BIOS is emulated, so none is needed. Passes jsmolka's `gba-tests` and DenSinH's FuzzARM ROMs. |
| Sega Master System / Game Gear | Z80 (passes ZEXDOC and ZEXALL, including undocumented flags), Mode 4 VDP with line interrupts, sprite zoom and collision, SN76489 sound with Game Gear stereo, Sega mapper with cartridge RAM. |
| PlayStation | R3000A, GTE, software GPU, DMA, timers, CD-ROM (CUE/BIN/ISO, CD-DA, XA audio), SPU with reverb, pads, memory cards, MDEC video. Needs a BIOS for discs; homebrew `.exe` files run without one on an emulated BIOS (TTY, critical sections, interrupt hooks, events, pads, exception hooks). Checked against hardware results from JaCzekanski's ps1-tests: polygon and line rasterization, Gouraud/UV interpolation, the palette cache and texture flipping match VRAM dumps; the GTE passes all 1150 register/opcode tests and 150,000 lines of fuzzing output; MDEC 4-bit output is exact. |

NES and SNES games run with PAL (50 Hz) timing when the ROM header or a
file name tag such as `(Europe)` or `(PAL)` marks them as European releases.

PlayStation 2 support is in progress in `src/systems/ps2` and is not usable
yet. So far the Emotion Engine CPU (R5900 with its 128-bit MMI instructions
and non-IEEE FPU) runs bare-metal ELF programs, checked against C test
programs compiled with clang. The vector units, Graphics Synthesizer, IOP,
SPU2 and BIOS boot are still to come. PlayStation 3 is not planned.

## Building

You need the Odin compiler (dev-2026-08 or newer; it uses the new `core:os`) and SDL 3.4. zemu uses
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
| Backspace (hold) | rewind |
| P | pause |
| F2 / F4 | save / load state |
| F3 | next save state slot (0-9) |
| F12 | screenshot (native resolution BMP) |
| Ctrl+O | load game |
| Ctrl+R | reset |
| Alt+Enter, F11 | fullscreen |

Default controls for player 1 are the arrow keys, **Z X A S** for B A Y X,
**Q W** for L R, **E R** for L2 R2, **Enter** for Start and **Right Shift**
for Select. You can remap them in *CONFIG > INPUT*.

Gamepads (up to four, hot-pluggable) work automatically with SDL's standard
mapping: on a PlayStation pad, Cross is B, Circle is A, Square is Y and
Triangle is X; the left stick doubles as the d-pad and the triggers are L2/R2.
Each player's pad buttons can be remapped in the same window. The Guide
(Home/PS) button opens and closes the menu; in the menu, the d-pad moves,
South (Cross/A) chooses and East (Circle/B) goes back.

### Cheats

*CHEAT > ADD CODE* takes Game Genie codes (NES, SNES `XXXX-XXXX`, Game
Boy `ABC-DEF-GHI`), Pro Action Replay (SNES, Master System / Game Gear), GameShark (Game Boy, and
PlayStation `80XXXXXX YYYY` / `30XXXXXX 00YY`), CodeBreaker (Game Boy
Advance `3AAAAAAA 00VV` / `8AAAAAAA VVVV`) and raw `ADDRESS:VALUE` RAM
writes. Codes are kept per game in `saves/<game>.cht`.

### Video

Games are always letterboxed with black bars and never stretched. The
*CONFIG > VIDEO* window has these options:

* **Aspect**: *Original (TV)* uses each console's real pixel shape (8:7 for
  Nintendo, 4:3 for PlayStation), *4:3* forces a 4:3 picture, and *Square
  pixels* shows the raw framebuffer.
* **Integer scaling** keeps the vertical scale a whole number.
* **Smooth filter** turns on bilinear filtering (off by default).

The interface has its own scale (*MISC > GUI OPTS*, 1x–8x, 3x by default) and a choice of
color themes. It does not resize itself to fit the window: a bigger window
simply shows more desktop, and windows stay where you put them.

### Files

Configuration, saves and screenshots go in SDL's per-user preference
directory, for example `~/.local/share/zemu/zemu/` on Linux or
`%APPDATA%\zemu\zemu\` on Windows.

* `zemu.cfg`: settings, key bindings and recent games
* `saves/<game>.srm`: NES/SNES battery RAM
* `saves/<game>.mcr`: PlayStation memory card (slot 1), written only once a game saves
* `saves/<game>.cht`: cheat codes
* `saves/<game>.st0`–`.st9`: save states. They are tied to the exact game and
  zemu build that made them, and anything else is refused.

MSU-1 games find their files next to the ROM: `game.sfc` uses `game.msu`
for data and `game-0.pcm`, `game-1.pcm`, ... for audio tracks.

For PlayStation games, point *CONFIG > PATHS* at a BIOS image (512 KiB, for
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

The NES, SNES, Game Boy, GBA and PlayStation tests run freely redistributable test ROMs. They
are not included, so clone the suites and point the tests at them:

```sh
git clone https://github.com/christopherpow/nes-test-roms
git clone https://github.com/PeterLemon/SNES
git clone https://github.com/PeterLemon/PSX
mkdir gbtests && git clone https://github.com/retrio/gb-test-roms gbtests/gb-test-roms
# plus the dmg-acid2 and cgb-acid2 release ROMs and repositories, as
# gbtests/dmg-acid2/dmg-acid2.gb and gbtests/cgb-acid2/cgb-acid2.gbc
# ZEXDOC/ZEXALL for the Z80, e.g. from floooh/chips-test (tests/roms)
mkdir z80tests && cp chips-test/tests/roms/zex*.com z80tests/
git clone https://github.com/jsmolka/gba-tests
git clone https://github.com/DenSinH/FuzzARM
git clone https://github.com/JaCzekanski/ps1-tests
git clone --branch v0.19 https://github.com/Lameguy64/PSn00bSDK
PSN00BSDK=PSn00bSDK PS1_TESTS=ps1-tests tools/ps1-tests/build.sh   # needs clang + ld.lld
ZEMU_NES_TESTS=nes-test-roms ZEMU_SNES_TESTS=SNES ZEMU_PSX_TESTS=PSX ZEMU_GB_TESTS=gbtests \
ZEMU_Z80_TESTS=z80tests ZEMU_GBA_TESTS=gba-tests ZEMU_GBA_FUZZ=FuzzARM \
ZEMU_PS1_TESTS=ps1-tests ./build.sh test
```

JaCzekanski's ps1-tests ship VRAM dumps and TTY logs captured on a real
PlayStation; `tools/ps1-tests/build.sh` compiles them with clang (no GCC MIPS
toolchain needed; GTE instructions clang cannot assemble are emitted by
macros) and the tests compare zemu's VRAM and TTY output against them.

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

* NES: blargg's `sprdma_and_dmc_dma` still fails; the MMC6 and older-MMC3
  variant tests fail because those boards are not emulated.
* SNES: of the enhancement chips only the Super FX is emulated; games that
  need another (SA-1, DSP-1, Cx4, S-DD1, SPC7110, …) are refused at load.
* Game Boy: `oam_bug/7-timing_effect` has not been confirmed (it runs too long
  for the test harness).
* Game Boy Advance: the official sound driver's BIOS calls (used by a few
  games instead of their own mixer) are not emulated, and the prefetch
  buffer is modelled only roughly.
* PlayStation: overlapping VRAM-to-VRAM copies shifted 1-3 pixels to the
  right still differ from hardware in one column; 8-bit MDEC output is off by
  one in a few values; bus and DMA timings are not cycle-exact (ps1-tests'
  `access-time`, `bandwidth` and `chopping` measure them); the emulated BIOS
  covers what homebrew SDKs use, not the memory card or CD file services
  games need (use a real BIOS for discs).

## License

GNU AGPL v3, see `LICENSE`. The SPC700 boot ROM is an original program that
implements the documented upload protocol; it is not Nintendo's IPL.
