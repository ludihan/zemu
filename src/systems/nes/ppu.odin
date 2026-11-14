package nes

// 2C02 picture processing unit, emulated dot by dot (341 dots x 262 lines).

SCREEN_WIDTH  :: 256
SCREEN_HEIGHT :: 240

PRERENDER_LINE :: 261
SPRITE_FETCH_DOT :: 260
VBLANK_LINE    :: 241

Sprite :: struct {
	x:       u8,
	attr:    u8,
	lo, hi:  u8,
	is_zero: bool,
}

Ppu :: struct {
	ctrl, mask, status: u8,
	oam_addr:    u8,
	oam:         [256]u8,
	palette:     [32]u8,
	v, t:        u16,
	fine_x:      u8,
	w:           bool,
	read_buffer: u8,
	open_bus:    u8,

	scanline:    int,
	dot:         int,
	odd_frame:   bool,
	frame_ready: bool,
	frame_count: u64,
	dots:        u64, // free-running dot counter (for mapper A12 timing)

	// background pipeline
	nt_latch, at_latch, lo_latch, hi_latch: u8,
	bg_lo, bg_hi, at_lo, at_hi:             u16,

	// sprites for the line being drawn
	sprites:      [8]Sprite,
	sprite_count: int,

	framebuffer: [SCREEN_WIDTH * SCREEN_HEIGHT]u32,
}

ppu_reset :: proc(p: ^Ppu) {
	p.ctrl = 0
	p.mask = 0
	p.w = false
	p.read_buffer = 0
	p.scanline = 0
	p.dot = 0
	p.odd_frame = false
}

@(private = "file")
rendering_enabled :: #force_inline proc(p: ^Ppu) -> bool {
	return p.mask & 0x18 != 0
}

// NMI output line (vblank flag AND NMI enable), sampled by the CPU each cycle.
ppu_nmi_line :: #force_inline proc(p: ^Ppu) -> bool {
	return p.status & 0x80 != 0 && p.ctrl & 0x80 != 0
}

// --- PPU address space -----------------------------------------------------

@(private = "file")
palette_index :: #force_inline proc(addr: u16) -> int {
	i := int(addr & 0x1F)
	if i & 0x13 == 0x10 {
		i &= ~int(0x10) // $3F10/$14/$18/$1C mirror $3F00/$04/$08/$0C
	}
	return i
}

ppu_mem_read :: proc(c: ^Console, addr: u16) -> u8 {
	a := addr & 0x3FFF
	cart_ppu_address(&c.cart, a, c.ppu.dots)
	switch a {
	case 0x0000 ..= 0x1FFF:
		return cart_chr_read(&c.cart, a)
	case 0x2000 ..= 0x3EFF:
		return c.vram[cart_nt_index(&c.cart, a)]
	case:
		return c.ppu.palette[palette_index(a)]
	}
}

ppu_mem_write :: proc(c: ^Console, addr: u16, value: u8) {
	a := addr & 0x3FFF
	cart_ppu_address(&c.cart, a, c.ppu.dots)
	switch a {
	case 0x0000 ..= 0x1FFF:
		cart_chr_write(&c.cart, a, value)
	case 0x2000 ..= 0x3EFF:
		c.vram[cart_nt_index(&c.cart, a)] = value
	case:
		c.ppu.palette[palette_index(a)] = value & 0x3F
	}
}

// --- CPU-visible registers -------------------------------------------------

