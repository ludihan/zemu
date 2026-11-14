package ps2

// Emotion Engine core: a MIPS III derived 64-bit CPU (Toshiba R5900) with
// 128-bit general purpose registers, the MMI multimedia instructions, a
// second HI/LO pair for its two multipliers, and an FPU without IEEE
// infinities or NaNs. Branches have delay slots; branch-likely forms annul
// the slot when not taken.

Ee :: struct {
	gpr:    [32]u128,
	hi, lo: u128, // upper 64 bits are HI1/LO1
	sa:     u32,  // shift amount for QFSRV, in bits
	pc:     u32,  // address of the instruction being executed
	npc:    u32,  // address of the next one (the delay slot after a branch)
	target: u32,  // where a taken branch goes once its slot has run
	jump:   bool, // a branch was taken this instruction
	annul:  bool, // a branch-likely was not taken: skip the slot
	redirect: bool, // an exception or ERET replaced npc: no delay slot
	in_delay: bool, // the current instruction is a branch delay slot
	cop0:   [32]u32,
	fpu:    Fpu,
	cycles: u64,
}

COP0_COUNT  :: 9
COP0_STATUS :: 12
COP0_CAUSE  :: 13
COP0_EPC    :: 14
COP0_PRID   :: 15

ee_reset :: proc(cpu: ^Ee, entry: u32) {
	cpu^ = {}
	cpu.pc = entry
	cpu.npc = entry + 4
	cpu.cop0[COP0_PRID] = 0x2E20
	cpu.cop0[COP0_STATUS] = 0x7000_0000 // COP0/1/2 usable, kernel mode
	fpu_reset(&cpu.fpu)
}

// --- register helpers ----------------------------------------------------------

lo64 :: #force_inline proc(v: u128) -> u64 {return u64(v)}
hi64 :: #force_inline proc(v: u128) -> u64 {return u64(v >> 64)}
make128 :: #force_inline proc(lo, hi: u64) -> u128 {return u128(lo) | u128(hi) << 64}

HIGH_MASK :: u128(0xFFFF_FFFF_FFFF_FFFF) << 64

// Writes the low doubleword, keeping the upper 64 bits (MIPS III operations
// on the EE leave them alone).
set64 :: #force_inline proc(cpu: ^Ee, r: u32, v: u64) {
	cpu.gpr[r] = (cpu.gpr[r] & HIGH_MASK) | u128(v)
}

// 32-bit results are sign-extended to 64 bits.
set32 :: #force_inline proc(cpu: ^Ee, r: u32, v: u32) {
	set64(cpu, r, u64(i64(i32(v))))
}

sx32 :: #force_inline proc(v: u32) -> u64 {return u64(i64(i32(v)))}

@(private = "file")
imm16 :: #force_inline proc(op: u32) -> u64 {return u64(i64(i16(u16(op))))}

// --- stepping ----------------------------------------------------------------

ee_step :: proc(c: ^Console) {
	cpu := &c.ee
	op := read32(c, cpu.pc)
	cpu.jump = false
	cpu.annul = false
	cpu.redirect = false
	execute(c, op)
	cpu.gpr[0] = 0
	was_jump := cpu.jump
	switch {
	case cpu.redirect:
		cpu.pc = cpu.npc
		cpu.npc = cpu.pc + 4
		was_jump = false
	case cpu.annul:
		cpu.pc = cpu.npc + 4
		cpu.npc = cpu.pc + 4
	case cpu.jump:
		cpu.pc = cpu.npc
		cpu.npc = cpu.target
	case:
		cpu.pc = cpu.npc
		cpu.npc += 4
	}
	cpu.in_delay = was_jump
	cpu.cycles += 1
	cpu.cop0[COP0_COUNT] += 1
}

@(private = "file")
take :: #force_inline proc(cpu: ^Ee, cond: bool, op: u32) {
	if cond {
		cpu.target = cpu.pc + 4 + u32(imm16(op) << 2)
		cpu.jump = true
	}
}

@(private = "file")
take_likely :: #force_inline proc(cpu: ^Ee, cond: bool, op: u32) {
	if cond {
		cpu.target = cpu.pc + 4 + u32(imm16(op) << 2)
		cpu.jump = true
	} else {
		cpu.annul = true
	}
}

