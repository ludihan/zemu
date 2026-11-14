package psx

// Motion Decoder: decompresses run-length coded DCT macroblocks into RGB
// pixels for full-motion video.

MDEC_IN_CAPACITY  :: 0x40000 // halfwords of compressed input buffered
MDEC_OUT_CAPACITY :: 0x20000 // words of decoded output buffered

Mdec :: struct {
	command:     u32,
	words_left:  int,
	depth:       u32, // 0 = 4-bit, 1 = 8-bit, 2 = 24-bit, 3 = 15-bit
	signed:      bool,
	bit15:       bool,
	quant:       [2][64]u8, // luma, chroma
	scale:       [64]i16,
	params:      [64]u32,
	param_len:   int,
	param_need:  int,
	mode:        enum u8 {Idle, Decode, Quant, Scale},

	input:       [dynamic]u16,
	output:      [dynamic]u32,
	out_pos:     int,
	enable_in:   bool,
	enable_out:  bool,
}

@(private = "file", rodata)
ZIGZAG := [64]u8 {
	0, 1, 5, 6, 14, 15, 27, 28,
	2, 4, 7, 13, 16, 26, 29, 42,
	3, 8, 12, 17, 25, 30, 41, 43,
	9, 11, 18, 24, 31, 40, 44, 53,
	10, 19, 23, 32, 39, 45, 52, 54,
	20, 22, 33, 38, 46, 51, 55, 60,
	21, 34, 37, 47, 50, 56, 59, 61,
	35, 36, 48, 49, 57, 58, 62, 63,
}

// ZAGZIG[k] is the raster position of the k-th coefficient in zigzag order.
@(private = "file")
ZAGZIG: [64]u8

@(init, private = "file")
build_zagzig :: proc "contextless" () {
	for z, i in ZIGZAG {
		ZAGZIG[z] = u8(i)
	}
}

mdec_reset :: proc(m: ^Mdec) {
	m.mode = .Idle
	m.words_left = 0
	clear(&m.input)
	clear(&m.output)
	m.out_pos = 0
}

mdec_destroy :: proc(m: ^Mdec) {
	delete(m.input)
	delete(m.output)
}

mdec_status :: proc(m: ^Mdec) -> u32 {
	s: u32
	if m.out_pos >= len(m.output) {s |= 1 << 31} // output FIFO empty
	if m.mode != .Idle {s |= 1 << 29}            // command busy
	if m.enable_in && m.mode != .Idle {s |= 1 << 28}
	if m.enable_out && m.out_pos < len(m.output) {s |= 1 << 27}
	s |= m.depth << 25
	if m.signed {s |= 1 << 24}
	if m.bit15 {s |= 1 << 23}
	s |= u32(max(m.words_left - 1, 0)) & 0xFFFF
	s |= 4 << 16 // current block: blocks are decoded at once, so it reads as Y (4)
	return s
}

mdec_write_control :: proc(m: ^Mdec, v: u32) {
	if v & (1 << 31) != 0 {
		mdec_reset(m)
	}
	m.enable_in = v & (1 << 30) != 0
	m.enable_out = v & (1 << 29) != 0
}

mdec_read_data :: proc(c: ^Console) -> u32 {
	m := &c.mdec
	if m.out_pos < len(m.output) {
		v := m.output[m.out_pos]
		m.out_pos += 1
		if m.out_pos >= len(m.output) {
			clear(&m.output)
			m.out_pos = 0
		}
		return v
	}
	return 0
}

