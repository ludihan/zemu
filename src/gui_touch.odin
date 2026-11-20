package zemu

// Touch interface for phones and tablets. Same look as the desktop GUI
// (gradients, pixel font, snow) but built like a mobile app: bottom tabs,
// big rows you scroll by dragging, action sheets, and an on-screen gamepad.

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import retro "libretro"
import sdl "vendor:sdl3"

Touch_Page :: enum u8 {
	Games,
	Cores,
	Settings,
	Core_Options, // sub-pages
	About,
}

Touch_Sheet :: enum u8 {
	None,
	Game_Menu,    // in-game pause menu
	Core_Pick,    // choose which core opens a game
	Game_Actions, // long press on a game
	Core_Actions, // tap on an installed core
}

Finger :: struct {
	id:     sdl.FingerID,
	x, y:   int, // canvas coordinates
	active: bool,
}

MAX_FINGERS   :: 10
MOUSE_FINGER  :: sdl.FingerID(0xFFFF_FFFF)

HEADER_H :: 22
TABBAR_H :: 28
ROW_H    :: 24

Game_Entry :: struct {
	path:   string,
	name:   string,
	core:   string, // core it was last played with ("" if never)
	recent: bool,
}

Touch :: struct {
	page:   Touch_Page,
	sheet:  Touch_Sheet,
	scroll: [Touch_Page]f32,
	vel:    f32,
	drag_active:  bool,
	drag_start_y: int,
	drag_start_scroll: f32,
	drag_last_y:  int,
	long_fired:   bool,

	fingers: [MAX_FINGERS]Finger,
	safe:    Rect, // insets: x = left, y = top, w = right, h = bottom

	games:        [dynamic]Game_Entry,
	games_dirty:  bool,
	sheet_index:  int,
	pick_cores:   [dynamic]int,
	pick_game:    string,
	cores_remote: bool, // CORES page shows the download list

	import_mutex: ^sdl.Mutex,
	imported:     [dynamic]string, // files picked in the system dialog, to copy in
	menu_was_down: bool,
	confirm:       bool, // the open sheet's destructive item was tapped once
}

touch: Touch

// --- Layout and events ---------------------------------------------------------

touch_layout :: proc(ow, oh: int) {
	// Aim for ~270 logical pixels across the short side: big, readable pixels.
	short := min(ow, oh)
	ui.scale = max(1, int(math.round(f32(short) / 270)))
	canvas_resize(&ui.cv, max(1, ow / ui.scale), max(1, oh / ui.scale))

	// Notches, rounded corners and system bars.
	sr: sdl.Rect
	ww, wh: i32
	_ = sdl.GetWindowSize(app.window, &ww, &wh)
	touch.safe = {}
	if sdl.GetWindowSafeArea(app.window, &sr) && ww > 0 {
		k := ui.pixel_density / f32(ui.scale)
		touch.safe.x = int(f32(sr.x) * k + 0.99)
		touch.safe.y = int(f32(sr.y) * k + 0.99)
		touch.safe.w = int(f32(ww - sr.x - sr.w) * k + 0.99)
		touch.safe.h = int(f32(wh - sr.y - sr.h) * k + 0.99)
	}
}

touch_event :: proc(e: ^sdl.Event) {
	#partial switch e.type {
	case .FINGER_DOWN, .FINGER_MOTION:
		x, y := finger_to_canvas(e.tfinger.x, e.tfinger.y)
		finger_set(e.tfinger.fingerID, x, y, true)
	case .FINGER_UP, .FINGER_CANCELED:
		finger_set(e.tfinger.fingerID, 0, 0, false)
	// A real mouse (not one synthesized from touch) acts as one finger, so the
	// on-screen pad can be tried on a desktop.
	case .MOUSE_BUTTON_DOWN:
		if e.button.which != sdl.TOUCH_MOUSEID && e.button.button == sdl.BUTTON_LEFT {
			x, y := window_to_canvas(e.button.x, e.button.y)
			finger_set(MOUSE_FINGER, x, y, true)
		}
	case .MOUSE_MOTION:
		if e.motion.which != sdl.TOUCH_MOUSEID && .LEFT in e.motion.state {
			x, y := window_to_canvas(e.motion.x, e.motion.y)
			finger_set(MOUSE_FINGER, x, y, true)
		}
	case .MOUSE_BUTTON_UP:
		if e.button.which != sdl.TOUCH_MOUSEID && e.button.button == sdl.BUTTON_LEFT {
			finger_set(MOUSE_FINGER, 0, 0, false)
		}
	}
}

finger_to_canvas :: proc(nx, ny: f32) -> (int, int) {
	ww, wh: i32
	_ = sdl.GetWindowSize(app.window, &ww, &wh)
	return window_to_canvas(nx * f32(ww), ny * f32(wh))
}

finger_set :: proc(id: sdl.FingerID, x, y: int, down: bool) {
	free_slot := -1
	for &f, i in touch.fingers {
		if f.active && f.id == id {
			if down {
				f.x, f.y = x, y
			} else {
				f.active = false
			}
			return
		}
		if !f.active && free_slot < 0 do free_slot = i
	}
	if down && free_slot >= 0 {
		touch.fingers[free_slot] = {id = id, x = x, y = y, active = true}
	}
}

// --- Frame -------------------------------------------------------------------

