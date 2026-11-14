package gba

// ARM7TDMI: ARMv4T with the ARM and Thumb instruction sets, banked registers
// for every processor mode, and a pipeline-visible PC (+8 ARM, +4 Thumb).

MODE_USR :: 0x10
MODE_FIQ :: 0x11
MODE_IRQ :: 0x12
MODE_SVC :: 0x13
MODE_ABT :: 0x17
MODE_UND :: 0x1B
MODE_SYS :: 0x1F

FLAG_N :: u32(1) << 31
FLAG_Z :: u32(1) << 30
FLAG_C :: u32(1) << 29
FLAG_V :: u32(1) << 28
FLAG_I :: u32(1) << 7
FLAG_F :: u32(1) << 6
FLAG_T :: u32(1) << 5

Bank :: enum u8 {
	Usr, // also System
	Fiq,
	Irq,
	Svc,
	Abt,
	Und,
}

Cpu :: struct {
	r:        [16]u32,
	cpsr:     u32,
	spsr:     [Bank]u32,
	bank_r13: [Bank]u32,
	bank_r14: [Bank]u32,
	fiq_r8_12: [5]u32,
	usr_r8_12: [5]u32,
	pc:       u32, // address of the next instruction
	branched: bool,
	pipe:     [2]u32, // prefetched opcodes for pc+size and pc+2*size
	flush:    bool,   // the pipeline must be refilled from pc
	halted:   bool,
	cycles:   int,
}

@(private = "file")
bank_of :: proc(mode: u32) -> Bank {
	switch mode & 0x1F {
	case MODE_FIQ: return .Fiq
	case MODE_IRQ: return .Irq
	case MODE_SVC: return .Svc
	case MODE_ABT: return .Abt
	case MODE_UND: return .Und
	}
	return .Usr
}

// Switches processor mode, swapping banked registers.
set_mode :: proc(cpu: ^Cpu, mode: u32) {
	old := bank_of(cpu.cpsr)
	new := bank_of(mode)
	cpu.cpsr = (cpu.cpsr & ~u32(0x1F)) | (mode & 0x1F)
	if old == new {
		return
	}
	cpu.bank_r13[old] = cpu.r[13]
	cpu.bank_r14[old] = cpu.r[14]
	if old == .Fiq {
		for i in 0 ..< 5 {
			cpu.fiq_r8_12[i] = cpu.r[8 + i]
			cpu.r[8 + i] = cpu.usr_r8_12[i]
		}
	}
	if new == .Fiq {
		for i in 0 ..< 5 {
			cpu.usr_r8_12[i] = cpu.r[8 + i]
			cpu.r[8 + i] = cpu.fiq_r8_12[i]
		}
	}
	cpu.r[13] = cpu.bank_r13[new]
	cpu.r[14] = cpu.bank_r14[new]
}

@(private = "file")
thumb :: #force_inline proc(cpu: ^Cpu) -> bool {
	return cpu.cpsr & FLAG_T != 0
}

// Restores CPSR from SPSR (exception return).
@(private = "file")
restore_cpsr :: proc(cpu: ^Cpu) {
	b := bank_of(cpu.cpsr)
	if b == .Usr {
		return
	}
	s := cpu.spsr[b]
	set_mode(cpu, s)
	cpu.cpsr = s
}

cpu_reset :: proc(c: ^Console) {
	cpu := &c.cpu
	cpu^ = {}
	cpu.cpsr = MODE_SVC | FLAG_I | FLAG_F
	// State after the BIOS boot sequence (it is skipped).
	set_mode(cpu, MODE_IRQ)
	cpu.r[13] = 0x0300_7FA0
	set_mode(cpu, MODE_SVC)
	cpu.r[13] = 0x0300_7FE0
	set_mode(cpu, MODE_SYS)
	cpu.r[13] = 0x0300_7F00
	cpu.cpsr = MODE_SYS
	cpu.pc = 0x0800_0000
	cpu.flush = true
}

// Enters an exception: IRQ, SWI (when not emulated), undefined.
exception :: proc(cpu: ^Cpu, mode: u32, vector: u32, return_addr: u32) {
	old := cpu.cpsr
	set_mode(cpu, mode)
	cpu.spsr[bank_of(mode)] = old
	cpu.r[14] = return_addr
	cpu.cpsr = (cpu.cpsr & ~FLAG_T) | FLAG_I
	cpu.pc = vector
	cpu.branched = true
	cpu.flush = true
}

// --- barrel shifter ----------------------------------------------------------

Shift_Kind :: enum u8 {
	Lsl,
	Lsr,
	Asr,
	Ror,
}

