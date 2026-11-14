package snes

// Ricoh 5A22: a WDC 65C816 core. Every bus access is charged its region's
// master-clock cost by `read`/`write`; internal cycles cost 6.

Flag :: enum u8 {
	C, // carry
	Z, // zero
	I, // IRQ disable
	D, // decimal
	X, // 8-bit index registers (break flag in emulation mode)
	M, // 8-bit accumulator
	V, // overflow
	N, // negative
}
Flags :: bit_set[Flag; u8]

Cpu :: struct {
	a, x, y:   u16,
	sp, dp:    u16,
	pc:        u16,
	pbr, dbr:  u8,
	p:         Flags,
	e:         bool, // emulation mode
	waiting:   bool, // WAI
	stopped:   bool, // STP
	nmi_pending: bool,
	irq_line:  bool,
}

VEC_COP_NATIVE :: 0xFFE4
VEC_BRK_NATIVE :: 0xFFE6
VEC_NMI_NATIVE :: 0xFFEA
VEC_IRQ_NATIVE :: 0xFFEE
VEC_COP_EMU    :: 0xFFF4
VEC_NMI_EMU    :: 0xFFFA
VEC_RESET      :: 0xFFFC
VEC_IRQ_EMU    :: 0xFFFE

cpu_reset :: proc(c: ^Console) {
	cpu := &c.cpu
	cpu.e = true
	cpu.p = {.M, .X, .I}
	cpu.sp = 0x01FF
	cpu.dp = 0
	cpu.dbr = 0
	cpu.pbr = 0
	cpu.x &= 0xFF
	cpu.y &= 0xFF
	cpu.waiting = false
	cpu.stopped = false
	cpu.nmi_pending = false
	lo := u16(bus_peek(c, VEC_RESET))
	cpu.pc = lo | u16(bus_peek(c, VEC_RESET + 1)) << 8
}

// --- bus helpers -----------------------------------------------------------

@(private = "file")
io :: #force_inline proc(c: ^Console) {
	c.pending += 6
}

@(private = "file")
fetch8 :: #force_inline proc(c: ^Console) -> u8 {
	v := read(c, u32(c.cpu.pbr) << 16 | u32(c.cpu.pc))
	c.cpu.pc += 1
	return v
}

@(private = "file")
fetch16 :: #force_inline proc(c: ^Console) -> u16 {
	lo := u16(fetch8(c))
	return lo | u16(fetch8(c)) << 8
}

@(private = "file")
fetch24 :: #force_inline proc(c: ^Console) -> u32 {
	lo := u32(fetch16(c))
	return lo | u32(fetch8(c)) << 16
}

// 16-bit read that wraps within bank 0 (direct page / stack addressing).
@(private = "file")
read16_bank0 :: proc(c: ^Console, addr: u16) -> u16 {
	lo := u16(read(c, u32(addr)))
	return lo | u16(read(c, u32(addr + 1))) << 8
}

@(private = "file")
read16 :: proc(c: ^Console, addr: u32) -> u16 {
	lo := u16(read(c, addr))
	return lo | u16(read(c, (addr + 1) & 0xFFFFFF)) << 8
}

@(private = "file")
write16 :: proc(c: ^Console, addr: u32, v: u16) {
	write(c, addr, u8(v))
	write(c, (addr + 1) & 0xFFFFFF, u8(v >> 8))
}

@(private = "file")
push8 :: proc(c: ^Console, v: u8) {
	cpu := &c.cpu
	write(c, u32(cpu.sp), v)
	if cpu.e {
		cpu.sp = 0x0100 | ((cpu.sp - 1) & 0xFF)
	} else {
		cpu.sp -= 1
	}
}

@(private = "file")
pull8 :: proc(c: ^Console) -> u8 {
	cpu := &c.cpu
	if cpu.e {
		cpu.sp = 0x0100 | ((cpu.sp + 1) & 0xFF)
	} else {
		cpu.sp += 1
	}
	return read(c, u32(cpu.sp))
}

@(private = "file")
push16 :: proc(c: ^Console, v: u16) {
	push8(c, u8(v >> 8))
	push8(c, u8(v))
}

@(private = "file")
pull16 :: proc(c: ^Console) -> u16 {
	lo := u16(pull8(c))
	return lo | u16(pull8(c)) << 8
}

// --- flags -----------------------------------------------------------------

@(private = "file")
m8 :: #force_inline proc(cpu: ^Cpu) -> bool {return .M in cpu.p}
@(private = "file")
x8 :: #force_inline proc(cpu: ^Cpu) -> bool {return .X in cpu.p}

