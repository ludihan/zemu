package gb

// LCD controller. Lines are rendered whole when mode 3 ends, using the
// registers as they are at that point.

SCREEN_W :: 160
SCREEN_H :: 144
LINE_DOTS :: 456

Ppu :: struct {
	vram:      [2][0x2000]u8,
	oam:       [0xA0]u8,
	lcdc, stat, scy, scx, ly, lyc, wy, wx: u8,
	bgp, obp0, obp1: u8,
	dot:       int,
	mode:      u8,
	first_line: bool, // the line right after the LCD turns on (no OAM scan)
	window_line: int,
	stat_line: bool, // previous level of the combined STAT interrupt signal
	frame_ready: bool,
	// CGB
	vbk:       u8,
	bg_pal:    [64]u8,
	ob_pal:    [64]u8,
	bcps, ocps: u8,
	opri:      u8,
	framebuffer: [SCREEN_W * SCREEN_H]u32,
}

@(private = "file", rodata)
DMG_SHADES := [4]u32{0xE0F8D0, 0x88C070, 0x346856, 0x081820}

ppu_reset :: proc(p: ^Ppu) {
	p.lcdc = 0x91
	p.stat = 0x85
	p.bgp = 0xFC
	p.obp0 = 0xFF
	p.obp1 = 0xFF
	p.ly = 0
	p.dot = 0
	p.mode = 2
	for &b in p.bg_pal {b = 0xFF}
}

@(private = "file")
lcd_on :: #force_inline proc(p: ^Ppu) -> bool {
	return p.lcdc & 0x80 != 0
}

ppu_write_lcdc :: proc(c: ^Console, v: u8) {
	p := &c.ppu
	was_on := lcd_on(p)
	p.lcdc = v
	if was_on && !lcd_on(p) {
		p.ly = 0
		p.dot = 0
		p.mode = 0
		p.window_line = 0
		for &px in p.framebuffer {px = 0xFFFFFF}
	} else if !was_on && lcd_on(p) {
		// The first line after switching on is 4 dots short and skips the
		// OAM scan (STAT reads mode 0 until mode 3 starts).
		p.ly = 0
		p.dot = 4
		p.mode = 0
		p.first_line = true
		p.window_line = 0
	}
}

ppu_read_stat :: proc(p: ^Ppu) -> u8 {
	v := (p.stat & 0x78) | 0x80
	if lcd_on(p) {
		v |= p.mode
		if p.ly == p.lyc {v |= 0x04}
	}
	return v
}

// The four STAT sources are OR-ed into one line; only its rising edge
// requests an interrupt ("STAT blocking").
@(private = "file")
update_stat :: proc(c: ^Console) {
	p := &c.ppu
	line := false
	if lcd_on(p) {
		if p.stat & 0x40 != 0 && p.ly == p.lyc {line = true}
		switch p.mode {
		case 0: if p.stat & 0x08 != 0 {line = true}
		case 1: if p.stat & 0x10 != 0 {line = true}
		case 2: if p.stat & 0x20 != 0 {line = true}
		}
	}
	if line && !p.stat_line {
		c.if_ |= 0x02
	}
	p.stat_line = line
}

ppu_stat_written :: proc(c: ^Console) {
	update_stat(c)
}

// Advances the PPU by `dots` (4.19 MHz clocks).
ppu_step :: proc(c: ^Console, dots: int) {
	p := &c.ppu
	if !lcd_on(p) {
		// With the LCD off, still produce a frame every 70224 dots.
		p.dot += dots
		if p.dot >= LINE_DOTS * 154 {
			p.dot -= LINE_DOTS * 154
			p.frame_ready = true
		}
		return
	}
	for _ in 0 ..< dots {
		p.dot += 1
		if p.ly < SCREEN_H {
			switch p.dot {
			case 80:
				p.mode = 3
				update_stat(c)
			case 252:
				render_line(c)
				p.mode = 0
				update_stat(c)
				hdma_hblank(c)
			}
		}
		if p.dot >= LINE_DOTS {
			p.dot = 0
			p.first_line = false
			p.ly += 1
			if p.ly == SCREEN_H {
				p.mode = 1
				c.if_ |= 0x01
				p.frame_ready = true
			} else if p.ly > 153 {
				p.ly = 0
				p.window_line = 0
			}
			if p.ly < SCREEN_H {
				p.mode = 2
			}
			update_stat(c)
		}
	}
}

