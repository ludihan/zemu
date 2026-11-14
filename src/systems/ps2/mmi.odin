package ps2

// MMI: the EE's 128-bit SIMD integer instructions (parallel words, halfwords
// and bytes), the second multiplier pipeline (MULT1, DIV1, ...) and the
// HI/LO packing operations.

W :: [4]u32
H :: [8]u16
B :: [16]u8

@(private = "file") w4 :: #force_inline proc(v: u128) -> W {return transmute(W)v}
@(private = "file") h8 :: #force_inline proc(v: u128) -> H {return transmute(H)v}
@(private = "file") b16 :: #force_inline proc(v: u128) -> B {return transmute(B)v}
@(private = "file") fw :: #force_inline proc(v: W) -> u128 {return transmute(u128)v}
@(private = "file") fh :: #force_inline proc(v: H) -> u128 {return transmute(u128)v}
@(private = "file") fb :: #force_inline proc(v: B) -> u128 {return transmute(u128)v}

@(private = "file")
sat32 :: #force_inline proc(v: i64) -> u32 {return u32(i32(clamp(v, i64(min(i32)), i64(max(i32)))))}
@(private = "file")
sat16 :: #force_inline proc(v: i32) -> u16 {return u16(i16(clamp(v, i32(min(i16)), i32(max(i16)))))}
@(private = "file")
sat8 :: #force_inline proc(v: i32) -> u8 {return u8(i8(clamp(v, i32(min(i8)), i32(max(i8)))))}

mmi :: proc(c: ^Console, op: u32) {
	cpu := &c.ee
	rs := (op >> 21) & 31
	rt := (op >> 16) & 31
	rd := (op >> 11) & 31
	sa := (op >> 6) & 31
	a := cpu.gpr[rs]
	b := cpu.gpr[rt]
	switch op & 0x3F {
	case 0x00, 0x01, 0x20, 0x21: // MADD, MADDU, MADD1, MADDU1
		pipe1 := op & 0x20 != 0
		shift: uint = pipe1 ? 64 : 0
		acc := u64(u32(cpu.lo >> shift)) | u64(u32(cpu.hi >> shift)) << 32
		prod: u64
		if op & 1 == 0 {
			prod = u64(i64(i32(u32(a))) * i64(i32(u32(b))))
		} else {
			prod = u64(u32(a)) * u64(u32(b))
		}
		r := acc + prod
		set_hilo(cpu, pipe1, sx32(u32(r)), sx32(u32(r >> 32)))
		set64(cpu, rd, sx32(u32(r)))
	case 0x04: // PLZCW
		x := w4(a)
		out: W
		for i in 0 ..< 2 {
			v := x[i]
			if v & 0x8000_0000 != 0 {v = ~v}
			n: u32 = 0
			for bit := 30; bit >= 0 && (v >> uint(bit)) & 1 == 0; bit -= 1 {n += 1}
			out[i] = n
		}
		set64(cpu, rd, u64(out[0]) | u64(out[1]) << 32)
	case 0x08: mmi0(c, op, a, b, rd)
	case 0x09: mmi2(c, op, a, b, rd)
	case 0x28: mmi1(c, op, a, b, rd)
	case 0x29: mmi3(c, op, a, b, rd)
	case 0x10: set64(cpu, rd, hi64(cpu.hi))
	case 0x11: cpu.hi = make128(lo64(cpu.hi), lo64(a))
	case 0x12: set64(cpu, rd, hi64(cpu.lo))
	case 0x13: cpu.lo = make128(lo64(cpu.lo), lo64(a))
	case 0x18: // MULT1
		r := i64(i32(u32(a))) * i64(i32(u32(b)))
		set_hilo(cpu, true, sx32(u32(r)), sx32(u32(r >> 32)))
		set64(cpu, rd, sx32(u32(r)))
	case 0x19:
		r := u64(u32(a)) * u64(u32(b))
		set_hilo(cpu, true, sx32(u32(r)), sx32(u32(r >> 32)))
		set64(cpu, rd, sx32(u32(r)))
	case 0x1A:
		q, r := div32(i32(u32(a)), i32(u32(b)))
		set_hilo(cpu, true, sx32(u32(q)), sx32(u32(r)))
	case 0x1B:
		q, r := divu32(u32(a), u32(b))
		set_hilo(cpu, true, sx32(q), sx32(r))
	case 0x30: pmfhl(cpu, sa, rd)
	case 0x31: // PMTHL.LW
		if sa == 0 {
			x := w4(a)
			lo, hi := w4(cpu.lo), w4(cpu.hi)
			lo[0], hi[0], lo[2], hi[2] = x[0], x[1], x[2], x[3]
			cpu.lo, cpu.hi = fw(lo), fw(hi)
		}
	case 0x34, 0x36, 0x37: // PSLLH, PSRLH, PSRAH
		x := h8(b)
		s := sa & 15
		for &v in x {
			switch op & 0x3F {
			case 0x34: v <<= s
			case 0x36: v >>= s
			case 0x37: v = u16(i16(v) >> s)
			}
		}
		cpu.gpr[rd] = fh(x)
	case 0x3C, 0x3E, 0x3F: // PSLLW, PSRLW, PSRAW
		x := w4(b)
		for &v in x {
			switch op & 0x3F {
			case 0x3C: v <<= sa
			case 0x3E: v >>= sa
			case 0x3F: v = u32(i32(v) >> sa)
			}
		}
		cpu.gpr[rd] = fw(x)
	case:
		ee_exception(c, EXC_RESERVED)
	}
}

