package nes

// Ricoh 2A03: a 6502 without decimal mode. Every bus access goes through
// `read`/`write`, which advance the PPU and APU by one CPU cycle, so timing
// falls out of the access pattern (including dummy reads) automatically.

Flag :: enum u8 {
	Carry,
	Zero,
	Irq_Disable,
	Decimal,
	Break,
	Unused,
	Overflow,
	Negative,
}
Flags :: bit_set[Flag; u8]

Irq_Source :: enum u8 {
	Apu_Frame,
	Apu_Dmc,
	Mapper,
}
Irq_Sources :: bit_set[Irq_Source; u8]

Cpu :: struct {
	a, x, y, s: u8,
	p:          Flags,
	pc:         u16,
	cycles:     u64,
	nmi_line:   bool, // last sampled NMI line level
	nmi_pending: bool,
	irq_pending: bool, // IRQ to service before the next instruction
	nmi_take:    bool, // NMI to service before the next instruction
	// Interrupt lines as they were before the most recent cycle. The 6502 polls
	// during the second-to-last cycle of an instruction, so a line that rises
	// on the final cycle is only noticed one instruction later.
	poll_nmi:    bool,
	poll_irq:    bool,
	jammed:     bool,
}

Mode :: enum u8 {
	Imp, Acc, Imm, Zp, Zpx, Zpy, Abs, Abx, Aby, Ind, Izx, Izy, Rel,
}

@(rodata)
MODES := [256]Mode {
	//      0     1     2     3     4     5     6     7     8     9     A     B     C     D     E     F
	/*0*/ .Imp, .Izx, .Imp, .Izx, .Zp,  .Zp,  .Zp,  .Zp,  .Imp, .Imm, .Acc, .Imm, .Abs, .Abs, .Abs, .Abs,
	/*1*/ .Rel, .Izy, .Imp, .Izy, .Zpx, .Zpx, .Zpx, .Zpx, .Imp, .Aby, .Imp, .Aby, .Abx, .Abx, .Abx, .Abx,
	/*2*/ .Abs, .Izx, .Imp, .Izx, .Zp,  .Zp,  .Zp,  .Zp,  .Imp, .Imm, .Acc, .Imm, .Abs, .Abs, .Abs, .Abs,
	/*3*/ .Rel, .Izy, .Imp, .Izy, .Zpx, .Zpx, .Zpx, .Zpx, .Imp, .Aby, .Imp, .Aby, .Abx, .Abx, .Abx, .Abx,
	/*4*/ .Imp, .Izx, .Imp, .Izx, .Zp,  .Zp,  .Zp,  .Zp,  .Imp, .Imm, .Acc, .Imm, .Abs, .Abs, .Abs, .Abs,
	/*5*/ .Rel, .Izy, .Imp, .Izy, .Zpx, .Zpx, .Zpx, .Zpx, .Imp, .Aby, .Imp, .Aby, .Abx, .Abx, .Abx, .Abx,
	/*6*/ .Imp, .Izx, .Imp, .Izx, .Zp,  .Zp,  .Zp,  .Zp,  .Imp, .Imm, .Acc, .Imm, .Ind, .Abs, .Abs, .Abs,
	/*7*/ .Rel, .Izy, .Imp, .Izy, .Zpx, .Zpx, .Zpx, .Zpx, .Imp, .Aby, .Imp, .Aby, .Abx, .Abx, .Abx, .Abx,
	/*8*/ .Imm, .Izx, .Imm, .Izx, .Zp,  .Zp,  .Zp,  .Zp,  .Imp, .Imm, .Imp, .Imm, .Abs, .Abs, .Abs, .Abs,
	/*9*/ .Rel, .Izy, .Imp, .Izy, .Zpx, .Zpx, .Zpy, .Zpy, .Imp, .Aby, .Imp, .Aby, .Abx, .Abx, .Aby, .Aby,
	/*A*/ .Imm, .Izx, .Imm, .Izx, .Zp,  .Zp,  .Zp,  .Zp,  .Imp, .Imm, .Imp, .Imm, .Abs, .Abs, .Abs, .Abs,
	/*B*/ .Rel, .Izy, .Imp, .Izy, .Zpx, .Zpx, .Zpy, .Zpy, .Imp, .Aby, .Imp, .Aby, .Abx, .Abx, .Aby, .Aby,
	/*C*/ .Imm, .Izx, .Imm, .Izx, .Zp,  .Zp,  .Zp,  .Zp,  .Imp, .Imm, .Imp, .Imm, .Abs, .Abs, .Abs, .Abs,
	/*D*/ .Rel, .Izy, .Imp, .Izy, .Zpx, .Zpx, .Zpx, .Zpx, .Imp, .Aby, .Imp, .Aby, .Abx, .Abx, .Abx, .Abx,
	/*E*/ .Imm, .Izx, .Imm, .Izx, .Zp,  .Zp,  .Zp,  .Zp,  .Imp, .Imm, .Imp, .Imm, .Abs, .Abs, .Abs, .Abs,
	/*F*/ .Rel, .Izy, .Imp, .Izy, .Zpx, .Zpx, .Zpx, .Zpx, .Imp, .Aby, .Imp, .Aby, .Abx, .Abx, .Abx, .Abx,
}

