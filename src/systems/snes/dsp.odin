package snes

import "core:math"

// S-DSP: eight BRR sample voices with ADSR/GAIN envelopes, noise, pitch
// modulation and an 8-tap FIR echo, producing one stereo sample every 32 SPC
// clocks (32 kHz).

Env_Mode :: enum u8 {
	Release,
	Attack,
	Decay,
	Sustain,
}

Voice :: struct {
	buf:        [12]i16, // decoded sample ring
	buf_pos:    int,
	interp_pos: int,
	brr_addr:   u16,
	brr_offset: int,
	header:     u8,
	kon_delay:  int,
	env_mode:   Env_Mode,
	env:        i32,
	output:     i32, // last output, for pitch modulation of the next voice
}

Dsp :: struct {
	regs:      [128]u8,
	voices:    [8]Voice,
	ram:       ^[0x10000]u8,
	counter:   int,
	noise:     i32,
	every_other: bool,
	kon:       u8, // latched key-on bits to process
	echo_pos:  int,
	echo_len:  int,
	fir_hist:  [2][8]i32,
	fir_pos:   int,
}

// Voice register offsets
V_VOLL   :: 0x0
V_VOLR   :: 0x1
V_PITCHL :: 0x2
V_PITCHH :: 0x3
V_SRCN   :: 0x4
V_ADSR1  :: 0x5
V_ADSR2  :: 0x6
V_GAIN   :: 0x7
V_ENVX   :: 0x8
V_OUTX   :: 0x9

// Global registers
R_MVOLL :: 0x0C
R_MVOLR :: 0x1C
R_EVOLL :: 0x2C
R_EVOLR :: 0x3C
R_KON   :: 0x4C
R_KOFF  :: 0x5C
R_FLG   :: 0x6C
R_ENDX  :: 0x7C
R_EFB   :: 0x0D
R_PMON  :: 0x2D
R_NON   :: 0x3D
R_EON   :: 0x4D
R_DIR   :: 0x5D
R_ESA   :: 0x6D
R_EDL   :: 0x7D

@(rodata, private = "file")
RATE_PERIODS := [32]int {
	0, 2048, 1536, 1280, 1024, 768, 640, 512, 384, 320, 256, 192, 160, 128, 96, 80,
	64, 48, 40, 32, 24, 20, 16, 12, 10, 8, 6, 5, 4, 3, 2, 1,
}

@(rodata, private = "file")
RATE_OFFSETS := [32]int {
	0, 0, 1040, 536, 0, 1040, 536, 0, 1040, 536, 0, 1040, 536, 0, 1040, 536,
	0, 1040, 536, 0, 1040, 536, 0, 1040, 536, 0, 1040, 536, 0, 1040, 0, 0,
}

COUNTER_RANGE :: 2048 * 5 * 3

// Gaussian interpolation kernel, generated rather than copied from hardware.
// gauss[256 + i] weighs the sample just before the interpolation point and
// gauss[i] the one two samples after it, for fraction i/256.
@(private = "file")
gauss: [512]i32

@(init, private = "file")
build_gauss :: proc "contextless" () {
	K :: proc "contextless" (d: f64) -> f64 {
		a := 1.248 // gives weights close to 1305 at d=0 and ~370 at d=1
		edge := math.exp(-4 * a)
		return 1305 * (math.exp(-d * d * a) - edge) / (1 - edge)
	}
	for j in 0 ..< 512 {
		d: f64
		if j >= 256 {
			d = f64(512 - j) / 256 // (0, 1]
		} else {
			d = 2 - f64(j) / 256   // (1, 2]
		}
		gauss[j] = i32(math.round(max(K(d), 0)))
	}
}

dsp_reset :: proc(d: ^Dsp) {
	ram := d.ram
	d^ = {}
	d.ram = ram
	d.regs[R_FLG] = 0xE0
	d.noise = 0x4000
	d.echo_len = 4
	for &v in d.voices {
		v.brr_offset = 1
	}
}

