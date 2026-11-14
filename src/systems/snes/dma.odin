package snes

Dma_Channel :: struct {
	control:     u8,  // $43x0
	b_addr:      u8,  // $43x1
	a_addr:      u16, // $43x2-3
	a_bank:      u8,  // $43x4
	count:       u16, // $43x5-6 (also HDMA indirect address)
	ind_bank:    u8,  // $43x7
	table_addr:  u16, // $43x8-9
	line_counter: u8, // $43xA
	unused:      u8,  // $43xB / $43xF

	hdma_active:   bool,
	hdma_transfer: bool,
}

@(private = "file", rodata)
B_OFFSETS := [8][4]u8 {
	{0, 0, 0, 0},
	{0, 1, 0, 1},
	{0, 0, 0, 0},
	{0, 0, 1, 1},
	{0, 1, 2, 3},
	{0, 1, 0, 1},
	{0, 0, 0, 0},
	{0, 0, 1, 1},
}

@(private = "file", rodata)
UNIT_SIZE := [8]int{1, 2, 2, 4, 4, 4, 2, 4}

dma_read_reg :: proc(c: ^Console, addr: u16) -> u8 {
	ch := &c.dma[(addr >> 4) & 7]
	switch addr & 0x0F {
	case 0x0: return ch.control
	case 0x1: return ch.b_addr
	case 0x2: return u8(ch.a_addr)
	case 0x3: return u8(ch.a_addr >> 8)
	case 0x4: return ch.a_bank
	case 0x5: return u8(ch.count)
	case 0x6: return u8(ch.count >> 8)
	case 0x7: return ch.ind_bank
	case 0x8: return u8(ch.table_addr)
	case 0x9: return u8(ch.table_addr >> 8)
	case 0xA: return ch.line_counter
	case 0xB, 0xF: return ch.unused
	}
	return c.open_bus
}

dma_write_reg :: proc(c: ^Console, addr: u16, v: u8) {
	ch := &c.dma[(addr >> 4) & 7]
	switch addr & 0x0F {
	case 0x0: ch.control = v
	case 0x1: ch.b_addr = v
	case 0x2: ch.a_addr = (ch.a_addr & 0xFF00) | u16(v)
	case 0x3: ch.a_addr = (ch.a_addr & 0x00FF) | u16(v) << 8
	case 0x4: ch.a_bank = v
	case 0x5: ch.count = (ch.count & 0xFF00) | u16(v)
	case 0x6: ch.count = (ch.count & 0x00FF) | u16(v) << 8
	case 0x7: ch.ind_bank = v
	case 0x8: ch.table_addr = (ch.table_addr & 0xFF00) | u16(v)
	case 0x9: ch.table_addr = (ch.table_addr & 0x00FF) | u16(v) << 8
	case 0xA: ch.line_counter = v
	case 0xB, 0xF: ch.unused = v
	}
}

// The A bus cannot reach the B bus or the DMA registers themselves.
@(private = "file")
a_bus_valid :: proc(addr: u32) -> bool {
	bank := addr >> 16
	a := addr & 0xFFFF
	if bank & 0x40 == 0 {
		if a >= 0x2100 && a <= 0x21FF {return false}
		if a >= 0x4300 && a <= 0x437F {return false}
	}
	return true
}

@(private = "file")
transfer_byte :: proc(c: ^Console, ch: ^Dma_Channel, a_addr: u32, b_offset: u8) {
	b := 0x2100 | u32(ch.b_addr + b_offset)
	if ch.control & 0x80 != 0 {
		// B -> A
		v := bus_read(c, b)
		if a_bus_valid(a_addr) {
			bus_write(c, a_addr, v)
		}
	} else {
		v := a_bus_valid(a_addr) ? bus_read(c, a_addr) : c.open_bus
		bus_write(c, b, v)
	}
}

// General-purpose DMA, triggered by a write to MDMAEN ($420B). The CPU is
// halted for the duration; the time is charged to `pending`.
dma_run :: proc(c: ^Console, mask: u8) {
	if mask == 0 {
		return
	}
	c.pending += 12
	for i in 0 ..< 8 {
		if mask & (1 << uint(i)) == 0 {
			continue
		}
		ch := &c.dma[i]
		c.pending += 8
		mode := ch.control & 7
		step: i32 = 0
		if ch.control & 0x08 == 0 {
			step = ch.control & 0x10 != 0 ? -1 : 1
		}
		n := 0
		for {
			a := u32(ch.a_bank) << 16 | u32(ch.a_addr)
			transfer_byte(c, ch, a, B_OFFSETS[mode][n & 3])
			ch.a_addr = u16(i32(ch.a_addr) + step)
			c.pending += 8
			n += 1
			ch.count -= 1
			if ch.count == 0 {
				break
			}
		}
	}
}

// Called at the start of each frame.
hdma_init :: proc(c: ^Console) {
	for i in 0 ..< 8 {
		ch := &c.dma[i]
		ch.hdma_active = false
		ch.hdma_transfer = false
		if c.hdmaen & (1 << uint(i)) == 0 {
			continue
		}
		ch.table_addr = ch.a_addr
		hdma_load_entry(c, ch)
	}
}

@(private = "file")
hdma_table_read :: proc(c: ^Console, ch: ^Dma_Channel) -> u8 {
	v := bus_read(c, u32(ch.a_bank) << 16 | u32(ch.table_addr))
	ch.table_addr += 1
	c.pending += 8
	return v
}

@(private = "file")
hdma_load_entry :: proc(c: ^Console, ch: ^Dma_Channel) {
	ch.line_counter = hdma_table_read(c, ch)
	if ch.control & 0x40 != 0 {
		lo := u16(hdma_table_read(c, ch))
		ch.count = lo | u16(hdma_table_read(c, ch)) << 8
	}
	ch.hdma_active = ch.line_counter != 0
	ch.hdma_transfer = true
}

// Called once per visible scanline at the start of HBlank.
hdma_line :: proc(c: ^Console) {
	if c.hdmaen == 0 {
		return
	}
	c.pending += 18
	for i in 0 ..< 8 {
		ch := &c.dma[i]
		if c.hdmaen & (1 << uint(i)) == 0 || !ch.hdma_active {
			continue
		}
		c.pending += 8
		mode := ch.control & 7
		if ch.hdma_transfer {
			for n in 0 ..< UNIT_SIZE[mode] {
				addr: u32
				if ch.control & 0x40 != 0 {
					addr = u32(ch.ind_bank) << 16 | u32(ch.count)
					ch.count += 1
				} else {
					addr = u32(ch.a_bank) << 16 | u32(ch.table_addr)
					ch.table_addr += 1
				}
				transfer_byte(c, ch, addr, B_OFFSETS[mode][n])
				c.pending += 8
			}
		}
		ch.line_counter -= 1
		ch.hdma_transfer = ch.line_counter & 0x80 != 0
		if ch.line_counter & 0x7F == 0 {
			hdma_load_entry(c, ch)
		}
	}
}
