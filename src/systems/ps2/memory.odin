package ps2

// EE address space. Kernel segments and the user-mode mirrors the BIOS sets
// up through the TLB (0x20000000 uncached, 0x30000000 uncached-accelerated)
// all fold onto physical addresses; the TLB itself is not modelled.

RAM_SIZE     :: 32 * 1024 * 1024
BIOS_SIZE    :: 4 * 1024 * 1024
SCRATCH_SIZE :: 16 * 1024
IOP_RAM_SIZE :: 2 * 1024 * 1024

@(private = "file")
physical :: #force_inline proc(addr: u32) -> u32 {
	return addr & 0x1FFF_FFFF
}

@(private = "file")
Region :: enum u8 {
	None,
	Ram,
	Scratch,
	Bios,
	Iop_Ram,
	Io,
}

// Finds the backing slice for `addr` (with room for `size` bytes) or a
// register region.
@(private = "file")
lookup :: #force_inline proc(c: ^Console, addr: u32, size: u32) -> (Region, []u8, u32) {
	if addr >> 28 == 0x7 && addr & 0x0FFF_C000 == 0 {
		return .Scratch, c.scratch[:], addr & (SCRATCH_SIZE - 1)
	}
	p := physical(addr)
	switch {
	case p < 0x1000_0000:
		return .Ram, c.ram, p & (RAM_SIZE - 1)
	case p >= 0x1FC0_0000:
		if len(c.bios) == 0 {return .None, nil, 0}
		return .Bios, c.bios, (p - 0x1FC0_0000) & (BIOS_SIZE - 1)
	case p >= 0x1C00_0000 && p < 0x1E00_0000:
		return .Iop_Ram, c.iop_ram[:], p & (IOP_RAM_SIZE - 1)
	}
	return .Io, nil, p
}

read8 :: proc(c: ^Console, addr: u32) -> u8 {
	region, mem, off := lookup(c, addr, 1)
	if mem != nil {return mem[off]}
	if region == .Io {return u8(io_read32(c, off & ~u32(3)) >> ((off & 3) * 8))}
	return 0
}

read16 :: proc(c: ^Console, addr: u32) -> u16 {
	region, mem, off := lookup(c, addr, 2)
	off &= ~u32(1)
	if mem != nil {return u16(mem[off]) | u16(mem[off + 1]) << 8}
	if region == .Io {return u16(io_read32(c, off & ~u32(3)) >> ((off & 2) * 8))}
	return 0
}

read32 :: proc(c: ^Console, addr: u32) -> u32 {
	region, mem, off := lookup(c, addr, 4)
	off &= ~u32(3)
	if mem != nil {
		return u32(mem[off]) | u32(mem[off + 1]) << 8 | u32(mem[off + 2]) << 16 | u32(mem[off + 3]) << 24
	}
	if region == .Io {return io_read32(c, off)}
	return 0
}

read64 :: proc(c: ^Console, addr: u32) -> u64 {
	a := addr & ~u32(7)
	return u64(read32(c, a)) | u64(read32(c, a + 4)) << 32
}

read128 :: proc(c: ^Console, addr: u32) -> u128 {
	a := addr & ~u32(15)
	region, _, off := lookup(c, a, 16)
	if region == .Io {
		return io_read128(c, off)
	}
	return u128(read64(c, a)) | u128(read64(c, a + 8)) << 64
}

write8 :: proc(c: ^Console, addr: u32, v: u8) {
	region, mem, off := lookup(c, addr, 1)
	switch region {
	case .Ram, .Scratch, .Iop_Ram: mem[off] = v
	case .Io: io_write8(c, off, v)
	case .Bios, .None:
	}
}

write16 :: proc(c: ^Console, addr: u32, v: u16) {
	region, mem, off := lookup(c, addr, 2)
	off &= ~u32(1)
	switch region {
	case .Ram, .Scratch, .Iop_Ram:
		mem[off] = u8(v)
		mem[off + 1] = u8(v >> 8)
	case .Io: io_write32(c, off & ~u32(3), u32(v), 2, off & 2)
	case .Bios, .None:
	}
}

write32 :: proc(c: ^Console, addr: u32, v: u32) {
	region, mem, off := lookup(c, addr, 4)
	off &= ~u32(3)
	switch region {
	case .Ram, .Scratch, .Iop_Ram:
		mem[off] = u8(v)
		mem[off + 1] = u8(v >> 8)
		mem[off + 2] = u8(v >> 16)
		mem[off + 3] = u8(v >> 24)
	case .Io: io_write32(c, off, v, 4, 0)
	case .Bios, .None:
	}
}

write64 :: proc(c: ^Console, addr: u32, v: u64) {
	a := addr & ~u32(7)
	region, _, off := lookup(c, a, 8)
	if region == .Io {
		io_write64(c, off, v)
		return
	}
	write32(c, a, u32(v))
	write32(c, a + 4, u32(v >> 32))
}

write128 :: proc(c: ^Console, addr: u32, v: u128) {
	a := addr & ~u32(15)
	region, _, off := lookup(c, a, 16)
	if region == .Io {
		io_write128(c, off, v)
		return
	}
	write64(c, a, u64(v))
	write64(c, a + 8, u64(v >> 64))
}
