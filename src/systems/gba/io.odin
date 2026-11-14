package gba

// I/O registers at 0x04000000: interrupts, timers, DMA, keypad and the
// glue that routes video and sound registers to their units.

IRQ_VBLANK  :: u16(1 << 0)
IRQ_HBLANK  :: u16(1 << 1)
IRQ_VCOUNT  :: u16(1 << 2)
IRQ_TIMER0  :: u16(1 << 3)
IRQ_DMA0    :: u16(1 << 8)
IRQ_KEYPAD  :: u16(1 << 12)

Timer :: struct {
	reload:  u16,
	counter: u16,
	control: u16,
	acc:     int, // prescaler progress in CPU cycles
}

Dma :: struct {
	src, dst:         u32, // register values
	count:            u16,
	control:          u16,
	cur_src, cur_dst: u32, // internal pointers
	cur_count:        u32,
	active:           bool,
}

irq_raise :: #force_inline proc(c: ^Console, bits: u16) {
	c.if_ |= bits
}

irq_pending :: #force_inline proc(c: ^Console) -> bool {
	return c.ime && c.ie & c.if_ & 0x3FFF != 0
}

irq_wake :: #force_inline proc(c: ^Console) -> bool {
	return c.ie & c.if_ & 0x3FFF != 0
}

// --- register access ----------------------------------------------------------

io_read8 :: proc(c: ^Console, addr: u32) -> u8 {
	v := io_read16(c, addr & ~u32(1))
	return u8(v >> ((addr & 1) * 8))
}

io_write8 :: proc(c: ^Console, addr: u32, v: u8) {
	a := addr & 0x3FF
	switch a {
	case 0x202: // IF: write-one-to-clear per byte
		c.if_ &= ~u16(v)
		return
	case 0x203:
		c.if_ &= ~(u16(v) << 8)
		return
	case 0x301: // HALTCNT
		c.cpu.halted = true
		return
	case 0x0A0 ..= 0x0A7: // FIFOs take byte writes
		fifo_write8(&c.sound, int(a - 0xA0) / 4, v)
		return
	}
	if a >= 0x60 && a < 0xA0 {
		sound_write8(&c.sound, a, v)
		return
	}
	old := io_read16(c, addr & ~u32(1))
	if a & 1 != 0 {
		io_write16(c, addr & ~u32(1), (old & 0x00FF) | u16(v) << 8)
	} else {
		io_write16(c, addr, (old & 0xFF00) | u16(v))
	}
}

io_read16 :: proc(c: ^Console, addr: u32) -> u16 {
	a := addr & 0x3FE
	if a >= 0x60 && a < 0xA0 {
		return u16(sound_read8(&c.sound, a)) | u16(sound_read8(&c.sound, a + 1)) << 8
	}
	switch a {
	case 0x000 ..= 0x05F: return ppu_read16(c, a)
	case 0x0B8, 0x0C4, 0x0D0, 0x0DC: return 0 // DMA counts are write-only
	case 0x0BA, 0x0C6, 0x0D2, 0x0DE:
		return c.dma[(a - 0xBA) / 12].control
	case 0x0B0 ..= 0x0DF: return 0
	case 0x100, 0x104, 0x108, 0x10C:
		return c.timers[(a - 0x100) / 4].counter
	case 0x102, 0x106, 0x10A, 0x10E:
		return c.timers[(a - 0x102) / 4].control
	case 0x130: return keyinput(c)
	case 0x132: return c.keycnt
	case 0x134: return 0x8000 // RCNT: general purpose mode
	case 0x200: return c.ie
	case 0x202: return c.if_
	case 0x204: return c.waitcnt
	case 0x208: return c.ime ? 1 : 0
	case 0x300: return u16(c.postflg)
	case 0x120 ..= 0x15F: return c.io_misc[(a - 0x120) / 2]
	}
	return 0
}

