package zemu

import "base:runtime"
import "core:c"
import "core:fmt"
import sdl "vendor:sdl3"

APP_NAME    :: "ZEMU"
APP_VERSION :: "0.1"

App :: struct {
	window:   ^sdl.Window,
	renderer: ^sdl.Renderer,
	running:  bool,
	gui_open: bool, // GUI shown and emulation paused
	paused:   bool,
}

app: App
app_ctx: runtime.Context

app_init :: proc "c" (appstate: ^rawptr, argc: c.int, argv: [^]cstring) -> sdl.AppResult {
	context = app_ctx
	_ = sdl.SetAppMetadata(APP_NAME, APP_VERSION, "dev.zemu.libretro")
	_ = sdl.SetHint(sdl.HINT_RENDER_VSYNC, "1")
	if !sdl.Init({.VIDEO, .AUDIO, .GAMEPAD}) {
		fmt.eprintln("SDL_Init failed:", sdl.GetError())
		return .FAILURE
	}
	paths_init()
	settings_load()

	flags: sdl.WindowFlags = {.RESIZABLE, .HIGH_PIXEL_DENSITY}
	if settings.fullscreen do flags += {.FULLSCREEN}
	if !sdl.CreateWindowAndRenderer(APP_NAME, 256 * 3, 224 * 3, flags, &app.window, &app.renderer) {
		fmt.eprintln("CreateWindowAndRenderer failed:", sdl.GetError())
		return .FAILURE
	}
	_ = sdl.SetRenderVSync(app.renderer, 1 if settings.vsync else 0)
	app.running = true

	// zemu [core] [content]
	args := argv[:argc]
	if len(args) >= 2 && core_load(string(args[1])) {
		if len(args) >= 3 {
			_ = core_load_game(string(args[2]))
		} else {
			_ = core_start_no_game()
		}
	}
	return .CONTINUE
}

emulation_active :: proc() -> bool {
	return core_loaded && core.game_loaded && !app.gui_open && !app.paused
}

app_iterate :: proc "c" (appstate: rawptr) -> sdl.AppResult {
	context = app_ctx
	defer free_all(context.temp_allocator)
	if !app.running do return .SUCCESS

	if emulation_active() {
		n := timing_frames_due()
		for _ in 0 ..< n {
			core_run_frame()
			timing.fps_frames += 1
		}
		audio_update_rate()
		if core.shutdown_requested {
			core_unload_game()
			app.gui_open = true
		}
	} else {
		timing_reset()
	}

	_ = sdl.SetRenderDrawColor(app.renderer, 0, 0, 0, 255)
	_ = sdl.RenderClear(app.renderer)
	w, h: c.int
	_ = sdl.GetRenderOutputSize(app.renderer, &w, &h)
	video_draw({0, 0, f32(w), f32(h)}, app.gui_open)
	if debug_screenshot() do return .SUCCESS
	_ = sdl.RenderPresent(app.renderer)
	return .CONTINUE
}

// ZEMU_SCREENSHOT=out.bmp saves the frame after ZEMU_SCREENSHOT_FRAMES
// (default 30) iterations and quits. Used to check rendering headless.
debug_screenshot :: proc() -> bool {
	@(static) frame: int
	path := sdl.getenv("ZEMU_SCREENSHOT")
	if path == nil do return false
	frame += 1
	want := 30
	if n := sdl.getenv("ZEMU_SCREENSHOT_FRAMES"); n != nil do want = int(sdl.atoi(n))
	if frame < want do return false
	if surf := sdl.RenderReadPixels(app.renderer, nil); surf != nil {
		_ = sdl.SaveBMP(surf, path)
		sdl.DestroySurface(surf)
	}
	return true
}

app_event :: proc "c" (appstate: rawptr, event: ^sdl.Event) -> sdl.AppResult {
	context = app_ctx
	#partial switch event.type {
	case .QUIT:
		return .SUCCESS
	case .GAMEPAD_ADDED:
		input_gamepad_added(event.gdevice.which)
	case .GAMEPAD_REMOVED:
		input_gamepad_removed(event.gdevice.which)
	case .KEY_DOWN:
		hotkey(event.key.scancode, event.key.mod, event.key.repeat)
	case .KEY_UP:
		if event.key.scancode == .GRAVE do timing.fast_forward = timing.ff_toggle
	case .WILL_ENTER_BACKGROUND, .WINDOW_FOCUS_LOST:
		sram_save()
	}
	return .CONTINUE
}

hotkey :: proc(sc: sdl.Scancode, mod: sdl.Keymod, repeat: bool) {
	if repeat do return
	#partial switch sc {
	case .ESCAPE:
		if core.game_loaded do gui_toggle()
	case .F2:  if emulation_active() do _ = state_save(state_slot)
	case .F4:  if emulation_active() do _ = state_load(state_slot)
	case .F3:
		state_slot = (state_slot + 1) % 10
		osd_message(fmt.tprintf("STATE SLOT %d", state_slot))
	case .GRAVE:
		timing.fast_forward = true // hold
	case .F9:
		timing.ff_toggle = !timing.ff_toggle
		timing.fast_forward = timing.ff_toggle
	case .P:
		if core.game_loaded do app.paused = !app.paused
	case .RETURN:
		if .LALT in mod || .RALT in mod do toggle_fullscreen()
	case .F11:
		toggle_fullscreen()
	}
}

gui_toggle :: proc() {
	app.gui_open = !app.gui_open
	audio_pause(app.gui_open)
}

toggle_fullscreen :: proc() {
	settings.fullscreen = !settings.fullscreen
	_ = sdl.SetWindowFullscreen(app.window, settings.fullscreen)
}

app_quit :: proc "c" (appstate: rawptr, result: sdl.AppResult) {
	context = app_ctx
	core_options_save()
	core_unload()
	settings_save()
	sdl.Quit()
}