mdec_write_command :: proc(c: ^Console, v: u32) {
	m := &c.mdec
	switch m.mode {
	case .Idle:
		m.command = v
		switch v >> 29 {
		case 1:
			m.depth = (v >> 27) & 3
			m.signed = v & (1 << 26) != 0
			m.bit15 = v & (1 << 25) != 0
			m.words_left = int(v & 0xFFFF)
			clear(&m.input)
			m.mode = m.words_left > 0 ? .Decode : .Idle
		case 2:
			m.param_need = v & 1 != 0 ? 32 : 16
			m.param_len = 0
			m.mode = .Quant
		case 3:
			m.param_need = 32
			m.param_len = 0
			m.mode = .Scale
		}
	case .Decode:
		if len(m.input) < MDEC_IN_CAPACITY {
			append(&m.input, u16(v), u16(v >> 16))
		}
		m.words_left -= 1
		if m.words_left <= 0 {
			decode_all(m)
			m.mode = .Idle
		}
	case .Quant, .Scale:
		if m.param_len < len(m.params) {
			m.params[m.param_len] = v
			m.param_len += 1
		}
		if m.param_len >= m.param_need {
			if m.mode == .Quant {
				for i in 0 ..< 64 {
					m.quant[0][i] = u8(m.params[i / 4] >> (u32(i & 3) * 8))
				}
				if m.param_need == 32 {
					for i in 0 ..< 64 {
						m.quant[1][i] = u8(m.params[16 + i / 4] >> (u32(i & 3) * 8))
					}
				}
			} else {
				for i in 0 ..< 64 {
					m.scale[i] = i16(m.params[i / 2] >> (u32(i & 1) * 16))
				}
			}
			m.mode = .Idle
		}
	}
}

// Decodes one 8x8 block. Returns false when the input runs out.
@(private = "file")
decode_block :: proc(m: ^Mdec, pos: ^int, table: int, out: ^[64]i32) -> bool {
	coeffs: [64]i32
	// skip padding
	for pos^ < len(m.input) && m.input[pos^] == 0xFE00 {
		pos^ += 1
	}
	if pos^ >= len(m.input) {
		return false
	}
	q := &m.quant[table]
	first := m.input[pos^]
	pos^ += 1
	qscale := i32(first >> 10)
	k := 0
	n := first
	for {
		// Coefficients are kept with four fraction bits: the scaled value,
		// nudged half a step toward zero (as Mednafen models the hardware;
		// the result matches hardware MDEC output in JaCzekanski's ps1-tests).
		ci := i32(i16(n << 6)) >> 6
		val: i32
		if qscale == 0 {
			val = ci * 2 << 4
		} else {
			qk := k == 0 ? i32(q[0]) : qscale * i32(q[k])
			val = (k == 0 ? ci * qk : (ci * qk) >> 3) << 4
			if ci < 0 {val += 8} else if ci > 0 {val -= 8}
		}
		val = clamp(val, -0x4000, 0x3FFF)
		if qscale > 0 {
			coeffs[ZAGZIG[k]] = val
		} else {
			coeffs[k] = val
		}
		if pos^ >= len(m.input) {
			break
		}
		n = m.input[pos^]
		pos^ += 1
		if n == 0xFE00 {
			break
		}
		k += int(n >> 10) + 1
		if k > 63 {
			break
		}
	}
	idct(m, &coeffs, out)
	return true
}

// Two 1-D passes, each writing its result transposed, with the scale matrix
// cut to 13 bits; the first pass keeps 16 bits, the second rounds.
@(private = "file")
idct :: proc(m: ^Mdec, src: ^[64]i32, dst: ^[64]i32) {
	tmp: [64]i32
	for row in 0 ..< 8 {
		for x in 0 ..< 8 {
			sum: i64
			for u in 0 ..< 8 {
				sum += i64(src[row * 8 + u]) * i64(m.scale[u * 8 + x] >> 3)
			}
			tmp[x * 8 + row] = i32(i16(sum >> 14))
		}
	}
	for row in 0 ..< 8 {
		for x in 0 ..< 8 {
			sum: i64
			for u in 0 ..< 8 {
				sum += i64(tmp[row * 8 + u]) * i64(m.scale[u * 8 + x] >> 3)
			}
			dst[x * 8 + row] = i32(clamp((sum + 0x8000) >> 16, -128, 127))
		}
	}
}

