package ps2

import "core:math"

// Graphics Synthesizer: drawing registers, the GIF packet interface, a
// software rasterizer (points, lines, triangles, sprites with Gouraud
// shading, texturing, alpha test/blend and depth test), host-to-local
// transfers and the display read-out circuits.

Gs_Vertex :: struct {
	x, y:  i32, // 12.4 fixed point, window coordinates (offset removed)
	z:     u32,
	rgba:  [4]u8,
	s, t, q: f32,
	u, v:  i32, // 12.4 fixed point texel coordinates
}

Gs_Context :: struct {
	xyoffset: u64,
	scissor:  u64,
	frame:    u64,
	zbuf:     u64,
	test:     u64,
	alpha:    u64,
	tex0:     u64,
	tex1:     u64,
	clamp:    u64,
	fba:      u64,
}

Gs_Transfer :: struct {
	active: bool,
	x, y:   u32, // progress inside the rectangle
	buf:    u64, // bits not yet forming a whole pixel
	bits:   u32,
}

Gs :: struct {
	mem:       [GS_MEM_WORDS]u32,
	ctx:       [2]Gs_Context,
	prim:      u64,
	prmode:    u64,
	prmodecont: bool,
	rgbaq:     u64,
	q:         f32,
	st:        u64,
	uv:        u64,
	texa:      u64,
	colclamp:  u64,
	pabe:      u64,
	dthe:      u64,
	bitbltbuf: u64,
	trxpos:    u64,
	trxreg:    u64,
	xfer:      Gs_Transfer,
	queue:     [3]Gs_Vertex,
	count:     int,
	strip_fan_first: bool,
	// GIF
	tag:       u128,
	nloop:     u32,
	nreg:      u32,
	reg_index: u32,
	in_packet: bool,
	// read-out
	frame_px:  []u32, // allocated by the console: 1024 x 1024 max
	frame_w:   int,
	frame_h:   int,
}

gs_reset :: proc(g: ^Gs) {
	px := g.frame_px
	g^ = {}
	g.frame_px = px
	g.prmodecont = true
	g.colclamp = 1
	g.q = 1
}

// --- register writes -----------------------------------------------------------

gs_write_reg :: proc(g: ^Gs, reg: u32, v: u64) {
	switch reg {
	case 0x00:
		g.prim = v
		g.count = 0
	case 0x01:
		g.rgbaq = v
		g.q = transmute(f32)u32(v >> 32)
	case 0x02: g.st = v
	case 0x03: g.uv = v
	case 0x04: vertex_kick(g, i32(v & 0xFFFF), i32((v >> 16) & 0xFFFF), u32((v >> 32) & 0xFF_FFFF), true)
	case 0x05: vertex_kick(g, i32(v & 0xFFFF), i32((v >> 16) & 0xFFFF), u32(v >> 32), true)
	case 0x0C: vertex_kick(g, i32(v & 0xFFFF), i32((v >> 16) & 0xFFFF), u32((v >> 32) & 0xFF_FFFF), false)
	case 0x0D: vertex_kick(g, i32(v & 0xFFFF), i32((v >> 16) & 0xFFFF), u32(v >> 32), false)
	case 0x06, 0x07: g.ctx[reg - 0x06].tex0 = v
	case 0x08, 0x09: g.ctx[reg - 0x08].clamp = v
	case 0x14, 0x15: g.ctx[reg - 0x14].tex1 = v
	case 0x16, 0x17: // TEX2: updates the CLUT fields of TEX0
		t := &g.ctx[reg - 0x16].tex0
		mask := u64(0xFFFF_FFE0_0000_0000) | u64(0x3F) << 20
		t^ = (t^ & ~mask) | (v & mask)
	case 0x18, 0x19: g.ctx[reg - 0x18].xyoffset = v
	case 0x1A: g.prmodecont = v & 1 != 0
	case 0x1B: g.prmode = v
	case 0x3B: g.texa = v
	case 0x40, 0x41: g.ctx[reg - 0x40].scissor = v
	case 0x42, 0x43: g.ctx[reg - 0x42].alpha = v
	case 0x45: g.dthe = v
	case 0x46: g.colclamp = v
	case 0x47, 0x48: g.ctx[reg - 0x47].test = v
	case 0x49: g.pabe = v
	case 0x4A, 0x4B: g.ctx[reg - 0x4A].fba = v
	case 0x4C, 0x4D: g.ctx[reg - 0x4C].frame = v
	case 0x4E, 0x4F: g.ctx[reg - 0x4E].zbuf = v
	case 0x50: g.bitbltbuf = v
	case 0x51: g.trxpos = v
	case 0x52: g.trxreg = v
	case 0x53: transfer_start(g, u32(v & 3))
	case 0x54: transfer_data(g, v)
	}
}