// Shift by an immediate amount (where 0 encodes LSR/ASR #32 and RRX).
@(private = "file")
shift_imm :: proc(cpu: ^Cpu, v: u32, kind: Shift_Kind, amount: u32) -> (u32, bool) {
	carry := cpu.cpsr & FLAG_C != 0
	switch kind {
	case .Lsl:
		if amount == 0 {return v, carry}
		return v << amount, (v >> (32 - amount)) & 1 != 0
	case .Lsr:
		if amount == 0 {return 0, v >> 31 != 0}
		return v >> amount, (v >> (amount - 1)) & 1 != 0
	case .Asr:
		if amount == 0 {
			return u32(i32(v) >> 31), v >> 31 != 0
		}
		return u32(i32(v) >> amount), (v >> (amount - 1)) & 1 != 0
	case .Ror:
		if amount == 0 { // RRX
			return (v >> 1) | (carry ? 0x8000_0000 : 0), v & 1 != 0
		}
		r := v >> amount | v << (32 - amount)
		return r, r >> 31 != 0
	}
	return v, carry
}

// Shift by a register amount (only the low byte counts; 0 leaves C alone).
@(private = "file")
shift_reg :: proc(cpu: ^Cpu, v: u32, kind: Shift_Kind, amount: u32) -> (u32, bool) {
	carry := cpu.cpsr & FLAG_C != 0
	n := amount & 0xFF
	if n == 0 {
		return v, carry
	}
	switch kind {
	case .Lsl:
		if n < 32 {return v << n, (v >> (32 - n)) & 1 != 0}
		if n == 32 {return 0, v & 1 != 0}
		return 0, false
	case .Lsr:
		if n < 32 {return v >> n, (v >> (n - 1)) & 1 != 0}
		if n == 32 {return 0, v >> 31 != 0}
		return 0, false
	case .Asr:
		if n < 32 {return u32(i32(v) >> n), (v >> (n - 1)) & 1 != 0}
		return u32(i32(v) >> 31), v >> 31 != 0
	case .Ror:
		r := n & 31
		if r == 0 {return v, v >> 31 != 0}
		res := v >> r | v << (32 - r)
		return res, res >> 31 != 0
	}
	return v, carry
}

@(private = "file")
set_nz :: #force_inline proc(cpu: ^Cpu, v: u32) {
	cpu.cpsr &= ~(FLAG_N | FLAG_Z)
	if v == 0 {cpu.cpsr |= FLAG_Z}
	cpu.cpsr |= v & FLAG_N
}

@(private = "file")
set_c :: #force_inline proc(cpu: ^Cpu, on: bool) {
	if on {cpu.cpsr |= FLAG_C} else {cpu.cpsr &= ~FLAG_C}
}

@(private = "file")
set_v :: #force_inline proc(cpu: ^Cpu, on: bool) {
	if on {cpu.cpsr |= FLAG_V} else {cpu.cpsr &= ~FLAG_V}
}

@(private = "file")
add_flags :: proc(cpu: ^Cpu, a, b: u32, carry_in: u32, set: bool) -> u32 {
	r64 := u64(a) + u64(b) + u64(carry_in)
	r := u32(r64)
	if set {
		set_nz(cpu, r)
		set_c(cpu, r64 > 0xFFFF_FFFF)
		set_v(cpu, (~(a ~ b) & (a ~ r)) >> 31 != 0)
	}
	return r
}

@(private = "file")
sub_flags :: proc(cpu: ^Cpu, a, b: u32, carry_in: u32, set: bool) -> u32 {
	// a - b - !carry, computed as a + ~b + carry
	return add_flags(cpu, a, ~b, carry_in, set)
}

@(private = "file")
condition :: proc(cpu: ^Cpu, cond: u32) -> bool {
	f := cpu.cpsr
	n := f & FLAG_N != 0
	z := f & FLAG_Z != 0
	c := f & FLAG_C != 0
	v := f & FLAG_V != 0
	switch cond & 0xF {
	case 0x0: return z
	case 0x1: return !z
	case 0x2: return c
	case 0x3: return !c
	case 0x4: return n
	case 0x5: return !n
	case 0x6: return v
	case 0x7: return !v
	case 0x8: return c && !z
	case 0x9: return !c || z
	case 0xA: return n == v
	case 0xB: return n != v
	case 0xC: return !z && n == v
	case 0xD: return z || n != v
	case 0xE: return true
	}
	return false
}

// --- step ------------------------------------------------------------------

