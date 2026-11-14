package gba

// Picture processing: text and affine backgrounds, the three bitmap modes,
// regular and affine sprites, windows and color effects. Lines are rendered
// whole at the start of horizontal blank.

SCREEN_W :: 240
SCREEN_H :: 160

LINE_CYCLES  :: 1232
HBLANK_START :: 1006
TOTAL_LINES  :: 228

TRANSPARENT :: u32(0x8000_0000)

Ppu :: struct {
	dispcnt:   u16,
	dispstat:  u16,
	vcount:    u16,
	bgcnt:     [4]u16,
	hofs:      [4]u16,
	vofs:      [4]u16,
	affine:    [2][4]i16, // pa, pb, pc, pd for BG2 and BG3
	ref:       [2][2]i32, // reference point registers (x, y)
	internal:  [2][2]i32, // current reference point, advanced every line
	winh:      [2]u16,
	winv:      [2]u16,
	winin:     u16,
	winout:    u16,
	mosaic:    u16,
	bldcnt:    u16,
	bldalpha:  u16,
	bldy:      u16,
	green_swap: u16,
	cycle:     int,
	framebuffer: [SCREEN_W * SCREEN_H]u32,
}

ppu_reset :: proc(p: ^Ppu) {
	p^ = {}
	p.dispcnt = 0x0080
	p.affine = {{256, 0, 0, 256}, {256, 0, 0, 256}}
}

ppu_read16 :: proc(c: ^Console, a: u32) -> u16 {
	p := &c.ppu
	switch a {
	case 0x00: return p.dispcnt
	case 0x02: return p.green_swap
	case 0x04: return p.dispstat
	case 0x06: return p.vcount
	case 0x08, 0x0A, 0x0C, 0x0E: return p.bgcnt[(a - 8) / 2]
	case 0x48: return p.winin
	case 0x4A: return p.winout
	case 0x50: return p.bldcnt
	case 0x52: return p.bldalpha
	}
	return 0 // everything else is write-only
}

ppu_write16 :: proc(c: ^Console, a: u32, v: u16) {
	p := &c.ppu
	switch a {
	case 0x00: p.dispcnt = v
	case 0x02: p.green_swap = v
	case 0x04:
		p.dispstat = (p.dispstat & 0x0007) | (v & 0xFF38)
		check_vcount(c)
	case 0x08, 0x0A, 0x0C, 0x0E:
		mask: u16 = a >= 0x0C ? 0xFFFF : 0xDFFF
		p.bgcnt[(a - 8) / 2] = v & mask
	case 0x10, 0x14, 0x18, 0x1C: p.hofs[(a - 0x10) / 4] = v & 0x1FF
	case 0x12, 0x16, 0x1A, 0x1E: p.vofs[(a - 0x12) / 4] = v & 0x1FF
	case 0x20 ..= 0x26: p.affine[0][(a - 0x20) / 2] = i16(v)
	case 0x30 ..= 0x36: p.affine[1][(a - 0x30) / 2] = i16(v)
	case 0x28 ..= 0x2E, 0x38 ..= 0x3E:
		bg := a >= 0x38 ? 1 : 0
		off := a - (bg == 1 ? 0x38 : 0x28)
		axis := int(off / 4)
		r := u32(p.ref[bg][axis])
		if off & 2 == 0 {
			r = (r & 0xFFFF_0000) | u32(v)
		} else {
			r = (r & 0x0000_FFFF) | u32(v & 0x0FFF) << 16
		}
		// 28-bit signed fixed point
		p.ref[bg][axis] = i32(r << 4) >> 4
		p.internal[bg][axis] = p.ref[bg][axis]
	case 0x40, 0x42: p.winh[(a - 0x40) / 2] = v
	case 0x44, 0x46: p.winv[(a - 0x44) / 2] = v
	case 0x48: p.winin = v & 0x3F3F
	case 0x4A: p.winout = v & 0x3F3F
	case 0x4C: p.mosaic = v
	case 0x50: p.bldcnt = v & 0x3FFF
	case 0x52: p.bldalpha = v & 0x1F1F
	case 0x54: p.bldy = v & 0x1F
	}
}

@(private = "file")
check_vcount :: proc(c: ^Console) {
	p := &c.ppu
	match := p.vcount == p.dispstat >> 8
	if match {
		if p.dispstat & 0x04 == 0 && p.dispstat & 0x20 != 0 {
			irq_raise(c, IRQ_VCOUNT)
		}
		p.dispstat |= 0x04
	} else {
		p.dispstat &= ~u16(0x04)
	}
}