@(private = "file")
decode_all :: proc(m: ^Mdec) {
	pos := 0
	clear(&m.output)
	m.out_pos = 0
	for pos < len(m.input) && len(m.output) < MDEC_OUT_CAPACITY {
		if m.depth >= 2 {
			// colour macroblock: Cr, Cb, Y1..Y4
			cr, cb: [64]i32
			y: [4][64]i32
			if !decode_block(m, &pos, 1, &cr) {break}
			if !decode_block(m, &pos, 1, &cb) {break}
			ok := true
			for i in 0 ..< 4 {
				if !decode_block(m, &pos, 0, &y[i]) {
					ok = false
					break
				}
			}
			if !ok {break}
			emit_color(m, &cr, &cb, &y)
		} else {
			blk: [64]i32
			if !decode_block(m, &pos, 0, &blk) {break}
			emit_mono(m, &blk)
		}
	}
	clear(&m.input)
}

@(private = "file")
emit_color :: proc(m: ^Mdec, cr, cb: ^[64]i32, y: ^[4][64]i32) {
	pixels: [16 * 16][3]u8
	for py in 0 ..< 16 {
		for px in 0 ..< 16 {
			blk := (py / 8) * 2 + px / 8
			luma := y[blk][(py & 7) * 8 + (px & 7)]
			ci := (py / 2) * 8 + px / 2
			r_off := (1402 * cr[ci]) / 1000
			g_off := (-334 * cb[ci] - 714 * cr[ci]) / 1000
			b_off := (1772 * cb[ci]) / 1000
			conv :: proc(v: i32, signed: bool) -> u8 {
				c := clamp(v, -128, 127)
				return signed ? u8(i8(c)) : u8(c + 128)
			}
			pixels[py * 16 + px] = {
				conv(luma + r_off, m.signed),
				conv(luma + g_off, m.signed),
				conv(luma + b_off, m.signed),
			}
		}
	}
	if m.depth == 2 {
		// 24-bit: pack 3 bytes per pixel into words
		bytes: [16 * 16 * 3]u8
		for p, i in pixels {
			bytes[i * 3 + 0] = p[0]
			bytes[i * 3 + 1] = p[1]
			bytes[i * 3 + 2] = p[2]
		}
		for i := 0; i < len(bytes); i += 4 {
			append(&m.output, u32(bytes[i]) | u32(bytes[i + 1]) << 8 | u32(bytes[i + 2]) << 16 | u32(bytes[i + 3]) << 24)
		}
	} else {
		// 15-bit: two pixels per word
		for i := 0; i < len(pixels); i += 2 {
			pack :: proc(p: [3]u8, bit15: bool) -> u32 {
				v := u32(p[0] >> 3) | u32(p[1] >> 3) << 5 | u32(p[2] >> 3) << 10
				if bit15 {v |= 0x8000}
				return v
			}
			append(&m.output, pack(pixels[i], m.bit15) | pack(pixels[i + 1], m.bit15) << 16)
		}
	}
}

@(private = "file")
emit_mono :: proc(m: ^Mdec, blk: ^[64]i32) {
	vals: [64]u8
	for v, i in blk {
		c := clamp(v, -128, 127)
		vals[i] = m.signed ? u8(i8(c)) : u8(c + 128)
	}
	if m.depth == 1 {
		for i := 0; i < 64; i += 4 {
			append(&m.output, u32(vals[i]) | u32(vals[i + 1]) << 8 | u32(vals[i + 2]) << 16 | u32(vals[i + 3]) << 24)
		}
	} else {
		for i := 0; i < 64; i += 8 {
			w: u32
			for k in 0 ..< 8 {
				// 4-bit output rounds to the nearest step and saturates
				c := clamp((blk[i + k] + 8) >> 4, -8, 7)
				w |= u32(m.signed ? c & 15 : c + 8) << (u32(k) * 4)
			}
			append(&m.output, w)
		}
	}
}