@(private = "file")
write_reg :: #force_inline proc(cpu: ^Cpu, r: u32, v: u32) {
	if r == 15 {
		cpu.pc = v & ~u32(thumb(cpu) ? 1 : 3)
		cpu.branched = true
	} else {
		cpu.r[r] = v
	}
}

cpu_step :: proc(c: ^Console) -> int {
	cpu := &c.cpu
	cpu.cycles = 0
	if cpu.halted && irq_wake(c) {
		cpu.halted = false
	}
	if irq_pending(c) && cpu.cpsr & FLAG_I == 0 {
		cpu.halted = false
		exception(cpu, MODE_IRQ, 0x18, cpu.pc + 4)
		c.bios_latch = 0xE25E_F004
		return 3
	}
	if c.intr_wait != 0 && cpu.pc == c.intr_wait_pc && !cpu.halted {
		// IntrWait resumes here after each interrupt handler returns.
		if !intr_wait_done(c) {
			cpu.halted = true
		}
	}
	if cpu.halted {
		return halt_cycles(c)
	}
	// Three-stage pipeline: the two opcodes after the executing one have
	// already been fetched, so stores to them do not affect execution.
	cpu.branched = false
	addr := cpu.pc
	if addr < 0x4000 {
		c.bios_latch = bios_word(c, addr + 8)
	}
	if thumb(cpu) {
		if cpu.flush {
			cpu.pipe[0] = u32(fetch16(c, addr))
			cpu.pipe[1] = u32(fetch16(c, addr + 2))
			cpu.flush = false
		}
		op := cpu.pipe[0]
		cpu.pipe[0] = cpu.pipe[1]
		cpu.pipe[1] = u32(fetch16(c, addr + 4))
		cpu.r[15] = addr + 4
		execute_thumb(c, op, addr)
		if !cpu.branched {cpu.pc = addr + 2}
	} else {
		if cpu.flush {
			cpu.pipe[0] = fetch32(c, addr)
			cpu.pipe[1] = fetch32(c, addr + 4)
			cpu.flush = false
		}
		op := cpu.pipe[0]
		cpu.pipe[0] = cpu.pipe[1]
		cpu.pipe[1] = fetch32(c, addr + 8)
		cpu.r[15] = addr + 8
		if condition(cpu, op >> 28) {
			execute_arm(c, op, addr)
		}
		if !cpu.branched {cpu.pc = addr + 4}
	}
	if cpu.branched {
		cpu.flush = true
	}
	return cpu.cycles + 1
}

// --- ARM -------------------------------------------------------------------

@(private = "file")
operand2 :: proc(cpu: ^Cpu, op: u32) -> (u32, bool) {
	if op & (1 << 25) != 0 {
		imm := op & 0xFF
		rot := ((op >> 8) & 0xF) * 2
		if rot == 0 {
			return imm, cpu.cpsr & FLAG_C != 0
		}
		v := imm >> rot | imm << (32 - rot)
		return v, v >> 31 != 0
	}
	rm := op & 0xF
	kind := Shift_Kind((op >> 5) & 3)
	if op & (1 << 4) != 0 {
		// register-specified shift: PC reads 12 ahead here
		rs := cpu.r[(op >> 8) & 0xF]
		v := cpu.r[rm]
		if rm == 15 {v += 4}
		cpu.cycles += 1
		return shift_reg(cpu, v, kind, rs)
	}
	return shift_imm(cpu, cpu.r[rm], kind, (op >> 7) & 0x1F)
}

