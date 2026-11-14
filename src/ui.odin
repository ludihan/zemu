package main

import "core:fmt"
import "core:os"
import sdl "vendor:sdl3"

import "emu"
import "gui"

ui_init_windows :: proc(app: ^App) {
	ctx := &app.ui
	app.win_load    = {title = "LOAD GAME", rect = {20, 22, 330, 214}}
	app.win_input   = {title = "INPUT CONFIG", rect = {40, 30, 300, 178}}
	app.win_video   = {title = "VIDEO", rect = {60, 40, 236, 148}}
	app.win_ui      = {title = "INTERFACE", rect = {70, 50, 220, 108}}
	app.win_sound   = {title = "SOUND", rect = {80, 60, 200, 84}}
	app.win_paths   = {title = "PATHS", rect = {50, 70, 300, 110}}
	app.win_about   = {title = "ABOUT", rect = {90, 50, 250, 140}}
	app.win_message = {title = "MESSAGE", rect = {100, 80, 260, 84}}
	for w in ([]^gui.Window{&app.win_load, &app.win_input, &app.win_video, &app.win_ui, &app.win_sound, &app.win_paths, &app.win_about, &app.win_message}) {
		gui.add_window(ctx, w)
	}
}

ui_open_load :: proc(app: ^App, purpose: Browse_Purpose) {
	b := &app.browser
	if b.purpose != purpose || len(b.files) == 0 && len(b.dirs) == 0 {
		b.purpose = purpose
		start := purpose == .Psx_Bios && app.cfg.psx_bios != "" ? os.dir(app.cfg.psx_bios) : app.cfg.rom_dir
		browser_open(b, start)
	}
	app.win_load.title = purpose == .Rom ? "LOAD GAME" : "SELECT PLAYSTATION BIOS"
	gui.open_window(&app.ui, &app.win_load)
	app.menu_active = true
}

ui_finish_rebind :: proc(app: ^App, sc: sdl.Scancode) {
	btn, ok := app.rebinding.?
	if !ok {
		return
	}
	#partial switch sc {
	case .ESCAPE:
		// cancel
	case .BACKSPACE, .DELETE:
		app.cfg.keys[app.input_pad][btn] = .UNKNOWN
	case:
		app.cfg.keys[app.input_pad][btn] = sc
	}
	app.rebinding = nil
}

// --- menu bar --------------------------------------------------------------

Menu_Id :: enum {
	Game,
	Config,
	Misc,
}

