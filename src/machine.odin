package main

import "core:os"
import "core:strings"

import "emu"
import "systems/gb"
import "systems/nes"
import "systems/psx"
import "systems/snes"

// The running console. Each variant is a heap-allocated core owned by the app.
Machine :: union {
	^nes.Console,
	^snes.Console,
	^psx.Console,
	^gb.Console,
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
	switch kind {
	case .NES:
		rom := read_rom(path) or_return
		defer delete(rom)
		return nes.create(rom)
	case .SNES:
		rom := read_rom(path) or_return
		defer delete(rom)
		return snes.create(rom)
	case .GB:
		rom := read_rom(path) or_return
		defer delete(rom)
		return gb.create(rom)
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
	}
	m^ = nil
}

machine_kind :: proc(m: Machine) -> emu.System_Kind {
	switch _ in m {
	case ^nes.Console:
		return .NES
	case ^snes.Console:
		return .SNES
	case ^psx.Console:
		return .PSX
	case ^gb.Console:
		return .GB
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
	}
	return {}
}

// Width of one pixel relative to its height, as displayed on a television.
machine_pixel_aspect :: proc(m: Machine, f: emu.Frame) -> f32 {
	switch _ in m {
	case ^nes.Console:
		return 8.0 / 7.0
	case ^snes.Console:
		// 8:7 pixels at 256 wide; hi-res frames have twice as many, half as wide.
		return f.width > 256 ? 4.0 / 7.0 : 8.0 / 7.0
	case ^psx.Console:
		// Every PlayStation video mode fills a 4:3 screen.
		return (4.0 / 3.0) * f32(f.height) / f32(max(f.width, 1))
	case ^gb.Console:
		return 1 // square pixels on the LCD
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
	}
	return false
}