@(private = "file")
execute_arm :: proc(c: ^Console, op: u32, addr: u32) {
	cpu := &c.cpu
	switch {
	case op & 0x0FFF_FFF0 == 0x012F_FF10: // BX
		target := cpu.r[op & 0xF]
		if target & 1 != 0 {
			cpu.cpsr |= FLAG_T
			cpu.pc = target & ~u32(1)
		} else {
			cpu.cpsr &= ~FLAG_T
			cpu.pc = target & ~u32(3)
		}
		cpu.branched = true
	case op & 0x0FC0_00F0 == 0x0000_0090: // MUL / MLA
		rd := (op >> 16) & 0xF
		v := cpu.r[op & 0xF] * cpu.r[(op >> 8) & 0xF]
		if op & (1 << 21) != 0 {
			v += cpu.r[(op >> 12) & 0xF]
		}
		cpu.r[rd] = v
		if op & (1 << 20) != 0 {set_nz(cpu, v)}
		cpu.cycles += 2
	case op & 0x0F80_00F0 == 0x0080_0090: // long multiply
		rd_hi := (op >> 16) & 0xF
		rd_lo := (op >> 12) & 0xF
		a := cpu.r[op & 0xF]
		b := cpu.r[(op >> 8) & 0xF]
		r: u64
		if op & (1 << 22) != 0 {
			r = u64(i64(i32(a)) * i64(i32(b)))
		} else {
			r = u64(a) * u64(b)
		}
		if op & (1 << 21) != 0 {
			r += u64(cpu.r[rd_hi]) << 32 | u64(cpu.r[rd_lo])
		}
		cpu.r[rd_lo] = u32(r)
		cpu.r[rd_hi] = u32(r >> 32)
		if op & (1 << 20) != 0 {
			cpu.cpsr &= ~(FLAG_N | FLAG_Z)
			if r == 0 {cpu.cpsr |= FLAG_Z}
			if r >> 63 != 0 {cpu.cpsr |= FLAG_N}
		}
		cpu.cycles += 3
	case op & 0x0FB0_0FF0 == 0x0100_0090: // SWP / SWPB
		rn := cpu.r[(op >> 16) & 0xF]
		rm := cpu.r[op & 0xF]
		rd := (op >> 12) & 0xF
		if op & (1 << 22) != 0 {
			v := read8(c, rn)
			write8(c, rn, u8(rm))
			cpu.r[rd] = u32(v)
		} else {
			v := read32_rotated(c, rn)
			write32(c, rn, rm)
			cpu.r[rd] = v
		}
		cpu.cycles += 2
	case op & 0x0E00_0090 == 0x0000_0090 && op & 0x60 != 0: // halfword transfers
		halfword_transfer(c, op)
	case op & 0x0FBF_0FFF == 0x010F_0000: // MRS
		v := cpu.cpsr
		if op & (1 << 22) != 0 {
			b := bank_of(cpu.cpsr)
			v = b == .Usr ? cpu.cpsr : cpu.spsr[b]
		}
		cpu.r[(op >> 12) & 0xF] = v
	case op & 0x0DB0_F000 == 0x0120_F000: // MSR
		v: u32
		if op & (1 << 25) != 0 {
			imm := op & 0xFF
			rot := ((op >> 8) & 0xF) * 2
			v = imm >> rot | (rot != 0 ? imm << (32 - rot) : 0)
		} else {
			v = cpu.r[op & 0xF]
		}
		msr(cpu, op, v)
	case op & 0x0C00_0000 == 0x0000_0000:
		data_processing(c, op)
	case op & 0x0E00_0010 == 0x0600_0010:
		exception(cpu, MODE_UND, 0x04, addr + 4) // undefined
	case op & 0x0C00_0000 == 0x0400_0000:
		single_transfer(c, op)
	case op & 0x0E00_0000 == 0x0800_0000:
		block_transfer(c, op)
	case op & 0x0E00_0000 == 0x0A00_0000: // B / BL
		off := u32(i32(op << 8) >> 6)
		if op & (1 << 24) != 0 {
			cpu.r[14] = addr + 4
		}
		cpu.pc = cpu.r[15] + off
		cpu.branched = true
		cpu.cycles += 2
	case op & 0x0F00_0000 == 0x0F00_0000: // SWI
		software_interrupt(c, (op >> 16) & 0xFF, addr + 4)
	}
}

@(private = "file")
msr :: proc(cpu: ^Cpu, op: u32, v: u32) {
	mask: u32 = 0
	if op & (1 << 19) != 0 {mask |= 0xFF00_0000}
	if op & (1 << 16) != 0 {mask |= 0x0000_00FF}
	if op & (1 << 22) != 0 {
		b := bank_of(cpu.cpsr)
		if b != .Usr {
			cpu.spsr[b] = (cpu.spsr[b] & ~mask) | (v & mask)
		}
		return
	}
	if cpu.cpsr & 0x1F == MODE_USR {
		mask &= 0xFF00_0000 // user mode may only change the flags
	}
	nv := (cpu.cpsr & ~mask) | (v & mask)
	if mask & 0xFF != 0 {
		set_mode(cpu, nv)
	}
	cpu.cpsr = nv
}

