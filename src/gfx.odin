package zemu

// Software canvas for the GUI. Everything is drawn at a low logical
// resolution (like ZSNES' 256x224 GUI) and scaled up with nearest filtering.

Color :: distinct u32 // 0xAARRGGBB

rgb :: proc(r, g, b: int) -> Color {
	return Color(0xFF000000 | u32(clamp(r, 0, 255)) << 16 | u32(clamp(g, 0, 255)) << 8 | u32(clamp(b, 0, 255)))
}

rgba :: proc(r, g, b, a: int) -> Color {
	return Color(u32(clamp(a, 0, 255)) << 24 | u32(clamp(r, 0, 255)) << 16 | u32(clamp(g, 0, 255)) << 8 | u32(clamp(b, 0, 255)))
}

color_rgb :: proc(c: Color) -> (r, g, b, a: int) {
	return int(u32(c) >> 16 & 0xFF), int(u32(c) >> 8 & 0xFF), int(u32(c) & 0xFF), int(u32(c) >> 24)
}

shade :: proc(c: Color, f: f32) -> Color {
	r, g, b, a := color_rgb(c)
	return rgba(int(f32(r) * f), int(f32(g) * f), int(f32(b) * f), a)
}

lighten :: proc(c: Color, amount: int) -> Color {
	r, g, b, a := color_rgb(c)
	return rgba(r + amount, g + amount, b + amount, a)
}

mix :: proc(a, b: Color, t: f32) -> Color {
	ar, ag, ab, aa := color_rgb(a)
	br, bg, bb, ba := color_rgb(b)
	l :: proc(x, y: int, t: f32) -> int { return int(f32(x) + (f32(y) - f32(x)) * t + 0.5) }
	return rgba(l(ar, br, t), l(ag, bg, t), l(ab, bb, t), l(aa, ba, t))
}

Rect :: struct {
	x, y, w, h: int,
}

rect_contains :: proc(r: Rect, x, y: int) -> bool {
	return x >= r.x && y >= r.y && x < r.x + r.w && y < r.y + r.h
}

rect_intersect :: proc(a, b: Rect) -> Rect {
	x0 := max(a.x, b.x)
	y0 := max(a.y, b.y)
	x1 := min(a.x + a.w, b.x + b.w)
	y1 := min(a.y + a.h, b.y + b.h)
	return {x0, y0, max(0, x1 - x0), max(0, y1 - y0)}
}

rect_inset :: proc(r: Rect, n: int) -> Rect {
	return {r.x + n, r.y + n, r.w - 2 * n, r.h - 2 * n}
}

Canvas :: struct {
	w, h: int,
	pix:  []u32,
	clip: Rect,
}

canvas_resize :: proc(cv: ^Canvas, w, h: int) {
	if cv.w == w && cv.h == h && cv.pix != nil do return
	delete(cv.pix)
	cv.w, cv.h = w, h
	cv.pix = make([]u32, w * h)
	cv.clip = {0, 0, w, h}
}

canvas_clear :: proc(cv: ^Canvas, c: Color) {
	for &p in cv.pix do p = u32(c)
	cv.clip = {0, 0, cv.w, cv.h}
}

set_clip :: proc(cv: ^Canvas, r: Rect) {
	cv.clip = rect_intersect(r, {0, 0, cv.w, cv.h})
}

reset_clip :: proc(cv: ^Canvas) {
	cv.clip = {0, 0, cv.w, cv.h}
}

@(private="file")
blend :: #force_inline proc(dst: ^u32, c: Color) {
	a := u32(c) >> 24
	if a == 255 {
		dst^ = u32(c)
		return
	}
	if a == 0 do return
	d := dst^
	ia := 255 - a
	r := ((u32(c) >> 16 & 0xFF) * a + (d >> 16 & 0xFF) * ia) / 255
	g := ((u32(c) >> 8 & 0xFF) * a + (d >> 8 & 0xFF) * ia) / 255
	b := ((u32(c) & 0xFF) * a + (d & 0xFF) * ia) / 255
	da := min(255, a + (d >> 24) * ia / 255)
	dst^ = da << 24 | r << 16 | g << 8 | b
}

put_pixel :: proc(cv: ^Canvas, x, y: int, c: Color) {
	if !rect_contains(cv.clip, x, y) do return
	blend(&cv.pix[y * cv.w + x], c)
}

