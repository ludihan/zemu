package psx

// GPU: command processing and a software rasterizer working on the 1 MiB
// (1024x512 x 16-bit) VRAM.

VRAM_W :: 1024
VRAM_H :: 512
MAX_OUT_W :: 640
MAX_OUT_H :: 480

Gpu_Mode :: enum u8 {
	Command,
	Cpu_To_Vram,
	Polyline,
}

Vertex :: struct {
	x, y:    i32,
	r, g, b: i32,
	u, v:    i32,
}

Gpu :: struct {
	vram:          [VRAM_W * VRAM_H]u16,

	// draw mode (GP0 E1)
	tex_x:         i32,
	tex_y:         i32,
	semi_mode:     u32,
	tex_depth:     u32,
	dither:        bool,
	draw_display:  bool,
	tex_disable:   bool,
	rect_flip_x:   bool,
	rect_flip_y:   bool,
	// palette cache
	clut_cache:    [256]u16,
	clut_entries:  int, // 0, 16 or 256 entries loaded
	clut_cached_x, clut_cached_y: i32,
	// texture window (E2)
	win_mask_x, win_mask_y, win_off_x, win_off_y: i32,
	// drawing area and offset (E3-E5)
	area_left, area_top, area_right, area_bottom: i32,
	off_x, off_y:  i32,
	// mask bit (E6)
	set_mask:      bool,
	check_mask:    bool,

	// display (GP1)
	display_off:   bool,
	dma_dir:       u32,
	disp_x, disp_y: i32,
	h_start, h_end: i32,
	v_start, v_end: i32,
	hres:          u32,
	vres_480:      bool,
	pal:           bool,
	depth24:       bool,
	interlace:     bool,
	irq:           bool,
	irq_edge:      bool, // set when irq rises; consumed by the console
	busy:          int,  // GPU clocks of drawing still "in progress"
	allow_tex_disable: bool,

	// command assembly
	mode:          Gpu_Mode,
	cmd:           [16]u32,
	cmd_len:       int,
	cmd_needed:    int,
	poly_prev:     Vertex,
	poly_shaded:   bool,
	poly_semi:     bool,
	poly_expect_color: bool,
	poly_color:    u32,

	// transfers
	xfer_x, xfer_y, xfer_w, xfer_h: i32,
	xfer_cx, xfer_cy: i32,
	read_active:   bool,
	read_x, read_y, read_w, read_h, read_cx, read_cy: i32,
	gpuread:       u32,

	odd_line:      bool,
	field:         bool,

	framebuffer:   [MAX_OUT_W * MAX_OUT_H]u32,
	out_w, out_h:  int,
}

@(rodata, private = "file")
DITHER := [4][4]i32 {
	{-4, 0, -3, 1},
	{2, -2, 3, -1},
	{-3, 1, -4, 0},
	{3, -1, 2, -2},
}

gpu_reset :: proc(g: ^Gpu) {
	g.mode = .Command
	g.cmd_len = 0
	g.tex_x = 0
	g.tex_y = 0
	g.semi_mode = 0
	g.tex_depth = 0
	g.dither = false
	g.draw_display = false
	g.tex_disable = false
	g.win_mask_x = 0
	g.win_mask_y = 0
	g.win_off_x = 0
	g.win_off_y = 0
	g.area_left = 0
	g.area_top = 0
	g.area_right = 0
	g.area_bottom = 0
	g.off_x = 0
	g.off_y = 0
	g.set_mask = false
	g.check_mask = false
	g.display_off = true
	g.dma_dir = 0
	g.disp_x = 0
	g.disp_y = 0
	g.h_start = 0x200
	g.h_end = 0x200 + 256 * 10
	g.v_start = 0x10
	g.v_end = 0x10 + 240
	g.hres = 0
	g.vres_480 = false
	g.pal = false
	g.depth24 = false
	g.interlace = false
	g.irq = false
	g.read_active = false
	g.out_w = 320
	g.out_h = 240
}

