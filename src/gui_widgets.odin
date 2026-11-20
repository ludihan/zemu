package zemu

// Immediate-mode widgets in the ZSNES look: bevelled buttons, sunken lists
// with arrow scrollbars, small check boxes and text fields.

import "core:strings"
import sdl "vendor:sdl3"

next_id :: proc() -> int {
	ui.id_counter += 1
	return ui.id_counter
}

mouse_in :: proc(r: Rect) -> bool {
	return !ui.input_blocked && rect_contains(r, ui.mx, ui.my)
}

// A completed click: pressed and released inside r.
clicked :: proc(r: Rect) -> bool {
	return !ui.input_blocked && ui.mouse_released && rect_contains(r, ui.mx, ui.my) && rect_contains(r, ui.press_x, ui.press_y)
}

held :: proc(r: Rect) -> bool {
	return !ui.input_blocked && ui.mouse_down && rect_contains(r, ui.mx, ui.my) && rect_contains(r, ui.press_x, ui.press_y)
}

// Returns true when the close box was clicked.
window_frame :: proc(cv: ^Canvas, title: string, r: Rect) -> (close: bool) {
	fill_rect(cv, {r.x + 3, r.y + 3, r.w, r.h}, rgba(0, 0, 0, 100)) // shadow
	vgradient(cv, r, theme.win_top, theme.win_bottom)
	rect_outline(cv, r, theme.border)
	bevel(cv, rect_inset(r, 1), theme.light, theme.dark)

	tb := title_bar_rect(r)
	vgradient(cv, tb, theme.title_top, theme.title_bottom)
	hline(cv, tb.x, tb.y + tb.h, tb.w, theme.dark)
	draw_text(cv, tb.x + 3, tb.y + 2, title, theme.text)

	cb := Rect{tb.x + tb.w - 10, tb.y + 1, 9, 7} // 5x5 glyph centred: 2px each side, 1px top/bottom
	hover := mouse_in(cb)
	fill_rect(cv, cb, theme.button_hi if hover else theme.button)
	bevel(cv, cb, theme.light, theme.dark, held(cb))
	draw_char(cv, cb.x + 2, cb.y + 1, 'X', theme.text)
	return clicked(cb)
}

title_bar_rect :: proc(r: Rect) -> Rect {
	return {r.x + 2, r.y + 2, r.w - 4, 9}
}

// Body area inside a window, below the title bar.
window_body :: proc(r: Rect) -> Rect {
	return {r.x + 5, r.y + 15, r.w - 10, r.h - 19}
}

label :: proc(cv: ^Canvas, x, y: int, s: string, col: Color = Color(0)) {
	draw_text(cv, x, y, s, col if col != 0 else theme.text)
}

button :: proc(cv: ^Canvas, r: Rect, text: string, enabled := true) -> bool {
	hover := enabled && mouse_in(r)
	down := enabled && held(r)
	fill_rect(cv, r, theme.button_hi if hover else theme.button)
	rect_outline(cv, rect_inset(r, -1), theme.border)
	bevel(cv, r, theme.light, theme.dark, down)
	t := text if len(text) == 1 else fit_text(text, r.w - 4)
	// Centre on the ink: text_width counts the gap after the last glyph.
	tx := r.x + (r.w - (text_width(t) - 1)) / 2 + (1 if down else 0)
	ty := r.y + (r.h - GLYPH_H) / 2 + (1 if down else 0)
	draw_text(cv, tx, ty, t, theme.text if enabled else theme.text_dim)
	return enabled && clicked(r)
}

checkbox :: proc(cv: ^Canvas, x, y: int, text: string, value: ^bool) -> bool {
	box := Rect{x, y, 7, 7}
	hit := Rect{x, y - 1, 10 + text_width(text), 9}
	fill_rect(cv, box, theme.list_bg)
	bevel(cv, box, theme.dark, theme.light)
	if value^ do draw_char(cv, x + 1, y + 1, ICON_CHECK[0], theme.text_hi)
	draw_text(cv, x + 10, y + 1, text, theme.text)
	if clicked(hit) {
		value^ = !value^
		return true
	}
	return false
}

// Round-ish radio button.
radio :: proc(cv: ^Canvas, x, y: int, text: string, selected: bool) -> bool {
	box := Rect{x, y, 7, 7}
	hit := Rect{x, y - 1, 10 + text_width(text), 9}
	fill_rect(cv, {x + 1, y, 5, 7}, theme.list_bg)
	fill_rect(cv, {x, y + 1, 7, 5}, theme.list_bg)
	hline(cv, x + 1, y, 5, theme.dark)
	vline(cv, x, y + 1, 5, theme.dark)
	hline(cv, x + 1, y + 6, 5, theme.light)
	vline(cv, x + 6, y + 1, 5, theme.light)
	if selected do fill_rect(cv, {x + 2, y + 2, 3, 3}, theme.text_hi)
	draw_text(cv, x + 10, y + 1, text, theme.text)
	_ = box
	return clicked(hit)
}

