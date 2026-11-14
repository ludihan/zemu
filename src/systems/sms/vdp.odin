package sms

// Video Display Processor (TMS9918 derivative) in Mode 4, as used by the
// Master System and Game Gear. Lines are rendered whole.

SCREEN_W :: 256
SCREEN_H :: 192
GG_W     :: 160
GG_H     :: 144
GG_X     :: 48 // Game Gear viewport offset inside the 256x192 picture
GG_Y     :: 24

Vdp :: struct {
	vram:        [0x4000]u8,
	cram:        [64]u8, // 32 bytes on Master System, 64 on Game Gear
	regs:        [11]u8,
	addr:        u16,
	code:        u8,
	latch:       u8,
	second_byte: bool,
	read_buffer: u8,
	cram_latch:  u8,
	status:      u8,
	line_counter: u8,
	line_irq:    bool,
	line:        int,
	game_gear:   bool,
	framebuffer: [SCREEN_W * SCREEN_H]u32,
	gg_frame:    [GG_W * GG_H]u32,
}

vdp_reset :: proc(v: ^Vdp) {
	gg := v.game_gear
	v^ = {}
	v.game_gear = gg
	v.regs = {0x36, 0x80, 0xFF, 0xFF, 0xFF, 0xFF, 0xFB, 0x00, 0x00, 0x00, 0xFF}
}

vdp_irq :: proc(v: ^Vdp) -> bool {
	frame := v.status & 0x80 != 0 && v.regs[1] & 0x20 != 0
	line := v.line_irq && v.regs[0] & 0x10 != 0
	return frame || line
}

vdp_read_status :: proc(v: ^Vdp) -> u8 {
	s := v.status | 0x1F
	v.status = 0
	v.line_irq = false
	v.second_byte = false
	return s
}

vdp_write_control :: proc(v: ^Vdp, b: u8) {
	if !v.second_byte {
		v.latch = b
		v.addr = (v.addr & 0x3F00) | u16(b)
		v.second_byte = true
		return
	}
	v.second_byte = false
	v.addr = u16(b & 0x3F) << 8 | u16(v.latch)
	v.code = b >> 6
	switch v.code {
	case 0:
		v.read_buffer = v.vram[v.addr]
		v.addr = (v.addr + 1) & 0x3FFF
	case 2:
		reg := b & 0x0F
		if int(reg) < len(v.regs) {
			v.regs[reg] = v.latch
		}
	}
}

vdp_read_data :: proc(v: ^Vdp) -> u8 {
	v.second_byte = false
	r := v.read_buffer
	v.read_buffer = v.vram[v.addr]
	v.addr = (v.addr + 1) & 0x3FFF
	return r
}

vdp_write_data :: proc(v: ^Vdp, b: u8) {
	v.second_byte = false
	if v.code == 3 {
		if v.game_gear {
			// 12-bit colors are written as two bytes; the second commits both
			if v.addr & 1 == 0 {
				v.cram_latch = b
			} else {
				v.cram[(v.addr - 1) & 0x3F] = v.cram_latch
				v.cram[v.addr & 0x3F] = b & 0x0F
			}
		} else {
			v.cram[v.addr & 0x1F] = b
		}
	} else {
		v.vram[v.addr] = b
	}
	v.read_buffer = b
	v.addr = (v.addr + 1) & 0x3FFF
}

// V counter as the CPU sees it (NTSC 192-line mode jumps from $DA to $D5).
vdp_v_counter :: proc(v: ^Vdp) -> u8 {
	if v.line <= 0xDA {
		return u8(v.line)
	}
	return u8(v.line - 6)
}

@(private = "file")
color :: #force_inline proc(v: ^Vdp, index: int) -> u32 {
	if v.game_gear {
		lo := u32(v.cram[(index * 2) & 0x3F])
		hi := u32(v.cram[(index * 2 + 1) & 0x3F])
		r := lo & 0x0F
		g := lo >> 4
		b := hi & 0x0F
		return (r * 17) << 16 | (g * 17) << 8 | (b * 17)
	}
	c := u32(v.cram[index & 0x1F])
	return ((c & 3) * 85) << 16 | (((c >> 2) & 3) * 85) << 8 | (((c >> 4) & 3) * 85)
}

@(private = "file")
tile_pixel :: #force_inline proc(v: ^Vdp, tile: int, row: int, col: int) -> u8 {
	base := (tile * 32 + row * 4) & 0x3FFF
	bit := u8(7 - col)
	p := (v.vram[base] >> bit) & 1
	p |= ((v.vram[base + 1] >> bit) & 1) << 1
	p |= ((v.vram[base + 2] >> bit) & 1) << 2
	p |= ((v.vram[base + 3] >> bit) & 1) << 3
	return p
}

