package zemu

// CORES window: download cores from the buildbot and manage installed ones.

import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"

Cores_Tab :: enum u8 {
	Download,
	Installed,
}

Cores_Dialog :: struct {
	tab:       Cores_Tab,
	installed: List_State,
	remote:    List_State,
	search:    [dynamic]u8,
}

cores_dlg: Cores_Dialog

cores_dialog_open :: proc() {
	cores_scan()
	if downloads_supported() && (dl.state == .Empty || dl.state == .Failed) do catalog_refresh()
	cores_dlg.tab = .Download if len(installed_cores) == 0 && downloads_supported() else .Installed
}

// Open the download list filtered to cores that open files of this type.
cores_dialog_find :: proc(ext: string) {
	dialog_open(.Cores)
	cores_dlg.tab = .Download
	clear(&cores_dlg.search)
	append(&cores_dlg.search, ..transmute([]u8)ext)
	cores_dlg.remote = {}
}

cores_dialog :: proc(cv: ^Canvas, b: Rect) {
	// Tabs
	tabs := [Cores_Tab]string{.Download = "DOWNLOAD", .Installed = fmt.tprintf("INSTALLED (%d)", len(installed_cores))}
	x := b.x
	for t in Cores_Tab {
		w := text_width(tabs[t]) + 12
		r := Rect{x, b.y, w, 11}
		sel := cores_dlg.tab == t
		fill_rect(cv, r, theme.button_hi if sel else shade(theme.button, 0.7))
		bevel(cv, r, theme.light, theme.dark)
		draw_text(cv, r.x + 6, r.y + 3, tabs[t], theme.text if sel else theme.text_dim)
		if clicked(r) {
			cores_dlg.tab = t
			focus_clear()
		}
		x += w + 2
	}
	hline(cv, b.x, b.y + 11, b.w, theme.light)
	if ui.focus == 0 && (consume_key(sdl.K_TAB)) {
		cores_dlg.tab = .Installed if cores_dlg.tab == .Download else .Download
	}

	body := Rect{b.x, b.y + 15, b.w, b.h - 15}
	switch cores_dlg.tab {
	case .Download:  download_tab(cv, body)
	case .Installed: installed_tab(cv, body)
	}
}

download_tab :: proc(cv: ^Canvas, b: Rect) {
	if !downloads_supported() {
		for l, i in wrap_text("CORE DOWNLOADS AREN'T AVAILABLE ON THIS PLATFORM. COPY CORES INTO THE CORES FOLDER:", b.w) {
			label(cv, b.x, b.y + i * 9, l)
		}
		label(cv, b.x, b.y + 30, fit_text_tail(paths.cores, b.w), theme.text_hi)
		return
	}

	label(cv, b.x, b.y + 2, "FIND")
	_ = text_field(cv, {b.x + 28, b.y, b.w - 28 - 56, 11}, &cores_dlg.search, 32)
	if button(cv, {b.x + b.w - 50, b.y, 50, 11}, "REFRESH", dl.state != .Loading && !download_busy()) do catalog_refresh()

	query := string(cores_dlg.search[:])
	rows := make([dynamic]int, context.temp_allocator)
	for rc, i in dl.remote do if remote_matches(rc, query) do append(&rows, i)

	names := make([]string, len(rows), context.temp_allocator)
	colors := make([]Color, len(rows), context.temp_allocator)
	for ri, i in rows {
		rc := dl.remote[ri]
		mark := "  "
		col := theme.text
		if dl.job != nil && dl.job_core == ri {
			mark = ICON_DOWN + " "
			col = theme.text_hi
		} else if slice_contains(dl.queue[:], ri) {
			mark = ". "
			col = theme.text_dim
		} else if remote_installed(rc) {
			mark = ICON_CHECK + " "
			col = theme.text_hi
		}
		names[i] = strings.concatenate({mark, rc.name}, context.temp_allocator)
		colors[i] = col
	}

	lr := Rect{b.x, b.y + 14, b.w, b.h - 14 - 34}
	st := &cores_dlg.remote
	visible := (lr.h - 4) / LINE_H
	enter := false
	if ui.focus == 0 do enter = list_keys(st, len(rows), visible)
	res := list_box(cv, lr, names, st, ui.focus == 0, colors)
	if res.clicked do focus_clear()

	switch dl.state {
	case .Empty, .Loading:
		label(cv, lr.x + 6, lr.y + 6, "LOADING CORE LIST...", theme.text_dim)
	case .Failed:
		label(cv, lr.x + 6, lr.y + 6, "COULD NOT GET THE CORE LIST", theme.text_dim)
		label(cv, lr.x + 6, lr.y + 15, "CHECK YOUR CONNECTION AND REFRESH", theme.text_dim)
	case .Ready:
		if len(rows) == 0 do label(cv, lr.x + 6, lr.y + 6, "NO MATCHING CORES", theme.text_dim)
	}

	sel := st.sel
	has := sel >= 0 && sel < len(rows)
	y := lr.y + lr.h + 3
	if dl.job != nil {
		rc := dl.remote[dl.job_core]
		label(cv, b.x, y, fit_text(fmt.tprintf("GETTING %s  %s", rc.id, format_size(dl.job.bytes)), b.w), theme.text_hi)
		// Unknown size: show an animated sweep.
		t := f32(ui.frame % 60) / 60
		progress_bar(cv, {b.x, y + 10, b.w - 66, 6}, t)
	} else if has {
		rc := dl.remote[rows[sel]]
		info := rc.system if rc.system != "" else rc.id
		label(cv, b.x, y, fit_text(info, b.w), theme.text_dim)
		if rc.extensions != "" {
			label(cv, b.x, y + 9, fit_text(strings.to_upper(rc.extensions, context.temp_allocator), b.w - 66), theme.text_dim)
		}
	}
	if has {
		rc := dl.remote[rows[sel]]
		txt := "UPDATE" if remote_installed(rc) else "DOWNLOAD"
		if button(cv, {b.x + b.w - 60, b.y + b.h - 13, 60, 12}, txt) || enter || res.activated {
			download_core(rows[sel])
		}
	}
}