touch_frame :: proc() {
	cv := &ui.cv
	touch_take_imports()

	if !app.gui_open {
		canvas_clear(cv, Color(0))
		touch_pad_frame(cv)
		draw_osd()
		return
	}

	in_game := core.game_loaded
	if in_game {
		canvas_clear(cv, rgba(0, 0, 0, 120)) // dimmed game shows through
		if touch.page != .Core_Options && touch.page != .Settings && touch.sheet == .None {
			touch.sheet = .Game_Menu
		}
	} else {
		draw_background(cv)
		if settings.snow do draw_snow(cv)
		if touch.sheet == .Game_Menu do touch.sheet = .None
	}

	back := consume_key(sdl.K_ESCAPE) || consume_key(sdl.K_AC_BACK)
	if touch.sheet == .None do touch.confirm = false

	showing_page := !(in_game && touch.sheet == .Game_Menu)
	if showing_page {
		ui.input_blocked = touch.sheet != .None
		touch_page(cv, in_game)
		ui.input_blocked = false
	}
	if touch.sheet != .None {
		touch_sheet(cv)
		if back {
			if touch.sheet == .Game_Menu do touch_resume()
			else do touch.sheet = .None
		}
	} else if back {
		switch touch.page {
		case .Core_Options, .Settings, .About:
			if in_game do touch.page = .Games
			else do touch.page = .Settings if touch.page != .Settings else .Games
			focus_clear()
		case .Cores:
			touch.page = .Games
		case .Games:
		}
	}
	touch_scroll_physics()
}

touch_resume :: proc() {
	touch.sheet = .None
	touch.page = .Games
	if app.gui_open && core.game_loaded do gui_toggle()
}

// --- Pages ----------------------------------------------------------------------

touch_page :: proc(cv: ^Canvas, in_game: bool) {
	s := touch.safe
	top := s.y
	has_tabs := !in_game && touch.page <= .Settings
	bottom := cv.h - s.h - (TABBAR_H if has_tabs else 0)

	title: string
	back_btn := false
	switch touch.page {
	case .Games:        title = "GAMES"
	case .Cores:        title = "CORES"
	case .Settings:     title = "SETTINGS"; back_btn = in_game
	case .Core_Options: title = "CORE OPTIONS"; back_btn = true
	case .About:        title = "ABOUT"; back_btn = true
	}

	content := Rect{s.x, top + HEADER_H, cv.w - s.x - s.w, bottom - top - HEADER_H}
	switch touch.page {
	case .Games:        games_page(cv, content)
	case .Cores:        cores_page(cv, content)
	case .Settings:     settings_page(cv, content)
	case .Core_Options: core_options_page(cv, content)
	case .About:        about_page(cv, content)
	}

	// Header bar (drawn last so lists scroll under it).
	hdr := Rect{0, 0, cv.w, top + HEADER_H}
	vgradient(cv, hdr, theme.title_top, theme.title_bottom)
	hline(cv, 0, hdr.h - 1, cv.w, theme.dark)
	draw_text(cv, (cv.w - text_width(title)) / 2, top + (HEADER_H - GLYPH_H) / 2, title, theme.text)
	if back_btn {
		br := Rect{s.x, top, 36, HEADER_H}
		draw_text(cv, br.x + 6, top + (HEADER_H - GLYPH_H) / 2, ICON_LEFT + " BACK", theme.text)
		if clicked(br) {
			touch.page = .Games if in_game else .Settings
			focus_clear()
		}
	}
	if touch.page == .Games {
		ir := Rect{cv.w - s.w - 48, top + 3, 44, HEADER_H - 6}
		if t_button(cv, ir, "+ ADD") do touch_import()
	}

	if has_tabs do tab_bar(cv, {0, bottom, cv.w, TABBAR_H + s.h})
}

tab_bar :: proc(cv: ^Canvas, r: Rect) {
	vgradient(cv, r, theme.win_top, theme.win_bottom)
	hline(cv, r.x, r.y, r.w, theme.light)
	names := [3]string{"GAMES", "CORES", "SETTINGS"}
	icons := [3]string{ICON_RIGHT, ICON_DOWN, "*"}
	w := r.w / 3
	for i in 0 ..< 3 {
		tr := Rect{r.x + i * w, r.y, w, TABBAR_H}
		sel := int(touch.page) == i
		if sel do fill_rect(cv, {tr.x + 4, tr.y + 2, tr.w - 8, tr.h - 4}, shade(theme.select, 0.6))
		col := theme.text_hi if sel else theme.text
		draw_text(cv, tr.x + (tr.w - CHAR_W) / 2, tr.y + 5, icons[i], col)
		draw_text(cv, tr.x + (tr.w - text_width(names[i])) / 2, tr.y + 15, names[i], col)
		if clicked(tr) && touch.page != Touch_Page(i) {
			touch.page = Touch_Page(i)
			focus_clear()
			if touch.page == .Games do touch.games_dirty = true
			if touch.page == .Cores do cores_page_open()
		}
	}
}

// Big touch button.
t_button :: proc(cv: ^Canvas, r: Rect, text: string, enabled := true) -> bool {
	down := enabled && held(r)
	fill_rounded(cv, r, theme.button_hi if down else theme.button)
	hline(cv, r.x + 1, r.y, r.w - 2, theme.light)
	hline(cv, r.x + 1, r.y + r.h - 1, r.w - 2, theme.dark)
	t := fit_text(text, r.w - 6)
	draw_text(cv, r.x + (r.w - text_width(t)) / 2, r.y + (r.h - GLYPH_H) / 2, t, theme.text if enabled else theme.text_dim)
	return enabled && clicked(r)
}

// --- Scrolling ------------------------------------------------------------------

