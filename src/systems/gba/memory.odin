package gba

// Memory map and bus. Every access goes through these procedures, which also
// charge the access's wait states to the CPU's cycle count.

BIOS_SIZE  :: 0x4000
EWRAM_SIZE :: 0x40000
IWRAM_SIZE :: 0x8000
VRAM_SIZE  :: 0x18000
MAX_ROM    :: 0x200_0000

// The replacement BIOS: only the IRQ vector holds real code, everything else
// (SWIs) is emulated directly. Its handler matches the real one's register
// usage, so games that inspect the stack or call 0x03007FFC work unchanged.
@(private = "file", rodata)
BIOS_IRQ := [?]u32 {
	0xE92D_500F, // 0x18 stmfd sp!, {r0-r3, r12, lr}
	0xE3A0_0301, // 0x1C mov   r0, #0x04000000
	0xE28F_E000, // 0x20 add   lr, pc, #0
	0xE510_F004, // 0x24 ldr   pc, [r0, #-4]
	0xE8BD_500F, // 0x28 ldmfd sp!, {r0-r3, r12, lr}
	0xE25E_F004, // 0x2C subs  pc, lr, #4
}

bios_init :: proc(c: ^Console) {
	c.bios = {}
	// Every other vector spins in place: they are never reached normally.
	for v := 0; v < 0x18; v += 4 {
		put32(c.bios[:], v, 0xEAFF_FFFE)
	}
	for word, i in BIOS_IRQ {
		put32(c.bios[:], 0x18 + i * 4, word)
	}
	// The word the real BIOS prefetches while returning from an IRQ; reads
	// of the BIOS from outside it see this value afterwards.
	put32(c.bios[:], 0x34, 0xE55E_C002)
}

bios_word :: proc(c: ^Console, addr: u32) -> u32 {
	a := int(addr & 0x3FFC)
	return get32(c.bios[:], a)
}

@(private = "file")
get32 :: #force_inline proc(m: []u8, i: int) -> u32 {
	return u32(m[i]) | u32(m[i + 1]) << 8 | u32(m[i + 2]) << 16 | u32(m[i + 3]) << 24
}

@(private = "file")
get16 :: #force_inline proc(m: []u8, i: int) -> u16 {
	return u16(m[i]) | u16(m[i + 1]) << 8
}

@(private = "file")
put32 :: #force_inline proc(m: []u8, i: int, v: u32) {
	m[i] = u8(v)
	m[i + 1] = u8(v >> 8)
	m[i + 2] = u8(v >> 16)
	m[i + 3] = u8(v >> 24)
}

@(private = "file")
put16 :: #force_inline proc(m: []u8, i: int, v: u16) {
	m[i] = u8(v)
	m[i + 1] = u8(v >> 8)
}

// VRAM is 96 KiB mirrored in 128 KiB steps; the last 32 KiB of each step
// repeats the OBJ area.
vram_index :: #force_inline proc(addr: u32) -> int {
	a := addr & 0x1FFFF
	if a >= 0x18000 {
		a -= 0x8000
	}
	return int(a)
}

// --- wait states -------------------------------------------------------------

@(private = "file", rodata)
ROM_N := [4]int{4, 3, 2, 8}

@(private = "file", rodata)
ROM_S0 := [2]int{2, 1}

@(private = "file", rodata)
ROM_S1 := [2]int{4, 1}

@(private = "file", rodata)
ROM_S2 := [2]int{8, 1}

// Recomputes the cartridge timings from WAITCNT.
update_waitstates :: proc(c: ^Console) {
	w := c.waitcnt
	c.sram_wait = ROM_N[w & 3]
	c.rom_n[0] = ROM_N[(w >> 2) & 3]
	c.rom_s[0] = ROM_S0[(w >> 4) & 1]
	c.rom_n[1] = ROM_N[(w >> 5) & 3]
	c.rom_s[1] = ROM_S1[(w >> 7) & 1]
	c.rom_n[2] = ROM_N[(w >> 8) & 3]
	c.rom_s[2] = ROM_S2[(w >> 10) & 1]
	c.prefetch = w & 0x4000 != 0
}

// Extra cycles for an access. `wide` is a 32-bit access, which takes two
// bus cycles on the 16-bit buses.
@(private = "file")
wait :: #force_inline proc(c: ^Console, addr: u32, wide: bool) -> int {
	switch addr >> 24 {
	case 0x02:
		return wide ? 5 : 2
	case 0x05, 0x06:
		return wide ? 1 : 0
	case 0x08 ..= 0x0D:
		region := int((addr >> 25) & 3) - 4
		if region < 0 || region > 2 {region = 0}
		// Sequential code fetches with the prefetch buffer enabled are
		// nearly free; approximate every other access as a mix.
		s := c.rom_s[region]
		n := c.rom_n[region]
		if c.prefetch {
			return wide ? s : 0
		}
		return wide ? n + s + 1 : n
	case 0x0E, 0x0F:
		return c.sram_wait
	}
	return 0
}