@(private = "file")
jump_to :: #force_inline proc(cpu: ^Ee, target: u32) {
	cpu.target = target
	cpu.jump = true
}

// Raises an exception; with no BIOS, SYSCALL is handled by the HLE kernel.
ee_exception :: proc(c: ^Console, code: u32) {
	cpu := &c.ee
	if code == EXC_SYSCALL && c.hle_kernel {
		hle_syscall(c)
		return
	}
	cause := (cpu.cop0[COP0_CAUSE] & ~u32(0x8000_007C)) | code << 2
	epc := cpu.pc
	if cpu.in_delay {
		epc -= 4
		cause |= 0x8000_0000 // BD
	}
	if cpu.cop0[COP0_STATUS] & 0x2 == 0 {
		cpu.cop0[COP0_EPC] = epc
		cpu.cop0[COP0_CAUSE] = cause
	}
	cpu.cop0[COP0_STATUS] |= 0x2 // EXL
	vector: u32 = cpu.cop0[COP0_STATUS] & (1 << 22) != 0 ? 0xBFC0_0380 : 0x8000_0180
	cpu.annul = false
	cpu.jump = false
	cpu.npc = vector
	cpu.redirect = true
}

EXC_SYSCALL :: 8
EXC_BREAK   :: 9
EXC_RESERVED :: 10
EXC_OVERFLOW :: 12
EXC_TRAP    :: 13

// --- decoding -------------------------------------------------------------------

