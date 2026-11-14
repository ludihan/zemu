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