gpu_status :: proc(g: ^Gpu) -> u32 {
	s: u32
	s |= u32(g.tex_x / 64) & 0xF
	s |= u32(g.tex_y / 256) << 4
	s |= g.semi_mode << 5
	s |= g.tex_depth << 7
	if g.dither {s |= 1 << 9}
	if g.draw_display {s |= 1 << 10}
	if g.set_mask {s |= 1 << 11}
	if g.check_mask {s |= 1 << 12}
	if g.interlace && g.field {s |= 1 << 13}
	if g.tex_disable {s |= 1 << 15}
	s |= (g.hres & 0x7) << 16 // includes the 368-pixel bit
	if g.vres_480 {s |= 1 << 19}
	if g.pal {s |= 1 << 20}
	if g.depth24 {s |= 1 << 21}
	if g.interlace {s |= 1 << 22}
	if g.display_off {s |= 1 << 23}
	if g.irq {s |= 1 << 24}
	// Pixels are written at once, but the GPU reports itself busy (not
	// ready for commands or DMA blocks) for about as long as drawing them
	// takes. "Ready to send VRAM" is set while a VRAM-to-CPU copy is pending.
	ready := g.busy <= 0
	if ready {s |= 1 << 26}
	// The FIFO is only left holding data while drawing when DMA fed it.
	if ready || g.dma_dir == 0 {s |= 1 << 28}
	if g.read_active {s |= 1 << 27}
	s |= g.dma_dir << 29
	switch g.dma_dir {
	case 1: s |= 1 << 25 // FIFO not full
	case 2: if ready {s |= 1 << 25} // follows "ready for a DMA block"
	case 3: if g.read_active {s |= 1 << 25}
	}
	if g.odd_line && !(g.interlace && g.vres_480) {s |= 1 << 31}
	if g.interlace && g.vres_480 && g.field {s |= 1 << 31}
	return s
}

// --- GP1: display control ---------------------------------------------------

gpu_gp1 :: proc(g: ^Gpu, w: u32) {
	switch w >> 24 {
	case 0x00:
		gpu_reset(g)
	case 0x01:
		g.mode = .Command
		g.cmd_len = 0
	case 0x02:
		g.irq = false
	case 0x03:
		g.display_off = w & 1 != 0
	case 0x04:
		g.dma_dir = w & 3
	case 0x05:
		g.disp_x = i32(w & 0x3FE)
		g.disp_y = i32((w >> 10) & 0x1FF)
	case 0x06:
		g.h_start = i32(w & 0xFFF)
		g.h_end = i32((w >> 12) & 0xFFF)
	case 0x07:
		g.v_start = i32(w & 0x3FF)
		g.v_end = i32((w >> 10) & 0x3FF)
	case 0x08:
		// GPUSTAT bit 16 (368-pixel mode) followed by bits 17-18
		g.hres = ((w & 3) << 1) | ((w >> 6) & 1)
		g.vres_480 = w & 0x04 != 0
		g.pal = w & 0x08 != 0
		g.depth24 = w & 0x10 != 0
		g.interlace = w & 0x20 != 0
	case 0x09:
		g.allow_tex_disable = w & 1 != 0
	case 0x10 ..= 0x1F:
		switch w & 7 {
		case 2: g.gpuread = u32(g.win_mask_x) | u32(g.win_mask_y) << 5 | u32(g.win_off_x) << 10 | u32(g.win_off_y) << 15
		case 3: g.gpuread = u32(g.area_left) | u32(g.area_top) << 10
		case 4: g.gpuread = u32(g.area_right) | u32(g.area_bottom) << 10
		case 5: g.gpuread = (u32(g.off_x) & 0x7FF) | (u32(g.off_y) & 0x7FF) << 11
		case 7: g.gpuread = 2 // GPU version
		}
	}
}

// --- GP0: rendering and VRAM commands ---------------------------------------

@(private = "file")
command_words :: proc(op: u32) -> int {
	switch op {
	case 0x02: return 3
	case 0x20 ..= 0x3F:
		verts := op & 0x08 != 0 ? 4 : 3
		per := 1
		if op & 0x04 != 0 {per += 1}
		if op & 0x10 != 0 {per += 1}
		n := 1 + verts * per
		if op & 0x10 != 0 {n -= 1}
		return n
	case 0x40 ..= 0x5F:
		return op & 0x10 != 0 ? 4 : 3
	case 0x60 ..= 0x7F:
		n := 2
		if op & 0x04 != 0 {n += 1}
		if (op >> 3) & 3 == 0 {n += 1}
		return n
	case 0x80 ..= 0x9F: return 4
	case 0xA0 ..= 0xDF: return 3
	}
	return 1
}

gpu_gp0 :: proc(g: ^Gpu, w: u32) {
	switch g.mode {
	case .Cpu_To_Vram:
		vram_transfer_write(g, u16(w))
		if g.mode == .Cpu_To_Vram {
			vram_transfer_write(g, u16(w >> 16))
		}
		return
	case .Polyline:
		polyline_word(g, w)
		return
	case .Command:
	}

	if g.cmd_len == 0 {
		g.cmd_needed = command_words(w >> 24)
	}
	g.cmd[g.cmd_len] = w
	g.cmd_len += 1
	if g.cmd_len < g.cmd_needed {
		return
	}
	g.cmd_len = 0
	execute_command(g)
}

