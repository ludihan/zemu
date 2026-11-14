package psx

// Geometry Transformation Engine (COP2): fixed-point 3D transforms,
// perspective projection, lighting and depth cueing.

Gte :: struct {
	v:      [3][3]i16, // V0..V2 (x, y, z)
	rgbc:   [4]u8,
	otz:    u16,
	ir:     [4]i16, // IR0..IR3
	sxy:    [3][2]i16,
	sz:     [4]u16,
	rgb:    [3][4]u8,
	res1:   u32,
	mac:    [4]i32, // MAC0..MAC3
	lzcs:   u32,
	lzcr:   u32,

	rt:     [3][3]i16,
	tr:     [3]i32,
	llm:    [3][3]i16,
	bk:     [3]i32,
	lcm:    [3][3]i16,
	fc:     [3]i32,
	ofx:    i32,
	ofy:    i32,
	h:      u16,
	dqa:    i16,
	dqb:    i32,
	zsf3:   i16,
	zsf4:   i16,
	flag:   u32,

	// per-command state
	sf:     u32, // 12 when the sf bit is set, otherwise 0
	lm:     bool,
}

@(private = "file")
unr_table: [257]u8

@(init, private = "file")
build_unr_table :: proc "contextless" () {
	for i in 0 ..< 257 {
		v := (0x40000 / (i + 0x100) + 1) / 2 - 0x101
		unr_table[i] = u8(max(v, 0))
	}
}

// --- register access -------------------------------------------------------

@(private = "file")
pack16 :: #force_inline proc(lo, hi: i16) -> u32 {
	return u32(u16(lo)) | u32(u16(hi)) << 16
}

gte_read_data :: proc(g: ^Gte, r: u32) -> u32 {
	switch r {
	case 0, 2, 4: return pack16(g.v[r / 2][0], g.v[r / 2][1])
	case 1, 3, 5: return u32(i32(g.v[r / 2][2]))
	case 6:       return u32(g.rgbc[0]) | u32(g.rgbc[1]) << 8 | u32(g.rgbc[2]) << 16 | u32(g.rgbc[3]) << 24
	case 7:       return u32(g.otz)
	case 8 ..= 11: return u32(i32(g.ir[r - 8]))
	case 12 ..= 14: return pack16(g.sxy[r - 12][0], g.sxy[r - 12][1])
	case 15:      return pack16(g.sxy[2][0], g.sxy[2][1])
	case 16 ..= 19: return u32(g.sz[r - 16])
	case 20 ..= 22:
		c := g.rgb[r - 20]
		return u32(c[0]) | u32(c[1]) << 8 | u32(c[2]) << 16 | u32(c[3]) << 24
	case 23:      return g.res1
	case 24 ..= 27: return u32(g.mac[r - 24])
	case 28, 29:
		cv :: proc(v: i16) -> u32 {return u32(clamp(i32(v) >> 7, 0, 0x1F))}
		return cv(g.ir[1]) | cv(g.ir[2]) << 5 | cv(g.ir[3]) << 10
	case 30:      return g.lzcs
	case 31:      return g.lzcr
	}
	return 0
}

gte_write_data :: proc(g: ^Gte, r: u32, v: u32) {
	switch r {
	case 0, 2, 4:
		g.v[r / 2][0] = i16(v)
		g.v[r / 2][1] = i16(v >> 16)
	case 1, 3, 5:
		g.v[r / 2][2] = i16(v)
	case 6:
		g.rgbc = {u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)}
	case 7:
		g.otz = u16(v)
	case 8 ..= 11:
		g.ir[r - 8] = i16(v)
	case 12 ..= 14:
		g.sxy[r - 12] = {i16(v), i16(v >> 16)}
	case 15:
		g.sxy[0] = g.sxy[1]
		g.sxy[1] = g.sxy[2]
		g.sxy[2] = {i16(v), i16(v >> 16)}
	case 16 ..= 19:
		g.sz[r - 16] = u16(v)
	case 20 ..= 22:
		g.rgb[r - 20] = {u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24)}
	case 23:
		g.res1 = v
	case 24 ..= 27:
		g.mac[r - 24] = i32(v)
	case 28:
		g.ir[1] = i16((v & 0x1F) << 7)
		g.ir[2] = i16(((v >> 5) & 0x1F) << 7)
		g.ir[3] = i16(((v >> 10) & 0x1F) << 7)
	case 30:
		g.lzcs = v
		x := i32(v) < 0 ? ~v : v
		n: u32 = 0
		for n < 32 && x & (0x8000_0000 >> n) == 0 {
			n += 1
		}
		g.lzcr = n
	}
}

