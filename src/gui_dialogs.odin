package zemu

// The desktop GUI's windows.

import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"

dialog_title :: proc(d: Dialog) -> string {
	switch d {
	case .None:         return ""
	case .Load:         return "LOAD GAME"
	case .Pick_State:   return "PICK STATE"
	case .Input:        return "INPUT CONFIG"
	case .Video:        return "VIDEO CONFIG"
	case .Sound:        return "SOUND CONFIG"
	case .Core_Options: return "CORE OPTIONS"
	case .Cores:        return "CORES"
	case .Cheat_Add:    return "ADD CHEAT CODE"
	case .Cheat_Browse: return "CHEAT BROWSER"
	case .Netplay:      return "NETPLAY"
	case .Gui_Opts:     return "GUI OPTIONS"
	case .About:        return "ABOUT"
	case .Message:      return ui.message_title
	}
	return ""
}

// Preferred size; dialogs with lists grow with the canvas.
dialog_size :: proc(d: Dialog) -> (w, h: int) {
	cw, ch := ui.cv.w, ui.cv.h - MENUBAR_H
	switch d {
	case .Load, .Cores:   return min(cw - 8, 420), min(ch - 8, 300)
	case .Core_Options:   return min(cw - 8, 360), min(ch - 8, 260)
	case .Cheat_Browse:   return min(cw - 8, 300), min(ch - 8, 200)
	case .Input:          return 230, 196
	case .Pick_State:     return 160, 92
	case .Video:          return 170, 116
	case .Sound:          return 170, 80
	case .Cheat_Add:      return 200, 96
	case .Netplay:        return 200, 80
	case .Gui_Opts:       return 190, 150
	case .About:          return min(cw - 8, 240), 190
	case .Message:        return min(cw - 8, max(140, text_width(ui.message) + 20)), 70
	case .None:
	}
	return 160, 100
}

dialog_open :: proc(d: Dialog) {
	if ui.dialog != .None do dialog_close()
	ui.dialog = d
	w, h := dialog_size(d)
	ui.dialog_rect = {(ui.cv.w - w) / 2, MENUBAR_H + (ui.cv.h - MENUBAR_H - h) / 2, w, h}
	#partial switch d {
	case .Load:         load_dialog_open()
	case .Pick_State:   pick_state_open()
	case .Cores:        cores_dialog_open()
	case .Cheat_Add:    clear(&cheat_code_buf); clear(&cheat_desc_buf)
	}
}

dialog_close :: proc() {
	#partial switch ui.dialog {
	case .Core_Options: core_options_save()
	case .Input, .Video, .Sound, .Gui_Opts: settings_save()
	}
	input_capture = -1
	ui.dialog = .None
	ui.dragging = false
	focus_clear()
}

dialog_frame :: proc(cv: ^Canvas) {
	r := &ui.dialog_rect
	r.w, r.h = dialog_size(ui.dialog)
	// Drag by the title bar.
	tb := title_bar_rect(r^)
	if !ui.input_blocked && ui.mouse_pressed && rect_contains({tb.x, tb.y, tb.w - 10, tb.h}, ui.mx, ui.my) {
		ui.dragging = true
		ui.drag_dx, ui.drag_dy = ui.mx - r.x, ui.my - r.y
	}
	if !ui.mouse_down do ui.dragging = false
	if ui.dragging {
		r.x, r.y = ui.mx - ui.drag_dx, ui.my - ui.drag_dy
	}
	r.x = clamp(r.x, 0, max(0, cv.w - r.w))
	r.y = clamp(r.y, MENUBAR_H, max(MENUBAR_H, cv.h - r.h))

	d := ui.dialog
	if window_frame(cv, dialog_title(d), r^) {
		dialog_close()
		return
	}
	b := window_body(r^)
	switch d {
	case .None:
	case .Load:         load_dialog(cv, b)
	case .Pick_State:   pick_state_dialog(cv, b)
	case .Input:        input_dialog(cv, b)
	case .Video:        video_dialog(cv, b)
	case .Sound:        sound_dialog(cv, b)
	case .Core_Options: core_options_dialog(cv, b)
	case .Cores:        cores_dialog(cv, b)
	case .Cheat_Add:    cheat_add_dialog(cv, b)
	case .Cheat_Browse: cheat_browse_dialog(cv, b)
	case .Netplay:      netplay_dialog(cv, b)
	case .Gui_Opts:     gui_opts_dialog(cv, b)
	case .About:        about_dialog(cv, b)
	case .Message:      message_dialog(cv, b)
	}
}