@(private = "file")
sign11 :: #force_inline proc(v: u32) -> i32 {
	return i32(v << 21) >> 21
}

@(private = "file")
vertex_xy :: #force_inline proc(g: ^Gpu, w: u32) -> (i32, i32) {
	return sign11(w) + g.off_x, sign11(w >> 16) + g.off_y
}

@(private = "file")
set_color :: #force_inline proc(v: ^Vertex, w: u32) {
	v.r = i32(w & 0xFF)
	v.g = i32((w >> 8) & 0xFF)
	v.b = i32((w >> 16) & 0xFF)
}

@(private = "file")
execute_command :: proc(g: ^Gpu) {
	c := &g.cmd
	op := c[0] >> 24
	switch op {
	case 0x01: // clear cache: the palette is reloaded at the next textured draw
		g.clut_entries = 0
	case 0x02:
		fill_rect(g, c[0], c[1], c[2])
	case 0x1F:
		if !g.irq {g.irq_edge = true}
		g.irq = true
	case 0x20 ..= 0x3F:
		draw_polygon(g, op)
	case 0x40 ..= 0x5F:
		shaded := op & 0x10 != 0
		v0, v1: Vertex
		set_color(&v0, c[0])
		v0.x, v0.y = vertex_xy(g, c[1])
		if shaded {
			set_color(&v1, c[2])
			v1.x, v1.y = vertex_xy(g, c[3])
		} else {
			set_color(&v1, c[0])
			v1.x, v1.y = vertex_xy(g, c[2])
		}
		draw_line(g, v0, v1, shaded, op & 0x02 != 0)
		if op & 0x08 != 0 {
			g.mode = .Polyline
			g.poly_prev = v1
			g.poly_shaded = shaded
			g.poly_semi = op & 0x02 != 0
			g.poly_expect_color = shaded
			g.poly_color = c[0]
		}
	case 0x60 ..= 0x7F:
		draw_rect(g, op)
	case 0x80 ..= 0x9F:
		copy_vram(g, c[1], c[2], c[3])
	case 0xA0 ..= 0xBF:
		g.xfer_x = i32(c[1] & 0x3FF)
		g.xfer_y = i32((c[1] >> 16) & 0x1FF)
		g.xfer_w = i32(((c[2] & 0xFFFF) - 1) & 0x3FF) + 1
		g.xfer_h = i32((((c[2] >> 16) & 0xFFFF) - 1) & 0x1FF) + 1
		g.xfer_cx = 0
		g.xfer_cy = 0
		g.mode = .Cpu_To_Vram
	case 0xC0 ..= 0xDF:
		g.read_x = i32(c[1] & 0x3FF)
		g.read_y = i32((c[1] >> 16) & 0x1FF)
		g.read_w = i32(((c[2] & 0xFFFF) - 1) & 0x3FF) + 1
		g.read_h = i32((((c[2] >> 16) & 0xFFFF) - 1) & 0x1FF) + 1
		g.read_cx = 0
		g.read_cy = 0
		g.read_active = true
	case 0xE1:
		w := c[0]
		g.tex_x = i32(w & 0xF) * 64
		g.tex_y = i32((w >> 4) & 1) * 256
		g.semi_mode = (w >> 5) & 3
		g.tex_depth = (w >> 7) & 3 // 2 and the "reserved" 3 both mean 15-bit
		g.dither = w & (1 << 9) != 0
		g.draw_display = w & (1 << 10) != 0
		g.tex_disable = g.allow_tex_disable && w & (1 << 11) != 0
		g.rect_flip_x = w & (1 << 12) != 0
		g.rect_flip_y = w & (1 << 13) != 0
	case 0xE2:
		w := c[0]
		g.win_mask_x = i32(w & 0x1F)
		g.win_mask_y = i32((w >> 5) & 0x1F)
		g.win_off_x = i32((w >> 10) & 0x1F)
		g.win_off_y = i32((w >> 15) & 0x1F)
	case 0xE3:
		g.area_left = i32(c[0] & 0x3FF)
		g.area_top = i32((c[0] >> 10) & 0x1FF)
	case 0xE4:
		g.area_right = i32(c[0] & 0x3FF)
		g.area_bottom = i32((c[0] >> 10) & 0x1FF)
	case 0xE5:
		g.off_x = sign11(c[0])
		g.off_y = sign11(c[0] >> 11)
	case 0xE6:
		g.set_mask = c[0] & 1 != 0
		g.check_mask = c[0] & 2 != 0
	}
}