execute :: proc(c: ^Console, op: u32) {
	cpu := &c.ee
	rs := (op >> 21) & 31
	rt := (op >> 16) & 31
	switch op >> 26 {
	case 0x00: special(c, op)
	case 0x01: regimm(c, op)
	case 0x02: jump_to(cpu, (cpu.pc + 4) & 0xF000_0000 | (op & 0x03FF_FFFF) << 2)
	case 0x03:
		set64(cpu, 31, u64(cpu.pc + 8))
		jump_to(cpu, (cpu.pc + 4) & 0xF000_0000 | (op & 0x03FF_FFFF) << 2)
	case 0x04: take(cpu, lo64(cpu.gpr[rs]) == lo64(cpu.gpr[rt]), op)
	case 0x05: take(cpu, lo64(cpu.gpr[rs]) != lo64(cpu.gpr[rt]), op)
	case 0x06: take(cpu, i64(lo64(cpu.gpr[rs])) <= 0, op)
	case 0x07: take(cpu, i64(lo64(cpu.gpr[rs])) > 0, op)
	case 0x08: // ADDI
		a := i32(u32(lo64(cpu.gpr[rs])))
		b := i32(i16(u16(op)))
		r := a + b
		if (a >= 0) == (b >= 0) && (r >= 0) != (a >= 0) {
			ee_exception(c, EXC_OVERFLOW)
			return
		}
		set32(cpu, rt, u32(r))
	case 0x09: set32(cpu, rt, u32(lo64(cpu.gpr[rs])) + u32(imm16(op)))
	case 0x0A: set64(cpu, rt, i64(lo64(cpu.gpr[rs])) < i64(imm16(op)) ? 1 : 0)
	case 0x0B: set64(cpu, rt, lo64(cpu.gpr[rs]) < imm16(op) ? 1 : 0)
	case 0x0C: set64(cpu, rt, lo64(cpu.gpr[rs]) & u64(op & 0xFFFF))
	case 0x0D: set64(cpu, rt, lo64(cpu.gpr[rs]) | u64(op & 0xFFFF))
	case 0x0E: set64(cpu, rt, lo64(cpu.gpr[rs]) ~ u64(op & 0xFFFF))
	case 0x0F: set32(cpu, rt, (op & 0xFFFF) << 16)
	case 0x10: cop0(c, op)
	case 0x11: cop1(c, op)
	case 0x12: cop2(c, op)
	case 0x14: take_likely(cpu, lo64(cpu.gpr[rs]) == lo64(cpu.gpr[rt]), op)
	case 0x15: take_likely(cpu, lo64(cpu.gpr[rs]) != lo64(cpu.gpr[rt]), op)
	case 0x16: take_likely(cpu, i64(lo64(cpu.gpr[rs])) <= 0, op)
	case 0x17: take_likely(cpu, i64(lo64(cpu.gpr[rs])) > 0, op)
	case 0x18: // DADDI
		a := i64(lo64(cpu.gpr[rs]))
		b := i64(imm16(op))
		r := a + b
		if (a >= 0) == (b >= 0) && (r >= 0) != (a >= 0) {
			ee_exception(c, EXC_OVERFLOW)
			return
		}
		set64(cpu, rt, u64(r))
	case 0x19: set64(cpu, rt, lo64(cpu.gpr[rs]) + imm16(op))
	case 0x1A: load_left_right(c, op, true, true)   // LDL
	case 0x1B: load_left_right(c, op, true, false)  // LDR
	case 0x1C: mmi(c, op)
	case 0x1E: // LQ: the address is forced to 16-byte alignment
		addr := (u32(lo64(cpu.gpr[rs])) + u32(imm16(op))) & ~u32(15)
		cpu.gpr[rt] = read128(c, addr)
	case 0x1F:
		addr := (u32(lo64(cpu.gpr[rs])) + u32(imm16(op))) & ~u32(15)
		write128(c, addr, cpu.gpr[rt])
	case 0x20 ..= 0x27, 0x37:
		addr := u32(lo64(cpu.gpr[rs])) + u32(imm16(op))
		switch op >> 26 {
		case 0x20: set64(cpu, rt, u64(i64(i8(read8(c, addr)))))
		case 0x21: set64(cpu, rt, u64(i64(i16(read16(c, addr)))))
		case 0x22: load_word_lr(c, op, addr, true)
		case 0x23: set32(cpu, rt, read32(c, addr))
		case 0x24: set64(cpu, rt, u64(read8(c, addr)))
		case 0x25: set64(cpu, rt, u64(read16(c, addr)))
		case 0x26: load_word_lr(c, op, addr, false)
		case 0x27: set64(cpu, rt, u64(read32(c, addr)))
		case 0x37: set64(cpu, rt, read64(c, addr))
		}
	case 0x28 ..= 0x2E, 0x3F:
		addr := u32(lo64(cpu.gpr[rs])) + u32(imm16(op))
		v := lo64(cpu.gpr[rt])
		switch op >> 26 {
		case 0x28: write8(c, addr, u8(v))
		case 0x29: write16(c, addr, u16(v))
		case 0x2A: store_word_lr(c, addr, u32(v), true)
		case 0x2B: write32(c, addr, u32(v))
		case 0x2C: store_left_right(c, op, true)  // SDL
		case 0x2D: store_left_right(c, op, false) // SDR
		case 0x2E: store_word_lr(c, addr, u32(v), false)
		case 0x3F: write64(c, addr, v)
		}
	case 0x2F, 0x33: // CACHE, PREF: no effect here
	case 0x31: // LWC1
		addr := u32(lo64(cpu.gpr[rs])) + u32(imm16(op))
		cpu.fpu.r[rt] = read32(c, addr)
	case 0x39: // SWC1
		addr := u32(lo64(cpu.gpr[rs])) + u32(imm16(op))
		write32(c, addr, cpu.fpu.r[rt])
	case 0x36: // LQC2
		addr := (u32(lo64(cpu.gpr[rs])) + u32(imm16(op))) & ~u32(15)
		c.vu0.vf[rt] = read128(c, addr)
	case 0x3E: // SQC2
		addr := (u32(lo64(cpu.gpr[rs])) + u32(imm16(op))) & ~u32(15)
		write128(c, addr, c.vu0.vf[rt])
	case:
		ee_exception(c, EXC_RESERVED)
	}
}

