package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/rand"
import "core:os"
import "core:strings"
import sdl "vendor:sdl3"

import "emu"
import "gui"

APP_NAME    :: "zemu"
APP_VERSION :: "0.1.0"

MAX_FLAKES :: 220

Flake :: struct {
	x, y, speed, drift: f32,
}

Osd :: struct {
	buf:   [128]u8,
	len:   int,
	until: f64,
}

App :: struct {
	window:      ^sdl.Window,
	renderer:    ^sdl.Renderer,
	ui:          gui.Context,
	cfg:         Config,
	cfg_path:    string,
	data_dir:    string,
	video:       Video,
	audio:       Audio,
	pads:        Gamepads,

	machine:     Machine,
	rom_path:    string,
	bios:        []u8,
	state_slot:  int,

	running:     bool,
	menu_active: bool,
	paused:      bool,
	fast_forward: bool,
	rewinding:   bool,
	rewind:      Rewind,
	time:        f64,
	frame_acc:   f64,
	last_ticks:  u64,
	fps:         f64,
	fps_frames:  int,
	fps_time:    f64,

	osd:         Osd,
	flakes:      [MAX_FLAKES]Flake,

	// windows
	win_load:    gui.Window,
	win_input:   gui.Window,
	win_video:   gui.Window,
	win_ui:      gui.Window,
	win_sound:   gui.Window,
	win_paths:   gui.Window,
	win_about:   gui.Window,
	win_message: gui.Window,
	win_cheats:  gui.Window,
	cheats:      Cheat_List,
	cheat_list:  gui.List_State,
	cheat_code_field: gui.Text_Field,
	cheat_name_field: gui.Text_Field,
	cheat_error: string,
	browser:     Browser,
	message:     [256]u8,
	message_len: int,
	input_pad:   int,
	rebinding:   Maybe(emu.Button),
}

// `data_dir` overrides where config, saves and screenshots live (tests use a
// temporary directory); by default SDL's per-user preference path is used.
app_init :: proc(app: ^App, data_dir := "") -> bool {
	_ = sdl.SetAppMetadata(APP_NAME, APP_VERSION, "org.zemu.zemu")
	if !sdl.Init({.VIDEO, .AUDIO, .GAMEPAD}) {
		log.errorf("SDL_Init failed: %s", sdl.GetError())
		return false
	}

	if data_dir != "" {
		app.data_dir = strings.clone(data_dir)
	} else if pref := sdl.GetPrefPath("zemu", "zemu"); pref != nil {
		app.data_dir = strings.clone(string(cstring(pref)))
		sdl.free(pref)
	} else {
		app.data_dir = strings.clone(".")
	}
	app.cfg_path, _ = os.join_path({app.data_dir, "zemu.cfg"}, context.allocator)
	for sub in ([]string{"saves", "screenshots"}) {
		p, _ := os.join_path({app.data_dir, sub}, context.temp_allocator)
		os.make_directory_all(p)
	}

	app.cfg = config_defaults()
	config_load(&app.cfg, app.cfg_path)

	flags: sdl.WindowFlags = {.RESIZABLE, .HIGH_PIXEL_DENSITY}
	if app.cfg.fullscreen {
		flags += {.FULLSCREEN}
	}
	app.window = sdl.CreateWindow("zemu", 1280, 720, flags)
	if app.window == nil {
		log.errorf("SDL_CreateWindow failed: %s", sdl.GetError())
		return false
	}
	sdl.SetWindowMinimumSize(app.window, 320, 240)
	app.renderer = sdl.CreateRenderer(app.window, nil)
	if app.renderer == nil {
		log.errorf("SDL_CreateRenderer failed: %s", sdl.GetError())
		return false
	}
	sdl.SetRenderVSync(app.renderer, app.cfg.vsync ? 1 : 0)

	if !gui.init(&app.ui, app.renderer) {
		log.errorf("failed to create font texture: %s", sdl.GetError())
		return false
	}
	app_apply_ui_config(app)
	_ = sdl.StartTextInput(app.window)

	ui_init_windows(app)
	browser_open(&app.browser, app.cfg.rom_dir)

	for &f in app.flakes {
		f = new_flake(true)
	}

	app.running = true
	app.menu_active = true
	app.last_ticks = sdl.GetTicksNS()
	return true
}