// Attribute bits used for drawing: PRIM itself or PRMODE.
@(private = "file")
attr :: #force_inline proc(g: ^Gs) -> u64 {
	return g.prmodecont ? g.prim : (g.prim & 7) | (g.prmode & ~u64(7))
}

@(private = "file", rodata)
VERTS_PER_PRIM := [8]int{1, 2, 2, 3, 3, 3, 2, 1}

@(private = "file")
vertex_kick :: proc(g: ^Gs, x, y: i32, z: u32, draw: bool) {
	a := attr(g)
	c := &g.ctx[(a >> 9) & 1]
	ofx := i32(c.xyoffset & 0xFFFF)
	ofy := i32((c.xyoffset >> 32) & 0xFFFF)
	vtx := Gs_Vertex {
		x = x - ofx,
		y = y - ofy,
		z = z,
		rgba = {u8(g.rgbaq), u8(g.rgbaq >> 8), u8(g.rgbaq >> 16), u8(g.rgbaq >> 24)},
		s = transmute(f32)u32(g.st),
		t = transmute(f32)u32(g.st >> 32),
		q = g.q,
		u = i32(g.uv & 0x3FFF),
		v = i32((g.uv >> 16) & 0x3FFF),
	}
	kind := g.prim & 7
	needed := VERTS_PER_PRIM[kind]
	if g.count < 3 {
		g.queue[g.count] = vtx
		g.count += 1
	}
	if g.count < needed {
		return
	}
	if draw {
		switch kind {
		case 0: draw_point(g, g.queue[0])
		case 1, 2: draw_line(g, g.queue[0], g.queue[1])
		case 3, 4, 5: draw_triangle(g, g.queue[0], g.queue[1], g.queue[2])
		case 6: draw_sprite(g, g.queue[0], g.queue[1])
		}
	}
	switch kind {
	case 2: // line strip keeps the last vertex
		g.queue[0] = g.queue[1]
		g.count = 1
	case 4: // triangle strip
		g.queue[0], g.queue[1] = g.queue[1], g.queue[2]
		g.count = 2
	case 5: // fan keeps the first
		g.queue[1] = g.queue[2]
		g.count = 2
	case:
		g.count = 0
	}
}

// --- per-pixel pipeline -----------------------------------------------------------

@(private = "file")
Pixel_State :: struct {
	attr:     u64,
	ctx:      ^Gs_Context,
	fbp, fbw, fpsm: u32,
	fbmsk:    u32,
	zbp, zpsm: u32,
	zmsk:     bool,
	test:     u64,
	alpha:    u64,
	sx0, sx1, sy0, sy1: i32,
	tex:      bool,
	tbp, tbw, tpsm, tw, th: u32,
	tcc:      bool,
	tfx:      u32,
	wms, wmt: u32,
	minu, maxu, minv, maxv: u32,
	cbp, cpsm: u32,
	abe:      bool,
	fst:      bool,
}

