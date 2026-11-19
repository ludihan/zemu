package zemu

// The GUI: a ZSNES-style interface drawn into a low resolution software
// canvas. The canvas grows with the window (keeping whole-pixel scaling), so
// bigger windows get more room instead of just bigger pixels.

import "core:c"
import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:strings"
import sdl "vendor:sdl3"

GUI_BASE_W :: 256
GUI_BASE_H :: 224

UI_Kind :: enum u8 {
	Desktop, // mouse + keyboard, ZSNES menus and windows
	Touch,   // phones/tablets: full-screen pages, big targets, on-screen pad
}

Dialog :: enum u8 {
	None,
	Load,
	Pick_State,
	Input,
	Video,
	Sound,
	Core_Options,
	Cores,
	Cheat_Add,
	Cheat_Browse,
	Netplay,
	Gui_Opts,
	About,
	Message,
}

Flake :: struct {
	x, y, speed, phase: f32,
	bright: u8,
}

SNOW_COUNT :: 200

UI :: struct {
	kind: UI_Kind,
	cv:   Canvas,
	tex:  ^sdl.Texture,
	tex_w, tex_h: int,
	scale: int,
	dst:   sdl.FRect, // where the canvas lands, in render pixels
	pixel_density: f32,

	// Input for this frame, in canvas coordinates.
	mx, my:          int,
	mouse_down:      bool,
	mouse_pressed:   bool,
	mouse_released:  bool,
	press_x, press_y: int,
	wheel:           int,
	mouse_seen:      bool,
	keys:            [dynamic]sdl.Keycode,
	text:            strings.Builder,
	input_blocked:   bool, // a menu is open over the dialog

	// Menus
	menu:      int, // open menu index, -1 when closed
	menu_item: int,
	menu_rects: [MENU_COUNT]Rect,

	// Dialog window
	dialog:      Dialog,
	dialog_rect: Rect,
	dragging:    bool,
	drag_dx, drag_dy: int,
	message:     string,
	message_title: string,

	// Widgets
	focus:        int, // id of the focused text field, 0 = none
	id_counter:   int,
	scroll_drag:  int, // id of the scrollbar being dragged
	slider_drag:  int,
	last_click_ns: u64,
	last_click_item: int,

	frame: int,
	snow:  [SNOW_COUNT]Flake,
}

ui: UI

Theme :: struct {
	base:         Color,
	win_top:      Color,
	win_bottom:   Color,
	title_top:    Color,
	title_bottom: Color,
	light:        Color,
	dark:         Color,
	border:       Color,
	text:         Color,
	text_dim:     Color,
	text_hi:      Color,
	text_shadow:  Color,
	list_bg:      Color,
	select:       Color,
	button:       Color,
	button_hi:    Color,
}

theme: Theme

theme_update :: proc() {
	g := settings.gui_color
	base := rgb(int(g[0]), int(g[1]), int(g[2]))
	theme.base         = base
	theme.win_top      = lighten(base, 10)
	theme.win_bottom   = shade(base, 0.35)
	theme.title_top    = lighten(base, 70)
	theme.title_bottom = lighten(base, 10)
	theme.light        = lighten(base, 100)
	theme.dark         = shade(base, 0.25)
	theme.border       = rgb(0, 0, 0)
	theme.text         = rgb(232, 232, 232)
	theme.text_dim     = mix(rgb(150, 150, 150), base, 0.3)
	theme.text_hi      = rgb(255, 240, 120)
	theme.text_shadow  = shade(base, 0.15)
	theme.list_bg      = shade(base, 0.2)
	theme.select       = lighten(base, 50)
	theme.button       = lighten(base, 25)
	theme.button_hi    = lighten(base, 55)
}

gui_init :: proc() {
	font_init()
	ui.menu = -1
	ui.text = strings.builder_make()
	ui.kind = gui_pick_kind()
	for &f in ui.snow do snow_respawn(&f, true)
}

// Touch UI on phones, desktop UI elsewhere, unless the user overrides it.
gui_pick_kind :: proc() -> UI_Kind {
	switch settings.ui_override {
	case .Desktop: return .Desktop
	case .Touch:   return .Touch
	case .Auto:
	}
	when IS_MOBILE {
		return .Touch
	} else {
		return .Desktop
	}
}

// --- Events -------------------------------------------------------------------