fill_rect :: proc(cv: ^Canvas, r: Rect, c: Color) {
	rr := rect_intersect(r, cv.clip)
	for y in rr.y ..< rr.y + rr.h {
		row := cv.pix[y * cv.w:]
		for x in rr.x ..< rr.x + rr.w do blend(&row[x], c)
	}
}

hline :: proc(cv: ^Canvas, x, y, w: int, c: Color) {
	fill_rect(cv, {x, y, w, 1}, c)
}

vline :: proc(cv: ^Canvas, x, y, h: int, c: Color) {
	fill_rect(cv, {x, y, 1, h}, c)
}

rect_outline :: proc(cv: ^Canvas, r: Rect, c: Color) {
	hline(cv, r.x, r.y, r.w, c)
	hline(cv, r.x, r.y + r.h - 1, r.w, c)
	vline(cv, r.x, r.y + 1, r.h - 2, c)
	vline(cv, r.x + r.w - 1, r.y + 1, r.h - 2, c)
}

// 3D bevel: light on top/left, dark on bottom/right (inverted when sunken).
bevel :: proc(cv: ^Canvas, r: Rect, light, dark: Color, sunken := false) {
	tl, br := light, dark
	if sunken do tl, br = dark, light
	hline(cv, r.x, r.y, r.w, tl)
	vline(cv, r.x, r.y, r.h, tl)
	hline(cv, r.x, r.y + r.h - 1, r.w, br)
	vline(cv, r.x + r.w - 1, r.y, r.h, br)
}

vgradient :: proc(cv: ^Canvas, r: Rect, top, bottom: Color) {
	if r.h <= 0 do return
	for i in 0 ..< r.h {
		t := f32(i) / f32(max(1, r.h - 1))
		hline(cv, r.x, r.y + i, r.w, mix(top, bottom, t))
	}
}

fill_circle :: proc(cv: ^Canvas, cx, cy, r: int, c: Color) {
	for dy in -r ..= r {
		dx := int(f32(r) * sqrt_f32(1 - f32(dy * dy) / f32(max(1, r * r))) + 0.5)
		hline(cv, cx - dx, cy + dy, 2 * dx + 1, c)
	}
}

circle_outline :: proc(cv: ^Canvas, cx, cy, r: int, c: Color) {
	// Midpoint circle.
	x, y := r, 0
	err := 1 - r
	for x >= y {
		pts := [8][2]int{{x, y}, {y, x}, {-y, x}, {-x, y}, {-x, -y}, {-y, -x}, {y, -x}, {x, -y}}
		for p in pts do put_pixel(cv, cx + p[0], cy + p[1], c)
		y += 1
		if err < 0 {
			err += 2 * y + 1
		} else {
			x -= 1
			err += 2 * (y - x) + 1
		}
	}
}

// Rectangle with the corners cut by one pixel: buttons on the touch UI.
fill_rounded :: proc(cv: ^Canvas, r: Rect, c: Color) {
	fill_rect(cv, {r.x + 1, r.y, r.w - 2, r.h}, c)
	vline(cv, r.x, r.y + 1, r.h - 2, c)
	vline(cv, r.x + r.w - 1, r.y + 1, r.h - 2, c)
}

@(private="file")
sqrt_f32 :: proc(x: f32) -> f32 {
	if x <= 0 do return 0
	// Newton iterations are plenty for pixel circles.
	g := x
	for _ in 0 ..< 8 do g = 0.5 * (g + x / g)
	return g
}

// --- Pixel font ---------------------------------------------------------------
// 5x5 upper-case glyphs, 6 pixel advance, drawn with a 1 pixel drop shadow like
// the ZSNES GUI. Lower case is drawn as upper case.

GLYPH_W  :: 5
GLYPH_H  :: 5
CHAR_W   :: 6
LINE_H   :: 8

// Control codes used for icons in GUI strings.
ICON_UP    :: "\x01"
ICON_DOWN  :: "\x02"
ICON_LEFT  :: "\x03"
ICON_RIGHT :: "\x04"
ICON_CHECK :: "\x05"
ICON_DIR   :: "\x06"

@(private="file")
glyph_bits: [128][GLYPH_H]u8