io_write16 :: proc(c: ^Console, addr: u32, v: u16) {
	a := addr & 0x3FE
	if a >= 0x60 && a < 0xA0 {
		sound_write8(&c.sound, a, u8(v))
		sound_write8(&c.sound, a + 1, u8(v >> 8))
		return
	}
	switch a {
	case 0x000 ..= 0x05F: ppu_write16(c, a, v)
	case 0x0A0 ..= 0x0A7:
		fifo_write8(&c.sound, int(a - 0xA0) / 4, u8(v))
		fifo_write8(&c.sound, int(a - 0xA0) / 4, u8(v >> 8))
	case 0x0B0 ..= 0x0DF:
		dma_write16(c, a, v)
	case 0x100, 0x104, 0x108, 0x10C:
		c.timers[(a - 0x100) / 4].reload = v
	case 0x102, 0x106, 0x10A, 0x10E:
		t := &c.timers[(a - 0x102) / 4]
		if t.control & 0x80 == 0 && v & 0x80 != 0 {
			t.counter = t.reload
			t.acc = 0
		}
		t.control = v & 0xC7
	case 0x132:
		c.keycnt = v
		keypad_check(c)
	case 0x200: c.ie = v
	case 0x202: c.if_ &= ~v
	case 0x204:
		c.waitcnt = v & 0x5FFF
		update_waitstates(c)
	case 0x208: c.ime = v & 1 != 0
	case 0x300:
		c.postflg = u8(v)
		if v & 0x8000 == 0 {
			c.cpu.halted = true // HALTCNT in the high byte
		}
	case 0x120 ..= 0x15F: c.io_misc[(a - 0x120) / 2] = v
	}
}

// --- keypad -----------------------------------------------------------------

keyinput :: proc(c: ^Console) -> u16 {
	v: u16 = 0x03FF
	p := c.pad
	if .A in p      {v &= ~u16(1 << 0)}
	if .B in p      {v &= ~u16(1 << 1)}
	if .Select in p {v &= ~u16(1 << 2)}
	if .Start in p  {v &= ~u16(1 << 3)}
	if .Right in p  {v &= ~u16(1 << 4)}
	if .Left in p   {v &= ~u16(1 << 5)}
	if .Up in p     {v &= ~u16(1 << 6)}
	if .Down in p   {v &= ~u16(1 << 7)}
	if .R in p      {v &= ~u16(1 << 8)}
	if .L in p      {v &= ~u16(1 << 9)}
	return v
}

keypad_check :: proc(c: ^Console) {
	if c.keycnt & 0x4000 == 0 {
		return
	}
	pressed := ~keyinput(c) & 0x3FF
	want := c.keycnt & 0x3FF
	hit := c.keycnt & 0x8000 != 0 ? pressed & want == want : pressed & want != 0
	if hit && want != 0 {
		irq_raise(c, IRQ_KEYPAD)
	}
}

// --- timers ---------------------------------------------------------------------

@(private = "file", rodata)
PRESCALE_SHIFT := [4]uint{0, 6, 8, 10}

timers_step :: proc(c: ^Console, cycles: int) {
	overflows_prev := 0
	for i in 0 ..< 4 {
		t := &c.timers[i]
		if t.control & 0x80 == 0 {
			overflows_prev = 0
			continue
		}
		ticks: int
		if i > 0 && t.control & 0x04 != 0 {
			ticks = overflows_prev // count-up: clocked by the previous timer
		} else {
			t.acc += cycles
			shift := PRESCALE_SHIFT[t.control & 3]
			ticks = t.acc >> shift
			t.acc -= ticks << shift
		}
		overflows := 0
		for ticks > 0 {
			room := 0x10000 - int(t.counter)
			if ticks < room {
				t.counter += u16(ticks)
				break
			}
			ticks -= room
			t.counter = t.reload
			overflows += 1
			if t.control & 0x40 != 0 {
				irq_raise(c, IRQ_TIMER0 << uint(i))
			}
			if i < 2 {
				sound_timer_overflow(c, i)
			}
		}
		overflows_prev = overflows
	}
}

// --- DMA ------------------------------------------------------------------------

DMA_IMMEDIATE :: 0
DMA_VBLANK    :: 1
DMA_HBLANK    :: 2
DMA_SPECIAL   :: 3

@(private = "file", rodata)
SRC_MASK := [4]u32{0x07FF_FFFF, 0x0FFF_FFFF, 0x0FFF_FFFF, 0x0FFF_FFFF}

