package psx

// PS-X EXE executables (homebrew, test programs, or a game's boot file).

EXE_HEADER_SIZE :: 0x800

@(private = "file")
rd32 :: #force_inline proc(b: []u8, off: int) -> u32 {
	return u32(b[off]) | u32(b[off + 1]) << 8 | u32(b[off + 2]) << 16 | u32(b[off + 3]) << 24
}

exe_valid :: proc(exe: []u8) -> bool {
	if len(exe) < EXE_HEADER_SIZE || string(exe[:8]) != "PS-X EXE" {
		return false
	}
	size := int(rd32(exe, 0x1C))
	return size >= 0 && EXE_HEADER_SIZE + size <= len(exe) + 0x800 // some files trim padding
}

// Copies the program into RAM and points the CPU at it.
exe_load :: proc(c: ^Console) {
	exe := c.exe
	if !exe_valid(exe) {
		return
	}
	pc := rd32(exe, 0x10)
	gp := rd32(exe, 0x14)
	dest := rd32(exe, 0x18)
	size := int(rd32(exe, 0x1C))
	sp_base := rd32(exe, 0x30)
	sp_off := rd32(exe, 0x34)

	body := exe[EXE_HEADER_SIZE:]
	n := min(size, len(body))
	for i in 0 ..< n {
		c.ram[(int(dest & 0x1F_FFFF) + i) & (RAM_SIZE - 1)] = body[i]
	}
	cpu := &c.cpu
	cpu.pc = pc
	cpu.next_pc = pc + 4
	cpu.branch = false
	cpu.r[28] = gp
	if sp_base != 0 {
		cpu.r[29] = sp_base + sp_off
		cpu.r[30] = sp_base + sp_off
	} else if cpu.r[29] == 0 {
		cpu.r[29] = 0x801F_FFF0
	}
}