@(private = "file")
polyline_word :: proc(g: ^Gpu, w: u32) {
	if w & 0xF000_F000 == 0x5000_5000 {
		g.mode = .Command
		return
	}
	if g.poly_expect_color {
		g.poly_color = w
		g.poly_expect_color = false
		return
	}
	v: Vertex
	set_color(&v, g.poly_shaded ? g.poly_color : g.cmd[0])
	v.x, v.y = vertex_xy(g, w)
	draw_line(g, g.poly_prev, v, g.poly_shaded, g.poly_semi)
	g.poly_prev = v
	g.poly_expect_color = g.poly_shaded
}

// --- VRAM transfers --------------------------------------------------------

@(private = "file")
vram_index :: #force_inline proc(x, y: i32) -> int {
	return int(y & (VRAM_H - 1)) * VRAM_W + int(x & (VRAM_W - 1))
}

@(private = "file")
vram_transfer_write :: proc(g: ^Gpu, p: u16) {
	i := vram_index(g.xfer_x + g.xfer_cx, g.xfer_y + g.xfer_cy)
	if !(g.check_mask && g.vram[i] & 0x8000 != 0) {
		g.vram[i] = p | (g.set_mask ? 0x8000 : 0)
	}
	g.xfer_cx += 1
	if g.xfer_cx >= g.xfer_w {
		g.xfer_cx = 0
		g.xfer_cy += 1
		if g.xfer_cy >= g.xfer_h {
			g.mode = .Command
		}
	}
}

gpu_read :: proc(g: ^Gpu) -> u32 {
	if !g.read_active {
		return g.gpuread
	}
	v: u32
	for half in 0 ..< 2 {
		p := g.vram[vram_index(g.read_x + g.read_cx, g.read_y + g.read_cy)]
		v |= u32(p) << (u32(half) * 16)
		g.read_cx += 1
		if g.read_cx >= g.read_w {
			g.read_cx = 0
			g.read_cy += 1
			if g.read_cy >= g.read_h {
				g.read_active = false
				break
			}
		}
	}
	g.gpuread = v
	return v
}

@(private = "file")
fill_rect :: proc(g: ^Gpu, color, pos, size: u32) {
	x0 := i32(pos & 0x3F0)
	y0 := i32((pos >> 16) & 0x1FF)
	w := i32(((size & 0x3FF) + 15) & ~u32(15))
	h := i32((size >> 16) & 0x1FF)
	p := to15(color)
	for y in 0 ..< h {
		for x in 0 ..< w {
			g.vram[vram_index(x0 + x, y0 + y)] = p
		}
	}
}

@(private = "file")
copy_vram :: proc(g: ^Gpu, src, dst, size: u32) {
	sx := i32(src & 0x3FF)
	sy := i32((src >> 16) & 0x1FF)
	dx := i32(dst & 0x3FF)
	dy := i32((dst >> 16) & 0x1FF)
	w := i32(((size & 0xFFFF) - 1) & 0x3FF) + 1
	h := i32((((size >> 16) & 0xFFFF) - 1) & 0x1FF) + 1
	// The GPU moves each row through a 16-pixel buffer: it reads up to the
	// next 16-pixel boundary of the source, then writes that run. Overlapping
	// copies therefore act like memmove inside a run and smear across runs.
	buf: [16]u16
	for y in 0 ..< h {
		x: i32 = 0
		for x < w {
			run := min(16 - ((sx + x) & 15), w - x)
			for k in 0 ..< run {
				buf[k] = g.vram[vram_index(sx + x + k, sy + y)]
			}
			for k in 0 ..< run {
				di := vram_index(dx + x + k, dy + y)
				if g.check_mask && g.vram[di] & 0x8000 != 0 {
					continue
				}
				g.vram[di] = buf[k] | (g.set_mask ? 0x8000 : 0)
			}
			x += run
		}
	}
}

// --- pixel pipeline --------------------------------------------------------

@(private = "file")
to15 :: #force_inline proc(c: u32) -> u16 {
	r := u16((c >> 3) & 0x1F)
	gg := u16((c >> 11) & 0x1F)
	b := u16((c >> 19) & 0x1F)
	return r | gg << 5 | b << 10
}

Draw_Flags :: bit_set[enum u8 {
	Textured,
	Raw,
	Semi,
	Shaded,
	Dither,
}; u8]

Texture_Info :: struct {
	page_x, page_y: i32,
	clut_x, clut_y: i32,
	depth:          u32,
	semi_mode:      u32,
}