@(private = "file")
special :: proc(c: ^Console, op: u32) {
	cpu := &c.ee
	rs := (op >> 21) & 31
	rt := (op >> 16) & 31
	rd := (op >> 11) & 31
	sa := (op >> 6) & 31
	a := lo64(cpu.gpr[rs])
	b := lo64(cpu.gpr[rt])
	switch op & 0x3F {
	case 0x00: set32(cpu, rd, u32(b) << sa)
	case 0x02: set32(cpu, rd, u32(b) >> sa)
	case 0x03: set32(cpu, rd, u32(i32(u32(b)) >> sa))
	case 0x04: set32(cpu, rd, u32(b) << (a & 31))
	case 0x06: set32(cpu, rd, u32(b) >> (a & 31))
	case 0x07: set32(cpu, rd, u32(i32(u32(b)) >> (a & 31)))
	case 0x08: jump_to(cpu, u32(a))
	case 0x09:
		set64(cpu, rd, u64(cpu.pc + 8))
		jump_to(cpu, u32(a))
	case 0x0A: if b == 0 {set64(cpu, rd, a)} // MOVZ
	case 0x0B: if b != 0 {set64(cpu, rd, a)} // MOVN
	case 0x0C: ee_exception(c, EXC_SYSCALL)
	case 0x0D: ee_exception(c, EXC_BREAK)
	case 0x0F: // SYNC
	case 0x10: set64(cpu, rd, lo64(cpu.hi))
	case 0x11: cpu.hi = make128(a, hi64(cpu.hi))
	case 0x12: set64(cpu, rd, lo64(cpu.lo))
	case 0x13: cpu.lo = make128(a, hi64(cpu.lo))
	case 0x14: set64(cpu, rd, b << (a & 63))
	case 0x16: set64(cpu, rd, b >> (a & 63))
	case 0x17: set64(cpu, rd, u64(i64(b) >> (a & 63)))
	case 0x18: // MULT: the EE also writes LO to rd
		r := i64(i32(u32(a))) * i64(i32(u32(b)))
		cpu.lo = make128(sx32(u32(r)), hi64(cpu.lo))
		cpu.hi = make128(sx32(u32(r >> 32)), hi64(cpu.hi))
		set64(cpu, rd, lo64(cpu.lo))
	case 0x19:
		r := u64(u32(a)) * u64(u32(b))
		cpu.lo = make128(sx32(u32(r)), hi64(cpu.lo))
		cpu.hi = make128(sx32(u32(r >> 32)), hi64(cpu.hi))
		set64(cpu, rd, lo64(cpu.lo))
	case 0x1A:
		q, r := div32(i32(u32(a)), i32(u32(b)))
		cpu.lo = make128(sx32(u32(q)), hi64(cpu.lo))
		cpu.hi = make128(sx32(u32(r)), hi64(cpu.hi))
	case 0x1B:
		q, r := divu32(u32(a), u32(b))
		cpu.lo = make128(sx32(q), hi64(cpu.lo))
		cpu.hi = make128(sx32(r), hi64(cpu.hi))
	case 0x1C: // DMULT (not on the EE, but harmless and used by some compilers)
		r := i128(i64(a)) * i128(i64(b))
		cpu.lo = make128(u64(r), hi64(cpu.lo))
		cpu.hi = make128(u64(r >> 64), hi64(cpu.hi))
	case 0x1D:
		r := u128(a) * u128(b)
		cpu.lo = make128(u64(r), hi64(cpu.lo))
		cpu.hi = make128(u64(r >> 64), hi64(cpu.hi))
	case 0x1E:
		if b != 0 && !(i64(a) == min(i64) && i64(b) == -1) {
			cpu.lo = make128(u64(i64(a) / i64(b)), hi64(cpu.lo))
			cpu.hi = make128(u64(i64(a) % i64(b)), hi64(cpu.hi))
		}
	case 0x1F:
		if b != 0 {
			cpu.lo = make128(a / b, hi64(cpu.lo))
			cpu.hi = make128(a % b, hi64(cpu.hi))
		}
	case 0x20:
		x, y := i32(u32(a)), i32(u32(b))
		r := x + y
		if (x >= 0) == (y >= 0) && (r >= 0) != (x >= 0) {
			ee_exception(c, EXC_OVERFLOW)
			return
		}
		set32(cpu, rd, u32(r))
	case 0x21: set32(cpu, rd, u32(a) + u32(b))
	case 0x22:
		x, y := i32(u32(a)), i32(u32(b))
		r := x - y
		if (x >= 0) != (y >= 0) && (r >= 0) != (x >= 0) {
			ee_exception(c, EXC_OVERFLOW)
			return
		}
		set32(cpu, rd, u32(r))
	case 0x23: set32(cpu, rd, u32(a) - u32(b))
	case 0x24: set64(cpu, rd, a & b)
	case 0x25: set64(cpu, rd, a | b)
	case 0x26: set64(cpu, rd, a ~ b)
	case 0x27: set64(cpu, rd, ~(a | b))
	case 0x28: set64(cpu, rd, u64(cpu.sa)) // MFSA
	case 0x29: cpu.sa = u32(a) & 0x7F       // MTSA
	case 0x2A: set64(cpu, rd, i64(a) < i64(b) ? 1 : 0)
	case 0x2B: set64(cpu, rd, a < b ? 1 : 0)
	case 0x2C:
		r := i64(a) + i64(b)
		if (i64(a) >= 0) == (i64(b) >= 0) && (r >= 0) != (i64(a) >= 0) {
			ee_exception(c, EXC_OVERFLOW)
			return
		}
		set64(cpu, rd, u64(r))
	case 0x2D: set64(cpu, rd, a + b)
	case 0x2E:
		r := i64(a) - i64(b)
		if (i64(a) >= 0) != (i64(b) >= 0) && (r >= 0) != (i64(a) >= 0) {
			ee_exception(c, EXC_OVERFLOW)
			return
		}
		set64(cpu, rd, u64(r))
	case 0x2F: set64(cpu, rd, a - b)
	case 0x30: if i64(a) >= i64(b) {ee_exception(c, EXC_TRAP)}
	case 0x31: if a >= b {ee_exception(c, EXC_TRAP)}
	case 0x32: if i64(a) < i64(b) {ee_exception(c, EXC_TRAP)}
	case 0x33: if a < b {ee_exception(c, EXC_TRAP)}
	case 0x34: if a == b {ee_exception(c, EXC_TRAP)}
	case 0x36: if a != b {ee_exception(c, EXC_TRAP)}
	case 0x38: set64(cpu, rd, b << sa)
	case 0x3A: set64(cpu, rd, b >> sa)
	case 0x3B: set64(cpu, rd, u64(i64(b) >> sa))
	case 0x3C: set64(cpu, rd, b << (sa + 32))
	case 0x3E: set64(cpu, rd, b >> (sa + 32))
	case 0x3F: set64(cpu, rd, u64(i64(b) >> (sa + 32)))
	case:
		ee_exception(c, EXC_RESERVED)
	}
}