// Writes the LO/HI pair of pipeline 0 (lower halves) or 1 (upper halves).
@(private = "file")
set_hilo :: proc(cpu: ^Ee, pipe1: bool, lo, hi: u64) {
	if pipe1 {
		cpu.lo = make128(lo64(cpu.lo), lo)
		cpu.hi = make128(lo64(cpu.hi), hi)
	} else {
		cpu.lo = make128(lo, hi64(cpu.lo))
		cpu.hi = make128(hi, hi64(cpu.hi))
	}
}

@(private = "file")
pmfhl :: proc(cpu: ^Ee, sa: u32, rd: u32) {
	lo, hi := w4(cpu.lo), w4(cpu.hi)
	switch sa {
	case 0: cpu.gpr[rd] = fw({lo[0], hi[0], lo[2], hi[2]})
	case 1: cpu.gpr[rd] = fw({lo[1], hi[1], lo[3], hi[3]})
	case 2:
		s0 := sat32(i64(u64(lo[0]) | u64(hi[0]) << 32))
		s1 := sat32(i64(u64(lo[2]) | u64(hi[2]) << 32))
		cpu.gpr[rd] = make128(sx32(s0), sx32(s1))
	case 3:
		l, h := h8(cpu.lo), h8(cpu.hi)
		cpu.gpr[rd] = fh({l[0], l[2], h[0], h[2], l[4], l[6], h[4], h[6]})
	case 4:
		cpu.gpr[rd] = fh({
			sat16(i32(lo[0])), sat16(i32(lo[1])), sat16(i32(hi[0])), sat16(i32(hi[1])),
			sat16(i32(lo[2])), sat16(i32(lo[3])), sat16(i32(hi[2])), sat16(i32(hi[3])),
		})
	}
}

