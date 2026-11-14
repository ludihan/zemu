package gui

// All widget rects/positions are relative to the current window's client
// area (or absolute when no window is current).

label :: proc(ctx: ^Context, x, y: i32, s: string, color: Maybe(Color) = nil) {
	p := to_screen(ctx, {x, y, 0, 0})
	text_shadowed(ctx, p.x, p.y, s, color.? or_else ctx.theme.text)
}

label_dim :: proc(ctx: ^Context, x, y: i32, s: string) {
	label(ctx, x, y, s, ctx.theme.text_dim)
}

// Horizontal etched separator.
separator :: proc(ctx: ^Context, x, y, w: i32) {
	p := to_screen(ctx, {x, y, w, 2})
	hline(ctx, p.x, p.y, w, ctx.theme.border_dark)
	hline(ctx, p.x, p.y + 1, w, ctx.theme.border_light)
}

// An etched frame with a caption, used to group related options.
group :: proc(ctx: ^Context, r: Rect, caption: string) {
	s := to_screen(ctx, r)
	t := &ctx.theme
	frame := Rect{s.x, s.y + 4, s.w, s.h - 4}
	outline_rect(ctx, {frame.x + 1, frame.y + 1, frame.w - 1, frame.h - 1}, t.border_light)
	outline_rect(ctx, {frame.x, frame.y, frame.w - 1, frame.h - 1}, t.border_dark)
	if caption != "" {
		cw := text_width(caption) + 4
		gradient_rect(ctx, {s.x + 6, s.y, cw, CELL_H}, t.window_top, t.window_top)
		text_shadowed(ctx, s.x + 8, s.y, caption, t.text_hot)
	}
}

button :: proc(ctx: ^Context, r: Rect, caption: string, enabled := true) -> bool {
	s := to_screen(ctx, r)
	t := &ctx.theme
	hot := enabled && hovered(ctx, s)
	down := enabled && held(ctx, s)
	top, bottom := t.button_top, t.button_bottom
	if hot {
		top, bottom = t.button_hot_top, t.button_hot_bottom
	}
	if down {
		top, bottom = bottom, top
	}
	gradient_rect(ctx, s, top, bottom)
	if down {
		bevel(ctx, s, t.border_dark, t.border_light)
	} else {
		bevel(ctx, s, t.border_light, t.border_dark)
	}
	tw := text_width(caption)
	tx := s.x + (s.w - tw) / 2 + (down ? 1 : 0)
	ty := s.y + (s.h - CELL_H) / 2 + 1 + (down ? 1 : 0)
	text_shadowed(ctx, tx, ty, caption, enabled ? t.text : t.text_dim)
	return enabled && clicked(ctx, s)
}

@(private = "file")
check_box_frame :: proc(ctx: ^Context, s: Rect) {
	t := &ctx.theme
	fill_rect(ctx, s, t.field)
	bevel(ctx, s, t.border_dark, t.border_light)
}

checkbox :: proc(ctx: ^Context, x, y: i32, caption: string, value: ^bool) -> bool {
	t := &ctx.theme
	box := to_screen(ctx, {x, y, 9, 9})
	hit := Rect{box.x, box.y, 12 + text_width(caption), 9}
	check_box_frame(ctx, box)
	if value^ {
		symbol(ctx, box.x + 2, box.y, .Check, t.text_hot)
	}
	hot := hovered(ctx, hit)
	text_shadowed(ctx, box.x + 13, box.y + 1, caption, hot ? t.text_hot : t.text)
	if clicked(ctx, hit) {
		value^ = !value^
		return true
	}
	return false
}

radio :: proc(ctx: ^Context, x, y: i32, caption: string, selected: bool) -> bool {
	t := &ctx.theme
	box := to_screen(ctx, {x, y, 9, 9})
	hit := Rect{box.x, box.y, 12 + text_width(caption), 9}
	check_box_frame(ctx, box)
	if selected {
		symbol(ctx, box.x + 2, box.y, .Dot, t.text_hot)
	}
	hot := hovered(ctx, hit)
	text_shadowed(ctx, box.x + 13, box.y + 1, caption, hot ? t.text_hot : t.text)
	return clicked(ctx, hit)
}

// "<  value  >" selector. Returns -1, 0 or +1.
stepper :: proc(ctx: ^Context, r: Rect, value: string) -> int {
	t := &ctx.theme
	s := to_screen(ctx, r)
	left := Rect{s.x, s.y, 10, s.h}
	right := Rect{s.x + s.w - 10, s.y, 10, s.h}
	mid := Rect{s.x + 10, s.y, s.w - 20, s.h}
	fill_rect(ctx, mid, t.field)
	bevel(ctx, mid, t.border_dark, t.border_light)
	tw := text_width(value)
	text_fit(ctx, mid.x + max((mid.w - tw) / 2, 2), mid.y + (mid.h - CELL_H) / 2 + 1, mid.w - 4, value, t.text)

	result := 0
	for b, i in ([2]Rect{left, right}) {
		hot := hovered(ctx, b)
		gradient_rect(ctx, b, hot ? t.button_hot_top : t.button_top, hot ? t.button_hot_bottom : t.button_bottom)
		bevel(ctx, b, t.border_light, t.border_dark)
		symbol(ctx, b.x + 2, b.y + (b.h - CELL_H) / 2 + 1, i == 0 ? .Arrow_Left : .Arrow_Right, t.text)
		if clicked(ctx, b) {
			result = i == 0 ? -1 : 1
		}
	}
	return result
}