@(private = "file")
set_flag :: #force_inline proc(cpu: ^Cpu, f: Flag, on: bool) {
	if on {cpu.p += {f}} else {cpu.p -= {f}}
}

@(private = "file")
set_nz :: #force_inline proc(cpu: ^Cpu, v: u16, wide: bool) {
	if wide {
		set_flag(cpu, .Z, v == 0)
		set_flag(cpu, .N, v & 0x8000 != 0)
	} else {
		set_flag(cpu, .Z, v & 0xFF == 0)
		set_flag(cpu, .N, v & 0x80 != 0)
	}
}

// Applies P after it changes (PLP, REP, SEP, RTI, XCE): 8-bit index
// registers lose their high byte and emulation mode forces M and X.
@(private = "file")
fix_p :: proc(cpu: ^Cpu) {
	if cpu.e {
		cpu.p += {.M, .X}
		cpu.sp = 0x0100 | (cpu.sp & 0xFF)
	}
	if .X in cpu.p {
		cpu.x &= 0xFF
		cpu.y &= 0xFF
	}
}

// --- addressing ------------------------------------------------------------

Mode :: enum u8 {
	Imm,
	Dp, Dp_X, Dp_Y,
	Dp_Ind, Dp_Ind_Long, Dp_X_Ind, Dp_Ind_Y, Dp_Ind_Long_Y,
	Abs, Abs_X, Abs_Y,
	Long, Long_X,
	Sr, Sr_Ind_Y,
}

@(private = "file")
dp_base :: proc(c: ^Console, offset: u8) -> u16 {
	if c.cpu.dp & 0xFF != 0 {
		io(c)
	}
	return c.cpu.dp + u16(offset)
}

// Direct page + index, honoring emulation-mode page wrapping.
@(private = "file")
dp_indexed :: proc(c: ^Console, offset: u8, index: u16) -> u16 {
	cpu := &c.cpu
	if cpu.dp & 0xFF != 0 {
		io(c)
	}
	io(c)
	if cpu.e && cpu.dp & 0xFF == 0 {
		return (cpu.dp & 0xFF00) | u16(offset + u8(index))
	}
	return cpu.dp + u16(offset) + index
}

@(private = "file")
data_addr :: #force_inline proc(c: ^Console, a: u16) -> u32 {
	return u32(c.cpu.dbr) << 16 | u32(a)
}

// Returns the 24-bit effective address. `write_like` adds the index penalty
// cycle that stores and RMW instructions always pay.
@(private = "file")
effective :: proc(c: ^Console, mode: Mode, write_like: bool) -> u32 {
	cpu := &c.cpu
	switch mode {
	case .Imm:
		a := u32(cpu.pbr) << 16 | u32(cpu.pc)
		return a
	case .Dp:
		return u32(dp_base(c, fetch8(c)))
	case .Dp_X:
		return u32(dp_indexed(c, fetch8(c), cpu.x))
	case .Dp_Y:
		return u32(dp_indexed(c, fetch8(c), cpu.y))
	case .Dp_Ind:
		ptr := dp_base(c, fetch8(c))
		return data_addr(c, read16_bank0(c, ptr))
	case .Dp_Ind_Long:
		ptr := dp_base(c, fetch8(c))
		lo := u32(read16_bank0(c, ptr))
		return lo | u32(read(c, u32(ptr + 2))) << 16
	case .Dp_X_Ind:
		ptr := dp_indexed(c, fetch8(c), cpu.x)
		return data_addr(c, read16_bank0(c, ptr))
	case .Dp_Ind_Y:
		ptr := dp_base(c, fetch8(c))
		base := data_addr(c, read16_bank0(c, ptr))
		eff := (base + u32(cpu.y)) & 0xFFFFFF
		if write_like || !x8(cpu) || (base & 0xFF00) != (eff & 0xFF00) {
			io(c)
		}
		return eff
	case .Dp_Ind_Long_Y:
		ptr := dp_base(c, fetch8(c))
		lo := u32(read16_bank0(c, ptr))
		base := lo | u32(read(c, u32(ptr + 2))) << 16
		return (base + u32(cpu.y)) & 0xFFFFFF
	case .Abs:
		return data_addr(c, fetch16(c))
	case .Abs_X, .Abs_Y:
		base := data_addr(c, fetch16(c))
		index := mode == .Abs_X ? cpu.x : cpu.y
		eff := (base + u32(index)) & 0xFFFFFF
		if write_like || !x8(cpu) || (base & 0xFF00) != (eff & 0xFF00) {
			io(c)
		}
		return eff
	case .Long:
		return fetch24(c)
	case .Long_X:
		return (fetch24(c) + u32(cpu.x)) & 0xFFFFFF
	case .Sr:
		off := fetch8(c)
		io(c)
		return u32(cpu.sp + u16(off))
	case .Sr_Ind_Y:
		off := fetch8(c)
		io(c)
		ptr := read16_bank0(c, cpu.sp + u16(off))
		io(c)
		return (data_addr(c, ptr) + u32(cpu.y)) & 0xFFFFFF
	}
	return 0
}