// --- CPU access to OAM and VRAM ---------------------------------------------

// OAM is locked during the OAM scan and pixel transfer, VRAM during transfer.
oam_locked :: proc(p: ^Ppu) -> bool {
	return lcd_on(p) && p.ly < SCREEN_H && (p.mode == 2 || p.mode == 3)
}

vram_locked :: proc(p: ^Ppu) -> bool {
	return lcd_on(p) && p.ly < SCREEN_H && p.mode == 3
}

// --- DMG OAM corruption bug ----------------------------------------------------
//
// On the DMG, a 16-bit increment/decrement of a value in $FE00-$FEFF, or a
// CPU access to that range, during the OAM scan corrupts the 8-byte row the
// scan is reading.

// Byte offset of the row being scanned, or -1 outside the scan.
oam_scan_row :: proc(p: ^Ppu) -> int {
	// The CPU sees the PPU at the end of its M-cycle; the scan state that
	// matters is the one during it.
	d := p.dot - 4
	if !lcd_on(p) || p.ly >= SCREEN_H || p.first_line || d < 0 || d >= 80 {
		return -1
	}
	row := (d / 4) * 8 + 8
	return row < 0xA0 ? row : -1
}

@(private = "file")
word :: #force_inline proc(p: ^Ppu, i: int) -> u16 {
	return u16(p.oam[i]) | u16(p.oam[i + 1]) << 8
}

@(private = "file")
set_word :: #force_inline proc(p: ^Ppu, i: int, v: u16) {
	p.oam[i] = u8(v)
	p.oam[i + 1] = u8(v >> 8)
}

@(private = "file")
copy_tail :: proc(p: ^Ppu, row: int) {
	for k in 2 ..< 8 {
		p.oam[row + k] = p.oam[row - 8 + k]
	}
}

oam_corrupt_write :: proc(p: ^Ppu, row: int) {
	if row < 8 {return}
	a, b, c := word(p, row), word(p, row - 8), word(p, row - 4)
	set_word(p, row, ((a ~ c) & (b ~ c)) ~ c)
	copy_tail(p, row)
}

oam_corrupt_read :: proc(p: ^Ppu, row: int) {
	if row < 8 {return}
	a, b, c := word(p, row), word(p, row - 8), word(p, row - 4)
	set_word(p, row, b | (a & c))
	copy_tail(p, row)
}

// A read combined with an increment/decrement (LD A,(HL+), POP).
oam_corrupt_read_inc :: proc(p: ^Ppu, row: int) {
	if row >= 0x20 && row < 0x98 {
		a, b, c, d := word(p, row - 16), word(p, row - 8), word(p, row), word(p, row - 4)
		set_word(p, row - 8, (b & (a | c | d)) | (a & c & d))
		for k in 0 ..< 8 {
			v := p.oam[row - 8 + k]
			p.oam[row + k] = v
			p.oam[row - 16 + k] = v
		}
	}
	oam_corrupt_read(p, row)
}

// --- rendering -------------------------------------------------------------

@(private = "file")
cgb_color :: #force_inline proc(pal: []u8, index: int) -> u32 {
	lo := u16(pal[index * 2])
	hi := u16(pal[index * 2 + 1])
	v := lo | hi << 8
	r := u32(v & 0x1F)
	g := u32((v >> 5) & 0x1F)
	b := u32((v >> 10) & 0x1F)
	return (r << 3 | r >> 2) << 16 | (g << 3 | g >> 2) << 8 | (b << 3 | b >> 2)
}

@(private = "file")
tile_pixel :: #force_inline proc(p: ^Ppu, bank: int, tile_addr: int, row: int, col: int) -> u8 {
	lo := p.vram[bank][(tile_addr + row * 2) & 0x1FFF]
	hi := p.vram[bank][(tile_addr + row * 2 + 1) & 0x1FFF]
	bit := u8(7 - col)
	return ((hi >> bit) & 1) << 1 | ((lo >> bit) & 1)
}