@(private = "file")
read_matrix :: proc(m: ^[3][3]i16, r: u32) -> u32 {
	switch r {
	case 0: return pack16(m[0][0], m[0][1])
	case 1: return pack16(m[0][2], m[1][0])
	case 2: return pack16(m[1][1], m[1][2])
	case 3: return pack16(m[2][0], m[2][1])
	case 4: return u32(i32(m[2][2]))
	}
	return 0
}

@(private = "file")
write_matrix :: proc(m: ^[3][3]i16, r: u32, v: u32) {
	lo := i16(v)
	hi := i16(v >> 16)
	switch r {
	case 0: m[0][0] = lo; m[0][1] = hi
	case 1: m[0][2] = lo; m[1][0] = hi
	case 2: m[1][1] = lo; m[1][2] = hi
	case 3: m[2][0] = lo; m[2][1] = hi
	case 4: m[2][2] = lo
	}
}

gte_read_control :: proc(g: ^Gte, r: u32) -> u32 {
	switch r {
	case 0 ..= 4:   return read_matrix(&g.rt, r)
	case 5 ..= 7:   return u32(g.tr[r - 5])
	case 8 ..= 12:  return read_matrix(&g.llm, r - 8)
	case 13 ..= 15: return u32(g.bk[r - 13])
	case 16 ..= 20: return read_matrix(&g.lcm, r - 16)
	case 21 ..= 23: return u32(g.fc[r - 21])
	case 24:        return u32(g.ofx)
	case 25:        return u32(g.ofy)
	case 26:        return u32(i32(i16(g.h))) // reads back sign-extended (hardware quirk)
	case 27:        return u32(i32(g.dqa))
	case 28:        return u32(g.dqb)
	case 29:        return u32(i32(g.zsf3))
	case 30:        return u32(i32(g.zsf4))
	case 31:        return g.flag
	}
	return 0
}

gte_write_control :: proc(g: ^Gte, r: u32, v: u32) {
	switch r {
	case 0 ..= 4:   write_matrix(&g.rt, r, v)
	case 5 ..= 7:   g.tr[r - 5] = i32(v)
	case 8 ..= 12:  write_matrix(&g.llm, r - 8, v)
	case 13 ..= 15: g.bk[r - 13] = i32(v)
	case 16 ..= 20: write_matrix(&g.lcm, r - 16, v)
	case 21 ..= 23: g.fc[r - 21] = i32(v)
	case 24:        g.ofx = i32(v)
	case 25:        g.ofy = i32(v)
	case 26:        g.h = u16(v)
	case 27:        g.dqa = i16(v)
	case 28:        g.dqb = i32(v)
	case 29:        g.zsf3 = i16(v)
	case 30:        g.zsf4 = i16(v)
	case 31:
		g.flag = v & 0x7FFF_F000
		if g.flag & 0x7F87_E000 != 0 {g.flag |= 0x8000_0000}
	}
}

// --- arithmetic with saturation flags ---------------------------------------

@(private = "file")
check_mac :: proc(g: ^Gte, i: int, v: i64) -> i64 {
	// 44-bit signed range for MAC1-3
	if v > 0x7FF_FFFF_FFFF {
		g.flag |= u32(1) << u32(31 - i)
	} else if v < -0x800_0000_0000 {
		g.flag |= u32(1) << u32(28 - i)
	}
	// results wrap to 44 bits
	return (v << 20) >> 20
}

@(private = "file")
set_mac :: proc(g: ^Gte, i: int, v: i64) -> i64 {
	r := check_mac(g, i, v)
	g.mac[i] = i32(r >> g.sf)
	return r >> g.sf
}

@(private = "file")
set_mac0 :: proc(g: ^Gte, v: i64) {
	if v > 0x7FFF_FFFF {
		g.flag |= 1 << 16
	} else if v < -0x8000_0000 {
		g.flag |= 1 << 15
	}
	g.mac[0] = i32(v)
}

@(private = "file")
set_ir :: proc(g: ^Gte, i: int, v: i64, lm: bool) {
	lo: i64 = lm ? 0 : -0x8000
	if v < lo || v > 0x7FFF {
		g.flag |= u32(1) << u32(25 - i)
	}
	g.ir[i] = i16(clamp(v, lo, 0x7FFF))
}