@(private = "file")
texel :: proc(g: ^Gpu, t: ^Texture_Info, u_in, v_in: i32) -> u16 {
	u := u_in & 0xFF
	v := v_in & 0xFF
	u = (u & ~(g.win_mask_x * 8)) | ((g.win_off_x & g.win_mask_x) * 8)
	v = (v & ~(g.win_mask_y * 8)) | ((g.win_off_y & g.win_mask_y) * 8)
	switch t.depth {
	case 0:
		w := g.vram[vram_index(t.page_x + u / 4, t.page_y + v)]
		return g.clut_cache[(w >> (u32(u & 3) * 4)) & 0xF]
	case 1:
		w := g.vram[vram_index(t.page_x + u / 2, t.page_y + v)]
		return g.clut_cache[(w >> (u32(u & 1) * 8)) & 0xFF]
	}
	return g.vram[vram_index(t.page_x + u, t.page_y + v)]
}

// The GPU keeps the palette in a cache that it reloads only when a textured
// primitive uses a different palette address, or needs all 256 entries
// after only 16 were loaded, or after GP0(01) cleared it. Overwriting palette
// data in VRAM is not seen until then.
@(private = "file")
clut_load :: proc(g: ^Gpu, t: ^Texture_Info) {
	needed: int
	switch t.depth {
	case 0: needed = 16
	case 1: needed = 256
	case: return // 15-bit textures do not use the palette
	}
	if g.clut_entries >= needed && g.clut_cached_x == t.clut_x && g.clut_cached_y == t.clut_y {
		return
	}
	for i in 0 ..< needed {
		g.clut_cache[i] = g.vram[vram_index(t.clut_x + i32(i), t.clut_y)]
	}
	g.clut_entries = needed
	g.clut_cached_x, g.clut_cached_y = t.clut_x, t.clut_y
}

@(private = "file")
in_area :: #force_inline proc(g: ^Gpu, x, y: i32) -> bool {
	return x >= g.area_left && x <= g.area_right && y >= g.area_top && y <= g.area_bottom
}

// Shades and writes one pixel. Colors are 8-bit per channel; `tex` is used
// only when textured.
@(private = "file")
plot :: proc(g: ^Gpu, x, y: i32, r, gg, b: i32, flags: Draw_Flags, t: ^Texture_Info, u, v: i32) {
	g.busy += 1 // about one GPU clock per pixel
	idx := vram_index(x, y)
	dst := g.vram[idx]
	if g.check_mask && dst & 0x8000 != 0 {
		return
	}
	cr, cg, cb := r, gg, b
	semi := .Semi in flags
	mask_bit: u16 = 0
	if .Textured in flags {
		tx := texel(g, t, u, v)
		if tx == 0 {
			return
		}
		tr := i32(tx & 0x1F) << 3
		tg := i32((tx >> 5) & 0x1F) << 3
		tb := i32((tx >> 10) & 0x1F) << 3
		if .Raw in flags {
			cr, cg, cb = tr, tg, tb
		} else {
			cr = (tr * r) >> 7
			cg = (tg * gg) >> 7
			cb = (tb * b) >> 7
		}
		semi = semi && tx & 0x8000 != 0
		mask_bit = tx & 0x8000
	}
	if .Dither in flags {
		d := DITHER[y & 3][x & 3]
		cr += d
		cg += d
		cb += d
	}
	r5 := clamp(cr, 0, 255) >> 3
	g5 := clamp(cg, 0, 255) >> 3
	b5 := clamp(cb, 0, 255) >> 3
	if semi {
		br := i32(dst & 0x1F)
		bg := i32((dst >> 5) & 0x1F)
		bb := i32((dst >> 10) & 0x1F)
		mode := .Textured in flags ? t.semi_mode : g.semi_mode
		switch mode {
		case 0: r5, g5, b5 = (br + r5) >> 1, (bg + g5) >> 1, (bb + b5) >> 1
		case 1: r5, g5, b5 = min(br + r5, 31), min(bg + g5, 31), min(bb + b5, 31)
		case 2: r5, g5, b5 = max(br - r5, 0), max(bg - g5, 0), max(bb - b5, 0)
		case 3: r5, g5, b5 = min(br + r5 / 4, 31), min(bg + g5 / 4, 31), min(bb + b5 / 4, 31)
		}
	}
	out := u16(r5) | u16(g5) << 5 | u16(b5) << 10 | mask_bit
	if g.set_mask {
		out |= 0x8000
	}
	g.vram[idx] = out
}

// --- primitives ------------------------------------------------------------

@(private = "file")
texture_info :: proc(g: ^Gpu, clut_word, page_word: u32) -> Texture_Info {
	return {
		clut_x    = i32((clut_word >> 16) & 0x3F) * 16,
		clut_y    = i32((clut_word >> 22) & 0x1FF),
		page_x    = i32((page_word >> 16) & 0xF) * 64,
		page_y    = i32((page_word >> 20) & 1) * 256,
		semi_mode = (page_word >> 21) & 3,
		depth     = (page_word >> 23) & 3,
	}
}