ui_draw_menu_bar :: proc(app: ^App) {
	has_game := app.machine != nil

	game_items := make([dynamic]gui.Menu_Item, context.temp_allocator)
	append(&game_items,
		gui.Menu_Item{label = "Load...", shortcut = "Ctrl+O"},
		gui.Menu_Item{label = "Run", shortcut = "Esc", disabled = !has_game},
		gui.Menu_Item{label = "Reset", shortcut = "Ctrl+R", disabled = !has_game},
		gui.Menu_Item{label = "Close game", disabled = !has_game},
		gui.Menu_Item{separator = true},
		gui.Menu_Item{label = fmt.tprintf("Save state %d", app.state_slot), shortcut = "F2", disabled = !has_game},
		gui.Menu_Item{label = fmt.tprintf("Load state %d", app.state_slot), shortcut = "F4", disabled = !has_game},
		gui.Menu_Item{label = "Next slot", shortcut = "F3"},
		gui.Menu_Item{separator = true},
	)
	recent_start := len(game_items)
	for r, i in app.cfg.recent {
		append(&game_items, gui.Menu_Item{label = fmt.tprintf("%d %s", i + 1, os.base(r))})
	}
	if len(app.cfg.recent) == 0 {
		append(&game_items, gui.Menu_Item{label = "(no recent games)", disabled = true})
	}
	append(&game_items, gui.Menu_Item{separator = true})
	quit_index := len(game_items)
	append(&game_items, gui.Menu_Item{label = "Quit"})

	config_items := []gui.Menu_Item {
		{label = "Input..."},
		{label = "Video..."},
		{label = "Sound..."},
		{label = "Paths..."},
		{label = "Interface..."},
	}
	misc_items := []gui.Menu_Item {
		{label = "Show FPS", checked = app.cfg.show_fps},
		{label = "Screenshot", shortcut = "F12", disabled = !has_game},
		{label = "Fullscreen", shortcut = "Alt+Enter", checked = app.cfg.fullscreen},
		{separator = true},
		{label = "About..."},
	}
	menus := []gui.Menu {
		{title = "GAME", items = game_items[:]},
		{title = "CONFIG", items = config_items},
		{title = "MISC", items = misc_items},
	}

	status := "ZEMU " + APP_VERSION
	if has_game {
		region := machine_fps(app.machine) < 55 ? " PAL" : ""
		status = fmt.tprintf("%s%s  ZEMU %s", emu.SYSTEM_INFO[machine_kind(app.machine)].short_name, region, APP_VERSION)
	}
	m, item := gui.menu_bar(&app.ui, menus, status)
	if m < 0 {
		return
	}
	switch Menu_Id(m) {
	case .Game:
		switch {
		case item == 0: ui_open_load(app, .Rom)
		case item == 1: app.menu_active = false
		case item == 2:
			app_reset_game(app)
			app.menu_active = false
		case item == 3: app_close_game(app)
		case item == 5: app_save_state(app)
		case item == 6: app_load_state(app)
		case item == 7: app_next_slot(app)
		case item == quit_index: app.running = false
		case item >= recent_start && item < recent_start + len(app.cfg.recent):
			path := fmt.tprintf("%s", app.cfg.recent[item - recent_start])
			app_load_game(app, path)
		}
	case .Config:
		windows := [?]^gui.Window{&app.win_input, &app.win_video, &app.win_sound, &app.win_paths, &app.win_ui}
		if item >= 0 && item < len(windows) {
			gui.open_window(&app.ui, windows[item])
		}
	case .Misc:
		switch item {
		case 0: app.cfg.show_fps = !app.cfg.show_fps
		case 1: app_screenshot(app)
		case 2: app_toggle_fullscreen(app)
		case 4: gui.open_window(&app.ui, &app.win_about)
		}
	}
}

// --- windows ---------------------------------------------------------------

ui_draw_windows :: proc(app: ^App) {
	ctx := &app.ui
	for w in gui.window_order(ctx) {
		if !gui.begin_window(ctx, w) {
			continue
		}
		switch w {
		case &app.win_load:    draw_load_window(app)
		case &app.win_input:   draw_input_window(app)
		case &app.win_video:   draw_video_window(app)
		case &app.win_ui:      draw_interface_window(app)
		case &app.win_sound:   draw_sound_window(app)
		case &app.win_paths:   draw_paths_window(app)
		case &app.win_about:   draw_about_window(app)
		case &app.win_message: draw_message_window(app)
		}
		gui.end_window(ctx)
	}
}

@(private = "file")
client_size :: proc(w: ^gui.Window) -> [2]i32 {
	return {w.rect.w - 8, w.rect.h - gui.TITLE_H - 7}
}