// "< VALUE >" selector. Returns -1/+1 when stepped.
stepper :: proc(cv: ^Canvas, r: Rect, value: string, enabled := true) -> int {
	lb := Rect{r.x, r.y, 9, r.h}
	rb := Rect{r.x + r.w - 9, r.y, 9, r.h}
	mid := Rect{r.x + 10, r.y, r.w - 20, r.h}
	fill_rect(cv, mid, theme.list_bg)
	bevel(cv, mid, theme.dark, theme.light)
	t := fit_text(value, mid.w - 4)
	draw_text(cv, mid.x + (mid.w - text_width(t)) / 2, mid.y + (mid.h - GLYPH_H) / 2, t, theme.text if enabled else theme.text_dim)
	step := 0
	if button(cv, lb, ICON_LEFT, enabled) do step = -1
	if button(cv, rb, ICON_RIGHT, enabled) do step = 1
	if enabled && clicked(mid) do step = 1
	return step
}

// Horizontal slider for 0..max_value. Returns true when changed.
slider :: proc(cv: ^Canvas, r: Rect, value: ^int, max_value: int) -> bool {
	id := next_id()
	fill_rect(cv, {r.x, r.y + r.h / 2 - 1, r.w, 3}, theme.list_bg)
	bevel(cv, {r.x, r.y + r.h / 2 - 1, r.w, 3}, theme.dark, theme.light)
	if !ui.input_blocked && ui.mouse_pressed && rect_contains(r, ui.mx, ui.my) do ui.slider_drag = id
	if !ui.mouse_down && ui.slider_drag == id do ui.slider_drag = 0
	changed := false
	if ui.slider_drag == id {
		v := clamp((ui.mx - r.x) * max_value / max(1, r.w - 1), 0, max_value)
		if v != value^ {
			value^ = v
			changed = true
		}
	}
	tx := r.x + value^ * (r.w - 5) / max(1, max_value)
	thumb := Rect{tx, r.y, 5, r.h}
	fill_rect(cv, thumb, theme.button_hi)
	bevel(cv, thumb, theme.light, theme.dark)
	return changed
}

// Sunken panel.
panel :: proc(cv: ^Canvas, r: Rect) {
	fill_rect(cv, r, theme.list_bg)
	bevel(cv, r, theme.dark, theme.light)
}

List_State :: struct {
	sel:    int,
	scroll: int,
}

SCROLLBAR_W :: 7

// Vertical scrollbar with arrow buttons. `total` rows, `visible` rows shown.
scrollbar :: proc(cv: ^Canvas, r: Rect, scroll: ^int, total, visible: int) {
	id := next_id()
	max_scroll := max(0, total - visible)
	up := Rect{r.x, r.y, r.w, 7}
	dn := Rect{r.x, r.y + r.h - 7, r.w, 7}
	track := Rect{r.x, r.y + 7, r.w, r.h - 14}
	fill_rect(cv, track, shade(theme.list_bg, 0.8))
	if button(cv, up, ICON_UP) do scroll^ -= 1
	if button(cv, dn, ICON_DOWN) do scroll^ += 1
	// Auto-repeat while an arrow is held.
	if ui.frame % 4 == 0 && held(up) do scroll^ -= 1
	if ui.frame % 4 == 0 && held(dn) do scroll^ += 1

	if max_scroll > 0 && track.h > 4 {
		th := max(5, track.h * visible / max(1, total))
		ty := track.y + (track.h - th) * scroll^ / max_scroll
		thumb := Rect{track.x, ty, track.w, th}
		if !ui.input_blocked && ui.mouse_pressed && rect_contains(track, ui.mx, ui.my) {
			if rect_contains(thumb, ui.mx, ui.my) {
				ui.scroll_drag = id
			} else {
				scroll^ += visible if ui.my > ty else -visible
			}
		}
		if !ui.mouse_down && ui.scroll_drag == id do ui.scroll_drag = 0
		if ui.scroll_drag == id {
			scroll^ = (ui.my - track.y - th / 2) * max_scroll / max(1, track.h - th)
		}
		fill_rect(cv, thumb, theme.button)
		bevel(cv, thumb, theme.light, theme.dark)
	}
	scroll^ = clamp(scroll^, 0, max_scroll)
}

List_Result :: struct {
	clicked:   bool, // selection changed by the mouse
	activated: bool, // double click
}