app_destroy :: proc(app: ^App) {
	app_close_game(app)
	config_save(&app.cfg, app.cfg_path)
	config_destroy(&app.cfg)
	browser_destroy(&app.browser)
	delete(app.bios)
	video_destroy(&app.video)
	audio_close(&app.audio)
	gamepads_close(&app.pads)
	gui.destroy(&app.ui)
	if app.renderer != nil {sdl.DestroyRenderer(app.renderer)}
	if app.window != nil {sdl.DestroyWindow(app.window)}
	delete(app.cfg_path)
	delete(app.data_dir)
	sdl.Quit()
}

app_apply_ui_config :: proc(app: ^App) {
	app.ui.scale = i32(clamp(app.cfg.ui_scale, 1, 8))
	app.cfg.theme = clamp(app.cfg.theme, 0, len(gui.THEMES) - 1)
	app.ui.theme = gui.THEMES[app.cfg.theme]
}

// --- messages --------------------------------------------------------------

osd_show :: proc(app: ^App, format: string, args: ..any) {
	s := fmt.bprintf(app.osd.buf[:], format, ..args)
	app.osd.len = len(s)
	app.osd.until = app.time + 2.5
}

show_message :: proc(app: ^App, format: string, args: ..any) {
	s := fmt.bprintf(app.message[:], format, ..args)
	app.message_len = len(s)
	gui.center_window(&app.ui, &app.win_message)
	gui.open_window(&app.ui, &app.win_message)
	app.menu_active = true
}

// --- game lifetime ---------------------------------------------------------

save_path :: proc(app: ^App, rom: string, ext: string) -> string {
	name := fmt.tprintf("%s%s", os.stem(rom), ext)
	p, _ := os.join_path({app.data_dir, "saves", name}, context.temp_allocator)
	return p
}

// Battery RAM for cartridges, memory card images for the PlayStation.
@(private = "file")
save_extension :: proc(kind: emu.System_Kind) -> string {
	return kind == .PSX ? ".mcr" : ".srm"
}

@(private = "file")
write_save_ram :: proc(app: ^App) {
	if app.machine == nil || app.rom_path == "" {
		return
	}
	data := machine_save_ram(app.machine)
	if len(data) == 0 {
		return
	}
	path := save_path(app, app.rom_path, save_extension(machine_kind(app.machine)))
	if err := os.write_entire_file(path, data); err != nil {
		log.warnf("could not write %s: %v", path, err)
	}
}

cheat_path :: proc(app: ^App) -> string {
	return save_path(app, app.rom_path, ".cht")
}

app_close_game :: proc(app: ^App) {
	if app.machine == nil {
		return
	}
	write_save_ram(app)
	cheats_save(&app.cheats, cheat_path(app))
	app.cheats = {}
	rewind_reset(&app.rewind)
	machine_destroy(&app.machine)
	delete(app.rom_path)
	app.rom_path = ""
	app.video.has_frame = false
	audio_close(&app.audio)
	sdl.SetWindowTitle(app.window, "zemu")
}

@(private = "file")
load_bios :: proc(app: ^App, kind: emu.System_Kind, path: string) -> ([]u8, emu.Load_Error) {
	if !emu.SYSTEM_INFO[kind].needs_bios {
		return nil, .None
	}
	delete(app.bios)
	app.bios = nil
	if app.cfg.psx_bios == "" {
		// Homebrew executables can run without a BIOS; discs cannot.
		ext := strings.to_lower(os.ext(path), context.temp_allocator)
		if ext == ".exe" || ext == ".psx" {
			return nil, .None
		}
		return nil, .Missing_Bios
	}
	data, err := os.read_entire_file(app.cfg.psx_bios, context.allocator)
	if err != nil {
		return nil, .Missing_Bios
	}
	app.bios = data
	return data, .None
}