dsp_read :: proc(d: ^Dsp, addr: u8) -> u8 {
	return d.regs[addr & 0x7F]
}

dsp_write :: proc(d: ^Dsp, addr: u8, v: u8) {
	d.regs[addr] = v
	switch addr {
	case R_KON:
		d.kon |= v
	case R_ENDX:
		d.regs[R_ENDX] = 0 // any write clears it
	}
}

@(private = "file")
rate_fires :: #force_inline proc(d: ^Dsp, rate: int) -> bool {
	period := RATE_PERIODS[rate & 31]
	if period == 0 {
		return false
	}
	return (d.counter + RATE_OFFSETS[rate & 31]) % period == 0
}

@(private = "file")
clamp16 :: #force_inline proc(v: i32) -> i32 {
	return clamp(v, -32768, 32767)
}

// Decodes the next four samples of a voice's BRR stream into its ring buffer.
@(private = "file")
decode_brr :: proc(d: ^Dsp, v: ^Voice) {
	ram := d.ram
	header := v.header
	shift := u32(header >> 4)
	filter := (header >> 2) & 3
	b0 := ram[u16(v.brr_addr + u16(v.brr_offset))]
	b1 := ram[u16(v.brr_addr + u16(v.brr_offset + 1))]
	nibbles := u16(b0) << 8 | u16(b1)

	for _ in 0 ..< 4 {
		s := i32(i16(nibbles) >> 12) // top nibble, sign-extended
		nibbles <<= 4
		if shift <= 12 {
			s = (s << shift) >> 1
		} else {
			s = s < 0 ? -2048 : 0
		}
		p1 := i32(v.buf[(v.buf_pos + 11) % 12])
		p2 := i32(v.buf[(v.buf_pos + 10) % 12]) >> 1
		p1 >>= 1 // stored samples are 15-bit values shifted left by one
		switch filter {
		case 1:
			s += p1 + ((-p1) >> 4)
		case 2:
			s += (p1 << 1) + ((-(p1 * 3)) >> 5) - p2 + (p2 >> 4)
		case 3:
			s += (p1 << 1) + ((-(p1 * 13)) >> 6) - p2 + ((p2 * 3) >> 4)
		}
		s = clamp16(s)
		v.buf[v.buf_pos] = i16(s << 1)
		v.buf_pos = (v.buf_pos + 1) % 12
	}

	v.brr_offset += 2
	if v.brr_offset >= 9 {
		voice := voice_index(d, v)
		if header & 0x01 != 0 {
			d.regs[R_ENDX] |= u8(1) << uint(voice)
			if header & 0x02 != 0 {
				v.brr_addr = sample_pointer(d, voice, true)
			} else {
				v.env_mode = .Release
				v.env = 0
			}
		} else {
			v.brr_addr += 9
		}
		v.brr_offset = 1
		v.header = ram[v.brr_addr]
	}
}

@(private = "file")
voice_index :: proc(d: ^Dsp, v: ^Voice) -> int {
	for i in 0 ..< 8 {
		if &d.voices[i] == v {return i}
	}
	return 0
}

@(private = "file")
sample_pointer :: proc(d: ^Dsp, voice: int, loop: bool) -> u16 {
	srcn := u16(d.regs[voice * 0x10 + V_SRCN])
	entry := u16(d.regs[R_DIR]) * 0x100 + srcn * 4 + (loop ? 2 : 0)
	return u16(d.ram[entry]) | u16(d.ram[u16(entry + 1)]) << 8
}

@(private = "file")
key_on :: proc(d: ^Dsp, i: int) {
	v := &d.voices[i]
	v.brr_addr = sample_pointer(d, i, false)
	v.brr_offset = 1
	v.header = d.ram[v.brr_addr]
	v.buf = {}
	v.buf_pos = 0
	v.interp_pos = 0
	v.env = 0
	v.env_mode = .Attack
	v.kon_delay = 5
	d.regs[R_ENDX] &= ~(u8(1) << uint(i))
	// Prime the interpolation history with the first samples.
	decode_brr(d, v)
	decode_brr(d, v)
	decode_brr(d, v)
}

