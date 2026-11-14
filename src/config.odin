package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"

import "emu"
import "gui"

Aspect_Mode :: enum u8 {
	Original, // the console's real pixel aspect, as on a CRT
	Force_4_3,
	Square,   // 1:1 pixels
}

ASPECT_NAMES := [Aspect_Mode]string {
	.Original  = "Original (TV)",
	.Force_4_3 = "4:3",
	.Square    = "Square pixels",
}

MAX_RECENT :: 8

Key_Map :: [emu.Button]sdl.Scancode

Config :: struct {
	ui_scale:      int,
	theme:         int,
	snow:          bool,
	integer_scale: bool,
	aspect:        Aspect_Mode,
	smooth:        bool,
	crop_overscan: bool,
	vsync:         bool,
	fullscreen:    bool,
	show_fps:      bool,
	rewind:        bool,
	audio:         bool,
	volume:        int,
	rom_dir:       string,
	psx_bios:      string,
	keys:          [emu.MAX_PADS]Key_Map,
	recent:        [dynamic]string,
}

DEFAULT_KEYS_P1 :: Key_Map {
	.Up     = .UP,
	.Down   = .DOWN,
	.Left   = .LEFT,
	.Right  = .RIGHT,
	.A      = .X,
	.B      = .Z,
	.X      = .S,
	.Y      = .A,
	.L      = .Q,
	.R      = .W,
	.L2     = .E,
	.R2     = .R,
	.Select = .RSHIFT,
	.Start  = .RETURN,
}

DEFAULT_KEYS_P2 :: Key_Map {
	.Up     = .I,
	.Down   = .K,
	.Left   = .J,
	.Right  = .L,
	.A      = .N,
	.B      = .B,
	.X      = .H,
	.Y      = .G,
	.L      = .T,
	.R      = .Y,
	.L2     = .UNKNOWN,
	.R2     = .UNKNOWN,
	.Select = .V,
	.Start  = .M,
}

BUTTON_NAMES := [emu.Button]string {
	.Up     = "UP",
	.Down   = "DOWN",
	.Left   = "LEFT",
	.Right  = "RIGHT",
	.A      = "A",
	.B      = "B",
	.X      = "X",
	.Y      = "Y",
	.L      = "L",
	.R      = "R",
	.L2     = "L2",
	.R2     = "R2",
	.Select = "SELECT",
	.Start  = "START",
}

config_defaults :: proc() -> Config {
	return Config {
		ui_scale      = 3,
		theme         = 0,
		snow          = true,
		integer_scale = false,
		aspect        = .Original,
		smooth        = false,
		crop_overscan = true,
		vsync         = true,
		audio         = true,
		rewind        = true,
		volume        = 80,
		keys          = {DEFAULT_KEYS_P1, DEFAULT_KEYS_P2},
	}
}

config_destroy :: proc(c: ^Config) {
	delete(c.rom_dir)
	delete(c.psx_bios)
	for r in c.recent {
		delete(r)
	}
	delete(c.recent)
	c.rom_dir = ""
	c.psx_bios = ""
	c.recent = nil
}

// Replaces an owned string field with a copy of `value`.
set_string :: proc(field: ^string, value: string) {
	if field^ == value {
		return
	}
	old := field^
	field^ = strings.clone(value)
	delete(old)
}

config_add_recent :: proc(c: ^Config, path: string) {
	for r, i in c.recent {
		if r == path {
			delete(r)
			ordered_remove(&c.recent, i)
			break
		}
	}
	inject_at(&c.recent, 0, strings.clone(path))
	for len(c.recent) > MAX_RECENT {
		delete(pop(&c.recent))
	}
}

@(private = "file")
parse_bool :: proc(s: string) -> bool {
	return s == "1" || s == "true" || s == "yes" || s == "on"
}

@(private = "file")
parse_int :: proc(s: string, fallback: int) -> int {
	v, ok := strconv.parse_int(s, 10)
	return ok ? v : fallback
}