// Show the end of a long path: "~ROMS/SNES".
fit_text_tail :: proc(s: string, w: int) -> string {
	n := w / CHAR_W
	if len(s) <= n do return s
	if n <= 1 do return ""
	return strings.concatenate({"~", s[len(s) - n + 1:]}, context.temp_allocator)
}

wrap_text :: proc(s: string, w: int) -> []string {
	n := max(1, w / CHAR_W)
	lines := make([dynamic]string, context.temp_allocator)
	rest := s
	for len(rest) > 0 {
		if nl := strings.index_byte(rest, '\n'); nl >= 0 && nl <= n {
			append(&lines, rest[:nl])
			rest = rest[nl + 1:]
			continue
		}
		if len(rest) <= n {
			append(&lines, rest)
			break
		}
		cut := strings.last_index_byte(rest[:n + 1], ' ')
		if cut <= 0 do cut = n
		append(&lines, rest[:cut])
		rest = strings.trim_left_space(rest[cut:])
	}
	return lines[:]
}

// --- Load game ------------------------------------------------------------------

Load_Dialog :: struct {
	dir:        string,
	entries:    []Dir_Entry,
	files:      [dynamic]int,
	dirs:       [dynamic]int,
	file_list:  List_State,
	dir_list:   List_State,
	focus_dirs: bool,
	show_all:   bool,
	core_pick:  int, // index into the candidate cores for the selected file
}

load_dlg: Load_Dialog

load_dialog_open :: proc() {
	cores_scan()
	dir := settings.last_dir
	if dir == "" || !dir_exists(dir) {
		when IS_WEB || IS_MOBILE {
			dir = paths.roms // imported games live here
		} else {
			home := sdl.GetUserFolder(.HOME)
			dir = string(home) if home != nil else paths.roms
		}
	}
	load_dialog_chdir(dir)
}

load_dialog_chdir :: proc(dir: string) {
	d := strings.clone(dir)
	delete(load_dlg.dir)
	load_dlg.dir = d
	if load_dlg.entries != nil do free_dir_entries(load_dlg.entries)
	load_dlg.entries = list_dir(d)
	load_dlg.file_list = {}
	load_dlg.dir_list = {}
	load_dialog_filter()
}

load_dialog_filter :: proc() {
	clear(&load_dlg.files)
	clear(&load_dlg.dirs)
	for e, i in load_dlg.entries {
		if e.is_dir {
			if !strings.has_prefix(e.name, ".") do append(&load_dlg.dirs, i)
		} else if load_dlg.show_all || (!strings.has_prefix(e.name, ".") && (len(installed_cores) == 0 || known_extension(extension(e.name)))) {
			append(&load_dlg.files, i)
		}
	}
}

load_dialog_selected :: proc() -> (path: string, ok: bool) {
	s := load_dlg.file_list.sel
	if s < 0 || s >= len(load_dlg.files) do return "", false
	return join_path(load_dlg.dir, load_dlg.entries[load_dlg.files[s]].name, context.temp_allocator), true
}

// Candidate cores for a file: the loaded core first if it accepts it.
load_dialog_candidates :: proc(path: string) -> []int {
	ext := extension(path)
	res := make([dynamic]int, context.temp_allocator)
	cands := cores_for_extension(ext)
	if ext == "zip" && len(cands) == 0 {
		for _, i in installed_cores do append(&res, i)
		return res[:]
	}
	if core_loaded {
		if i := core_entry_index(core.path); i >= 0 {
			for c in cands do if c == i do append(&res, i)
		}
	}
	for c in cands {
		if len(res) > 0 && res[0] == c do continue
		append(&res, c)
	}
	return res[:]
}