@(private = "file")
set_ir0 :: proc(g: ^Gte, v: i64) {
	if v < 0 || v > 0x1000 {
		g.flag |= 1 << 12
	}
	g.ir[0] = i16(clamp(v, 0, 0x1000))
}

@(private = "file")
set_mac_ir :: proc(g: ^Gte, i: int, v: i64) {
	set_ir(g, i, set_mac(g, i, v), g.lm)
}

@(private = "file")
push_sz :: proc(g: ^Gte, v: i64) {
	if v < 0 || v > 0xFFFF {
		g.flag |= 1 << 18
	}
	g.sz[0] = g.sz[1]
	g.sz[1] = g.sz[2]
	g.sz[2] = g.sz[3]
	g.sz[3] = u16(clamp(v, 0, 0xFFFF))
}

@(private = "file")
push_sxy :: proc(g: ^Gte, x, y: i64) {
	if x < -0x400 || x > 0x3FF {g.flag |= 1 << 14}
	if y < -0x400 || y > 0x3FF {g.flag |= 1 << 13}
	g.sxy[0] = g.sxy[1]
	g.sxy[1] = g.sxy[2]
	g.sxy[2] = {i16(clamp(x, -0x400, 0x3FF)), i16(clamp(y, -0x400, 0x3FF))}
}

@(private = "file")
push_color :: proc(g: ^Gte) {
	col: [4]u8
	for i in 0 ..< 3 {
		v := g.mac[i + 1] >> 4
		if v < 0 || v > 0xFF {
			g.flag |= u32(1) << u32(21 - i)
		}
		col[i] = u8(clamp(v, 0, 0xFF))
	}
	col[3] = g.rgbc[3]
	g.rgb[0] = g.rgb[1]
	g.rgb[1] = g.rgb[2]
	g.rgb[2] = col
}

// Newton-Raphson division H / SZ3 as the hardware does it (17-bit result).
@(private = "file")
divide :: proc(g: ^Gte) -> i64 {
	h := u32(g.h)
	sz := u32(g.sz[3])
	if h >= sz * 2 {
		g.flag |= 1 << 17
		return 0x1FFFF
	}
	z: u32 = 0
	for z < 16 && sz & (0x8000 >> z) == 0 {
		z += 1
	}
	n := u64(h) << z
	d := u64(sz) << z
	u := u64(unr_table[(d - 0x7FC0) >> 7]) + 0x101
	d = (0x200_0080 - d * u) >> 8
	d = (0x000_0080 + d * u) >> 8
	return i64(min(0x1FFFF, (n * d + 0x8000) >> 16))
}

@(private = "file")
mat_vec :: proc(g: ^Gte, m: ^[3][3]i16, add: [3]i64, v: [3]i64) {
	for i in 0 ..< 3 {
		r := add[i] << 12
		r = check_mac(g, i + 1, r + i64(m[i][0]) * v[0])
		r = check_mac(g, i + 1, r + i64(m[i][1]) * v[1])
		r = check_mac(g, i + 1, r + i64(m[i][2]) * v[2])
		set_mac_ir(g, i + 1, r)
	}
}

@(private = "file")
rtp :: proc(g: ^Gte, vi: int, last: bool) {
	v := [3]i64{i64(g.v[vi][0]), i64(g.v[vi][1]), i64(g.v[vi][2])}
	z: i64
	for i in 0 ..< 3 {
		r := i64(g.tr[i]) << 12
		r = check_mac(g, i + 1, r + i64(g.rt[i][0]) * v[0])
		r = check_mac(g, i + 1, r + i64(g.rt[i][1]) * v[1])
		r = check_mac(g, i + 1, r + i64(g.rt[i][2]) * v[2])
		shifted := set_mac(g, i + 1, r)
		if i == 2 {
			// IR3's flag is computed from the value shifted by 12 regardless of sf.
			z = r >> 12
			lo: i64 = g.lm ? 0 : -0x8000
			if z < -0x8000 || z > 0x7FFF {
				g.flag |= 1 << 22
			}
			g.ir[3] = i16(clamp(shifted, lo, 0x7FFF))
		} else {
			set_ir(g, i + 1, shifted, g.lm)
		}
	}
	push_sz(g, z)
	n := divide(g)
	x := n * i64(g.ir[1]) + i64(g.ofx)
	set_mac0(g, x)
	y := n * i64(g.ir[2]) + i64(g.ofy)
	set_mac0(g, y)
	push_sxy(g, x >> 16, y >> 16)
	if last {
		dq := n * i64(g.dqa) + i64(g.dqb)
		set_mac0(g, dq)
		set_ir0(g, dq >> 12)
	}
}