// Direct-page and stack-relative operands wrap within bank 0 for 16-bit data.
@(private = "file")
bank0_mode :: #force_inline proc(mode: Mode) -> bool {
	#partial switch mode {
	case .Dp, .Dp_X, .Dp_Y, .Sr:
		return true
	}
	return false
}

@(private = "file")
load :: proc(c: ^Console, mode: Mode, wide: bool) -> u16 {
	if mode == .Imm {
		if wide {return fetch16(c)}
		return u16(fetch8(c))
	}
	addr := effective(c, mode, false)
	if !wide {
		return u16(read(c, addr))
	}
	if bank0_mode(mode) {
		return read16_bank0(c, u16(addr))
	}
	return read16(c, addr)
}

@(private = "file")
store_at :: proc(c: ^Console, addr: u32, mode: Mode, v: u16, wide: bool) {
	if !wide {
		write(c, addr, u8(v))
		return
	}
	if bank0_mode(mode) {
		write(c, addr, u8(v))
		write(c, u32(u16(addr) + 1), u8(v >> 8))
		return
	}
	write16(c, addr, v)
}

@(private = "file")
store :: proc(c: ^Console, mode: Mode, v: u16, wide: bool) {
	store_at(c, effective(c, mode, true), mode, v, wide)
}

// ALU-group operand modes indexed by the low five bits of the opcode.
@(private = "file", rodata)
ALU_MODES := [32]Mode {
	0x01 = .Dp_X_Ind, 0x03 = .Sr, 0x05 = .Dp, 0x07 = .Dp_Ind_Long, 0x09 = .Imm, 0x0D = .Abs, 0x0F = .Long,
	0x11 = .Dp_Ind_Y, 0x12 = .Dp_Ind, 0x13 = .Sr_Ind_Y, 0x15 = .Dp_X, 0x17 = .Dp_Ind_Long_Y,
	0x19 = .Abs_Y, 0x1D = .Abs_X, 0x1F = .Long_X,
}

// --- arithmetic ------------------------------------------------------------

@(private = "file")
adc :: proc(cpu: ^Cpu, v: u16) {
	wide := !m8(cpu)
	carry := u32(.C in cpu.p ? 1 : 0)
	if wide {
		a := u32(cpu.a)
		b := u32(v)
		r: u32
		if .D in cpu.p {
			r = (a & 0x000F) + (b & 0x000F) + carry
			if r > 0x0009 {r += 0x0006}
			r = (a & 0x00F0) + (b & 0x00F0) + (r > 0x000F ? 0x0010 : 0) + (r & 0x000F)
			if r > 0x009F {r += 0x0060}
			r = (a & 0x0F00) + (b & 0x0F00) + (r > 0x00FF ? 0x0100 : 0) + (r & 0x00FF)
			if r > 0x09FF {r += 0x0600}
			r = (a & 0xF000) + (b & 0xF000) + (r > 0x0FFF ? 0x1000 : 0) + (r & 0x0FFF)
			set_flag(cpu, .V, (~(a ~ b) & (a ~ r) & 0x8000) != 0)
			if r > 0x9FFF {r += 0x6000}
		} else {
			r = a + b + carry
			set_flag(cpu, .V, (~(a ~ b) & (a ~ r) & 0x8000) != 0)
		}
		set_flag(cpu, .C, r > 0xFFFF)
		cpu.a = u16(r)
		set_nz(cpu, cpu.a, true)
	} else {
		a := u32(cpu.a & 0xFF)
		b := u32(v & 0xFF)
		r: u32
		if .D in cpu.p {
			r = (a & 0x0F) + (b & 0x0F) + carry
			if r > 0x09 {r += 0x06}
			r = (a & 0xF0) + (b & 0xF0) + (r > 0x0F ? 0x10 : 0) + (r & 0x0F)
			set_flag(cpu, .V, (~(a ~ b) & (a ~ r) & 0x80) != 0)
			if r > 0x9F {r += 0x60}
		} else {
			r = a + b + carry
			set_flag(cpu, .V, (~(a ~ b) & (a ~ r) & 0x80) != 0)
		}
		set_flag(cpu, .C, r > 0xFF)
		cpu.a = (cpu.a & 0xFF00) | u16(r & 0xFF)
		set_nz(cpu, cpu.a, false)
	}
}