gui_event :: proc(e: ^sdl.Event) {
	#partial switch e.type {
	case .MOUSE_MOTION:
		ui.mouse_seen = true
		ui.mx, ui.my = window_to_canvas(e.motion.x, e.motion.y)
	case .MOUSE_BUTTON_DOWN:
		ui.mx, ui.my = window_to_canvas(e.button.x, e.button.y)
		if e.button.button == sdl.BUTTON_LEFT {
			ui.mouse_down = true
			ui.mouse_pressed = true
			ui.press_x, ui.press_y = ui.mx, ui.my
		} else if e.button.button == sdl.BUTTON_RIGHT {
			// Right click backs out, like ZSNES.
			append(&ui.keys, sdl.K_ESCAPE)
		}
	case .MOUSE_BUTTON_UP:
		ui.mx, ui.my = window_to_canvas(e.button.x, e.button.y)
		if e.button.button == sdl.BUTTON_LEFT {
			ui.mouse_down = false
			ui.mouse_released = true
		}
	case .MOUSE_WHEEL:
		ui.wheel += int(-e.wheel.y)
	case .KEY_DOWN:
		append(&ui.keys, e.key.key)
	case .TEXT_INPUT:
		strings.write_string(&ui.text, string(e.text.text))
	case .GAMEPAD_BUTTON_DOWN:
		// Drive the GUI with a gamepad.
		#partial switch sdl.GamepadButton(e.gbutton.button) {
		case .DPAD_UP:    append(&ui.keys, sdl.K_UP)
		case .DPAD_DOWN:  append(&ui.keys, sdl.K_DOWN)
		case .DPAD_LEFT:  append(&ui.keys, sdl.K_LEFT)
		case .DPAD_RIGHT: append(&ui.keys, sdl.K_RIGHT)
		case .SOUTH:      append(&ui.keys, sdl.K_RETURN)
		case .EAST:       append(&ui.keys, sdl.K_ESCAPE)
		case .LEFT_SHOULDER:  append(&ui.keys, sdl.K_PAGEUP)
		case .RIGHT_SHOULDER: append(&ui.keys, sdl.K_PAGEDOWN)
		}
	}
	if ui.kind == .Touch do touch_event(e)
}

window_to_canvas :: proc(wx, wy: f32) -> (int, int) {
	// Window coordinates -> render pixels -> canvas pixels.
	px := wx * ui.pixel_density
	py := wy * ui.pixel_density
	if ui.scale <= 0 do return 0, 0
	return int(math.floor((px - ui.dst.x) / f32(ui.scale))), int(math.floor((py - ui.dst.y) / f32(ui.scale)))
}

key_pressed :: proc(k: sdl.Keycode) -> bool {
	if ui.input_blocked do return false
	for kk in ui.keys do if kk == k do return true
	return false
}

consume_key :: proc(k: sdl.Keycode) -> bool {
	for kk, i in ui.keys {
		if kk == k {
			ordered_remove(&ui.keys, i)
			return true
		}
	}
	return false
}

// --- Frame --------------------------------------------------------------------

// Size the canvas to the window: the largest whole scale that keeps at least
// 256x224 logical pixels, then fill the rest of the window with extra canvas.
gui_layout :: proc() {
	ow, oh: c.int
	_ = sdl.GetRenderOutputSize(app.renderer, &ow, &oh)
	ui.pixel_density = sdl.GetWindowPixelDensity(app.window)
	if ui.pixel_density <= 0 do ui.pixel_density = 1

	if ui.kind == .Touch {
		touch_layout(int(ow), int(oh))
	} else {
		s := max(1, min(int(ow) / GUI_BASE_W, int(oh) / GUI_BASE_H))
		ui.scale = s
		canvas_resize(&ui.cv, max(1, int(ow) / s), max(1, int(oh) / s))
	}
	ui.dst = {
		f32(int(ow) - ui.cv.w * ui.scale) / 2,
		f32(int(oh) - ui.cv.h * ui.scale) / 2,
		f32(ui.cv.w * ui.scale),
		f32(ui.cv.h * ui.scale),
	}
}

// Draw the GUI (or the in-game overlay) and present it over the game.
gui_frame :: proc() {
	theme_update()
	gui_layout()
	ui.frame += 1
	ui.id_counter = 0

	if ui.kind == .Touch {
		touch_frame()
	} else if app.gui_open {
		desktop_frame()
	} else {
		canvas_clear(&ui.cv, Color(0))
		draw_osd()
	}

	gui_upload()
	_ = sdl.RenderTexture(app.renderer, ui.tex, nil, &ui.dst)

	// Reset per-frame input.
	ui.mouse_pressed = false
	ui.mouse_released = false
	ui.wheel = 0
	clear(&ui.keys)
	strings.builder_reset(&ui.text)
}