load_dialog_go_up :: proc() {
	parent := dir_name(load_dlg.dir)
	if parent != load_dlg.dir do load_dialog_chdir(strings.clone(parent, context.temp_allocator))
}

load_dialog_launch :: proc() {
	path, ok := load_dialog_selected()
	if !ok do return
	cands := load_dialog_candidates(path)
	if len(cands) == 0 {
		// Take the user straight to cores that can open it.
		if downloads_supported() {
			set_last_dir(load_dlg.dir)
			cores_dialog_find(extension(path))
		} else {
			message_box("NO CORE", "NO INSTALLED CORE OPENS THIS FILE.")
		}
		return
	}
	pick := cands[clamp(load_dlg.core_pick, 0, len(cands) - 1)]
	set_last_dir(load_dlg.dir)
	_ = launch_game(installed_cores[pick].path, path)
}

load_dialog :: proc(cv: ^Canvas, b: Rect) {
	dlg := &load_dlg
	label(cv, b.x, b.y, fit_text_tail(dlg.dir, b.w), theme.text_hi)

	list_h := b.h - 40
	dirs_w := max(60, b.w / 3)
	files_r := Rect{b.x, b.y + 10, b.w - dirs_w - 4, list_h}
	dirs_r := Rect{files_r.x + files_r.w + 4, files_r.y, dirs_w, list_h}
	visible := max(1, (list_h - 4) / LINE_H)

	file_names := make([]string, len(dlg.files), context.temp_allocator)
	for fi, i in dlg.files do file_names[i] = dlg.entries[fi].name
	dir_names := make([]string, len(dlg.dirs) + 1, context.temp_allocator)
	dir_names[0] = ".."
	for di, i in dlg.dirs do dir_names[i + 1] = dlg.entries[di].name

	// Keyboard: Tab switches lists, Backspace goes up, letters jump.
	if !ui.input_blocked && ui.focus == 0 {
		if consume_key(sdl.K_TAB) do dlg.focus_dirs = !dlg.focus_dirs
		if consume_key(sdl.K_BACKSPACE) do load_dialog_go_up()
		if dlg.focus_dirs {
			list_type_jump(&dlg.dir_list, dir_names, visible)
			if list_keys(&dlg.dir_list, len(dir_names), visible) do load_dialog_open_dir(dlg.dir_list.sel)
		} else {
			old := dlg.file_list.sel
			list_type_jump(&dlg.file_list, file_names, visible)
			if list_keys(&dlg.file_list, len(file_names), visible) {
				load_dialog_launch()
				return
			}
			if dlg.file_list.sel != old do dlg.core_pick = 0
		}
	}

	old_sel := dlg.file_list.sel
	fr := list_box(cv, files_r, file_names, &dlg.file_list, !dlg.focus_dirs)
	if fr.clicked do dlg.focus_dirs = false
	if dlg.file_list.sel != old_sel do dlg.core_pick = 0
	if fr.activated {
		load_dialog_launch()
		return
	}
	dir_colors := make([]Color, len(dir_names), context.temp_allocator)
	for &c in dir_colors do c = theme.text_hi
	dr := list_box(cv, dirs_r, dir_names, &dlg.dir_list, dlg.focus_dirs, dir_colors)
	if dr.clicked do dlg.focus_dirs = true
	if dr.activated {
		load_dialog_open_dir(dlg.dir_list.sel)
		return
	}

	y := files_r.y + files_r.h + 4
	if checkbox(cv, b.x, y, "SHOW ALL FILES", &dlg.show_all) {
		load_dialog_filter()
		dlg.file_list = {}
	}

	// Core picker for the selected file.
	y += 12
	path, has_file := load_dialog_selected()
	cands: []int
	if has_file do cands = load_dialog_candidates(path)
	core_label := "-"
	if len(cands) > 0 {
		dlg.core_pick = clamp(dlg.core_pick, 0, len(cands) - 1)
		core_label = installed_cores[cands[dlg.core_pick]].name
	} else if has_file {
		core_label = "NONE - LOAD TO FIND ONE"
	}
	label(cv, b.x, y + 2, "CORE:")
	step := stepper(cv, {b.x + 32, y, b.w - 32 - 50, 10}, core_label, len(cands) > 1)
	if step != 0 && len(cands) > 0 do dlg.core_pick = (dlg.core_pick + step + len(cands)) % len(cands)

	if button(cv, {b.x + b.w - 44, y - 1, 44, 12}, "LOAD", has_file) do load_dialog_launch()
	when IS_WEB {
		if button(cv, {b.x + b.w - 44, y - 15, 44, 12}, "IMPORT") do web_import_file(.Rom)
	}
}

