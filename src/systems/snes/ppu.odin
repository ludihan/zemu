package snes

// S-PPU1/S-PPU2, rendered one scanline at a time at the start of HBlank.

SCREEN_WIDTH  :: 256
MAX_HEIGHT    :: 239
HIRES_WIDTH   :: 512

Bg :: struct {
	sc:        u8,  // BGnSC: map base and size
	char_base: u16, // word address
	hofs:      u16,
	vofs:      u16,
}

Ppu :: struct {
	vram:        [0x8000]u16,
	cgram:       [256]u16,
	oam:         [544]u8,

	inidisp:     u8,
	obsel:       u8,
	oam_addr:    u16, // byte address into OAM
	oam_reload:  u16, // word address written to $2102/3
	oam_latch:   u8,
	oam_priority: bool,
	bgmode:      u8,
	mosaic:      u8,
	bg:          [4]Bg,
	ofs_latch:   u8,
	hofs_latch:  u8,
	m7sel:       u8,
	m7:          [6]i16, // a, b, c, d, x, y
	m7hofs:      i16,
	m7vofs:      i16,
	m7_latch:    u8,
	vmain:       u8,
	vram_addr:   u16,
	vram_latch:  u16,
	cg_addr:     u8,
	cg_high:     bool,
	cg_latch:    u8,
	w12sel, w34sel, wobjsel: u8,
	wh:          [4]u8,
	wbglog, wobjlog: u8,
	tm, ts, tmw, tsw: u8,
	cgwsel, cgadsub: u8,
	fixed:       [3]u8, // fixed color r, g, b (5 bits each)
	setini:      u8,

	// counters / open bus
	hcount, vcount: u16,
	hcount_high, vcount_high: bool,
	counters_latched: bool,
	mdr1, mdr2:  u8,
	range_over, time_over: bool,

	// output
	fb_low:      [SCREEN_WIDTH * MAX_HEIGHT]u32,
	fb_high:     [HIRES_WIDTH * MAX_HEIGHT]u32,
	hires_frame: bool, // any line this frame used a 512-pixel mode
	height:      int,
}

@(private = "file", rodata)
BRIGHTNESS_SCALE := [16]u32{0, 17, 34, 51, 68, 85, 102, 119, 136, 153, 170, 187, 204, 221, 238, 255}

ppu_reset :: proc(p: ^Ppu) {
	p.inidisp = 0x80
	p.vmain = 0
	p.height = 224
}

// --- register access -------------------------------------------------------

@(private = "file")
vram_remap :: proc(p: ^Ppu) -> u16 {
	a := p.vram_addr
	switch (p.vmain >> 2) & 3 {
	case 1: a = (a & 0xFF00) | ((a & 0x001F) << 3) | ((a >> 5) & 7)
	case 2: a = (a & 0xFE00) | ((a & 0x003F) << 3) | ((a >> 6) & 7)
	case 3: a = (a & 0xFC00) | ((a & 0x007F) << 3) | ((a >> 7) & 7)
	}
	return a & 0x7FFF
}

@(private = "file")
vram_increment :: proc(p: ^Ppu) {
	switch p.vmain & 3 {
	case 0:    p.vram_addr += 1
	case 1:    p.vram_addr += 32
	case 2, 3: p.vram_addr += 128
	}
}

ppu_latch_counters :: proc(c: ^Console) {
	p := &c.ppu
	p.hcount = u16(c.h / 4)
	p.vcount = u16(c.v)
	p.counters_latched = true
}