@(private = "file")
pixel_state :: proc(g: ^Gs) -> Pixel_State {
	a := attr(g)
	c := &g.ctx[(a >> 9) & 1]
	p := Pixel_State{attr = a, ctx = c}
	p.fbp = u32(c.frame & 0x1FF) * 32
	p.fbw = u32((c.frame >> 16) & 0x3F)
	p.fpsm = u32((c.frame >> 24) & 0x3F)
	p.fbmsk = u32(c.frame >> 32)
	p.zbp = u32(c.zbuf & 0x1FF) * 32
	p.zpsm = u32((c.zbuf >> 24) & 0xF) | 0x30
	p.zmsk = (c.zbuf >> 32) & 1 != 0
	p.test = c.test
	p.alpha = c.alpha
	p.sx0 = i32(c.scissor & 0x7FF)
	p.sx1 = i32((c.scissor >> 16) & 0x7FF)
	p.sy0 = i32((c.scissor >> 32) & 0x7FF)
	p.sy1 = i32((c.scissor >> 48) & 0x7FF)
	p.tex = a & 0x10 != 0
	p.abe = a & 0x40 != 0
	p.fst = a & 0x100 != 0
	t := c.tex0
	p.tbp = u32(t & 0x3FFF)
	p.tbw = u32((t >> 14) & 0x3F)
	p.tpsm = u32((t >> 20) & 0x3F)
	p.tw = 1 << min(u32((t >> 26) & 0xF), 10)
	p.th = 1 << min(u32((t >> 30) & 0xF), 10)
	p.tcc = (t >> 34) & 1 != 0
	p.tfx = u32((t >> 35) & 3)
	p.cbp = u32((t >> 37) & 0x3FFF)
	p.cpsm = u32((t >> 51) & 0xF)
	cl := c.clamp
	p.wms = u32(cl & 3)
	p.wmt = u32((cl >> 2) & 3)
	p.minu = u32((cl >> 4) & 0x3FF)
	p.maxu = u32((cl >> 14) & 0x3FF)
	p.minv = u32((cl >> 24) & 0x3FF)
	p.maxv = u32((cl >> 34) & 0x3FF)
	return p
}

@(private = "file")
wrap :: #force_inline proc(v: i32, size: u32, mode: u32, lo, hi: u32) -> u32 {
	switch mode {
	case 1: return u32(clamp(v, 0, i32(size) - 1))
	case 2: return u32(clamp(v, i32(lo), i32(hi)))
	case 3: return (u32(v) & lo) | hi
	}
	return u32(v) & (size - 1)
}

@(private = "file")
clut_entry :: proc(g: ^Gs, p: ^Pixel_State, index: u32) -> u32 {
	x, y: u32
	if p.tpsm == PSMT8 || p.tpsm == PSMT8H {
		// bits 3 and 4 of the index are swapped in the CLUT layout
		i := (index & 0xE7) | (index & 0x08) << 1 | (index & 0x10) >> 1
		x, y = i & 15, i >> 4
	} else {
		x, y = index & 7, index >> 3
	}
	if p.cpsm == PSMCT32 || p.cpsm == PSMCT24 {
		return gs_read_pixel(g, p.cbp, 1, PSMCT32, x, y)
	}
	return texa16(g, gs_read_pixel(g, p.cbp, 1, p.cpsm, x, y))
}

@(private = "file")
texa16 :: #force_inline proc(g: ^Gs, c: u32) -> u32 {
	return rgba16_to_32(c, u32(g.texa & 0xFF), u32((g.texa >> 32) & 0xFF), (g.texa >> 15) & 1 != 0)
}

@(private = "file")
sample :: proc(g: ^Gs, p: ^Pixel_State, tu, tv: i32) -> u32 {
	u := wrap(tu, p.tw, p.wms, p.minu, p.maxu)
	v := wrap(tv, p.th, p.wmt, p.minv, p.maxv)
	switch p.tpsm {
	case PSMCT32: return gs_read_pixel(g, p.tbp, p.tbw, PSMCT32, u, v)
	case PSMCT24:
		c := gs_read_pixel(g, p.tbp, p.tbw, PSMCT24, u, v)
		a := u32(g.texa & 0xFF)
		if (g.texa >> 15) & 1 != 0 && c == 0 {a = 0}
		return c | a << 24
	case PSMCT16, PSMCT16S:
		return texa16(g, gs_read_pixel(g, p.tbp, p.tbw, p.tpsm, u, v))
	case PSMT8, PSMT4, PSMT8H, PSMT4HL, PSMT4HH:
		return clut_entry(g, p, gs_read_pixel(g, p.tbp, p.tbw, p.tpsm, u, v))
	}
	return 0
}

