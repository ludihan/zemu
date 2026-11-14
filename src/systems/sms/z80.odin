package sms

// Zilog Z80, including the undocumented flag bits 3 and 5, IXH/IXL style
// operands and the DDCB/FDCB forms. Memory and I/O go through `Bus`, so
// the core can run on a console or on a flat test memory.

FLAG_C :: 0x01
FLAG_N :: 0x02
FLAG_P :: 0x04
FLAG_X :: 0x08
FLAG_H :: 0x10
FLAG_Y :: 0x20
FLAG_Z :: 0x40
FLAG_S :: 0x80

Bus :: struct {
	user:  rawptr,
	read:  proc(user: rawptr, addr: u16) -> u8,
	write: proc(user: rawptr, addr: u16, v: u8),
	input: proc(user: rawptr, port: u16) -> u8,
	output: proc(user: rawptr, port: u16, v: u8),
}

Z80 :: struct {
	a, f, b, c, d, e, h, l: u8,
	a2, f2, b2, c2, d2, e2, h2, l2: u8,
	ix, iy, sp, pc: u16,
	i, r:      u8,
	iff1, iff2: bool,
	im:        u8,
	halted:    bool,
	ei_delay:  bool,
	memptr:    u16,
	irq_line:  bool,
	nmi_pending: bool,
	cycles:    int, // T-states of the last step
	bus:       Bus,
}

@(private = "file")
sz53p: [256]u8 // S, Z, bits 5/3 and parity for each byte

@(init, private = "file")
build_tables :: proc "contextless" () {
	for i in 0 ..< 256 {
		v := u8(i)
		f := v & (FLAG_S | FLAG_Y | FLAG_X)
		if v == 0 {f |= FLAG_Z}
		parity := true
		for b in 0 ..< 8 {
			if (v >> uint(b)) & 1 != 0 {parity = !parity}
		}
		if parity {f |= FLAG_P}
		sz53p[i] = f
	}
}

z80_reset :: proc(z: ^Z80) {
	bus := z.bus
	z^ = {}
	z.bus = bus
	z.a, z.f = 0xFF, 0xFF
	z.sp = 0xFFFF
	z.ix, z.iy = 0xFFFF, 0xFFFF
}

// --- memory helpers -----------------------------------------------------------

@(private = "file")
rd :: #force_inline proc(z: ^Z80, a: u16) -> u8 {return z.bus.read(z.bus.user, a)}
@(private = "file")
wr :: #force_inline proc(z: ^Z80, a: u16, v: u8) {z.bus.write(z.bus.user, a, v)}

@(private = "file")
fetch :: #force_inline proc(z: ^Z80) -> u8 {
	v := rd(z, z.pc)
	z.pc += 1
	return v
}

@(private = "file")
fetch16 :: #force_inline proc(z: ^Z80) -> u16 {
	lo := u16(fetch(z))
	return lo | u16(fetch(z)) << 8
}

@(private = "file")
rd16 :: #force_inline proc(z: ^Z80, a: u16) -> u16 {
	return u16(rd(z, a)) | u16(rd(z, a + 1)) << 8
}

@(private = "file")
wr16 :: #force_inline proc(z: ^Z80, a: u16, v: u16) {
	wr(z, a, u8(v))
	wr(z, a + 1, u8(v >> 8))
}

@(private = "file")
push :: #force_inline proc(z: ^Z80, v: u16) {
	z.sp -= 2
	wr16(z, z.sp, v)
}

@(private = "file")
pop :: #force_inline proc(z: ^Z80) -> u16 {
	v := rd16(z, z.sp)
	z.sp += 2
	return v
}

@(private = "file")
inc_r :: #force_inline proc(z: ^Z80) {
	z.r = (z.r & 0x80) | ((z.r + 1) & 0x7F)
}

// --- register pairs ------------------------------------------------------------

@(private = "file") bc :: #force_inline proc(z: ^Z80) -> u16 {return u16(z.b) << 8 | u16(z.c)}
@(private = "file") de :: #force_inline proc(z: ^Z80) -> u16 {return u16(z.d) << 8 | u16(z.e)}
@(private = "file") hl :: #force_inline proc(z: ^Z80) -> u16 {return u16(z.h) << 8 | u16(z.l)}
@(private = "file") set_bc :: #force_inline proc(z: ^Z80, v: u16) {z.b = u8(v >> 8); z.c = u8(v)}
@(private = "file") set_de :: #force_inline proc(z: ^Z80, v: u16) {z.d = u8(v >> 8); z.e = u8(v)}
@(private = "file") set_hl :: #force_inline proc(z: ^Z80, v: u16) {z.h = u8(v >> 8); z.l = u8(v)}