div32 :: proc(a, b: i32) -> (q, r: i32) {
	if b == 0 {
		return a < 0 ? 1 : -1, a
	}
	if a == min(i32) && b == -1 {
		return a, 0
	}
	return a / b, a % b
}

divu32 :: proc(a, b: u32) -> (q, r: u32) {
	if b == 0 {
		return 0xFFFF_FFFF, a
	}
	return a / b, a % b
}

@(private = "file")
regimm :: proc(c: ^Console, op: u32) {
	cpu := &c.ee
	rs := (op >> 21) & 31
	a := i64(lo64(cpu.gpr[rs]))
	switch (op >> 16) & 31 {
	case 0x00: take(cpu, a < 0, op)
	case 0x01: take(cpu, a >= 0, op)
	case 0x02: take_likely(cpu, a < 0, op)
	case 0x03: take_likely(cpu, a >= 0, op)
	case 0x08: if a >= i64(imm16(op)) {ee_exception(c, EXC_TRAP)}
	case 0x09: if u64(a) >= imm16(op) {ee_exception(c, EXC_TRAP)}
	case 0x0A: if a < i64(imm16(op)) {ee_exception(c, EXC_TRAP)}
	case 0x0B: if u64(a) < imm16(op) {ee_exception(c, EXC_TRAP)}
	case 0x0C: if a == i64(imm16(op)) {ee_exception(c, EXC_TRAP)}
	case 0x0E: if a != i64(imm16(op)) {ee_exception(c, EXC_TRAP)}
	case 0x10:
		set64(cpu, 31, u64(cpu.pc + 8))
		take(cpu, a < 0, op)
	case 0x11:
		set64(cpu, 31, u64(cpu.pc + 8))
		take(cpu, a >= 0, op)
	case 0x12:
		set64(cpu, 31, u64(cpu.pc + 8))
		take_likely(cpu, a < 0, op)
	case 0x13:
		set64(cpu, 31, u64(cpu.pc + 8))
		take_likely(cpu, a >= 0, op)
	case 0x18: cpu.sa = ((u32(a) ~ u32(op)) & 0xF) * 8 // MTSAB: byte count, kept in bits
	case 0x19: cpu.sa = ((u32(a) ~ u32(op)) & 7) * 16  // MTSAH
	case:
		ee_exception(c, EXC_RESERVED)
	}
}

// --- unaligned loads and stores -----------------------------------------------