@(private = "file")
data_processing :: proc(c: ^Console, op: u32) {
	cpu := &c.cpu
	opcode := (op >> 21) & 0xF
	s := op & (1 << 20) != 0
	rn_i := (op >> 16) & 0xF
	rd := (op >> 12) & 0xF
	op2, shifter_carry := operand2(cpu, op)
	rn := cpu.r[rn_i]
	if rn_i == 15 && op & (1 << 25) == 0 && op & (1 << 4) != 0 {
		rn += 4
	}
	carry := (cpu.cpsr >> 29) & 1
	logical_flags := s && rd != 15
	r: u32
	write := true
	switch opcode {
	case 0x0: r = rn & op2
	case 0x1: r = rn ~ op2
	case 0x2: r = sub_flags(cpu, rn, op2, 1, s && rd != 15)
	case 0x3: r = sub_flags(cpu, op2, rn, 1, s && rd != 15)
	case 0x4: r = add_flags(cpu, rn, op2, 0, s && rd != 15)
	case 0x5: r = add_flags(cpu, rn, op2, carry, s && rd != 15)
	case 0x6: r = sub_flags(cpu, rn, op2, carry, s && rd != 15)
	case 0x7: r = sub_flags(cpu, op2, rn, carry, s && rd != 15)
	case 0x8: r = rn & op2; write = false
	case 0x9: r = rn ~ op2; write = false
	case 0xA: r = sub_flags(cpu, rn, op2, 1, true); write = false
	case 0xB: r = add_flags(cpu, rn, op2, 0, true); write = false
	case 0xC: r = rn | op2
	case 0xD: r = op2
	case 0xE: r = rn & ~op2
	case 0xF: r = ~op2
	}
	is_logical := opcode <= 1 || (opcode >= 8 && opcode <= 9) || opcode >= 0xC
	if is_logical && (logical_flags || !write) {
		set_nz(cpu, r)
		set_c(cpu, shifter_carry)
	}
	if !write {
		if rd == 15 && s {
			restore_cpsr(cpu) // TSTP-style forms on old code; harmless here
		}
		return
	}
	if rd == 15 {
		if s {
			restore_cpsr(cpu)
		}
		cpu.pc = r & ~u32(cpu.cpsr & FLAG_T != 0 ? 1 : 3)
		cpu.branched = true
		cpu.cycles += 2
	} else {
		cpu.r[rd] = r
	}
}

@(private = "file")
single_transfer :: proc(c: ^Console, op: u32) {
	cpu := &c.cpu
	rn_i := (op >> 16) & 0xF
	rd := (op >> 12) & 0xF
	base := cpu.r[rn_i]
	offset: u32
	if op & (1 << 25) != 0 {
		offset, _ = shift_imm(cpu, cpu.r[op & 0xF], Shift_Kind((op >> 5) & 3), (op >> 7) & 0x1F)
	} else {
		offset = op & 0xFFF
	}
	up := op & (1 << 23) != 0
	pre := op & (1 << 24) != 0
	target := up ? base + offset : base - offset
	addr := pre ? target : base
	load := op & (1 << 20) != 0
	byte := op & (1 << 22) != 0
	writeback := !pre || op & (1 << 21) != 0
	cpu.cycles += 2
	if load {
		v := byte ? u32(read8(c, addr)) : read32_rotated(c, addr)
		if writeback && rn_i != rd {
			cpu.r[rn_i] = target
		}
		write_reg(cpu, rd, v)
	} else {
		v := cpu.r[rd]
		if rd == 15 {v += 4} // stored PC is 12 ahead
		if byte {write8(c, addr, u8(v))} else {write32(c, addr, v)}
		if writeback {
			cpu.r[rn_i] = target
		}
	}
}

@(private = "file")
halfword_transfer :: proc(c: ^Console, op: u32) {
	cpu := &c.cpu
	rn_i := (op >> 16) & 0xF
	rd := (op >> 12) & 0xF
	base := cpu.r[rn_i]
	offset := op & (1 << 22) != 0 ? ((op >> 4) & 0xF0) | (op & 0xF) : cpu.r[op & 0xF]
	up := op & (1 << 23) != 0
	pre := op & (1 << 24) != 0
	target := up ? base + offset : base - offset
	addr := pre ? target : base
	load := op & (1 << 20) != 0
	writeback := !pre || op & (1 << 21) != 0
	kind := (op >> 5) & 3
	cpu.cycles += 2
	if load {
		v: u32
		switch kind {
		case 1: // LDRH: misaligned reads rotate
			v = u32(read16(c, addr & ~u32(1)))
			if addr & 1 != 0 {v = v >> 8 | v << 24}
		case 2: // LDRSB
			v = u32(i32(i8(read8(c, addr))))
		case 3: // LDRSH: a misaligned address loads a sign-extended byte
			if addr & 1 != 0 {
				v = u32(i32(i8(read8(c, addr))))
			} else {
				v = u32(i32(i16(read16(c, addr))))
			}
		}
		if writeback && rn_i != rd {
			cpu.r[rn_i] = target
		}
		write_reg(cpu, rd, v)
	} else {
		v := cpu.r[rd]
		if rd == 15 {v += 4}
		write16(c, addr, u16(v))
		if writeback {
			cpu.r[rn_i] = target
		}
	}
}