@(private = "file")
draw_pixel :: proc(g: ^Gs, p: ^Pixel_State, x, y: i32, z: u32, col: [4]i32, s, t, q: f32, uu, vv: i32) {
	if x < p.sx0 || x > p.sx1 || y < p.sy0 || y > p.sy1 || x < 0 || y < 0 {
		return
	}
	r, gg, b, a := col[0], col[1], col[2], col[3]
	if p.tex {
		tu, tv: i32
		if p.fst {
			tu, tv = uu >> 4, vv >> 4
		} else {
			qq := q == 0 ? 1 : q
			tu = i32(math.floor(s / qq * f32(p.tw)))
			tv = i32(math.floor(t / qq * f32(p.th)))
		}
		tc := sample(g, p, tu, tv)
		tr, tg, tb, ta := i32(tc & 0xFF), i32((tc >> 8) & 0xFF), i32((tc >> 16) & 0xFF), i32(tc >> 24)
		switch p.tfx {
		case 0: // modulate
			r, gg, b = min(tr * r >> 7, 255), min(tg * gg >> 7, 255), min(tb * b >> 7, 255)
			if p.tcc {a = min(ta * a >> 7, 255)}
		case 1: // decal
			r, gg, b = tr, tg, tb
			if p.tcc {a = ta}
		case 2, 3: // highlight
			r = min((tr * r >> 7) + a, 255)
			gg = min((tg * gg >> 7) + a, 255)
			b = min((tb * b >> 7) + a, 255)
			if p.tcc {a = p.tfx == 2 ? min(a + ta, 255) : ta}
		}
	}

	ux, uy := u32(x), u32(y)
	write_fb, write_z := true, !p.zmsk
	// alpha test
	if p.test & 1 != 0 {
		aref := i32((p.test >> 4) & 0xFF)
		pass: bool
		switch (p.test >> 1) & 7 {
		case 0: pass = false
		case 1: pass = true
		case 2: pass = a < aref
		case 3: pass = a <= aref
		case 4: pass = a == aref
		case 5: pass = a >= aref
		case 6: pass = a > aref
		case 7: pass = a != aref
		}
		if !pass {
			switch (p.test >> 12) & 3 {
			case 0: return
			case 1: write_z = false
			case 2: write_fb = false
			case 3: write_z = false // RGB only: alpha kept below via mask
			}
		}
	}
	// depth test
	if p.test & (1 << 16) != 0 {
		zcur := gs_read_pixel(g, p.zbp, p.fbw, p.zpsm, ux, uy)
		switch (p.test >> 17) & 3 {
		case 0: return
		case 2: if z < zcur {return}
		case 3: if z <= zcur {return}
		}
	}
	if p.abe && (g.pabe & 1 == 0 || a & 0x80 != 0) {
		d := gs_read_pixel(g, p.fbp, p.fbw, p.fpsm, ux, uy)
		if p.fpsm == PSMCT16 || p.fpsm == PSMCT16S {
			d = rgba16_to_32(d, 0, 0x80, false)
		} else if p.fpsm == PSMCT24 {
			d |= 0x8000_0000
		}
		src := [3]i32{r, gg, b}
		dst := [3]i32{i32(d & 0xFF), i32((d >> 8) & 0xFF), i32((d >> 16) & 0xFF)}
		da := i32(d >> 24)
		al := p.alpha
		cfac: i32
		switch (al >> 4) & 3 {
		case 0: cfac = a
		case 1: cfac = da
		case: cfac = i32((al >> 32) & 0xFF)
		}
		out: [3]i32
		for i in 0 ..< 3 {
			pick :: #force_inline proc(sel: u64, s, d: i32) -> i32 {
				switch sel {
				case 0: return s
				case 1: return d
				}
				return 0
			}
			va := pick(al & 3, src[i], dst[i])
			vb := pick((al >> 2) & 3, src[i], dst[i])
			vd := pick((al >> 6) & 3, src[i], dst[i])
			out[i] = ((va - vb) * cfac >> 7) + vd
		}
		r, gg, b = out[0], out[1], out[2]
	}
	if g.colclamp & 1 != 0 {
		r, gg, b = clamp(r, 0, 255), clamp(gg, 0, 255), clamp(b, 0, 255)
	} else {
		r, gg, b = r & 0xFF, gg & 0xFF, b & 0xFF
	}
	if write_fb {
		c := u32(r) | u32(gg) << 8 | u32(b) << 16 | u32(a & 0xFF) << 24
		if p.ctx.fba & 1 != 0 {c |= 0x8000_0000}
		mask := p.fbmsk
		if p.test & 1 != 0 && (p.test >> 12) & 3 == 3 {mask |= 0xFF00_0000}
		if p.fpsm == PSMCT16 || p.fpsm == PSMCT16S {
			gs_write_pixel(g, p.fbp, p.fbw, p.fpsm, ux, uy, rgba32_to_16(c), rgba32_to_16(mask))
		} else {
			gs_write_pixel(g, p.fbp, p.fbw, p.fpsm, ux, uy, c, mask)
		}
	}
	if write_z && p.test & (1 << 16) != 0 {
		gs_write_pixel(g, p.zbp, p.fbw, p.zpsm, ux, uy, z)
	}
}