// --- reads ---------------------------------------------------------------------

read8 :: proc(c: ^Console, addr: u32) -> u8 {
	c.cpu.cycles += wait(c, addr, false)
	switch addr >> 24 {
	case 0x00:
		if addr < BIOS_SIZE {
			if c.cpu.pc < BIOS_SIZE {
				return c.bios[addr]
			}
			return u8(c.bios_latch >> ((addr & 3) * 8))
		}
		return u8(open_bus(c) >> ((addr & 3) * 8))
	case 0x02: return c.ewram[addr & (EWRAM_SIZE - 1)]
	case 0x03: return c.iwram[addr & (IWRAM_SIZE - 1)]
	case 0x04: return io_read8(c, addr)
	case 0x05: return c.palette[addr & 0x3FF]
	case 0x06: return c.vram[vram_index(addr)]
	case 0x07: return c.oam[addr & 0x3FF]
	case 0x08 ..= 0x0D:
		return u8(rom_read16(c, addr) >> ((addr & 1) * 8))
	case 0x0E, 0x0F:
		return save_read8(c, addr)
	}
	return u8(open_bus(c) >> ((addr & 3) * 8))
}

read16 :: proc(c: ^Console, address: u32) -> u16 {
	addr := address & ~u32(1)
	c.cpu.cycles += wait(c, addr, false)
	switch addr >> 24 {
	case 0x00:
		if addr < BIOS_SIZE {
			if c.cpu.pc < BIOS_SIZE {
				return get16(c.bios[:], int(addr))
			}
			return u16(c.bios_latch >> ((addr & 2) * 8))
		}
	case 0x02: return get16(c.ewram[:], int(addr & (EWRAM_SIZE - 1)))
	case 0x03: return get16(c.iwram[:], int(addr & (IWRAM_SIZE - 1)))
	case 0x04: return io_read16(c, addr)
	case 0x05: return get16(c.palette[:], int(addr & 0x3FF))
	case 0x06: return get16(c.vram[:], vram_index(addr))
	case 0x07: return get16(c.oam[:], int(addr & 0x3FF))
	case 0x08 ..= 0x0D: return rom_read16(c, addr)
	case 0x0E, 0x0F:
		v := u16(save_read8(c, addr))
		return v * 0x0101
	}
	return u16(open_bus(c) >> ((addr & 2) * 8))
}

read32 :: proc(c: ^Console, address: u32) -> u32 {
	addr := address & ~u32(3)
	c.cpu.cycles += wait(c, addr, true)
	switch addr >> 24 {
	case 0x00:
		if addr < BIOS_SIZE {
			if c.cpu.pc < BIOS_SIZE {
				return get32(c.bios[:], int(addr))
			}
			return c.bios_latch
		}
	case 0x02: return get32(c.ewram[:], int(addr & (EWRAM_SIZE - 1)))
	case 0x03: return get32(c.iwram[:], int(addr & (IWRAM_SIZE - 1)))
	case 0x04: return u32(io_read16(c, addr)) | u32(io_read16(c, addr + 2)) << 16
	case 0x05: return get32(c.palette[:], int(addr & 0x3FF))
	case 0x06: return get32(c.vram[:], vram_index(addr))
	case 0x07: return get32(c.oam[:], int(addr & 0x3FF))
	case 0x08 ..= 0x0D:
		return u32(rom_read16(c, addr)) | u32(rom_read16(c, addr + 2)) << 16
	case 0x0E, 0x0F:
		v := u32(save_read8(c, addr))
		return v * 0x0101_0101
	}
	return open_bus(c)
}

// LDR of a misaligned word rotates the aligned word.
read32_rotated :: proc(c: ^Console, addr: u32) -> u32 {
	v := read32(c, addr)
	r := (addr & 3) * 8
	if r == 0 {
		return v
	}
	return v >> r | v << (32 - r)
}

fetch16 :: #force_inline proc(c: ^Console, addr: u32) -> u16 {
	v := read16(c, addr)
	c.last_fetch = u32(v) * 0x0001_0001
	return v
}

fetch32 :: #force_inline proc(c: ^Console, addr: u32) -> u32 {
	v := read32(c, addr)
	c.last_fetch = v
	return v
}

