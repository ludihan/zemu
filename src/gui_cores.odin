package zemu

// CORES window: installed cores.

import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"

Cores_Dialog :: struct {
	installed: List_State,
}

cores_dlg: Cores_Dialog

cores_dialog_open :: proc() {
	cores_scan()
}

cores_dialog :: proc(cv: ^Canvas, b: Rect) {
	installed_tab(cv, b)
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
	}
	sel := st.sel
	has := sel >= 0 && sel < len(installed_cores)
	y := b.y + b.h - 26
	if has {
		e := installed_cores[sel]
		label(cv, b.x, y, fit_text(fmt.tprintf("FILES: %s", strings.to_upper(e.extensions, context.temp_allocator)), b.w), theme.text_dim)
	}
	y += 12
	can_start := has && installed_cores[sel].no_game
	if button(cv, {b.x, y, 56, 12}, "START", can_start) || (can_start && (enter || res.activated)) {
		if core_load(installed_cores[sel].path) && core_start_no_game() {
			ui.dialog = .None
			app.gui_open = false
			audio_pause(false)
			return
		}
		message_box("ERROR", "THE CORE DID NOT START")
	}
	if button(cv, {b.x + 62, y, 56, 12}, "REMOVE", has) {
		path := installed_cores[sel].path
		if core_loaded && core.path == path do core_unload()
		_ = delete_file(path)
		cores_scan()
	}
	_ = sdl.K_RETURN
}