@(private = "file", rodata)
DST_MASK := [4]u32{0x07FF_FFFF, 0x07FF_FFFF, 0x07FF_FFFF, 0x0FFF_FFFF}

@(private = "file")
dma_write16 :: proc(c: ^Console, a: u32, v: u16) {
	n := int(a - 0xB0) / 12
	d := &c.dma[n]
	switch (a - 0xB0) % 12 {
	case 0: d.src = (d.src & 0xFFFF_0000) | u32(v)
	case 2: d.src = (d.src & 0x0000_FFFF) | u32(v) << 16
	case 4: d.dst = (d.dst & 0xFFFF_0000) | u32(v)
	case 6: d.dst = (d.dst & 0x0000_FFFF) | u32(v) << 16
	case 8: d.count = v
	case 10:
		was := d.control & 0x8000 != 0
		d.control = v
		if !was && v & 0x8000 != 0 {
			d.cur_src = d.src & SRC_MASK[n]
			d.cur_dst = d.dst & DST_MASK[n]
			dma_reload_count(d, n)
			if (v >> 12) & 3 == DMA_IMMEDIATE {
				dma_run(c, n)
			}
		}
	}
}

@(private = "file")
dma_reload_count :: proc(d: ^Dma, n: int) {
	max: u32 = n == 3 ? 0x10000 : 0x4000
	d.cur_count = u32(d.count) & (max - 1)
	if d.cur_count == 0 {
		d.cur_count = max
	}
}

// Starts every enabled channel waiting on `timing`.
dma_trigger :: proc(c: ^Console, timing: u16) {
	for i in 0 ..< 4 {
		d := &c.dma[i]
		if d.control & 0x8000 != 0 && (d.control >> 12) & 3 == timing {
			if timing == DMA_SPECIAL && (i == 0 || i == 3) {
				continue // video capture (DMA3) is not emulated
			}
			dma_run(c, i)
		}
	}
}

// Sound FIFO request: DMA1/2 in special mode pointed at that FIFO.
dma_fifo_request :: proc(c: ^Console, fifo: int) {
	target := u32(0x0400_00A0) + u32(fifo) * 4
	for i in 1 ..= 2 {
		d := &c.dma[i]
		if d.control & 0x8000 != 0 && (d.control >> 12) & 3 == DMA_SPECIAL && d.dst & ~u32(3) == target {
			dma_run(c, i)
		}
	}
}

@(private = "file")
dma_run :: proc(c: ^Console, n: int) {
	d := &c.dma[n]
	ctl := d.control
	fifo := (ctl >> 12) & 3 == DMA_SPECIAL && (n == 1 || n == 2)
	wide := ctl & 0x0400 != 0 || fifo
	size := u32(wide ? 4 : 2)
	count := fifo ? 4 : d.cur_count
	dst_mode := fifo ? 2 : (ctl >> 5) & 3
	src_mode := (ctl >> 7) & 3

	// The EEPROM's size is decided by the length of the first transfer.
	if n == 3 && c.save.kind == .Eeprom && d.cur_dst >> 24 == 0x0D {
		eeprom_detect(&c.save, int(count))
	}

	saved_cycles := c.cpu.cycles
	for _ in 0 ..< count {
		if wide {
			write32(c, d.cur_dst, read32(c, d.cur_src))
		} else {
			write16(c, d.cur_dst, read16(c, d.cur_src))
		}
		switch src_mode {
		case 0: d.cur_src += size
		case 1: d.cur_src -= size
		}
		switch dst_mode {
		case 0, 3: d.cur_dst += size
		case 1: d.cur_dst -= size
		}
	}
	c.dma_cycles += c.cpu.cycles - saved_cycles + int(count) * 2 + 2
	c.cpu.cycles = saved_cycles

	if ctl & 0x4000 != 0 {
		irq_raise(c, IRQ_DMA0 << uint(n))
	}
	if ctl & 0x0200 != 0 && (ctl >> 12) & 3 != DMA_IMMEDIATE {
		dma_reload_count(d, n)
		if dst_mode == 3 {
			d.cur_dst = d.dst & DST_MASK[n]
		}
	} else {
		d.control &= 0x7FFF
	}
}