// Cycles until the PPU next changes state (used to skip halted time).
ppu_next_event :: proc(p: ^Ppu) -> int {
	if p.cycle < HBLANK_START {
		return HBLANK_START - p.cycle
	}
	return LINE_CYCLES - p.cycle
}

// Advances the PPU. Returns true when a frame has finished.
ppu_step :: proc(c: ^Console, cycles: int) -> bool {
	p := &c.ppu
	done := false
	p.cycle += cycles
	for {
		if p.dispstat & 0x02 == 0 && p.cycle >= HBLANK_START {
			p.dispstat |= 0x02
			if int(p.vcount) < SCREEN_H {
				render_line(c, int(p.vcount))
				dma_trigger(c, DMA_HBLANK)
			}
			if p.dispstat & 0x10 != 0 {
				irq_raise(c, IRQ_HBLANK)
			}
			continue
		}
		if p.cycle < LINE_CYCLES {
			break
		}
		p.cycle -= LINE_CYCLES
		p.dispstat &= ~u16(0x02)
		p.vcount += 1
		if int(p.vcount) < SCREEN_H {
			// affine reference points step by (pb, pd) every line
			for bg in 0 ..< 2 {
				p.internal[bg][0] += i32(p.affine[bg][1])
				p.internal[bg][1] += i32(p.affine[bg][3])
			}
		}
		if int(p.vcount) == SCREEN_H {
			p.dispstat |= 0x01
			if p.dispstat & 0x08 != 0 {
				irq_raise(c, IRQ_VBLANK)
			}
			dma_trigger(c, DMA_VBLANK)
			p.internal = p.ref
			done = true
		}
		if int(p.vcount) == TOTAL_LINES - 1 {
			p.dispstat &= ~u16(0x01)
		}
		if int(p.vcount) >= TOTAL_LINES {
			p.vcount = 0
		}
		check_vcount(c)
	}
	return done
}

// --- rendering -------------------------------------------------------------

@(private = "file")
Line :: [SCREEN_W]u32 // RGB555 in the low bits, TRANSPARENT when empty

@(private = "file")
Obj_Line :: struct {
	color:    [SCREEN_W]u32,
	priority: [SCREEN_W]u8,
	semi:     [SCREEN_W]bool,
	window:   [SCREEN_W]bool,
}

@(private = "file")
pal16 :: #force_inline proc(c: ^Console, index: int) -> u32 {
	i := (index * 2) & 0x3FF
	return u32(c.palette[i]) | u32(c.palette[i + 1]) << 8
}

@(private = "file")
vram8 :: #force_inline proc(c: ^Console, addr: int) -> u8 {
	return c.vram[addr % VRAM_SIZE]
}

@(private = "file")
render_text_bg :: proc(c: ^Console, bg: int, y: int, out: ^Line) {
	p := &c.ppu
	cnt := p.bgcnt[bg]
	char_base := int((cnt >> 2) & 3) * 0x4000
	screen_base := int((cnt >> 8) & 0x1F) * 0x800
	bpp8 := cnt & 0x80 != 0
	size := (cnt >> 14) & 3
	width := size & 1 != 0 ? 512 : 256
	height := size & 2 != 0 ? 512 : 256
	sy := y
	if cnt & 0x40 != 0 {
		mh := int((p.mosaic >> 4) & 0xF) + 1
		sy -= sy % mh
	}
	vy := (sy + int(p.vofs[bg])) & (height - 1)
	mw := cnt & 0x40 != 0 ? int(p.mosaic & 0xF) + 1 : 1
	for x in 0 ..< SCREEN_W {
		mx := x - x % mw
		vx := (mx + int(p.hofs[bg])) & (width - 1)
		block := (vx >> 8) + (vy >> 8) * (width >> 8)
		entry_addr := screen_base + block * 0x800 + ((vy & 255) >> 3) * 64 + ((vx & 255) >> 3) * 2
		e := u16(vram8(c, entry_addr)) | u16(vram8(c, entry_addr + 1)) << 8
		tile := int(e & 0x3FF)
		tx := vx & 7
		ty := vy & 7
		if e & 0x0400 != 0 {tx = 7 - tx}
		if e & 0x0800 != 0 {ty = 7 - ty}
		index: int
		if bpp8 {
			addr := char_base + tile * 64 + ty * 8 + tx
			if addr >= 0x10000 {
				out[x] = TRANSPARENT
				continue
			}
			index = int(c.vram[addr])
		} else {
			addr := char_base + tile * 32 + ty * 4 + tx / 2
			if addr >= 0x10000 {
				out[x] = TRANSPARENT
				continue
			}
			b := c.vram[addr]
			index = int(tx & 1 != 0 ? b >> 4 : b & 0xF)
			if index != 0 {
				index += int(e >> 12) * 16
			}
		}
		out[x] = index == 0 ? TRANSPARENT : pal16(c, index)
	}
}