@(private = "file")
mmi0 :: proc(c: ^Console, op: u32, a, b: u128, rd: u32) {
	cpu := &c.ee
	r: u128
	switch (op >> 6) & 31 {
	case 0x00, 0x01, 0x02, 0x03, 0x10, 0x11: // word ops
		x, y := w4(a), w4(b)
		out: W
		for i in 0 ..< 4 {
			p, q := i32(x[i]), i32(y[i])
			switch (op >> 6) & 31 {
			case 0x00: out[i] = x[i] + y[i]
			case 0x01: out[i] = x[i] - y[i]
			case 0x02: out[i] = p > q ? 0xFFFF_FFFF : 0
			case 0x03: out[i] = u32(max(p, q))
			case 0x10: out[i] = sat32(i64(p) + i64(q))
			case 0x11: out[i] = sat32(i64(p) - i64(q))
			}
		}
		r = fw(out)
	case 0x04, 0x05, 0x06, 0x07, 0x14, 0x15: // halfword ops
		x, y := h8(a), h8(b)
		out: H
		for i in 0 ..< 8 {
			p, q := i32(i16(x[i])), i32(i16(y[i]))
			switch (op >> 6) & 31 {
			case 0x04: out[i] = x[i] + y[i]
			case 0x05: out[i] = x[i] - y[i]
			case 0x06: out[i] = p > q ? 0xFFFF : 0
			case 0x07: out[i] = u16(i16(max(p, q)))
			case 0x14: out[i] = sat16(p + q)
			case 0x15: out[i] = sat16(p - q)
			}
		}
		r = fh(out)
	case 0x08, 0x09, 0x0A, 0x18, 0x19: // byte ops
		x, y := b16(a), b16(b)
		out: B
		for i in 0 ..< 16 {
			p, q := i32(i8(x[i])), i32(i8(y[i]))
			switch (op >> 6) & 31 {
			case 0x08: out[i] = x[i] + y[i]
			case 0x09: out[i] = x[i] - y[i]
			case 0x0A: out[i] = p > q ? 0xFF : 0
			case 0x18: out[i] = sat8(p + q)
			case 0x19: out[i] = sat8(p - q)
			}
		}
		r = fb(out)
	case 0x12: // PEXTLW
		x, y := w4(a), w4(b)
		r = fw({y[0], x[0], y[1], x[1]})
	case 0x13: // PPACW
		x, y := w4(a), w4(b)
		r = fw({y[0], y[2], x[0], x[2]})
	case 0x16: // PEXTLH
		x, y := h8(a), h8(b)
		r = fh({y[0], x[0], y[1], x[1], y[2], x[2], y[3], x[3]})
	case 0x17: // PPACH
		x, y := h8(a), h8(b)
		r = fh({y[0], y[2], y[4], y[6], x[0], x[2], x[4], x[6]})
	case 0x1A: // PEXTLB
		x, y := b16(a), b16(b)
		out: B
		for i in 0 ..< 8 {
			out[2 * i] = y[i]
			out[2 * i + 1] = x[i]
		}
		r = fb(out)
	case 0x1B: // PPACB
		x, y := b16(a), b16(b)
		out: B
		for i in 0 ..< 8 {
			out[i] = y[2 * i]
			out[i + 8] = x[2 * i]
		}
		r = fb(out)
	case 0x1E: // PEXT5
		y := w4(b)
		out: W
		for i in 0 ..< 4 {
			v := y[i]
			out[i] = (v & 0x1F) << 3 | ((v >> 5) & 0x1F) << 11 | ((v >> 10) & 0x1F) << 19 | ((v >> 15) & 1) << 31
		}
		r = fw(out)
	case 0x1F: // PPAC5
		y := w4(b)
		out: W
		for i in 0 ..< 4 {
			v := y[i]
			out[i] = (v >> 3) & 0x1F | ((v >> 11) & 0x1F) << 5 | ((v >> 19) & 0x1F) << 10 | (v >> 31) << 15
		}
		r = fw(out)
	case:
		ee_exception(c, EXC_RESERVED)
		return
	}
	cpu.gpr[rd] = r
}