load_dialog_open_dir :: proc(sel: int) {
	if sel == 0 {
		load_dialog_go_up()
	} else if sel > 0 && sel - 1 < len(load_dlg.dirs) {
		name := load_dlg.entries[load_dlg.dirs[sel - 1]].name
		load_dialog_chdir(join_path(load_dlg.dir, name, context.temp_allocator))
	}
}

// --- Pick state -------------------------------------------------------------

state_used: [10]bool

pick_state_open :: proc() {
	for i in 0 ..< 10 do state_used[i] = state_exists(i)
}

pick_state_dialog :: proc(cv: ^Canvas, b: Rect) {
	for i in 0 ..< 10 {
		r := Rect{b.x + (i % 5) * 30, b.y + (i / 5) * 22, 26, 18}
		if i == state_slot do rect_outline(cv, rect_inset(r, -2), theme.text_hi)
		if button(cv, r, fmt.tprintf("%d", i)) do state_slot = i
		if state_used[i] do fill_rect(cv, {r.x + r.w - 5, r.y + 2, 3, 3}, theme.text_hi)
	}
	if consume_key(sdl.K_LEFT)  do state_slot = (state_slot + 9) % 10
	if consume_key(sdl.K_RIGHT) do state_slot = (state_slot + 1) % 10
	y := b.y + 48
	if button(cv, {b.x, y, 70, 12}, "SAVE") {
		_ = state_save(state_slot)
		dialog_close()
		if app.gui_open do gui_toggle()
	}
	if button(cv, {b.x + 80, y, 70, 12}, "LOAD", state_used[state_slot]) || consume_key(sdl.K_RETURN) {
		if state_used[state_slot] {
			_ = state_load(state_slot)
			dialog_close()
			if app.gui_open do gui_toggle()
		}
	}
}

// --- Input -----------------------------------------------------------------

input_capture := -1 // button waiting for a key

input_dialog :: proc(cv: ^Canvas, b: Rect) {
	label(cv, b.x, b.y, "PLAYER 1 KEYBOARD", theme.text_hi)
	if input_capture >= 0 {
		for k in ui.keys {
			if k == sdl.K_ESCAPE do break
			sc := sdl.GetScancodeFromKey(k, nil)
			if sc != .UNKNOWN {
				settings.keys[input_capture] = sc
				input_capture = -1
				break
			}
		}
		if consume_key(sdl.K_ESCAPE) do input_capture = -1
		clear(&ui.keys)
	}
	for i in 0 ..< 12 {
		col := i / 6
		row := i % 6
		x := b.x + col * 110
		y := b.y + 11 + row * 13
		label(cv, x, y + 3, BUTTON_NAMES[i])
		sc := settings.keys[i]
		name := string(sdl.GetScancodeName(sc)) if sc != .UNKNOWN else "-"
		if input_capture == i do name = "PRESS KEY"
		if button(cv, {x + 40, y, 64, 11}, strings.to_upper(name, context.temp_allocator)) {
			input_capture = i
		}
	}
	y := b.y + 11 + 6 * 13 + 4
	if button(cv, {b.x, y, 60, 12}, "DEFAULTS") do settings.keys = DEFAULT_KEYS
	y += 18
	label(cv, b.x, y, "GAMEPADS", theme.text_hi)
	y += 10
	any := false
	for g, i in input.gamepads {
		if g == nil do continue
		any = true
		name := sdl.GetGamepadName(g)
		label(cv, b.x, y, fit_text(fmt.tprintf("%d: %s", i + 1, name), b.w))
		y += 9
	}
	if !any {
		label(cv, b.x, y, "NONE CONNECTED", theme.text_dim)
		y += 9
	}
	_ = checkbox(cv, b.x, b.y + b.h - 8, "LEFT STICK AS D-PAD", &settings.stick_as_dpad)
}