// Starts a scrolling region; returns the y offset to draw content at.
scroll_region :: proc(area: Rect, content_h: int) -> int {
	sc := &touch.scroll[touch.page]
	max_scroll := f32(max(0, content_h - area.h))
	if !ui.input_blocked {
		if ui.mouse_pressed && rect_contains(area, ui.mx, ui.my) {
			touch.drag_active = false
			touch.drag_start_y = ui.my
			touch.drag_last_y = ui.my
			touch.drag_start_scroll = sc^
			touch.vel = 0
			touch.long_fired = false
		}
		if ui.mouse_down && rect_contains(area, ui.press_x, ui.press_y) {
			if !touch.drag_active && abs(ui.my - touch.drag_start_y) > 5 {
				touch.drag_active = true
				ui.press_x, ui.press_y = -10000, -10000 // a drag is not a tap
			}
		}
		if touch.drag_active {
			if ui.mouse_down {
				sc^ = touch.drag_start_scroll - f32(ui.my - touch.drag_start_y)
				touch.vel = f32(touch.drag_last_y - ui.my)
				touch.drag_last_y = ui.my
			} else {
				touch.drag_active = false
			}
		}
		if ui.wheel != 0 && rect_contains(area, ui.mx, ui.my) do sc^ += f32(ui.wheel * ROW_H)
	}
	sc^ = clamp(sc^, 0, max_scroll)
	return area.y - int(sc^)
}

touch_scroll_physics :: proc() {
	if touch.drag_active || ui.mouse_down do return
	if abs(touch.vel) < 0.2 {
		touch.vel = 0
		return
	}
	touch.scroll[touch.page] += touch.vel
	touch.vel *= 0.92
}

// Long press on a row (fires once per press).
long_pressed :: proc(r: Rect) -> bool {
	if ui.input_blocked || touch.long_fired || touch.drag_active do return false
	if ui.mouse_down && rect_contains(r, ui.mx, ui.my) && rect_contains(r, ui.press_x, ui.press_y) {
		if sdl.GetTicksNS() - ui.press_ns > 500_000_000 {
			touch.long_fired = true
			ui.press_x, ui.press_y = -10000, -10000
			return true
		}
	}
	return false
}

row_bg :: proc(cv: ^Canvas, r: Rect, i: int) {
	if held(r) do fill_rect(cv, r, shade(theme.select, 0.7))
	else if i % 2 == 0 do fill_rect(cv, r, rgba(0, 0, 0, 40))
	hline(cv, r.x + 6, r.y + r.h - 1, r.w - 12, rgba(255, 255, 255, 18))
}

section_header :: proc(cv: ^Canvas, x, y: int, s: string) {
	draw_text(cv, x + 8, y + 8, s, theme.text_hi)
}

// --- Games page -----------------------------------------------------------------

games_refresh :: proc() {
	for g in touch.games {
		delete(g.path); delete(g.name); delete(g.core)
	}
	clear(&touch.games)
	seen := make(map[string]bool, allocator = context.temp_allocator)
	for r in settings.recent {
		core_path, game_path := split_recent(r)
		if !file_exists(game_path) do continue
		append(&touch.games, Game_Entry{path = strings.clone(game_path), name = strings.clone(stem(game_path)), core = strings.clone(core_path), recent = true})
		seen[game_path] = true
	}
	lib := make([dynamic]Game_Entry, context.temp_allocator)
	for d in list_dir(paths.roms, context.temp_allocator) {
		if d.is_dir do continue
		p := join_path(paths.roms, d.name)
		if seen[p] {
			delete(p)
			continue
		}
		append(&lib, Game_Entry{path = p, name = strings.clone(stem(d.name))})
	}
	slice.sort_by(lib[:], proc(a, b: Game_Entry) -> bool {
		return strings.compare(strings.to_lower(a.name, context.temp_allocator), strings.to_lower(b.name, context.temp_allocator)) < 0
	})
	append(&touch.games, ..lib[:])
	touch.games_dirty = false
}

games_page :: proc(cv: ^Canvas, area: Rect) {
	if touch.games_dirty || (len(touch.games) == 0 && ui.frame % 120 == 1) do games_refresh()
	n_recent := 0
	for g in touch.games do if g.recent do n_recent += 1
	n_lib := len(touch.games) - n_recent

	content_h := ROW_H * len(touch.games) + 20 * (int(n_recent > 0) + int(n_lib > 0)) + 8
	set_clip(cv, area)
	y := scroll_region(area, content_h)
	if len(touch.games) == 0 {
		reset_clip(cv)
		empty_state(cv, area, "NO GAMES YET", "TAP + ADD TO IMPORT A GAME FILE" if len(installed_cores) > 0 else "GET A CORE IN THE CORES TAB, THEN TAP + ADD")
		return
	}
	for g, i in touch.games {
		if i == 0 && g.recent {
			section_header(cv, area.x, y, "RECENT")
			y += 20
		} else if !g.recent && (i == 0 || touch.games[i - 1].recent) {
			section_header(cv, area.x, y, "LIBRARY")
			y += 20
		}
		r := Rect{area.x, y, area.w, ROW_H}
		if r.y + r.h >= area.y && r.y < area.y + area.h {
			row_bg(cv, r, i)
			draw_text(cv, r.x + 10, r.y + 5, fit_text(g.name, r.w - 20), theme.text)
			sub := strings.to_upper(extension(g.path), context.temp_allocator)
			if g.core != "" {
				if ci := core_entry_index(g.core); ci >= 0 do sub = installed_cores[ci].name
			}
			draw_text(cv, r.x + 10, r.y + 14, fit_text(sub, r.w - 20), theme.text_dim)
			if long_pressed(r) {
				touch.sheet = .Game_Actions
				touch.sheet_index = i
			} else if clicked(r) {
				touch_launch(g.path, g.core)
			}
		}
		y += ROW_H
	}
	reset_clip(cv)
}

empty_state :: proc(cv: ^Canvas, area: Rect, title, body: string) {
	y := area.y + area.h / 3
	draw_text(cv, area.x + (area.w - text_width(title)) / 2, y, title, theme.text)
	for l, i in wrap_text(body, area.w - 32) {
		draw_text(cv, area.x + (area.w - text_width(l)) / 2, y + 14 + i * 9, l, theme.text_dim)
	}
}