ppu_reg_read :: proc(c: ^Console, reg: u16) -> u8 {
	p := &c.ppu
	switch reg & 7 {
	case 2:
		v := (p.status & 0xE0) | (p.open_bus & 0x1F)
		p.status &= 0x7F
		p.w = false
		p.open_bus = v
		return v
	case 4:
		p.open_bus = p.oam[p.oam_addr]
		return p.open_bus
	case 7:
		addr := p.v & 0x3FFF
		v: u8
		if addr >= 0x3F00 {
			// Palette reads are immediate; the buffer gets the nametable underneath.
			v = (ppu_mem_read(c, addr) & 0x3F) | (p.open_bus & 0xC0)
			p.read_buffer = ppu_mem_read(c, addr - 0x1000)
		} else {
			v = p.read_buffer
			p.read_buffer = ppu_mem_read(c, addr)
		}
		p.v += (p.ctrl & 0x04 != 0) ? 32 : 1
		cart_ppu_address(&c.cart, p.v & 0x3FFF, p.dots)
		p.open_bus = v
		return v
	}
	return p.open_bus
}

ppu_reg_write :: proc(c: ^Console, reg: u16, value: u8) {
	p := &c.ppu
	p.open_bus = value
	switch reg & 7 {
	case 0:
		p.ctrl = value
		p.t = (p.t & 0xF3FF) | (u16(value & 0x03) << 10)
	case 1:
		p.mask = value
	case 3:
		p.oam_addr = value
	case 4:
		p.oam[p.oam_addr] = value
		p.oam_addr += 1
	case 5:
		if !p.w {
			p.t = (p.t & 0xFFE0) | u16(value >> 3)
			p.fine_x = value & 7
		} else {
			p.t = (p.t & 0x8C1F) | (u16(value & 0x07) << 12) | (u16(value & 0xF8) << 2)
		}
		p.w = !p.w
	case 6:
		if !p.w {
			p.t = (p.t & 0x00FF) | (u16(value & 0x3F) << 8)
		} else {
			p.t = (p.t & 0xFF00) | u16(value)
			p.v = p.t
			cart_ppu_address(&c.cart, p.v & 0x3FFF, p.dots)
		}
		p.w = !p.w
	case 7:
		ppu_mem_write(c, p.v, value)
		p.v += (p.ctrl & 0x04 != 0) ? 32 : 1
		cart_ppu_address(&c.cart, p.v & 0x3FFF, p.dots)
	}
}

// --- scrolling helpers (loopy) ---------------------------------------------

@(private = "file")
increment_x :: proc(p: ^Ppu) {
	if p.v & 0x001F == 31 {
		p.v &= ~u16(0x001F)
		p.v ~= 0x0400
	} else {
		p.v += 1
	}
}

@(private = "file")
increment_y :: proc(p: ^Ppu) {
	if p.v & 0x7000 != 0x7000 {
		p.v += 0x1000
		return
	}
	p.v &= ~u16(0x7000)
	y := (p.v & 0x03E0) >> 5
	switch y {
	case 29:
		y = 0
		p.v ~= 0x0800
	case 31:
		y = 0
	case:
		y += 1
	}
	p.v = (p.v & ~u16(0x03E0)) | (y << 5)
}

@(private = "file")
load_shifters :: proc(p: ^Ppu) {
	p.bg_lo = (p.bg_lo & 0xFF00) | u16(p.lo_latch)
	p.bg_hi = (p.bg_hi & 0xFF00) | u16(p.hi_latch)
	p.at_lo = (p.at_lo & 0xFF00) | (p.at_latch & 1 != 0 ? 0xFF : 0x00)
	p.at_hi = (p.at_hi & 0xFF00) | (p.at_latch & 2 != 0 ? 0xFF : 0x00)
}

@(private = "file")
fetch_background :: proc(c: ^Console) {
	p := &c.ppu
	switch (p.dot - 1) & 7 {
	case 0:
		load_shifters(p)
		p.nt_latch = ppu_mem_read(c, 0x2000 | (p.v & 0x0FFF))
	case 2:
		at := ppu_mem_read(c, 0x23C0 | (p.v & 0x0C00) | ((p.v >> 4) & 0x38) | ((p.v >> 2) & 0x07))
		if p.v & 0x40 != 0 {at >>= 4}
		if p.v & 0x02 != 0 {at >>= 2}
		p.at_latch = at & 3
	case 3:
		// The pattern address reaches the bus a dot before the data is latched,
		// which is what A12-watching mappers see.
		base := u16(p.ctrl & 0x10) << 8
		p.lo_latch = ppu_mem_read(c, base + u16(p.nt_latch) * 16 + ((p.v >> 12) & 7))
	case 5:
		base := u16(p.ctrl & 0x10) << 8
		p.hi_latch = ppu_mem_read(c, base + u16(p.nt_latch) * 16 + ((p.v >> 12) & 7) + 8)
	case 7:
		increment_x(p)
	}
}

