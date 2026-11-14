package psx

// LSI LR33300 (MIPS R3000A compatible) with the System Control coprocessor
// (COP0) and the GTE (COP2). Load and branch delay slots are emulated.

Exception :: enum u32 {
	Interrupt        = 0x00,
	Address_Load     = 0x04,
	Address_Store    = 0x05,
	Bus_Fetch        = 0x06,
	Bus_Data         = 0x07,
	Syscall          = 0x08,
	Break            = 0x09,
	Reserved         = 0x0A,
	Cop_Unusable     = 0x0B,
	Overflow         = 0x0C,
}

Cpu :: struct {
	r:          [32]u32,
	pc:         u32, // address of the instruction being executed
	next_pc:    u32,
	hi, lo:     u32,
	load_reg:   u32, // pending delayed load (0 = none)
	load_val:   u32,
	in_delay:   bool, // current instruction is in a branch delay slot
	branch:     bool, // current instruction is a taken/untaken branch
	// COP0
	sr:         u32,
	cause:      u32,
	epc:        u32,
	bad_vaddr:  u32,
	cop0:       [16]u32, // breakpoint registers etc., stored but unused
}

SR_IEC  :: 1 << 0
SR_ISC  :: 1 << 16 // isolate cache: stores go nowhere
SR_BEV  :: 1 << 22
SR_CU2  :: 1 << 30

RESET_VECTOR :: 0xBFC0_0000

cpu_reset :: proc(c: ^Console) {
	cpu := &c.cpu
	cpu^ = {}
	cpu.pc = RESET_VECTOR
	cpu.next_pc = RESET_VECTOR + 4
	cpu.sr = SR_BEV
}

@(private = "file")
set_reg :: #force_inline proc(cpu: ^Cpu, r: u32, v: u32, delayed: ^u32) {
	cpu.r[r] = v
	cpu.r[0] = 0
	if r == delayed^ {
		delayed^ = 0 // the instruction's own write wins over the delayed load
	}
}

@(private = "file")
schedule_load :: #force_inline proc(cpu: ^Cpu, r: u32, v: u32, delayed: ^u32) {
	if r == delayed^ {
		delayed^ = 0 // a second load to the same register cancels the first
	}
	cpu.load_reg = r
	cpu.load_val = v
}

raise_exception :: proc(c: ^Console, ex: Exception) {
	cpu := &c.cpu
	// push the KU/IE mode stack
	mode := cpu.sr & 0x3F
	cpu.sr = (cpu.sr & ~u32(0x3F)) | ((mode << 2) & 0x3F)
	cpu.cause = (cpu.cause & ~u32(0x7C)) | (u32(ex) << 2)
	if cpu.in_delay {
		cpu.epc = cpu.pc - 4
		cpu.cause |= 1 << 31
	} else {
		cpu.epc = cpu.pc
		cpu.cause &= ~u32(1 << 31)
	}
	handler: u32 = cpu.sr & SR_BEV != 0 ? 0xBFC0_0180 : 0x8000_0080
	cpu.pc = handler
	cpu.next_pc = handler + 4
}

// True when an enabled interrupt is pending.
@(private = "file")
interrupt_pending :: #force_inline proc(c: ^Console) -> bool {
	cpu := &c.cpu
	if c.i_stat & c.i_mask != 0 {
		cpu.cause |= 1 << 10
	} else {
		cpu.cause &= ~u32(1 << 10)
	}
	return cpu.sr & SR_IEC != 0 && (cpu.sr & cpu.cause & 0xFF00) != 0
}

// Executes one instruction. Returns the CPU cycles spent.
cpu_step :: proc(c: ^Console) -> int {
	cpu := &c.cpu

	if interrupt_pending(c) {
		// A GTE command about to execute completes before the interrupt is
		// taken; the BIOS handler skips it on return, so run it now.
		op := fetch_word(c, cpu.pc)
		if op >> 25 == 0x25 && !cpu.branch {
			gte_command(&c.gte, op)
		}
		// If the next instruction is a branch delay slot, EPC must point at the
		// branch so it is re-executed on return.
		cpu.in_delay = cpu.branch
		cpu.branch = false
		raise_exception(c, .Interrupt)
	}

	// Without a BIOS image, its entry points are emulated.
	if !c.has_bios && hle_intercept(c) {
		return 4
	}

	pc := cpu.pc
	if pc & 3 != 0 {
		cpu.bad_vaddr = pc
		raise_exception(c, .Address_Load)
		return 2
	}
	// The scratchpad, the interrupt registers and the MDEC do not answer
	// instruction fetches (other I/O ports do, with the register value).
	switch physical(pc) {
	case 0x1F80_0000 ..< 0x1F80_0400, 0x1F80_1070 ..< 0x1F80_1080, 0x1F80_1820 ..< 0x1F80_1830:
		raise_exception(c, .Bus_Fetch)
		return 2
	}
	op := fetch_word(c, pc)

	cpu.in_delay = cpu.branch
	cpu.branch = false
	cpu.pc = cpu.next_pc
	cpu.next_pc += 4

	delayed_reg := cpu.load_reg
	delayed_val := cpu.load_val
	cpu.load_reg = 0

	// Exceptions inside execute need the address of the faulting instruction.
	saved_pc := cpu.pc
	cpu.pc = pc
	exception_raised := execute(c, op, &delayed_reg, delayed_val)
	if !exception_raised {
		cpu.pc = saved_pc
	}

	if delayed_reg != 0 {
		cpu.r[delayed_reg] = delayed_val
	}
	cpu.r[0] = 0
	return 2
}

