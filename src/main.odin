// zemu: a multi-system emulator (NES, SNES, PlayStation) with a classic
// DOS-emulator style interface, drawn directly with SDL3.
package main

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"

import "emu"
import "gui"

_ :: mem // only used by the debug tracking allocator

Options :: struct {
	rom:        string,
	frames:     int,    // run this many frames headlessly, then exit
	screenshot: string, // with --frames: save the window contents here (BMP)
	dump_frame: string, // with --frames: save the core's native frame here (BMP)
	dump_audio: string, // with --frames: save the audio produced here (WAV)
	open:       string, // with --frames: window to show (load, input, video, ui, sound, paths, about, cheats)
	menu:       bool,   // with --frames: show the menu over the game
	ui_scale:   int,
}

USAGE :: `usage: zemu [rom] [options]

  rom                 .nes .sfc .smc .gb .gbc .gba (Nintendo), .sms .gg .sg (Sega),
                      .cue .bin .iso .exe (PlayStation)
  --ui-scale N        interface scale, 1-8
  --frames N          run N frames as fast as possible, then exit
  --screenshot FILE   with --frames: write the final window to FILE (BMP)
  --dump-frame FILE   with --frames: write the console's native picture to FILE (BMP)
  --dump-audio FILE   with --frames: write the audio produced to FILE (WAV)
  --menu              with --frames: show the menu in the screenshot
  --open NAME         with --frames: open a menu window (load, input, video, ui, sound, paths, about, cheats)
`

parse_args :: proc(args: []string) -> (opts: Options, ok: bool) {
	for i := 0; i < len(args); i += 1 {
		a := args[i]
		next :: proc(args: []string, i: ^int) -> (string, bool) {
			if i^ + 1 >= len(args) {
				return "", false
			}
			i^ += 1
			return args[i^], true
		}
		switch a {
		case "-h", "--help":
			return opts, false
		case "--frames":
			v := next(args, &i) or_return
			opts.frames = strconv.parse_int(v) or_return
		case "--screenshot":
			opts.screenshot = next(args, &i) or_return
		case "--dump-frame":
			opts.dump_frame = next(args, &i) or_return
		case "--dump-audio":
			opts.dump_audio = next(args, &i) or_return
		case "--open":
			opts.open = next(args, &i) or_return
		case "--menu":
			opts.menu = true
		case "--ui-scale":
			v := next(args, &i) or_return
			opts.ui_scale = strconv.parse_int(v) or_return
		case:
			if strings.has_prefix(a, "-") {
				fmt.eprintfln("unknown option: %s", a)
				return opts, false
			}
			opts.rom = a
		}
	}
	return opts, true
}

main :: proc() {
	context.logger = log.create_console_logger(.Info when !ODIN_DEBUG else .Debug)
	defer log.destroy_console_logger(context.logger)

	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)
		defer {
			for _, leak in track.allocation_map {
				fmt.eprintfln("leak: %v bytes at %v", leak.size, leak.location)
			}
			for bad in track.bad_free_array {
				fmt.eprintfln("bad free at %v", bad.location)
			}
			mem.tracking_allocator_destroy(&track)
		}
	}

	opts, ok := parse_args(os.args[1:])
	if !ok {
		fmt.eprint(USAGE)
		os.exit(2)
	}

	app: App
	if !app_init(&app) {
		app_destroy(&app)
		os.exit(1)
	}
	defer app_destroy(&app)

	if opts.ui_scale > 0 {
		app.cfg.ui_scale = clamp(opts.ui_scale, 1, 8)
		app_apply_ui_config(&app)
	}
	if opts.rom != "" {
		app_load_game(&app, opts.rom)
	}

	if opts.frames > 0 {
		run_headless(&app, opts)
		return
	}
	for app.running {
		app_frame(&app)
	}
}