gui_upload :: proc() {
	if ui.tex == nil || ui.tex_w != ui.cv.w || ui.tex_h != ui.cv.h {
		if ui.tex != nil do sdl.DestroyTexture(ui.tex)
		ui.tex = sdl.CreateTexture(app.renderer, .ARGB8888, .STREAMING, c.int(ui.cv.w), c.int(ui.cv.h))
		_ = sdl.SetTextureBlendMode(ui.tex, {.BLEND})
		_ = sdl.SetTextureScaleMode(ui.tex, .NEAREST)
		ui.tex_w, ui.tex_h = ui.cv.w, ui.cv.h
	}
	_ = sdl.UpdateTexture(ui.tex, nil, raw_data(ui.cv.pix), c.int(ui.cv.w * 4))
}

desktop_frame :: proc() {
	cv := &ui.cv
	if core.game_loaded {
		// The paused game shows through, dimmed by video_draw.
		canvas_clear(cv, rgba(0, 0, 0, 60))
	} else {
		draw_background(cv)
	}
	if settings.snow do draw_snow(cv)
	if !core.game_loaded do draw_logo(cv)

	desktop_keyboard()

	// Menus take the mouse when open, so dialogs underneath ignore it.
	menubar_layout()
	ui.input_blocked = ui.menu >= 0
	if ui.dialog != .None do dialog_frame(cv)
	ui.input_blocked = false
	draw_menubar(cv)
	if ui.menu >= 0 do draw_menu(cv)

	if ui.mouse_seen do draw_cursor(cv, ui.mx, ui.my)
}

// Keys that work anywhere in the desktop GUI.
desktop_keyboard :: proc() {
	if consume_key(sdl.K_ESCAPE) {
		if ui.menu >= 0 {
			ui.menu = -1
		} else if ui.dialog != .None {
			dialog_close()
		} else if core.game_loaded {
			gui_toggle()
		}
	}
	if ui.menu >= 0 {
		if consume_key(sdl.K_LEFT)  do menu_open((ui.menu + MENU_COUNT - 1) % MENU_COUNT)
		if consume_key(sdl.K_RIGHT) do menu_open((ui.menu + 1) % MENU_COUNT)
		items := menu_items(ui.menu)
		if consume_key(sdl.K_UP)   do ui.menu_item = menu_step(items, ui.menu_item, -1)
		if consume_key(sdl.K_DOWN) do ui.menu_item = menu_step(items, ui.menu_item, 1)
		if consume_key(sdl.K_RETURN) {
			if ui.menu_item >= 0 && ui.menu_item < len(items) && items[ui.menu_item].enabled {
				it := items[ui.menu_item]
				ui.menu = -1
				menu_action(it.action, it.arg)
			}
		}
	} else if ui.dialog == .None {
		// Nothing open: the arrows/enter bring up the menu bar.
		for k in ([]sdl.Keycode{sdl.K_DOWN, sdl.K_UP, sdl.K_LEFT, sdl.K_RIGHT, sdl.K_RETURN}) {
			if consume_key(k) {
				menu_open(0)
				break
			}
		}
	}
}

// --- Background, logo, snow, cursor ---------------------------------------------

draw_background :: proc(cv: ^Canvas) {
	vgradient(cv, {0, 0, cv.w, cv.h}, shade(theme.base, 0.3), rgb(0, 0, 8))
}