@(private="file")
FONT_SRC := [?]struct{ch: u8, rows: [GLYPH_H]string}{
	{0x01, {"..#..", ".###.", "#####", ".....", "....."}},
	{0x02, {".....", ".....", "#####", ".###.", "..#.."}},
	{0x03, {"...#.", "..##.", ".###.", "..##.", "...#."}},
	{0x04, {".#...", ".##..", ".###.", ".##..", ".#..."}},
	{0x05, {"....#", "...#.", "#.#..", ".#...", "....."}},
	{0x06, {"##...", "#####", "#...#", "#...#", "#####"}},
	{'!', {"..#..", "..#..", "..#..", ".....", "..#.."}},
	{'"', {".#.#.", ".#.#.", ".....", ".....", "....."}},
	{'#', {".#.#.", "#####", ".#.#.", "#####", ".#.#."}},
	{'$', {".####", "#.#..", ".###.", "..#.#", "####."}},
	{'%', {"##..#", "##.#.", "..#..", ".#.##", "#..##"}},
	{'&', {".##..", "#..#.", ".##.#", "#..#.", ".##.#"}},
	{'\'', {"..#..", "..#..", ".....", ".....", "....."}},
	{'(', {"...#.", "..#..", "..#..", "..#..", "...#."}},
	{')', {".#...", "..#..", "..#..", "..#..", ".#..."}},
	{'*', {"..#..", "#.#.#", ".###.", "#.#.#", "..#.."}},
	{'+', {".....", "..#..", ".###.", "..#..", "....."}},
	{',', {".....", ".....", ".....", "..#..", ".#..."}},
	{'-', {".....", ".....", ".###.", ".....", "....."}},
	{'.', {".....", ".....", ".....", ".....", "..#.."}},
	{'/', {"....#", "...#.", "..#..", ".#...", "#...."}},
	{'0', {".###.", "#..##", "#.#.#", "##..#", ".###."}},
	{'1', {"..#..", ".##..", "..#..", "..#..", ".###."}},
	{'2', {".###.", "#...#", "..##.", ".#...", "#####"}},
	{'3', {"####.", "....#", "..##.", "....#", "####."}},
	{'4', {"#..#.", "#..#.", "#####", "...#.", "...#."}},
	{'5', {"#####", "#....", "####.", "....#", "####."}},
	{'6', {".###.", "#....", "####.", "#...#", ".###."}},
	{'7', {"#####", "....#", "...#.", "..#..", "..#.."}},
	{'8', {".###.", "#...#", ".###.", "#...#", ".###."}},
	{'9', {".###.", "#...#", ".####", "....#", ".###."}},
	{':', {".....", "..#..", ".....", "..#..", "....."}},
	{';', {".....", "..#..", ".....", "..#..", ".#..."}},
	{'<', {"...#.", "..#..", ".#...", "..#..", "...#."}},
	{'=', {".....", ".###.", ".....", ".###.", "....."}},
	{'>', {".#...", "..#..", "...#.", "..#..", ".#..."}},
	{'?', {".###.", "#...#", "..##.", ".....", "..#.."}},
	{'@', {".###.", "#.###", "#.#.#", "#.##.", ".##.."}},
	{'A', {".###.", "#...#", "#####", "#...#", "#...#"}},
	{'B', {"####.", "#...#", "####.", "#...#", "####."}},
	{'C', {".####", "#....", "#....", "#....", ".####"}},
	{'D', {"####.", "#...#", "#...#", "#...#", "####."}},
	{'E', {"#####", "#....", "####.", "#....", "#####"}},
	{'F', {"#####", "#....", "####.", "#....", "#...."}},
	{'G', {".####", "#....", "#..##", "#...#", ".###."}},
	{'H', {"#...#", "#...#", "#####", "#...#", "#...#"}},
	{'I', {".###.", "..#..", "..#..", "..#..", ".###."}},
	{'J', {"....#", "....#", "....#", "#...#", ".###."}},
	{'K', {"#...#", "#..#.", "###..", "#..#.", "#...#"}},
	{'L', {"#....", "#....", "#....", "#....", "#####"}},
	{'M', {"#...#", "##.##", "#.#.#", "#...#", "#...#"}},
	{'N', {"#...#", "##..#", "#.#.#", "#..##", "#...#"}},
	{'O', {".###.", "#...#", "#...#", "#...#", ".###."}},
	{'P', {"####.", "#...#", "####.", "#....", "#...."}},
	{'Q', {".###.", "#...#", "#.#.#", "#..#.", ".##.#"}},
	{'R', {"####.", "#...#", "####.", "#..#.", "#...#"}},
	{'S', {".####", "#....", ".###.", "....#", "####."}},
	{'T', {"#####", "..#..", "..#..", "..#..", "..#.."}},
	{'U', {"#...#", "#...#", "#...#", "#...#", ".###."}},
	{'V', {"#...#", "#...#", "#...#", ".#.#.", "..#.."}},
	{'W', {"#...#", "#...#", "#.#.#", "##.##", "#...#"}},
	{'X', {"#...#", ".#.#.", "..#..", ".#.#.", "#...#"}},
	{'Y', {"#...#", ".#.#.", "..#..", "..#..", "..#.."}},
	{'Z', {"#####", "...#.", "..#..", ".#...", "#####"}},
	{'[', {".###.", ".#...", ".#...", ".#...", ".###."}},
	{'\\', {"#....", ".#...", "..#..", "...#.", "....#"}},
	{']', {".###.", "...#.", "...#.", "...#.", ".###."}},
	{'^', {"..#..", ".#.#.", ".....", ".....", "....."}},
	{'_', {".....", ".....", ".....", ".....", "#####"}},
	{'`', {".#...", "..#..", ".....", ".....", "....."}},
	{'{', {"..##.", ".#...", "##...", ".#...", "..##."}},
	{'|', {"..#..", "..#..", "..#..", "..#..", "..#.."}},
	{'}', {".##..", "...#.", "...##", "...#.", ".##.."}},
	{'~', {".....", ".#...", "#.#.#", "...#.", "....."}},
}