// Called at the start of every scanline.
vdp_line :: proc(v: ^Vdp, line: int) -> (frame_start: bool) {
	v.line = line
	if line < SCREEN_H {
		render_line(v, line)
	}
	// The line counter runs on active lines and line 192; elsewhere it reloads.
	if line <= SCREEN_H {
		if v.line_counter == 0 {
			v.line_counter = v.regs[10]
			v.line_irq = true
		} else {
			v.line_counter -= 1
		}
	} else {
		v.line_counter = v.regs[10]
	}
	if line == SCREEN_H {
		v.status |= 0x80
		if v.game_gear {
			for y in 0 ..< GG_H {
				copy(v.gg_frame[y * GG_W:][:GG_W], v.framebuffer[(y + GG_Y) * SCREEN_W + GG_X:][:GG_W])
			}
		}
		return true
	}
	return false
}

@(private = "file")
render_line :: proc(v: ^Vdp, y: int) {
	row := v.framebuffer[y * SCREEN_W:][:SCREEN_W]
	if v.regs[0] & 0x04 == 0 {
		render_legacy(v, y, row) // Mode 4 off: the TMS9918 modes
		return
	}
	backdrop := color(v, 16 + int(v.regs[7] & 0x0F))
	if v.regs[1] & 0x40 == 0 {
		for &p in row {p = 0}
		return
	}

	bg_opaque: [SCREEN_W]bool
	bg_priority: [SCREEN_W]bool
	name_base := int(v.regs[2] & 0x0E) << 10
	hscroll := int(v.regs[8])
	if v.regs[0] & 0x40 != 0 && y < 16 {
		hscroll = 0
	}
	vscroll := int(v.regs[9])
	for x in 0 ..< SCREEN_W {
		vy := y + vscroll
		if v.regs[0] & 0x80 != 0 && x >= 192 {
			vy = y // right 8 columns ignore vertical scroll
		}
		vy %= 224
		sx := (x - hscroll) & 0xFF
		entry_addr := name_base + (vy / 8) * 64 + (sx / 8) * 2
		lo := u16(v.vram[entry_addr & 0x3FFF])
		hi := u16(v.vram[(entry_addr + 1) & 0x3FFF])
		e := lo | hi << 8
		tile := int(e & 0x1FF)
		trow := vy & 7
		tcol := sx & 7
		if e & 0x0400 != 0 {trow = 7 - trow}
		if e & 0x0200 != 0 {tcol = 7 - tcol}
		p := tile_pixel(v, tile, trow, tcol)
		pal := e & 0x0800 != 0 ? 16 : 0
		row[x] = color(v, pal + int(p))
		bg_opaque[x] = p != 0
		bg_priority[x] = e & 0x1000 != 0
	}

	// sprites
	sat := int(v.regs[5] & 0x7E) << 7
	tall := v.regs[1] & 0x02 != 0
	zoom := v.regs[1] & 0x01 != 0
	height := tall ? 16 : 8
	scale := zoom ? 2 : 1
	tile_base := v.regs[6] & 0x04 != 0 ? 256 : 0
	drawn: [SCREEN_W]bool
	count := 0
	for i in 0 ..< 64 {
		sy := int(v.vram[(sat + i) & 0x3FFF])
		if sy == 0xD0 {
			break // end of the sprite list in 192-line mode
		}
		top := sy + 1
		if top > 240 {top -= 256} // wraps above the screen
		if y < top || y >= top + height * scale {
			continue
		}
		count += 1
		if count > 8 {
			v.status |= 0x40
			break
		}
		sx := int(v.vram[(sat + 0x80 + i * 2) & 0x3FFF])
		if v.regs[0] & 0x08 != 0 {sx -= 8}
		tile := int(v.vram[(sat + 0x81 + i * 2) & 0x3FFF]) + tile_base
		if tall {tile &= ~int(1)}
		line := (y - top) / scale
		if line >= 8 {
			tile += 1
			line -= 8
		}
		for col in 0 ..< 8 * scale {
			x := sx + col
			if x < 0 || x >= SCREEN_W {
				continue
			}
			p := tile_pixel(v, tile, line, col / scale)
			if p == 0 {
				continue
			}
			if drawn[x] {
				v.status |= 0x20 // sprite collision
				continue
			}
			drawn[x] = true
			if bg_priority[x] && bg_opaque[x] {
				continue
			}
			row[x] = color(v, 16 + int(p))
		}
	}

	if v.regs[0] & 0x20 != 0 {
		for x in 0 ..< 8 {row[x] = backdrop}
	}
}

// --- TMS9918 modes ----------------------------------------------------------
// The SG-1000's video, which the Master System's VDP keeps for older games:
// Graphics I and II, text and multicolor, with the TMS9918's own sprites and
// fixed 16-color palette.

@(private = "file")
TMS_PALETTE := [16]u32 {
	0x000000, 0x000000, 0x21C842, 0x5EDC78, 0x5455ED, 0x7D76FC, 0xD4524D, 0x42EBF5,
	0xFC5554, 0xFF7978, 0xD4C154, 0xE6CE80, 0x21B03B, 0xC95BBA, 0xCCCCCC, 0xFFFFFF,
}