draw_logo :: proc(cv: ^Canvas) {
	LOGO :: "ZEMU"
	s := max(3, min(cv.w / 50, cv.h / 36))
	w := (len(LOGO) * CHAR_W - 1) * s
	x := (cv.w - w) / 2
	y := cv.h / 2 - 3 * s
	// Drop shadow, dark outline, then a vertical gradient face.
	draw_text_plain(cv, x + s, y + s, LOGO, rgba(0, 0, 0, 160), s)
	for dy in -1 ..= 1 do for dx in -1 ..= 1 {
		if dx != 0 || dy != 0 do draw_text_plain(cv, x + dx, y + dy, LOGO, theme.dark, s)
	}
	top := rgb(255, 255, 255)
	bot := theme.title_top
	for row in 0 ..< GLYPH_H * s {
		set_clip(cv, {0, y + row, cv.w, 1})
		draw_text_plain(cv, x, y, LOGO, mix(top, bot, f32(row) / f32(GLYPH_H * s)), s)
	}
	reset_clip(cv)

	sub := "LIBRETRO FRONTEND"
	draw_text(cv, (cv.w - text_width(sub)) / 2, y + GLYPH_H * s + 6, sub, theme.text)
	ver := fmt.tprintf("V%s", APP_VERSION)
	draw_text(cv, cv.w - text_width(ver) - 4, cv.h - LINE_H - 2, ver, theme.text_dim)
	hint := "NO CORES INSTALLED - SEE CORES MENU" if len(installed_cores) == 0 else "GAME - LOAD TO START"
	draw_text(cv, (cv.w - text_width(hint)) / 2, cv.h - LINE_H * 3, hint, theme.text_dim)
}

snow_respawn :: proc(f: ^Flake, anywhere: bool) {
	w := f32(max(ui.cv.w, GUI_BASE_W))
	h := f32(max(ui.cv.h, GUI_BASE_H))
	f.x = rand.float32() * w
	f.y = rand.float32() * h if anywhere else -2
	f.speed = 0.25 + rand.float32() * 0.75
	f.phase = rand.float32() * math.TAU
	f.bright = u8(140 + rand.int31_max(115))
}

draw_snow :: proc(cv: ^Canvas) {
	for &f in ui.snow {
		f.y += f.speed
		f.phase += 0.03
		x := f.x + math.sin(f.phase) * 1.5
		if f.y > f32(cv.h) || x < -2 || x > f32(cv.w) + 2 do snow_respawn(&f, false)
		b := int(f.bright)
		put_pixel(cv, int(x), int(f.y), rgb(b, b, b))
	}
}

CURSOR := []string{
	"#",
	"##",
	"#+#",
	"#++#",
	"#+++#",
	"#++++#",
	"#+++++#",
	"#++++++#",
	"#+++####",
	"#+#+#",
	"##.#+#",
	"#...#+#",
	".....##",
}

draw_cursor :: proc(cv: ^Canvas, x, y: int) {
	draw_sprite(cv, x, y, CURSOR, rgb(0, 0, 0), rgb(220, 230, 255))
}

// --- In-game overlay: messages and FPS ---------------------------------------

draw_osd :: proc() {
	cv := &ui.cv
	if msg, ok := osd_current(); ok {
		draw_text(cv, 4, cv.h - LINE_H - 2, msg, rgb(255, 255, 255), rgb(0, 0, 0))
	}
	if settings.show_fps && emulation_active() {
		s := fmt.tprintf("%.0f", timing.fps)
		draw_text(cv, cv.w - text_width(s) - 4, 3, s, rgb(255, 255, 255), rgb(0, 0, 0))
	}
	if app.paused {
		draw_text(cv, (cv.w - text_width("PAUSED")) / 2, cv.h / 2, "PAUSED", rgb(255, 255, 255), rgb(0, 0, 0))
	}
}

// --- Menu bar -------------------------------------------------------------------

Menu_Action :: enum u8 {
	None,
	Open_Dialog,
	Run,
	Reset,
	Save_State,
	Load_State,
	Quit,
	Recent,
	Save_Config,
	Close_Game,
}

Menu_Item :: struct {
	label:   string,
	key:     string, // shortcut shown on the right
	action:  Menu_Action,
	arg:     int,
	enabled: bool,
	sep:     bool, // separator line instead of an item
}

MENU_COUNT :: 6
MENU_NAMES := [MENU_COUNT]string{"GAME", "CONFIG", "CORES", "CHEAT", "NETPLAY", "MISC"}
MENUBAR_H :: 10