@(private = "file")
branch_to :: #force_inline proc(cpu: ^Cpu, target: u32) {
	cpu.next_pc = target
	cpu.branch = true
}

@(private = "file")
execute :: proc(c: ^Console, op: u32, delayed: ^u32, delayed_val: u32) -> (exception: bool) {
	cpu := &c.cpu
	rs := (op >> 21) & 31
	rt := (op >> 16) & 31
	rd := (op >> 11) & 31
	shamt := (op >> 6) & 31
	imm := op & 0xFFFF
	simm := u32(i32(i16(u16(imm))))
	s := cpu.r[rs]
	t := cpu.r[rt]
	// The instruction after a branch is always in the delay slot of the
	// branch, even when not taken; `branch` marks that.
	pc_next := cpu.pc + 4 // pc is the current instruction here

	switch op >> 26 {
	case 0x00: // SPECIAL
		switch op & 0x3F {
		case 0x00: set_reg(cpu, rd, t << shamt, delayed)
		case 0x02: set_reg(cpu, rd, t >> shamt, delayed)
		case 0x03: set_reg(cpu, rd, u32(i32(t) >> shamt), delayed)
		case 0x04: set_reg(cpu, rd, t << (s & 31), delayed)
		case 0x06: set_reg(cpu, rd, t >> (s & 31), delayed)
		case 0x07: set_reg(cpu, rd, u32(i32(t) >> (s & 31)), delayed)
		case 0x08: // JR
			branch_to(cpu, s)
		case 0x09: // JALR
			set_reg(cpu, rd, pc_next + 4, delayed)
			branch_to(cpu, s)
		case 0x0C:
			raise_exception(c, .Syscall)
			return true
		case 0x0D:
			raise_exception(c, .Break)
			return true
		case 0x10: set_reg(cpu, rd, cpu.hi, delayed)
		case 0x11: cpu.hi = s
		case 0x12: set_reg(cpu, rd, cpu.lo, delayed)
		case 0x13: cpu.lo = s
		case 0x18: // MULT
			r := i64(i32(s)) * i64(i32(t))
			cpu.hi = u32(u64(r) >> 32)
			cpu.lo = u32(u64(r))
		case 0x19: // MULTU
			r := u64(s) * u64(t)
			cpu.hi = u32(r >> 32)
			cpu.lo = u32(r)
		case 0x1A: // DIV
			n := i32(s)
			d := i32(t)
			switch {
			case d == 0:
				cpu.hi = u32(n)
				cpu.lo = n >= 0 ? 0xFFFF_FFFF : 1
			case u32(n) == 0x8000_0000 && d == -1:
				cpu.hi = 0
				cpu.lo = 0x8000_0000
			case:
				cpu.hi = u32(n % d)
				cpu.lo = u32(n / d)
			}
		case 0x1B: // DIVU
			if t == 0 {
				cpu.hi = s
				cpu.lo = 0xFFFF_FFFF
			} else {
				cpu.hi = s % t
				cpu.lo = s / t
			}
		case 0x20: // ADD
			r, overflow := add_overflow(s, t)
			if overflow {
				raise_exception(c, .Overflow)
				return true
			}
			set_reg(cpu, rd, r, delayed)
		case 0x21: set_reg(cpu, rd, s + t, delayed)
		case 0x22: // SUB
			r := s - t
			if ((s ~ t) & (s ~ r)) >> 31 != 0 {
				raise_exception(c, .Overflow)
				return true
			}
			set_reg(cpu, rd, r, delayed)
		case 0x23: set_reg(cpu, rd, s - t, delayed)
		case 0x24: set_reg(cpu, rd, s & t, delayed)
		case 0x25: set_reg(cpu, rd, s | t, delayed)
		case 0x26: set_reg(cpu, rd, s ~ t, delayed)
		case 0x27: set_reg(cpu, rd, ~(s | t), delayed)
		case 0x2A: set_reg(cpu, rd, i32(s) < i32(t) ? 1 : 0, delayed)
		case 0x2B: set_reg(cpu, rd, s < t ? 1 : 0, delayed)
		case:
			raise_exception(c, .Reserved)
			return true
		}
	case 0x01: // BcondZ
		// bit 16: GEZ vs LTZ; bits 17-20 == 0x10 means "and link"
		is_gez := (op >> 16) & 1 != 0
		link := (op >> 17) & 0xF == 0x8
		test := i32(s) < 0
		if is_gez {test = !test}
		if link {
			set_reg(cpu, 31, pc_next + 4, delayed)
		}
		cpu.branch = true
		if test {
			cpu.next_pc = pc_next + (simm << 2)
		}
	case 0x02: // J
		branch_to(cpu, (pc_next & 0xF000_0000) | ((op & 0x03FF_FFFF) << 2))
	case 0x03: // JAL
		set_reg(cpu, 31, pc_next + 4, delayed)
		branch_to(cpu, (pc_next & 0xF000_0000) | ((op & 0x03FF_FFFF) << 2))
	case 0x04: // BEQ
		cpu.branch = true
		if s == t {cpu.next_pc = pc_next + (simm << 2)}
	case 0x05: // BNE
		cpu.branch = true
		if s != t {cpu.next_pc = pc_next + (simm << 2)}
	case 0x06: // BLEZ
		cpu.branch = true
		if i32(s) <= 0 {cpu.next_pc = pc_next + (simm << 2)}
	case 0x07: // BGTZ
		cpu.branch = true
		if i32(s) > 0 {cpu.next_pc = pc_next + (simm << 2)}
	case 0x08: // ADDI
		r, overflow := add_overflow(s, simm)
		if overflow {
			raise_exception(c, .Overflow)
			return true
		}
		set_reg(cpu, rt, r, delayed)
	case 0x09: set_reg(cpu, rt, s + simm, delayed)
	case 0x0A: set_reg(cpu, rt, i32(s) < i32(simm) ? 1 : 0, delayed)
	case 0x0B: set_reg(cpu, rt, s < simm ? 1 : 0, delayed)
	case 0x0C: set_reg(cpu, rt, s & imm, delayed)
	case 0x0D: set_reg(cpu, rt, s | imm, delayed)
	case 0x0E: set_reg(cpu, rt, s ~ imm, delayed)
	case 0x0F: set_reg(cpu, rt, imm << 16, delayed)
	case 0x10: // COP0
		switch rs {
		case 0x00: // MFC0
			v: u32
			switch rd {
			case 8:  v = cpu.bad_vaddr
			case 12: v = cpu.sr
			case 13: v = cpu.cause
			case 14: v = cpu.epc
			case 15: v = 0x0000_0002
			case:    v = cpu.cop0[rd & 15]
			}
			schedule_load(cpu, rt, v, delayed)
		case 0x04: // MTC0
			switch rd {
			case 12: cpu.sr = t
			case 13: cpu.cause = (cpu.cause & ~u32(0x300)) | (t & 0x300)
			case:    cpu.cop0[rd & 15] = t
			}
		case 0x10: // RFE
			if op & 0x3F == 0x10 {
				mode := cpu.sr & 0x3F
				cpu.sr = (cpu.sr & ~u32(0x0F)) | (mode >> 2)
			}
		}
	case 0x12: // COP2 (GTE)
		if cpu.sr & SR_CU2 == 0 {
			cpu.cause = (cpu.cause & ~u32(0x3000_0000)) | (2 << 28)
			raise_exception(c, .Cop_Unusable)
			return true
		}
		if op & (1 << 25) != 0 {
			gte_command(&c.gte, op)
			return false
		}
		switch rs {
		case 0x00: schedule_load(cpu, rt, gte_read_data(&c.gte, rd), delayed)
		case 0x02: schedule_load(cpu, rt, gte_read_control(&c.gte, rd), delayed)
		case 0x04: gte_write_data(&c.gte, rd, t)
		case 0x06: gte_write_control(&c.gte, rd, t)
		}
	case 0x11, 0x13: // COP1 / COP3 do not exist
		cpu.cause = (cpu.cause & ~u32(0x3000_0000)) | ((op >> 26) & 3) << 28
		raise_exception(c, .Cop_Unusable)
		return true
	case 0x20: // LB
		if cpu.sr & SR_ISC != 0 {return false}
		schedule_load(cpu, rt, u32(i32(i8(load8(c, s + simm)))), delayed)
	case 0x21: // LH
		addr := s + simm
		if addr & 1 != 0 {
			cpu.bad_vaddr = addr
			raise_exception(c, .Address_Load)
			return true
		}
		if cpu.sr & SR_ISC != 0 {return false}
		schedule_load(cpu, rt, u32(i32(i16(load16(c, addr)))), delayed)
	case 0x22, 0x26: // LWL / LWR
		addr := s + simm
		aligned := load32(c, addr & ~u32(3))
		// These merge with a load still in flight to the same register.
		cur := rt == delayed^ ? delayed_val : cpu.r[rt]
		v: u32
		if op >> 26 == 0x22 {
			switch addr & 3 {
			case 0: v = (cur & 0x00FF_FFFF) | (aligned << 24)
			case 1: v = (cur & 0x0000_FFFF) | (aligned << 16)
			case 2: v = (cur & 0x0000_00FF) | (aligned << 8)
			case 3: v = aligned
			}
		} else {
			switch addr & 3 {
			case 0: v = aligned
			case 1: v = (cur & 0xFF00_0000) | (aligned >> 8)
			case 2: v = (cur & 0xFFFF_0000) | (aligned >> 16)
			case 3: v = (cur & 0xFFFF_FF00) | (aligned >> 24)
			}
		}
		if rt == delayed^ {delayed^ = 0}
		cpu.load_reg = rt
		cpu.load_val = v
	case 0x23: // LW
		addr := s + simm
		if addr & 3 != 0 {
			cpu.bad_vaddr = addr
			raise_exception(c, .Address_Load)
			return true
		}
		if cpu.sr & SR_ISC != 0 {return false}
		schedule_load(cpu, rt, load32(c, addr), delayed)
	case 0x24: // LBU
		if cpu.sr & SR_ISC != 0 {return false}
		schedule_load(cpu, rt, u32(load8(c, s + simm)), delayed)
	case 0x25: // LHU
		addr := s + simm
		if addr & 1 != 0 {
			cpu.bad_vaddr = addr
			raise_exception(c, .Address_Load)
			return true
		}
		if cpu.sr & SR_ISC != 0 {return false}
		schedule_load(cpu, rt, u32(load16(c, addr)), delayed)
	case 0x28: // SB
		if cpu.sr & SR_ISC == 0 {store8(c, s + simm, u8(t))}
	case 0x29: // SH
		addr := s + simm
		if addr & 1 != 0 {
			cpu.bad_vaddr = addr
			raise_exception(c, .Address_Store)
			return true
		}
		if cpu.sr & SR_ISC == 0 {store16(c, addr, u16(t))}
	case 0x2A, 0x2E: // SWL / SWR
		addr := s + simm
		if cpu.sr & SR_ISC != 0 {return false}
		aligned_addr := addr & ~u32(3)
		mem := load32(c, aligned_addr)
		v: u32
		if op >> 26 == 0x2A {
			switch addr & 3 {
			case 0: v = (mem & 0xFFFF_FF00) | (t >> 24)
			case 1: v = (mem & 0xFFFF_0000) | (t >> 16)
			case 2: v = (mem & 0xFF00_0000) | (t >> 8)
			case 3: v = t
			}
		} else {
			switch addr & 3 {
			case 0: v = t
			case 1: v = (mem & 0x0000_00FF) | (t << 8)
			case 2: v = (mem & 0x0000_FFFF) | (t << 16)
			case 3: v = (mem & 0x00FF_FFFF) | (t << 24)
			}
		}
		store32(c, aligned_addr, v)
	case 0x2B: // SW
		addr := s + simm
		if addr & 3 != 0 {
			cpu.bad_vaddr = addr
			raise_exception(c, .Address_Store)
			return true
		}
		if cpu.sr & SR_ISC == 0 {store32(c, addr, t)}
	case 0x32: // LWC2
		addr := s + simm
		if addr & 3 != 0 {
			cpu.bad_vaddr = addr
			raise_exception(c, .Address_Load)
			return true
		}
		gte_write_data(&c.gte, rt, load32(c, addr))
	case 0x3A: // SWC2
		addr := s + simm
		if addr & 3 != 0 {
			cpu.bad_vaddr = addr
			raise_exception(c, .Address_Store)
			return true
		}
		store32(c, addr, gte_read_data(&c.gte, rt))
	case:
		raise_exception(c, .Reserved)
		return true
	}
	return false
}

@(private = "file")
add_overflow :: #force_inline proc(a, b: u32) -> (u32, bool) {
	r := a + b
	return r, (~(a ~ b) & (a ~ r)) >> 31 != 0
}