// --- Video -----------------------------------------------------------------

video_dialog :: proc(cv: ^Canvas, b: Rect) {
	label(cv, b.x, b.y, "SCALING", theme.text_hi)
	names := [Scale_Mode]string{.Aspect = "KEEP ASPECT", .Integer = "INTEGER", .Stretch = "STRETCH"}
	y := b.y + 10
	for m in Scale_Mode {
		if radio(cv, b.x, y, names[m], settings.scale_mode == m) do settings.scale_mode = m
		y += 10
	}
	y += 4
	_ = checkbox(cv, b.x, y, "BILINEAR FILTER", &settings.video_filter); y += 11
	if checkbox(cv, b.x, y, "FULLSCREEN", &settings.fullscreen) {
		_ = sdl.SetWindowFullscreen(app.window, settings.fullscreen)
	}
	y += 11
	if checkbox(cv, b.x, y, "VSYNC", &settings.vsync) {
		_ = sdl.SetRenderVSync(app.renderer, 1 if settings.vsync else 0)
	}
	y += 11
	_ = checkbox(cv, b.x, y, "SHOW FPS", &settings.show_fps)
}

// --- Sound -----------------------------------------------------------------

sound_dialog :: proc(cv: ^Canvas, b: Rect) {
	on := !settings.mute
	if checkbox(cv, b.x, b.y, "ENABLE SOUND", &on) do settings.mute = !on
	y := b.y + 14
	if audio.stream != nil {
		label(cv, b.x, y, fmt.tprintf("CORE RATE: %.0f HZ", audio.sample_rate), theme.text_dim)
		label(cv, b.x, y + 10, fmt.tprintf("LATENCY: %.0f MS", audio_queued_ms()), theme.text_dim)
	} else {
		label(cv, b.x, y, "NO GAME RUNNING", theme.text_dim)
	}
}

// --- Core options -------------------------------------------------------------

core_opt_list: List_State

core_options_dialog :: proc(cv: ^Canvas, b: Rect) {
	if !core_loaded {
		label(cv, b.x, b.y, "NO CORE LOADED", theme.text_dim)
		return
	}
	label(cv, b.x, b.y, fit_text(core.name, b.w), theme.text_hi)
	vis := make([dynamic]int, context.temp_allocator)
	for o, i in core.options do if o.visible && len(o.values) > 0 do append(&vis, i)

	area := Rect{b.x, b.y + 10, b.w, b.h - 36}
	panel(cv, area)
	row_h := 12
	visible := max(1, (area.h - 4) / row_h)
	st := &core_opt_list
	if mouse_in(area) && ui.wheel != 0 do st.scroll += ui.wheel * 2

	if !ui.input_blocked {
		_ = list_keys(st, len(vis), visible)
		if st.sel >= 0 && st.sel < len(vis) {
			o := &core.options[vis[st.sel]]
			if consume_key(sdl.K_LEFT)  do core_option_set(o, o.current - 1)
			if consume_key(sdl.K_RIGHT) do core_option_set(o, o.current + 1)
		}
	}
	scrollbar(cv, {area.x + area.w - SCROLLBAR_W - 1, area.y + 1, SCROLLBAR_W, area.h - 2}, &st.scroll, len(vis), visible)

	inner := Rect{area.x + 2, area.y + 2, area.w - SCROLLBAR_W - 5, area.h - 4}
	set_clip(cv, inner)
	val_w := min(120, inner.w / 2)
	for vi in st.scroll ..< min(len(vis), st.scroll + visible) {
		o := &core.options[vis[vi]]
		y := inner.y + (vi - st.scroll) * row_h
		row := Rect{inner.x, y, inner.w, row_h}
		if vi == st.sel do fill_rect(cv, row, shade(theme.select, 0.8))
		if clicked({row.x, row.y, row.w - val_w, row.h}) do st.sel = vi
		label(cv, row.x + 2, y + 3, fit_text(o.desc, row.w - val_w - 6))
		step := stepper(cv, {row.x + row.w - val_w, y + 1, val_w, row_h - 2}, o.values[o.current].label)
		if step != 0 {
			st.sel = vi
			core_option_set(o, o.current + step)
		}
	}
	reset_clip(cv)

	// Description of the selected option.
	if st.sel >= 0 && st.sel < len(vis) {
		info := core.options[vis[st.sel]].info
		lines := wrap_text(info, b.w)
		for l, i in lines[:min(2, len(lines))] do label(cv, b.x, area.y + area.h + 3 + i * 9, l, theme.text_dim)
	}
	if button(cv, {b.x + b.w - 60, b.y + b.h - 11, 60, 11}, "DEFAULTS") {
		for &o in core.options do core_option_set(&o, o.default_)
	}
}