@(private = "file")
render_affine_bg :: proc(c: ^Console, bg: int, out: ^Line) {
	p := &c.ppu
	cnt := p.bgcnt[bg]
	n := bg - 2
	char_base := int((cnt >> 2) & 3) * 0x4000
	screen_base := int((cnt >> 8) & 0x1F) * 0x800
	size := 128 << ((cnt >> 14) & 3)
	wrap := cnt & 0x2000 != 0
	pa := i32(p.affine[n][0])
	pc := i32(p.affine[n][2])
	rx := p.internal[n][0]
	ry := p.internal[n][1]
	for x in 0 ..< SCREEN_W {
		tx := int(rx >> 8)
		ty := int(ry >> 8)
		rx += pa
		ry += pc
		if wrap {
			tx &= size - 1
			ty &= size - 1
		} else if tx < 0 || ty < 0 || tx >= size || ty >= size {
			out[x] = TRANSPARENT
			continue
		}
		tile := int(vram8(c, screen_base + (ty >> 3) * (size >> 3) + (tx >> 3)))
		index := int(vram8(c, char_base + tile * 64 + (ty & 7) * 8 + (tx & 7)))
		out[x] = index == 0 ? TRANSPARENT : pal16(c, index)
	}
}

@(private = "file")
render_bitmap_bg :: proc(c: ^Console, mode: int, out: ^Line) {
	p := &c.ppu
	pa := i32(p.affine[0][0])
	pc := i32(p.affine[0][2])
	rx := p.internal[0][0]
	ry := p.internal[0][1]
	w, h := SCREEN_W, SCREEN_H
	if mode == 5 {
		w, h = 160, 128
	}
	page := p.dispcnt & 0x10 != 0 && mode != 3 ? 0xA000 : 0
	for x in 0 ..< SCREEN_W {
		tx := int(rx >> 8)
		ty := int(ry >> 8)
		rx += pa
		ry += pc
		if tx < 0 || ty < 0 || tx >= w || ty >= h {
			out[x] = TRANSPARENT
			continue
		}
		if mode == 4 {
			index := int(c.vram[page + ty * w + tx])
			out[x] = index == 0 ? TRANSPARENT : pal16(c, index)
		} else {
			i := page + (ty * w + tx) * 2
			out[x] = (u32(c.vram[i]) | u32(c.vram[i + 1]) << 8) & 0x7FFF
		}
	}
}

@(private = "file", rodata)
OBJ_SIZE := [3][4][2]int {
	{{8, 8}, {16, 16}, {32, 32}, {64, 64}},
	{{16, 8}, {32, 8}, {32, 16}, {64, 32}},
	{{8, 16}, {8, 32}, {16, 32}, {32, 64}},
}

@(private = "file")
oam16 :: #force_inline proc(c: ^Console, i: int) -> u16 {
	return u16(c.oam[i]) | u16(c.oam[i + 1]) << 8
}