@(private = "file")
draw_load_window :: proc(app: ^App) {
	ctx := &app.ui
	b := &app.browser
	size := client_size(&app.win_load)
	dir_w: i32 = 104
	file_w := size.x - dir_w - 4
	list_h := size.y - 48

	if gui.has_keyboard(ctx) {
		for k in gui.keys(ctx) {
			#partial switch k.scancode {
			case .TAB:       b.focus_dirs = !b.focus_dirs
			case .BACKSPACE:
				b.dir_list.selected = 0
				if len(b.dirs) > 0 && b.dirs[0].text == ".." {
					browser_enter_dir(b)
					return
				}
			}
		}
	}

	gui.label(ctx, 0, 0, b.purpose == .Rom ? "FILENAME" : "BIOS IMAGE", b.focus_dirs ? nil : ctx.theme.text_hot)
	gui.label(ctx, file_w + 4, 0, "DIRECTORY", b.focus_dirs ? ctx.theme.text_hot : nil)

	res := gui.list_box(ctx, &b.file_list, {0, 10, file_w, list_h}, b.files[:], !b.focus_dirs)
	if gui.clicked(ctx, gui.to_screen(ctx, {0, 10, file_w, list_h})) {
		b.focus_dirs = false
	}
	dres := gui.list_box(ctx, &b.dir_list, {file_w + 4, 10, dir_w, list_h}, b.dirs[:], b.focus_dirs)
	if gui.clicked(ctx, gui.to_screen(ctx, {file_w + 4, 10, dir_w, list_h})) {
		b.focus_dirs = true
	}
	if dres.activated {
		browser_enter_dir(b)
		return
	}

	y := 12 + list_h
	gui.text_box(ctx, {0, y, size.x, 11}, b.error != "" ? b.error : b.dir)
	y += 15
	if gui.checkbox(ctx, 0, y + 2, "Show all files", &b.show_all) {
		browser_refresh(b)
		return
	}
	choose := res.activated
	if gui.button(ctx, {size.x - 112, y, 54, 14}, b.purpose == .Rom ? "LOAD" : "SELECT", len(b.files) > 0) {
		choose = true
	}
	if gui.button(ctx, {size.x - 54, y, 54, 14}, "CANCEL") {
		app.win_load.open = false
	}
	if choose {
		if path, ok := browser_selected_file(b); ok {
			switch b.purpose {
			case .Rom:
				app_load_game(app, path)
			case .Psx_Bios:
				set_string(&app.cfg.psx_bios, path)
				app.win_load.open = false
				b.purpose = .Rom
				browser_open(b, app.cfg.rom_dir)
			}
		}
	}
}

@(private = "file")
draw_input_window :: proc(app: ^App) {
	ctx := &app.ui
	size := client_size(&app.win_input)
	gui.label(ctx, 0, 2, "PLAYER")
	if d := gui.stepper(ctx, {44, 0, 70, 11}, fmt.tprintf("%d", app.input_pad + 1)); d != 0 {
		app.input_pad = clamp(app.input_pad + d, 0, emu.MAX_PADS - 1)
		app.rebinding = nil
	}
	pad_name := "Keyboard only"
	if p := app.pads.pads[app.input_pad]; p != nil {
		if n := sdl.GetGamepadName(p); n != nil {
			pad_name = fmt.tprintf("Pad: %s", n)
		}
	}
	gui.text_box(ctx, {120, 0, size.x - 120, 11}, pad_name)

	keys := &app.cfg.keys[app.input_pad]
	col_w := (size.x - 6) / 2
	i: i32 = 0
	for name, btn in BUTTON_NAMES {
		col := i / 7
		row := i % 7
		x := col * (col_w + 6)
		y := 18 + row * 15
		gui.label(ctx, x, y + 2, name)
		waiting := app.rebinding == btn
		if gui.binding(ctx, {x + 42, y, col_w - 42, 12}, scancode_name(keys[btn]), waiting) {
			app.rebinding = btn
		}
		i += 1
	}
	y: i32 = 18 + 7 * 15 + 2
	gui.label_dim(ctx, 0, y, "Click a field, then press a key.")
	gui.label_dim(ctx, 0, y + 10, "Del clears, Esc cancels. Pads map automatically.")
	if gui.button(ctx, {size.x - 64, y + 22, 64, 14}, "DEFAULTS") {
		app.cfg.keys[app.input_pad] = app.input_pad == 0 ? DEFAULT_KEYS_P1 : DEFAULT_KEYS_P2
		app.rebinding = nil
	}
	if !app.win_input.open {
		app.rebinding = nil
	}
}