// Start a game, asking which core to use when more than one fits.
touch_launch :: proc(path, last_core: string) {
	cands := load_dialog_candidates(path)
	if last_core != "" && core_entry_index(last_core) >= 0 {
		_ = launch_game(last_core, path)
		touch.games_dirty = true
		return
	}
	switch len(cands) {
	case 0:
		if downloads_supported() {
			touch.page = .Cores
			cores_page_open()
			touch.cores_remote = true
			clear(&cores_dlg.search)
			append(&cores_dlg.search, ..transmute([]u8)extension(path))
			osd_message("GET A CORE FOR THIS GAME")
		} else {
			osd_message("NO CORE FOR THIS GAME")
		}
	case 1:
		_ = launch_game(installed_cores[cands[0]].path, path)
		touch.games_dirty = true
	case:
		clear(&touch.pick_cores)
		append(&touch.pick_cores, ..cands)
		delete(touch.pick_game)
		touch.pick_game = strings.clone(path)
		touch.sheet = .Core_Pick
	}
}

// --- Importing games -----------------------------------------------------------

touch_import :: proc() {
	when IS_WEB {
		web_import_file(.Rom)
	} else {
		if touch.import_mutex == nil do touch.import_mutex = sdl.CreateMutex()
		cb :: proc "c" (userdata: rawptr, filelist: [^]cstring, filter: i32) {
			context = app_ctx
			if filelist == nil do return
			sdl.LockMutex(touch.import_mutex)
			for i := 0; filelist[i] != nil; i += 1 {
				append(&touch.imported, strings.clone(string(filelist[i])))
			}
			sdl.UnlockMutex(touch.import_mutex)
		}
		sdl.ShowOpenFileDialog(cb, nil, app.window, nil, 0, nil, true)
	}
}

// Copy picked files into the library. On Android these are content:// URIs,
// which SDL's file functions can read.
touch_take_imports :: proc() {
	if touch.import_mutex == nil do return
	sdl.LockMutex(touch.import_mutex)
	files := touch.imported[:]
	touch.imported = nil
	sdl.UnlockMutex(touch.import_mutex)
	for f in files {
		import_rom_file(f)
		delete(f)
	}
	delete(files)
}

import_rom_file :: proc(src: string) {
	data, ok := read_file(src, context.temp_allocator)
	if !ok {
		osd_message("COULD NOT READ FILE")
		return
	}
	name := uri_file_name(src)
	if !write_file(join_path(paths.roms, name, context.temp_allocator), data) {
		osd_message("COULD NOT SAVE FILE")
		return
	}
	osd_message(fmt.tprintf("ADDED %s", stem(name)))
	touch.games_dirty = true
}

// "content://.../document/primary%3ADownload%2Fgame.sfc" -> "game.sfc"
uri_file_name :: proc(uri: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(uri); i += 1 {
		if uri[i] == '%' && i + 2 < len(uri) {
			hex :: proc(c: u8) -> int {
				switch c {
				case '0' ..= '9': return int(c - '0')
				case 'a' ..= 'f': return int(c - 'a' + 10)
				case 'A' ..= 'F': return int(c - 'A' + 10)
				}
				return 0
			}
			strings.write_byte(&b, u8(hex(uri[i + 1]) * 16 + hex(uri[i + 2])))
			i += 2
		} else {
			strings.write_byte(&b, uri[i])
		}
	}
	s := strings.to_string(b)
	cut := max(strings.last_index_byte(s, '/'), strings.last_index_byte(s, ':'), strings.last_index_byte(s, '\\'))
	name := s[cut + 1:]
	return name if name != "" else "game.bin"
}

// --- Cores page -----------------------------------------------------------------

cores_page_open :: proc() {
	cores_scan()
	if downloads_supported() && (dl.state == .Empty || dl.state == .Failed) do catalog_refresh()
	touch.cores_remote = len(installed_cores) == 0 && downloads_supported()
}

cores_page :: proc(cv: ^Canvas, area: Rect) {
	// Segmented control: INSTALLED | GET MORE
	seg := Rect{area.x + 8, area.y + 6, area.w - 16, 16}
	half := seg.w / 2
	for i in 0 ..< 2 {
		r := Rect{seg.x + i * half, seg.y, half if i == 0 else seg.w - half, seg.h}
		sel := touch.cores_remote == (i == 1)
		fill_rounded(cv, r, theme.select if sel else shade(theme.button, 0.6))
		t := fmt.tprintf("INSTALLED (%d)", len(installed_cores)) if i == 0 else "GET MORE"
		draw_text(cv, r.x + (r.w - text_width(t)) / 2, r.y + 6, t, theme.text if sel else theme.text_dim)
		if clicked(r) {
			touch.cores_remote = i == 1
			touch.scroll[.Cores] = 0
			focus_clear()
		}
	}

	list := Rect{area.x, seg.y + seg.h + 6, area.w, area.y + area.h - seg.y - seg.h - 6}
	if touch.cores_remote {
		remote_cores_list(cv, list)
	} else {
		installed_cores_list(cv, list)
	}
}

installed_cores_list :: proc(cv: ^Canvas, area: Rect) {
	if len(installed_cores) == 0 {
		empty_state(cv, area, "NO CORES INSTALLED", "CORES RUN THE GAMES. OPEN GET MORE TO DOWNLOAD SOME.")
		return
	}
	set_clip(cv, area)
	y := scroll_region(area, len(installed_cores) * ROW_H)
	for e, i in installed_cores {
		r := Rect{area.x, y + i * ROW_H, area.w, ROW_H}
		if r.y + r.h < area.y || r.y > area.y + area.h do continue
		row_bg(cv, r, i)
		draw_text(cv, r.x + 10, r.y + 5, fit_text(e.name, r.w - 20), theme.text)
		sub := strings.to_upper(e.extensions, context.temp_allocator) if e.extensions != "" else "RUNS WITHOUT A GAME"
		draw_text(cv, r.x + 10, r.y + 14, fit_text(sub, r.w - 20), theme.text_dim)
		if clicked(r) || long_pressed(r) {
			touch.sheet = .Core_Actions
			touch.sheet_index = i
		}
	}
	reset_clip(cv)
}