@(private = "file")
run_envelope :: proc(d: ^Dsp, v: ^Voice, base: int) {
	if v.env_mode == .Release {
		v.env = max(v.env - 8, 0)
		return
	}
	adsr1 := d.regs[base + V_ADSR1]
	adsr2 := d.regs[base + V_ADSR2]
	env := v.env
	rate: int
	step: i32
	if adsr1 & 0x80 != 0 {
		switch v.env_mode {
		case .Attack:
			rate = int(adsr1 & 0x0F) * 2 + 1
			step = rate == 31 ? 1024 : 32
		case .Decay:
			rate = int((adsr1 >> 4) & 7) * 2 + 16
			step = -(((env - 1) >> 8) + 1)
		case .Sustain:
			rate = int(adsr2 & 0x1F)
			step = -(((env - 1) >> 8) + 1)
		case .Release:
		}
	} else {
		gain := d.regs[base + V_GAIN]
		if gain & 0x80 == 0 {
			v.env = i32(gain & 0x7F) * 16
			return
		}
		rate = int(gain & 0x1F)
		switch (gain >> 5) & 3 {
		case 0: step = -32
		case 1: step = -(((env - 1) >> 8) + 1)
		case 2: step = 32
		case 3: step = env < 0x600 ? 32 : 8
		}
	}
	if !rate_fires(d, rate) {
		return
	}
	env += step
	if v.env_mode == .Attack && env > 0x7FF && adsr1 & 0x80 != 0 {
		v.env_mode = .Decay
	}
	env = clamp(env, 0, 0x7FF)
	if v.env_mode == .Decay && (env >> 8) == i32(adsr2 >> 5) {
		v.env_mode = .Sustain
	}
	v.env = env
}

@(private = "file")
interpolate :: proc(v: ^Voice) -> i32 {
	offset := v.interp_pos >> 12
	i := (v.interp_pos >> 4) & 0xFF
	base := v.buf_pos + offset // oldest of the four samples
	s0 := i32(v.buf[(base + 0) % 12])
	s1 := i32(v.buf[(base + 1) % 12])
	s2 := i32(v.buf[(base + 2) % 12])
	s3 := i32(v.buf[(base + 3) % 12])
	out := (gauss[255 - i] * s0) >> 11
	out += (gauss[511 - i] * s1) >> 11
	out += (gauss[256 + i] * s2) >> 11
	out = i32(i16(out)) // the hardware wraps here
	out += (gauss[i] * s3) >> 11
	return clamp16(out) & ~i32(1)
}