// Index register in use for the current instruction: 0 = HL, 1 = IX, 2 = IY.
Index :: enum u8 {
	HL,
	IX,
	IY,
}

@(private = "file")
get_xy :: proc(z: ^Z80, idx: Index) -> u16 {
	switch idx {
	case .HL: return hl(z)
	case .IX: return z.ix
	case .IY: return z.iy
	}
	return 0
}

@(private = "file")
set_xy :: proc(z: ^Z80, idx: Index, v: u16) {
	switch idx {
	case .HL: set_hl(z, v)
	case .IX: z.ix = v
	case .IY: z.iy = v
	}
}

// rp table: BC DE HL/IX/IY SP
@(private = "file")
get_rp :: proc(z: ^Z80, p: u8, idx: Index) -> u16 {
	switch p & 3 {
	case 0: return bc(z)
	case 1: return de(z)
	case 2: return get_xy(z, idx)
	}
	return z.sp
}

@(private = "file")
set_rp :: proc(z: ^Z80, p: u8, idx: Index, v: u16) {
	switch p & 3 {
	case 0: set_bc(z, v)
	case 1: set_de(z, v)
	case 2: set_xy(z, idx, v)
	case 3: z.sp = v
	}
}

// 8-bit register by index B C D E H L (HL) A; with an index prefix H/L mean
// IXH/IXL. Index 6 is memory and handled by the caller.
@(private = "file")
get_r :: proc(z: ^Z80, r: u8, idx: Index) -> u8 {
	switch r & 7 {
	case 0: return z.b
	case 1: return z.c
	case 2: return z.d
	case 3: return z.e
	case 4: return u8(get_xy(z, idx) >> 8)
	case 5: return u8(get_xy(z, idx))
	case 7: return z.a
	}
	return 0
}

@(private = "file")
set_r :: proc(z: ^Z80, r: u8, idx: Index, v: u8) {
	switch r & 7 {
	case 0: z.b = v
	case 1: z.c = v
	case 2: z.d = v
	case 3: z.e = v
	case 4: set_xy(z, idx, (get_xy(z, idx) & 0x00FF) | u16(v) << 8)
	case 5: set_xy(z, idx, (get_xy(z, idx) & 0xFF00) | u16(v))
	case 7: z.a = v
	}
}

// Address of the (HL) / (IX+d) / (IY+d) operand, fetching d when indexed.
@(private = "file")
mem_addr :: proc(z: ^Z80, idx: Index) -> u16 {
	if idx == .HL {
		return hl(z)
	}
	d := i8(fetch(z))
	a := u16(i32(get_xy(z, idx)) + i32(d))
	z.memptr = a
	z.cycles += 8
	return a
}

// --- ALU -------------------------------------------------------------------

@(private = "file")
alu :: proc(z: ^Z80, op: u8, v: u8) {
	a := z.a
	carry: u8 = z.f & FLAG_C
	switch op & 7 {
	case 0, 1: // ADD, ADC
		cin: u16 = op & 7 == 1 ? u16(carry) : 0
		r := u16(a) + u16(v) + cin
		res := u8(r)
		f := sz53p[res] & ~u8(FLAG_P)
		if (a ~ v ~ res) & 0x10 != 0 {f |= FLAG_H}
		if (a ~ res) & (v ~ res) & 0x80 != 0 {f |= FLAG_P}
		if r > 0xFF {f |= FLAG_C}
		z.a = res
		z.f = f
	case 2, 3, 7: // SUB, SBC, CP
		cin: u16 = op & 7 == 3 ? u16(carry) : 0
		r := u16(a) - u16(v) - cin
		res := u8(r)
		f := (sz53p[res] & ~u8(FLAG_P)) | FLAG_N
		if (a ~ v ~ res) & 0x10 != 0 {f |= FLAG_H}
		if (a ~ v) & (a ~ res) & 0x80 != 0 {f |= FLAG_P}
		if r > 0xFF {f |= FLAG_C}
		if op & 7 == 7 {
			// CP takes bits 5 and 3 from the operand
			f = (f & ~u8(FLAG_X | FLAG_Y)) | (v & (FLAG_X | FLAG_Y))
		} else {
			z.a = res
		}
		z.f = f
	case 4:
		z.a = a & v
		z.f = sz53p[z.a] | FLAG_H
	case 5:
		z.a = a ~ v
		z.f = sz53p[z.a]
	case 6:
		z.a = a | v
		z.f = sz53p[z.a]
	}
}