NMI_VECTOR   :: 0xFFFA
RESET_VECTOR :: 0xFFFC
IRQ_VECTOR   :: 0xFFFE

cpu_power_on :: proc(c: ^Console) {
	c.cpu = {}
	c.cpu.s = 0
	c.cpu.p = {.Irq_Disable, .Unused}
	reset_sequence(c)
}

// The reset button keeps A, X, Y and the flags (I is set); S drops by 3
// because the reset sequence is an interrupt whose stack writes are reads.
cpu_reset :: proc(c: ^Console) {
	c.cpu.p += {.Irq_Disable}
	c.cpu.jammed = false
	c.cpu.nmi_pending = false
	c.cpu.nmi_take = false
	c.cpu.irq_pending = false
	reset_sequence(c)
}

// Seven cycles: two dummy reads, three stack "pushes" that only read, then
// the vector.
@(private = "file")
reset_sequence :: proc(c: ^Console) {
	cpu := &c.cpu
	_ = read(c, cpu.pc)
	_ = read(c, cpu.pc)
	for _ in 0 ..< 3 {
		_ = read(c, 0x100 | u16(cpu.s))
		cpu.s -= 1
	}
	lo := u16(read(c, RESET_VECTOR))
	cpu.pc = lo | u16(read(c, RESET_VECTOR + 1)) << 8
}

// --- timed bus access ------------------------------------------------------

read :: #force_inline proc(c: ^Console, addr: u16) -> u8 {
	if c.dma.need_halt {
		process_dma(c, addr)
	}
	cycle_start(c, true)
	v := bus_read(c, addr)
	cycle_end(c, true)
	return v
}

write :: #force_inline proc(c: ^Console, addr: u16, value: u8) {
	cycle_start(c, false)
	bus_write(c, addr, value)
	cycle_end(c, false)
}

@(private = "file")
fetch :: #force_inline proc(c: ^Console) -> u8 {
	v := read(c, c.cpu.pc)
	c.cpu.pc += 1
	return v
}

@(private = "file")
push :: #force_inline proc(c: ^Console, v: u8) {
	write(c, 0x100 | u16(c.cpu.s), v)
	c.cpu.s -= 1
}

@(private = "file")
pull :: #force_inline proc(c: ^Console) -> u8 {
	c.cpu.s += 1
	return read(c, 0x100 | u16(c.cpu.s))
}

@(private = "file")
set_zn :: #force_inline proc(cpu: ^Cpu, v: u8) {
	cpu.p -= {.Zero, .Negative}
	if v == 0 {cpu.p += {.Zero}}
	if v & 0x80 != 0 {cpu.p += {.Negative}}
}

@(private = "file")
set_flag :: #force_inline proc(cpu: ^Cpu, f: Flag, on: bool) {
	if on {cpu.p += {f}} else {cpu.p -= {f}}
}