ppu_read :: proc(c: ^Console, reg: u16) -> u8 {
	p := &c.ppu
	switch reg {
	case 0x2134, 0x2135, 0x2136:
		// signed 16x8 multiply of M7A and the high byte of M7B
		r := i32(p.m7[0]) * i32(i8(u16(p.m7[1]) >> 8))
		p.mdr1 = u8(u32(r) >> (8 * u32(reg - 0x2134)))
		return p.mdr1
	case 0x2137:
		ppu_latch_counters(c)
		return c.open_bus
	case 0x2138:
		v := p.oam[oam_index(p.oam_addr)]
		p.oam_addr = (p.oam_addr + 1) & 0x3FF
		p.mdr1 = v
		return v
	case 0x2139:
		v := u8(p.vram_latch)
		if p.vmain & 0x80 == 0 {
			p.vram_latch = p.vram[vram_remap(p)]
			vram_increment(p)
		}
		p.mdr1 = v
		return v
	case 0x213A:
		v := u8(p.vram_latch >> 8)
		if p.vmain & 0x80 != 0 {
			p.vram_latch = p.vram[vram_remap(p)]
			vram_increment(p)
		}
		p.mdr1 = v
		return v
	case 0x213B:
		word := p.cgram[p.cg_addr]
		v: u8
		if !p.cg_high {
			v = u8(word)
		} else {
			v = (u8(word >> 8) & 0x7F) | (p.mdr2 & 0x80)
			p.cg_addr += 1
		}
		p.cg_high = !p.cg_high
		p.mdr2 = v
		return v
	case 0x213C:
		v := p.hcount_high ? u8(p.hcount >> 8) & 1 | (p.mdr2 & 0xFE) : u8(p.hcount)
		p.hcount_high = !p.hcount_high
		p.mdr2 = v
		return v
	case 0x213D:
		v := p.vcount_high ? u8(p.vcount >> 8) & 1 | (p.mdr2 & 0xFE) : u8(p.vcount)
		p.vcount_high = !p.vcount_high
		p.mdr2 = v
		return v
	case 0x213E:
		v := u8(0x01) | (p.mdr1 & 0x10)
		if p.time_over {v |= 0x80}
		if p.range_over {v |= 0x40}
		p.mdr1 = v
		return v
	case 0x213F:
		v := u8(0x03) | (p.mdr2 & 0x20)
		if p.counters_latched {v |= 0x40}
		if c.frame_count & 1 != 0 {v |= 0x80}
		if c.pal {v |= 0x10}
		p.counters_latched = false
		p.hcount_high = false
		p.vcount_high = false
		p.mdr2 = v
		return v
	}
	return p.mdr1
}

@(private = "file")
oam_index :: #force_inline proc(addr: u16) -> int {
	a := int(addr & 0x3FF)
	if a >= 0x200 {
		return 0x200 + (a & 0x1F)
	}
	return a
}

ppu_write :: proc(c: ^Console, reg: u16, v: u8) {
	p := &c.ppu
	switch reg {
	case 0x2100:
		p.inidisp = v
	case 0x2101:
		p.obsel = v
	case 0x2102:
		p.oam_reload = (p.oam_reload & 0x100) | u16(v)
		p.oam_addr = p.oam_reload << 1
	case 0x2103:
		p.oam_reload = (p.oam_reload & 0xFF) | (u16(v & 1) << 8)
		p.oam_priority = v & 0x80 != 0
		p.oam_addr = p.oam_reload << 1
	case 0x2104:
		a := p.oam_addr & 0x3FF
		if a >= 0x200 {
			p.oam[0x200 + int(a & 0x1F)] = v
		} else if a & 1 == 0 {
			p.oam_latch = v
		} else {
			p.oam[a - 1] = p.oam_latch
			p.oam[a] = v
		}
		p.oam_addr = (p.oam_addr + 1) & 0x3FF
	case 0x2105:
		p.bgmode = v
	case 0x2106:
		p.mosaic = v
	case 0x2107 ..= 0x210A:
		p.bg[reg - 0x2107].sc = v
	case 0x210B:
		p.bg[0].char_base = u16(v & 0x0F) << 12
		p.bg[1].char_base = u16(v >> 4) << 12
	case 0x210C:
		p.bg[2].char_base = u16(v & 0x0F) << 12
		p.bg[3].char_base = u16(v >> 4) << 12
	case 0x210D, 0x210F, 0x2111, 0x2113:
		i := (reg - 0x210D) / 2
		p.bg[i].hofs = ((u16(v) << 8) | u16(p.ofs_latch & 0xF8) | u16(p.hofs_latch & 7)) & 0x3FF
		p.ofs_latch = v
		p.hofs_latch = v
		if reg == 0x210D {
			p.m7hofs = sign13(u16(v) << 8 | u16(p.m7_latch))
			p.m7_latch = v
		}
	case 0x210E, 0x2110, 0x2112, 0x2114:
		i := (reg - 0x210E) / 2
		p.bg[i].vofs = ((u16(v) << 8) | u16(p.ofs_latch)) & 0x3FF
		p.ofs_latch = v
		if reg == 0x210E {
			p.m7vofs = sign13(u16(v) << 8 | u16(p.m7_latch))
			p.m7_latch = v
		}
	case 0x2115:
		p.vmain = v
	case 0x2116:
		p.vram_addr = (p.vram_addr & 0xFF00) | u16(v)
		p.vram_latch = p.vram[vram_remap(p)]
	case 0x2117:
		p.vram_addr = (p.vram_addr & 0x00FF) | (u16(v) << 8)
		p.vram_latch = p.vram[vram_remap(p)]
	case 0x2118:
		a := vram_remap(p)
		p.vram[a] = (p.vram[a] & 0xFF00) | u16(v)
		if p.vmain & 0x80 == 0 {vram_increment(p)}
	case 0x2119:
		a := vram_remap(p)
		p.vram[a] = (p.vram[a] & 0x00FF) | (u16(v) << 8)
		if p.vmain & 0x80 != 0 {vram_increment(p)}
	case 0x211A:
		p.m7sel = v
	case 0x211B ..= 0x2120:
		i := reg - 0x211B
		value := u16(v) << 8 | u16(p.m7_latch)
		p.m7[i] = i >= 4 ? sign13(value) : i16(value)
		p.m7_latch = v
	case 0x2121:
		p.cg_addr = v
		p.cg_high = false
	case 0x2122:
		if !p.cg_high {
			p.cg_latch = v
		} else {
			p.cgram[p.cg_addr] = (u16(v & 0x7F) << 8) | u16(p.cg_latch)
			p.cg_addr += 1
		}
		p.cg_high = !p.cg_high
	case 0x2123: p.w12sel = v
	case 0x2124: p.w34sel = v
	case 0x2125: p.wobjsel = v
	case 0x2126 ..= 0x2129: p.wh[reg - 0x2126] = v
	case 0x212A: p.wbglog = v
	case 0x212B: p.wobjlog = v
	case 0x212C: p.tm = v
	case 0x212D: p.ts = v
	case 0x212E: p.tmw = v
	case 0x212F: p.tsw = v
	case 0x2130: p.cgwsel = v
	case 0x2131: p.cgadsub = v
	case 0x2132:
		intensity := v & 0x1F
		if v & 0x20 != 0 {p.fixed[0] = intensity}
		if v & 0x40 != 0 {p.fixed[1] = intensity}
		if v & 0x80 != 0 {p.fixed[2] = intensity}
	case 0x2133:
		p.setini = v
		p.height = v & 0x04 != 0 ? 239 : 224
	}
}

