// Package gui is a small immediate-mode widget toolkit drawn directly with the
// SDL renderer, styled after classic DOS-era emulator menus: bevelled
// gradient windows, a pixel font and a top menu bar.
//
// All coordinates are in "UI pixels". The user picks an integer UI scale and
// the toolkit never resizes itself to fit the window: a larger window simply
// shows more desktop.
package gui

import "core:strings"
import sdl "vendor:sdl3"

Color :: [4]u8

Rect :: struct {
	x, y, w, h: i32,
}

rect_contains :: #force_inline proc(r: Rect, p: [2]i32) -> bool {
	return p.x >= r.x && p.y >= r.y && p.x < r.x + r.w && p.y < r.y + r.h
}

rect_inset :: #force_inline proc(r: Rect, n: i32) -> Rect {
	return {r.x + n, r.y + n, max(r.w - 2 * n, 0), max(r.h - 2 * n, 0)}
}

MAX_WINDOWS :: 16
MAX_KEYS    :: 32
TITLE_H     :: 13

Window :: struct {
	title: string,
	rect:  Rect,
	open:  bool,
}

Key_Press :: struct {
	scancode: sdl.Scancode,
	key:      sdl.Keycode,
	mod:      sdl.Keymod,
	repeat:   bool,
}

Context :: struct {
	renderer:       ^sdl.Renderer,
	font:           ^sdl.Texture,
	theme:          Theme,
	scale:          i32,
	size:           [2]i32, // UI pixels visible this frame
	time:           f64,

	// input, in UI pixels
	mouse:          [2]i32,
	press_pos:      [2]i32,
	mouse_down:     bool,
	mouse_pressed:  bool,
	mouse_released: bool,
	double_click:   bool,
	wheel:          i32,
	keys:           [MAX_KEYS]Key_Press,
	key_count:      int,
	text:           [64]u8,
	text_len:       int,

	// window management
	order:          [MAX_WINDOWS]^Window, // back to front
	order_count:    int,
	input_window:   ^Window, // window that receives mouse input this frame
	current:        ^Window,
	origin:         [2]i32,  // top-left of the current window's client area
	drag_window:    ^Window,
	drag_offset:    [2]i32,
	// True while an overlay (the open menu) owns the mouse.
	capture_mouse:  bool,
	menu:           Menu_State,
	// The text field that has keyboard focus (nil when none). While set, the
	// application should not treat key presses as shortcuts.
	text_focus:     ^Text_Field,
}

init :: proc(ctx: ^Context, renderer: ^sdl.Renderer) -> bool {
	ctx.renderer = renderer
	ctx.scale = 2
	ctx.theme = THEMES[0]
	ctx.menu = {open = -1, hot_item = -1}

	w := GLYPH_COUNT * CELL_W
	h := CELL_H
	pixels := make([]u32, w * h, context.temp_allocator)
	font_rasterize(pixels)
	ctx.font = sdl.CreateTexture(renderer, .ARGB8888, .STATIC, i32(w), i32(h))
	if ctx.font == nil {
		return false
	}
	sdl.UpdateTexture(ctx.font, nil, raw_data(pixels), i32(w * 4))
	sdl.SetTextureBlendMode(ctx.font, {.BLEND})
	sdl.SetTextureScaleMode(ctx.font, .NEAREST)
	return true
}

destroy :: proc(ctx: ^Context) {
	if ctx.font != nil {
		sdl.DestroyTexture(ctx.font)
		ctx.font = nil
	}
}

// --- input -----------------------------------------------------------------