@(private = "file")
render_objects :: proc(c: ^Console, y: int, out: ^Obj_Line) {
	p := &c.ppu
	for x in 0 ..< SCREEN_W {
		out.color[x] = TRANSPARENT
		out.priority[x] = 4
		out.semi[x] = false
		out.window[x] = false
	}
	one_d := p.dispcnt & 0x40 != 0
	bitmap := p.dispcnt & 7 >= 3
	for i in 0 ..< 128 {
		a0 := oam16(c, i * 8)
		a1 := oam16(c, i * 8 + 2)
		a2 := oam16(c, i * 8 + 4)
		affine := a0 & 0x100 != 0
		if !affine && a0 & 0x200 != 0 {
			continue // disabled
		}
		shape := int(a0 >> 14)
		if shape == 3 {
			continue
		}
		size := OBJ_SIZE[shape][a1 >> 14]
		w, h := size[0], size[1]
		bw, bh := w, h
		if affine && a0 & 0x200 != 0 {
			bw, bh = w * 2, h * 2 // double-size bounding box
		}
		oy := int(a0 & 0xFF)
		if oy >= SCREEN_H {oy -= 256}
		if y < oy || y >= oy + bh {
			continue
		}
		ox := int(a1 & 0x1FF)
		if ox >= SCREEN_W {ox -= 512}
		mode := (a0 >> 10) & 3
		if mode == 3 {
			continue
		}
		bpp8 := a0 & 0x2000 != 0
		tile := int(a2 & 0x3FF)
		if bitmap && tile < 512 {
			continue // those tiles hold the bitmap
		}
		prio := u8((a2 >> 10) & 3)
		palette := int(a2 >> 12)

		pa, pb, pc, pd: i32 = 256, 0, 0, 256
		if affine {
			base := int((a1 >> 9) & 0x1F) * 32
			pa = i32(i16(oam16(c, base + 6)))
			pb = i32(i16(oam16(c, base + 14)))
			pc = i32(i16(oam16(c, base + 22)))
			pd = i32(i16(oam16(c, base + 30)))
		}
		dy := y - oy
		if a0 & 0x1000 != 0 { // mosaic
			mh := int((p.mosaic >> 12) & 0xF) + 1
			dy -= dy % mh
		}
		for bx in 0 ..< bw {
			x := ox + bx
			if x < 0 || x >= SCREEN_W {
				continue
			}
			tx, ty: int
			if affine {
				cx := i32(bx - bw / 2)
				cy := i32(dy - bh / 2)
				tx = int((pa * cx + pb * cy) >> 8) + w / 2
				ty = int((pc * cx + pd * cy) >> 8) + h / 2
				if tx < 0 || ty < 0 || tx >= w || ty >= h {
					continue
				}
			} else {
				tx = bx
				ty = dy
				if a1 & 0x1000 != 0 {tx = w - 1 - tx}
				if a1 & 0x2000 != 0 {ty = h - 1 - ty}
			}
			tile_x := tx >> 3
			tile_y := ty >> 3
			t: int
			if one_d {
				t = tile + tile_y * (w >> 3) * (bpp8 ? 2 : 1) + tile_x * (bpp8 ? 2 : 1)
			} else {
				t = tile + tile_y * 32 + tile_x * (bpp8 ? 2 : 1)
			}
			index: int
			if bpp8 {
				addr := 0x10000 + ((t & 0x3FF) * 32 + (ty & 7) * 8 + (tx & 7))
				index = int(c.vram[addr % VRAM_SIZE])
			} else {
				addr := 0x10000 + ((t & 0x3FF) * 32 + (ty & 7) * 4 + (tx & 7) / 2)
				b := c.vram[addr % VRAM_SIZE]
				index = int(tx & 1 != 0 ? b >> 4 : b & 0xF)
				if index != 0 {
					index += palette * 16
				}
			}
			if index == 0 {
				continue
			}
			if mode == 2 {
				out.window[x] = true
				continue
			}
			// Lower OAM indices win; a later sprite only replaces a pixel
			// when it has strictly higher priority.
			if prio < out.priority[x] {
				out.color[x] = pal16(c, 256 + index)
				out.priority[x] = prio
				out.semi[x] = mode == 1
			}
		}
	}
}

@(private = "file")
in_window :: proc(coord: int, reg: u16, limit: int) -> bool {
	lo := int(reg >> 8)
	hi := int(reg & 0xFF)
	if hi > limit || lo > hi {
		if lo > hi {
			return coord >= lo || coord < hi
		}
		hi = limit
	}
	return coord >= lo && coord < hi
}

@(private = "file")
blend :: #force_inline proc(a, b: u32, eva, evb: u32) -> u32 {
	r := min(((a & 31) * eva + (b & 31) * evb) >> 4, 31)
	g := min((((a >> 5) & 31) * eva + ((b >> 5) & 31) * evb) >> 4, 31)
	bl := min((((a >> 10) & 31) * eva + ((b >> 10) & 31) * evb) >> 4, 31)
	return r | g << 5 | bl << 10
}

@(private = "file")
brighten :: #force_inline proc(a: u32, evy: u32) -> u32 {
	r := a & 31
	g := (a >> 5) & 31
	b := (a >> 10) & 31
	r += ((31 - r) * evy) >> 4
	g += ((31 - g) * evy) >> 4
	b += ((31 - b) * evy) >> 4
	return r | g << 5 | b << 10
}

@(private = "file")
darken :: #force_inline proc(a: u32, evy: u32) -> u32 {
	r := a & 31
	g := (a >> 5) & 31
	b := (a >> 10) & 31
	r -= (r * evy) >> 4
	g -= (g * evy) >> 4
	b -= (b * evy) >> 4
	return r | g << 5 | b << 10
}

@(private = "file")
to_rgb :: #force_inline proc(c: u32) -> u32 {
	r := c & 31
	g := (c >> 5) & 31
	b := (c >> 10) & 31
	return (r << 3 | r >> 2) << 16 | (g << 3 | g >> 2) << 8 | (b << 3 | b >> 2)
}