@(private = "file")
sign13 :: #force_inline proc(v: u16) -> i16 {
	return i16(v << 3) >> 3
}

// Called at the start of vblank.
ppu_vblank :: proc(p: ^Ppu) {
	if p.inidisp & 0x80 == 0 {
		p.oam_addr = p.oam_reload << 1
	}
}

ppu_frame_start :: proc(p: ^Ppu) {
	p.hires_frame = false
	p.range_over = false
	p.time_over = false
}

// --- line rendering --------------------------------------------------------

// One layer pixel: 15-bit BGR color, z (0 = transparent), color-math flag.
Pixel :: struct {
	color: u16,
	z:     u8,
	math:  bool,
}

Layer :: enum u8 {
	Bg1,
	Bg2,
	Bg3,
	Bg4,
	Obj,
	Backdrop,
}

// z values (higher is in front) for [layer][priority] in each mode.
@(private = "file")
z_for :: proc(mode: u8, bg3_priority: bool, layer: Layer, prio: int) -> u8 {
	@(static, rodata) Z_MODE0 := [5][4]u8{{8, 11, 0, 0}, {7, 10, 0, 0}, {2, 5, 0, 0}, {1, 4, 0, 0}, {3, 6, 9, 12}}
	@(static, rodata) Z_MODE1 := [5][4]u8{{6, 9, 0, 0}, {5, 8, 0, 0}, {1, 3, 0, 0}, {0, 0, 0, 0}, {2, 4, 7, 10}}
	@(static, rodata) Z_MODE1_HI := [5][4]u8{{5, 8, 0, 0}, {4, 7, 0, 0}, {1, 10, 0, 0}, {0, 0, 0, 0}, {2, 3, 6, 9}}
	@(static, rodata) Z_MODE2 := [5][4]u8{{3, 7, 0, 0}, {1, 5, 0, 0}, {0, 0, 0, 0}, {0, 0, 0, 0}, {2, 4, 6, 8}}
	@(static, rodata) Z_MODE6 := [5][4]u8{{2, 5, 0, 0}, {0, 0, 0, 0}, {0, 0, 0, 0}, {0, 0, 0, 0}, {1, 3, 4, 6}}
	@(static, rodata) Z_MODE7 := [5][4]u8{{3, 3, 0, 0}, {1, 5, 0, 0}, {0, 0, 0, 0}, {0, 0, 0, 0}, {2, 4, 6, 7}}
	l := int(layer)
	if l > 4 || prio < 0 || prio > 3 {
		return 0
	}
	switch mode {
	case 0:    return Z_MODE0[l][prio]
	case 1:    return bg3_priority ? Z_MODE1_HI[l][prio] : Z_MODE1[l][prio]
	case 2 ..= 5: return Z_MODE2[l][prio]
	case 6:    return Z_MODE6[l][prio]
	case 7:    return Z_MODE7[l][prio]
	}
	return 0
}