// Unmapped reads return the last prefetched opcode.
@(private = "file")
open_bus :: proc(c: ^Console) -> u32 {
	return c.last_fetch
}

rom_read16 :: proc(c: ^Console, address: u32) -> u16 {
	addr := address & ~u32(1)
	if addr >> 8 == 0x0800_00 {
		if v, ok := rtc_read(&c.rtc, addr); ok {
			return v
		}
	}
	if c.save.kind == .Eeprom && addr >> 24 == 0x0D && (len(c.rom) <= 0x100_0000 || addr >= 0x0DFF_FF00) {
		return eeprom_read(&c.save)
	}
	off := int(addr & (MAX_ROM - 1))
	if off + 1 < len(c.rom) {
		v := get16(c.rom, off)
		if c.patches.count > 0 {
			lo := emu_patch(c, addr, u8(v))
			hi := emu_patch(c, addr + 1, u8(v >> 8))
			v = u16(lo) | u16(hi) << 8
		}
		return v
	}
	// Past the end of the cartridge the bus floats to the address.
	return u16(addr >> 1)
}

// --- writes ------------------------------------------------------------------

write8 :: proc(c: ^Console, addr: u32, v: u8) {
	c.cpu.cycles += wait(c, addr, false)
	switch addr >> 24 {
	case 0x02: c.ewram[addr & (EWRAM_SIZE - 1)] = v
	case 0x03: c.iwram[addr & (IWRAM_SIZE - 1)] = v
	case 0x04: io_write8(c, addr, v)
	case 0x05:
		// 8-bit writes to palette RAM store the byte in both halves.
		put16(c.palette[:], int(addr & 0x3FE), u16(v) * 0x0101)
	case 0x06:
		// Only background VRAM takes byte writes (duplicated); the OBJ area
		// ignores them.
		i := vram_index(addr)
		limit := c.ppu.dispcnt & 7 >= 3 ? 0x14000 : 0x10000
		if i < limit {
			put16(c.vram[:], i & ~int(1), u16(v) * 0x0101)
		}
	case 0x07: // OAM ignores byte writes
	case 0x0E, 0x0F:
		save_write8(c, addr, v)
	}
}

write16 :: proc(c: ^Console, address: u32, v: u16) {
	addr := address & ~u32(1)
	c.cpu.cycles += wait(c, addr, false)
	switch addr >> 24 {
	case 0x02: put16(c.ewram[:], int(addr & (EWRAM_SIZE - 1)), v)
	case 0x03: put16(c.iwram[:], int(addr & (IWRAM_SIZE - 1)), v)
	case 0x04: io_write16(c, addr, v)
	case 0x05: put16(c.palette[:], int(addr & 0x3FF), v)
	case 0x06: put16(c.vram[:], vram_index(addr), v)
	case 0x07: put16(c.oam[:], int(addr & 0x3FF), v)
	case 0x08 ..= 0x0D:
		if c.save.kind == .Eeprom && addr >> 24 == 0x0D {
			eeprom_write(&c.save, v)
		} else if addr >> 8 == 0x0800_00 {
			rtc_write(&c.rtc, addr, v)
		}
	case 0x0E, 0x0F:
		save_write8(c, address, u8(v >> ((address & 1) * 8)))
	}
}

write32 :: proc(c: ^Console, address: u32, v: u32) {
	addr := address & ~u32(3)
	c.cpu.cycles += wait(c, addr, true)
	switch addr >> 24 {
	case 0x02: put32(c.ewram[:], int(addr & (EWRAM_SIZE - 1)), v)
	case 0x03: put32(c.iwram[:], int(addr & (IWRAM_SIZE - 1)), v)
	case 0x04:
		io_write16(c, addr, u16(v))
		io_write16(c, addr + 2, u16(v >> 16))
	case 0x05: put32(c.palette[:], int(addr & 0x3FF), v)
	case 0x06: put32(c.vram[:], vram_index(addr), v)
	case 0x07: put32(c.oam[:], int(addr & 0x3FF), v)
	case 0x08 ..= 0x0D:
		if c.save.kind == .Eeprom && addr >> 24 == 0x0D {
			eeprom_write(&c.save, u16(v))
		} else if addr >> 8 == 0x0800_00 {
			rtc_write(&c.rtc, addr, u16(v))
			rtc_write(&c.rtc, addr + 2, u16(v >> 16))
		}
	case 0x0E, 0x0F:
		save_write8(c, address, u8(v >> ((address & 3) * 8)))
	}
}