// Resolves the effective address of an operand. `write_like` forces the dummy
// read that indexed stores and read-modify-write instructions always perform.
@(private = "file")
operand_address :: proc(c: ^Console, mode: Mode, write_like: bool) -> u16 {
	cpu := &c.cpu
	#partial switch mode {
	case .Imm:
		a := cpu.pc
		cpu.pc += 1
		return a
	case .Zp:
		return u16(fetch(c))
	case .Zpx:
		base := fetch(c)
		_ = read(c, u16(base))
		return u16(base + cpu.x)
	case .Zpy:
		base := fetch(c)
		_ = read(c, u16(base))
		return u16(base + cpu.y)
	case .Abs:
		lo := u16(fetch(c))
		return lo | u16(fetch(c)) << 8
	case .Abx, .Aby:
		lo := u16(fetch(c))
		base := lo | u16(fetch(c)) << 8
		index := u16(mode == .Abx ? cpu.x : cpu.y)
		eff := base + index
		if write_like || (base & 0xFF00) != (eff & 0xFF00) {
			_ = read(c, (base & 0xFF00) | (eff & 0x00FF))
		}
		return eff
	case .Izx:
		ptr := fetch(c)
		_ = read(c, u16(ptr))
		ptr += cpu.x
		lo := u16(read(c, u16(ptr)))
		return lo | u16(read(c, u16(ptr + 1))) << 8
	case .Izy:
		ptr := fetch(c)
		lo := u16(read(c, u16(ptr)))
		base := lo | u16(read(c, u16(ptr + 1))) << 8
		eff := base + u16(cpu.y)
		if write_like || (base & 0xFF00) != (eff & 0xFF00) {
			_ = read(c, (base & 0xFF00) | (eff & 0x00FF))
		}
		return eff
	}
	return 0
}

@(private = "file")
adc :: proc(cpu: ^Cpu, v: u8) {
	carry := u16(.Carry in cpu.p ? 1 : 0)
	sum := u16(cpu.a) + u16(v) + carry
	result := u8(sum)
	set_flag(cpu, .Carry, sum > 0xFF)
	set_flag(cpu, .Overflow, (~(cpu.a ~ v) & (cpu.a ~ result) & 0x80) != 0)
	cpu.a = result
	set_zn(cpu, result)
}

@(private = "file")
compare :: proc(cpu: ^Cpu, reg, v: u8) {
	set_flag(cpu, .Carry, reg >= v)
	set_zn(cpu, reg - v)
}

@(private = "file")
asl :: proc(cpu: ^Cpu, v: u8) -> u8 {
	set_flag(cpu, .Carry, v & 0x80 != 0)
	r := v << 1
	set_zn(cpu, r)
	return r
}

@(private = "file")
lsr :: proc(cpu: ^Cpu, v: u8) -> u8 {
	set_flag(cpu, .Carry, v & 1 != 0)
	r := v >> 1
	set_zn(cpu, r)
	return r
}

@(private = "file")
rol :: proc(cpu: ^Cpu, v: u8) -> u8 {
	r := v << 1 | (.Carry in cpu.p ? 1 : 0)
	set_flag(cpu, .Carry, v & 0x80 != 0)
	set_zn(cpu, r)
	return r
}

@(private = "file")
ror :: proc(cpu: ^Cpu, v: u8) -> u8 {
	r := v >> 1 | (.Carry in cpu.p ? 0x80 : 0)
	set_flag(cpu, .Carry, v & 1 != 0)
	set_zn(cpu, r)
	return r
}

@(private = "file")
branch :: proc(c: ^Console, taken: bool) {
	offset := i8(fetch(c))
	if !taken {
		return
	}
	cpu := &c.cpu
	irq_before := cpu.poll_irq // IRQ line at the end of the opcode cycle
	_ = read(c, cpu.pc)
	target := u16(i16(cpu.pc) + i16(offset))
	if (target & 0xFF00) != (cpu.pc & 0xFF00) {
		_ = read(c, (cpu.pc & 0xFF00) | (target & 0x00FF))
	} else if cpu.poll_irq && !irq_before {
		// A taken branch that stays on its page does not poll during its last
		// cycle: an IRQ that rose during the operand fetch waits one more
		// instruction.
		cpu.poll_irq = false
	}
	cpu.pc = target
}