@(private = "file")
color_of :: #force_inline proc(v: Gs_Vertex) -> [4]i32 {
	return {i32(v.rgba[0]), i32(v.rgba[1]), i32(v.rgba[2]), i32(v.rgba[3])}
}

@(private = "file")
draw_point :: proc(g: ^Gs, v: Gs_Vertex) {
	p := pixel_state(g)
	draw_pixel(g, &p, (v.x + 8) >> 4, (v.y + 8) >> 4, v.z, color_of(v), v.s, v.t, v.q, v.u, v.v)
}

@(private = "file")
draw_sprite :: proc(g: ^Gs, a0, b0: Gs_Vertex) {
	p := pixel_state(g)
	a, b := a0, b0
	if a.x > b.x {a.x, b.x, a.u, b.u, a.s, b.s = b.x, a.x, b.u, a.u, b.s, a.s}
	if a.y > b.y {a.y, b.y, a.v, b.v, a.t, b.t = b.y, a.y, b.v, a.v, b.t, a.t}
	// pixels whose centre is inside [x0, x1): top-left fill convention
	x0 := max((a.x + 15) >> 4, p.sx0)
	x1 := min((b.x + 15) >> 4, p.sx1 + 1)
	y0 := max((a.y + 15) >> 4, p.sy0)
	y1 := min((b.y + 15) >> 4, p.sy1 + 1)
	col := color_of(b0) // sprites are flat, with the colour of the last vertex
	w := f32(max(b.x - a.x, 1))
	h := f32(max(b.y - a.y, 1))
	for y in y0 ..< y1 {
		fy := (f32(y * 16 - a.y)) / h
		for x in x0 ..< x1 {
			fx := (f32(x * 16 - a.x)) / w
			uu := a.u + i32(fx * f32(b.u - a.u))
			vv := a.v + i32(fy * f32(b.v - a.v))
			s := a.s + fx * (b.s - a.s)
			t := a.t + fy * (b.t - a.t)
			draw_pixel(g, &p, x, y, b0.z, col, s, t, b0.q, uu, vv)
		}
	}
}

@(private = "file")
draw_line :: proc(g: ^Gs, a, b: Gs_Vertex) {
	p := pixel_state(g)
	gouraud := p.attr & 0x08 != 0
	x0, y0 := f32(a.x) / 16, f32(a.y) / 16
	x1, y1 := f32(b.x) / 16, f32(b.y) / 16
	steps := int(max(abs(x1 - x0), abs(y1 - y0)))
	ca, cb := color_of(a), color_of(b)
	for i in 0 ..= max(steps, 0) {
		k := steps == 0 ? 0 : f32(i) / f32(steps)
		col := cb
		if gouraud {
			for j in 0 ..< 4 {col[j] = ca[j] + i32(f32(cb[j] - ca[j]) * k)}
		}
		z := u32(f32(a.z) + (f32(b.z) - f32(a.z)) * k)
		draw_pixel(g, &p, i32(math.round(x0 + (x1 - x0) * k)), i32(math.round(y0 + (y1 - y0) * k)), z, col,
			a.s + (b.s - a.s) * k, a.t + (b.t - a.t) * k, a.q + (b.q - a.q) * k,
			a.u + i32(f32(b.u - a.u) * k), a.v + i32(f32(b.v - a.v) * k))
	}
}