@(private = "file")
bg_bpp :: proc(mode: u8, bg: int) -> int {
	@(static, rodata) BPP := [8][4]int {
		{2, 2, 2, 2},
		{4, 4, 2, 0},
		{4, 4, 0, 0},
		{8, 4, 0, 0},
		{8, 2, 0, 0},
		{4, 2, 0, 0},
		{4, 0, 0, 0},
		{8, 0, 0, 0},
	}
	return BPP[mode & 7][bg]
}

Line_State :: struct {
	layers:   [5][HIRES_WIDTH]Pixel,
	window:   [6][SCREEN_WIDTH]bool, // per layer (BG1-4, OBJ, color window)
	hires:    bool,
	width:    int,
}

@(private = "file")
line_state: Line_State // scratch, reused every line (render is single-threaded)

@(private = "file")
compute_windows :: proc(p: ^Ppu, ls: ^Line_State) {
	sel := [6]u8 {
		p.w12sel & 0x0F, p.w12sel >> 4, p.w34sel & 0x0F, p.w34sel >> 4,
		p.wobjsel & 0x0F, p.wobjsel >> 4,
	}
	logic := [6]u8 {
		p.wbglog & 3, (p.wbglog >> 2) & 3, (p.wbglog >> 4) & 3, (p.wbglog >> 6) & 3,
		p.wobjlog & 3, (p.wobjlog >> 2) & 3,
	}
	for l in 0 ..< 6 {
		s := sel[l]
		w1_on := s & 0x2 != 0
		w2_on := s & 0x8 != 0
		w1_inv := s & 0x1 != 0
		w2_inv := s & 0x4 != 0
		for x in 0 ..< SCREEN_WIDTH {
			in1 := x >= int(p.wh[0]) && x <= int(p.wh[1])
			in2 := x >= int(p.wh[2]) && x <= int(p.wh[3])
			if w1_inv {in1 = !in1}
			if w2_inv {in2 = !in2}
			r: bool
			switch {
			case w1_on && w2_on:
				switch logic[l] {
				case 0: r = in1 || in2
				case 1: r = in1 && in2
				case 2: r = in1 != in2
				case 3: r = in1 == in2
				}
			case w1_on: r = in1
			case w2_on: r = in2
			case:       r = false
			}
			ls.window[l][x] = r
		}
	}
}

@(private = "file")
map_entry :: proc(p: ^Ppu, bg: ^Bg, tx, ty: int) -> u16 {
	base := int(bg.sc & 0xFC) << 8
	size := bg.sc & 3
	addr := base + ((ty & 31) << 5) + (tx & 31)
	if tx & 32 != 0 && size & 1 != 0 {
		addr += 0x400
	}
	if ty & 32 != 0 && size & 2 != 0 {
		addr += size == 3 ? 0x800 : 0x400
	}
	return p.vram[addr & 0x7FFF]
}

// Decodes one 8-pixel row of a tile into color indices.
@(private = "file")
tile_row :: proc(p: ^Ppu, char_base: u16, tile: int, row: int, bpp: int, out: ^[8]u8) {
	words_per_tile := bpp * 4
	addr := int(char_base) + tile * words_per_tile + row
	out^ = {}
	for plane_pair in 0 ..< bpp / 2 {
		w := p.vram[(addr + plane_pair * 8) & 0x7FFF]
		lo := u8(w)
		hi := u8(w >> 8)
		for x in 0 ..< 8 {
			bit := u8(7 - x)
			out[x] |= ((lo >> bit) & 1) << u8(plane_pair * 2)
			out[x] |= ((hi >> bit) & 1) << u8(plane_pair * 2 + 1)
		}
	}
}

@(private = "file")
bg_color :: proc(p: ^Ppu, mode: u8, bg_index: int, bpp: int, palette: int, index: u8) -> u16 {
	if bpp == 8 && p.cgwsel & 1 != 0 && (mode == 3 || mode == 4) {
		return direct_color(index, u8(palette))
	}
	switch bpp {
	case 2:
		base := mode == 0 ? bg_index * 32 : 0
		return p.cgram[(base + palette * 4 + int(index)) & 0xFF]
	case 4:
		return p.cgram[(palette * 16 + int(index)) & 0xFF]
	}
	return p.cgram[index]
}