@(private = "file")
mmi1 :: proc(c: ^Console, op: u32, a, b: u128, rd: u32) {
	cpu := &c.ee
	r: u128
	switch (op >> 6) & 31 {
	case 0x01: // PABSW
		y := w4(b)
		for &v in y {
			if v == 0x8000_0000 {v = 0x7FFF_FFFF} else if i32(v) < 0 {v = u32(-i32(v))}
		}
		r = fw(y)
	case 0x05: // PABSH
		y := h8(b)
		for &v in y {
			if v == 0x8000 {v = 0x7FFF} else if i16(v) < 0 {v = u16(-i16(v))}
		}
		r = fh(y)
	case 0x02, 0x03, 0x10, 0x11:
		x, y := w4(a), w4(b)
		out: W
		for i in 0 ..< 4 {
			switch (op >> 6) & 31 {
			case 0x02: out[i] = x[i] == y[i] ? 0xFFFF_FFFF : 0
			case 0x03: out[i] = u32(min(i32(x[i]), i32(y[i])))
			case 0x10: out[i] = u32(min(u64(x[i]) + u64(y[i]), 0xFFFF_FFFF))
			case 0x11: out[i] = x[i] > y[i] ? x[i] - y[i] : 0
			}
		}
		r = fw(out)
	case 0x04, 0x06, 0x07, 0x14, 0x15:
		x, y := h8(a), h8(b)
		out: H
		for i in 0 ..< 8 {
			switch (op >> 6) & 31 {
			case 0x04: out[i] = i < 4 ? x[i] - y[i] : x[i] + y[i] // PADSBH
			case 0x06: out[i] = x[i] == y[i] ? 0xFFFF : 0
			case 0x07: out[i] = u16(min(i16(x[i]), i16(y[i])))
			case 0x14: out[i] = u16(min(u32(x[i]) + u32(y[i]), 0xFFFF))
			case 0x15: out[i] = x[i] > y[i] ? x[i] - y[i] : 0
			}
		}
		r = fh(out)
	case 0x0A, 0x18, 0x19:
		x, y := b16(a), b16(b)
		out: B
		for i in 0 ..< 16 {
			switch (op >> 6) & 31 {
			case 0x0A: out[i] = x[i] == y[i] ? 0xFF : 0
			case 0x18: out[i] = u8(min(u32(x[i]) + u32(y[i]), 0xFF))
			case 0x19: out[i] = x[i] > y[i] ? x[i] - y[i] : 0
			}
		}
		r = fb(out)
	case 0x12: // PEXTUW
		x, y := w4(a), w4(b)
		r = fw({y[2], x[2], y[3], x[3]})
	case 0x16: // PEXTUH
		x, y := h8(a), h8(b)
		r = fh({y[4], x[4], y[5], x[5], y[6], x[6], y[7], x[7]})
	case 0x1A: // PEXTUB
		x, y := b16(a), b16(b)
		out: B
		for i in 0 ..< 8 {
			out[2 * i] = y[i + 8]
			out[2 * i + 1] = x[i + 8]
		}
		r = fb(out)
	case 0x1B: // QFSRV: funnel shift of rs:rt right by SA bits
		s := cpu.sa & 0x7F
		if s == 0 {
			r = b
		} else {
			r = b >> s | a << (128 - s)
		}
	case:
		ee_exception(c, EXC_RESERVED)
		return
	}
	cpu.gpr[rd] = r
}