@(private = "file")
inc8 :: proc(z: ^Z80, v: u8) -> u8 {
	r := v + 1
	f := (z.f & FLAG_C) | (sz53p[r] & ~u8(FLAG_P))
	if v & 0x0F == 0x0F {f |= FLAG_H}
	if r == 0x80 {f |= FLAG_P}
	z.f = f
	return r
}

@(private = "file")
dec8 :: proc(z: ^Z80, v: u8) -> u8 {
	r := v - 1
	f := (z.f & FLAG_C) | (sz53p[r] & ~u8(FLAG_P)) | FLAG_N
	if v & 0x0F == 0 {f |= FLAG_H}
	if r == 0x7F {f |= FLAG_P}
	z.f = f
	return r
}

@(private = "file")
add16 :: proc(z: ^Z80, a, b: u16) -> u16 {
	r := u32(a) + u32(b)
	f := z.f & (FLAG_S | FLAG_Z | FLAG_P)
	f |= u8(r >> 8) & (FLAG_X | FLAG_Y)
	if (a ~ b ~ u16(r)) & 0x1000 != 0 {f |= FLAG_H}
	if r > 0xFFFF {f |= FLAG_C}
	z.f = f
	z.memptr = a + 1
	return u16(r)
}

@(private = "file")
adc16 :: proc(z: ^Z80, a, b: u16) -> u16 {
	r := u32(a) + u32(b) + u32(z.f & FLAG_C)
	res := u16(r)
	f := u8(res >> 8) & (FLAG_S | FLAG_X | FLAG_Y)
	if res == 0 {f |= FLAG_Z}
	if (a ~ b ~ res) & 0x1000 != 0 {f |= FLAG_H}
	if (a ~ res) & (b ~ res) & 0x8000 != 0 {f |= FLAG_P}
	if r > 0xFFFF {f |= FLAG_C}
	z.f = f
	z.memptr = a + 1
	return res
}

@(private = "file")
sbc16 :: proc(z: ^Z80, a, b: u16) -> u16 {
	r := u32(a) - u32(b) - u32(z.f & FLAG_C)
	res := u16(r)
	f := (u8(res >> 8) & (FLAG_S | FLAG_X | FLAG_Y)) | FLAG_N
	if res == 0 {f |= FLAG_Z}
	if (a ~ b ~ res) & 0x1000 != 0 {f |= FLAG_H}
	if (a ~ b) & (a ~ res) & 0x8000 != 0 {f |= FLAG_P}
	if r > 0xFFFF {f |= FLAG_C}
	z.f = f
	z.memptr = a + 1
	return res
}

// CB-prefix rotates and shifts: RLC RRC RL RR SLA SRA SLL SRL.
@(private = "file")
rot :: proc(z: ^Z80, op: u8, v: u8) -> u8 {
	c: u8
	r: u8
	switch op & 7 {
	case 0: c = v >> 7; r = v << 1 | c
	case 1: c = v & 1; r = v >> 1 | c << 7
	case 2: c = v >> 7; r = v << 1 | (z.f & FLAG_C)
	case 3: c = v & 1; r = v >> 1 | (z.f & FLAG_C) << 7
	case 4: c = v >> 7; r = v << 1
	case 5: c = v & 1; r = (v >> 1) | (v & 0x80)
	case 6: c = v >> 7; r = v << 1 | 1
	case 7: c = v & 1; r = v >> 1
	}
	z.f = sz53p[r] | c
	return r
}

@(private = "file")
bit_test :: proc(z: ^Z80, n: u8, v: u8, xy_source: u8) {
	b := v & (1 << n)
	f := (z.f & FLAG_C) | FLAG_H | (xy_source & (FLAG_X | FLAG_Y))
	if b == 0 {f |= FLAG_Z | FLAG_P}
	if n == 7 && b != 0 {f |= FLAG_S}
	z.f = f
}

@(private = "file")
condition :: #force_inline proc(z: ^Z80, cc: u8) -> bool {
	switch cc & 7 {
	case 0: return z.f & FLAG_Z == 0
	case 1: return z.f & FLAG_Z != 0
	case 2: return z.f & FLAG_C == 0
	case 3: return z.f & FLAG_C != 0
	case 4: return z.f & FLAG_P == 0
	case 5: return z.f & FLAG_P != 0
	case 6: return z.f & FLAG_S == 0
	}
	return z.f & FLAG_S != 0
}