@(private = "file")
block_transfer :: proc(c: ^Console, op: u32) {
	cpu := &c.cpu
	rn_i := (op >> 16) & 0xF
	list := op & 0xFFFF
	pre := op & (1 << 24) != 0
	up := op & (1 << 23) != 0
	user_bank := op & (1 << 22) != 0
	writeback := op & (1 << 21) != 0
	load := op & (1 << 20) != 0
	base := cpu.r[rn_i]

	count: u32 = 0
	for i in 0 ..< 16 {
		if list & (1 << uint(i)) != 0 {count += 1}
	}
	empty := list == 0
	if empty {
		list = 1 << 15 // an empty list transfers PC and moves the base by 64
		count = 16
	}
	// Transfers always go upwards in memory; compute the lowest address.
	start: u32
	if up {
		start = pre ? base + 4 : base
	} else {
		start = pre ? base - count * 4 : base - count * 4 + 4
	}
	new_base := up ? base + count * 4 : base - count * 4

	// S bit without PC in an LDM (or any STM): use the user registers.
	old_mode := cpu.cpsr & 0x1F
	switch_bank := user_bank && !(load && list & (1 << 15) != 0)
	if switch_bank {
		set_mode(cpu, MODE_USR)
	}
	addr := start
	first := true
	for i in u32(0) ..< 16 {
		if list & (1 << i) == 0 {
			continue
		}
		if load {
			v := read32(c, addr)
			if i == 15 {
				cpu.pc = v & ~u32(3)
				cpu.branched = true
				if user_bank {
					restore_cpsr(cpu)
					if cpu.cpsr & FLAG_T != 0 {cpu.pc = v & ~u32(1)}
				}
			} else {
				cpu.r[i] = v
			}
		} else {
			v := cpu.r[i]
			if i == 15 {v += 4}
			// The base register is stored as its old value only when it is
			// the first register in the list.
			if i == rn_i && !first && writeback {v = new_base}
			write32(c, addr, v)
		}
		first = false
		addr += 4
	}
	if switch_bank {
		set_mode(cpu, old_mode)
	}
	if empty {
		new_base = up ? base + 0x40 : base - 0x40
	}
	if writeback && !(load && list & (1 << rn_i) != 0) {
		cpu.r[rn_i] = new_base
	}
	cpu.cycles += int(count) + 1
}

// --- Thumb -------------------------------------------------------------------