app_load_game :: proc(app: ^App, path: string) -> bool {
	kind, ok := system_for_path(path)
	if !ok {
		show_message(app, "Unknown file type:\n%s", os.base(path))
		return false
	}
	if !os.exists(path) {
		show_message(app, "File not found:\n%s", os.base(path))
		return false
	}
	bios, bios_err := load_bios(app, kind, path)
	if bios_err != .None {
		show_message(app, "%s", emu.LOAD_ERROR_TEXT[bios_err])
		return false
	}

	m, err := machine_create(kind, path, bios)
	if err != .None {
		show_message(app, "%s:\n%s", emu.LOAD_ERROR_TEXT[err], os.base(path))
		return false
	}

	app_close_game(app)
	app.machine = m
	app.rom_path = strings.clone(path)

	if sram, sram_err := os.read_entire_file(save_path(app, path, save_extension(kind)), context.temp_allocator); sram_err == nil {
		machine_load_save_ram(app.machine, sram)
	}

	cheats_load(&app.cheats, kind, cheat_path(app))
	cheats_sync(app.machine, &app.cheats)
	rewind_reset(&app.rewind)
	// PlayStation states are large; snapshot them less often.
	app.rewind.interval = kind == .PSX ? 4 : 2

	info := emu.SYSTEM_INFO[kind]
	if !audio_open(&app.audio, info.sample_rate) {
		log.warnf("audio unavailable: %s", sdl.GetError())
	}
	config_add_recent(&app.cfg, path)
	set_string(&app.cfg.rom_dir, os.dir(path))
	title := fmt.ctprintf("zemu - %s [%s]", os.stem(path), info.short_name)
	sdl.SetWindowTitle(app.window, title)

	app.paused = false
	app.menu_active = false
	app.frame_acc = 0
	app.win_load.open = false
	osd_show(app, "%s loaded (%s%s)", os.stem(path), info.short_name, machine_fps(app.machine) < 55 ? " PAL" : "")
	return true
}

@(private = "file")
state_path :: proc(app: ^App) -> string {
	return save_path(app, app.rom_path, fmt.tprintf(".st%d", app.state_slot))
}

app_save_state :: proc(app: ^App) {
	if app.machine == nil {
		return
	}
	data := machine_save_state(app.machine)
	defer delete(data)
	if data == nil || os.write_entire_file(state_path(app), data) != nil {
		osd_show(app, "Could not save state %d", app.state_slot)
		return
	}
	osd_show(app, "State %d saved", app.state_slot)
}

app_load_state :: proc(app: ^App) {
	if app.machine == nil {
		return
	}
	data, err := os.read_entire_file(state_path(app), context.allocator)
	if err != nil {
		osd_show(app, "State %d is empty", app.state_slot)
		return
	}
	defer delete(data)
	if !machine_load_state(app.machine, data) {
		osd_show(app, "State %d is from another game or version", app.state_slot)
		return
	}
	cheats_sync(app.machine, &app.cheats) // states carry the patch list they were saved with
	app.menu_active = false
	osd_show(app, "State %d loaded", app.state_slot)
}

app_next_slot :: proc(app: ^App) {
	app.state_slot = (app.state_slot + 1) % 10
	osd_show(app, "State slot %d", app.state_slot)
}

app_reset_game :: proc(app: ^App) {
	if app.machine != nil {
		machine_reset(app.machine)
		osd_show(app, "Reset")
	}
}

app_toggle_fullscreen :: proc(app: ^App) {
	app.cfg.fullscreen = !app.cfg.fullscreen
	sdl.SetWindowFullscreen(app.window, app.cfg.fullscreen)
}

// Writes a core frame to a BMP file at its native resolution.
save_frame_bmp :: proc(f: emu.Frame, path: string) -> bool {
	if !emu.frame_is_valid(f) {
		return false
	}
	surface := sdl.CreateSurfaceFrom(i32(f.width), i32(f.height), .XRGB8888, raw_data(f.pixels), i32(f.pitch * 4))
	if surface == nil {
		return false
	}
	defer sdl.DestroySurface(surface)
	return sdl.SaveBMP(surface, strings.clone_to_cstring(path, context.temp_allocator))
}

app_screenshot :: proc(app: ^App) {
	if app.machine == nil {
		return
	}
	name := fmt.tprintf("%s-%d.bmp", os.stem(app.rom_path), sdl.GetTicks())
	path, _ := os.join_path({app.data_dir, "screenshots", name}, context.temp_allocator)
	if save_frame_bmp(machine_frame(app.machine, &app.cfg), path) {
		osd_show(app, "Saved %s", name)
	}
}