@(private = "file")
draw_polygon :: proc(g: ^Gpu, op: u32) {
	c := &g.cmd
	shaded := op & 0x10 != 0
	quad := op & 0x08 != 0
	textured := op & 0x04 != 0 && !g.tex_disable
	semi := op & 0x02 != 0
	raw := op & 0x01 != 0
	n := quad ? 4 : 3

	verts: [4]Vertex
	tex: Texture_Info
	i := 1
	for k in 0 ..< n {
		color_word := c[0]
		if shaded && k > 0 {
			color_word = c[i]
			i += 1
		}
		set_color(&verts[k], color_word)
		verts[k].x, verts[k].y = vertex_xy(g, c[i])
		i += 1
		if op & 0x04 != 0 {
			uv := c[i]
			i += 1
			verts[k].u = i32(uv & 0xFF)
			verts[k].v = i32((uv >> 8) & 0xFF)
			if k == 0 {
				tex.clut_x = i32((uv >> 16) & 0x3F) * 16
				tex.clut_y = i32((uv >> 22) & 0x1FF)
			}
			if k == 1 {
				page := texture_info(g, 0, uv)
				tex.page_x = page.page_x
				tex.page_y = page.page_y
				tex.semi_mode = page.semi_mode
				tex.depth = page.depth
				// textured polygons also update the global texpage
				g.tex_x = page.page_x
				g.tex_y = page.page_y
				g.semi_mode = page.semi_mode
				g.tex_depth = page.depth
				// ...including texture disable, when GP1(09) allows it
				g.tex_disable = g.allow_tex_disable && (uv >> 27) & 1 != 0
			}
		}
	}

	flags: Draw_Flags
	if textured {flags += {.Textured}}
	if raw && textured {flags += {.Raw}}
	if semi {flags += {.Semi}}
	if shaded {flags += {.Shaded}}
	if g.dither && (shaded || (textured && !raw)) {flags += {.Dither}}

	if textured {
		clut_load(g, &tex)
	}
	draw_triangle(g, verts[0], verts[1], verts[2], flags, &tex)
	if quad {
		draw_triangle(g, verts[1], verts[2], verts[3], flags, &tex)
	}
}

@(private = "file")
edge :: #force_inline proc(a, b: Vertex, x, y: i32) -> i64 {
	return i64(b.x - a.x) * i64(y - a.y) - i64(b.y - a.y) * i64(x - a.x)
}

// True for top or left edges of the triangle as wound by draw_triangle
// (positive area with y pointing down). Pixels exactly on those edges are
// drawn; pixels on bottom/right edges are not, matching the hardware.
@(private = "file")
is_top_left :: #force_inline proc(a, b: Vertex) -> bool {
	return (a.y == b.y && b.x > a.x) || b.y < a.y
}

@(private = "file")
draw_triangle :: proc(g: ^Gpu, a, b, c_in: Vertex, flags: Draw_Flags, tex: ^Texture_Info) {
	v0, v1, v2 := a, b, c_in
	area := edge(v0, v1, v2.x, v2.y)
	if area == 0 {
		return
	}
	if area < 0 {
		v1, v2 = v2, v1
		area = -area
	}
	min_x := min(v0.x, v1.x, v2.x)
	max_x := max(v0.x, v1.x, v2.x)
	min_y := min(v0.y, v1.y, v2.y)
	max_y := max(v0.y, v1.y, v2.y)
	// The GPU refuses primitives larger than 1023x511.
	if max_x - min_x >= 1024 || max_y - min_y >= 512 {
		return
	}
	min_x = max(min_x, g.area_left)
	max_x = min(max_x, g.area_right)
	min_y = max(min_y, g.area_top)
	max_y = min(max_y, g.area_bottom)
	if min_x > max_x || min_y > max_y {
		return
	}

	bias0: i64 = is_top_left(v1, v2) ? 0 : -1
	bias1: i64 = is_top_left(v2, v0) ? 0 : -1
	bias2: i64 = is_top_left(v0, v1) ? 0 : -1
	shaded := .Shaded in flags
	textured := .Textured in flags

	// Colours and texture coordinates step by per-triangle gradients in
	// 12.12 fixed point (truncated), starting from the topmost vertex with a
	// half-unit bias, as the GPU's interpolators do.
	// The anchor ("core") vertex is the leftmost one, with the tie-breaking
	// the hardware uses.
	top: Vertex
	if b.x <= a.x {
		top = c_in.x <= b.x ? c_in : b
	} else {
		top = c_in.x < a.x ? c_in : a
	}
	gr := gradients(v0, v1, v2, proc(v: Vertex) -> i32 {return v.r})
	gg_ := gradients(v0, v1, v2, proc(v: Vertex) -> i32 {return v.g})
	gb := gradients(v0, v1, v2, proc(v: Vertex) -> i32 {return v.b})
	gu := gradients(v0, v1, v2, proc(v: Vertex) -> i32 {return v.u})
	gv := gradients(v0, v1, v2, proc(v: Vertex) -> i32 {return v.v})
	at :: #force_inline proc(base: i32, d: [2]i64, x, y: i32, top: Vertex) -> i32 {
		fixed := (i64(base) << FIXED_BITS) + (1 << (FIXED_BITS - 1)) + d.x * i64(x - top.x) + d.y * i64(y - top.y)
		return i32(fixed >> FIXED_BITS)
	}

	for y in min_y ..= max_y {
		for x in min_x ..= max_x {
			w0 := edge(v1, v2, x, y)
			w1 := edge(v2, v0, x, y)
			w2 := edge(v0, v1, x, y)
			if w0 + bias0 < 0 || w1 + bias1 < 0 || w2 + bias2 < 0 {
				continue
			}
			r, gg, bb := v0.r, v0.g, v0.b
			if shaded {
				r = clamp(at(top.r, gr, x, y, top), 0, 255)
				gg = clamp(at(top.g, gg_, x, y, top), 0, 255)
				bb = clamp(at(top.b, gb, x, y, top), 0, 255)
			}
			u, v: i32
			if textured {
				u = at(top.u, gu, x, y, top) & 0xFF
				v = at(top.v, gv, x, y, top) & 0xFF
			}
			plot(g, x, y, r, gg, bb, flags, tex, u, v)
		}
	}
}