@(private = "file")
render_legacy :: proc(v: ^Vdp, y: int, row: []u32) {
	backdrop := TMS_PALETTE[v.regs[7] & 0x0F]
	if v.regs[1] & 0x40 == 0 {
		for &p in row {p = backdrop}
		return
	}
	pick :: #force_inline proc(index: u8, backdrop: u32) -> u32 {
		return index == 0 ? backdrop : TMS_PALETTE[index]
	}
	text := v.regs[1] & 0x10 != 0
	multicolor := v.regs[1] & 0x08 != 0
	graphics2 := v.regs[0] & 0x02 != 0
	name_base := int(v.regs[2] & 0x0F) << 10
	ty := y / 8
	switch {
	case text:
		// 40 columns of 6-pixel characters between 8-pixel borders
		fg := pick(v.regs[7] >> 4, backdrop)
		pattern_base := int(v.regs[4] & 0x07) << 11
		for x in 0 ..< SCREEN_W {
			if x < 8 || x >= 248 {
				row[x] = backdrop
				continue
			}
			col := (x - 8) / 6
			name := int(v.vram[(name_base + ty * 40 + col) & 0x3FFF])
			bits := v.vram[(pattern_base + name * 8 + y % 8) & 0x3FFF]
			row[x] = bits & (0x80 >> u8((x - 8) % 6)) != 0 ? fg : backdrop
		}
		return // no sprites in text mode
	case multicolor:
		// each name selects 4x4-pixel blocks of two colors per byte
		pattern_base := int(v.regs[4] & 0x07) << 11
		for x in 0 ..< SCREEN_W {
			name := int(v.vram[(name_base + ty * 32 + x / 8) & 0x3FFF])
			b := v.vram[(pattern_base + name * 8 + (ty & 3) * 2 + (y / 4) & 1) & 0x3FFF]
			row[x] = pick(x & 4 == 0 ? b >> 4 : b & 0x0F, backdrop)
		}
	case:
		for x in 0 ..< SCREEN_W {
			name := int(v.vram[(name_base + ty * 32 + x / 8) & 0x3FFF])
			bits, colors: u8
			if graphics2 {
				// three thirds of the screen with 256 patterns each; registers
				// 3 and 4 also mask the table addresses
				index := (ty / 8) * 256 + name
				pattern := (int(v.regs[4] & 0x04) << 11) | (index * 8 + y % 8) & (int(v.regs[4] & 0x03) << 11 | 0x7FF)
				color_addr := (int(v.regs[3] & 0x80) << 6) | (index * 8 + y % 8) & (int(v.regs[3] & 0x7F) << 6 | 0x3F)
				bits = v.vram[pattern & 0x3FFF]
				colors = v.vram[color_addr & 0x3FFF]
			} else {
				bits = v.vram[(int(v.regs[4] & 0x07) << 11 + name * 8 + y % 8) & 0x3FFF]
				colors = v.vram[(int(v.regs[3]) << 6 + name / 8) & 0x3FFF]
			}
			on := bits & (0x80 >> u8(x & 7)) != 0
			row[x] = pick(on ? colors >> 4 : colors & 0x0F, backdrop)
		}
	}
	legacy_sprites(v, y, row)
}

// Up to four of 32 sprites per line; more set the fifth-sprite flag and
// number in the status register.
@(private = "file")
legacy_sprites :: proc(v: ^Vdp, y: int, row: []u32) {
	sat := int(v.regs[5] & 0x7F) << 7
	pattern_base := int(v.regs[6] & 0x07) << 11
	big := v.regs[1] & 0x02 != 0
	zoom := v.regs[1] & 0x01 != 0
	size := big ? 16 : 8
	scale := zoom ? 2 : 1
	drawn: [SCREEN_W]bool
	count := 0
	for i in 0 ..< 32 {
		entry := sat + i * 4
		sy := int(v.vram[entry & 0x3FFF])
		if sy == 0xD0 {
			break
		}
		top := sy + 1
		if top > 0xE0 {top -= 256}
		if y < top || y >= top + size * scale {
			continue
		}
		count += 1
		if count > 4 {
			if v.status & 0x40 == 0 {
				v.status = (v.status & 0xE0) | 0x40 | u8(i)
			}
			break
		}
		sx := int(v.vram[(entry + 1) & 0x3FFF])
		name := int(v.vram[(entry + 2) & 0x3FFF])
		attr := v.vram[(entry + 3) & 0x3FFF]
		if attr & 0x80 != 0 {sx -= 32} // early clock
		if big {name &= 0xFC}
		line := (y - top) / scale
		for col in 0 ..< size * scale {
			x := sx + col
			if x < 0 || x >= SCREEN_W {
				continue
			}
			c := col / scale
			// 16x16 sprites: four patterns, left column first
			addr := pattern_base + name * 8 + (c / 8) * 16 + line
			if v.vram[addr & 0x3FFF] & (0x80 >> u8(c & 7)) == 0 {
				continue
			}
			if drawn[x] {
				v.status |= 0x20 // collision
				continue
			}
			drawn[x] = true
			if attr & 0x0F != 0 {
				row[x] = TMS_PALETTE[attr & 0x0F]
			}
		}
	}
}
