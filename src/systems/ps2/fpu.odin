package ps2

import "core:math"

// EE floating-point unit (COP1). Single precision only, and not IEEE: there
// are no infinities, NaNs or denormals. Values with the maximum exponent are
// ordinary large numbers, overflow clamps to ±max and denormals flush to zero.

FCR31_C :: u32(1) << 23

Fpu :: struct {
	r:     [32]u32, // raw register bits
	acc:   u32,
	fcr31: u32,
}

fpu_reset :: proc(f: ^Fpu) {
	f^ = {}
	f.fcr31 = 0x0100_0001
}

// Interprets PS2 float bits as an ordinary float.
@(private = "file")
to_f32 :: proc(bits: u32) -> f32 {
	e := (bits >> 23) & 0xFF
	switch e {
	case 0: return transmute(f32)(bits & 0x8000_0000) // denormal -> ±0
	case 255:
		// would be Inf/NaN in IEEE: on the EE it is just a big number
		return transmute(f32)((bits & 0x8000_0000) | 0x7F7F_FFFF)
	}
	return transmute(f32)bits
}

@(private = "file")
from_f32 :: proc(v: f32) -> u32 {
	bits := transmute(u32)v
	e := (bits >> 23) & 0xFF
	switch e {
	case 0: return bits & 0x8000_0000
	case 255: return (bits & 0x8000_0000) | 0x7F7F_FFFF
	}
	return bits
}

@(private = "file")
reg :: #force_inline proc(f: ^Fpu, i: u32) -> f32 {return to_f32(f.r[i])}

cop1 :: proc(c: ^Console, op: u32) {
	cpu := &c.ee
	f := &cpu.fpu
	ft := (op >> 16) & 31
	fs := (op >> 11) & 31
	fd := (op >> 6) & 31
	switch (op >> 21) & 31 {
	case 0x00: set32(cpu, ft, f.r[fs]) // MFC1
	case 0x02: set32(cpu, ft, fs == 31 ? f.fcr31 : (fs == 0 ? 0x2E30 : 0)) // CFC1
	case 0x04: f.r[fs] = u32(lo64(cpu.gpr[ft])) // MTC1
	case 0x06: if fs == 31 {f.fcr31 = (u32(lo64(cpu.gpr[ft])) & 0x0083_C078) | 0x0100_0001}
	case 0x08: // BC1
		cond := f.fcr31 & FCR31_C != 0
		off := u32(i64(i16(u16(op))) << 2)
		switch ft & 3 {
		case 0: if !cond {cpu.target = cpu.pc + 4 + off; cpu.jump = true}
		case 1: if cond {cpu.target = cpu.pc + 4 + off; cpu.jump = true}
		case 2: if !cond {cpu.target = cpu.pc + 4 + off; cpu.jump = true} else {cpu.annul = true}
		case 3: if cond {cpu.target = cpu.pc + 4 + off; cpu.jump = true} else {cpu.annul = true}
		}
	case 0x10: fpu_single(f, op, fs, ft, fd)
	case 0x14: // W format
		if op & 0x3F == 0x20 { // CVT.S.W
			f.r[fd] = from_f32(f32(i32(f.r[fs])))
		}
	}
}

@(private = "file")
fpu_single :: proc(f: ^Fpu, op: u32, fs, ft, fd: u32) {
	a := reg(f, fs)
	b := reg(f, ft)
	acc := to_f32(f.acc)
	switch op & 0x3F {
	case 0x00: f.r[fd] = from_f32(a + b)
	case 0x01: f.r[fd] = from_f32(a - b)
	case 0x02: f.r[fd] = from_f32(a * b)
	case 0x03:
		if b == 0 {
			// division by zero: ±max with the sign of the quotient
			sign := (f.r[fs] ~ f.r[ft]) & 0x8000_0000
			f.r[fd] = sign | 0x7F7F_FFFF
			f.fcr31 |= 0x0001_0000 | 0x20 // D flag and sticky
		} else {
			f.r[fd] = from_f32(a / b)
		}
	case 0x04: // SQRT of |ft|
		f.r[fd] = from_f32(math.sqrt(abs(b)))
	case 0x05: f.r[fd] = f.r[fs] & 0x7FFF_FFFF
	case 0x06: f.r[fd] = f.r[fs]
	case 0x07: f.r[fd] = f.r[fs] ~ 0x8000_0000
	case 0x16: // RSQRT: fs / sqrt(|ft|)
		s := math.sqrt(abs(b))
		if s == 0 {
			f.r[fd] = (f.r[fs] & 0x8000_0000) | 0x7F7F_FFFF
		} else {
			f.r[fd] = from_f32(a / s)
		}
	case 0x18: f.acc = from_f32(a + b)
	case 0x19: f.acc = from_f32(a - b)
	case 0x1A: f.acc = from_f32(a * b)
	case 0x1C: f.r[fd] = from_f32(acc + a * b)
	case 0x1D: f.r[fd] = from_f32(acc - a * b)
	case 0x1E: f.acc = from_f32(acc + a * b)
	case 0x1F: f.acc = from_f32(acc - a * b)
	case 0x24: // CVT.W.S: truncates and saturates
		switch {
		case f.r[fs] & 0x7F80_0000 >= 0x4F00_0000:
			f.r[fd] = f.r[fs] & 0x8000_0000 != 0 ? 0x8000_0000 : 0x7FFF_FFFF
		case:
			f.r[fd] = u32(i32(a))
		}
	case 0x28: f.r[fd] = from_f32(max(a, b))
	case 0x29: f.r[fd] = from_f32(min(a, b))
	case 0x30: f.fcr31 &= ~FCR31_C
	case 0x32: set_c(f, a == b)
	case 0x34: set_c(f, a < b)
	case 0x36: set_c(f, a <= b)
	}
}

@(private = "file")
set_c :: #force_inline proc(f: ^Fpu, on: bool) {
	if on {f.fcr31 |= FCR31_C} else {f.fcr31 &= ~FCR31_C}
}