installed_tab :: proc(cv: ^Canvas, b: Rect) {
	st := &cores_dlg.installed
	names := make([]string, len(installed_cores), context.temp_allocator)
	for e, i in installed_cores do names[i] = e.name
	lr := Rect{b.x, b.y, b.w, b.h - 30}
	visible := (lr.h - 4) / LINE_H
	enter := list_keys(st, len(names), visible)
	res := list_box(cv, lr, names, st, true)
	if len(names) == 0 {
		label(cv, lr.x + 6, lr.y + 6, "NO CORES INSTALLED", theme.text_dim)
		if downloads_supported() do label(cv, lr.x + 6, lr.y + 15, "GET SOME IN THE DOWNLOAD TAB", theme.text_dim)
	}
	sel := st.sel
	has := sel >= 0 && sel < len(installed_cores)
	y := b.y + b.h - 26
	if has {
		e := installed_cores[sel]
		exts := strings.to_upper(e.extensions, context.temp_allocator) if e.extensions != "" else "NO CONTENT NEEDED"
		label(cv, b.x, y, fit_text(exts, b.w), theme.text_dim)
	}
	y += 12
	can_start := has && installed_cores[sel].no_game
	if button(cv, {b.x, y, 50, 12}, "START", can_start) || (can_start && (enter || res.activated)) {
		if core_load(installed_cores[sel].path) && core_start_no_game() {
			ui.dialog = .None
			app.gui_open = false
			audio_pause(false)
			gui_update_cursor()
			return
		}
		message_box("ERROR", "THE CORE DID NOT START")
	}
	if button(cv, {b.x + 54, y, 50, 12}, "REMOVE", has) {
		path := installed_cores[sel].path
		if core_loaded && core.path == path do core_unload()
		_ = delete_file(path)
		cores_scan()
	}
	can_update := downloads_supported() && dl.state == .Ready && len(installed_cores) > 0 && !download_busy()
	if button(cv, {b.x + b.w - 70, y, 70, 12}, "UPDATE ALL", can_update) do update_all_cores()
}

slice_contains :: proc(s: []int, v: int) -> bool {
	for x in s do if x == v do return true
	return false
}

format_size :: proc(n: i64) -> string {
	if n >= 1024 * 1024 do return fmt.tprintf("%.1f MB", f64(n) / (1024 * 1024))
	if n >= 1024 do return fmt.tprintf("%d KB", n / 1024)
	return fmt.tprintf("%d B", n)
}