@(private = "file")
sbc :: proc(cpu: ^Cpu, v: u16) {
	wide := !m8(cpu)
	if .D not_in cpu.p {
		adc(cpu, wide ? ~v : (~v & 0xFF))
		return
	}
	carry := i32(.C in cpu.p ? 1 : 0)
	if wide {
		a := i32(cpu.a)
		b := i32(~v & 0xFFFF)
		r := (a & 0x000F) + (b & 0x000F) + carry
		if r <= 0x000F {r -= 0x0006}
		r = (a & 0x00F0) + (b & 0x00F0) + (r > 0x000F ? 0x0010 : 0) + (r & 0x000F)
		if r <= 0x00FF {r -= 0x0060}
		r = (a & 0x0F00) + (b & 0x0F00) + (r > 0x00FF ? 0x0100 : 0) + (r & 0x00FF)
		if r <= 0x0FFF {r -= 0x0600}
		r = (a & 0xF000) + (b & 0xF000) + (r > 0x0FFF ? 0x1000 : 0) + (r & 0x0FFF)
		set_flag(cpu, .V, (~(a ~ b) & (a ~ r) & 0x8000) != 0)
		if r <= 0xFFFF {r -= 0x6000}
		set_flag(cpu, .C, r > 0xFFFF)
		cpu.a = u16(r & 0xFFFF)
		set_nz(cpu, cpu.a, true)
	} else {
		a := i32(cpu.a & 0xFF)
		b := i32(~v & 0xFF)
		r := (a & 0x0F) + (b & 0x0F) + carry
		if r <= 0x0F {r -= 0x06}
		r = (a & 0xF0) + (b & 0xF0) + (r > 0x0F ? 0x10 : 0) + (r & 0x0F)
		set_flag(cpu, .V, (~(a ~ b) & (a ~ r) & 0x80) != 0)
		if r <= 0xFF {r -= 0x60}
		set_flag(cpu, .C, r > 0xFF)
		cpu.a = (cpu.a & 0xFF00) | u16(r & 0xFF)
		set_nz(cpu, cpu.a, false)
	}
}

@(private = "file")
compare :: proc(cpu: ^Cpu, reg, v: u16, wide: bool) {
	if wide {
		set_flag(cpu, .C, reg >= v)
		set_nz(cpu, reg - v, true)
	} else {
		set_flag(cpu, .C, reg & 0xFF >= v & 0xFF)
		set_nz(cpu, (reg - v) & 0xFF, false)
	}
}

// Read-modify-write shifts/rotates/inc/dec on a value of the given width.
RMW_Op :: enum u8 {
	Asl, Rol, Lsr, Ror, Inc, Dec,
}

@(private = "file")
rmw_value :: proc(cpu: ^Cpu, op: RMW_Op, v: u16, wide: bool) -> u16 {
	msb: u16 = wide ? 0x8000 : 0x80
	mask: u16 = wide ? 0xFFFF : 0xFF
	r: u16
	switch op {
	case .Asl:
		set_flag(cpu, .C, v & msb != 0)
		r = (v << 1) & mask
	case .Rol:
		r = ((v << 1) | (.C in cpu.p ? 1 : 0)) & mask
		set_flag(cpu, .C, v & msb != 0)
	case .Lsr:
		set_flag(cpu, .C, v & 1 != 0)
		r = (v & mask) >> 1
	case .Ror:
		r = ((v & mask) >> 1) | (.C in cpu.p ? msb : 0)
		set_flag(cpu, .C, v & 1 != 0)
	case .Inc:
		r = (v + 1) & mask
	case .Dec:
		r = (v - 1) & mask
	}
	set_nz(cpu, r, wide)
	return r
}

@(private = "file")
rmw_memory :: proc(c: ^Console, mode: Mode, op: RMW_Op) {
	wide := !m8(&c.cpu)
	addr := effective(c, mode, true)
	v: u16
	if !wide {
		v = u16(read(c, addr))
	} else if bank0_mode(mode) {
		v = read16_bank0(c, u16(addr))
	} else {
		v = read16(c, addr)
	}
	io(c)
	r := rmw_value(&c.cpu, op, v, wide)
	store_at(c, addr, mode, r, wide)
}

// TSB / TRB
@(private = "file")
test_bits :: proc(c: ^Console, mode: Mode, set: bool) {
	cpu := &c.cpu
	wide := !m8(cpu)
	addr := effective(c, mode, true)
	v: u16
	if !wide {
		v = u16(read(c, addr))
	} else if bank0_mode(mode) {
		v = read16_bank0(c, u16(addr))
	} else {
		v = read16(c, addr)
	}
	io(c)
	a := wide ? cpu.a : cpu.a & 0xFF
	set_flag(cpu, .Z, v & a == 0)
	r := set ? v | a : v & ~a
	store_at(c, addr, mode, r, wide)
}