menu_items :: proc(m: int) -> []Menu_Item {
	items := make([dynamic]Menu_Item, context.temp_allocator)
	game := core.game_loaded
	add :: proc(items: ^[dynamic]Menu_Item, label: string, action: Menu_Action, arg := 0, enabled := true, key := "") {
		append(items, Menu_Item{label = label, action = action, arg = arg, enabled = enabled, key = key})
	}
	sep :: proc(items: ^[dynamic]Menu_Item) {
		append(items, Menu_Item{sep = true})
	}
	switch m {
	case 0: // GAME
		add(&items, "LOAD", .Open_Dialog, int(Dialog.Load))
		add(&items, "RUN", .Run, 0, game, "ESC")
		add(&items, "RESET", .Reset, 0, game)
		add(&items, "CLOSE", .Close_Game, 0, game)
		sep(&items)
		add(&items, "SAVE STATE", .Save_State, 0, game, "F2")
		add(&items, "LOAD STATE", .Load_State, 0, game, "F4")
		add(&items, "PICK STATE", .Open_Dialog, int(Dialog.Pick_State), game, "F3")
		sep(&items)
		add(&items, "QUIT", .Quit)
		if len(settings.recent) > 0 {
			sep(&items)
			for r, i in settings.recent {
				_, game_path := split_recent(r)
				add(&items, fmt.tprintf("%d %s", (i + 1) % 10, stem(game_path)), .Recent, i)
			}
		}
	case 1: // CONFIG
		add(&items, "INPUT", .Open_Dialog, int(Dialog.Input))
		sep(&items)
		add(&items, "VIDEO", .Open_Dialog, int(Dialog.Video))
		add(&items, "SOUND", .Open_Dialog, int(Dialog.Sound))
		sep(&items)
		add(&items, "CORE OPTIONS", .Open_Dialog, int(Dialog.Core_Options), core_loaded && len(core.options) > 0)
	case 2: // CORES
		add(&items, "BROWSE / DOWNLOAD", .Open_Dialog, int(Dialog.Cores))
	case 3: // CHEAT
		add(&items, "ADD CODE", .Open_Dialog, int(Dialog.Cheat_Add), game)
		add(&items, "BROWSE", .Open_Dialog, int(Dialog.Cheat_Browse), game)
	case 4: // NETPLAY
		add(&items, "INTERNET", .Open_Dialog, int(Dialog.Netplay))
	case 5: // MISC
		add(&items, "GUI OPTS", .Open_Dialog, int(Dialog.Gui_Opts))
		add(&items, "SAVE CFG", .Save_Config)
		add(&items, "ABOUT", .Open_Dialog, int(Dialog.About))
	}
	return items[:]
}

split_recent :: proc(r: string) -> (core_path, game_path: string) {
	i := strings.index_byte(r, '|')
	if i < 0 do return "", r
	return r[:i], r[i + 1:]
}

menu_step :: proc(items: []Menu_Item, cur, dir: int) -> int {
	n := len(items)
	if n == 0 do return -1
	i := cur
	for _ in 0 ..< n {
		i = (i + dir + n) % n
		if !items[i].sep do return i
	}
	return cur
}

menu_open :: proc(m: int) {
	ui.menu = m
	ui.menu_item = menu_step(menu_items(m), -1, 1)
}

menubar_layout :: proc() {
	x := 3
	for name, i in MENU_NAMES {
		w := text_width(name) + 6
		ui.menu_rects[i] = {x, 0, w, MENUBAR_H}
		x += w
	}
}

menu_box_rect :: proc(m: int, items: []Menu_Item) -> Rect {
	w := 0
	for it in items {
		iw := text_width(it.label) + 16
		if it.key != "" do iw += text_width(it.key) + 12
		w = max(w, iw)
	}
	h := 4
	for it in items do h += 3 if it.sep else LINE_H + 1
	r := Rect{ui.menu_rects[m].x, MENUBAR_H, w, h}
	if r.x + r.w > ui.cv.w do r.x = max(0, ui.cv.w - r.w)
	return r
}

draw_menubar :: proc(cv: ^Canvas) {
	bar := Rect{0, 0, cv.w, MENUBAR_H}
	vgradient(cv, bar, theme.title_top, theme.title_bottom)
	hline(cv, 0, MENUBAR_H - 1, cv.w, theme.dark)

	mouse_on_bar := rect_contains(bar, ui.mx, ui.my)
	for name, i in MENU_NAMES {
		r := ui.menu_rects[i]
		hover := rect_contains(r, ui.mx, ui.my)
		if hover && ui.mouse_pressed {
			if ui.menu == i do ui.menu = -1
			else do menu_open(i)
		} else if hover && ui.menu >= 0 && ui.menu != i {
			menu_open(i) // slide between menus while one is open
		}
		if ui.menu == i {
			fill_rect(cv, {r.x, r.y + 1, r.w, r.h - 2}, theme.select)
			bevel(cv, {r.x, r.y + 1, r.w, r.h - 2}, theme.dark, theme.light)
		}
		draw_text(cv, r.x + 3, 2, name, theme.text)
	}

	// Clicking outside an open menu closes it.
	if ui.menu >= 0 && ui.mouse_pressed && !mouse_on_bar {
		box := menu_box_rect(ui.menu, menu_items(ui.menu))
		if !rect_contains(box, ui.mx, ui.my) do ui.menu = -1
	}
}