@(private = "file")
FIXED_BITS :: 12

// d/dx and d/dy of an attribute across a triangle, in 12-bit fixed point,
// truncated toward zero. Together with the leftmost-vertex anchor this
// reproduces hardware VRAM dumps exactly.
@(private = "file")
gradients :: proc(a, b, c: Vertex, attr: proc(v: Vertex) -> i32) -> [2]i64 {
	denom := i64(b.x - a.x) * i64(c.y - b.y) - i64(c.x - b.x) * i64(b.y - a.y)
	if denom == 0 {
		return {}
	}
	pa, pb, pc := i64(attr(a)), i64(attr(b)), i64(attr(c))
	ddx := (pb - pa) * i64(c.y - b.y) - (pc - pb) * i64(b.y - a.y)
	ddy := i64(b.x - a.x) * (pc - pb) - i64(c.x - b.x) * (pb - pa)
	return {(ddx << FIXED_BITS) / denom, (ddy << FIXED_BITS) / denom}
}

@(private = "file")
draw_line :: proc(g: ^Gpu, a, b: Vertex, shaded, semi: bool) {
	dx := b.x - a.x
	dy := b.y - a.y
	if abs(dx) >= 1024 || abs(dy) >= 512 {
		return
	}
	k := max(abs(dx), abs(dy))
	flags: Draw_Flags
	if semi {flags += {.Semi}}
	if g.dither {flags += {.Dither}} // unlike polygons, flat lines are dithered too
	// The hardware always draws left to right, stepping 32.32 fixed-point
	// coordinates from the centre of the first pixel; steps round away from
	// zero, and lines going up start half a pixel lower.
	p0, p1 := a, b
	if k > 0 && p0.x >= p1.x {
		p0, p1 = b, a
	}
	divide :: proc(delta: i64, k: i64) -> i64 {
		d := delta << 32
		if d < 0 {d -= k - 1} else if d > 0 {d += k - 1}
		return d / k
	}
	HALF :: i64(1) << 31
	x := i64(p0.x) << 32 | HALF - 1024
	y := i64(p0.y) << 32 | HALF
	step_x, step_y: i64
	if k > 0 {
		step_x = divide(i64(p1.x - p0.x), i64(k))
		step_y = divide(i64(p1.y - p0.y), i64(k))
	}
	if step_y < 0 {
		y -= 1024
	}
	// colours step in 12-bit fixed point, from the middle of the first value
	col := [3]i64{i64(p0.r) << 12 | 1 << 11, i64(p0.g) << 12 | 1 << 11, i64(p0.b) << 12 | 1 << 11}
	col_step: [3]i64
	if shaded && k > 0 {
		col_step = {
			(i64(p1.r - p0.r) << 12) / i64(k),
			(i64(p1.g - p0.g) << 12) / i64(k),
			(i64(p1.b - p0.b) << 12) / i64(k),
		}
	}
	for _ in 0 ..= k {
		px := i32(((x >> 32) & 2047) << 21 >> 21) // 11-bit signed
		py := i32(((y >> 32) & 2047) << 21 >> 21)
		if in_area(g, px, py) {
			plot(g, px, py, i32(col[0] >> 12), i32(col[1] >> 12), i32(col[2] >> 12), flags, nil, 0, 0)
		}
		x += step_x
		y += step_y
		col += col_step
	}
}