remote_cores_list :: proc(cv: ^Canvas, area: Rect) {
	if !downloads_supported() {
		empty_state(cv, area, "NOT AVAILABLE", "CORE DOWNLOADS AREN'T AVAILABLE ON THIS PLATFORM.")
		return
	}
	sr := Rect{area.x + 8, area.y, area.w - 16, 16}
	_ = text_field(cv, sr, &cores_dlg.search, 32)
	if len(cores_dlg.search) == 0 && ui.focus == 0 do draw_text(cv, sr.x + 4, sr.y + 6, "SEARCH NAME, SYSTEM, EXTENSION", theme.text_dim)

	list := Rect{area.x, area.y + 20, area.w, area.h - 20}
	switch dl.state {
	case .Empty, .Loading:
		empty_state(cv, list, "LOADING", "GETTING THE CORE LIST...")
		return
	case .Failed:
		empty_state(cv, list, "OFFLINE", "COULD NOT GET THE CORE LIST.")
		if t_button(cv, {list.x + (list.w - 80) / 2, list.y + list.h / 2 + 24, 80, 18}, "TRY AGAIN") do catalog_refresh()
		return
	case .Ready:
	}

	query := string(cores_dlg.search[:])
	rows := make([dynamic]int, context.temp_allocator)
	for rc, i in dl.remote do if remote_matches(rc, query) do append(&rows, i)

	set_clip(cv, list)
	y := scroll_region(list, len(rows) * ROW_H)
	for ri, i in rows {
		r := Rect{list.x, y + i * ROW_H, list.w, ROW_H}
		if r.y + r.h < list.y || r.y > list.y + list.h do continue
		rc := dl.remote[ri]
		row_bg(cv, r, i)
		draw_text(cv, r.x + 10, r.y + 5, fit_text(rc.name, r.w - 60), theme.text)
		draw_text(cv, r.x + 10, r.y + 14, fit_text(strings.to_upper(rc.extensions, context.temp_allocator), r.w - 60), theme.text_dim)

		status := "GET"
		col := theme.text
		if dl.job != nil && dl.job_core == ri {
			status = format_size(dl.job.bytes)
			col = theme.text_hi
		} else if slice_contains(dl.queue[:], ri) {
			status = "QUEUED"
			col = theme.text_dim
		} else if remote_installed(rc) {
			status = ICON_CHECK
			col = theme.text_hi
		}
		draw_text(cv, r.x + r.w - text_width(status) - 10, r.y + 9, status, col)
		if clicked(r) {
			focus_clear()
			download_core(ri)
		}
	}
	reset_clip(cv)
}

// --- Settings ---------------------------------------------------------------------

Setting_Row :: struct {
	label: string,
	value: string,
}

settings_page :: proc(cv: ^Canvas, area: Rect) {
	scale_names := [Scale_Mode]string{.Aspect = "KEEP ASPECT", .Integer = "INTEGER", .Stretch = "STRETCH"}
	ui_names := [UI_Override]string{.Auto = "AUTO", .Desktop = "DESKTOP", .Touch = "TOUCH"}
	onoff :: proc(b: bool) -> string { return "ON" if b else "OFF" }

	rows := []Setting_Row{
		{"SCALING", scale_names[settings.scale_mode]},
		{"SMOOTH PIXELS", onoff(settings.video_filter)},
		{"SHOW FPS", onoff(settings.show_fps)},
		{"SOUND", onoff(!settings.mute)},
		{"TOUCH PAD OPACITY", fmt.tprintf("%d%%", settings.touch_opacity)},
		{"SNOW", onoff(settings.snow)},
		{"INTERFACE", ui_names[settings.ui_override]},
		{"CORE OPTIONS", ICON_RIGHT if core_loaded && len(core.options) > 0 else "-"},
		{"ABOUT", ICON_RIGHT},
	}
	set_clip(cv, area)
	y := scroll_region(area, len(rows) * ROW_H + 8)
	for row, i in rows {
		r := Rect{area.x, y + i * ROW_H, area.w, ROW_H}
		row_bg(cv, r, i)
		draw_text(cv, r.x + 10, r.y + 10, row.label, theme.text)
		draw_text(cv, r.x + r.w - text_width(row.value) - 10, r.y + 10, row.value, theme.text_hi)
		if !clicked(r) do continue
		switch i {
		case 0: settings.scale_mode = Scale_Mode((int(settings.scale_mode) + 1) % len(Scale_Mode))
		case 1: settings.video_filter = !settings.video_filter
		case 2: settings.show_fps = !settings.show_fps
		case 3: settings.mute = !settings.mute
		case 4: settings.touch_opacity = (settings.touch_opacity + 20) % 120 if settings.touch_opacity < 100 else 20
		case 5: settings.snow = !settings.snow
		case 6:
			settings.ui_override = UI_Override((int(settings.ui_override) + 1) % len(UI_Override))
			ui.kind = gui_pick_kind()
			gui_update_cursor()
		case 7: if core_loaded && len(core.options) > 0 do touch.page = .Core_Options
		case 8: touch.page = .About
		}
		settings_save()
	}
	reset_clip(cv)
}