// A horizontal slider for an integer in [lo, hi]. Returns true while changed.
slider :: proc(ctx: ^Context, r: Rect, value: ^int, lo, hi: int) -> bool {
	t := &ctx.theme
	s := to_screen(ctx, r)
	track := Rect{s.x, s.y + s.h / 2 - 2, s.w, 4}
	fill_rect(ctx, track, t.field)
	bevel(ctx, track, t.border_dark, t.border_light)
	span := max(hi - lo, 1)
	knob_x := s.x + i32(f32(value^ - lo) / f32(span) * f32(s.w - 6))
	knob := Rect{knob_x, s.y, 6, s.h}
	gradient_rect(ctx, knob, t.button_hot_top, t.button_bottom)
	bevel(ctx, knob, t.border_light, t.border_dark)
	if held(ctx, s) {
		f := f32(ctx.mouse.x - s.x - 3) / f32(max(s.w - 6, 1))
		v := lo + int(f * f32(span) + 0.5)
		v = clamp(v, lo, hi)
		if v != value^ {
			value^ = v
			return true
		}
	}
	return false
}

// --- list box --------------------------------------------------------------

List_Item :: struct {
	text:  string,
	icon:  Maybe(Symbol),
	color: Maybe(Color),
}

List_State :: struct {
	selected:   int,
	scroll:     int,
	drag_thumb: bool,
}

List_Result :: struct {
	activated:  bool, // double-click or Enter on `selected`
	changed:    bool, // selection moved
}

ROW_H :: CELL_H + 1