// --- Cheats --------------------------------------------------------------------

Cheat :: struct {
	code:    string,
	desc:    string,
	enabled: bool,
}

cheats: [dynamic]Cheat
cheat_code_buf: [dynamic]u8
cheat_desc_buf: [dynamic]u8
cheat_list: List_State

cheats_apply :: proc() {
	if !core.game_loaded do return
	core.api.cheat_reset()
	idx: u32 = 0
	for ch in cheats {
		if !ch.enabled do continue
		core.api.cheat_set(idx, true, tcstr(ch.code))
		idx += 1
	}
}

cheat_add_dialog :: proc(cv: ^Canvas, b: Rect) {
	label(cv, b.x, b.y + 2, "CODE")
	sub1 := text_field(cv, {b.x + 36, b.y, b.w - 36, 11}, &cheat_code_buf, 64)
	label(cv, b.x, b.y + 18, "DESC")
	sub2 := text_field(cv, {b.x + 36, b.y + 16, b.w - 36, 11}, &cheat_desc_buf, 40)
	label(cv, b.x, b.y + 32, "GAME GENIE, PAR OR RAW CODES", theme.text_dim)
	if button(cv, {b.x + b.w - 50, b.y + b.h - 12, 50, 12}, "ADD", len(cheat_code_buf) > 0) || ((sub1 || sub2) && len(cheat_code_buf) > 0) {
		desc := string(cheat_desc_buf[:]) if len(cheat_desc_buf) > 0 else string(cheat_code_buf[:])
		append(&cheats, Cheat{code = strings.clone(string(cheat_code_buf[:])), desc = strings.clone(desc), enabled = true})
		cheats_apply()
		clear(&cheat_code_buf)
		clear(&cheat_desc_buf)
		osd_message("CHEAT ADDED")
	}
}

cheat_browse_dialog :: proc(cv: ^Canvas, b: Rect) {
	names := make([]string, len(cheats), context.temp_allocator)
	colors := make([]Color, len(cheats), context.temp_allocator)
	for ch, i in cheats {
		names[i] = fmt.tprintf("%s %s", "[X]" if ch.enabled else "[ ]", ch.desc)
		colors[i] = theme.text if ch.enabled else theme.text_dim
	}
	lr := Rect{b.x, b.y, b.w, b.h - 16}
	visible := (lr.h - 4) / LINE_H
	toggle := list_keys(&cheat_list, len(cheats), visible) || consume_key(sdl.K_SPACE)
	if list_box(cv, lr, names, &cheat_list, true, colors).activated do toggle = true
	sel := cheat_list.sel
	has := sel >= 0 && sel < len(cheats)
	y := b.y + b.h - 12
	if button(cv, {b.x, y, 60, 12}, "TOGGLE", has) do toggle = true
	if button(cv, {b.x + 66, y, 60, 12}, "REMOVE", has) {
		delete(cheats[sel].code); delete(cheats[sel].desc)
		ordered_remove(&cheats, sel)
		cheats_apply()
		return
	}
	if toggle && has {
		cheats[sel].enabled = !cheats[sel].enabled
		cheats_apply()
	}
	if len(cheats) == 0 do label(cv, lr.x + 6, lr.y + 6, "NO CHEATS - USE ADD CODE", theme.text_dim)
}