// Feeds an SDL event to the toolkit. Coordinates are in window pixels.
handle_event :: proc(ctx: ^Context, e: ^sdl.Event) {
	s := f32(max(ctx.scale, 1))
	#partial switch e.type {
	case .MOUSE_MOTION:
		ctx.mouse = {i32(e.motion.x / s), i32(e.motion.y / s)}
	case .MOUSE_BUTTON_DOWN:
		if e.button.button == sdl.BUTTON_LEFT {
			ctx.mouse = {i32(e.button.x / s), i32(e.button.y / s)}
			ctx.mouse_down = true
			ctx.mouse_pressed = true
			ctx.press_pos = ctx.mouse
			ctx.double_click = e.button.clicks >= 2
		}
	case .MOUSE_BUTTON_UP:
		if e.button.button == sdl.BUTTON_LEFT {
			ctx.mouse = {i32(e.button.x / s), i32(e.button.y / s)}
			ctx.mouse_down = false
			ctx.mouse_released = true
		}
	case .MOUSE_WHEEL:
		ctx.wheel += i32(e.wheel.integer_y)
	case .KEY_DOWN:
		if ctx.key_count < MAX_KEYS {
			ctx.keys[ctx.key_count] = {e.key.scancode, e.key.key, e.key.mod, e.key.repeat}
			ctx.key_count += 1
		}
	case .TEXT_INPUT:
		if e.text.text != nil {
			t := string(e.text.text)
			n := copy(ctx.text[ctx.text_len:], t)
			ctx.text_len += n
		}
	}
}

// Begins a UI frame. `pixel_w`/`pixel_h` is the renderer output size.
begin :: proc(ctx: ^Context, pixel_w, pixel_h: i32, time: f64) {
	ctx.scale = clamp(ctx.scale, 1, 8)
	ctx.size = {pixel_w / ctx.scale, pixel_h / ctx.scale}
	ctx.time = time
	ctx.current = nil
	ctx.origin = {}

	// Keep every window reachable after the OS window shrinks or the scale grows.
	for i in 0 ..< ctx.order_count {
		clamp_window(ctx, ctx.order[i])
	}

	// Topmost open window under the mouse gets the mouse.
	ctx.capture_mouse = menu_is_open(ctx)
	ctx.input_window = nil
	if !ctx.capture_mouse {
		for i := ctx.order_count - 1; i >= 0; i -= 1 {
			w := ctx.order[i]
			if w.open && rect_contains(w.rect, ctx.mouse) {
				ctx.input_window = w
				break
			}
		}
	}
	if ctx.drag_window != nil {
		ctx.input_window = ctx.drag_window
	}
	if ctx.mouse_pressed && ctx.input_window != nil {
		bring_to_front(ctx, ctx.input_window)
	}

	sdl.SetRenderScale(ctx.renderer, f32(ctx.scale), f32(ctx.scale))
	sdl.SetRenderDrawBlendMode(ctx.renderer, {.BLEND})
}

// Ends a UI frame and clears per-frame input.
end :: proc(ctx: ^Context) {
	if !ctx.mouse_down {
		ctx.drag_window = nil
	}
	ctx.mouse_pressed = false
	ctx.mouse_released = false
	ctx.double_click = false
	ctx.wheel = 0
	ctx.key_count = 0
	ctx.text_len = 0
	sdl.SetRenderScale(ctx.renderer, 1, 1)
}

// Keys pressed this frame, for the focused (topmost) window or global hotkeys.
keys :: proc(ctx: ^Context) -> []Key_Press {
	return ctx.keys[:ctx.key_count]
}

key_pressed :: proc(ctx: ^Context, sc: sdl.Scancode) -> bool {
	for k in keys(ctx) {
		if k.scancode == sc {return true}
	}
	return false
}

// Removes all queued key presses (after a widget consumed them).
consume_keys :: proc(ctx: ^Context) {
	ctx.key_count = 0
}

typed_text :: proc(ctx: ^Context) -> string {
	return string(ctx.text[:ctx.text_len])
}

// --- window stack ----------------------------------------------------------

@(private = "file")
find_window :: proc(ctx: ^Context, w: ^Window) -> int {
	for i in 0 ..< ctx.order_count {
		if ctx.order[i] == w {return i}
	}
	return -1
}

