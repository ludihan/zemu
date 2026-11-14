package ps2

// EE hardware registers (0x10000000-0x1000FFFF) and the GS privileged
// registers (0x12000000). Only what the current milestones need is
// interpreted; everything else reads back what was written.

KPUTCHAR :: 0x1000_F180 // EE SIO transmit: the kernel's debug output

io_read32 :: proc(c: ^Console, p: u32) -> u32 {
	switch {
	case p >= 0x1000_0000 && p < 0x1001_0000:
		i := (p - 0x1000_0000) >> 2
		switch p {
		case 0x1000_F130: return 0 // SIO status: transmitter always ready
		}
		return c.ee_regs[i]
	case p >= 0x1200_0000 && p < 0x1200_2000:
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
	case p >= 0x1000_0000 && p < 0x1001_0000:
		c.ee_regs[(p - 0x1000_0000) >> 2] = v
	case p >= 0x1200_0000 && p < 0x1200_2000:
		c.gs_priv[(p - 0x1200_0000) >> 2] = v
	}
	_ = size
}

io_write64 :: proc(c: ^Console, p: u32, v: u64) {
	io_write32(c, p, u32(v), 4, 0)
	io_write32(c, p + 4, u32(v >> 32), 4, 0)
}

io_write128 :: proc(c: ^Console, p: u32, v: u128) {
	io_write64(c, p, u64(v))
	io_write64(c, p + 8, u64(v >> 64))
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