// --- Netplay -------------------------------------------------------------------

netplay_dialog :: proc(cv: ^Canvas, b: Rect) {
	for l, i in wrap_text("NETPLAY ISN'T AVAILABLE IN THIS VERSION.", b.w) {
		label(cv, b.x, b.y + i * 9, l)
	}
	if button(cv, {b.x + (b.w - 40) / 2, b.y + b.h - 12, 40, 12}, "OK") || consume_key(sdl.K_RETURN) do dialog_close()
}

// --- GUI options ---------------------------------------------------------------

gui_opts_dialog :: proc(cv: ^Canvas, b: Rect) {
	_ = checkbox(cv, b.x, b.y, "SNOW", &settings.snow)
	label(cv, b.x, b.y + 14, "WINDOW COLOR", theme.text_hi)
	names := [3]string{"R", "G", "B"}
	for i in 0 ..< 3 {
		y := b.y + 24 + i * 11
		label(cv, b.x, y + 2, names[i])
		v := int(settings.gui_color[i])
		if slider(cv, {b.x + 10, y, b.w - 40, 9}, &v, 255) do settings.gui_color[i] = u8(v)
		label(cv, b.x + b.w - 24, y + 2, fmt.tprintf("%d", v))
	}
	y := b.y + 60
	if button(cv, {b.x, y, 60, 11}, "DEFAULT") do settings.gui_color = {40, 56, 160}

	y += 18
	label(cv, b.x, y, "INTERFACE", theme.text_hi)
	y += 10
	opts := [UI_Override]string{.Auto = "AUTO", .Desktop = "DESKTOP", .Touch = "TOUCH"}
	x := b.x
	for o in UI_Override {
		if radio(cv, x, y, opts[o], settings.ui_override == o) {
			settings.ui_override = o
			ui.kind = gui_pick_kind()
		}
		x += 18 + text_width(opts[o])
	}
}

// --- About -----------------------------------------------------------------------

about_dialog :: proc(cv: ^Canvas, b: Rect) {
	lines := []struct{s: string, hi: bool}{
		{fmt.tprintf("ZEMU V%s", APP_VERSION), true},
		{"A LIBRETRO FRONTEND IN THE STYLE OF ZSNES", false},
		{"WRITTEN IN ODIN WITH SDL3", false},
		{"", false},
		{"KEYS", true},
		{"ESC      GUI / BACK TO GAME", false},
		{"F2 / F4  SAVE / LOAD STATE", false},
		{"F3       NEXT STATE SLOT", false},
		{"`        FAST FORWARD (HOLD)", false},
		{"F9       FAST FORWARD TOGGLE", false},
		{"P        PAUSE", false},
		{"F11      FULLSCREEN", false},
	}
	y := b.y
	for l in lines {
		label(cv, b.x, y, fit_text(l.s, b.w), theme.text_hi if l.hi else theme.text)
		y += 9
	}
	y += 4
	label(cv, b.x, y, "DATA:", theme.text_hi)
	label(cv, b.x + 34, y, fit_text_tail(paths.base, b.w - 34), theme.text_dim)
	if core_loaded {
		y += 9
		label(cv, b.x, y, "CORE:", theme.text_hi)
		label(cv, b.x + 34, y, fit_text(fmt.tprintf("%s %s", core.name, core.version), b.w - 34), theme.text_dim)
	}
}

message_dialog :: proc(cv: ^Canvas, b: Rect) {
	for l, i in wrap_text(ui.message, b.w) do label(cv, b.x, b.y + i * 9, l)
	if button(cv, {b.x + (b.w - 40) / 2, b.y + b.h - 12, 40, 12}, "OK") || consume_key(sdl.K_RETURN) do dialog_close()
}