// Moves MAC toward the far color by IR0 (depth cueing).
@(private = "file")
depth_cue :: proc(g: ^Gte, mac: [3]i64) {
	for i in 0 ..< 3 {
		fc := i64(g.fc[i]) << 12
		r := set_mac(g, i + 1, fc - mac[i])
		set_ir(g, i + 1, r, false) // this intermediate always saturates signed
	}
	for i in 0 ..< 3 {
		r := i64(g.ir[i + 1]) * i64(g.ir[0]) + mac[i]
		set_mac_ir(g, i + 1, r)
	}
}

@(private = "file")
color_times_ir :: proc(g: ^Gte) -> [3]i64 {
	return {
		(i64(g.rgbc[0]) * i64(g.ir[1])) << 4,
		(i64(g.rgbc[1]) * i64(g.ir[2])) << 4,
		(i64(g.rgbc[2]) * i64(g.ir[3])) << 4,
	}
}

Light_Kind :: enum u8 {
	Plain, // NCS: light only
	Color, // NCC: light times vertex color
	Depth, // NCD: light times vertex color, then depth cue
}

@(private = "file")
light :: proc(g: ^Gte, vi: int, kind: Light_Kind) {
	v := [3]i64{i64(g.v[vi][0]), i64(g.v[vi][1]), i64(g.v[vi][2])}
	mat_vec(g, &g.llm, {0, 0, 0}, v)
	ir := [3]i64{i64(g.ir[1]), i64(g.ir[2]), i64(g.ir[3])}
	mat_vec(g, &g.lcm, {i64(g.bk[0]), i64(g.bk[1]), i64(g.bk[2])}, ir)
	switch kind {
	case .Plain:
	case .Color:
		m := color_times_ir(g)
		for i in 0 ..< 3 {set_mac_ir(g, i + 1, m[i])}
	case .Depth:
		depth_cue(g, color_times_ir(g))
	}
	push_color(g)
}