@(private = "file")
mmi2 :: proc(c: ^Console, op: u32, a, b: u128, rd: u32) {
	cpu := &c.ee
	switch (op >> 6) & 31 {
	case 0x00, 0x04: // PMADDW, PMSUBW
		x, y := w4(a), w4(b)
		lo, hi := w4(cpu.lo), w4(cpu.hi)
		out: [2]u64
		for k in 0 ..< 2 {
			i := k * 2
			acc := i64(u64(lo[i]) | u64(hi[i]) << 32)
			p := i64(i32(x[i])) * i64(i32(y[i]))
			v := op & 0x100 == 0 ? acc + p : acc - p
			out[k] = u64(v)
			lo[i], lo[i + 1] = u32(v), u32(i32(u32(v)) >> 31)
			hi[i], hi[i + 1] = u32(v >> 32), u32(i32(u32(v >> 32)) >> 31)
		}
		cpu.lo, cpu.hi = fw(lo), fw(hi)
		cpu.gpr[rd] = make128(out[0], out[1])
	case 0x02, 0x03: // PSLLVW, PSRLVW
		x, y := w4(a), w4(b)
		r0, r1: u32
		if (op >> 6) & 31 == 0x02 {
			r0, r1 = y[0] << (x[0] & 31), y[2] << (x[2] & 31)
		} else {
			r0, r1 = y[0] >> (x[0] & 31), y[2] >> (x[2] & 31)
		}
		cpu.gpr[rd] = make128(sx32(r0), sx32(r1))
	case 0x08: cpu.gpr[rd] = cpu.hi
	case 0x09: cpu.gpr[rd] = cpu.lo
	case 0x0A: // PINTH
		x, y := h8(a), h8(b)
		cpu.gpr[rd] = fh({y[0], x[4], y[1], x[5], y[2], x[6], y[3], x[7]})
	case 0x0C: // PMULTW
		x, y := w4(a), w4(b)
		out: [2]u64
		lo, hi: W
		for k in 0 ..< 2 {
			i := k * 2
			v := i64(i32(x[i])) * i64(i32(y[i]))
			out[k] = u64(v)
			lo[i], lo[i + 1] = u32(v), u32(i32(u32(v)) >> 31)
			hi[i], hi[i + 1] = u32(v >> 32), u32(i32(u32(v >> 32)) >> 31)
		}
		cpu.lo, cpu.hi = fw(lo), fw(hi)
		cpu.gpr[rd] = make128(out[0], out[1])
	case 0x0D: // PDIVW
		x, y := w4(a), w4(b)
		lo, hi: [2]u64
		for k in 0 ..< 2 {
			q, r := div32(i32(x[k * 2]), i32(y[k * 2]))
			lo[k], hi[k] = sx32(u32(q)), sx32(u32(r))
		}
		cpu.lo, cpu.hi = make128(lo[0], lo[1]), make128(hi[0], hi[1])
	case 0x0E: cpu.gpr[rd] = make128(lo64(b), lo64(a)) // PCPYLD
	case 0x10, 0x14, 0x11, 0x15, 0x1C: // halfword multiplies
		x, y := h8(a), h8(b)
		p: [8]i32
		for i in 0 ..< 8 {p[i] = i32(i16(x[i])) * i32(i16(y[i]))}
		lo, hi := w4(cpu.lo), w4(cpu.hi)
		switch (op >> 6) & 31 {
		case 0x11, 0x15: // PHMADH, PHMSBH
			sub := (op >> 6) & 31 == 0x15
			s: [4]i32
			for k in 0 ..< 4 {
				s[k] = sub ? p[2 * k + 1] - p[2 * k] : p[2 * k + 1] + p[2 * k]
			}
			lo = {u32(s[0]), lo[1], u32(s[2]), lo[3]}
			hi = {u32(s[1]), hi[1], u32(s[3]), hi[3]}
			cpu.gpr[rd] = fw({u32(s[0]), u32(s[1]), u32(s[2]), u32(s[3])})
		case:
			nl := W{u32(p[0]), u32(p[1]), u32(p[4]), u32(p[5])}
			nh := W{u32(p[2]), u32(p[3]), u32(p[6]), u32(p[7])}
			switch (op >> 6) & 31 {
			case 0x10:
				for i in 0 ..< 4 {nl[i] += lo[i]; nh[i] += hi[i]}
			case 0x14:
				for i in 0 ..< 4 {nl[i] = lo[i] - nl[i]; nh[i] = hi[i] - nh[i]}
			}
			lo, hi = nl, nh
			cpu.gpr[rd] = fw({nl[0], nh[0], nl[2], nh[2]})
		}
		cpu.lo, cpu.hi = fw(lo), fw(hi)
	case 0x12: cpu.gpr[rd] = a & b
	case 0x13: cpu.gpr[rd] = a ~ b
	case 0x1A: // PEXEH
		y := h8(b)
		cpu.gpr[rd] = fh({y[2], y[1], y[0], y[3], y[6], y[5], y[4], y[7]})
	case 0x1B: // PREVH
		y := h8(b)
		cpu.gpr[rd] = fh({y[3], y[2], y[1], y[0], y[7], y[6], y[5], y[4]})
	case 0x1D: // PDIVBW
		x := w4(a)
		d := i32(i16(u16(b)))
		lo, hi: W
		for i in 0 ..< 4 {
			q, r := div32(i32(x[i]), d)
			lo[i], hi[i] = u32(q), u32(i32(i16(r)))
		}
		cpu.lo, cpu.hi = fw(lo), fw(hi)
	case 0x1E: // PEXEW
		y := w4(b)
		cpu.gpr[rd] = fw({y[2], y[1], y[0], y[3]})
	case 0x1F: // PROT3W
		y := w4(b)
		cpu.gpr[rd] = fw({y[1], y[2], y[0], y[3]})
	case:
		ee_exception(c, EXC_RESERVED)
	}
}

