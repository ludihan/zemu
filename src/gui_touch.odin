package zemu

// Touch interface (filled in with the mobile UI).

import sdl "vendor:sdl3"

touch_event :: proc(e: ^sdl.Event) {}

touch_layout :: proc(ow, oh: int) {
	ui.scale = max(1, min(ow / GUI_BASE_W, oh / GUI_BASE_H))
	canvas_resize(&ui.cv, max(1, ow / ui.scale), max(1, oh / ui.scale))
}

touch_game_area :: proc(w, h: f32) -> sdl.FRect {
	return {0, 0, w, h}
}

touch_frame :: proc() {
	if app.gui_open do desktop_frame()
	else {
		canvas_clear(&ui.cv, Color(0))
		draw_osd()
	}
}