// A scrolling list with keyboard navigation (arrows, PgUp/PgDn, Home/End,
// Enter, type-to-jump) when `keyboard` is true.
list_box :: proc(ctx: ^Context, state: ^List_State, r: Rect, items: []List_Item, keyboard := true) -> (res: List_Result) {
	t := &ctx.theme
	s := to_screen(ctx, r)
	fill_rect(ctx, s, t.field)
	bevel(ctx, s, t.border_dark, t.border_light)

	inner := rect_inset(s, 1)
	visible := max(int(inner.h / ROW_H), 1)
	count := len(items)
	old := state.selected
	state.selected = clamp(state.selected, 0, max(count - 1, 0))

	// keyboard
	if keyboard && has_keyboard(ctx) && count > 0 {
		for k in keys(ctx) {
			#partial switch k.scancode {
			case .UP:       state.selected -= 1
			case .DOWN:     state.selected += 1
			case .PAGEUP:   state.selected -= visible - 1
			case .PAGEDOWN: state.selected += visible - 1
			case .HOME:     state.selected = 0
			case .END:      state.selected = count - 1
			case .RETURN, .KP_ENTER:
				res.activated = true
			}
		}
		// Type a letter to jump to the next item starting with it.
		for ch in typed_text(ctx) {
			lower := to_lower(ch)
			for step in 1 ..= count {
				i := (state.selected + step) % count
				name := items[i].text
				if len(name) > 0 && to_lower(rune(name[0])) == lower {
					state.selected = i
					break
				}
			}
		}
		state.selected = clamp(state.selected, 0, count - 1)
	}

	// mouse wheel
	if hovered(ctx, s) && ctx.wheel != 0 {
		state.scroll -= int(ctx.wheel) * 3
	}

	// keep the selection visible after keyboard moves
	if state.selected != old {
		if state.selected < state.scroll {state.scroll = state.selected}
		if state.selected >= state.scroll + visible {state.scroll = state.selected - visible + 1}
	}

	needs_bar := count > visible
	bar_w: i32 = needs_bar ? 9 : 0
	rows := Rect{inner.x, inner.y, inner.w - bar_w, inner.h}

	// scrollbar
	if needs_bar {
		bar := Rect{inner.x + inner.w - bar_w, inner.y, bar_w, inner.h}
		up := Rect{bar.x, bar.y, bar_w, 9}
		down := Rect{bar.x, bar.y + bar.h - 9, bar_w, 9}
		track := Rect{bar.x, up.y + 9, bar_w, bar.h - 18}
		fill_rect(ctx, track, t.window_bottom)
		for b, i in ([2]Rect{up, down}) {
			gradient_rect(ctx, b, t.button_top, t.button_bottom)
			bevel(ctx, b, t.border_light, t.border_dark)
			symbol(ctx, b.x + 2, b.y, i == 0 ? .Arrow_Up : .Arrow_Down, t.text)
			if clicked(ctx, b) {
				state.scroll += i == 0 ? -1 : 1
			}
		}
		max_scroll := count - visible
		thumb_h := max(track.h * i32(visible) / i32(count), 6)
		travel := track.h - thumb_h
		if ctx.mouse_pressed && hovered(ctx, track) {
			state.drag_thumb = true
		}
		if !ctx.mouse_down {
			state.drag_thumb = false
		}
		if state.drag_thumb && has_mouse(ctx) {
			f := f32(ctx.mouse.y - track.y - thumb_h / 2) / f32(max(travel, 1))
			state.scroll = int(f * f32(max_scroll) + 0.5)
		}
		state.scroll = clamp(state.scroll, 0, max_scroll)
		thumb_y := track.y + (max_scroll > 0 ? travel * i32(state.scroll) / i32(max_scroll) : 0)
		thumb := Rect{track.x, thumb_y, bar_w, thumb_h}
		gradient_rect(ctx, thumb, t.button_hot_top, t.button_bottom)
		bevel(ctx, thumb, t.border_light, t.border_dark)
	} else {
		state.scroll = 0
	}
	state.scroll = clamp(state.scroll, 0, max(count - visible, 0))

	// rows
	set_clip(ctx, rows)
	for i in state.scroll ..< min(state.scroll + visible, count) {
		item := items[i]
		row := Rect{rows.x, rows.y + i32(i - state.scroll) * ROW_H, rows.w, ROW_H}
		color := item.color.? or_else t.text
		if i == state.selected {
			fill_rect(ctx, row, t.selection)
			color = t.selection_text
		} else if hovered(ctx, row) {
			fill_rect(ctx, row, {t.selection.r, t.selection.g, t.selection.b, 70})
		}
		tx := row.x + 2
		if icon, ok := item.icon.?; ok {
			symbol(ctx, tx, row.y + 1, icon, t.text_hot)
			tx += CELL_W + 2
		}
		text_fit(ctx, tx, row.y + 1, row.x + row.w - tx - 1, item.text, color)
		if hovered(ctx, row) && ctx.mouse_pressed {
			state.selected = i
			if ctx.double_click {
				res.activated = true
			}
		}
	}
	if current := ctx.current; current != nil {
		// restore the window clip
		w := current.rect
		set_clip(ctx, Rect{w.x + 1, w.y + TITLE_H, w.w - 2, w.h - TITLE_H - 1})
	} else {
		set_clip(ctx, nil)
	}
	res.changed = state.selected != old
	return
}

@(private = "file")
to_lower :: #force_inline proc(r: rune) -> rune {
	return r >= 'A' && r <= 'Z' ? r + 32 : r
}

// A read-only text box (single line).
text_box :: proc(ctx: ^Context, r: Rect, s: string) {
	t := &ctx.theme
	sr := to_screen(ctx, r)
	fill_rect(ctx, sr, t.field)
	bevel(ctx, sr, t.border_dark, t.border_light)
	// show the end of long strings (paths)
	max_chars := int((sr.w - 4) / CELL_W)
	n := 0
	for _ in s {n += 1}
	str := s
	if n > max_chars && max_chars > 1 {
		skip := n - max_chars + 1
		idx := 0
		count := 0
		for _, i in s {
			if count == skip {
				idx = i
				break
			}
			count += 1
		}
		str = s[idx:]
		text(ctx, sr.x + 2, sr.y + (sr.h - CELL_H) / 2 + 1, "~", t.text_dim)
		text_shadowed(ctx, sr.x + 2 + CELL_W, sr.y + (sr.h - CELL_H) / 2 + 1, str, t.text)
		return
	}
	text_shadowed(ctx, sr.x + 2, sr.y + (sr.h - CELL_H) / 2 + 1, str, t.text)
}

// Shows a key-binding field; returns true when clicked (start rebinding).
binding :: proc(ctx: ^Context, r: Rect, s: string, waiting: bool) -> bool {
	t := &ctx.theme
	sr := to_screen(ctx, r)
	hot := hovered(ctx, sr)
	fill_rect(ctx, sr, waiting ? t.selection : (hot ? Color{t.selection.r, t.selection.g, t.selection.b, 90} : t.field))
	bevel(ctx, sr, t.border_dark, t.border_light)
	shown := s
	if waiting {
		blink := int(ctx.time * 3) % 2 == 0
		shown = blink ? "PRESS..." : ""
	}
	text_fit(ctx, sr.x + 3, sr.y + (sr.h - CELL_H) / 2 + 1, sr.w - 5, shown, waiting ? t.selection_text : t.text)
	return clicked(ctx, sr)
}