@(private = "file")
direct_color :: proc(index: u8, palette: u8) -> u16 {
	// BBGGGRRR from the pixel, plus one extra bit per channel from the palette.
	r := u16(index & 0x07) << 2 | u16(palette & 1) << 1
	g := u16((index >> 3) & 0x07) << 2 | u16(palette & 2)
	b := u16((index >> 6) & 0x03) << 3 | u16(palette & 4) << 0
	return r | g << 5 | b << 10
}

@(private = "file")
render_bg :: proc(p: ^Ppu, ls: ^Line_State, bg_index: int, line: int) {
	mode := p.bgmode & 7
	bpp := bg_bpp(mode, bg_index)
	if bpp == 0 {
		return
	}
	bg := &p.bg[bg_index]
	out := &ls.layers[bg_index]
	big := p.bgmode & (0x10 << uint(bg_index)) != 0
	hires := mode == 5 || mode == 6
	tile_h := big ? 16 : 8
	tile_w := (big || hires) ? 16 : 8
	bg3_priority := p.bgmode & 0x08 != 0

	mosaic_size := p.mosaic & (1 << uint(bg_index)) != 0 ? int(p.mosaic >> 4) + 1 : 1
	y_line := line
	if mosaic_size > 1 {
		y_line = line - (line - 1) %% mosaic_size
	}

	width := hires ? HIRES_WIDTH : SCREEN_WIDTH
	opt := (mode == 2 || mode == 4 || mode == 6) && bg_index < 2

	row_cache: [8]u8
	cached_tile := -1
	cached_entry: u16

	for sx in 0 ..< width {
		px := sx
		if mosaic_size > 1 {
			unit := hires ? mosaic_size * 2 : mosaic_size
			px = sx - sx % unit
		}
		hofs := int(bg.hofs)
		vofs := int(bg.vofs)
		if opt {
			hofs, vofs = offset_per_tile(p, bg_index, hires ? px / 2 : px, hofs, vofs)
		}
		x := hires ? px + hofs * 2 : px + hofs
		y := y_line + vofs
		tx := x / tile_w
		ty := y / tile_h
		entry := map_entry(p, bg, tx, ty)
		half := tile_w == 16 ? (x >> 3) & 1 : 0
		key := (tx & 0x3F) | (ty & 0x3F) << 6 | (y % tile_h) << 12 | half << 17
		if key != cached_tile || entry != cached_entry {
			cached_tile = key
			cached_entry = entry
			tile := int(entry & 0x3FF)
			hflip := entry & 0x4000 != 0
			vflip := entry & 0x8000 != 0
			row := y % tile_h
			if vflip {row = tile_h - 1 - row}
			col_half := (x % tile_w) >= 8 ? 1 : 0
			if hflip && tile_w == 16 {col_half = 1 - col_half}
			if row >= 8 {tile += 16}
			tile += col_half
			tile_row(p, bg.char_base, tile & 0x3FF, row & 7, bpp, &row_cache)
		}
		col := x & 7
		if entry & 0x4000 != 0 {col = 7 - col}
		idx := row_cache[col]
		if idx == 0 {
			out[sx] = {}
			continue
		}
		prio := int(entry >> 13) & 1
		palette := int(entry >> 10) & 7
		out[sx] = Pixel {
			color = bg_color(p, mode, bg_index, bpp, palette, idx),
			z     = z_for(mode, bg3_priority, Layer(bg_index), prio),
			math  = p.cgadsub & (1 << uint(bg_index)) != 0,
		}
	}
}

// Offset-per-tile (modes 2, 4, 6): BG3's tilemap supplies per-column scroll.
@(private = "file")
offset_per_tile :: proc(p: ^Ppu, bg_index: int, x: int, hofs, vofs: int) -> (int, int) {
	col := (x + (hofs & 7)) >> 3
	if col == 0 {
		return hofs, vofs
	}
	bg3 := &p.bg[2]
	tx := ((col - 1) + (int(bg3.hofs) >> 3)) & 63
	ty := int(bg3.vofs) >> 3
	enable_bit := u16(0x2000) << uint(bg_index)
	h := hofs
	v := vofs
	mode := p.bgmode & 7
	if mode == 4 {
		e := map_entry(p, bg3, tx, ty)
		if e & enable_bit != 0 {
			if e & 0x8000 != 0 {
				v = int(e & 0x3FF)
			} else {
				h = (hofs & 7) | int(e & 0x3F8)
			}
		}
		return h, v
	}
	eh := map_entry(p, bg3, tx, ty)
	ev := map_entry(p, bg3, tx, ty + 1)
	if eh & enable_bit != 0 {h = (hofs & 7) | int(eh & 0x3F8)}
	if ev & enable_bit != 0 {v = int(ev & 0x3FF)}
	return h, v
}