@(private = "file")
interrupt :: proc(c: ^Console, vector: u16, is_brk: bool) {
	cpu := &c.cpu
	if is_brk {
		_ = fetch(c) // padding byte
	} else {
		_ = read(c, cpu.pc)
		_ = read(c, cpu.pc)
	}
	push(c, u8(cpu.pc >> 8))
	push(c, u8(cpu.pc))
	// An NMI detected by now (before the flags are pushed) hijacks the
	// BRK/IRQ sequence and takes its vector instead.
	v := vector
	if c.cpu.nmi_pending && vector != NMI_VECTOR {
		v = NMI_VECTOR
		c.cpu.nmi_pending = false
	}
	flags := cpu.p + {.Unused}
	if is_brk {flags += {.Break}} else {flags -= {.Break}}
	push(c, transmute(u8)flags)
	cpu.p += {.Irq_Disable}
	lo := u16(read(c, v))
	cpu.pc = lo | u16(read(c, v + 1)) << 8
}

// Executes one instruction (or services one pending interrupt).
cpu_step :: proc(c: ^Console) {
	cpu := &c.cpu
	if cpu.jammed {
		tick(c)
		return
	}
	if cpu.nmi_take {
		cpu.nmi_take = false
		cpu.nmi_pending = false
		interrupt(c, NMI_VECTOR, false)
		cpu.irq_pending = false
		return
	}
	if cpu.irq_pending {
		interrupt(c, IRQ_VECTOR, false)
		cpu.irq_pending = false
		return
	}

	i_before := .Irq_Disable in cpu.p
	op := fetch(c)
	mode := MODES[op]
	execute(c, op, mode)

	// Interrupts are polled at the end of the instruction. CLI/SEI/PLP change
	// the I flag after the poll, so they use the old value.
	i_flag := .Irq_Disable in cpu.p
	if op == 0x58 || op == 0x78 || op == 0x28 {
		i_flag = i_before
	}
	cpu.irq_pending = !i_flag && cpu.poll_irq
	cpu.nmi_take = cpu.poll_nmi
	if op == 0x00 {
		// BRK does not poll at its end: an NMI that arrives during its last
		// cycles is taken after the handler's first instruction.
		cpu.nmi_take = false
	}
}