@(private = "file")
branch :: proc(c: ^Console, taken: bool) {
	offset := i8(fetch8(c))
	if !taken {
		return
	}
	cpu := &c.cpu
	io(c)
	target := u16(i32(cpu.pc) + i32(offset))
	if cpu.e && (target & 0xFF00) != (cpu.pc & 0xFF00) {
		io(c)
	}
	cpu.pc = target
}

@(private = "file")
interrupt :: proc(c: ^Console, native_vector, emu_vector: u16, is_brk: bool) {
	cpu := &c.cpu
	if !cpu.e {
		push8(c, cpu.pbr)
	}
	push16(c, cpu.pc)
	flags := cpu.p
	if cpu.e {
		// In emulation mode bit 4 is the B flag.
		if is_brk {flags += {.X}} else {flags -= {.X}}
	}
	push8(c, transmute(u8)flags)
	cpu.p += {.I}
	cpu.p -= {.D}
	cpu.pbr = 0
	vector := cpu.e ? emu_vector : native_vector
	cpu.pc = read16(c, u32(vector))
}

// Executes one instruction or services one interrupt.
cpu_step :: proc(c: ^Console) {
	cpu := &c.cpu
	if cpu.stopped {
		c.pending += 24
		return
	}
	if cpu.nmi_pending {
		cpu.nmi_pending = false
		cpu.waiting = false
		io(c)
		io(c)
		interrupt(c, VEC_NMI_NATIVE, VEC_NMI_EMU, false)
		return
	}
	if cpu.irq_line {
		cpu.waiting = false
		if .I not_in cpu.p {
			io(c)
			io(c)
			interrupt(c, VEC_IRQ_NATIVE, VEC_IRQ_EMU, false)
			return
		}
	}
	if cpu.waiting {
		c.pending += 24
		return
	}
	execute(c, fetch8(c))
}