// --- execution ---------------------------------------------------------------

@(private = "file", rodata)
BASE_CYCLES := [256]u8 {
	4, 10, 7, 6, 4, 4, 7, 4, 4, 11, 7, 6, 4, 4, 7, 4,
	8, 10, 7, 6, 4, 4, 7, 4, 12, 11, 7, 6, 4, 4, 7, 4,
	7, 10, 16, 6, 4, 4, 7, 4, 7, 11, 16, 6, 4, 4, 7, 4,
	7, 10, 13, 6, 11, 11, 10, 4, 7, 11, 13, 6, 4, 4, 7, 4,
	4, 4, 4, 4, 4, 4, 7, 4, 4, 4, 4, 4, 4, 4, 7, 4,
	4, 4, 4, 4, 4, 4, 7, 4, 4, 4, 4, 4, 4, 4, 7, 4,
	4, 4, 4, 4, 4, 4, 7, 4, 4, 4, 4, 4, 4, 4, 7, 4,
	7, 7, 7, 7, 7, 7, 4, 7, 4, 4, 4, 4, 4, 4, 7, 4,
	4, 4, 4, 4, 4, 4, 7, 4, 4, 4, 4, 4, 4, 4, 7, 4,
	4, 4, 4, 4, 4, 4, 7, 4, 4, 4, 4, 4, 4, 4, 7, 4,
	4, 4, 4, 4, 4, 4, 7, 4, 4, 4, 4, 4, 4, 4, 7, 4,
	4, 4, 4, 4, 4, 4, 7, 4, 4, 4, 4, 4, 4, 4, 7, 4,
	5, 10, 10, 10, 10, 11, 7, 11, 5, 10, 10, 0, 10, 17, 7, 11,
	5, 10, 10, 11, 10, 11, 7, 11, 5, 4, 10, 11, 10, 0, 7, 11,
	5, 10, 10, 19, 10, 11, 7, 11, 5, 4, 10, 4, 10, 0, 7, 11,
	5, 10, 10, 4, 10, 11, 7, 11, 5, 6, 10, 4, 10, 0, 7, 11,
}

// Executes one instruction (or accepts an interrupt) and returns T-states.
z80_step :: proc(z: ^Z80) -> int {
	if z.nmi_pending {
		z.nmi_pending = false
		z.halted = false
		z.iff1 = false
		inc_r(z)
		push(z, z.pc)
		z.pc = 0x0066
		return 11
	}
	if z.irq_line && z.iff1 && !z.ei_delay {
		z.halted = false
		z.iff1 = false
		z.iff2 = false
		inc_r(z)
		switch z.im {
		case 2:
			push(z, z.pc)
			vec := u16(z.i) << 8 | 0xFF
			z.pc = rd16(z, vec)
			return 19
		case:
			// IM 1 (and IM 0 with the data bus floating at $FF = RST 38h)
			push(z, z.pc)
			z.pc = 0x0038
			return 13
		}
	}
	z.ei_delay = false
	if z.halted {
		inc_r(z)
		return 4
	}
	z.cycles = 0
	execute(z, .HL)
	return z.cycles
}