@(private = "file")
render_mode7 :: proc(p: ^Ppu, ls: ^Line_State, line: int, extbg: bool) {
	a := i32(p.m7[0])
	b := i32(p.m7[1])
	cc := i32(p.m7[2])
	d := i32(p.m7[3])
	cx := i32(p.m7[4])
	cy := i32(p.m7[5])
	hofs := i32(p.m7hofs)
	vofs := i32(p.m7vofs)

	mosaic_bg1 := p.mosaic & 1 != 0 ? int(p.mosaic >> 4) + 1 : 1
	y := i32(line)
	if mosaic_bg1 > 1 {
		y = i32(line - (line - 1) %% mosaic_bg1)
	}
	if p.m7sel & 0x02 != 0 {y = 255 - y}

	clip :: #force_inline proc(v: i32) -> i32 {
		return v & 0x2000 != 0 ? v | ~i32(0x3FF) : v & 0x3FF
	}
	hh := clip(hofs - cx)
	vv := clip(vofs - cy)
	start_x := ((a * hh) & ~i32(63)) + ((b * y) & ~i32(63)) + ((b * vv) & ~i32(63)) + (cx << 8)
	start_y := ((cc * hh) & ~i32(63)) + ((d * y) & ~i32(63)) + ((d * vv) & ~i32(63)) + (cy << 8)

	out1 := &ls.layers[0]
	out2 := &ls.layers[1]
	repeat := p.m7sel >> 6
	math1 := p.cgadsub & 1 != 0
	math2 := p.cgadsub & 2 != 0
	for sx in 0 ..< SCREEN_WIDTH {
		xx := i32(sx)
		if p.m7sel & 0x01 != 0 {xx = 255 - xx}
		px := (start_x + a * xx) >> 8
		py := (start_y + cc * xx) >> 8
		out_of_bounds := px < 0 || px > 1023 || py < 0 || py > 1023
		tile: u16
		if out_of_bounds && repeat == 2 {
			out1[sx] = {}
			out2[sx] = {}
			continue
		}
		if out_of_bounds && repeat == 3 {
			tile = 0
		} else {
			tile = p.vram[((py & 0x3F8) << 4 | (px & 0x3FF) >> 3) & 0x7FFF] & 0xFF
		}
		pixel := u8(p.vram[(int(tile) * 64 + int(py & 7) * 8 + int(px & 7)) & 0x7FFF] >> 8)
		if pixel != 0 {
			color := p.cgwsel & 1 != 0 ? direct_color(pixel, 0) : p.cgram[pixel]
			out1[sx] = {color = color, z = z_for(7, false, .Bg1, 0), math = math1}
		} else {
			out1[sx] = {}
		}
		if extbg && pixel & 0x7F != 0 {
			prio := int(pixel >> 7)
			out2[sx] = {color = p.cgram[pixel & 0x7F], z = z_for(7, false, .Bg2, prio), math = math2}
		} else {
			out2[sx] = {}
		}
	}
}

@(private = "file", rodata)
OBJ_SIZES := [8][2][2]int {
	{{8, 8}, {16, 16}},
	{{8, 8}, {32, 32}},
	{{8, 8}, {64, 64}},
	{{16, 16}, {32, 32}},
	{{16, 16}, {64, 64}},
	{{32, 32}, {64, 64}},
	{{16, 32}, {32, 64}},
	{{16, 32}, {32, 32}},
}