// Finds the sprites for the next scanline and fetches their pattern bytes.
// Like the hardware, unused slots still fetch tile $FF, which matters for
// mappers that watch the PPU address bus.
@(private = "file")
evaluate_sprites :: proc(c: ^Console) {
	p := &c.ppu
	height := p.ctrl & 0x20 != 0 ? 16 : 8
	p.sprite_count = 0
	line := p.scanline
	found: [8]int
	for i in 0 ..< 64 {
		row := line - int(p.oam[i * 4])
		if row < 0 || row >= height {
			continue
		}
		if p.sprite_count == 8 {
			p.status |= 0x20 // sprite overflow (without the hardware's diagonal bug)
			break
		}
		found[p.sprite_count] = i
		p.sprite_count += 1
	}

	for slot in 0 ..< 8 {
		tile: u8 = 0xFF
		attr: u8 = 0
		row := 0
		i := found[slot]
		if slot < p.sprite_count {
			tile = p.oam[i * 4 + 1]
			attr = p.oam[i * 4 + 2]
			row = line - int(p.oam[i * 4])
			if attr & 0x80 != 0 {
				row = height - 1 - row // vertical flip
			}
		}
		addr: u16
		if height == 16 {
			t := u16(tile & 0xFE)
			if row >= 8 {
				t += 1
				row -= 8
			}
			addr = (u16(tile & 1) << 12) + t * 16 + u16(row)
		} else {
			addr = (u16(p.ctrl & 0x08) << 9) + u16(tile) * 16 + u16(row)
		}
		lo := ppu_mem_read(c, addr)
		hi := ppu_mem_read(c, addr + 8)
		if slot >= p.sprite_count {
			continue
		}
		if attr & 0x40 != 0 {
			lo = reverse_bits(lo)
			hi = reverse_bits(hi)
		}
		p.sprites[slot] = Sprite {
			x       = p.oam[i * 4 + 3],
			attr    = attr,
			lo      = lo,
			hi      = hi,
			is_zero = i == 0,
		}
	}
}

@(private = "file")
reverse_bits :: #force_inline proc(b: u8) -> u8 {
	r := b
	r = (r & 0xF0) >> 4 | (r & 0x0F) << 4
	r = (r & 0xCC) >> 2 | (r & 0x33) << 2
	r = (r & 0xAA) >> 1 | (r & 0x55) << 1
	return r
}

