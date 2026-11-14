package main

import "core:os"
import "core:testing"
import sdl "vendor:sdl3"

import "gui"

// Drives the real application with synthetic input, headlessly.

@(private = "file")
Harness :: struct {
	app: App,
	dir: string,
}

@(private = "file")
harness_start :: proc(t: ^testing.T, h: ^Harness) -> bool {
	_ = sdl.SetHint(sdl.HINT_VIDEO_DRIVER, "offscreen")
	_ = sdl.SetHint(sdl.HINT_AUDIO_DRIVER, "dummy")
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" {tmp = "/tmp"}
	h.dir, _ = os.join_path({tmp, "zemu-ui-test"}, context.allocator)
	os.make_directory_all(h.dir)
	if !app_init(&h.app, h.dir) {
		testing.fail_now(t, "app_init failed")
	}
	h.app.cfg.ui_scale = 2
	h.app.cfg.snow = false
	app_apply_ui_config(&h.app)
	step(h)
	return true
}

@(private = "file")
harness_stop :: proc(h: ^Harness) {
	app_destroy(&h.app)
	os.remove_all(h.dir)
	delete(h.dir)
}

@(private = "file")
step :: proc(h: ^Harness, frames := 1) {
	for _ in 0 ..< frames {
		app_frame(&h.app)
	}
}

// Clicks at a position given in UI pixels.
@(private = "file")
click :: proc(h: ^Harness, ui_x, ui_y: i32) {
	s := f32(h.app.ui.scale)
	x, y := f32(ui_x) * s + 1, f32(ui_y) * s + 1
	e: sdl.Event
	e.motion = {type = .MOUSE_MOTION, x = x, y = y}
	_ = sdl.PushEvent(&e)
	e = {}
	e.button = {type = .MOUSE_BUTTON_DOWN, button = sdl.BUTTON_LEFT, down = true, clicks = 1, x = x, y = y}
	_ = sdl.PushEvent(&e)
	step(h)
	e = {}
	e.button = {type = .MOUSE_BUTTON_UP, button = sdl.BUTTON_LEFT, x = x, y = y}
	_ = sdl.PushEvent(&e)
	step(h)
}

@(private = "file")
drag :: proc(h: ^Harness, from, to: [2]i32) {
	s := f32(h.app.ui.scale)
	e: sdl.Event
	e.button = {type = .MOUSE_BUTTON_DOWN, button = sdl.BUTTON_LEFT, down = true, clicks = 1, x = f32(from.x) * s + 1, y = f32(from.y) * s + 1}
	_ = sdl.PushEvent(&e)
	step(h)
	e = {}
	e.motion = {type = .MOUSE_MOTION, x = f32(to.x) * s + 1, y = f32(to.y) * s + 1}
	_ = sdl.PushEvent(&e)
	step(h)
	e = {}
	e.button = {type = .MOUSE_BUTTON_UP, button = sdl.BUTTON_LEFT, x = f32(to.x) * s + 1, y = f32(to.y) * s + 1}
	_ = sdl.PushEvent(&e)
	step(h)
}

@(private = "file")
key :: proc(h: ^Harness, sc: sdl.Scancode) {
	e: sdl.Event
	e.key = {type = .KEY_DOWN, scancode = sc, down = true}
	_ = sdl.PushEvent(&e)
	step(h)
	e = {}
	e.key = {type = .KEY_UP, scancode = sc}
	_ = sdl.PushEvent(&e)
	step(h)
}

@(test)
menus_open_windows_and_escape_closes_them :: proc(t: ^testing.T) {
	h: Harness
	if !harness_start(t, &h) {return}
	defer harness_stop(&h)
	app := &h.app

	click(&h, 20, 6) // "GAME"
	testing.expect(t, gui.menu_is_open(&app.ui), "GAME menu should open")
	click(&h, 20, 19) // first item: Load...
	testing.expect(t, app.win_load.open, "load window should open")
	testing.expect(t, !gui.menu_is_open(&app.ui), "menu closes after choosing")

	key(&h, .ESCAPE)
	testing.expect(t, !app.win_load.open, "Esc closes the focused window")

	// Keyboard navigation: open CONFIG, go down to PATHS (skipping the
	// separator) and confirm.
	click(&h, 60, 6)
	testing.expect(t, gui.menu_is_open(&app.ui), "CONFIG menu should open")
	for _ in 0 ..< 4 {key(&h, .DOWN)}
	key(&h, .RETURN)
	testing.expect(t, app.win_paths.open, "PATHS window opens from the keyboard")
}