// Registers a window with the toolkit (once, at startup).
add_window :: proc(ctx: ^Context, w: ^Window) {
	if find_window(ctx, w) >= 0 || ctx.order_count >= MAX_WINDOWS {
		return
	}
	ctx.order[ctx.order_count] = w
	ctx.order_count += 1
}

bring_to_front :: proc(ctx: ^Context, w: ^Window) {
	i := find_window(ctx, w)
	if i < 0 {
		return
	}
	for j in i ..< ctx.order_count - 1 {
		ctx.order[j] = ctx.order[j + 1]
	}
	ctx.order[ctx.order_count - 1] = w
}

open_window :: proc(ctx: ^Context, w: ^Window) {
	w.open = true
	bring_to_front(ctx, w)
	clamp_window(ctx, w)
}

// Windows from back to front.
window_order :: proc(ctx: ^Context) -> []^Window {
	return ctx.order[:ctx.order_count]
}

// The open window that has keyboard focus, or nil.
focused_window :: proc(ctx: ^Context) -> ^Window {
	for i := ctx.order_count - 1; i >= 0; i -= 1 {
		if ctx.order[i].open {return ctx.order[i]}
	}
	return nil
}

any_window_open :: proc(ctx: ^Context) -> bool {
	return focused_window(ctx) != nil
}

center_window :: proc(ctx: ^Context, w: ^Window) {
	w.rect.x = (ctx.size.x - w.rect.w) / 2
	w.rect.y = max((ctx.size.y - w.rect.h) / 2, MENU_BAR_H + 2)
}

@(private = "file")
clamp_window :: proc(ctx: ^Context, w: ^Window) {
	if ctx.size.x <= 0 || ctx.size.y <= 0 {
		return
	}
	w.rect.x = clamp(w.rect.x, 24 - w.rect.w, max(ctx.size.x - 24, 0))
	w.rect.y = clamp(w.rect.y, MENU_BAR_H, max(ctx.size.y - TITLE_H, MENU_BAR_H))
}

// Draws a window frame and makes it current. Returns false when closed;
// do not call end_window in that case.
begin_window :: proc(ctx: ^Context, w: ^Window) -> bool {
	if !w.open {
		return false
	}
	ctx.current = w
	t := &ctx.theme
	r := w.rect

	// drop shadow
	fill_rect(ctx, {r.x + 3, r.y + 3, r.w, r.h}, {0, 0, 0, 90})
	gradient_rect(ctx, r, t.window_top, t.window_bottom)
	bevel(ctx, r, t.border_light, t.border_dark)

	title := Rect{r.x + 1, r.y + 1, r.w - 2, TITLE_H - 1}
	focused := focused_window(ctx) == w
	if focused {
		gradient_rect(ctx, title, t.title_top, t.title_bottom)
	} else {
		gradient_rect(ctx, title, t.title_inactive_top, t.title_inactive_bottom)
	}
	text_shadowed(ctx, title.x + 4, title.y + 2, w.title, t.title_text)

	close := Rect{r.x + r.w - 12, r.y + 2, 10, 9}
	has := has_mouse(ctx)
	close_hot := has && rect_contains(close, ctx.mouse)
	fill_rect(ctx, close, close_hot ? t.close_hot : t.close)
	bevel(ctx, close, t.border_light, t.border_dark)
	glyph(ctx, close.x + 2, close.y, int(Symbol.Close) - FIRST_GLYPH, t.title_text)

	if has && ctx.mouse_released && close_hot && rect_contains(close, ctx.press_pos) {
		w.open = false
	} else if has && ctx.mouse_pressed && rect_contains(title, ctx.mouse) && !close_hot {
		ctx.drag_window = w
		ctx.drag_offset = {ctx.mouse.x - r.x, ctx.mouse.y - r.y}
	}
	if ctx.drag_window == w && ctx.mouse_down {
		w.rect.x = ctx.mouse.x - ctx.drag_offset.x
		w.rect.y = ctx.mouse.y - ctx.drag_offset.y
		clamp_window(ctx, w)
	}

	ctx.origin = {w.rect.x + 4, w.rect.y + TITLE_H + 3}
	clip := Rect{r.x + 1, r.y + TITLE_H, r.w - 2, r.h - TITLE_H - 1}
	set_clip(ctx, clip)
	return true
}