// Produces one stereo sample.
dsp_sample :: proc(d: ^Dsp) -> (left, right: i16) {
	r := &d.regs
	d.counter -= 1
	if d.counter < 0 {
		d.counter = COUNTER_RANGE - 1
	}

	flg := r[R_FLG]
	if flg & 0x80 != 0 {
		for &v in d.voices {
			v.env_mode = .Release
			v.env = 0
		}
	}

	// Key on/off are sampled every other output sample.
	d.every_other = !d.every_other
	if d.every_other {
		koff := r[R_KOFF]
		for i in 0 ..< 8 {
			bit := u8(1) << uint(i)
			if d.kon & bit != 0 {
				key_on(d, i)
			} else if koff & bit != 0 {
				d.voices[i].env_mode = .Release
			}
		}
		d.kon = 0
	}

	if rate_fires(d, int(flg & 0x1F)) {
		feedback := (d.noise << 13) ~ (d.noise << 14)
		d.noise = (feedback & 0x4000) ~ (d.noise >> 1)
	}

	main_l, main_r, echo_l, echo_r: i32
	pmon := r[R_PMON]
	non := r[R_NON]
	eon := r[R_EON]
	prev_out: i32 = 0
	for i in 0 ..< 8 {
		v := &d.voices[i]
		base := i * 0x10
		pitch := i32(r[base + V_PITCHL]) | i32(r[base + V_PITCHH] & 0x3F) << 8
		if i > 0 && pmon & (1 << uint(i)) != 0 {
			pitch += ((prev_out >> 5) * pitch) >> 10
		}

		out: i32
		if v.kon_delay > 0 {
			v.kon_delay -= 1
		} else {
			sample := non & (1 << uint(i)) != 0 ? i32(i16(d.noise << 1)) : interpolate(v)
			run_envelope(d, v, base)
			out = ((sample * v.env) >> 11) & ~i32(1)

			step := int(clamp(pitch, 0, 0x3FFF))
			v.interp_pos += step
			for v.interp_pos >= 0x4000 {
				v.interp_pos -= 0x4000
				decode_brr(d, v)
			}
		}
		v.output = out
		prev_out = out
		r[base + V_ENVX] = u8(v.env >> 4)
		r[base + V_OUTX] = u8(out >> 8)

		vl := (out * i32(i8(r[base + V_VOLL]))) >> 7
		vr := (out * i32(i8(r[base + V_VOLR]))) >> 7
		main_l = clamp16(main_l + vl)
		main_r = clamp16(main_r + vr)
		if eon & (1 << uint(i)) != 0 {
			echo_l = clamp16(echo_l + vl)
			echo_r = clamp16(echo_r + vr)
		}
	}

	// --- echo ---
	esa := u16(r[R_ESA]) << 8
	addr := esa + u16(d.echo_pos)
	ram := d.ram
	in_l := i32(i16(u16(ram[addr]) | u16(ram[u16(addr + 1)]) << 8)) >> 1
	in_r := i32(i16(u16(ram[u16(addr + 2)]) | u16(ram[u16(addr + 3)]) << 8)) >> 1
	d.fir_pos = (d.fir_pos + 1) & 7
	d.fir_hist[0][d.fir_pos] = in_l
	d.fir_hist[1][d.fir_pos] = in_r
	fir: [2]i32
	for ch in 0 ..< 2 {
		sum: i32
		for tap in 0 ..< 7 {
			coef := i32(i8(r[tap * 0x10 + 0x0F]))
			sum += (d.fir_hist[ch][(d.fir_pos + 1 + tap) & 7] * coef) >> 6
		}
		sum = i32(i16(sum))
		sum += (d.fir_hist[ch][d.fir_pos] * i32(i8(r[0x7F]))) >> 6
		fir[ch] = clamp16(sum) & ~i32(1)
	}

	out_l := clamp16(((main_l * i32(i8(r[R_MVOLL]))) >> 7) + ((fir[0] * i32(i8(r[R_EVOLL]))) >> 7))
	out_r := clamp16(((main_r * i32(i8(r[R_MVOLR]))) >> 7) + ((fir[1] * i32(i8(r[R_EVOLR]))) >> 7))

	if flg & 0x20 == 0 {
		efb := i32(i8(r[R_EFB]))
		wl := clamp16(echo_l + ((fir[0] * efb) >> 7)) & ~i32(1)
		wr := clamp16(echo_r + ((fir[1] * efb) >> 7)) & ~i32(1)
		ram[addr] = u8(wl)
		ram[u16(addr + 1)] = u8(wl >> 8)
		ram[u16(addr + 2)] = u8(wr)
		ram[u16(addr + 3)] = u8(wr >> 8)
	}
	if d.echo_pos == 0 {
		edl := int(r[R_EDL] & 0x0F)
		d.echo_len = edl == 0 ? 4 : edl * 2048
	}
	d.echo_pos += 4
	if d.echo_pos >= d.echo_len {
		d.echo_pos = 0
	}

	if flg & 0x40 != 0 {
		return 0, 0
	}
	return i16(out_l), i16(out_r)
}