// List box. `colors` is optional, per row.
list_box :: proc(cv: ^Canvas, r: Rect, items: []string, st: ^List_State, focused := true, colors: []Color = nil) -> (res: List_Result) {
	panel(cv, r)
	if focused do rect_outline(cv, rect_inset(r, -1), theme.select)
	inner := Rect{r.x + 2, r.y + 2, r.w - 4 - SCROLLBAR_W, r.h - 4}
	visible := max(1, inner.h / LINE_H)

	if mouse_in(r) && ui.wheel != 0 do st.scroll += ui.wheel * 3
	scrollbar(cv, {r.x + r.w - SCROLLBAR_W - 1, r.y + 1, SCROLLBAR_W, r.h - 2}, &st.scroll, len(items), visible)
	st.sel = clamp(st.sel, -1, len(items) - 1)

	set_clip(cv, inner)
	for i in st.scroll ..< min(len(items), st.scroll + visible + 1) {
		y := inner.y + (i - st.scroll) * LINE_H
		row := Rect{inner.x, y, inner.w, LINE_H}
		if i == st.sel do fill_rect(cv, row, theme.select if focused else shade(theme.select, 0.7))
		col := theme.text
		if colors != nil && i < len(colors) && colors[i] != 0 do col = colors[i]
		draw_text(cv, row.x + 2, y + 1, fit_text(items[i], inner.w - 4), col)
		if clicked(row) {
			now := sdl.GetTicksNS()
			if ui.last_click_list == st && ui.last_click_item == i && now - ui.last_click_ns < 400_000_000 do res.activated = true
			ui.last_click_ns = now
			ui.last_click_item = i
			ui.last_click_list = st
			st.sel = i
			res.clicked = true
		}
	}
	reset_clip(cv)
	return
}

// Keyboard navigation for a focused list. Returns true on Enter.
list_keys :: proc(st: ^List_State, count, visible: int) -> bool {
	if count == 0 do return false
	moved := false
	if consume_key(sdl.K_UP)       { st.sel -= 1;       moved = true }
	if consume_key(sdl.K_DOWN)     { st.sel += 1;       moved = true }
	if consume_key(sdl.K_PAGEUP)   { st.sel -= visible; moved = true }
	if consume_key(sdl.K_PAGEDOWN) { st.sel += visible; moved = true }
	if consume_key(sdl.K_HOME)     { st.sel = 0;        moved = true }
	if consume_key(sdl.K_END)      { st.sel = count - 1; moved = true }
	if moved {
		st.sel = clamp(st.sel, 0, count - 1)
		list_reveal(st, visible)
	}
	return consume_key(sdl.K_RETURN)
}

list_reveal :: proc(st: ^List_State, visible: int) {
	if st.sel < st.scroll do st.scroll = st.sel
	if st.sel >= st.scroll + visible do st.scroll = st.sel - visible + 1
	st.scroll = max(0, st.scroll)
}

// Jump to the first item starting with the typed letter (ZSNES did this in
// its file browser). Uses this frame's text input.
list_type_jump :: proc(st: ^List_State, items: []string, visible: int, skip_prefix := 0) {
	t := strings.to_string(ui.text)
	if len(t) == 0 do return
	ch := t[0]
	if ch >= 'a' && ch <= 'z' do ch -= 32
	start := st.sel + 1
	for k in 0 ..< len(items) {
		i := (start + k) % len(items)
		name := items[i][min(skip_prefix, len(items[i])):]
		if len(name) == 0 do continue
		c0 := name[0]
		if c0 >= 'a' && c0 <= 'z' do c0 -= 32
		if c0 == ch {
			st.sel = i
			list_reveal(st, visible)
			return
		}
	}
}

// Single line text field. Returns true when Enter is pressed while focused.
text_field :: proc(cv: ^Canvas, r: Rect, buf: ^[dynamic]u8, max_len := 64) -> (submitted: bool) {
	id := next_id()
	if clicked(r) {
		ui.focus = id
		_ = sdl.StartTextInput(app.window)
	}
	focused := ui.focus == id
	panel(cv, r)
	if focused {
		rect_outline(cv, rect_inset(r, -1), theme.select)
		for ch in transmute([]u8)strings.to_string(ui.text) {
			if len(buf) < max_len && ch >= 32 && ch < 127 do append(buf, ch)
		}
		strings.builder_reset(&ui.text)
		if consume_key(sdl.K_BACKSPACE) && len(buf) > 0 do pop(buf)
		if consume_key(sdl.K_RETURN) do submitted = true
	}
	s := string(buf[:])
	vis := (r.w - 6) / CHAR_W
	if len(s) > vis do s = s[len(s) - vis:]
	draw_text(cv, r.x + 3, r.y + (r.h - GLYPH_H) / 2, s, theme.text)
	if focused && (ui.frame / 20) % 2 == 0 {
		cx := r.x + 3 + text_width(s)
		vline(cv, cx, r.y + 2, r.h - 4, theme.text_hi)
	}
	return
}

focus_clear :: proc() {
	if ui.focus != 0 {
		ui.focus = 0
		_ = sdl.StopTextInput(app.window)
	}
}

// Thin progress bar.
progress_bar :: proc(cv: ^Canvas, r: Rect, t: f32) {
	panel(cv, r)
	w := int(f32(r.w - 2) * clamp(t, 0, 1))
	vgradient(cv, {r.x + 1, r.y + 1, w, r.h - 2}, theme.title_top, theme.title_bottom)
}