end_window :: proc(ctx: ^Context) {
	set_clip(ctx, nil)
	ctx.current = nil
	ctx.origin = {}
}

// True when widgets in the current window (or the root layer) get the mouse.
has_mouse :: proc(ctx: ^Context) -> bool {
	if ctx.current == nil {
		return ctx.input_window == nil && !ctx.capture_mouse
	}
	return ctx.input_window == ctx.current && ctx.drag_window == nil
}

// True when the current window has keyboard focus.
has_keyboard :: proc(ctx: ^Context) -> bool {
	return ctx.current != nil && focused_window(ctx) == ctx.current
}

// Converts a rect relative to the current window's client area to UI pixels.
to_screen :: #force_inline proc(ctx: ^Context, r: Rect) -> Rect {
	return {r.x + ctx.origin.x, r.y + ctx.origin.y, r.w, r.h}
}

// Mouse helpers for custom widgets (rects in UI pixels).
hovered :: proc(ctx: ^Context, r: Rect) -> bool {
	return has_mouse(ctx) && rect_contains(r, ctx.mouse)
}

clicked :: proc(ctx: ^Context, r: Rect) -> bool {
	return has_mouse(ctx) && ctx.mouse_released && rect_contains(r, ctx.mouse) && rect_contains(r, ctx.press_pos)
}

held :: proc(ctx: ^Context, r: Rect) -> bool {
	return has_mouse(ctx) && ctx.mouse_down && rect_contains(r, ctx.press_pos) && rect_contains(r, ctx.mouse)
}

// --- drawing primitives (UI pixels) ----------------------------------------

set_clip :: proc(ctx: ^Context, r: Maybe(Rect)) {
	if rr, ok := r.?; ok {
		sr := sdl.Rect{rr.x, rr.y, rr.w, rr.h}
		sdl.SetRenderClipRect(ctx.renderer, &sr)
	} else {
		sdl.SetRenderClipRect(ctx.renderer, nil)
	}
}

@(private = "file")
set_color :: #force_inline proc(ctx: ^Context, c: Color) {
	sdl.SetRenderDrawColor(ctx.renderer, c.r, c.g, c.b, c.a)
}

fill_rect :: proc(ctx: ^Context, r: Rect, c: Color) {
	set_color(ctx, c)
	fr := sdl.FRect{f32(r.x), f32(r.y), f32(r.w), f32(r.h)}
	sdl.RenderFillRect(ctx.renderer, &fr)
}

outline_rect :: proc(ctx: ^Context, r: Rect, c: Color) {
	set_color(ctx, c)
	fr := sdl.FRect{f32(r.x), f32(r.y), f32(r.w), f32(r.h)}
	sdl.RenderRect(ctx.renderer, &fr)
}

hline :: proc(ctx: ^Context, x, y, w: i32, c: Color) {
	fill_rect(ctx, {x, y, w, 1}, c)
}

vline :: proc(ctx: ^Context, x, y, h: i32, c: Color) {
	fill_rect(ctx, {x, y, 1, h}, c)
}

// Raised 3D border: light top/left, dark bottom/right.
bevel :: proc(ctx: ^Context, r: Rect, light, dark: Color) {
	hline(ctx, r.x, r.y, r.w, light)
	vline(ctx, r.x, r.y, r.h, light)
	hline(ctx, r.x, r.y + r.h - 1, r.w, dark)
	vline(ctx, r.x + r.w - 1, r.y, r.h, dark)
}