@(private = "file")
execute :: proc(c: ^Console, op: u8) {
	cpu := &c.cpu

	// The eight ALU instructions share one operand-mode layout.
	if (op & 0x0F != 0x0B && op & 1 == 1) || op & 0x1F == 0x12 {
		if op == 0x89 { // BIT #imm only touches Z
			wide := !m8(cpu)
			v := load(c, .Imm, wide)
			a := wide ? cpu.a : cpu.a & 0xFF
			set_flag(cpu, .Z, a & v == 0)
			return
		}
		mode := ALU_MODES[op & 0x1F]
		wide := !m8(cpu)
		switch op >> 5 {
		case 0: v := load(c, mode, wide); cpu.a = wide ? cpu.a | v : cpu.a | (v & 0xFF); set_nz(cpu, cpu.a, wide)
		case 1: v := load(c, mode, wide); cpu.a = wide ? cpu.a & v : cpu.a & (v | 0xFF00); set_nz(cpu, cpu.a, wide)
		case 2: v := load(c, mode, wide); cpu.a = wide ? cpu.a ~ v : cpu.a ~ (v & 0xFF); set_nz(cpu, cpu.a, wide)
		case 3: adc(cpu, load(c, mode, wide))
		case 4: store(c, mode, cpu.a, wide)
		case 5:
			v := load(c, mode, wide)
			cpu.a = wide ? v : (cpu.a & 0xFF00) | (v & 0xFF)
			set_nz(cpu, cpu.a, wide)
		case 6: compare(cpu, cpu.a, load(c, mode, wide), wide)
		case 7: sbc(cpu, load(c, mode, wide))
		}
		return
	}

	mw := !m8(cpu)
	xw := !x8(cpu)
	switch op {
	// --- shifts, rotates, inc/dec ---
	case 0x06: rmw_memory(c, .Dp, .Asl)
	case 0x0E: rmw_memory(c, .Abs, .Asl)
	case 0x16: rmw_memory(c, .Dp_X, .Asl)
	case 0x1E: rmw_memory(c, .Abs_X, .Asl)
	case 0x26: rmw_memory(c, .Dp, .Rol)
	case 0x2E: rmw_memory(c, .Abs, .Rol)
	case 0x36: rmw_memory(c, .Dp_X, .Rol)
	case 0x3E: rmw_memory(c, .Abs_X, .Rol)
	case 0x46: rmw_memory(c, .Dp, .Lsr)
	case 0x4E: rmw_memory(c, .Abs, .Lsr)
	case 0x56: rmw_memory(c, .Dp_X, .Lsr)
	case 0x5E: rmw_memory(c, .Abs_X, .Lsr)
	case 0x66: rmw_memory(c, .Dp, .Ror)
	case 0x6E: rmw_memory(c, .Abs, .Ror)
	case 0x76: rmw_memory(c, .Dp_X, .Ror)
	case 0x7E: rmw_memory(c, .Abs_X, .Ror)
	case 0xE6: rmw_memory(c, .Dp, .Inc)
	case 0xEE: rmw_memory(c, .Abs, .Inc)
	case 0xF6: rmw_memory(c, .Dp_X, .Inc)
	case 0xFE: rmw_memory(c, .Abs_X, .Inc)
	case 0xC6: rmw_memory(c, .Dp, .Dec)
	case 0xCE: rmw_memory(c, .Abs, .Dec)
	case 0xD6: rmw_memory(c, .Dp_X, .Dec)
	case 0xDE: rmw_memory(c, .Abs_X, .Dec)
	case 0x0A, 0x2A, 0x4A, 0x6A, 0x1A, 0x3A:
		io(c)
		kind: RMW_Op
		switch op {
		case 0x0A: kind = .Asl
		case 0x2A: kind = .Rol
		case 0x4A: kind = .Lsr
		case 0x6A: kind = .Ror
		case 0x1A: kind = .Inc
		case 0x3A: kind = .Dec
		}
		if mw {
			cpu.a = rmw_value(cpu, kind, cpu.a, true)
		} else {
			cpu.a = (cpu.a & 0xFF00) | rmw_value(cpu, kind, cpu.a & 0xFF, false)
		}
	case 0x04: test_bits(c, .Dp, true)
	case 0x0C: test_bits(c, .Abs, true)
	case 0x14: test_bits(c, .Dp, false)
	case 0x1C: test_bits(c, .Abs, false)

	// --- index register loads / stores / compares ---
	case 0xA2: cpu.x = load(c, .Imm, xw); set_nz(cpu, cpu.x, xw)
	case 0xA6: cpu.x = load(c, .Dp, xw); set_nz(cpu, cpu.x, xw)
	case 0xAE: cpu.x = load(c, .Abs, xw); set_nz(cpu, cpu.x, xw)
	case 0xB6: cpu.x = load(c, .Dp_Y, xw); set_nz(cpu, cpu.x, xw)
	case 0xBE: cpu.x = load(c, .Abs_Y, xw); set_nz(cpu, cpu.x, xw)
	case 0xA0: cpu.y = load(c, .Imm, xw); set_nz(cpu, cpu.y, xw)
	case 0xA4: cpu.y = load(c, .Dp, xw); set_nz(cpu, cpu.y, xw)
	case 0xAC: cpu.y = load(c, .Abs, xw); set_nz(cpu, cpu.y, xw)
	case 0xB4: cpu.y = load(c, .Dp_X, xw); set_nz(cpu, cpu.y, xw)
	case 0xBC: cpu.y = load(c, .Abs_X, xw); set_nz(cpu, cpu.y, xw)
	case 0x86: store(c, .Dp, cpu.x, xw)
	case 0x8E: store(c, .Abs, cpu.x, xw)
	case 0x96: store(c, .Dp_Y, cpu.x, xw)
	case 0x84: store(c, .Dp, cpu.y, xw)
	case 0x8C: store(c, .Abs, cpu.y, xw)
	case 0x94: store(c, .Dp_X, cpu.y, xw)
	case 0x64: store(c, .Dp, 0, mw)
	case 0x74: store(c, .Dp_X, 0, mw)
	case 0x9C: store(c, .Abs, 0, mw)
	case 0x9E: store(c, .Abs_X, 0, mw)
	case 0xE0: compare(cpu, cpu.x, load(c, .Imm, xw), xw)
	case 0xE4: compare(cpu, cpu.x, load(c, .Dp, xw), xw)
	case 0xEC: compare(cpu, cpu.x, load(c, .Abs, xw), xw)
	case 0xC0: compare(cpu, cpu.y, load(c, .Imm, xw), xw)
	case 0xC4: compare(cpu, cpu.y, load(c, .Dp, xw), xw)
	case 0xCC: compare(cpu, cpu.y, load(c, .Abs, xw), xw)
	case 0x24, 0x2C, 0x34, 0x3C:
		mode: Mode = op == 0x24 ? .Dp : op == 0x2C ? .Abs : op == 0x34 ? .Dp_X : .Abs_X
		v := load(c, mode, mw)
		a := mw ? cpu.a : cpu.a & 0xFF
		set_flag(cpu, .Z, a & v == 0)
		set_flag(cpu, .N, v & (mw ? 0x8000 : 0x80) != 0)
		set_flag(cpu, .V, v & (mw ? 0x4000 : 0x40) != 0)

	// --- branches ---
	case 0x10: branch(c, .N not_in cpu.p)
	case 0x30: branch(c, .N in cpu.p)
	case 0x50: branch(c, .V not_in cpu.p)
	case 0x70: branch(c, .V in cpu.p)
	case 0x80: branch(c, true)
	case 0x90: branch(c, .C not_in cpu.p)
	case 0xB0: branch(c, .C in cpu.p)
	case 0xD0: branch(c, .Z not_in cpu.p)
	case 0xF0: branch(c, .Z in cpu.p)
	case 0x82:
		offset := i16(fetch16(c))
		io(c)
		cpu.pc = u16(i32(cpu.pc) + i32(offset))

	// --- jumps and calls ---
	case 0x4C:
		cpu.pc = fetch16(c)
	case 0x5C:
		target := fetch24(c)
		cpu.pc = u16(target)
		cpu.pbr = u8(target >> 16)
	case 0x6C:
		ptr := fetch16(c)
		cpu.pc = read16_bank0(c, ptr)
	case 0x7C:
		ptr := fetch16(c) + cpu.x
		io(c)
		cpu.pc = read16(c, u32(cpu.pbr) << 16 | u32(ptr))
	case 0xDC:
		ptr := fetch16(c)
		lo := read16_bank0(c, ptr)
		cpu.pbr = read(c, u32(ptr + 2))
		cpu.pc = lo
	case 0x20:
		target := fetch16(c)
		io(c)
		push16(c, cpu.pc - 1)
		cpu.pc = target
	case 0xFC:
		lo := u16(fetch8(c))
		push16(c, cpu.pc)
		hi := u16(fetch8(c))
		io(c)
		ptr := (lo | hi << 8) + cpu.x
		cpu.pc = read16(c, u32(cpu.pbr) << 16 | u32(ptr))
	case 0x22:
		lo := fetch16(c)
		push8(c, cpu.pbr)
		io(c)
		bank := fetch8(c)
		push16(c, cpu.pc - 1)
		cpu.pc = lo
		cpu.pbr = bank
	case 0x60:
		io(c)
		io(c)
		cpu.pc = pull16(c) + 1
		io(c)
	case 0x6B:
		io(c)
		io(c)
		cpu.pc = pull16(c) + 1
		cpu.pbr = pull8(c)
	case 0x40:
		io(c)
		io(c)
		cpu.p = transmute(Flags)pull8(c)
		fix_p(cpu)
		cpu.pc = pull16(c)
		if !cpu.e {
			cpu.pbr = pull8(c)
		}
	case 0x00:
		_ = fetch8(c) // signature byte
		interrupt(c, VEC_BRK_NATIVE, VEC_IRQ_EMU, true)
	case 0x02:
		_ = fetch8(c)
		interrupt(c, VEC_COP_NATIVE, VEC_COP_EMU, false)

	// --- stack ---
	case 0x48: io(c); if mw {push16(c, cpu.a)} else {push8(c, u8(cpu.a))}
	case 0xDA: io(c); if xw {push16(c, cpu.x)} else {push8(c, u8(cpu.x))}
	case 0x5A: io(c); if xw {push16(c, cpu.y)} else {push8(c, u8(cpu.y))}
	case 0x68:
		io(c); io(c)
		if mw {cpu.a = pull16(c)} else {cpu.a = (cpu.a & 0xFF00) | u16(pull8(c))}
		set_nz(cpu, cpu.a, mw)
	case 0xFA:
		io(c); io(c)
		cpu.x = xw ? pull16(c) : u16(pull8(c))
		set_nz(cpu, cpu.x, xw)
	case 0x7A:
		io(c); io(c)
		cpu.y = xw ? pull16(c) : u16(pull8(c))
		set_nz(cpu, cpu.y, xw)
	case 0x08: io(c); push8(c, transmute(u8)cpu.p)
	case 0x28:
		io(c); io(c)
		cpu.p = transmute(Flags)pull8(c)
		fix_p(cpu)
	case 0x8B: io(c); push8(c, cpu.dbr)
	case 0xAB:
		io(c); io(c)
		cpu.dbr = pull8(c)
		set_nz(cpu, u16(cpu.dbr), false)
	case 0x0B: io(c); push16(c, cpu.dp)
	case 0x2B:
		io(c); io(c)
		cpu.dp = pull16(c)
		set_nz(cpu, cpu.dp, true)
	case 0x4B: io(c); push8(c, cpu.pbr)
	case 0xF4: push16(c, fetch16(c))
	case 0xD4:
		ptr := dp_base(c, fetch8(c))
		push16(c, read16_bank0(c, ptr))
	case 0x62:
		offset := fetch16(c)
		io(c)
		push16(c, cpu.pc + offset)

	// --- transfers ---
	case 0xAA: io(c); cpu.x = xw ? cpu.a : cpu.a & 0xFF; set_nz(cpu, cpu.x, xw)
	case 0xA8: io(c); cpu.y = xw ? cpu.a : cpu.a & 0xFF; set_nz(cpu, cpu.y, xw)
	case 0x8A:
		io(c)
		cpu.a = mw ? cpu.x : (cpu.a & 0xFF00) | (cpu.x & 0xFF)
		set_nz(cpu, cpu.a, mw)
	case 0x98:
		io(c)
		cpu.a = mw ? cpu.y : (cpu.a & 0xFF00) | (cpu.y & 0xFF)
		set_nz(cpu, cpu.a, mw)
	case 0xBA: io(c); cpu.x = xw ? cpu.sp : cpu.sp & 0xFF; set_nz(cpu, cpu.x, xw)
	case 0x9A:
		io(c)
		cpu.sp = cpu.e ? 0x0100 | (cpu.x & 0xFF) : cpu.x
	case 0x9B: io(c); cpu.y = cpu.x; set_nz(cpu, cpu.y, xw)
	case 0xBB: io(c); cpu.x = cpu.y; set_nz(cpu, cpu.x, xw)
	case 0x5B: io(c); cpu.dp = cpu.a; set_nz(cpu, cpu.dp, true)
	case 0x7B: io(c); cpu.a = cpu.dp; set_nz(cpu, cpu.a, true)
	case 0x1B:
		io(c)
		cpu.sp = cpu.e ? 0x0100 | (cpu.a & 0xFF) : cpu.a
	case 0x3B: io(c); cpu.a = cpu.sp; set_nz(cpu, cpu.a, true)
	case 0xEB:
		io(c); io(c)
		cpu.a = cpu.a >> 8 | cpu.a << 8
		set_nz(cpu, cpu.a & 0xFF, false)

	// --- flags ---
	case 0x18: io(c); cpu.p -= {.C}
	case 0x38: io(c); cpu.p += {.C}
	case 0x58: io(c); cpu.p -= {.I}
	case 0x78: io(c); cpu.p += {.I}
	case 0xB8: io(c); cpu.p -= {.V}
	case 0xD8: io(c); cpu.p -= {.D}
	case 0xF8: io(c); cpu.p += {.D}
	case 0xC2:
		bits := transmute(Flags)fetch8(c)
		io(c)
		cpu.p -= bits
		fix_p(cpu)
	case 0xE2:
		bits := transmute(Flags)fetch8(c)
		io(c)
		cpu.p += bits
		fix_p(cpu)
	case 0xFB:
		io(c)
		carry := .C in cpu.p
		set_flag(cpu, .C, cpu.e)
		cpu.e = carry
		if cpu.e {
			cpu.p += {.M, .X}
		}
		fix_p(cpu)

	// --- register inc/dec ---
	case 0xE8: io(c); cpu.x = xw ? cpu.x + 1 : (cpu.x + 1) & 0xFF; set_nz(cpu, cpu.x, xw)
	case 0xC8: io(c); cpu.y = xw ? cpu.y + 1 : (cpu.y + 1) & 0xFF; set_nz(cpu, cpu.y, xw)
	case 0xCA: io(c); cpu.x = xw ? cpu.x - 1 : (cpu.x - 1) & 0xFF; set_nz(cpu, cpu.x, xw)
	case 0x88: io(c); cpu.y = xw ? cpu.y - 1 : (cpu.y - 1) & 0xFF; set_nz(cpu, cpu.y, xw)

	// --- block moves: one byte per execution, PC rewinds until A wraps ---
	case 0x54, 0x44:
		dst := fetch8(c)
		src := fetch8(c)
		cpu.dbr = dst
		v := read(c, u32(src) << 16 | u32(cpu.x))
		write(c, u32(dst) << 16 | u32(cpu.y), v)
		io(c)
		io(c)
		step: u16 = op == 0x54 ? 1 : 0xFFFF
		cpu.x += step
		cpu.y += step
		if !xw {
			cpu.x &= 0xFF
			cpu.y &= 0xFF
		}
		cpu.a -= 1
		if cpu.a != 0xFFFF {
			cpu.pc -= 3
		}

	// --- misc ---
	case 0xEA: io(c)
	case 0x42: _ = fetch8(c) // WDM
	case 0xCB: io(c); io(c); cpu.waiting = true
	case 0xDB: io(c); io(c); cpu.stopped = true
	}
}