// Runs the emulator without real-time pacing; used for testing and to grab
// screenshots of the interface.
run_headless :: proc(app: ^App, opts: Options) {
	recorded := make([dynamic]i16)
	defer delete(recorded)
	for _ in 0 ..< opts.frames {
		if app.machine == nil {
			break
		}
		machine_run_frame(app.machine, read_input(&app.cfg, &app.pads), &app.audio.buffer)
		if opts.dump_audio != "" {
			append(&recorded, ..emu.audio_slice(&app.audio.buffer))
		}
		audio_submit(&app.audio, false, 0, true)
	}
	if opts.dump_audio != "" && app.machine != nil {
		rate := emu.SYSTEM_INFO[machine_kind(app.machine)].sample_rate
		if !write_wav(opts.dump_audio, recorded[:], rate) {
			log.errorf("could not write %s", opts.dump_audio)
		}
	}
	if app.machine != nil {
		video_upload(&app.video, app.renderer, machine_frame(app.machine, &app.cfg), app.cfg.smooth)
	}
	app.menu_active = opts.menu || app.machine == nil || opts.open != ""
	Named_Window :: struct {
		name:   string,
		window: ^gui.Window,
	}
	windows := [?]Named_Window {
		{"load", &app.win_load},
		{"input", &app.win_input},
		{"video", &app.win_video},
		{"ui", &app.win_ui},
		{"sound", &app.win_sound},
		{"paths", &app.win_paths},
		{"about", &app.win_about},
		{"cheats", &app.win_cheats},
	}
	for nw in windows {
		if nw.name != opts.open {
			continue
		}
		if nw.window == &app.win_load {
			ui_open_load(app, .Rom)
		} else {
			gui.open_window(&app.ui, nw.window)
		}
	}
	// A few frames so snow and layout settle.
	for _ in 0 ..< 3 {
		app_render(app, 1.0 / 60.0)
	}
	app.time += 1
	app_render(app, 1.0 / 60.0)
	if opts.screenshot != "" {
		app_render_to_file(app, opts.screenshot)
	}
	if opts.dump_frame != "" && app.machine != nil {
		save_frame_bmp(machine_frame(app.machine, &app.cfg), opts.dump_frame)
	}
}

app_render_to_file :: proc(app: ^App, path: string) {
	app_draw(app, 0)
	surface := sdl.RenderReadPixels(app.renderer, nil)
	if surface == nil {
		log.errorf("RenderReadPixels failed: %s", sdl.GetError())
		return
	}
	defer sdl.DestroySurface(surface)
	if !sdl.SaveBMP(surface, strings.clone_to_cstring(path, context.temp_allocator)) {
		log.errorf("SaveBMP failed: %s", sdl.GetError())
	}
}

// Writes interleaved stereo 16-bit samples as a WAV file.
write_wav :: proc(path: string, samples: []i16, rate: int) -> bool {
	data_bytes := len(samples) * 2
	header: [44]u8
	put32 :: proc(b: []u8, v: u32) {
		b[0] = u8(v)
		b[1] = u8(v >> 8)
		b[2] = u8(v >> 16)
		b[3] = u8(v >> 24)
	}
	put16 :: proc(b: []u8, v: u16) {
		b[0] = u8(v)
		b[1] = u8(v >> 8)
	}
	copy(header[0:], "RIFF")
	put32(header[4:], u32(36 + data_bytes))
	copy(header[8:], "WAVEfmt ")
	put32(header[16:], 16)
	put16(header[20:], 1) // PCM
	put16(header[22:], 2) // stereo
	put32(header[24:], u32(rate))
	put32(header[28:], u32(rate * 4))
	put16(header[32:], 4)
	put16(header[34:], 16)
	copy(header[36:], "data")
	put32(header[40:], u32(data_bytes))

	out := make([]u8, 44 + data_bytes)
	defer delete(out)
	copy(out, header[:])
	for s, i in samples {
		put16(out[44 + i * 2:], u16(s))
	}
	return os.write_entire_file(path, out) == nil
}
