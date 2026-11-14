package main

import "core:os"
import "core:strings"

import "emu"
import "systems/gb"
import "systems/gba"
import "systems/nes"
import "systems/psx"
import "systems/sms"
import "systems/snes"

// The running console. Each variant is a heap-allocated core owned by the app.
Machine :: union {
	^nes.Console,
	^snes.Console,
	^psx.Console,
	^gb.Console,
	^sms.Console,
	^gba.Console,
}

// Picks a system from the file extension, or returns false.
system_for_path :: proc(path: string) -> (emu.System_Kind, bool) {
	ext := strings.to_lower(os.ext(path), context.temp_allocator)
	for info, kind in emu.SYSTEM_INFO {
		for e in info.extensions {
			if e == ext {
				return kind, true
			}
		}
	}
	return {}, false
}

is_supported_file :: proc(path: string) -> bool {
	_, ok := system_for_path(path)
	return ok
}

// Common naming conventions for European releases ("(E)", "(Europe)",
// "(PAL)", ...). Many NES dumps only record the region in the file name.
filename_says_pal :: proc(path: string) -> bool {
	name := strings.to_lower(os.base(path), context.temp_allocator)
	tags := [?]string{"(e)", "(europe)", "(pal)", "(eu)", "(germany)", "(france)", "(spain)", "(italy)", "(australia)", "(uk)", "(sweden)", "(netherlands)"}
	for t in tags {
		if strings.contains(name, t) {
			return true
		}
	}
	return false
}

// Loads a game. Cartridge images are read whole; PlayStation discs are
// opened and streamed sector by sector.
machine_create :: proc(kind: emu.System_Kind, path: string, bios: []u8) -> (machine: Machine, err: emu.Load_Error) {
	read_rom :: proc(path: string) -> ([]u8, emu.Load_Error) {
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil {
			return nil, .Io
		}
		return data, .None
	}
	pal := filename_says_pal(path)
	switch kind {
	case .NES:
		rom := read_rom(path) or_return
		defer delete(rom)
		return nes.create(rom, pal)
	case .SNES:
		rom := read_rom(path) or_return
		defer delete(rom)
		msu, _ := msu1_open(path)
		c, create_err := snes.create(rom, pal, msu)
		if create_err != .None && msu.close != nil {
			msu.close(msu.user)
		}
		return c, create_err
	case .GB:
		rom := read_rom(path) or_return
		defer delete(rom)
		return gb.create(rom)
	case .SMS, .GG:
		rom := read_rom(path) or_return
		defer delete(rom)
		return sms.create(rom, kind == .GG)
	case .GBA:
		rom := read_rom(path) or_return
		defer delete(rom)
		return gba.create(rom)
	case .PSX:
		ext := strings.to_lower(os.ext(path), context.temp_allocator)
		if ext == ".exe" || ext == ".psx" {
			exe := read_rom(path) or_return
			defer delete(exe)
			return psx.create(bios, nil, exe)
		}
		disc := psx.disc_open(path) or_return
		c, create_err := psx.create(bios, disc, nil)
		if create_err != .None {
			psx.disc_close(disc)
		}
		return c, create_err
	}
	return nil, .Unsupported_Format
}

machine_destroy :: proc(m: ^Machine) {
	switch c in m^ {
	case ^nes.Console:
		nes.destroy(c)
	case ^snes.Console:
		snes.destroy(c)
	case ^psx.Console:
		psx.destroy(c)
	case ^gb.Console:
		gb.destroy(c)
	case ^sms.Console:
		sms.destroy(c)
	case ^gba.Console:
		gba.destroy(c)
	}
	m^ = nil
}

machine_kind :: proc(m: Machine) -> emu.System_Kind {
	switch c in m {
	case ^nes.Console:
		return .NES
	case ^snes.Console:
		return .SNES
	case ^psx.Console:
		return .PSX
	case ^gb.Console:
		return .GB
	case ^sms.Console:
		return c.game_gear ? .GG : .SMS
	case ^gba.Console:
		return .GBA
	}
	return .NES
}

machine_run_frame :: proc(m: Machine, input: emu.Input, audio: ^emu.Audio_Buffer) {
	switch c in m {
	case ^nes.Console:
		nes.run_frame(c, input, audio)
	case ^snes.Console:
		snes.run_frame(c, input, audio)
	case ^psx.Console:
		psx.run_frame(c, input, audio)
	case ^gb.Console:
		gb.run_frame(c, input, audio)
	case ^sms.Console:
		sms.run_frame(c, input, audio)
	case ^gba.Console:
		gba.run_frame(c, input, audio)
	}
}