@(private = "file")
draw_video_window :: proc(app: ^App) {
	ctx := &app.ui
	cfg := &app.cfg
	size := client_size(&app.win_video)
	gui.label(ctx, 0, 2, "ASPECT")
	if d := gui.stepper(ctx, {60, 0, size.x - 60, 11}, ASPECT_NAMES[cfg.aspect]); d != 0 {
		n := len(Aspect_Mode)
		cfg.aspect = Aspect_Mode((int(cfg.aspect) + d + n) % n)
	}
	y: i32 = 18
	gui.checkbox(ctx, 0, y, "Integer scaling", &cfg.integer_scale)
	y += 13
	if gui.checkbox(ctx, 0, y, "Smooth (bilinear) filter", &cfg.smooth) && app.video.texture != nil {
		sdl.SetTextureScaleMode(app.video.texture, cfg.smooth ? .LINEAR : .NEAREST)
	}
	y += 13
	gui.checkbox(ctx, 0, y, "Hide NES overscan", &cfg.crop_overscan)
	y += 13
	if gui.checkbox(ctx, 0, y, "VSync", &cfg.vsync) {
		sdl.SetRenderVSync(app.renderer, cfg.vsync ? 1 : 0)
	}
	y += 13
	full := cfg.fullscreen
	if gui.checkbox(ctx, 0, y, "Fullscreen", &full) {
		app_toggle_fullscreen(app)
	}
	y += 13
	gui.checkbox(ctx, 0, y, "Show FPS", &cfg.show_fps)
	y += 15
	gui.label_dim(ctx, 0, y, "Games are always letterboxed, never")
	gui.label_dim(ctx, 0, y + 10, "stretched to fill the window.")
}

@(private = "file")
draw_interface_window :: proc(app: ^App) {
	ctx := &app.ui
	cfg := &app.cfg
	size := client_size(&app.win_ui)
	gui.label(ctx, 0, 2, "UI SCALE")
	if d := gui.stepper(ctx, {66, 0, size.x - 66, 11}, fmt.tprintf("%dx", cfg.ui_scale)); d != 0 {
		cfg.ui_scale = clamp(cfg.ui_scale + d, 1, 8)
		app_apply_ui_config(app)
	}
	gui.label(ctx, 0, 18, "THEME")
	if d := gui.stepper(ctx, {66, 16, size.x - 66, 11}, gui.THEMES[cfg.theme].name); d != 0 {
		n := len(gui.THEMES)
		cfg.theme = (cfg.theme + d + n) % n
		app_apply_ui_config(app)
	}
	gui.checkbox(ctx, 0, 34, "Falling snow background", &cfg.snow)
	gui.label_dim(ctx, 0, 50, "The menu keeps its size when the")
	gui.label_dim(ctx, 0, 60, "window is resized. Drag windows")
	gui.label_dim(ctx, 0, 70, "by their title bars.")
}

@(private = "file")
draw_sound_window :: proc(app: ^App) {
	ctx := &app.ui
	cfg := &app.cfg
	size := client_size(&app.win_sound)
	gui.checkbox(ctx, 0, 0, "Enable sound", &cfg.audio)
	gui.label(ctx, 0, 18, "VOLUME")
	gui.slider(ctx, {48, 16, size.x - 80, 12}, &cfg.volume, 0, 100)
	gui.label(ctx, size.x - 26, 18, fmt.tprintf("%3d", cfg.volume))
	rate := app.audio.sample_rate
	gui.label_dim(ctx, 0, 36, rate > 0 ? fmt.tprintf("Core output: %d Hz", rate) : "No game running")
}

@(private = "file")
draw_paths_window :: proc(app: ^App) {
	ctx := &app.ui
	size := client_size(&app.win_paths)
	gui.label(ctx, 0, 0, "PLAYSTATION BIOS (SCPH-xxxx.BIN)")
	gui.text_box(ctx, {0, 10, size.x, 11}, app.cfg.psx_bios != "" ? app.cfg.psx_bios : "(not set)")
	if gui.button(ctx, {size.x - 112, 24, 54, 14}, "BROWSE") {
		ui_open_load(app, .Psx_Bios)
	}
	if gui.button(ctx, {size.x - 54, 24, 54, 14}, "CLEAR") {
		set_string(&app.cfg.psx_bios, "")
	}
	gui.label(ctx, 0, 44, "SAVE DATA")
	saves, _ := os.join_path({app.data_dir, "saves"}, context.temp_allocator)
	gui.text_box(ctx, {0, 54, size.x, 11}, saves)
}