@(private = "file")
execute :: proc(c: ^Console, op: u8, mode: Mode) {
	cpu := &c.cpu
	switch op {
	// --- loads / ALU reads ---
	case 0xA9, 0xA5, 0xB5, 0xAD, 0xBD, 0xB9, 0xA1, 0xB1:
		cpu.a = read(c, operand_address(c, mode, false))
		set_zn(cpu, cpu.a)
	case 0xA2, 0xA6, 0xB6, 0xAE, 0xBE:
		cpu.x = read(c, operand_address(c, mode, false))
		set_zn(cpu, cpu.x)
	case 0xA0, 0xA4, 0xB4, 0xAC, 0xBC:
		cpu.y = read(c, operand_address(c, mode, false))
		set_zn(cpu, cpu.y)
	case 0xA3, 0xA7, 0xAF, 0xB3, 0xB7, 0xBF: // LAX
		v := read(c, operand_address(c, mode, false))
		cpu.a = v
		cpu.x = v
		set_zn(cpu, v)
	case 0xAB: // LXA (unstable; behaves as magic constant $FF on most consoles)
		v := read(c, operand_address(c, mode, false))
		cpu.a = (cpu.a | 0xFF) & v
		cpu.x = cpu.a
		set_zn(cpu, cpu.a)
	case 0x69, 0x65, 0x75, 0x6D, 0x7D, 0x79, 0x61, 0x71:
		adc(cpu, read(c, operand_address(c, mode, false)))
	case 0xE9, 0xE5, 0xF5, 0xED, 0xFD, 0xF9, 0xE1, 0xF1, 0xEB:
		adc(cpu, ~read(c, operand_address(c, mode, false)))
	case 0x29, 0x25, 0x35, 0x2D, 0x3D, 0x39, 0x21, 0x31:
		cpu.a &= read(c, operand_address(c, mode, false))
		set_zn(cpu, cpu.a)
	case 0x09, 0x05, 0x15, 0x0D, 0x1D, 0x19, 0x01, 0x11:
		cpu.a |= read(c, operand_address(c, mode, false))
		set_zn(cpu, cpu.a)
	case 0x49, 0x45, 0x55, 0x4D, 0x5D, 0x59, 0x41, 0x51:
		cpu.a ~= read(c, operand_address(c, mode, false))
		set_zn(cpu, cpu.a)
	case 0xC9, 0xC5, 0xD5, 0xCD, 0xDD, 0xD9, 0xC1, 0xD1:
		compare(cpu, cpu.a, read(c, operand_address(c, mode, false)))
	case 0xE0, 0xE4, 0xEC:
		compare(cpu, cpu.x, read(c, operand_address(c, mode, false)))
	case 0xC0, 0xC4, 0xCC:
		compare(cpu, cpu.y, read(c, operand_address(c, mode, false)))
	case 0x24, 0x2C:
		v := read(c, operand_address(c, mode, false))
		set_flag(cpu, .Zero, cpu.a & v == 0)
		set_flag(cpu, .Overflow, v & 0x40 != 0)
		set_flag(cpu, .Negative, v & 0x80 != 0)
	case 0x0B, 0x2B: // ANC
		cpu.a &= read(c, operand_address(c, mode, false))
		set_zn(cpu, cpu.a)
		set_flag(cpu, .Carry, cpu.a & 0x80 != 0)
	case 0x4B: // ALR
		cpu.a &= read(c, operand_address(c, mode, false))
		cpu.a = lsr(cpu, cpu.a)
	case 0x6B: // ARR
		cpu.a &= read(c, operand_address(c, mode, false))
		cpu.a = cpu.a >> 1 | (.Carry in cpu.p ? 0x80 : 0)
		set_zn(cpu, cpu.a)
		set_flag(cpu, .Carry, cpu.a & 0x40 != 0)
		set_flag(cpu, .Overflow, ((cpu.a >> 6) ~ (cpu.a >> 5)) & 1 != 0)
	case 0xCB: // AXS / SBX
		v := read(c, operand_address(c, mode, false))
		ax := cpu.a & cpu.x
		set_flag(cpu, .Carry, ax >= v)
		cpu.x = ax - v
		set_zn(cpu, cpu.x)
	case 0xBB: // LAS
		v := read(c, operand_address(c, mode, false)) & cpu.s
		cpu.a = v
		cpu.x = v
		cpu.s = v
		set_zn(cpu, v)

	// --- NOPs that still read an operand ---
	case 0x80, 0x82, 0x89, 0xC2, 0xE2, 0x04, 0x44, 0x64, 0x14, 0x34, 0x54, 0x74, 0xD4, 0xF4,
	     0x0C, 0x1C, 0x3C, 0x5C, 0x7C, 0xDC, 0xFC:
		_ = read(c, operand_address(c, mode, false))
	case 0xEA, 0x1A, 0x3A, 0x5A, 0x7A, 0xDA, 0xFA:
		_ = read(c, cpu.pc)

	// --- stores ---
	case 0x85, 0x95, 0x8D, 0x9D, 0x99, 0x81, 0x91:
		write(c, operand_address(c, mode, true), cpu.a)
	case 0x86, 0x96, 0x8E:
		write(c, operand_address(c, mode, true), cpu.x)
	case 0x84, 0x94, 0x8C:
		write(c, operand_address(c, mode, true), cpu.y)
	case 0x87, 0x97, 0x8F, 0x83: // SAX
		write(c, operand_address(c, mode, true), cpu.a & cpu.x)
	case 0x93, 0x9F, 0x9E, 0x9C, 0x9B: // SHA/SHX/SHY/TAS: unstable "AND high byte" stores
		addr := operand_address(c, mode, true)
		index := u16(op == 0x9C ? cpu.x : cpu.y)
		base := addr - index
		hi := u8(base >> 8) + 1
		v: u8
		switch op {
		case 0x93, 0x9F: v = cpu.a & cpu.x & hi
		case 0x9E:       v = cpu.x & hi
		case 0x9C:       v = cpu.y & hi
		case 0x9B:
			cpu.s = cpu.a & cpu.x
			v = cpu.s & hi
		}
		if (base & 0xFF00) != (addr & 0xFF00) {
			// On a page cross the stored value also replaces the address high byte.
			addr = u16(v) << 8 | (addr & 0x00FF)
		}
		write(c, addr, v)

	// --- read-modify-write ---
	case 0x0A: _ = read(c, cpu.pc); cpu.a = asl(cpu, cpu.a)
	case 0x4A: _ = read(c, cpu.pc); cpu.a = lsr(cpu, cpu.a)
	case 0x2A: _ = read(c, cpu.pc); cpu.a = rol(cpu, cpu.a)
	case 0x6A: _ = read(c, cpu.pc); cpu.a = ror(cpu, cpu.a)
	case 0x06, 0x16, 0x0E, 0x1E, 0x46, 0x56, 0x4E, 0x5E, 0x26, 0x36, 0x2E, 0x3E, 0x66, 0x76, 0x6E, 0x7E,
	     0xE6, 0xF6, 0xEE, 0xFE, 0xC6, 0xD6, 0xCE, 0xDE,
	     0x03, 0x07, 0x0F, 0x13, 0x17, 0x1B, 0x1F, 0x23, 0x27, 0x2F, 0x33, 0x37, 0x3B, 0x3F,
	     0x43, 0x47, 0x4F, 0x53, 0x57, 0x5B, 0x5F, 0x63, 0x67, 0x6F, 0x73, 0x77, 0x7B, 0x7F,
	     0xC3, 0xC7, 0xCF, 0xD3, 0xD7, 0xDB, 0xDF, 0xE3, 0xE7, 0xEF, 0xF3, 0xF7, 0xFB, 0xFF:
		addr := operand_address(c, mode, true)
		v := read(c, addr)
		write(c, addr, v) // dummy write of the unmodified value
		r: u8
		switch op & 0xE3 {
		case 0x02: r = asl(cpu, v)
		case 0x42: r = lsr(cpu, v)
		case 0x22: r = rol(cpu, v)
		case 0x62: r = ror(cpu, v)
		case 0xE2: r = v + 1; set_zn(cpu, r)
		case 0xC2: r = v - 1; set_zn(cpu, r)
		case 0x03: r = asl(cpu, v); cpu.a |= r; set_zn(cpu, cpu.a)            // SLO
		case 0x23: r = rol(cpu, v); cpu.a &= r; set_zn(cpu, cpu.a)            // RLA
		case 0x43: r = lsr(cpu, v); cpu.a ~= r; set_zn(cpu, cpu.a)            // SRE
		case 0x63: r = ror(cpu, v); adc(cpu, r)                               // RRA
		case 0xC3: r = v - 1; compare(cpu, cpu.a, r)                          // DCP
		case 0xE3: r = v + 1; adc(cpu, ~r)                                    // ISB
		}
		write(c, addr, r)

	// --- branches ---
	case 0x10: branch(c, .Negative not_in cpu.p)
	case 0x30: branch(c, .Negative in cpu.p)
	case 0x50: branch(c, .Overflow not_in cpu.p)
	case 0x70: branch(c, .Overflow in cpu.p)
	case 0x90: branch(c, .Carry not_in cpu.p)
	case 0xB0: branch(c, .Carry in cpu.p)
	case 0xD0: branch(c, .Zero not_in cpu.p)
	case 0xF0: branch(c, .Zero in cpu.p)

	// --- jumps and subroutines ---
	case 0x4C:
		lo := u16(fetch(c))
		cpu.pc = lo | u16(fetch(c)) << 8
	case 0x6C:
		lo := u16(fetch(c))
		ptr := lo | u16(fetch(c)) << 8
		// Page-wrap bug: the high byte comes from the same page.
		plo := u16(read(c, ptr))
		phi := u16(read(c, (ptr & 0xFF00) | ((ptr + 1) & 0x00FF)))
		cpu.pc = plo | phi << 8
	case 0x20:
		lo := u16(fetch(c))
		_ = read(c, 0x100 | u16(cpu.s))
		push(c, u8(cpu.pc >> 8))
		push(c, u8(cpu.pc))
		cpu.pc = lo | u16(fetch(c)) << 8
	case 0x60:
		_ = read(c, cpu.pc)
		_ = read(c, 0x100 | u16(cpu.s))
		lo := u16(pull(c))
		cpu.pc = lo | u16(pull(c)) << 8
		_ = read(c, cpu.pc)
		cpu.pc += 1
	case 0x40:
		_ = read(c, cpu.pc)
		_ = read(c, 0x100 | u16(cpu.s))
		cpu.p = transmute(Flags)pull(c) - {.Break} + {.Unused}
		lo := u16(pull(c))
		cpu.pc = lo | u16(pull(c)) << 8
	case 0x00:
		interrupt(c, IRQ_VECTOR, true)

	// --- stack ---
	case 0x48: _ = read(c, cpu.pc); push(c, cpu.a)
	case 0x08: _ = read(c, cpu.pc); push(c, transmute(u8)(cpu.p + {.Break, .Unused}))
	case 0x68:
		_ = read(c, cpu.pc)
		_ = read(c, 0x100 | u16(cpu.s))
		cpu.a = pull(c)
		set_zn(cpu, cpu.a)
	case 0x28:
		_ = read(c, cpu.pc)
		_ = read(c, 0x100 | u16(cpu.s))
		cpu.p = transmute(Flags)pull(c) - {.Break} + {.Unused}

	// --- flags ---
	case 0x18: _ = read(c, cpu.pc); cpu.p -= {.Carry}
	case 0x38: _ = read(c, cpu.pc); cpu.p += {.Carry}
	case 0x58: _ = read(c, cpu.pc); cpu.p -= {.Irq_Disable}
	case 0x78: _ = read(c, cpu.pc); cpu.p += {.Irq_Disable}
	case 0xB8: _ = read(c, cpu.pc); cpu.p -= {.Overflow}
	case 0xD8: _ = read(c, cpu.pc); cpu.p -= {.Decimal}
	case 0xF8: _ = read(c, cpu.pc); cpu.p += {.Decimal}

	// --- register transfers / inc / dec ---
	case 0xAA: _ = read(c, cpu.pc); cpu.x = cpu.a; set_zn(cpu, cpu.x)
	case 0xA8: _ = read(c, cpu.pc); cpu.y = cpu.a; set_zn(cpu, cpu.y)
	case 0x8A: _ = read(c, cpu.pc); cpu.a = cpu.x; set_zn(cpu, cpu.a)
	case 0x98: _ = read(c, cpu.pc); cpu.a = cpu.y; set_zn(cpu, cpu.a)
	case 0xBA: _ = read(c, cpu.pc); cpu.x = cpu.s; set_zn(cpu, cpu.x)
	case 0x9A: _ = read(c, cpu.pc); cpu.s = cpu.x
	case 0xE8: _ = read(c, cpu.pc); cpu.x += 1; set_zn(cpu, cpu.x)
	case 0xC8: _ = read(c, cpu.pc); cpu.y += 1; set_zn(cpu, cpu.y)
	case 0xCA: _ = read(c, cpu.pc); cpu.x -= 1; set_zn(cpu, cpu.x)
	case 0x88: _ = read(c, cpu.pc); cpu.y -= 1; set_zn(cpu, cpu.y)
	case 0x8B: // XAA (unstable)
		v := read(c, operand_address(c, mode, false))
		cpu.a = (cpu.a | 0xEE) & cpu.x & v
		set_zn(cpu, cpu.a)

	// --- JAM / KIL ---
	case 0x02, 0x12, 0x22, 0x32, 0x42, 0x52, 0x62, 0x72, 0x92, 0xB2, 0xD2, 0xF2:
		cpu.jammed = true
	}
}
