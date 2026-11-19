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
	app.gui_open = true

	gui_init()
	cores_scan()

	// zemu [core] [content]
	args := argv[:argc]
	if len(args) >= 2 && core_load(string(args[1])) {
		ok := core_load_game(string(args[2])) if len(args) >= 3 else core_start_no_game()
		if ok do app.gui_open = false
	}
	gui_update_cursor()
	return .CONTINUE
}

// The desktop GUI draws its own ZSNES-style cursor; the system one is hidden
// while the GUI is up, and always while a game runs.
gui_update_cursor :: proc() {
	if ui.kind == .Desktop && app.gui_open {
		_ = sdl.HideCursor()
		_ = sdl.StartTextInput(app.window) // for type-to-jump in lists
	} else {
		if ui.kind == .Desktop do _ = sdl.HideCursor()
		else do _ = sdl.ShowCursor()
		_ = sdl.StopTextInput(app.window)
	}
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
	if !core.game_loaded do app.gui_open = true
	video_draw(game_area(f32(w), f32(h)), app.gui_open)
	gui_frame()
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
	if frame == 2 {
		// ZEMU_DEBUG_DIALOG=<Dialog index> / ZEMU_DEBUG_MENU=<menu index>
		if d := sdl.getenv("ZEMU_DEBUG_DIALOG"); d != nil do dialog_open(Dialog(sdl.atoi(d)))
		if m := sdl.getenv("ZEMU_DEBUG_MENU"); m != nil do menu_open(int(sdl.atoi(m)))
		ui.mouse_seen = true
		ui.mx, ui.my = ui.cv.w / 2 + 20, ui.cv.h / 2 + 30
	}
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
		if !app.gui_open || !(event.key.scancode == .ESCAPE || event.key.scancode == .AC_BACK) {
			hotkey(event.key.scancode, event.key.mod, event.key.repeat)
		}
	case .KEY_UP:
		if event.key.scancode == .GRAVE do timing.fast_forward = timing.ff_toggle
	case .GAMEPAD_BUTTON_DOWN:
		// Guide (or Back+Start) opens the GUI from a controller.
		btn := sdl.GamepadButton(event.gbutton.button)
		if !app.gui_open && core.game_loaded {
			g := sdl.GetGamepadFromID(event.gbutton.which)
			if btn == .GUIDE || (g != nil && sdl.GetGamepadButton(g, .BACK) && sdl.GetGamepadButton(g, .START)) {
				gui_toggle()
				return .CONTINUE
			}
		}
	case .WILL_ENTER_BACKGROUND, .WINDOW_FOCUS_LOST:
		sram_save()
		if event.type == .WILL_ENTER_BACKGROUND && core.game_loaded && !app.gui_open do gui_toggle()
	}
	if app.gui_open || ui.kind == .Touch do gui_event(event)
	return .CONTINUE
}

// Where the game is drawn. The touch UI reserves room for the on-screen pad.
game_area :: proc(w, h: f32) -> sdl.FRect {
	if ui.kind == .Touch do return touch_game_area(w, h)
	return {0, 0, w, h}
}

hotkey :: proc(sc: sdl.Scancode, mod: sdl.Keymod, repeat: bool) {
	if repeat do return
	#partial switch sc {
	case .ESCAPE, .AC_BACK:
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
	if app.gui_open {
		sram_save()
		ui.menu = -1
	}
	audio_pause(app.gui_open)
	gui_update_cursor()
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
