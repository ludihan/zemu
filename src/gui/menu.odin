package gui

MENU_BAR_H :: 13

Menu_Item :: struct {
	label:     string,
	shortcut:  string,
	checked:   bool,
	disabled:  bool,
	separator: bool, // draws a divider instead of an item
}

Menu :: struct {
	title: string,
	items: []Menu_Item,
}

Menu_State :: struct {
	open:     int, // index of the open menu, -1 when closed
	hot_item: int,
}

menu_is_open :: proc(ctx: ^Context) -> bool {
	return ctx.menu.open >= 0
}

menu_close :: proc(ctx: ^Context) {
	ctx.menu.open = -1
	ctx.menu.hot_item = -1
}

menu_open :: proc(ctx: ^Context, index: int) {
	ctx.menu.open = index
	ctx.menu.hot_item = -1
}

@(private = "file")
menu_title_rect :: proc(menus: []Menu, index: int) -> Rect {
	x: i32 = 4
	for m, i in menus {
		w := text_width(m.title) + 12
		if i == index {
			return {x, 0, w, MENU_BAR_H}
		}
		x += w
	}
	return {}
}

@(private = "file")
dropdown_rect :: proc(menus: []Menu, index: int) -> Rect {
	title := menu_title_rect(menus, index)
	m := menus[index]
	w: i32 = 60
	h: i32 = 4
	for it in m.items {
		if it.separator {
			h += 4
			continue
		}
		iw := text_width(it.label) + 30
		if it.shortcut != "" {
			iw += text_width(it.shortcut) + 12
		}
		w = max(w, iw)
		h += ROW_H + 1
	}
	return {title.x, MENU_BAR_H, w, h}
}

@(private = "file")
selectable :: proc(it: Menu_Item) -> bool {
	return !it.separator && !it.disabled
}

// Draws the menu bar (call last so dropdowns appear on top of windows).
// Returns the chosen (menu, item) indices, or (-1, -1).
menu_bar :: proc(ctx: ^Context, menus: []Menu, right_text: string) -> (chosen_menu, chosen_item: int) {
	chosen_menu, chosen_item = -1, -1
	t := &ctx.theme
	bar := Rect{0, 0, ctx.size.x, MENU_BAR_H}
	gradient_rect(ctx, bar, t.menu_top, t.menu_bottom)
	hline(ctx, 0, MENU_BAR_H - 1, ctx.size.x, t.border_dark)
	hline(ctx, 0, 0, ctx.size.x, t.border_light)
	if right_text != "" {
		text_shadowed(ctx, ctx.size.x - text_width(right_text) - 6, 3, right_text, t.text_dim)
	}

	mouse_free := ctx.input_window == nil || menu_is_open(ctx)
	st := &ctx.menu

	for m, i in menus {
		r := menu_title_rect(menus, i)
		over := mouse_free && rect_contains(r, ctx.mouse)
		if i == st.open {
			fill_rect(ctx, r, t.menu_highlight)
			bevel(ctx, r, t.border_dark, t.border_light)
		} else if over {
			bevel(ctx, r, t.border_light, t.border_dark)
		}
		text_shadowed(ctx, r.x + 6, r.y + 3, m.title, i == st.open ? t.title_text : t.text)
		if over && ctx.mouse_pressed {
			if st.open == i {
				menu_close(ctx)
			} else {
				menu_open(ctx, i)
			}
			ctx.mouse_pressed = false
		} else if over && st.open >= 0 && st.open != i {
			menu_open(ctx, i) // slide between menus while open
		}
	}

	if st.open < 0 || st.open >= len(menus) {
		st.open = -1
		return
	}

	m := menus[st.open]
	drop := dropdown_rect(menus, st.open)

	// keyboard navigation
	for k in keys(ctx) {
		#partial switch k.scancode {
		case .LEFT:
			menu_open(ctx, (st.open + len(menus) - 1) % len(menus))
			return
		case .RIGHT:
			menu_open(ctx, (st.open + 1) % len(menus))
			return
		case .UP, .DOWN:
			dir := k.scancode == .UP ? -1 : 1
			n := len(m.items)
			for step in 1 ..= n {
				i := ((st.hot_item < 0 ? (dir > 0 ? -1 : 0) : st.hot_item) + dir * step + n * 4) % n
				if selectable(m.items[i]) {
					st.hot_item = i
					break
				}
			}
		case .RETURN, .KP_ENTER:
			if st.hot_item >= 0 && st.hot_item < len(m.items) && selectable(m.items[st.hot_item]) {
				chosen_menu, chosen_item = st.open, st.hot_item
				menu_close(ctx)
				consume_keys(ctx)
				return
			}
		}
	}

	fill_rect(ctx, {drop.x + 3, drop.y + 3, drop.w, drop.h}, {0, 0, 0, 90})
	gradient_rect(ctx, drop, t.menu_top, t.menu_bottom)
	bevel(ctx, drop, t.border_light, t.border_dark)

	y := drop.y + 2
	for it, i in m.items {
		if it.separator {
			hline(ctx, drop.x + 3, y + 1, drop.w - 6, t.border_dark)
			hline(ctx, drop.x + 3, y + 2, drop.w - 6, t.border_light)
			y += 4
			continue
		}
		row := Rect{drop.x + 2, y, drop.w - 4, ROW_H + 1}
		over := rect_contains(row, ctx.mouse)
		if over {
			st.hot_item = i
		}
		color := it.disabled ? t.text_dim : t.text
		if i == st.hot_item && !it.disabled {
			fill_rect(ctx, row, t.menu_highlight)
			color = t.title_text
		}
		if it.checked {
			symbol(ctx, row.x + 3, row.y + 1, .Check, t.text_hot)
		}
		text_shadowed(ctx, row.x + 14, row.y + 2, it.label, color)
		if it.shortcut != "" {
			text_shadowed(ctx, row.x + row.w - text_width(it.shortcut) - 4, row.y + 2, it.shortcut, t.text_dim)
		}
		if over && ctx.mouse_released && selectable(it) {
			chosen_menu, chosen_item = st.open, i
		}
		y += ROW_H + 1
	}

	if chosen_menu >= 0 {
		menu_close(ctx)
	} else if ctx.mouse_pressed && !rect_contains(drop, ctx.mouse) && !rect_contains(bar, ctx.mouse) {
		menu_close(ctx) // click outside
	}
	return
}