@(private = "file")
load_word_lr :: proc(c: ^Console, op: u32, addr: u32, left: bool) {
	cpu := &c.ee
	rt := (op >> 16) & 31
	shift := (addr & 3) * 8
	mem := read32(c, addr & ~u32(3))
	old := u32(lo64(cpu.gpr[rt]))
	v: u32
	if left {
		v = (old & (0x00FF_FFFF >> shift)) | (mem << (24 - shift))
	} else {
		v = (old & ~(0xFFFF_FFFF >> shift)) | (mem >> shift)
		if shift != 0 {
			// LWR with a nonzero offset keeps the upper 32 bits as they were
			set64(cpu, rt, (lo64(cpu.gpr[rt]) & 0xFFFF_FFFF_0000_0000) | u64(v))
			return
		}
	}
	set32(cpu, rt, v)
}

@(private = "file")
store_word_lr :: proc(c: ^Console, addr: u32, v: u32, left: bool) {
	shift := (addr & 3) * 8
	a := addr & ~u32(3)
	mem := read32(c, a)
	if left {
		mem = (mem & ~(0xFFFF_FFFF >> (24 - shift))) | (v >> (24 - shift))
	} else {
		mem = (mem & ~(0xFFFF_FFFF << shift)) | (v << shift)
	}
	write32(c, a, mem)
}

@(private = "file")
load_left_right :: proc(c: ^Console, op: u32, _: bool, left: bool) {
	cpu := &c.ee
	rs := (op >> 21) & 31
	rt := (op >> 16) & 31
	addr := u32(lo64(cpu.gpr[rs])) + u32(imm16(op))
	shift := u64(addr & 7) * 8
	mem := read64(c, addr & ~u32(7))
	old := lo64(cpu.gpr[rt])
	v: u64
	if left {
		v = (old & (0x00FF_FFFF_FFFF_FFFF >> shift)) | (mem << (56 - shift))
	} else {
		v = (old & ~(0xFFFF_FFFF_FFFF_FFFF >> shift)) | (mem >> shift)
	}
	set64(cpu, rt, v)
}

@(private = "file")
store_left_right :: proc(c: ^Console, op: u32, left: bool) {
	cpu := &c.ee
	rs := (op >> 21) & 31
	rt := (op >> 16) & 31
	addr := u32(lo64(cpu.gpr[rs])) + u32(imm16(op))
	v := lo64(cpu.gpr[rt])
	shift := u64(addr & 7) * 8
	a := addr & ~u32(7)
	mem := read64(c, a)
	if left {
		mem = (mem & ~(0xFFFF_FFFF_FFFF_FFFF >> (56 - shift))) | (v >> (56 - shift))
	} else {
		mem = (mem & ~(0xFFFF_FFFF_FFFF_FFFF << shift)) | (v << shift)
	}
	write64(c, a, mem)
}

// --- coprocessor 0 -------------------------------------------------------------

@(private = "file")
cop0 :: proc(c: ^Console, op: u32) {
	cpu := &c.ee
	rt := (op >> 16) & 31
	rd := (op >> 11) & 31
	switch (op >> 21) & 31 {
	case 0x00: set32(cpu, rt, cpu.cop0[rd]) // MFC0
	case 0x04: // MTC0
		cpu.cop0[rd] = u32(lo64(cpu.gpr[rt]))
	case 0x08: // BC0F/BC0T: the condition reflects DMA completion; treat as true
		switch rt {
		case 0: take(cpu, false, op)
		case 1: take(cpu, true, op)
		case 2: take_likely(cpu, false, op)
		case 3: take_likely(cpu, true, op)
		}
	case 0x10:
		switch op & 0x3F {
		case 0x18: // ERET
			st := cpu.cop0[COP0_STATUS]
			if st & 0x4 != 0 { // ERL
				cpu.cop0[COP0_STATUS] = st & ~u32(0x4)
				cpu.npc = cpu.cop0[30]
			} else {
				cpu.cop0[COP0_STATUS] = st & ~u32(0x2)
				cpu.npc = cpu.cop0[COP0_EPC]
			}
			cpu.redirect = true
		case 0x38: cpu.cop0[COP0_STATUS] |= 0x10000  // EI
		case 0x39: cpu.cop0[COP0_STATUS] &= ~u32(0x10000) // DI
		case: // TLB operations: the TLB is not modelled (direct mapping)
		}
	}
}