config_load :: proc(c: ^Config, path: string) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		return
	}
	defer delete(data)

	it := string(data)
	for line in strings.split_lines_iterator(&it) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' {
			continue
		}
		eq := strings.index_byte(l, '=')
		if eq < 0 {
			continue
		}
		key := strings.trim_space(l[:eq])
		value := strings.trim_space(l[eq + 1:])

		switch key {
		case "ui_scale":      c.ui_scale = clamp(parse_int(value, 2), 1, 8)
		case "theme":         c.theme = parse_int(value, 0)
		case "snow":          c.snow = parse_bool(value)
		case "integer_scale": c.integer_scale = parse_bool(value)
		case "smooth":        c.smooth = parse_bool(value)
		case "crop_overscan": c.crop_overscan = parse_bool(value)
		case "vsync":         c.vsync = parse_bool(value)
		case "fullscreen":    c.fullscreen = parse_bool(value)
		case "show_fps":      c.show_fps = parse_bool(value)
		case "rewind":        c.rewind = parse_bool(value)
		case "audio":         c.audio = parse_bool(value)
		case "volume":        c.volume = clamp(parse_int(value, 80), 0, 100)
		case "rom_dir":       set_string(&c.rom_dir, value)
		case "psx_bios":      set_string(&c.psx_bios, value)
		case "aspect":
			for name, mode in ASPECT_NAMES {
				if name == value {c.aspect = mode}
			}
		case "recent":
			if len(c.recent) < MAX_RECENT {
				append(&c.recent, strings.clone(value))
			}
		case:
			// "p1.up = Up"
			if len(key) > 3 && key[0] == 'p' && key[2] == '.' {
				pad := int(key[1] - '1')
				if pad < 0 || pad >= emu.MAX_PADS {
					continue
				}
				for name, b in BUTTON_NAMES {
					if strings.equal_fold(name, key[3:]) {
						c.keys[pad][b] = scancode_from_name(value)
					}
				}
			}
		}
	}
	c.theme = clamp(c.theme, 0, len(gui.THEMES) - 1)
}

config_save :: proc(c: ^Config, path: string) -> bool {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	fmt.sbprintln(&b, "# zemu configuration")
	fmt.sbprintfln(&b, "ui_scale = %d", c.ui_scale)
	fmt.sbprintfln(&b, "theme = %d", c.theme)
	fmt.sbprintfln(&b, "snow = %v", c.snow)
	fmt.sbprintfln(&b, "integer_scale = %v", c.integer_scale)
	fmt.sbprintfln(&b, "aspect = %s", ASPECT_NAMES[c.aspect])
	fmt.sbprintfln(&b, "smooth = %v", c.smooth)
	fmt.sbprintfln(&b, "crop_overscan = %v", c.crop_overscan)
	fmt.sbprintfln(&b, "vsync = %v", c.vsync)
	fmt.sbprintfln(&b, "fullscreen = %v", c.fullscreen)
	fmt.sbprintfln(&b, "show_fps = %v", c.show_fps)
	fmt.sbprintfln(&b, "rewind = %v", c.rewind)
	fmt.sbprintfln(&b, "audio = %v", c.audio)
	fmt.sbprintfln(&b, "volume = %d", c.volume)
	fmt.sbprintfln(&b, "rom_dir = %s", c.rom_dir)
	fmt.sbprintfln(&b, "psx_bios = %s", c.psx_bios)
	for pad in 0 ..< emu.MAX_PADS {
		for name, btn in BUTTON_NAMES {
			fmt.sbprintfln(&b, "p%d.%s = %s", pad + 1, name, scancode_name(c.keys[pad][btn]))
		}
	}
	for r in c.recent {
		fmt.sbprintfln(&b, "recent = %s", r)
	}
	return os.write_entire_file(path, strings.to_string(b)) == nil
}

scancode_name :: proc(sc: sdl.Scancode) -> string {
	if sc == .UNKNOWN {
		return "None"
	}
	name := sdl.GetScancodeName(sc)
	if name == nil || len(name) == 0 {
		return "None"
	}
	return string(name)
}

scancode_from_name :: proc(name: string) -> sdl.Scancode {
	if name == "None" || name == "" {
		return .UNKNOWN
	}
	cname := strings.clone_to_cstring(name, context.temp_allocator)
	return sdl.GetScancodeFromName(cname)
}