@(private = "file")
draw_triangle :: proc(g: ^Gs, v0, v1, v2: Gs_Vertex) {
	p := pixel_state(g)
	gouraud := p.attr & 0x08 != 0
	area := i64(v1.x - v0.x) * i64(v2.y - v0.y) - i64(v2.x - v0.x) * i64(v1.y - v0.y)
	if area == 0 {
		return
	}
	minx := max((min(v0.x, v1.x, v2.x) + 15) >> 4, p.sx0)
	maxx := min((max(v0.x, v1.x, v2.x) + 15) >> 4, p.sx1 + 1)
	miny := max((min(v0.y, v1.y, v2.y) + 15) >> 4, p.sy0)
	maxy := min((max(v0.y, v1.y, v2.y) + 15) >> 4, p.sy1 + 1)
	inv := 1 / f64(area)
	c0, c1, c2 := color_of(v0), color_of(v1), color_of(v2)
	flat := color_of(v2)

	edge :: #force_inline proc(ax, ay, bx, by, px, py: i32) -> i64 {
		return i64(bx - ax) * i64(py - ay) - i64(by - ay) * i64(px - ax)
	}
	// Top-left rule: pixels exactly on a right/bottom edge are excluded.
	bias :: #force_inline proc(ax, ay, bx, by: i32, positive: bool) -> i64 {
		top_left := (ay == by && (positive ? bx < ax : bx > ax)) || (positive ? by < ay : by > ay)
		return top_left ? 0 : -1
	}
	positive := area > 0
	b0 := bias(v1.x, v1.y, v2.x, v2.y, positive)
	b1 := bias(v2.x, v2.y, v0.x, v0.y, positive)
	b2 := bias(v0.x, v0.y, v1.x, v1.y, positive)
	for y in miny ..< maxy {
		py := y * 16
		for x in minx ..< maxx {
			px := x * 16
			w0 := edge(v1.x, v1.y, v2.x, v2.y, px, py)
			w1 := edge(v2.x, v2.y, v0.x, v0.y, px, py)
			w2 := edge(v0.x, v0.y, v1.x, v1.y, px, py)
			if !positive {w0, w1, w2 = -w0, -w1, -w2}
			if w0 + b0 < 0 || w1 + b1 < 0 || w2 + b2 < 0 {
				continue
			}
			l0 := f32(f64(abs(w0)) * abs(inv))
			l1 := f32(f64(abs(w1)) * abs(inv))
			l2 := 1 - l0 - l1
			col := flat
			if gouraud {
				for j in 0 ..< 4 {
					col[j] = clamp(i32(math.round(l0 * f32(c0[j]) + l1 * f32(c1[j]) + l2 * f32(c2[j]))), 0, 255)
				}
			}
			z := u32(clamp(f64(l0) * f64(v0.z) + f64(l1) * f64(v1.z) + f64(l2) * f64(v2.z), 0, 4294967295))
			s := l0 * v0.s + l1 * v1.s + l2 * v2.s
			t := l0 * v0.t + l1 * v1.t + l2 * v2.t
			q := l0 * v0.q + l1 * v1.q + l2 * v2.q
			uu := i32(l0 * f32(v0.u) + l1 * f32(v1.u) + l2 * f32(v2.u))
			vv := i32(l0 * f32(v0.v) + l1 * f32(v1.v) + l2 * f32(v2.v))
			draw_pixel(g, &p, x, y, z, col, s, t, q, uu, vv)
		}
	}
}

// --- transfers ------------------------------------------------------------------

@(private = "file")
psm_bits :: proc(psm: u32) -> u32 {
	switch psm {
	case PSMCT32, PSMZ32: return 32
	case PSMCT24, PSMZ24: return 24
	case PSMCT16, PSMCT16S, PSMZ16, PSMZ16S: return 16
	case PSMT8, PSMT8H: return 8
	case PSMT4, PSMT4HL, PSMT4HH: return 4
	}
	return 32
}

@(private = "file")
transfer_start :: proc(g: ^Gs, dir: u32) {
	g.xfer = {}
	switch dir {
	case 0: g.xfer.active = true // host -> local, data follows
	case 2: transfer_local(g)
	}
}