@(private = "file")
execute_thumb :: proc(c: ^Console, op: u32, addr: u32) {
	cpu := &c.cpu
	switch op >> 13 {
	case 0: // shifts / add-sub
		if (op >> 11) & 3 == 3 {
			rd := op & 7
			rs := cpu.r[(op >> 3) & 7]
			v := op & (1 << 10) != 0 ? (op >> 6) & 7 : cpu.r[(op >> 6) & 7]
			if op & (1 << 9) != 0 {
				cpu.r[rd] = sub_flags(cpu, rs, v, 1, true)
			} else {
				cpu.r[rd] = add_flags(cpu, rs, v, 0, true)
			}
		} else {
			v, carry := shift_imm(cpu, cpu.r[(op >> 3) & 7], Shift_Kind((op >> 11) & 3), (op >> 6) & 0x1F)
			cpu.r[op & 7] = v
			set_nz(cpu, v)
			set_c(cpu, carry)
		}
	case 1: // MOV/CMP/ADD/SUB immediate
		rd := (op >> 8) & 7
		imm := op & 0xFF
		switch (op >> 11) & 3 {
		case 0:
			cpu.r[rd] = imm
			set_nz(cpu, imm)
		case 1: _ = sub_flags(cpu, cpu.r[rd], imm, 1, true)
		case 2: cpu.r[rd] = add_flags(cpu, cpu.r[rd], imm, 0, true)
		case 3: cpu.r[rd] = sub_flags(cpu, cpu.r[rd], imm, 1, true)
		}
	case 2:
		switch {
		case op >> 10 == 0x10:
			thumb_alu(c, op)
		case op >> 10 == 0x11:
			thumb_hi_reg(c, op)
		case op >> 11 == 0x09: // LDR PC-relative
			a := (cpu.r[15] & ~u32(3)) + (op & 0xFF) * 4
			cpu.r[(op >> 8) & 7] = read32(c, a)
			cpu.cycles += 2
		case: // load/store register offset
			a := cpu.r[(op >> 3) & 7] + cpu.r[(op >> 6) & 7]
			rd := op & 7
			cpu.cycles += 2
			switch (op >> 9) & 7 {
			case 0: write32(c, a, cpu.r[rd])
			case 1: write16(c, a, u16(cpu.r[rd]))
			case 2: write8(c, a, u8(cpu.r[rd]))
			case 3: cpu.r[rd] = u32(i32(i8(read8(c, a))))
			case 4: cpu.r[rd] = read32_rotated(c, a)
			case 5:
				v := u32(read16(c, a & ~u32(1)))
				if a & 1 != 0 {v = v >> 8 | v << 24}
				cpu.r[rd] = v
			case 6: cpu.r[rd] = u32(read8(c, a))
			case 7:
				if a & 1 != 0 {
					cpu.r[rd] = u32(i32(i8(read8(c, a))))
				} else {
					cpu.r[rd] = u32(i32(i16(read16(c, a))))
				}
			}
		}
	case 3: // load/store immediate offset
		rd := op & 7
		base := cpu.r[(op >> 3) & 7]
		imm := (op >> 6) & 0x1F
		cpu.cycles += 2
		switch (op >> 11) & 3 {
		case 0: write32(c, base + imm * 4, cpu.r[rd])
		case 1: cpu.r[rd] = read32_rotated(c, base + imm * 4)
		case 2: write8(c, base + imm, u8(cpu.r[rd]))
		case 3: cpu.r[rd] = u32(read8(c, base + imm))
		}
	case 4:
		cpu.cycles += 2
		if op & (1 << 12) == 0 { // halfword immediate
			rd := op & 7
			a := cpu.r[(op >> 3) & 7] + ((op >> 6) & 0x1F) * 2
			if op & (1 << 11) != 0 {
				v := u32(read16(c, a & ~u32(1)))
				if a & 1 != 0 {v = v >> 8 | v << 24}
				cpu.r[rd] = v
			} else {
				write16(c, a, u16(cpu.r[rd]))
			}
		} else { // SP-relative
			rd := (op >> 8) & 7
			a := cpu.r[13] + (op & 0xFF) * 4
			if op & (1 << 11) != 0 {
				cpu.r[rd] = read32_rotated(c, a)
			} else {
				write32(c, a, cpu.r[rd])
			}
		}
	case 5:
		if op & (1 << 12) == 0 { // ADD rd, PC/SP, imm
			rd := (op >> 8) & 7
			imm := (op & 0xFF) * 4
			if op & (1 << 11) != 0 {
				cpu.r[rd] = cpu.r[13] + imm
			} else {
				cpu.r[rd] = (cpu.r[15] & ~u32(3)) + imm
			}
		} else if (op >> 8) & 0xF == 0 { // ADD SP, #±imm
			imm := (op & 0x7F) * 4
			if op & 0x80 != 0 {cpu.r[13] -= imm} else {cpu.r[13] += imm}
		} else if (op >> 9) & 3 == 2 { // PUSH / POP
			thumb_push_pop(c, op)
		}
	case 6:
		if op & (1 << 12) == 0 { // LDMIA / STMIA
			thumb_ldm_stm(c, op)
		} else {
			cond := (op >> 8) & 0xF
			if cond == 0xF {
				software_interrupt(c, op & 0xFF, addr + 2)
			} else if condition(cpu, cond) {
				off := u32(i32(i8(u8(op))) * 2)
				cpu.pc = cpu.r[15] + off
				cpu.branched = true
				cpu.cycles += 2
			}
		}
	case 7:
		switch (op >> 11) & 3 {
		case 0: // B
			off := u32(i32(op << 21) >> 20)
			cpu.pc = cpu.r[15] + off
			cpu.branched = true
			cpu.cycles += 2
		case 2: // BL, first half
			off := u32(i32(op << 21) >> 9)
			cpu.r[14] = cpu.r[15] + off
		case 3: // BL, second half
			target := cpu.r[14] + (op & 0x7FF) * 2
			cpu.r[14] = (addr + 2) | 1
			cpu.pc = target & ~u32(1)
			cpu.branched = true
			cpu.cycles += 2
		case 1: // BLX on later cores; undefined here
		}
	}
}