core_options_page :: proc(cv: ^Canvas, area: Rect) {
	if !core_loaded {
		empty_state(cv, area, "NO CORE LOADED", "START A GAME FIRST.")
		return
	}
	vis := make([dynamic]int, context.temp_allocator)
	for o, i in core.options do if o.visible && len(o.values) > 0 do append(&vis, i)
	set_clip(cv, area)
	y := scroll_region(area, len(vis) * ROW_H + 8)
	for oi, i in vis {
		o := &core.options[oi]
		r := Rect{area.x, y + i * ROW_H, area.w, ROW_H}
		if r.y + r.h < area.y || r.y > area.y + area.h do continue
		row_bg(cv, r, i)
		val := o.values[o.current].label
		vw := min(text_width(val), r.w / 2)
		draw_text(cv, r.x + 10, r.y + 10, fit_text(o.desc, r.w - vw - 30), theme.text)
		draw_text(cv, r.x + r.w - vw - 10, r.y + 10, fit_text(val, r.w / 2), theme.text_hi)
		if clicked(r) {
			core_option_set(o, o.current + 1)
			core_options_save()
		}
	}
	reset_clip(cv)
}

about_page :: proc(cv: ^Canvas, area: Rect) {
	lines := []string{
		fmt.tprintf("ZEMU V%s", APP_VERSION),
		"A LIBRETRO FRONTEND IN THE STYLE OF ZSNES.",
		"WRITTEN IN ODIN WITH SDL3.",
		"",
		"CORES COME FROM THE LIBRETRO BUILDBOT.",
	}
	y := area.y + 12
	for l in lines {
		for w in wrap_text(l, area.w - 20) {
			draw_text(cv, area.x + 10, y, w, theme.text)
			y += 9
		}
	}
	if core_loaded {
		y += 8
		draw_text(cv, area.x + 10, y, fit_text(fmt.tprintf("CORE: %s %s", core.name, core.version), area.w - 20), theme.text_dim)
	}
}

// --- Sheets -------------------------------------------------------------------------

Sheet_Item :: struct {
	label:   string,
	enabled: bool,
}

// Bottom sheet with a list of actions. Returns the tapped index or -1.
action_sheet :: proc(cv: ^Canvas, title: string, items: []Sheet_Item) -> int {
	fill_rect(cv, {0, 0, cv.w, cv.h}, rgba(0, 0, 0, 110))
	item_h := 22
	w := min(cv.w - 16, 260)
	h := 22 + len(items) * item_h + 8 + touch.safe.h
	r := Rect{(cv.w - w) / 2, cv.h - h, w, h}
	vgradient(cv, r, theme.win_top, theme.win_bottom)
	rect_outline(cv, r, theme.border)
	bevel(cv, rect_inset(r, 1), theme.light, theme.dark)
	draw_text(cv, r.x + (r.w - text_width(fit_text(title, r.w - 12))) / 2, r.y + 8, fit_text(title, r.w - 12), theme.text_hi)
	picked := -1
	for it, i in items {
		ir := Rect{r.x + 6, r.y + 22 + i * item_h, r.w - 12, item_h - 3}
		if t_button(cv, ir, it.label, it.enabled) do picked = i
	}
	// Tapping outside closes it.
	if ui.mouse_released && !rect_contains(r, ui.mx, ui.my) && !rect_contains(r, ui.press_x, ui.press_y) && touch.sheet != .Game_Menu {
		touch.sheet = .None
	}
	return picked
}

touch_sheet :: proc(cv: ^Canvas) {
	switch touch.sheet {
	case .None:
	case .Game_Menu:
		items := []Sheet_Item{
			{"RESUME", true},
			{"SAVE STATE", true},
			{fmt.tprintf("LOAD STATE%s", "" if state_exists(state_slot) else " (EMPTY)"), state_exists(state_slot)},
			{fmt.tprintf("SLOT %d  " + ICON_LEFT + " " + ICON_RIGHT, state_slot), true},
			{fmt.tprintf("FAST FORWARD: %s", "ON" if timing.ff_toggle else "OFF"), true},
			{"RESET", true},
			{"CORE OPTIONS", len(core.options) > 0},
			{"SETTINGS", true},
			{"CLOSE GAME", true},
		}
		switch action_sheet(cv, stem(core.game_path), items) {
		case 0: touch_resume()
		case 1:
			_ = state_save(state_slot)
			touch_resume()
		case 2:
			_ = state_load(state_slot)
			touch_resume()
		case 3:
			state_slot = (state_slot + 1) % 10
		case 4:
			timing.ff_toggle = !timing.ff_toggle
			timing.fast_forward = timing.ff_toggle
		case 5:
			core_reset()
			touch_resume()
		case 6:
			touch.sheet = .None
			touch.page = .Core_Options
		case 7:
			touch.sheet = .None
			touch.page = .Settings
		case 8:
			touch.sheet = .None
			core_unload_game()
			touch.page = .Games
			touch.games_dirty = true
		}
	case .Core_Pick:
		items := make([]Sheet_Item, len(touch.pick_cores), context.temp_allocator)
		for ci, i in touch.pick_cores do items[i] = {installed_cores[ci].name, true}
		if p := action_sheet(cv, "OPEN WITH", items); p >= 0 {
			touch.sheet = .None
			_ = launch_game(installed_cores[touch.pick_cores[p]].path, touch.pick_game)
			touch.games_dirty = true
		}
	case .Game_Actions:
		if touch.sheet_index >= len(touch.games) {
			touch.sheet = .None
			return
		}
		g := touch.games[touch.sheet_index]
		in_lib := strings.has_prefix(g.path, paths.roms)
		del_label := "REMOVE FROM RECENT"
		if in_lib do del_label = "TAP AGAIN TO DELETE" if touch.confirm else "DELETE FROM LIBRARY"
		items := []Sheet_Item{{"PLAY", true}, {"OPEN WITH...", true}, {del_label, true}}
		switch action_sheet(cv, g.name, items) {
		case 0:
			touch.sheet = .None
			touch_launch(g.path, g.core)
		case 1:
			touch.sheet = .None
			touch_launch(g.path, "")
		case 2:
			// Deleting the file asks first; dropping a recent entry doesn't.
			if in_lib && !touch.confirm {
				touch.confirm = true
				break
			}
			touch.sheet = .None
			if in_lib do _ = delete_file(g.path)
			for r, i in settings.recent {
				_, gp := split_recent(r)
				if gp == g.path {
					delete(r)
					ordered_remove(&settings.recent, i)
					break
				}
			}
			settings_save()
			touch.games_dirty = true
		}
	case .Core_Actions:
		if touch.sheet_index >= len(installed_cores) {
			touch.sheet = .None
			return
		}
		e := installed_cores[touch.sheet_index]
		items := []Sheet_Item{{"START WITHOUT GAME", e.no_game}, {"TAP AGAIN TO REMOVE" if touch.confirm else "REMOVE", true}}
		switch action_sheet(cv, e.name, items) {
		case 0:
			touch.sheet = .None
			if core_load(e.path) && core_start_no_game() {
				app.gui_open = false
				audio_pause(false)
				gui_update_cursor()
			}
		case 1:
			if !touch.confirm {
				touch.confirm = true
				break
			}
			touch.sheet = .None
			if core_loaded && core.path == e.path do core_unload()
			_ = delete_file(e.path)
			cores_scan()
		}
	}
}