@(private = "file")
transfer_data :: proc(g: ^Gs, data: u64) {
	x := &g.xfer
	if !x.active {
		return
	}
	dbp := u32((g.bitbltbuf >> 32) & 0x3FFF)
	dbw := u32((g.bitbltbuf >> 48) & 0x3F)
	dpsm := u32((g.bitbltbuf >> 56) & 0x3F)
	dsax := u32((g.trxpos >> 32) & 0x7FF)
	dsay := u32((g.trxpos >> 48) & 0x7FF)
	rrw := u32(g.trxreg & 0xFFF)
	rrh := u32((g.trxreg >> 32) & 0xFFF)
	bits := psm_bits(dpsm)
	if rrw == 0 || rrh == 0 {
		x.active = false
		return
	}
	// Feed the 64 bits through a small accumulator: 24-bit pixels straddle words.
	remaining: u32 = 64
	d := data
	for remaining > 0 && x.active {
		take := min(remaining, 32)
		x.buf |= (d & ((u64(1) << take) - 1)) << x.bits
		x.bits += take
		d >>= take
		remaining -= take
		for x.bits >= bits && x.active {
			pix := u32(x.buf & ((u64(1) << bits) - 1))
			x.buf >>= bits
			x.bits -= bits
			gs_write_pixel(g, dbp, dbw, dpsm, (dsax + x.x) & 2047, (dsay + x.y) & 2047, pix)
			x.x += 1
			if x.x >= rrw {
				x.x = 0
				x.y += 1
				if x.y >= rrh {
					x.active = false
				}
			}
		}
	}
}

@(private = "file")
transfer_local :: proc(g: ^Gs) {
	sbp := u32(g.bitbltbuf & 0x3FFF)
	sbw := u32((g.bitbltbuf >> 16) & 0x3F)
	spsm := u32((g.bitbltbuf >> 24) & 0x3F)
	dbp := u32((g.bitbltbuf >> 32) & 0x3FFF)
	dbw := u32((g.bitbltbuf >> 48) & 0x3F)
	dpsm := u32((g.bitbltbuf >> 56) & 0x3F)
	ssax, ssay := u32(g.trxpos & 0x7FF), u32((g.trxpos >> 16) & 0x7FF)
	dsax, dsay := u32((g.trxpos >> 32) & 0x7FF), u32((g.trxpos >> 48) & 0x7FF)
	rrw, rrh := u32(g.trxreg & 0xFFF), u32((g.trxreg >> 32) & 0xFFF)
	for y in 0 ..< rrh {
		for x in 0 ..< rrw {
			v := gs_read_pixel(g, sbp, sbw, spsm, (ssax + x) & 2047, (ssay + y) & 2047)
			gs_write_pixel(g, dbp, dbw, dpsm, (dsax + x) & 2047, (dsay + y) & 2047, v)
		}
	}
}

// --- GIF --------------------------------------------------------------------------

// Feeds one quadword to the GIF (from PATH3 DMA or the FIFO register).
gif_write :: proc(g: ^Gs, q: u128) {
	if !g.in_packet || g.nloop == 0 {
		// a new GIF tag
		g.tag = q
		g.nloop = u32(q & 0x7FFF)
		g.nreg = u32((q >> 60) & 0xF)
		if g.nreg == 0 {g.nreg = 16}
		g.reg_index = 0
		g.in_packet = g.nloop > 0
		if (q >> 46) & 1 != 0 && (q >> 58) & 3 == 0 { // PRE: set PRIM
			gs_write_reg(g, 0x00, u64((q >> 47) & 0x7FF))
		}
		return
	}
	switch (g.tag >> 58) & 3 {
	case 0: // PACKED
		reg := u32((g.tag >> (64 + 4 * u128(g.reg_index))) & 0xF)
		packed_write(g, reg, q)
		advance(g)
	case 1: // REGLIST: two registers per quadword
		for half in 0 ..< 2 {
			if !g.in_packet {break}
			reg := u32((g.tag >> (64 + 4 * u128(g.reg_index))) & 0xF)
			v := u64(q >> (64 * u128(half)))
			if reg != 0xE && reg != 0xF {
				gs_write_reg(g, reg, v)
			}
			advance(g)
		}
	case 2, 3: // IMAGE
		transfer_data(g, u64(q))
		transfer_data(g, u64(q >> 64))
		g.nloop -= 1
		if g.nloop == 0 {g.in_packet = false}
	}
}