@(private = "file")
thumb_alu :: proc(c: ^Console, op: u32) {
	cpu := &c.cpu
	rd := op & 7
	a := cpu.r[rd]
	b := cpu.r[(op >> 3) & 7]
	carry := (cpu.cpsr >> 29) & 1
	switch (op >> 6) & 0xF {
	case 0x0: cpu.r[rd] = a & b; set_nz(cpu, cpu.r[rd])
	case 0x1: cpu.r[rd] = a ~ b; set_nz(cpu, cpu.r[rd])
	case 0x2, 0x3, 0x4, 0x7:
		kinds := [8]Shift_Kind{.Lsl, .Lsl, .Lsl, .Lsr, .Asr, .Lsl, .Lsl, .Ror}
		v, cy := shift_reg(cpu, a, kinds[(op >> 6) & 7], b)
		cpu.r[rd] = v
		set_nz(cpu, v)
		set_c(cpu, cy)
		cpu.cycles += 1
	case 0x5: cpu.r[rd] = add_flags(cpu, a, b, carry, true)
	case 0x6: cpu.r[rd] = sub_flags(cpu, a, b, carry, true)
	case 0x8: set_nz(cpu, a & b)
	case 0x9: cpu.r[rd] = sub_flags(cpu, 0, b, 1, true)
	case 0xA: _ = sub_flags(cpu, a, b, 1, true)
	case 0xB: _ = add_flags(cpu, a, b, 0, true)
	case 0xC: cpu.r[rd] = a | b; set_nz(cpu, cpu.r[rd])
	case 0xD: cpu.r[rd] = a * b; set_nz(cpu, cpu.r[rd]); cpu.cycles += 2
	case 0xE: cpu.r[rd] = a & ~b; set_nz(cpu, cpu.r[rd])
	case 0xF: cpu.r[rd] = ~b; set_nz(cpu, cpu.r[rd])
	}
}

@(private = "file")
thumb_hi_reg :: proc(c: ^Console, op: u32) {
	cpu := &c.cpu
	rd := (op & 7) | ((op >> 4) & 8)
	rs := (op >> 3) & 0xF
	v := cpu.r[rs]
	switch (op >> 8) & 3 {
	case 0: write_reg(cpu, rd, cpu.r[rd] + v)
	case 1: _ = sub_flags(cpu, cpu.r[rd], v, 1, true)
	case 2: write_reg(cpu, rd, v)
	case 3: // BX
		if v & 1 != 0 {
			cpu.pc = v & ~u32(1)
		} else {
			cpu.cpsr &= ~FLAG_T
			cpu.pc = v & ~u32(3)
		}
		cpu.branched = true
	}
}

@(private = "file")
thumb_push_pop :: proc(c: ^Console, op: u32) {
	cpu := &c.cpu
	list := op & 0xFF
	extra := op & (1 << 8) != 0
	if op & (1 << 11) != 0 { // POP
		a := cpu.r[13]
		for i in u32(0) ..< 8 {
			if list & (1 << i) != 0 {
				cpu.r[i] = read32(c, a)
				a += 4
			}
		}
		if extra {
			cpu.pc = read32(c, a) & ~u32(1)
			cpu.branched = true
			a += 4
		}
		cpu.r[13] = a
	} else { // PUSH
		n: u32 = extra ? 1 : 0
		for i in u32(0) ..< 8 {
			if list & (1 << i) != 0 {n += 1}
		}
		a := cpu.r[13] - n * 4
		cpu.r[13] = a
		for i in u32(0) ..< 8 {
			if list & (1 << i) != 0 {
				write32(c, a, cpu.r[i])
				a += 4
			}
		}
		if extra {
			write32(c, a, cpu.r[14])
		}
	}
	cpu.cycles += 2
}

@(private = "file")
thumb_ldm_stm :: proc(c: ^Console, op: u32) {
	cpu := &c.cpu
	rb := (op >> 8) & 7
	list := op & 0xFF
	a := cpu.r[rb]
	if list == 0 {
		// empty list: transfers PC, base moves by 64
		if op & (1 << 11) != 0 {
			cpu.pc = read32(c, a) & ~u32(1)
			cpu.branched = true
		} else {
			write32(c, a, cpu.r[15] + 2)
		}
		cpu.r[rb] = a + 0x40
		return
	}
	n: u32 = 0
	for i in u32(0) ..< 8 {
		if list & (1 << i) != 0 {n += 1}
	}
	final := a + n * 4
	first := true
	for i in u32(0) ..< 8 {
		if list & (1 << i) == 0 {
			continue
		}
		if op & (1 << 11) != 0 {
			cpu.r[i] = read32(c, a)
		} else {
			v := cpu.r[i]
			if i == rb && !first {v = final}
			write32(c, a, v)
		}
		first = false
		a += 4
	}
	if !(op & (1 << 11) != 0 && list & (1 << rb) != 0) {
		cpu.r[rb] = final
	}
	cpu.cycles += int(n) + 1
}