@(private = "file")
draw_rect :: proc(g: ^Gpu, op: u32) {
	c := &g.cmd
	textured := op & 0x04 != 0 && !g.tex_disable
	i := 1
	x0, y0 := vertex_xy(g, c[i])
	i += 1
	tex: Texture_Info
	u0, v0: i32
	if op & 0x04 != 0 {
		uv := c[i]
		i += 1
		u0 = i32(uv & 0xFF)
		v0 = i32((uv >> 8) & 0xFF)
		tex = {
			clut_x    = i32((uv >> 16) & 0x3F) * 16,
			clut_y    = i32((uv >> 22) & 0x1FF),
			page_x    = g.tex_x,
			page_y    = g.tex_y,
			semi_mode = g.semi_mode,
			depth     = g.tex_depth,
		}
	}
	w, h: i32
	switch (op >> 3) & 3 {
	case 0:
		w = i32(c[i] & 0x3FF)
		h = i32((c[i] >> 16) & 0x1FF)
	case 1: w, h = 1, 1
	case 2: w, h = 8, 8
	case 3: w, h = 16, 16
	}
	flags: Draw_Flags
	if textured {flags += {.Textured}}
	if textured && op & 0x01 != 0 {flags += {.Raw}}
	if op & 0x02 != 0 {flags += {.Semi}}
	r := i32(c[0] & 0xFF)
	gg := i32((c[0] >> 8) & 0xFF)
	b := i32((c[0] >> 16) & 0xFF)
	if textured {
		clut_load(g, &tex)
	}

	for yy in 0 ..< h {
		y := y0 + yy
		if y < g.area_top || y > g.area_bottom {
			continue
		}
		for xx in 0 ..< w {
			x := x0 + xx
			if x < g.area_left || x > g.area_right {
				continue
			}
			// X-flipped rectangles start one texel over: the GPU forces the
			// low bit of U on before counting down.
			u := g.rect_flip_x ? (u0 | 1) - xx : u0 + xx
			v := g.rect_flip_y ? v0 - yy : v0 + yy
			plot(g, x, y, r, gg, b, flags, &tex, u, v)
		}
	}
}

// --- display output --------------------------------------------------------

@(private = "file", rodata)
HRES_WIDTHS := [8]int{256, 368, 320, 368, 512, 368, 640, 368}

// Copies the visible part of VRAM into the 24-bit output framebuffer.
gpu_build_frame :: proc(g: ^Gpu) {
	w := HRES_WIDTHS[g.hres & 7]
	h := g.vres_480 ? 480 : 240
	// Crop to the vertical display range when it is sensible.
	lines := int(g.v_end - g.v_start)
	if g.vres_480 && lines <= 256 {
		lines *= 2
	}
	if lines > 16 && lines < h {
		h = lines
	}
	g.out_w = w
	g.out_h = h
	if g.display_off {
		for &p in g.framebuffer[:w * h] {p = 0}
		return
	}
	for y in 0 ..< h {
		row := g.framebuffer[y * w:][:w]
		vy := g.disp_y + i32(y)
		if g.depth24 {
			// 24-bit: three bytes per pixel packed across 16-bit words
			base := vram_index(0, vy)
			for x in 0 ..< w {
				byte_off := int(g.disp_x) * 2 + x * 3
				b0 := vram_byte(g, base, byte_off)
				b1 := vram_byte(g, base, byte_off + 1)
				b2 := vram_byte(g, base, byte_off + 2)
				row[x] = u32(b0) << 16 | u32(b1) << 8 | u32(b2)
			}
		} else {
			for x in 0 ..< w {
				p := g.vram[vram_index(g.disp_x + i32(x), vy)]
				r := u32(p & 0x1F)
				gg := u32((p >> 5) & 0x1F)
				b := u32((p >> 10) & 0x1F)
				row[x] = (r << 3 | r >> 2) << 16 | (gg << 3 | gg >> 2) << 8 | (b << 3 | b >> 2)
			}
		}
	}
}

@(private = "file")
vram_byte :: #force_inline proc(g: ^Gpu, row_base: int, byte_off: int) -> u8 {
	word := g.vram[row_base + (byte_off / 2) % VRAM_W]
	return byte_off & 1 == 0 ? u8(word) : u8(word >> 8)
}