@(private = "file")
advance :: proc(g: ^Gs) {
	g.reg_index += 1
	if g.reg_index >= g.nreg {
		g.reg_index = 0
		g.nloop -= 1
		if g.nloop == 0 {
			g.in_packet = false
		}
	}
}

@(private = "file")
packed_write :: proc(g: ^Gs, reg: u32, q: u128) {
	lo := u64(q)
	hi := u64(q >> 64)
	switch reg {
	case 0x0: gs_write_reg(g, 0x00, lo & 0x7FF)
	case 0x1: // RGBAQ with Q taken from the last ST
		r := lo & 0xFF
		gg := (lo >> 32) & 0xFF
		b := hi & 0xFF
		a := (hi >> 32) & 0xFF
		g.rgbaq = r | gg << 8 | b << 16 | a << 24 | u64(transmute(u32)g.q) << 32
	case 0x2: // ST, and Q for the following RGBAQ
		g.st = lo
		g.q = transmute(f32)u32(hi)
	case 0x3: gs_write_reg(g, 0x03, (lo & 0x3FFF) | ((lo >> 32) & 0x3FFF) << 16)
	case 0x4: // XYZF2 (or XYZF3 when ADC is set)
		x := lo & 0xFFFF
		y := (lo >> 32) & 0xFFFF
		z := (hi >> 4) & 0xFF_FFFF
		f := (hi >> 36) & 0xFF
		v := x | y << 16 | z << 32 | f << 56
		gs_write_reg(g, (hi >> 47) & 1 != 0 ? 0x0C : 0x04, v)
	case 0x5:
		x := lo & 0xFFFF
		y := (lo >> 32) & 0xFFFF
		z := hi & 0xFFFF_FFFF
		gs_write_reg(g, (hi >> 47) & 1 != 0 ? 0x0D : 0x05, x | y << 16 | z << 32)
	case 0xE: gs_write_reg(g, u32(hi & 0xFF), lo) // A+D
	case 0xF: // NOP
	case: gs_write_reg(g, reg, lo)
	}
}

// --- display ------------------------------------------------------------------

// Builds the visible picture from the enabled read circuit (circuit 2 when
// both are on, as games normally use it for the main picture).
gs_read_out :: proc(c: ^Console) {
	g := &c.gs
	priv := &c.gs_priv
	pmode := priv[0]
	circuit := -1
	if pmode & 2 != 0 {circuit = 1} else if pmode & 1 != 0 {circuit = 0}
	if circuit < 0 || len(g.frame_px) == 0 {
		g.frame_w, g.frame_h = 640, 448
		for &p in g.frame_px[:640 * 448] {p = 0}
		return
	}
	base := circuit == 0 ? 0x70 / 4 : 0x90 / 4
	dispfb := u64(priv[base]) | u64(priv[base + 1]) << 32
	display := u64(priv[base + 4]) | u64(priv[base + 5]) << 32
	fbp := u32(dispfb & 0x1FF) * 32
	fbw := u32((dispfb >> 9) & 0x3F)
	psm := u32((dispfb >> 15) & 0x1F)
	dbx := u32((dispfb >> 32) & 0x7FF)
	dby := u32((dispfb >> 43) & 0x7FF)
	magh := u32((display >> 23) & 0xF) + 1
	magv := u32((display >> 27) & 0x3) + 1
	dw := u32((display >> 32) & 0xFFF) + 1
	dh := u32((display >> 44) & 0x7FF) + 1
	w := int(clamp(dw / magh, 1, 1024))
	h := int(clamp(dh / magv, 1, 1024))
	// Interlaced frame mode shows every line of the buffer.
	smode2 := priv[0x20 / 4]
	if smode2 & 1 != 0 && smode2 & 2 != 0 && h < 300 {
		h *= 2
	}
	h = min(h, 1024)
	g.frame_w, g.frame_h = w, h
	for y in 0 ..< h {
		for x in 0 ..< w {
			v := gs_read_pixel(g, fbp, fbw, psm, (dbx + u32(x)) & 2047, (dby + u32(y)) & 2047)
			if psm == PSMCT16 || psm == PSMCT16S {
				v = rgba16_to_32(v, 0, 0, false)
			}
			g.frame_px[y * w + x] = (v & 0xFF) << 16 | (v & 0xFF00) | (v >> 16) & 0xFF
		}
	}
}