@(private = "file")
draw_about_window :: proc(app: ^App) {
	ctx := &app.ui
	gui.label(ctx, 0, 0, "ZEMU " + APP_VERSION, ctx.theme.text_hot)
	gui.label(ctx, 0, 12, "A multi-system emulator written in Odin.")
	gui.label_dim(ctx, 0, 26, "Systems: NES, SNES, Game Boy, PlayStation")
	gui.label_dim(ctx, 0, 36, "Licensed under the GNU AGPL v3.")
	gui.label(ctx, 0, 52, "Esc    menu / back to game")
	gui.label(ctx, 0, 62, "Tab    fast forward (hold)")
	gui.label(ctx, 0, 72, "P      pause      F12 screenshot")
	gui.label(ctx, 0, 82, "F2/F4  save/load state  F3 slot")
	gui.label(ctx, 0, 92, "Alt+Enter fullscreen")
	if gui.button(ctx, {app.win_about.rect.w - 8 - 50, 104, 50, 14}, "OK") {
		app.win_about.open = false
	}
}

@(private = "file")
draw_message_window :: proc(app: ^App) {
	ctx := &app.ui
	size := client_size(&app.win_message)
	msg := string(app.message[:app.message_len])
	y: i32 = 2
	for line in split_lines(msg) {
		gui.label(ctx, 0, y, line)
		y += 10
	}
	if gui.button(ctx, {(size.x - 50) / 2, size.y - 15, 50, 14}, "OK") || gui.has_keyboard(ctx) && gui.key_pressed(ctx, .RETURN) {
		app.win_message.open = false
	}
}

@(private = "file")
split_lines :: proc(s: string) -> []string {
	lines := make([dynamic]string, context.temp_allocator)
	start := 0
	for i in 0 ..< len(s) {
		if s[i] == '\n' {
			append(&lines, s[start:i])
			start = i + 1
		}
	}
	append(&lines, s[start:])
	return lines[:]
}

// --- splash and overlay ----------------------------------------------------

ui_draw_splash :: proc(app: ^App) {
	ctx := &app.ui
	t := &ctx.theme
	logo := "ZEMU"
	big: i32 = 6
	w := gui.text_width(logo) * big
	x := (ctx.size.x - w) / 2
	y := ctx.size.y / 2 - 50
	gui.text_scaled(ctx, x + 3, y + 3, logo, big, t.text_shadow)
	gui.text_scaled(ctx, x, y, logo, big, t.title_top)
	gui.text_scaled(ctx, x, y, logo, big, {t.text.r, t.text.g, t.text.b, 120})

	lines := [?]string{"MULTI-SYSTEM EMULATOR", "", "NES  -  SNES  -  GAME BOY  -  PLAYSTATION", "", "GAME > LOAD (Ctrl+O) or drop a file here"}
	ly := y + gui.CELL_H * big + 10
	for l, i in lines {
		lw := gui.text_width(l)
		gui.text_shadowed(ctx, (ctx.size.x - lw) / 2, ly, l, i == 0 ? t.text_hot : t.text_dim)
		ly += 10
	}
}

ui_draw_overlay :: proc(app: ^App) {
	ctx := &app.ui
	t := &ctx.theme
	if app.osd.len > 0 && app.time < app.osd.until {
		s := string(app.osd.buf[:app.osd.len])
		gui.text(ctx, 5, ctx.size.y - 12, s, {0, 0, 0, 255})
		gui.text(ctx, 4, ctx.size.y - 13, s, {255, 255, 255, 255})
	}
	if app.cfg.show_fps && app.machine != nil && !app.menu_active {
		s := fmt.tprintf("%.1f FPS", app.fps)
		x := ctx.size.x - gui.text_width(s) - 4
		gui.text(ctx, x + 1, 5, s, {0, 0, 0, 255})
		gui.text(ctx, x, 4, s, {255, 255, 80, 255})
	}
	if app.paused && !app.menu_active {
		s := "PAUSED"
		x := (ctx.size.x - gui.text_width(s)) / 2
		gui.text(ctx, x + 1, 5, s, {0, 0, 0, 255})
		gui.text(ctx, x, 4, s, t.text_hot)
	}
}