// --- events ----------------------------------------------------------------

@(private = "file")
handle_hotkey :: proc(app: ^App, k: sdl.KeyboardEvent) -> bool {
	alt := k.mod & sdl.KMOD_ALT != {}
	ctrl := k.mod & sdl.KMOD_CTRL != {}
	#partial switch k.scancode {
	case .RETURN:
		if alt {
			app_toggle_fullscreen(app)
			return true
		}
	case .F11:
		app_toggle_fullscreen(app)
		return true
	case .F2:
		app_save_state(app)
		return true
	case .F3:
		app_next_slot(app)
		return true
	case .F4:
		app_load_state(app)
		return true
	case .F12:
		app_screenshot(app)
		return true
	case .O:
		if ctrl {
			ui_open_load(app, .Rom)
			return true
		}
	case .R:
		if ctrl {
			app_reset_game(app)
			return true
		}
	case .P:
		if !app.menu_active && app.machine != nil {
			app.paused = !app.paused
			osd_show(app, app.paused ? "Paused" : "Resumed")
			return true
		}
	case .ESCAPE:
		if app.rebinding != nil {
			return false // let the input window cancel the rebind
		}
		if gui.menu_is_open(&app.ui) {
			gui.menu_close(&app.ui)
			return true
		}
		if app.menu_active {
			if w := gui.focused_window(&app.ui); w != nil {
				w.open = false
			} else if app.machine != nil {
				app.menu_active = false
			}
		} else {
			app.menu_active = true
		}
		return true
	}
	return false
}

app_handle_events :: proc(app: ^App) {
	e: sdl.Event
	for sdl.PollEvent(&e) {
		#partial switch e.type {
		case .QUIT:
			app.running = false
			continue
		case .GAMEPAD_ADDED:
			gamepad_added(&app.pads, e.gdevice.which)
		case .GAMEPAD_REMOVED:
			gamepad_removed(&app.pads, e.gdevice.which)
		case .KEY_DOWN:
			if app.menu_active && app.ui.text_focus != nil {
				gui.handle_event(&app.ui, &e) // typing into a text field
				continue
			}
			if app.rebinding != nil {
				ui_finish_rebind(app, e.key.scancode)
				continue
			}
			if !e.key.repeat && handle_hotkey(app, e.key) {
				continue
			}
			if e.key.scancode == .TAB && !app.menu_active {
				app.fast_forward = true
			}
			if e.key.scancode == .BACKSPACE && !app.menu_active && app.cfg.rewind {
				app.rewinding = true
			}
		case .KEY_UP:
			#partial switch e.key.scancode {
			case .TAB:       app.fast_forward = false
			case .BACKSPACE: app.rewinding = false
			}
		case .WINDOW_FOCUS_LOST:
			app.fast_forward = false
			app.rewinding = false
		case .DROP_FILE:
			if e.drop.data != nil {
				app_load_game(app, strings.clone_from_cstring(e.drop.data, context.temp_allocator))
			}
		}
		if app.menu_active {
			gui.handle_event(&app.ui, &e)
		}
	}
}

// --- emulation -------------------------------------------------------------

app_emulate :: proc(app: ^App, dt: f64) {
	if app.machine == nil || app.menu_active || app.paused {
		app.frame_acc = 0
		return
	}
	period := 1.0 / machine_fps(app.machine)
	input := read_input(&app.cfg, &app.pads)

	frames := 0
	if app.fast_forward {
		frames = 4
		app.frame_acc = 0
	} else {
		app.frame_acc += dt
		// After a stall (window drag, breakpoint) don't try to catch up for seconds.
		app.frame_acc = min(app.frame_acc, period * 4)
		for app.frame_acc >= period && frames < 3 {
			app.frame_acc -= period
			frames += 1
		}
	}

	if app.rewinding {
		// Step back one snapshot per frame period (with snapshots every few
		// frames this plays history backwards a little faster than real time).
		for _ in 0 ..< frames {
			if !rewind_step(&app.rewind, app.machine) {
				break
			}
		}
		emu.audio_clear(&app.audio.buffer)
		if frames > 0 {
			video_upload(&app.video, app.renderer, machine_frame(app.machine, &app.cfg), app.cfg.smooth)
		}
		return
	}
	for _ in 0 ..< frames {
		cheats_apply(app.machine, &app.cheats)
		machine_run_frame(app.machine, input, &app.audio.buffer)
		audio_submit(&app.audio, app.cfg.audio, app.cfg.volume, app.fast_forward)
		if app.cfg.rewind {
			rewind_capture(&app.rewind, app.machine)
		}
		app.fps_frames += 1
	}
	if frames > 0 {
		video_upload(&app.video, app.renderer, machine_frame(app.machine, &app.cfg), app.cfg.smooth)
	}
}