@(private = "file")
execute :: proc(z: ^Z80, idx: Index) {
	inc_r(z)
	op := fetch(z)
	z.cycles += int(BASE_CYCLES[op])
	if idx != .HL {
		z.cycles += 4
	}

	switch op {
	case 0x40 ..= 0x7F:
		if op == 0x76 {
			z.halted = true
			return
		}
		dst := (op >> 3) & 7
		src := op & 7
		switch {
		case src == 6:
			// LD r,(HL) uses the real H/L even with a prefix
			v := rd(z, mem_addr(z, idx))
			set_r(z, dst, .HL, v)
		case dst == 6:
			a := mem_addr(z, idx)
			wr(z, a, get_r(z, src, .HL))
		case:
			set_r(z, dst, idx, get_r(z, src, idx))
		}
	case 0x80 ..= 0xBF:
		src := op & 7
		v := src == 6 ? rd(z, mem_addr(z, idx)) : get_r(z, src, idx)
		alu(z, op >> 3, v)
	case 0xC6, 0xCE, 0xD6, 0xDE, 0xE6, 0xEE, 0xF6, 0xFE:
		alu(z, op >> 3, fetch(z))

	case 0x00: // NOP
	case 0x01, 0x11, 0x21, 0x31:
		set_rp(z, op >> 4, idx, fetch16(z))
	case 0x09, 0x19, 0x29, 0x39:
		x := get_xy(z, idx)
		set_xy(z, idx, add16(z, x, get_rp(z, op >> 4, idx)))
	case 0x02:
		wr(z, bc(z), z.a)
		z.memptr = (bc(z) + 1) & 0xFF | u16(z.a) << 8
	case 0x12:
		wr(z, de(z), z.a)
		z.memptr = (de(z) + 1) & 0xFF | u16(z.a) << 8
	case 0x0A:
		z.a = rd(z, bc(z))
		z.memptr = bc(z) + 1
	case 0x1A:
		z.a = rd(z, de(z))
		z.memptr = de(z) + 1
	case 0x22:
		a := fetch16(z)
		wr16(z, a, get_xy(z, idx))
		z.memptr = a + 1
	case 0x2A:
		a := fetch16(z)
		set_xy(z, idx, rd16(z, a))
		z.memptr = a + 1
	case 0x32:
		a := fetch16(z)
		wr(z, a, z.a)
		z.memptr = (a + 1) & 0xFF | u16(z.a) << 8
	case 0x3A:
		a := fetch16(z)
		z.a = rd(z, a)
		z.memptr = a + 1
	case 0x03, 0x13, 0x23, 0x33:
		set_rp(z, op >> 4, idx, get_rp(z, op >> 4, idx) + 1)
	case 0x0B, 0x1B, 0x2B, 0x3B:
		set_rp(z, op >> 4, idx, get_rp(z, op >> 4, idx) - 1)
	case 0x04, 0x0C, 0x14, 0x1C, 0x24, 0x2C, 0x3C:
		r := (op >> 3) & 7
		set_r(z, r, idx, inc8(z, get_r(z, r, idx)))
	case 0x05, 0x0D, 0x15, 0x1D, 0x25, 0x2D, 0x3D:
		r := (op >> 3) & 7
		set_r(z, r, idx, dec8(z, get_r(z, r, idx)))
	case 0x34:
		a := mem_addr(z, idx)
		wr(z, a, inc8(z, rd(z, a)))
	case 0x35:
		a := mem_addr(z, idx)
		wr(z, a, dec8(z, rd(z, a)))
	case 0x06, 0x0E, 0x16, 0x1E, 0x26, 0x2E, 0x3E:
		set_r(z, (op >> 3) & 7, idx, fetch(z))
	case 0x36:
		if idx != .HL {
			d := i8(fetch(z))
			a := u16(i32(get_xy(z, idx)) + i32(d))
			z.memptr = a
			wr(z, a, fetch(z))
			z.cycles += 5
		} else {
			wr(z, hl(z), fetch(z))
		}
	case 0x07:
		c := z.a >> 7
		z.a = z.a << 1 | c
		z.f = (z.f & (FLAG_S | FLAG_Z | FLAG_P)) | (z.a & (FLAG_X | FLAG_Y)) | c
	case 0x0F:
		c := z.a & 1
		z.a = z.a >> 1 | c << 7
		z.f = (z.f & (FLAG_S | FLAG_Z | FLAG_P)) | (z.a & (FLAG_X | FLAG_Y)) | c
	case 0x17:
		c := z.a >> 7
		z.a = z.a << 1 | (z.f & FLAG_C)
		z.f = (z.f & (FLAG_S | FLAG_Z | FLAG_P)) | (z.a & (FLAG_X | FLAG_Y)) | c
	case 0x1F:
		c := z.a & 1
		z.a = z.a >> 1 | (z.f & FLAG_C) << 7
		z.f = (z.f & (FLAG_S | FLAG_Z | FLAG_P)) | (z.a & (FLAG_X | FLAG_Y)) | c
	case 0x08: // EX AF,AF'
		z.a, z.a2 = z.a2, z.a
		z.f, z.f2 = z.f2, z.f
	case 0x10: // DJNZ
		off := i8(fetch(z))
		z.b -= 1
		if z.b != 0 {
			z.pc = u16(i32(z.pc) + i32(off))
			z.memptr = z.pc
			z.cycles += 5
		}
	case 0x18:
		off := i8(fetch(z))
		z.pc = u16(i32(z.pc) + i32(off))
		z.memptr = z.pc
	case 0x20, 0x28, 0x30, 0x38:
		off := i8(fetch(z))
		if condition(z, (op >> 3) & 3) {
			z.pc = u16(i32(z.pc) + i32(off))
			z.memptr = z.pc
			z.cycles += 5
		}
	case 0x27: // DAA
		a := z.a
		corr: u8 = 0
		carry := z.f & FLAG_C
		if z.f & FLAG_H != 0 || a & 0x0F > 9 {corr |= 0x06}
		if carry != 0 || a > 0x99 {
			corr |= 0x60
			carry = FLAG_C
		}
		r := z.f & FLAG_N != 0 ? a - corr : a + corr
		f := sz53p[r] | carry | (z.f & FLAG_N)
		if (a ~ r) & 0x10 != 0 {f |= FLAG_H}
		z.a = r
		z.f = f
	case 0x2F: // CPL
		z.a = ~z.a
		z.f = (z.f & (FLAG_S | FLAG_Z | FLAG_P | FLAG_C)) | FLAG_H | FLAG_N | (z.a & (FLAG_X | FLAG_Y))
	case 0x37: // SCF
		z.f = (z.f & (FLAG_S | FLAG_Z | FLAG_P)) | FLAG_C | (z.a & (FLAG_X | FLAG_Y))
	case 0x3F: // CCF
		old_c := z.f & FLAG_C
		z.f = (z.f & (FLAG_S | FLAG_Z | FLAG_P)) | (z.a & (FLAG_X | FLAG_Y)) | (old_c != 0 ? FLAG_H : FLAG_C)

	// --- control flow ---
	case 0xC3:
		z.pc = fetch16(z)
		z.memptr = z.pc
	case 0xC2, 0xCA, 0xD2, 0xDA, 0xE2, 0xEA, 0xF2, 0xFA:
		a := fetch16(z)
		z.memptr = a
		if condition(z, op >> 3) {z.pc = a}
	case 0xE9:
		z.pc = get_xy(z, idx)
	case 0xCD:
		a := fetch16(z)
		push(z, z.pc)
		z.pc = a
		z.memptr = a
	case 0xC4, 0xCC, 0xD4, 0xDC, 0xE4, 0xEC, 0xF4, 0xFC:
		a := fetch16(z)
		z.memptr = a
		if condition(z, op >> 3) {
			push(z, z.pc)
			z.pc = a
			z.cycles += 7
		}
	case 0xC9:
		z.pc = pop(z)
		z.memptr = z.pc
	case 0xC0, 0xC8, 0xD0, 0xD8, 0xE0, 0xE8, 0xF0, 0xF8:
		if condition(z, op >> 3) {
			z.pc = pop(z)
			z.memptr = z.pc
			z.cycles += 6
		}
	case 0xC7, 0xCF, 0xD7, 0xDF, 0xE7, 0xEF, 0xF7, 0xFF:
		push(z, z.pc)
		z.pc = u16(op & 0x38)
		z.memptr = z.pc

	// --- stack and exchanges ---
	case 0xC1, 0xD1, 0xE1:
		set_rp(z, (op >> 4) & 3, idx, pop(z))
	case 0xF1:
		v := pop(z)
		z.a = u8(v >> 8)
		z.f = u8(v)
	case 0xC5, 0xD5, 0xE5:
		push(z, get_rp(z, (op >> 4) & 3, idx))
	case 0xF5:
		push(z, u16(z.a) << 8 | u16(z.f))
	case 0xE3: // EX (SP),HL
		v := rd16(z, z.sp)
		wr16(z, z.sp, get_xy(z, idx))
		set_xy(z, idx, v)
		z.memptr = v
	case 0xEB: // EX DE,HL (never IX/IY)
		t := de(z)
		set_de(z, hl(z))
		set_hl(z, t)
	case 0xD9: // EXX
		z.b, z.b2 = z.b2, z.b
		z.c, z.c2 = z.c2, z.c
		z.d, z.d2 = z.d2, z.d
		z.e, z.e2 = z.e2, z.e
		z.h, z.h2 = z.h2, z.h
		z.l, z.l2 = z.l2, z.l
	case 0xF9:
		z.sp = get_xy(z, idx)

	// --- I/O and interrupts ---
	case 0xD3:
		n := fetch(z)
		port := u16(z.a) << 8 | u16(n)
		z.bus.output(z.bus.user, port, z.a)
		z.memptr = u16(z.a) << 8 | u16(n + 1)
	case 0xDB:
		n := fetch(z)
		port := u16(z.a) << 8 | u16(n)
		z.a = z.bus.input(z.bus.user, port)
		z.memptr = port + 1
	case 0xF3:
		z.iff1 = false
		z.iff2 = false
	case 0xFB:
		z.iff1 = true
		z.iff2 = true
		z.ei_delay = true

	// --- prefixes ---
	case 0xCB:
		execute_cb(z, idx)
	case 0xED:
		execute_ed(z)
	case 0xDD:
		z.cycles -= 4 // the prefix itself is counted by the next instruction
		execute(z, .IX)
	case 0xFD:
		z.cycles -= 4
		execute(z, .IY)
	}
}