@(private = "file")
render_obj :: proc(p: ^Ppu, ls: ^Line_State, line: int) {
	out := &ls.layers[4]
	for &px in out[:SCREEN_WIDTH] {
		px = {}
	}
	size_sel := (p.obsel >> 5) & 7
	base := u16(p.obsel & 7) << 13
	gap := (u16((p.obsel >> 3) & 3) + 1) << 12
	interlace := p.setini & 0x02 != 0

	first := 0
	if p.oam_priority {
		first = int(p.oam_reload >> 1) & 0x7F
	}
	found: [32]int
	count := 0
	for n in 0 ..< 128 {
		i := (first + n) & 127
		hi := p.oam[0x200 + i / 4] >> uint((i & 3) * 2)
		large := hi & 2 != 0
		sz := OBJ_SIZES[size_sel][large ? 1 : 0]
		h := sz[1]
		if interlace {h /= 2}
		y := int(p.oam[i * 4 + 1])
		row := (line - y) & 0xFF
		if row >= h {
			continue
		}
		x := int(p.oam[i * 4]) | int(hi & 1) << 8
		if x >= 256 {x -= 512}
		if x <= -sz[0] {
			continue
		}
		if count == 32 {
			p.range_over = true
			break
		}
		found[count] = i
		count += 1
	}

	tiles_used := 0
	pixel_row: [8]u8
	// Earlier sprites have priority over later ones, so draw back to front.
	for k := count - 1; k >= 0; k -= 1 {
		i := found[k]
		hi := p.oam[0x200 + i / 4] >> uint((i & 3) * 2)
		large := hi & 2 != 0
		sz := OBJ_SIZES[size_sel][large ? 1 : 0]
		w, h := sz[0], sz[1]
		x := int(p.oam[i * 4]) | int(hi & 1) << 8
		if x >= 256 {x -= 512}
		y := int(p.oam[i * 4 + 1])
		tile := int(p.oam[i * 4 + 2])
		attr := p.oam[i * 4 + 3]
		row := (line - y) & 0xFF
		if interlace {row *= 2}
		if attr & 0x80 != 0 {row = h - 1 - row}
		prio := int(attr >> 4) & 3
		palette := int(attr >> 1) & 7
		table := attr & 1 != 0 ? base + gap : base
		z := z_for(p.bgmode & 7, p.bgmode & 0x08 != 0, .Obj, prio)
		math := palette >= 4 && p.cgadsub & 0x10 != 0

		for tx in 0 ..< w / 8 {
			sx0 := x + tx * 8
			if sx0 <= -8 || sx0 >= 256 {
				continue
			}
			tiles_used += 1
			if tiles_used > 34 {
				p.time_over = true
				return
			}
			col := attr & 0x40 != 0 ? w / 8 - 1 - tx : tx
			// Tiles are laid out on a 16x16 grid within the name table.
			t := (tile & 0xF0) | ((tile + col) & 0x0F)
			t = (t + (row >> 3) * 16) & 0xFF
			addr := (table + u16(t) * 16) & 0x7FFF
			tile_row(p, addr, 0, row & 7, 4, &pixel_row)
			for px in 0 ..< 8 {
				sx := sx0 + px
				if sx < 0 || sx >= 256 {
					continue
				}
				c := attr & 0x40 != 0 ? pixel_row[7 - px] : pixel_row[px]
				if c == 0 {
					continue
				}
				out[sx] = {color = p.cgram[128 + palette * 16 + int(c)], z = z, math = math}
			}
		}
	}
}

@(private = "file")
color_math :: proc(main, sub: u16, subtract, half: bool) -> u16 {
	r1, g1, b1 := i32(main & 31), i32((main >> 5) & 31), i32((main >> 10) & 31)
	r2, g2, b2 := i32(sub & 31), i32((sub >> 5) & 31), i32((sub >> 10) & 31)
	r, g, b: i32
	if subtract {
		r, g, b = r1 - r2, g1 - g2, b1 - b2
		if half {r, g, b = r >> 1, g >> 1, b >> 1}
		r, g, b = max(r, 0), max(g, 0), max(b, 0)
	} else {
		r, g, b = r1 + r2, g1 + g2, b1 + b2
		if half {r, g, b = r >> 1, g >> 1, b >> 1}
		r, g, b = min(r, 31), min(g, 31), min(b, 31)
	}
	return u16(r) | u16(g) << 5 | u16(b) << 10
}

@(private = "file")
to_rgb :: #force_inline proc(c: u16, brightness: u32) -> u32 {
	r := u32(c & 31)
	g := u32((c >> 5) & 31)
	b := u32((c >> 10) & 31)
	// expand 5 -> 8 bits, then scale by the master brightness
	r = ((r << 3 | r >> 2) * brightness) / 255
	g = ((g << 3 | g >> 2) * brightness) / 255
	b = ((b << 3 | b >> 2) * brightness) / 255
	return r << 16 | g << 8 | b
}