@(private = "file")
fcolor :: #force_inline proc(c: Color) -> sdl.FColor {
	return {f32(c.r) / 255, f32(c.g) / 255, f32(c.b) / 255, f32(c.a) / 255}
}

gradient_rect :: proc(ctx: ^Context, r: Rect, top, bottom: Color) {
	x0, y0 := f32(r.x), f32(r.y)
	x1, y1 := f32(r.x + r.w), f32(r.y + r.h)
	ct, cb := fcolor(top), fcolor(bottom)
	verts := [4]sdl.Vertex {
		{position = {x0, y0}, color = ct},
		{position = {x1, y0}, color = ct},
		{position = {x1, y1}, color = cb},
		{position = {x0, y1}, color = cb},
	}
	indices := [6]i32{0, 1, 2, 0, 2, 3}
	sdl.RenderGeometry(ctx.renderer, nil, raw_data(verts[:]), 4, raw_data(indices[:]), 6)
}

glyph :: proc(ctx: ^Context, x, y: i32, index: int, c: Color) {
	if index < 0 || index >= GLYPH_COUNT {
		return
	}
	src := sdl.FRect{f32(index * CELL_W), 0, CELL_W, CELL_H}
	dst := sdl.FRect{f32(x), f32(y), CELL_W, CELL_H}
	sdl.SetTextureColorMod(ctx.font, c.r, c.g, c.b)
	sdl.SetTextureAlphaMod(ctx.font, c.a)
	sdl.RenderTexture(ctx.renderer, ctx.font, &src, &dst)
}

symbol :: proc(ctx: ^Context, x, y: i32, s: Symbol, c: Color) {
	glyph(ctx, x, y, int(s) - FIRST_GLYPH, c)
}

text :: proc(ctx: ^Context, x, y: i32, s: string, c: Color) {
	cx := x
	for r in s {
		if r != ' ' {
			glyph(ctx, cx, y, glyph_index(r), c)
		}
		cx += CELL_W
	}
}

text_shadowed :: proc(ctx: ^Context, x, y: i32, s: string, c: Color) {
	text(ctx, x + 1, y + 1, s, ctx.theme.text_shadow)
	text(ctx, x, y, s, c)
}

// Draws `s` cut to fit `max_w` UI pixels, ending with "~" when truncated.
text_fit :: proc(ctx: ^Context, x, y, max_w: i32, s: string, c: Color, shadow := true) {
	max_chars := int(max_w / CELL_W)
	n := strings.rune_count(s)
	str := s
	if n > max_chars && max_chars > 0 {
		end := 0
		count := 0
		for _, i in s {
			if count == max_chars - 1 {
				end = i
				break
			}
			count += 1
		}
		str = s[:end]
		if shadow {text_shadowed(ctx, x, y, str, c)} else {text(ctx, x, y, str, c)}
		text(ctx, x + i32(max_chars - 1) * CELL_W, y, "~", ctx.theme.text_dim)
		return
	}
	if max_chars <= 0 {
		return
	}
	if shadow {text_shadowed(ctx, x, y, str, c)} else {text(ctx, x, y, str, c)}
}

// Text drawn with each font pixel blown up to `factor` x `factor` UI pixels.
text_scaled :: proc(ctx: ^Context, x, y: i32, s: string, factor: i32, c: Color) {
	f := f32(max(factor, 1))
	sdl.SetTextureColorMod(ctx.font, c.r, c.g, c.b)
	sdl.SetTextureAlphaMod(ctx.font, c.a)
	cx := f32(x)
	for r in s {
		src := sdl.FRect{f32(glyph_index(r) * CELL_W), 0, CELL_W, CELL_H}
		dst := sdl.FRect{cx, f32(y), CELL_W * f, CELL_H * f}
		sdl.RenderTexture(ctx.renderer, ctx.font, &src, &dst)
		cx += CELL_W * f
	}
}