@(private = "file")
execute_cb :: proc(z: ^Z80, idx: Index) {
	if idx != .HL {
		// DD CB d op: displacement comes before the opcode
		d := i8(fetch(z))
		op := fetch(z)
		a := u16(i32(get_xy(z, idx)) + i32(d))
		z.memptr = a
		v := rd(z, a)
		z.cycles = 23
		switch op >> 6 {
		case 0:
			r := rot(z, op >> 3, v)
			wr(z, a, r)
			if op & 7 != 6 {set_r(z, op & 7, .HL, r)}
		case 1:
			bit_test(z, (op >> 3) & 7, v, u8(a >> 8))
			z.cycles = 20
		case 2:
			r := v & ~(u8(1) << ((op >> 3) & 7))
			wr(z, a, r)
			if op & 7 != 6 {set_r(z, op & 7, .HL, r)}
		case 3:
			r := v | (u8(1) << ((op >> 3) & 7))
			wr(z, a, r)
			if op & 7 != 6 {set_r(z, op & 7, .HL, r)}
		}
		return
	}
	inc_r(z)
	op := fetch(z)
	r := op & 7
	n := (op >> 3) & 7
	z.cycles = r == 6 ? 15 : 8
	v := r == 6 ? rd(z, hl(z)) : get_r(z, r, .HL)
	switch op >> 6 {
	case 0:
		res := rot(z, op >> 3, v)
		if r == 6 {wr(z, hl(z), res)} else {set_r(z, r, .HL, res)}
	case 1:
		if r == 6 {
			bit_test(z, n, v, u8(z.memptr >> 8))
			z.cycles = 12
		} else {
			bit_test(z, n, v, v)
		}
	case 2:
		res := v & ~(u8(1) << n)
		if r == 6 {wr(z, hl(z), res)} else {set_r(z, r, .HL, res)}
	case 3:
		res := v | (u8(1) << n)
		if r == 6 {wr(z, hl(z), res)} else {set_r(z, r, .HL, res)}
	}
}