// Picks the frontmost pixel of the given screen (main or sub) at x.
@(private = "file")
pick :: proc(ls: ^Line_State, enabled: u8, masked: u8, x: int, lowres_x: int, hires_bg: bool) -> (Pixel, Layer) {
	best := Pixel{}
	best_layer := Layer.Backdrop
	for l in 0 ..< 5 {
		bit := u8(1) << uint(l)
		if enabled & bit == 0 {
			continue
		}
		if masked & bit != 0 && ls.window[l][lowres_x] {
			continue
		}
		idx := (l < 4 && hires_bg) ? x : lowres_x
		px := ls.layers[l][idx]
		if px.z > best.z {
			best = px
			best_layer = Layer(l)
		}
	}
	return best, best_layer
}

ppu_render_line :: proc(c: ^Console, line: int) {
	p := &c.ppu
	if line < 1 || line > p.height {
		return
	}
	y := line - 1
	mode := p.bgmode & 7
	hires := mode == 5 || mode == 6 || p.setini & 0x08 != 0
	if hires {
		p.hires_frame = true
	}
	low_row := p.fb_low[y * SCREEN_WIDTH:][:SCREEN_WIDTH]
	high_row := p.fb_high[y * HIRES_WIDTH:][:HIRES_WIDTH]

	if p.inidisp & 0x80 != 0 {
		for &px in low_row {px = 0}
		for &px in high_row {px = 0}
		return
	}
	brightness := BRIGHTNESS_SCALE[p.inidisp & 0x0F]
	ls := &line_state

	compute_windows(p, ls)
	active := p.tm | p.ts
	if mode == 7 {
		render_mode7(p, ls, line, p.setini & 0x40 != 0)
	} else {
		for bg in 0 ..< 4 {
			if active & (1 << uint(bg)) != 0 {
				render_bg(p, ls, bg, line)
			} else {
				for &px in ls.layers[bg] {px = {}}
			}
		}
	}
	if active & 0x10 != 0 {
		render_obj(p, ls, line)
	} else {
		for &px in ls.layers[4][:SCREEN_WIDTH] {px = {}}
	}

	hires_bg := mode == 5 || mode == 6
	width := hires ? HIRES_WIDTH : SCREEN_WIDTH
	backdrop := p.cgram[0]
	fixed := u16(p.fixed[0]) | u16(p.fixed[1]) << 5 | u16(p.fixed[2]) << 10
	subtract := p.cgadsub & 0x80 != 0
	half := p.cgadsub & 0x40 != 0
	use_sub := p.cgwsel & 0x02 != 0
	clip_mode := p.cgwsel >> 6
	prevent_mode := (p.cgwsel >> 4) & 3

	for hx in 0 ..< width {
		x := hires ? hx >> 1 : hx
		// In hires modes, even output pixels come from the sub screen.
		main_x := hx
		sub_x := hx
		if hires_bg {
			main_x = (hx & ~int(1)) | 1
			sub_x = hx & ~int(1)
		}

		m, m_layer := pick(ls, p.tm, p.tmw, main_x, x, hires_bg)
		main_color := m_layer == .Backdrop ? backdrop : m.color
		math_enabled := m_layer == .Backdrop ? p.cgadsub & 0x20 != 0 : m.math

		color_window := ls.window[5][x]
		in_region :: proc(mode: u8, inside: bool) -> bool {
			switch mode {
			case 1: return !inside
			case 2: return inside
			case 3: return true
			}
			return false
		}
		if in_region(clip_mode, color_window) {
			main_color = 0
		}
		if in_region(prevent_mode, color_window) {
			math_enabled = false
		}

		sub_color := fixed
		sub_is_backdrop := true
		if use_sub || hires {
			s, s_layer := pick(ls, p.ts, p.tsw, sub_x, x, hires_bg)
			if s_layer != .Backdrop {
				sub_color = s.color
				sub_is_backdrop = false
			} else if hires {
				sub_color = backdrop
			}
		}

		out_color := main_color
		if math_enabled {
			math_sub := use_sub ? sub_color : fixed
			out_color = color_math(main_color, math_sub, subtract, half && !(use_sub && sub_is_backdrop))
		}

		if hires {
			// The sub screen supplies the even pixels; it does not take part in math.
			if hx & 1 == 0 {
				out_color = sub_is_backdrop ? backdrop : sub_color
			}
			high_row[hx] = to_rgb(out_color, brightness)
			if hx & 1 == 1 {
				low_row[x] = high_row[hx]
			}
		} else {
			rgb := to_rgb(out_color, brightness)
			low_row[x] = rgb
			high_row[hx * 2] = rgb
			high_row[hx * 2 + 1] = rgb
		}
	}
}