@(private = "file")
render_pixel :: proc(c: ^Console) {
	p := &c.ppu
	x := p.dot - 1
	bg_pixel: u8 = 0
	bg_palette: u8 = 0
	if p.mask & 0x08 != 0 && (x >= 8 || p.mask & 0x02 != 0) {
		bit := u16(0x8000) >> p.fine_x
		p0 := u8(p.bg_lo & bit != 0)
		p1 := u8(p.bg_hi & bit != 0)
		bg_pixel = p1 << 1 | p0
		a0 := u8(p.at_lo & bit != 0)
		a1 := u8(p.at_hi & bit != 0)
		bg_palette = a1 << 1 | a0
	}

	sp_pixel: u8 = 0
	sp_palette: u8 = 0
	sp_behind := false
	if p.mask & 0x10 != 0 && (x >= 8 || p.mask & 0x04 != 0) {
		for i in 0 ..< p.sprite_count {
			s := &p.sprites[i]
			offset := x - int(s.x)
			if offset < 0 || offset > 7 {
				continue
			}
			shift := u8(7 - offset)
			px := ((s.hi >> shift) & 1) << 1 | ((s.lo >> shift) & 1)
			if px == 0 {
				continue
			}
			if s.is_zero && bg_pixel != 0 && x != 255 {
				p.status |= 0x40
			}
			sp_pixel = px
			sp_palette = (s.attr & 3) + 4
			sp_behind = s.attr & 0x20 != 0
			break
		}
	}

	color_index: u8
	switch {
	case bg_pixel == 0 && sp_pixel == 0:
		color_index = 0
	case bg_pixel == 0:
		color_index = sp_palette * 4 + sp_pixel
	case sp_pixel == 0:
		color_index = bg_palette * 4 + bg_pixel
	case sp_behind:
		color_index = bg_palette * 4 + bg_pixel
	case:
		color_index = sp_palette * 4 + sp_pixel
	}
	// When rendering is off but v points into palette RAM, that color shows.
	color := p.palette[palette_index(u16(color_index))]
	if p.mask & 0x01 != 0 {
		color &= 0x30
	}
	emphasis := int(p.mask >> 5)
	p.framebuffer[p.scanline * SCREEN_WIDTH + x] = PALETTE[emphasis][color & 0x3F]
}

ppu_step :: proc(c: ^Console) {
	p := &c.ppu
	p.dots += 1
	visible := p.scanline < 240
	prerender := p.scanline == PRERENDER_LINE
	rendering := rendering_enabled(p)

	if rendering && (visible || prerender) {
		if (p.dot >= 2 && p.dot <= 257) || (p.dot >= 322 && p.dot <= 337) {
			p.bg_lo <<= 1
			p.bg_hi <<= 1
			p.at_lo <<= 1
			p.at_hi <<= 1
		}
		if (p.dot >= 1 && p.dot <= 256) || (p.dot >= 321 && p.dot <= 336) {
			fetch_background(c)
		}
		switch p.dot {
		case 256:
			increment_y(p)
		case 257:
			load_shifters(p)
			p.v = (p.v & ~u16(0x041F)) | (p.t & 0x041F)
		case SPRITE_FETCH_DOT:
			// Sprite pattern fetches happen during dots 257-320; we do them all at
			// once where the first one would put A12 on the bus.
			evaluate_sprites(c)
			if prerender {
				p.sprite_count = 0 // dummy fetches; nothing is drawn on line 0
			}
		case 280 ..= 304:
			if prerender {
				p.v = (p.v & ~u16(0x7BE0)) | (p.t & 0x7BE0)
			}
		case 337, 339:
			_ = ppu_mem_read(c, 0x2000 | (p.v & 0x0FFF))
		}
	}

	if visible && p.dot >= 1 && p.dot <= 256 {
		if rendering {
			render_pixel(c)
		} else {
			// Backdrop (or palette entry pointed at by v when it is in $3F00-$3FFF).
			idx := p.v & 0x3F00 == 0x3F00 ? palette_index(p.v) : 0
			emphasis := int(p.mask >> 5)
			p.framebuffer[p.scanline * SCREEN_WIDTH + p.dot - 1] = PALETTE[emphasis][p.palette[idx] & 0x3F]
		}
	}

	if p.scanline == VBLANK_LINE && p.dot == 1 {
		p.status |= 0x80
		p.frame_ready = true
		p.frame_count += 1
	}
	if prerender && p.dot == 1 {
		p.status &= 0x1F // clear vblank, sprite 0 hit, overflow
	}

	// Advance. Odd frames skip the last pre-render dot when rendering.
	if prerender && p.dot == 339 && p.odd_frame && rendering {
		p.dot = 340
	}
	p.dot += 1
	if p.dot > 340 {
		p.dot = 0
		p.scanline += 1
		if p.scanline > PRERENDER_LINE {
			p.scanline = 0
			p.odd_frame = !p.odd_frame
		}
	}
}