@(test)
windows_drag_and_stay_put_when_the_window_resizes :: proc(t: ^testing.T) {
	h: Harness
	if !harness_start(t, &h) {return}
	defer harness_stop(&h)
	app := &h.app

	gui.open_window(&app.ui, &app.win_about)
	step(&h)
	r := app.win_about.rect
	drag(&h, {r.x + 20, r.y + 5}, {r.x + 60, r.y + 35})
	testing.expect_value(t, app.win_about.rect.x, r.x + 40)
	testing.expect_value(t, app.win_about.rect.y, r.y + 30)

	// Resizing the OS window must not rescale or move the interface.
	before := app.win_about.rect
	sdl.SetWindowSize(app.window, 1600, 900)
	step(&h, 3)
	testing.expect_value(t, app.win_about.rect, before)
	testing.expect_value(t, app.ui.scale, 2)
}

@(test)
ui_scale_and_theme_change_from_the_interface_window :: proc(t: ^testing.T) {
	h: Harness
	if !harness_start(t, &h) {return}
	defer harness_stop(&h)
	app := &h.app

	gui.open_window(&app.ui, &app.win_ui)
	step(&h)
	o := [2]i32{app.win_ui.rect.x + 4, app.win_ui.rect.y + gui.TITLE_H + 3}
	w := app.win_ui.rect.w - 8
	click(&h, o.x + w - 5, o.y + 5) // UI scale ">"
	testing.expect_value(t, app.cfg.ui_scale, 3)
	testing.expect_value(t, app.ui.scale, 3)

	o = [2]i32{app.win_ui.rect.x + 4, app.win_ui.rect.y + gui.TITLE_H + 3}
	w = app.win_ui.rect.w - 8
	click(&h, o.x + w - 5, o.y + 21) // theme ">"
	testing.expect_value(t, app.cfg.theme, 1)
}

@(test)
letterbox_never_stretches :: proc(t: ^testing.T) {
	cases := [?]struct {
		fw, fh: i32,
		par:    f32,
		ow, oh: i32,
	} {
		{256, 224, 8.0 / 7.0, 1920, 1080},
		{256, 224, 8.0 / 7.0, 1080, 1920},
		{320, 240, 1, 1000, 1000},
		{640, 480, 1, 300, 200},
	}
	for c in cases {
		for integer in ([2]bool{false, true}) {
			r := letterbox(c.fw, c.fh, c.par, c.ow, c.oh, integer)
			want := f32(c.fw) * c.par / f32(c.fh)
			got := r.w / r.h
			testing.expectf(t, abs(got - want) < 0.01, "aspect %v != %v", got, want)
			testing.expect(t, r.x >= 0 && r.y >= 0 && r.x + r.w <= f32(c.ow) + 0.5 && r.y + r.h <= f32(c.oh) + 0.5)
			testing.expect(t, r.w >= f32(c.ow) - 1 || r.h >= f32(c.oh) - 1 || integer, "fills one axis")
		}
	}
}

// A controller drives the menus: South opens the GAME menu, the d-pad moves,
// South chooses, East backs out.
@(test)
gamepad_navigates_the_menus :: proc(t: ^testing.T) {
	h: Harness
	if !harness_start(t, &h) {return}
	defer harness_stop(&h)
	app := &h.app

	testing.expect(t, app_gamepad_button(app, 0, .SOUTH), "South is used in the menu")
	step(&h)
	testing.expect(t, gui.menu_is_open(&app.ui), "South opens the GAME menu")
	app_gamepad_button(app, 0, .DPAD_DOWN) // first item: LOAD
	step(&h)
	app_gamepad_button(app, 0, .SOUTH)
	step(&h)
	testing.expect(t, app.win_load.open, "choosing LOAD opens the load window")
	app_gamepad_button(app, 0, .EAST)
	step(&h)
	testing.expect(t, !app.win_load.open, "East closes the window")
	testing.expect(t, !app_gamepad_button(&h.app, 0, .LEFT_SHOULDER), "unused buttons pass through")
}

// Gamepad bindings can be changed and survive a save and reload.
@(test)
gamepad_bindings_round_trip :: proc(t: ^testing.T) {
	cfg := config_defaults()
	defer config_destroy(&cfg)
	cfg.pad_map[1][.A] = Pad_Input(sdl.GamepadButton.NORTH)
	cfg.pad_map[0][.L2] = PAD_NONE
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" {tmp = "/tmp"}
	path, _ := os.join_path({tmp, "zemu-pad-test.cfg"}, context.temp_allocator)
	testing.expect(t, config_save(&cfg, path))
	defer os.remove(path)
	loaded := config_defaults()
	defer config_destroy(&loaded)
	config_load(&loaded, path)
	testing.expect_value(t, loaded.pad_map[1][.A], Pad_Input(sdl.GamepadButton.NORTH))
	testing.expect_value(t, loaded.pad_map[0][.L2], PAD_NONE)
	testing.expect_value(t, loaded.pad_map[0][.R2], PAD_RIGHT_TRIGGER)
	testing.expect_value(t, loaded.pad_map[0][.Start], Pad_Input(sdl.GamepadButton.START))
}