gte_command :: proc(g: ^Gte, op: u32) {
	g.flag = 0
	g.sf = op & (1 << 19) != 0 ? 12 : 0
	g.lm = op & (1 << 10) != 0

	switch op & 0x3F {
	case 0x01: // RTPS
		rtp(g, 0, true)
	case 0x30: // RTPT
		rtp(g, 0, false)
		rtp(g, 1, false)
		rtp(g, 2, true)
	case 0x06: // NCLIP
		s := g.sxy
		v := i64(s[0][0]) * i64(s[1][1]) + i64(s[1][0]) * i64(s[2][1]) + i64(s[2][0]) * i64(s[0][1]) -
		     i64(s[0][0]) * i64(s[2][1]) - i64(s[1][0]) * i64(s[0][1]) - i64(s[2][0]) * i64(s[1][1])
		set_mac0(g, v)
	case 0x0C: // OP
		d1, d2, d3 := i64(g.rt[0][0]), i64(g.rt[1][1]), i64(g.rt[2][2])
		ir1, ir2, ir3 := i64(g.ir[1]), i64(g.ir[2]), i64(g.ir[3])
		set_mac_ir(g, 1, ir3 * d2 - ir2 * d3)
		set_mac_ir(g, 2, ir1 * d3 - ir3 * d1)
		set_mac_ir(g, 3, ir2 * d1 - ir1 * d2)
	case 0x10: // DPCS
		depth_cue(g, {i64(g.rgbc[0]) << 16, i64(g.rgbc[1]) << 16, i64(g.rgbc[2]) << 16})
		push_color(g)
	case 0x2A: // DPCT
		for _ in 0 ..< 3 {
			c := g.rgb[0]
			depth_cue(g, {i64(c[0]) << 16, i64(c[1]) << 16, i64(c[2]) << 16})
			push_color(g)
		}
	case 0x11: // INTPL
		depth_cue(g, {i64(g.ir[1]) << 12, i64(g.ir[2]) << 12, i64(g.ir[3]) << 12})
		push_color(g)
	case 0x12: // MVMVA
		mx := (op >> 17) & 3
		vv := (op >> 15) & 3
		cv := (op >> 13) & 3
		m: [3][3]i16
		switch mx {
		case 0: m = g.rt
		case 1: m = g.llm
		case 2: m = g.lcm
		case 3: // garbage matrix
			m = {
				{-i16(u16(g.rgbc[0]) << 4), i16(u16(g.rgbc[0]) << 4), g.ir[0]},
				{g.rt[0][2], g.rt[0][2], g.rt[0][2]},
				{g.rt[1][1], g.rt[1][1], g.rt[1][1]},
			}
		}
		v: [3]i64
		if vv == 3 {
			v = {i64(g.ir[1]), i64(g.ir[2]), i64(g.ir[3])}
		} else {
			v = {i64(g.v[vv][0]), i64(g.v[vv][1]), i64(g.v[vv][2])}
		}
		add: [3]i64
		switch cv {
		case 0: add = {i64(g.tr[0]), i64(g.tr[1]), i64(g.tr[2])}
		case 1: add = {i64(g.bk[0]), i64(g.bk[1]), i64(g.bk[2])}
		case 2:
			// Far-color translation is bugged: only the flags see the first column.
			for i in 0 ..< 3 {
				r := (i64(g.fc[i]) << 12) + i64(m[i][0]) * v[0]
				set_ir(g, i + 1, check_mac(g, i + 1, r) >> g.sf, false)
				r2 := check_mac(g, i + 1, i64(m[i][1]) * v[1])
				r2 = check_mac(g, i + 1, r2 + i64(m[i][2]) * v[2])
				set_mac_ir(g, i + 1, r2)
			}
		}
		if cv != 2 {
			mat_vec(g, &m, add, v)
		}
	case 0x13: // NCDS
		light(g, 0, .Depth)
	case 0x16: // NCDT
		light(g, 0, .Depth)
		light(g, 1, .Depth)
		light(g, 2, .Depth)
	case 0x1B: // NCCS
		light(g, 0, .Color)
	case 0x3F: // NCCT
		light(g, 0, .Color)
		light(g, 1, .Color)
		light(g, 2, .Color)
	case 0x1E: // NCS
		light(g, 0, .Plain)
	case 0x20: // NCT
		light(g, 0, .Plain)
		light(g, 1, .Plain)
		light(g, 2, .Plain)
	case 0x14: // CDP
		ir := [3]i64{i64(g.ir[1]), i64(g.ir[2]), i64(g.ir[3])}
		mat_vec(g, &g.lcm, {i64(g.bk[0]), i64(g.bk[1]), i64(g.bk[2])}, ir)
		depth_cue(g, color_times_ir(g))
		push_color(g)
	case 0x1C: // CC
		ir := [3]i64{i64(g.ir[1]), i64(g.ir[2]), i64(g.ir[3])}
		mat_vec(g, &g.lcm, {i64(g.bk[0]), i64(g.bk[1]), i64(g.bk[2])}, ir)
		m := color_times_ir(g)
		for i in 0 ..< 3 {set_mac_ir(g, i + 1, m[i])}
		push_color(g)
	case 0x28: // SQR
		for i in 1 ..= 3 {
			set_mac_ir(g, i, i64(g.ir[i]) * i64(g.ir[i]))
		}
	case 0x29: // DCPL
		depth_cue(g, color_times_ir(g))
		push_color(g)
	case 0x2D: // AVSZ3
		v := i64(g.zsf3) * (i64(g.sz[1]) + i64(g.sz[2]) + i64(g.sz[3]))
		set_mac0(g, v)
		otz := v >> 12
		if otz < 0 || otz > 0xFFFF {g.flag |= 1 << 18}
		g.otz = u16(clamp(otz, 0, 0xFFFF))
	case 0x2E: // AVSZ4
		v := i64(g.zsf4) * (i64(g.sz[0]) + i64(g.sz[1]) + i64(g.sz[2]) + i64(g.sz[3]))
		set_mac0(g, v)
		otz := v >> 12
		if otz < 0 || otz > 0xFFFF {g.flag |= 1 << 18}
		g.otz = u16(clamp(otz, 0, 0xFFFF))
	case 0x3D: // GPF
		for i in 1 ..= 3 {
			set_mac_ir(g, i, i64(g.ir[0]) * i64(g.ir[i]))
		}
		push_color(g)
	case 0x3E: // GPL
		for i in 1 ..= 3 {
			set_mac_ir(g, i, (i64(g.mac[i]) << g.sf) + i64(g.ir[0]) * i64(g.ir[i]))
		}
		push_color(g)
	}

	if g.flag & 0x7F87_E000 != 0 {
		g.flag |= 0x8000_0000
	}
}