@(private = "file")
execute_ed :: proc(z: ^Z80) {
	inc_r(z)
	op := fetch(z)
	z.cycles = 8
	switch op {
	case 0x40, 0x48, 0x50, 0x58, 0x60, 0x68, 0x70, 0x78: // IN r,(C)
		v := z.bus.input(z.bus.user, bc(z))
		z.memptr = bc(z) + 1
		if op != 0x70 {set_r(z, (op >> 3) & 7, .HL, v)}
		z.f = (z.f & FLAG_C) | sz53p[v]
		z.cycles = 12
	case 0x41, 0x49, 0x51, 0x59, 0x61, 0x69, 0x71, 0x79: // OUT (C),r
		v: u8 = op == 0x71 ? 0 : get_r(z, (op >> 3) & 7, .HL)
		z.bus.output(z.bus.user, bc(z), v)
		z.memptr = bc(z) + 1
		z.cycles = 12
	case 0x42, 0x52, 0x62, 0x72:
		set_hl(z, sbc16(z, hl(z), get_rp(z, (op >> 4) & 3, .HL)))
		z.cycles = 15
	case 0x4A, 0x5A, 0x6A, 0x7A:
		set_hl(z, adc16(z, hl(z), get_rp(z, (op >> 4) & 3, .HL)))
		z.cycles = 15
	case 0x43, 0x53, 0x63, 0x73:
		a := fetch16(z)
		wr16(z, a, get_rp(z, (op >> 4) & 3, .HL))
		z.memptr = a + 1
		z.cycles = 20
	case 0x4B, 0x5B, 0x6B, 0x7B:
		a := fetch16(z)
		set_rp(z, (op >> 4) & 3, .HL, rd16(z, a))
		z.memptr = a + 1
		z.cycles = 20
	case 0x44, 0x4C, 0x54, 0x5C, 0x64, 0x6C, 0x74, 0x7C: // NEG
		v := z.a
		z.a = 0
		alu(z, 2, v)
	case 0x45, 0x4D, 0x55, 0x5D, 0x65, 0x6D, 0x75, 0x7D: // RETN / RETI
		z.pc = pop(z)
		z.memptr = z.pc
		z.iff1 = z.iff2
		z.cycles = 14
	case 0x46, 0x4E, 0x66, 0x6E: z.im = 0
	case 0x56, 0x76:             z.im = 1
	case 0x5E, 0x7E:             z.im = 2
	case 0x47: z.i = z.a; z.cycles = 9
	case 0x4F: z.r = z.a; z.cycles = 9
	case 0x57, 0x5F: // LD A,I / LD A,R
		z.a = op == 0x57 ? z.i : z.r
		z.f = (z.f & FLAG_C) | (sz53p[z.a] & ~u8(FLAG_P))
		if z.iff2 {z.f |= FLAG_P}
		z.cycles = 9
	case 0x67: // RRD
		v := rd(z, hl(z))
		wr(z, hl(z), (z.a << 4) | (v >> 4))
		z.a = (z.a & 0xF0) | (v & 0x0F)
		z.f = (z.f & FLAG_C) | sz53p[z.a]
		z.memptr = hl(z) + 1
		z.cycles = 18
	case 0x6F: // RLD
		v := rd(z, hl(z))
		wr(z, hl(z), (v << 4) | (z.a & 0x0F))
		z.a = (z.a & 0xF0) | (v >> 4)
		z.f = (z.f & FLAG_C) | sz53p[z.a]
		z.memptr = hl(z) + 1
		z.cycles = 18
	case 0xA0, 0xA8, 0xB0, 0xB8: // LDI LDD LDIR LDDR
		v := rd(z, hl(z))
		wr(z, de(z), v)
		step: u16 = op & 0x08 != 0 ? 0xFFFF : 1
		set_hl(z, hl(z) + step)
		set_de(z, de(z) + step)
		set_bc(z, bc(z) - 1)
		n := v + z.a
		f := z.f & (FLAG_S | FLAG_Z | FLAG_C)
		if bc(z) != 0 {f |= FLAG_P}
		f |= n & FLAG_X
		if n & 0x02 != 0 {f |= FLAG_Y}
		z.f = f
		z.cycles = 16
		if op >= 0xB0 && bc(z) != 0 {
			z.pc -= 2
			z.memptr = z.pc + 1
			z.cycles = 21
		}
	case 0xA1, 0xA9, 0xB1, 0xB9: // CPI CPD CPIR CPDR
		v := rd(z, hl(z))
		r := z.a - v
		step: u16 = op & 0x08 != 0 ? 0xFFFF : 1
		set_hl(z, hl(z) + step)
		set_bc(z, bc(z) - 1)
		f := (z.f & FLAG_C) | FLAG_N | (sz53p[r] & (FLAG_S | FLAG_Z))
		h := (z.a ~ v ~ r) & 0x10 != 0
		if h {f |= FLAG_H}
		n := r - (h ? 1 : 0)
		f |= n & FLAG_X
		if n & 0x02 != 0 {f |= FLAG_Y}
		if bc(z) != 0 {f |= FLAG_P}
		z.f = f
		z.memptr = op & 0x08 != 0 ? z.memptr - 1 : z.memptr + 1
		z.cycles = 16
		if op >= 0xB0 && bc(z) != 0 && r != 0 {
			z.pc -= 2
			z.memptr = z.pc + 1
			z.cycles = 21
		}
	case 0xA2, 0xAA, 0xB2, 0xBA: // INI IND INIR INDR
		v := z.bus.input(z.bus.user, bc(z))
		wr(z, hl(z), v)
		step: u16 = op & 0x08 != 0 ? 0xFFFF : 1
		set_hl(z, hl(z) + step)
		z.b -= 1
		z.f = (sz53p[z.b] & ~u8(FLAG_P)) | FLAG_N
		z.cycles = 16
		if op >= 0xB0 && z.b != 0 {
			z.pc -= 2
			z.cycles = 21
		}
	case 0xA3, 0xAB, 0xB3, 0xBB: // OUTI OUTD OTIR OTDR
		v := rd(z, hl(z))
		z.b -= 1
		z.bus.output(z.bus.user, bc(z), v)
		step: u16 = op & 0x08 != 0 ? 0xFFFF : 1
		set_hl(z, hl(z) + step)
		z.f = (sz53p[z.b] & ~u8(FLAG_P)) | FLAG_N
		z.cycles = 16
		if op >= 0xB0 && z.b != 0 {
			z.pc -= 2
			z.cycles = 21
		}
	}
}
