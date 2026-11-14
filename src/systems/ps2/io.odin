package ps2

// EE hardware registers (0x10000000-0x1000FFFF) and the GS privileged
// registers (0x12000000). Only what the current milestones need is
// interpreted; everything else reads back what was written.

KPUTCHAR :: 0x1000_F180 // EE SIO transmit: the kernel's debug output

GIF_FIFO  :: 0x1000_6000
D2_CHCR   :: 0x1000_A000
D2_MADR   :: 0x1000_A010
D2_QWC    :: 0x1000_A020
D2_TADR   :: 0x1000_A030
D_STAT    :: 0x1000_E010
GS_CSR    :: 0x1200_1000

io_read32 :: proc(c: ^Console, p: u32) -> u32 {
	switch {
	case p >= 0x1000_0000 && p < 0x1001_0000:
		i := (p - 0x1000_0000) >> 2
		switch p {
		case 0x1000_F130: return 0 // SIO status: transmitter always ready
		}
		return c.ee_regs[i]
	case p >= 0x1200_0000 && p < 0x1200_2000:
		if p == GS_CSR {
			return c.gs_priv[(p - 0x1200_0000) >> 2] | 0x1B << 16 // revision/ID in the upper bits
		}
		return c.gs_priv[(p - 0x1200_0000) >> 2]
	}
	return 0
}

io_read128 :: proc(c: ^Console, p: u32) -> u128 {
	return u128(io_read32(c, p)) | u128(io_read32(c, p + 4)) << 32 |
	       u128(io_read32(c, p + 8)) << 64 | u128(io_read32(c, p + 12)) << 96
}

io_write8 :: proc(c: ^Console, p: u32, v: u8) {
	if p == KPUTCHAR {
		debug_putc(c, v)
		return
	}
	shift := (p & 3) * 8
	old := io_read32(c, p & ~u32(3))
	io_write32(c, p & ~u32(3), (old & ~(u32(0xFF) << shift)) | u32(v) << shift, 1, p & 3)
}

// `size`/`offset` describe the original access width and byte position, for
// registers that care.
io_write32 :: proc(c: ^Console, p: u32, v: u32, size: u32, offset: u32) {
	switch {
	case p == KPUTCHAR:
		debug_putc(c, u8(v >> (offset * 8)))
	case p == D_STAT:
		// lower bits are write-one-to-clear, upper (masks) toggle
		r := &c.ee_regs[(D_STAT - 0x1000_0000) >> 2]
		r^ = (r^ & ~(v & 0xFFFF)) ~ (v & 0xFFFF_0000)
	case p >= 0x1000_0000 && p < 0x1001_0000:
		c.ee_regs[(p - 0x1000_0000) >> 2] = v
		if p == D2_CHCR && v & 0x100 != 0 {
			dma_gif(c)
		}
	case p >= 0x1200_0000 && p < 0x1200_2000:
		if p == GS_CSR {
			gs_priv_write(c, p, u64(v))
		} else {
			c.gs_priv[(p - 0x1200_0000) >> 2] = v
		}
	}
	_ = size
}

io_write64 :: proc(c: ^Console, p: u32, v: u64) {
	if p & ~u32(0xF) == GIF_FIFO {
		// The FIFO takes quadwords; accept them as two doubleword stores.
		if p & 8 == 0 {
			c.gif_fifo_lo = v
		} else {
			gif_write(&c.gs, u128(c.gif_fifo_lo) | u128(v) << 64)
		}
		return
	}
	if p >= 0x1200_0000 && p < 0x1200_2000 {
		gs_priv_write(c, p, v)
		return
	}
	io_write32(c, p, u32(v), 4, 0)
	io_write32(c, p + 4, u32(v >> 32), 4, 0)
}

io_write128 :: proc(c: ^Console, p: u32, v: u128) {
	if p == GIF_FIFO {
		gif_write(&c.gs, v)
		return
	}
	io_write64(c, p, u64(v))
	io_write64(c, p + 8, u64(v >> 64))
}

// GS privileged registers are 64 bits wide.
gs_priv_write :: proc(c: ^Console, p: u32, v: u64) {
	i := (p - 0x1200_0000) >> 2
	if p == GS_CSR {
		cur := u64(c.gs_priv[i])
		cur &= ~(v & 0x1F) // writing 1 clears the SIGNAL/FINISH/HSINT/VSINT/EDWINT flags
		if v & 0x200 != 0 { // RESET
			gs_reset(&c.gs)
			cur = 0
		}
		c.gs_priv[i] = u32(cur)
		return
	}
	c.gs_priv[i] = u32(v)
	c.gs_priv[i + 1] = u32(v >> 32)
}

// --- DMA channel 2 (EE -> GIF) -----------------------------------------------

dma_gif :: proc(c: ^Console) {
	r := &c.ee_regs
	chcr := &r[(D2_CHCR - 0x1000_0000) >> 2]
	madr := &r[(D2_MADR - 0x1000_0000) >> 2]
	qwc := &r[(D2_QWC - 0x1000_0000) >> 2]
	tadr := &r[(D2_TADR - 0x1000_0000) >> 2]
	send :: proc(c: ^Console, addr: u32, count: u32) {
		for i in 0 ..< min(count, 0x10000) {
			gif_write(&c.gs, read128(c, addr + i * 16))
		}
	}
	mode := (chcr^ >> 2) & 3
	if mode == 0 { // normal
		send(c, madr^, qwc^ & 0xFFFF)
		madr^ += (qwc^ & 0xFFFF) * 16
		qwc^ = 0
	} else { // source chain
		stack: [2]u32
		sp := 0
		for guard := 0; guard < 65536; guard += 1 {
			tag := read128(c, tadr^)
			count := u32(tag & 0xFFFF)
			id := u32((tag >> 28) & 7)
			addr := u32((tag >> 32) & 0x7FFF_FFF0)
			if chcr^ & 0x40 != 0 { // TTE: the tag's upper half goes to the GIF too
				gif_write(&c.gs, tag >> 64)
			}
			done := false
			switch id {
			case 0: // refe
				send(c, addr, count)
				done = true
			case 1: // cnt
				send(c, tadr^ + 16, count)
				tadr^ += 16 + count * 16
			case 2: // next
				send(c, tadr^ + 16, count)
				tadr^ = addr
			case 3, 4: // ref, refs
				send(c, addr, count)
				tadr^ += 16
			case 5: // call
				send(c, tadr^ + 16, count)
				if sp < len(stack) {
					stack[sp] = tadr^ + 16 + count * 16
					sp += 1
				}
				tadr^ = addr
			case 6: // ret
				send(c, tadr^ + 16, count)
				if sp > 0 {
					sp -= 1
					tadr^ = stack[sp]
				} else {
					done = true
				}
			case 7: // end
				send(c, tadr^ + 16, count)
				done = true
			}
			if done || ((tag >> 31) & 1 != 0 && chcr^ & 0x80 != 0) { // IRQ bit with TIE
				break
			}
		}
	}
	chcr^ &= ~u32(0x100) // STR cleared: transfer finished
	r[(D_STAT - 0x1000_0000) >> 2] |= 1 << 2
}

debug_putc :: proc(c: ^Console, ch: u8) {
	if c.debug_len < len(c.debug_out) {
		c.debug_out[c.debug_len] = ch
		c.debug_len += 1
	}
}

debug_output :: proc(c: ^Console) -> string {
	return string(c.debug_out[:c.debug_len])
}