@(private = "file")
render_line :: proc(c: ^Console, y: int) {
	p := &c.ppu
	row := c.ppu.framebuffer[y * SCREEN_W:][:SCREEN_W]
	if p.dispcnt & 0x80 != 0 {
		for &px in row {px = 0xFFFFFF} // forced blank shows white
		return
	}
	mode := int(p.dispcnt & 7)
	bgs: [4]Line
	enabled: [4]bool
	for bg in 0 ..< 4 {
		if p.dispcnt & (0x100 << uint(bg)) == 0 {
			continue
		}
		switch mode {
		case 0:
			enabled[bg] = true
			render_text_bg(c, bg, y, &bgs[bg])
		case 1:
			if bg < 2 {
				enabled[bg] = true
				render_text_bg(c, bg, y, &bgs[bg])
			} else if bg == 2 {
				enabled[bg] = true
				render_affine_bg(c, bg, &bgs[bg])
			}
		case 2:
			if bg >= 2 {
				enabled[bg] = true
				render_affine_bg(c, bg, &bgs[bg])
			}
		case 3, 4, 5:
			if bg == 2 {
				enabled[bg] = true
				render_bitmap_bg(c, mode, &bgs[bg])
			}
		}
	}
	objs: Obj_Line
	obj_on := p.dispcnt & 0x1000 != 0
	if obj_on || p.dispcnt & 0x8000 != 0 {
		render_objects(c, y, &objs)
	}

	// Background order: by priority, then by number.
	order: [4]int
	n := 0
	for prio in u16(0) ..< 4 {
		for bg in 0 ..< 4 {
			if enabled[bg] && p.bgcnt[bg] & 3 == prio {
				order[n] = bg
				n += 1
			}
		}
	}

	windows := p.dispcnt & 0xE000 != 0
	win_y: [2]bool
	for w in 0 ..< 2 {
		win_y[w] = p.dispcnt & (0x2000 << uint(w)) != 0 && in_window(y, p.winv[w], SCREEN_H)
	}
	backdrop := pal16(c, 0)
	effect := (p.bldcnt >> 6) & 3
	eva := min(u32(p.bldalpha & 0x1F), 16)
	evb := min(u32((p.bldalpha >> 8) & 0x1F), 16)
	evy := min(u32(p.bldy & 0x1F), 16)

	for x in 0 ..< SCREEN_W {
		mask: u16 = 0x3F
		if windows {
			switch {
			case win_y[0] && in_window(x, p.winh[0], SCREEN_W):
				mask = p.winin & 0x3F
			case win_y[1] && in_window(x, p.winh[1], SCREEN_W):
				mask = (p.winin >> 8) & 0x3F
			case p.dispcnt & 0x8000 != 0 && objs.window[x]:
				mask = (p.winout >> 8) & 0x3F
			case:
				mask = p.winout & 0x3F
			}
		}
		// Find the two topmost layers (4 = OBJ, 5 = backdrop). Sprites sit
		// above backgrounds of the same priority.
		top, below := backdrop, backdrop
		top_layer, below_layer := 5, 5
		obj_visible := obj_on && mask & 0x10 != 0 && objs.color[x] & TRANSPARENT == 0
		found := 0
		search: for prio in 0 ..< 4 {
			if obj_visible && int(objs.priority[x]) == prio {
				if found == 0 {
					top, top_layer = objs.color[x], 4
				} else {
					below, below_layer = objs.color[x], 4
				}
				found += 1
				if found == 2 {break search}
			}
			for i in 0 ..< n {
				bg := order[i]
				if int(p.bgcnt[bg] & 3) != prio || mask & (1 << uint(bg)) == 0 || bgs[bg][x] & TRANSPARENT != 0 {
					continue
				}
				if found == 0 {
					top, top_layer = bgs[bg][x], bg
				} else {
					below, below_layer = bgs[bg][x], bg
				}
				found += 1
				if found == 2 {break search}
			}
		}

		out := top
		target1 := p.bldcnt & (1 << uint(top_layer)) != 0
		target2 := p.bldcnt & (0x100 << uint(below_layer)) != 0
		if top_layer == 4 && objs.semi[x] && target2 {
			out = blend(top, below, eva, evb)
		} else if mask & 0x20 != 0 && target1 {
			switch effect {
			case 1:
				if target2 {out = blend(top, below, eva, evb)}
			case 2: out = brighten(top, evy)
			case 3: out = darken(top, evy)
			}
		}
		row[x] = to_rgb(out)
	}
}