draw_menu :: proc(cv: ^Canvas) {
	items := menu_items(ui.menu)
	box := menu_box_rect(ui.menu, items)
	fill_rect(cv, {box.x + 2, box.y + 2, box.w, box.h}, rgba(0, 0, 0, 90)) // shadow
	vgradient(cv, box, theme.win_top, theme.win_bottom)
	rect_outline(cv, box, theme.border)
	bevel(cv, rect_inset(box, 1), theme.light, theme.dark)

	y := box.y + 2
	for it, i in items {
		if it.sep {
			hline(cv, box.x + 3, y + 1, box.w - 6, theme.dark)
			hline(cv, box.x + 3, y + 2, box.w - 6, theme.light)
			y += 3
			continue
		}
		r := Rect{box.x + 2, y, box.w - 4, LINE_H + 1}
		hover := rect_contains(r, ui.mx, ui.my)
		if hover && (ui.mouse_pressed || ui.mx != ui.press_x || ui.my != ui.press_y) do ui.menu_item = i
		if ui.menu_item == i && it.enabled do fill_rect(cv, r, theme.select)
		col := theme.text if it.enabled else theme.text_dim
		draw_text(cv, r.x + 5, y + 2, it.label, col)
		if it.key != "" do draw_text(cv, r.x + r.w - text_width(it.key) - 4, y + 2, it.key, theme.text_dim)
		if hover && ui.mouse_released && it.enabled && rect_contains(box, ui.press_x, ui.press_y) {
			ui.menu = -1
			menu_action(it.action, it.arg)
			return
		}
		y += LINE_H + 1
	}
	// A press on the bar that opened the menu, released over an item, also picks it.
	if ui.mouse_released && rect_contains(box, ui.mx, ui.my) && !rect_contains(box, ui.press_x, ui.press_y) {
		if ui.menu_item >= 0 && ui.menu_item < len(items) && items[ui.menu_item].enabled && !items[ui.menu_item].sep {
			it := items[ui.menu_item]
			ui.menu = -1
			menu_action(it.action, it.arg)
		}
	}
}

menu_action :: proc(action: Menu_Action, arg: int) {
	switch action {
	case .None:
	case .Open_Dialog: dialog_open(Dialog(arg))
	case .Run:
		if core.game_loaded && app.gui_open do gui_toggle()
	case .Reset:
		core_reset()
		if app.gui_open do gui_toggle()
	case .Close_Game:
		core_unload_game()
	case .Save_State:
		_ = state_save(state_slot)
		if app.gui_open do gui_toggle()
	case .Load_State:
		_ = state_load(state_slot)
		if app.gui_open do gui_toggle()
	case .Quit: app.running = false
	case .Save_Config:
		settings_save()
		core_options_save()
		message_box("SAVE CFG", "CONFIGURATION SAVED")
	case .Recent:
		if arg < len(settings.recent) {
			core_path, game_path := split_recent(settings.recent[arg])
			launch_game(strings.clone(core_path, context.temp_allocator), strings.clone(game_path, context.temp_allocator))
		}
	}
}

// Load `core_path` (unless it's already loaded) and start `game_path`.
launch_game :: proc(core_path, game_path: string) -> bool {
	if !core_loaded || core.path != core_path {
		if !core_load(core_path) {
			message_box("ERROR", "COULD NOT LOAD THE CORE")
			return false
		}
	}
	if !core_load_game(game_path) {
		message_box("ERROR", "THE CORE COULD NOT LOAD THIS GAME")
		return false
	}
	set_last_core(core_path)
	recent_add(core_path, game_path)
	ui.dialog = .None
	ui.menu = -1
	app.gui_open = false
	app.paused = false
	audio_pause(false)
	return true
}

message_box :: proc(title, msg: string) {
	delete(ui.message)
	delete(ui.message_title)
	ui.message = strings.clone(msg)
	ui.message_title = strings.clone(title)
	dialog_open(.Message)
}