@(private = "file")
mmi3 :: proc(c: ^Console, op: u32, a, b: u128, rd: u32) {
	cpu := &c.ee
	switch (op >> 6) & 31 {
	case 0x00: // PMADDUW
		x, y := w4(a), w4(b)
		lo, hi := w4(cpu.lo), w4(cpu.hi)
		out: [2]u64
		for k in 0 ..< 2 {
			i := k * 2
			v := (u64(lo[i]) | u64(hi[i]) << 32) + u64(x[i]) * u64(y[i])
			out[k] = v
			lo[i], lo[i + 1] = u32(v), u32(i32(u32(v)) >> 31)
			hi[i], hi[i + 1] = u32(v >> 32), u32(i32(u32(v >> 32)) >> 31)
		}
		cpu.lo, cpu.hi = fw(lo), fw(hi)
		cpu.gpr[rd] = make128(out[0], out[1])
	case 0x03: // PSRAVW
		x, y := w4(a), w4(b)
		cpu.gpr[rd] = make128(sx32(u32(i32(y[0]) >> (x[0] & 31))), sx32(u32(i32(y[2]) >> (x[2] & 31))))
	case 0x08: cpu.hi = a
	case 0x09: cpu.lo = a
	case 0x0A: // PINTEH
		x, y := h8(a), h8(b)
		cpu.gpr[rd] = fh({y[0], x[0], y[2], x[2], y[4], x[4], y[6], x[6]})
	case 0x0C: // PMULTUW
		x, y := w4(a), w4(b)
		out: [2]u64
		lo, hi: W
		for k in 0 ..< 2 {
			i := k * 2
			v := u64(x[i]) * u64(y[i])
			out[k] = v
			lo[i], lo[i + 1] = u32(v), u32(i32(u32(v)) >> 31)
			hi[i], hi[i + 1] = u32(v >> 32), u32(i32(u32(v >> 32)) >> 31)
		}
		cpu.lo, cpu.hi = fw(lo), fw(hi)
		cpu.gpr[rd] = make128(out[0], out[1])
	case 0x0D: // PDIVUW
		x, y := w4(a), w4(b)
		lo, hi: [2]u64
		for k in 0 ..< 2 {
			q, r := divu32(x[k * 2], y[k * 2])
			lo[k], hi[k] = sx32(q), sx32(r)
		}
		cpu.lo, cpu.hi = make128(lo[0], lo[1]), make128(hi[0], hi[1])
	case 0x0E: cpu.gpr[rd] = make128(hi64(a), hi64(b)) // PCPYUD
	case 0x12: cpu.gpr[rd] = a | b
	case 0x13: cpu.gpr[rd] = ~(a | b)
	case 0x1A: // PEXCH
		y := h8(b)
		cpu.gpr[rd] = fh({y[0], y[2], y[1], y[3], y[4], y[6], y[5], y[7]})
	case 0x1B: // PCPYH
		y := h8(b)
		cpu.gpr[rd] = fh({y[0], y[0], y[0], y[0], y[4], y[4], y[4], y[4]})
	case 0x1E: // PEXCW
		y := w4(b)
		cpu.gpr[rd] = fw({y[0], y[2], y[1], y[3]})
	case:
		ee_exception(c, EXC_RESERVED)
	}
}