// --- On-screen gamepad -----------------------------------------------------------

Pad_Layout :: struct {
	game:     Rect, // canvas rect for the game picture
	dpad:     [2]int,
	dpad_r:   int,
	face:     [4]struct{ id: retro.Joypad_Id, x, y, r: int, name: string },
	l, r:     Rect,
	select_, start: Rect,
	menu:     Rect,
	ff:       Rect,
}

pad_layout :: proc(cv: ^Canvas) -> (p: Pad_Layout) {
	s := touch.safe
	area := Rect{s.x, s.y, cv.w - s.x - s.w, cv.h - s.y - s.h}
	aspect := video_aspect() if core.game_loaded else 4.0 / 3.0
	portrait := cv.h > cv.w

	if portrait {
		gh := min(int(f32(area.w) / aspect), area.h * 55 / 100)
		p.game = {area.x, area.y, area.w, gh}
		ctl := Rect{area.x, area.y + gh, area.w, area.h - gh}
		cy := ctl.y + ctl.h * 52 / 100
		p.dpad_r = min(area.w * 19 / 100, ctl.h * 28 / 100)
		p.dpad = {ctl.x + area.w * 25 / 100, cy}
		fc := [2]int{ctl.x + area.w * 75 / 100, cy}
		pad_face(&p, fc, p.dpad_r)
		p.l = {ctl.x + 8, ctl.y + 10, area.w * 26 / 100, 16}
		p.r = {ctl.x + ctl.w - 8 - area.w * 26 / 100, ctl.y + 10, area.w * 26 / 100, 16}
		by := ctl.y + ctl.h - 24
		p.select_ = {ctl.x + ctl.w / 2 - 46, by, 40, 14}
		p.start   = {ctl.x + ctl.w / 2 + 6, by, 40, 14}
		p.menu = {ctl.x + ctl.w / 2 - 20, ctl.y + 11, 40, 14}
		p.ff   = {ctl.x + ctl.w / 2 - 20, ctl.y + 29, 40, 14}
	} else {
		p.game = area
		p.dpad_r = min(area.h * 22 / 100, area.w * 12 / 100)
		p.dpad = {area.x + p.dpad_r + 18, area.y + area.h - p.dpad_r - 20}
		fc := [2]int{area.x + area.w - p.dpad_r - 18, p.dpad.y}
		pad_face(&p, fc, p.dpad_r)
		lw := max(50, area.w * 14 / 100)
		p.l = {area.x + 6, area.y + 6, lw, 16}
		p.r = {area.x + area.w - 6 - lw, area.y + 6, lw, 16}
		p.select_ = {area.x + area.w / 2 - 46, area.y + area.h - 18, 40, 14}
		p.start   = {area.x + area.w / 2 + 6, area.y + area.h - 18, 40, 14}
		p.menu = {area.x + area.w / 2 - 46, area.y + 4, 40, 14}
		p.ff   = {area.x + area.w / 2 + 6, area.y + 4, 40, 14}
	}
	return
}

@(private="file")
pad_face :: proc(p: ^Pad_Layout, c: [2]int, size: int) {
	off := size * 62 / 100
	r := size * 36 / 100
	// SNES layout: X top, A right, B bottom, Y left.
	p.face[0] = {.X, c.x, c.y - off, r, "X"}
	p.face[1] = {.A, c.x + off, c.y, r, "A"}
	p.face[2] = {.B, c.x, c.y + off, r, "B"}
	p.face[3] = {.Y, c.x - off, c.y, r, "Y"}
}

touch_game_area :: proc(w, h: f32) -> sdl.FRect {
	if ui.scale <= 0 || ui.cv.w == 0 do return {0, 0, w, h}
	g := pad_layout(&ui.cv).game
	s := f32(ui.scale)
	return {ui.dst.x + f32(g.x) * s, ui.dst.y + f32(g.y) * s, f32(g.w) * s, f32(g.h) * s}
}

bit :: proc(id: retro.Joypad_Id) -> u16 { return 1 << u16(id) }