// --- rendering -------------------------------------------------------------

@(private = "file")
new_flake :: proc(anywhere: bool) -> Flake {
	return {
		x     = rand.float32() * 4000,
		y     = anywhere ? rand.float32() * 2000 : -rand.float32() * 40,
		speed = 8 + rand.float32() * 26,
		drift = rand.float32() * 2 - 1,
	}
}

@(private = "file")
draw_snow :: proc(app: ^App, dt: f64) {
	ctx := &app.ui
	c := ctx.theme.snow
	for &f in app.flakes {
		f.y += f.speed * f32(dt)
		f.x += (f.drift + math.sin(f32(app.time) * 0.7 + f.speed)) * f32(dt) * 6
		if f.y > f32(ctx.size.y) {
			f = new_flake(false)
		}
		x := i32(f.x) % max(ctx.size.x, 1)
		alpha := u8(clamp(90 + f.speed * 5, 0, 255))
		gui.fill_rect(ctx, {x, i32(f.y), 1, 1}, {c.r, c.g, c.b, alpha})
	}
}

@(private = "file")
game_rect :: proc(app: ^App, out_w, out_h: i32) -> sdl.FRect {
	v := &app.video
	native := machine_pixel_aspect(app.machine, machine_frame(app.machine, &app.cfg))
	par := pixel_aspect_for(app.cfg.aspect, native, v.frame_w, v.frame_h)
	return letterbox(v.frame_w, v.frame_h, par, out_w, out_h, app.cfg.integer_scale)
}

app_render :: proc(app: ^App, dt: f64) {
	app_draw(app, dt)
	sdl.RenderPresent(app.renderer)
}

// Draws the whole window without presenting it.
app_draw :: proc(app: ^App, dt: f64) {
	r := app.renderer
	sdl.SetRenderScale(r, 1, 1)
	sdl.SetRenderDrawColor(r, 0, 0, 0, 255)
	sdl.RenderClear(r)

	out_w, out_h: i32
	sdl.GetRenderOutputSize(r, &out_w, &out_h)
	has_game := app.machine != nil && app.video.has_frame

	if app.menu_active {
		t := &app.ui.theme
		gui.gradient_rect(&app.ui, {0, 0, out_w, out_h}, t.desktop_top, t.desktop_bottom)
		if has_game {
			dst := game_rect(app, out_w, out_h)
			sdl.SetRenderDrawColor(r, 0, 0, 0, 255)
			sdl.RenderFillRect(r, &dst)
			video_draw(&app.video, r, dst, 110)
		}
	} else if has_game {
		video_draw(&app.video, r, game_rect(app, out_w, out_h))
	}

	ctx := &app.ui
	gui.begin(ctx, out_w, out_h, app.time)
	if app.menu_active {
		if app.cfg.snow {
			draw_snow(app, dt)
		}
		if !has_game && !gui.any_window_open(ctx) {
			ui_draw_splash(app)
		}
		ui_draw_windows(app)
		ui_draw_menu_bar(app)
	}
	ui_draw_overlay(app)
	gui.end(ctx)
}

app_frame :: proc(app: ^App) {
	now := sdl.GetTicksNS()
	dt := f64(now - app.last_ticks) / 1e9
	app.last_ticks = now
	app.time += dt

	app_handle_events(app)
	app_emulate(app, dt)
	app_render(app, dt)

	app.fps_time += dt
	if app.fps_time >= 1 {
		app.fps = f64(app.fps_frames) / app.fps_time
		app.fps_frames = 0
		app.fps_time = 0
	}
	if !app.cfg.vsync {
		sdl.DelayNS(1_000_000) // don't spin a core at 100% without vsync
	}
	free_all(context.temp_allocator)
}