font_init :: proc() {
	for g in FONT_SRC {
		for row, y in g.rows {
			bits: u8
			for x in 0 ..< GLYPH_W {
				if row[x] == '#' do bits |= 1 << u8(x)
			}
			glyph_bits[g.ch][y] = bits
		}
	}
}

text_width :: proc(s: string) -> int {
	return len(s) * CHAR_W
}

draw_char :: proc(cv: ^Canvas, x, y: int, ch: u8, c: Color, scale := 1) {
	ch := ch
	if ch >= 'a' && ch <= 'z' do ch -= 32
	if ch >= 128 do ch = '?'
	rows := glyph_bits[ch]
	for gy in 0 ..< GLYPH_H {
		bits := rows[gy]
		if bits == 0 do continue
		for gx in 0 ..< GLYPH_W {
			if bits & (1 << u8(gx)) == 0 do continue
			if scale == 1 {
				put_pixel(cv, x + gx, y + gy, c)
			} else {
				fill_rect(cv, {x + gx * scale, y + gy * scale, scale, scale}, c)
			}
		}
	}
}

draw_text_plain :: proc(cv: ^Canvas, x, y: int, s: string, c: Color, scale := 1) {
	cx := x
	for i in 0 ..< len(s) {
		draw_char(cv, cx, y, s[i], c, scale)
		cx += CHAR_W * scale
	}
}

// Text with the ZSNES-style drop shadow.
draw_text :: proc(cv: ^Canvas, x, y: int, s: string, c: Color, shadow: Color = Color(0)) {
	sh := shadow
	if sh == 0 do sh = theme.text_shadow
	draw_text_plain(cv, x + 1, y + 1, s, sh)
	draw_text_plain(cv, x, y, s, c)
}

// Clip a string to fit `w` pixels, ending with "~" like 8.3 names did.
fit_text :: proc(s: string, w: int) -> string {
	n := w / CHAR_W
	if len(s) <= n do return s
	if n <= 1 do return ""
	buf := make([]byte, n, context.temp_allocator)
	copy(buf, s[:n - 1])
	buf[n - 1] = '~'
	return string(buf)
}

// Small sprite from rows of characters: '.' transparent, '#' color a, '+' color b.
draw_sprite :: proc(cv: ^Canvas, x, y: int, rows: []string, a, b: Color) {
	for row, sy in rows {
		for sx in 0 ..< len(row) {
			switch row[sx] {
			case '#': put_pixel(cv, x + sx, y + sy, a)
			case '+': put_pixel(cv, x + sx, y + sy, b)
			}
		}
	}
}