@(private = "file")
render_line :: proc(c: ^Console) {
	p := &c.ppu
	y := int(p.ly)
	row := p.framebuffer[y * SCREEN_W:][:SCREEN_W]
	cgb := c.cgb

	bg_index: [SCREEN_W]u8     // raw color number 0-3 of the BG/window pixel
	bg_priority: [SCREEN_W]bool // CGB tile attribute bit 7

	bg_enabled := p.lcdc & 0x01 != 0
	if bg_enabled || cgb {
		window_visible := p.lcdc & 0x20 != 0 && int(p.wy) <= y && int(p.wx) <= 166
		drew_window := false
		for x in 0 ..< SCREEN_W {
			in_window := window_visible && x + 7 >= int(p.wx)
			map_base: int
			px, py: int
			if in_window {
				map_base = p.lcdc & 0x40 != 0 ? 0x1C00 : 0x1800
				px = x + 7 - int(p.wx)
				py = p.window_line
				drew_window = true
			} else {
				map_base = p.lcdc & 0x08 != 0 ? 0x1C00 : 0x1800
				px = (x + int(p.scx)) & 0xFF
				py = (y + int(p.scy)) & 0xFF
			}
			map_addr := map_base + (py / 8) * 32 + px / 8
			tile := p.vram[0][map_addr]
			attr: u8 = cgb ? p.vram[1][map_addr] : 0
			tile_addr: int
			if p.lcdc & 0x10 != 0 {
				tile_addr = int(tile) * 16
			} else {
				tile_addr = 0x1000 + int(i8(tile)) * 16
			}
			trow := py & 7
			tcol := px & 7
			if attr & 0x40 != 0 {trow = 7 - trow}
			if attr & 0x20 != 0 {tcol = 7 - tcol}
			ci := tile_pixel(p, int(attr >> 3) & 1, tile_addr, trow, tcol)
			if !cgb && !bg_enabled {
				ci = 0
			}
			bg_index[x] = ci
			bg_priority[x] = attr & 0x80 != 0
			if cgb {
				row[x] = cgb_color(p.bg_pal[:], int(attr & 7) * 4 + int(ci))
			} else {
				row[x] = DMG_SHADES[(p.bgp >> (ci * 2)) & 3]
			}
		}
		if drew_window {
			p.window_line += 1
		}
	} else {
		for &px in row {px = DMG_SHADES[0]}
	}

	if p.lcdc & 0x02 == 0 {
		return
	}

	// OAM scan: the first ten sprites on this line, in OAM order.
	height := p.lcdc & 0x04 != 0 ? 16 : 8
	found: [10]int
	count := 0
	for i in 0 ..< 40 {
		sy := int(p.oam[i * 4]) - 16
		if y >= sy && y < sy + height {
			found[count] = i
			count += 1
			if count == 10 {break}
		}
	}
	// Drawing order: DMG gives priority to the lowest X (then OAM order),
	// CGB to OAM order. Draw from lowest to highest priority.
	order := found
	if !cgb || p.opri & 1 != 0 {
		for i in 1 ..< count {
			for j := i; j > 0 && p.oam[order[j] * 4 + 1] < p.oam[order[j - 1] * 4 + 1]; j -= 1 {
				order[j], order[j - 1] = order[j - 1], order[j]
			}
		}
	}
	owner: [SCREEN_W]bool // a higher-priority sprite already covers this pixel
	for k in 0 ..< count {
		i := order[k]
		sy := int(p.oam[i * 4]) - 16
		sx := int(p.oam[i * 4 + 1]) - 8
		tile := int(p.oam[i * 4 + 2])
		attr := p.oam[i * 4 + 3]
		line := y - sy
		if attr & 0x40 != 0 {line = height - 1 - line}
		if height == 16 {tile &= 0xFE}
		bank := cgb ? int(attr >> 3) & 1 : 0
		for col in 0 ..< 8 {
			x := sx + col
			if x < 0 || x >= SCREEN_W || owner[x] {
				continue
			}
			tc := attr & 0x20 != 0 ? 7 - col : col
			ci := tile_pixel(p, bank, tile * 16, line, tc)
			if ci == 0 {
				continue
			}
			owner[x] = true
			if bg_index[x] != 0 {
				if cgb {
					// with LCDC bit 0 clear, sprites always win
					if p.lcdc & 0x01 != 0 && (attr & 0x80 != 0 || bg_priority[x]) {
						continue
					}
				} else if attr & 0x80 != 0 {
					continue
				}
			}
			if cgb {
				row[x] = cgb_color(p.ob_pal[:], int(attr & 7) * 4 + int(ci))
			} else {
				pal := attr & 0x10 != 0 ? p.obp1 : p.obp0
				row[x] = DMG_SHADES[(pal >> (ci * 2)) & 3]
			}
		}
	}
}