machine_reset :: proc(m: Machine) {
	switch c in m {
	case ^nes.Console:
		nes.reset(c)
	case ^snes.Console:
		snes.reset(c)
	case ^psx.Console:
		psx.reset(c)
	case ^gb.Console:
		gb.reset(c)
	case ^sms.Console:
		sms.reset(c)
	case ^gba.Console:
		gba.reset(c)
	}
}

machine_frame :: proc(m: Machine, cfg: ^Config) -> emu.Frame {
	switch c in m {
	case ^nes.Console:
		return nes.frame(c, cfg.crop_overscan)
	case ^snes.Console:
		return snes.frame(c)
	case ^psx.Console:
		return psx.frame(c)
	case ^gb.Console:
		return gb.frame(c)
	case ^sms.Console:
		return sms.frame(c)
	case ^gba.Console:
		return gba.frame(c)
	}
	return {}
}

// Width of one pixel relative to its height, as displayed on a television.
// SNES frames taller than this are interlaced (448 or 478 rows).
MAX_PROGRESSIVE_SNES_LINES :: 239

machine_pixel_aspect :: proc(m: Machine, f: emu.Frame) -> f32 {
	switch c in m {
	case ^nes.Console:
		return 8.0 / 7.0
	case ^snes.Console:
		// 8:7 pixels at 256 wide; hi-res frames have twice as many, half as
		// wide, and interlaced frames twice as many rows, half as tall.
		par: f32 = f.width > 256 ? 4.0 / 7.0 : 8.0 / 7.0
		if f.height > MAX_PROGRESSIVE_SNES_LINES {
			par *= 2
		}
		return par
	case ^psx.Console:
		// Every PlayStation video mode fills a 4:3 screen.
		return (4.0 / 3.0) * f32(f.height) / f32(max(f.width, 1))
	case ^gb.Console:
		return 1 // square pixels on the LCD
	case ^sms.Console:
		// Master System pixels are 8:7 like Nintendo's; the Game Gear LCD's are wider.
		return c.game_gear ? 6.0 / 5.0 : 8.0 / 7.0
	case ^gba.Console:
		return 1
	}
	return 1
}

machine_save_ram :: proc(m: Machine) -> []u8 {
	switch c in m {
	case ^nes.Console:
		return nes.save_ram(c)
	case ^snes.Console:
		return snes.save_ram(c)
	case ^psx.Console:
		return psx.save_ram(c)
	case ^gb.Console:
		return gb.save_ram(c)
	case ^sms.Console:
		return sms.save_ram(c)
	case ^gba.Console:
		return gba.save_ram(c)
	}
	return nil
}

machine_load_save_ram :: proc(m: Machine, data: []u8) {
	switch c in m {
	case ^nes.Console:
		nes.load_save_ram(c, data)
	case ^snes.Console:
		snes.load_save_ram(c, data)
	case ^psx.Console:
		psx.load_save_ram(c, data)
	case ^gb.Console:
		gb.load_save_ram(c, data)
	case ^sms.Console:
		sms.load_save_ram(c, data)
	case ^gba.Console:
		gba.load_save_ram(c, data)
	}
}

// Snapshot of the whole machine, allocated with `allocator`; nil on failure.
machine_save_state :: proc(m: Machine, allocator := context.allocator) -> []u8 {
	switch c in m {
	case ^nes.Console:
		return nes.save_state(c, allocator)
	case ^snes.Console:
		return snes.save_state(c, allocator)
	case ^psx.Console:
		return psx.save_state(c, allocator)
	case ^gb.Console:
		return gb.save_state(c, allocator)
	case ^sms.Console:
		return sms.save_state(c, allocator)
	case ^gba.Console:
		return gba.save_state(c, allocator)
	}
	return nil
}

// Restores a snapshot. Returns false (leaving the machine untouched) when
// the data was not made by this build for this game.
machine_load_state :: proc(m: Machine, data: []u8) -> bool {
	switch c in m {
	case ^nes.Console:
		return nes.load_state(c, data)
	case ^snes.Console:
		return snes.load_state(c, data)
	case ^psx.Console:
		return psx.load_state(c, data)
	case ^gb.Console:
		return gb.load_state(c, data)
	case ^sms.Console:
		return sms.load_state(c, data)
	case ^gba.Console:
		return gba.load_state(c, data)
	}
	return false
}

// Frames per second of the running console (PAL consoles run at 50 Hz).
machine_fps :: proc(m: Machine) -> f64 {
	switch c in m {
	case ^nes.Console:
		return nes.fps(c)
	case ^snes.Console:
		return snes.fps(c)
	case ^psx.Console:
		return emu.SYSTEM_INFO[.PSX].fps
	case ^gb.Console:
		return emu.SYSTEM_INFO[.GB].fps
	case ^sms.Console:
		return sms.fps(c)
	case ^gba.Console:
		return gba.fps(c)
	}
	return 60
}