touch_pad_frame :: proc(cv: ^Canvas) {
	p := pad_layout(cv)
	buttons: u16

	for f in touch.fingers {
		if !f.active do continue
		// D-pad: 8 directions from the angle, with a dead zone in the middle.
		dx := f32(f.x - p.dpad.x)
		dy := f32(f.y - p.dpad.y)
		dist := math.sqrt(dx * dx + dy * dy)
		if dist < f32(p.dpad_r) * 1.5 && dist > f32(p.dpad_r) * 0.18 {
			a := math.atan2(dy, dx) // -pi..pi, 0 = right
			sector := int(math.round(a / (math.PI / 4))) // -4..4
			switch sector {
			case 0:       buttons |= bit(.RIGHT)
			case 1:       buttons |= bit(.RIGHT) | bit(.DOWN)
			case 2:       buttons |= bit(.DOWN)
			case 3:       buttons |= bit(.DOWN) | bit(.LEFT)
			case 4, -4:   buttons |= bit(.LEFT)
			case -3:      buttons |= bit(.LEFT) | bit(.UP)
			case -2:      buttons |= bit(.UP)
			case -1:      buttons |= bit(.UP) | bit(.RIGHT)
			}
		}
		// Face buttons: the nearest within reach, or two when the finger
		// sits between them (A+B rolls).
		for b in p.face {
			bx := f32(f.x - b.x)
			by := f32(f.y - b.y)
			if bx * bx + by * by <= f32(b.r * b.r) * 2.2 do buttons |= bit(b.id)
		}
		grow :: proc(r: Rect) -> Rect { return {r.x - 4, r.y - 4, r.w + 8, r.h + 8} }
		if rect_contains(grow(p.l), f.x, f.y) do buttons |= bit(.L)
		if rect_contains(grow(p.r), f.x, f.y) do buttons |= bit(.R)
		if rect_contains(grow(p.select_), f.x, f.y) do buttons |= bit(.SELECT)
		if rect_contains(grow(p.start), f.x, f.y) do buttons |= bit(.START)
	}
	input.touch_pad.buttons = buttons

	// Menu and fast-forward are taps, not held buttons.
	if clicked(p.menu) {
		touch.sheet = .Game_Menu
		gui_toggle()
	}
	if clicked(p.ff) {
		timing.ff_toggle = !timing.ff_toggle
		timing.fast_forward = timing.ff_toggle
	}

	// Draw
	a := clamp(settings.touch_opacity * 255 / 100, 0, 255)
	if a == 0 do return
	base := rgba(200, 210, 255, a * 35 / 100)
	edge := rgba(230, 235, 255, a * 80 / 100)
	lit := rgba(255, 240, 120, a * 70 / 100)
	txt := rgba(255, 255, 255, a)

	// D-pad: a cross.
	cx, cy, r := p.dpad.x, p.dpad.y, p.dpad_r
	arm := r * 40 / 100
	fill_rounded(cv, {cx - arm, cy - r, arm * 2, r * 2}, base)
	fill_rect(cv, {cx - r, cy - arm, r - arm, arm * 2}, base)
	fill_rect(cv, {cx + arm, cy - arm, r - arm, arm * 2}, base)
	dirs := [4]struct{ id: retro.Joypad_Id, x, y: int, icon: u8 }{
		{.UP, cx, cy - r * 65 / 100, ICON_UP[0]},
		{.DOWN, cx, cy + r * 65 / 100, ICON_DOWN[0]},
		{.LEFT, cx - r * 65 / 100, cy, ICON_LEFT[0]},
		{.RIGHT, cx + r * 65 / 100, cy, ICON_RIGHT[0]},
	}
	for d in dirs {
		if buttons & bit(d.id) != 0 do fill_rect(cv, {d.x - arm + 1, d.y - arm + 1, arm * 2 - 2, arm * 2 - 2}, lit)
		draw_char(cv, d.x - 2, d.y - 2, d.icon, txt)
	}
	// Outline the whole cross: 12 edges.
	l := r - arm
	hline(cv, cx - arm, cy - r, arm * 2, edge)
	hline(cv, cx - arm, cy + r - 1, arm * 2, edge)
	vline(cv, cx - r, cy - arm, arm * 2, edge)
	vline(cv, cx + r - 1, cy - arm, arm * 2, edge)
	vline(cv, cx - arm, cy - r, l, edge)
	vline(cv, cx + arm - 1, cy - r, l, edge)
	vline(cv, cx - arm, cy + arm, l, edge)
	vline(cv, cx + arm - 1, cy + arm, l, edge)
	hline(cv, cx - r, cy - arm, l, edge)
	hline(cv, cx - r, cy + arm - 1, l, edge)
	hline(cv, cx + arm, cy - arm, l, edge)
	hline(cv, cx + arm, cy + arm - 1, l, edge)

	for b in p.face {
		fill_circle(cv, b.x, b.y, b.r, lit if buttons & bit(b.id) != 0 else base)
		circle_outline(cv, b.x, b.y, b.r, edge)
		draw_char(cv, b.x - 2, b.y - 2, b.name[0], txt)
	}
	pill :: proc(cv: ^Canvas, r: Rect, text: string, on: bool, base, lit, edge, txt: Color) {
		fill_rounded(cv, r, lit if on else base)
		hline(cv, r.x + 1, r.y, r.w - 2, edge)
		hline(cv, r.x + 1, r.y + r.h - 1, r.w - 2, edge)
		vline(cv, r.x, r.y + 1, r.h - 2, edge)
		vline(cv, r.x + r.w - 1, r.y + 1, r.h - 2, edge)
		draw_text_plain(cv, r.x + (r.w - text_width(text)) / 2, r.y + (r.h - GLYPH_H) / 2, text, txt)
	}
	pill(cv, p.l, "L", buttons & bit(.L) != 0, base, lit, edge, txt)
	pill(cv, p.r, "R", buttons & bit(.R) != 0, base, lit, edge, txt)
	pill(cv, p.select_, "SELECT", buttons & bit(.SELECT) != 0, base, lit, edge, txt)
	pill(cv, p.start, "START", buttons & bit(.START) != 0, base, lit, edge, txt)
	pill(cv, p.menu, "MENU", held(p.menu), base, lit, edge, txt)
	pill(cv, p.ff, ">>", timing.ff_toggle, base, lit, edge, txt)
}
