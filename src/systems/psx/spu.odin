package psx

import "core:math"

// Sound Processing Unit: 24 ADPCM voices with ADSR envelopes, pitch
// modulation, noise and the reverb unit, plus CD audio input. Output is
// 44.1 kHz stereo.

SPU_RAM_SIZE :: 512 * 1024
VOICES       :: 24

Adsr_Phase :: enum u8 {
	Off,
	Attack,
	Decay,
	Sustain,
	Release,
}

Spu_Voice :: struct {
	vol_l, vol_r: Volume,
	pitch:       u16,
	start:       u32, // byte address
	repeat:      u32,
	adsr_lo:     u16,
	adsr_hi:     u16,
	addr:        u32, // current block
	index:       int, // sample within the current block (0..27)
	frac:        u32, // 12-bit fraction between samples
	block:       [28]i16,
	block_flags: u8,
	hist:        [2]i32, // ADPCM filter history
	prev:        [3]i16, // last samples for interpolation
	phase:       Adsr_Phase,
	level:       i32,
	adsr_count:  int,
	output:      i32, // for pitch modulation of the next voice
}

Spu :: struct {
	ram:        [SPU_RAM_SIZE]u8,
	regs:       [512]u16, // raw register file for read-back
	voices:     [VOICES]Spu_Voice,
	main_l, main_r: Volume,
	cd_vol_l, cd_vol_r: i16,
	control:    u16,
	status:     u16,
	irq_addr:   u32,
	xfer_addr:  u32,
	endx:       u32,
	pmon:       u32,
	non:        u32,
	noise_level: i32,
	noise_count: int,
	irq_hit:    bool,
	eon:        u32,
	reverb_base: u32, // start of the reverb work area in SPU RAM (bytes)
	reverb_addr: u32, // current position in the work area
	reverb_out: [2]i32,
	reverb_odd: bool,
}

@(private = "file")
gauss: [512]i32

@(init, private = "file")
build_gauss :: proc "contextless" () {
	// Same Gaussian-style kernel as the SNES DSP (generated, not dumped).
	K :: proc "contextless" (d: f64) -> f64 {
		a := 1.248
		edge := math.exp(-4 * a)
		return 1305 * (math.exp(-d * d * a) - edge) / (1 - edge)
	}
	for j in 0 ..< 512 {
		d := j >= 256 ? f64(512 - j) / 256 : 2 - f64(j) / 256
		gauss[j] = i32(math.round(max(K(d), 0)))
	}
}

spu_reset :: proc(s: ^Spu) {
	s.regs = {}
	s.voices = {}
	s.main_l = {}
	s.main_r = {}
	s.control = 0
	s.status = 0
	s.endx = 0
	s.pmon = 0
	s.non = 0
	s.noise_level = 1
}

// A volume register: either a fixed level, or (bit 15) a sweep that ramps
// the level every sample with the same rate rules as the ADSR envelope:
// bit 14 exponential, bit 13 decrease, bit 12 negative phase, bits 6-0 rate.
Volume :: struct {
	reg:   u16,
	level: i32, // magnitude, 0..0x7FFF
	count: int,
}

@(private = "file")
volume_set :: proc(v: ^Volume, reg: u16) {
	v.reg = reg
	v.count = 0
	if reg & 0x8000 == 0 {
		v.level = i32(i16(reg << 1))
	}
}

@(private = "file")
volume_tick :: proc(v: ^Volume) {
	if v.reg & 0x8000 == 0 {
		return
	}
	rate := i32(v.reg & 0x7F)
	decrease := v.reg & 0x2000 != 0
	exponential := v.reg & 0x4000 != 0
	shift := rate >> 2
	step := decrease ? -8 + (rate & 3) : 7 - (rate & 3)
	cycles := 1 << u32(max(shift - 11, 0))
	step <<= u32(max(11 - shift, 0))
	level := abs(v.level)
	if exponential && !decrease && level > 0x6000 {
		cycles *= 4
	}
	if exponential && decrease {
		step = (step * level) >> 15
	}
	v.count += 1
	if v.count < int(cycles) {
		return
	}
	v.count = 0
	level = clamp(level + step, 0, 0x7FFF)
	v.level = v.reg & 0x1000 != 0 ? -level : level
}

spu_read :: proc(s: ^Spu, p: u32) -> u16 {
	off := (p - 0x1F80_1C00) & 0x3FE
	switch off {
	case 0x19C: return u16(s.endx)
	case 0x19E: return u16(s.endx >> 16)
	case 0x1AA: return s.control
	case 0x1B8: return u16(i16(s.main_l.level))
	case 0x1BA: return u16(i16(s.main_r.level))
	case 0x1AE:
		// mode bits mirror SPUCNT; bit 7 mirrors the DMA enable, bits 8/9 the
		// DMA write/read request for the selected transfer mode
		v := (s.control & 0x3F) | (s.irq_hit ? 0x40 : 0)
		if s.control & 0x20 != 0 {v |= 0x80}
		switch (s.control >> 4) & 3 {
		case 2: v |= 0x100
		case 3: v |= 0x200
		}
		return v
	}
	if off < 0x180 {
		v := int(off >> 4)
		if off & 0xF == 0xC {
			return u16(s.voices[v].level)
		}
	}
	if off >= 0x200 && off < 0x260 {
		// current voice volumes, as the sweeps leave them
		v := &s.voices[(off - 0x200) >> 2]
		return u16(i16(off & 2 == 0 ? v.vol_l.level : v.vol_r.level))
	}
	return s.regs[off >> 1]
}

spu_write :: proc(c: ^Console, p: u32, value: u16) {
	s := &c.spu
	off := (p - 0x1F80_1C00) & 0x3FE
	s.regs[off >> 1] = value
	if off < 0x180 {
		v := &s.voices[off >> 4]
		switch off & 0xF {
		case 0x0: volume_set(&v.vol_l, value)
		case 0x2: volume_set(&v.vol_r, value)
		case 0x4: v.pitch = value
		case 0x6: v.start = u32(value) * 8
		case 0x8: v.adsr_lo = value
		case 0xA: v.adsr_hi = value
		case 0xC: v.level = i32(i16(value))
		case 0xE: v.repeat = u32(value) * 8
		}
		return
	}
	switch off {
	case 0x180: volume_set(&s.main_l, value)
	case 0x182: volume_set(&s.main_r, value)
	case 0x188: key_on(s, u32(value))
	case 0x18A: key_on(s, u32(value) << 16)
	case 0x18C: key_off(s, u32(value))
	case 0x18E: key_off(s, u32(value) << 16)
	case 0x190: s.pmon = (s.pmon & 0xFFFF_0000) | u32(value)
	case 0x192: s.pmon = (s.pmon & 0x0000_FFFF) | u32(value) << 16
	case 0x194: s.non = (s.non & 0xFFFF_0000) | u32(value)
	case 0x196: s.non = (s.non & 0x0000_FFFF) | u32(value) << 16
	case 0x198: s.eon = (s.eon & 0xFFFF_0000) | u32(value)
	case 0x19A: s.eon = (s.eon & 0x0000_FFFF) | u32(value) << 16
	case 0x1A2:
		s.reverb_base = u32(value) * 8
		s.reverb_addr = s.reverb_base
	case 0x1A4: s.irq_addr = u32(value) * 8
	case 0x1A6: s.xfer_addr = u32(value) * 8
	case 0x1A8:
		write_ram16(s, s.xfer_addr, value)
		s.xfer_addr = (s.xfer_addr + 2) & (SPU_RAM_SIZE - 1)
	case 0x1AA:
		s.control = value
		if value & 0x40 == 0 {
			s.irq_hit = false
		}
	case 0x1B0: s.cd_vol_l = i16(value)
	case 0x1B2: s.cd_vol_r = i16(value)
	}
}

@(private = "file")
write_ram16 :: proc(s: ^Spu, addr: u32, v: u16) {
	a := addr & (SPU_RAM_SIZE - 2)
	s.ram[a] = u8(v)
	s.ram[a + 1] = u8(v >> 8)
}

spu_dma_write :: proc(s: ^Spu, v: u32) {
	write_ram16(s, s.xfer_addr, u16(v))
	write_ram16(s, s.xfer_addr + 2, u16(v >> 16))
	s.xfer_addr = (s.xfer_addr + 4) & (SPU_RAM_SIZE - 1)
}

spu_dma_read :: proc(s: ^Spu) -> u32 {
	a := s.xfer_addr & (SPU_RAM_SIZE - 4)
	v := u32(s.ram[a]) | u32(s.ram[a + 1]) << 8 | u32(s.ram[a + 2]) << 16 | u32(s.ram[a + 3]) << 24
	s.xfer_addr = (s.xfer_addr + 4) & (SPU_RAM_SIZE - 1)
	return v
}

@(private = "file")
key_on :: proc(s: ^Spu, mask: u32) {
	for i in 0 ..< VOICES {
		if mask & (1 << u32(i)) == 0 {
			continue
		}
		v := &s.voices[i]
		v.addr = v.start
		v.index = 0
		v.frac = 0
		v.hist = {}
		v.prev = {}
		v.phase = .Attack
		v.level = 0
		v.adsr_count = 0
		s.endx &= ~(u32(1) << u32(i))
		decode_block(s, v)
	}
}

@(private = "file")
key_off :: proc(s: ^Spu, mask: u32) {
	for i in 0 ..< VOICES {
		if mask & (1 << u32(i)) != 0 && s.voices[i].phase != .Off {
			s.voices[i].phase = .Release
		}
	}
}

@(private = "file", rodata)
FILTER_POS := [5]i32{0, 60, 115, 98, 122}
@(private = "file", rodata)
FILTER_NEG := [5]i32{0, 0, -52, -55, -60}

@(private = "file")
decode_block :: proc(s: ^Spu, v: ^Spu_Voice) {
	a := v.addr & (SPU_RAM_SIZE - 16)
	if s.control & 0x40 != 0 && s.irq_addr >= a && s.irq_addr < a + 16 {
		s.irq_hit = true
	}
	header := s.ram[a]
	v.block_flags = s.ram[a + 1]
	shift := u32(header & 0x0F)
	if shift > 12 {shift = 9}
	filter := min(int((header >> 4) & 7), 4)
	if v.block_flags & 0x04 != 0 {
		v.repeat = a // loop start
	}
	for i in 0 ..< 28 {
		b := s.ram[a + 2 + u32(i / 2)]
		nibble := i & 1 == 0 ? b & 0x0F : b >> 4
		sample := i32(i16(u16(nibble) << 12)) >> shift
		sample += (v.hist[0] * FILTER_POS[filter] + v.hist[1] * FILTER_NEG[filter] + 32) >> 6
		sample = clamp(sample, -32768, 32767)
		v.hist[1] = v.hist[0]
		v.hist[0] = sample
		v.block[i] = i16(sample)
	}
}

@(private = "file")
envelope_step :: proc(v: ^Spu_Voice, rate: i32, decrease, exponential: bool) {
	shift := rate >> 2
	step_raw := rate & 3
	step := decrease ? -8 + step_raw : 7 - step_raw
	cycles := 1 << u32(max(shift - 11, 0))
	step <<= u32(max(11 - shift, 0))
	if exponential && !decrease && v.level > 0x6000 {
		cycles *= 4
	}
	if exponential && decrease {
		step = (step * v.level) >> 15
	}
	v.adsr_count += 1
	if v.adsr_count < int(cycles) {
		return
	}
	v.adsr_count = 0
	v.level = clamp(v.level + step, 0, 0x7FFF)
}

@(private = "file")
run_adsr :: proc(v: ^Spu_Voice) {
	switch v.phase {
	case .Off:
	case .Attack:
		envelope_step(v, i32((v.adsr_lo >> 8) & 0x7F), false, v.adsr_lo & 0x8000 != 0)
		if v.level >= 0x7FFF {
			v.phase = .Decay
		}
	case .Decay:
		envelope_step(v, i32((v.adsr_lo >> 4) & 0xF) << 2, true, true)
		sustain := (i32(v.adsr_lo & 0xF) + 1) * 0x800
		if v.level <= sustain {
			v.phase = .Sustain
		}
	case .Sustain:
		envelope_step(v, i32((v.adsr_hi >> 6) & 0x7F), v.adsr_hi & 0x4000 != 0, v.adsr_hi & 0x8000 != 0)
	case .Release:
		envelope_step(v, i32(v.adsr_hi & 0x1F) << 2, true, v.adsr_hi & 0x20 != 0)
		if v.level == 0 {
			v.phase = .Off
		}
	}
}

@(private = "file")
step_noise :: proc(s: ^Spu) {
	shift := int((s.control >> 10) & 0xF)
	step := int((s.control >> 8) & 3) + 4
	s.noise_count += step
	limit := 0x20000 >> u32(shift)
	if s.noise_count < limit {
		return
	}
	s.noise_count -= limit
	bit := ((s.noise_level >> 15) ~ (s.noise_level >> 12) ~ (s.noise_level >> 11) ~ (s.noise_level >> 10) ~ 1) & 1
	s.noise_level = ((s.noise_level << 1) | bit) & 0xFFFF
}

// Produces one stereo output sample.
spu_sample :: proc(c: ^Console) -> (i16, i16) {
	s := &c.spu
	step_noise(s)
	sum_l, sum_r: i32
	rev_l, rev_r: i32 // input to the reverb unit (voices with EON set)
	enabled := s.control & 0x8000 != 0
	prev_out: i32 = 0
	for i in 0 ..< VOICES {
		v := &s.voices[i]
		volume_tick(&v.vol_l)
		volume_tick(&v.vol_r)
		if v.phase == .Off {
			v.output = 0
			prev_out = 0
			continue
		}
		step := u32(v.pitch)
		if i > 0 && s.pmon & (1 << u32(i)) != 0 {
			factor := prev_out + 0x8000
			step = u32(clamp((i32(step) * factor) >> 15, 0, 0xFFFF))
		}
		step = min(step, 0x3FFF)

		frac := v.frac >> 4
		cur := v.block[v.index]
		// The kernel's four taps sum to about 2048, so >> 11 keeps unity gain.
		raw: i32
		raw += (gauss[255 - frac] * i32(v.prev[0])) >> 11
		raw += (gauss[511 - frac] * i32(v.prev[1])) >> 11
		raw += (gauss[256 + frac] * i32(v.prev[2])) >> 11
		raw += (gauss[frac] * i32(cur)) >> 11
		raw = clamp(raw, -32768, 32767)
		if s.non & (1 << u32(i)) != 0 {
			raw = i32(i16(u16(s.noise_level)))
		}
		run_adsr(v)
		out := (raw * v.level) >> 15
		v.output = out
		prev_out = out
		vl := (out * v.vol_l.level) >> 15
		vr := (out * v.vol_r.level) >> 15
		sum_l += vl
		sum_r += vr
		if s.eon & (1 << u32(i)) != 0 {
			rev_l += vl
			rev_r += vr
		}

		v.frac += step
		for v.frac >= 0x1000 {
			v.frac -= 0x1000
			// shift the interpolation history by one sample
			v.prev[0] = v.prev[1]
			v.prev[1] = v.prev[2]
			v.prev[2] = v.block[v.index]
			v.index += 1
			if v.index >= 28 {
				v.index = 0
				if v.block_flags & 0x01 != 0 {
					s.endx |= 1 << u32(i)
					v.addr = v.repeat
					if v.block_flags & 0x02 == 0 {
						v.phase = .Off
						v.level = 0
					}
				} else {
					v.addr = (v.addr + 16) & (SPU_RAM_SIZE - 1)
				}
				decode_block(s, v)
			}
		}
	}

	if s.control & 0x0001 != 0 {
		cl, cr := cdrom_audio_sample(&c.cdrom)
		sum_l += (cl * i32(s.cd_vol_l)) >> 15
		sum_r += (cr * i32(s.cd_vol_r)) >> 15
	} else {
		_, _ = cdrom_audio_sample(&c.cdrom) // keep the CD stream moving
	}
	volume_tick(&s.main_l)
	volume_tick(&s.main_r)
	if s.irq_hit && s.control & 0x40 != 0 {
		request_irq(c, .Spu)
		s.irq_hit = false
		s.status |= 0x40
	}
	if !enabled || s.control & 0x4000 == 0 {
		return 0, 0 // SPU disabled or muted
	}
	// The reverb unit runs at 22.05 kHz; its output is held in between.
	s.reverb_odd = !s.reverb_odd
	if s.reverb_odd {
		run_reverb(s, clamp(rev_l, -32768, 32767), clamp(rev_r, -32768, 32767))
	}
	sum_l += s.reverb_out[0]
	sum_r += s.reverb_out[1]
	l := clamp((sum_l * s.main_l.level) >> 15, -32768, 32767)
	r := clamp((sum_r * s.main_r.level) >> 15, -32768, 32767)
	return i16(l), i16(r)
}

// --- reverb ------------------------------------------------------------------

// Reverb registers at $1F801DC0, in order.
Reverb_Reg :: enum u32 {
	dAPF1, dAPF2, vIIR, vCOMB1, vCOMB2, vCOMB3, vCOMB4, vWALL, vAPF1, vAPF2,
	mLSAME, mRSAME, mLCOMB1, mRCOMB1, mLCOMB2, mRCOMB2, dLSAME, dRSAME,
	mLDIFF, mRDIFF, mLCOMB3, mRCOMB3, mLCOMB4, mRCOMB4, dLDIFF, dRDIFF,
	mLAPF1, mRAPF1, mLAPF2, mRAPF2, vLIN, vRIN,
}

@(private = "file")
rreg :: #force_inline proc(s: ^Spu, r: Reverb_Reg) -> u32 {
	return u32(s.regs[(0x1C0 >> 1) + u32(r)])
}

@(private = "file")
rvol :: #force_inline proc(s: ^Spu, r: Reverb_Reg) -> i32 {
	return i32(i16(s.regs[(0x1C0 >> 1) + u32(r)]))
}

// Address of a work-area entry: offsets are in 8-byte units relative to the
// current position and wrap inside [reverb_base, end of SPU RAM).
@(private = "file")
reverb_address :: proc(s: ^Spu, offset: u32) -> u32 {
	base := s.reverb_base
	if base >= SPU_RAM_SIZE {
		return 0
	}
	span := SPU_RAM_SIZE - base
	rel := (s.reverb_addr - base + offset) % span
	return (base + rel) & (SPU_RAM_SIZE - 2)
}

@(private = "file")
rload :: proc(s: ^Spu, r: Reverb_Reg, minus: u32 = 0) -> i32 {
	a := reverb_address(s, rreg(s, r) * 8 - minus)
	return i32(i16(u16(s.ram[a]) | u16(s.ram[a + 1]) << 8))
}

@(private = "file")
rstore :: proc(s: ^Spu, r: Reverb_Reg, v: i32) {
	if s.control & 0x80 == 0 {
		return // reverb writes are disabled
	}
	a := reverb_address(s, rreg(s, r) * 8)
	c := u16(i16(clamp(v, -32768, 32767)))
	s.ram[a] = u8(c)
	s.ram[a + 1] = u8(c >> 8)
}

@(private = "file")
mul :: #force_inline proc(a, b: i32) -> i32 {
	return (a * b) >> 15
}

@(private = "file")
run_reverb :: proc(s: ^Spu, in_l, in_r: i32) {
	if s.reverb_base == 0 && s.control & 0x80 == 0 {
		s.reverb_out = {}
		return
	}
	lin := mul(in_l, rvol(s, .vLIN))
	rin := mul(in_r, rvol(s, .vRIN))
	wall := rvol(s, .vWALL)
	iir := rvol(s, .vIIR)

	// same-side and different-side reflections
	reflect :: proc(s: ^Spu, dst, src: Reverb_Reg, input, wall, iir: i32) {
		prev := rload(s, dst, 2)
		v := mul(input + mul(rload(s, src), wall) - prev, iir) + prev
		rstore(s, dst, v)
	}
	reflect(s, .mLSAME, .dLSAME, lin, wall, iir)
	reflect(s, .mRSAME, .dRSAME, rin, wall, iir)
	reflect(s, .mLDIFF, .dRDIFF, lin, wall, iir)
	reflect(s, .mRDIFF, .dLDIFF, rin, wall, iir)

	// early echo (comb filters)
	c1, c2, c3, c4 := rvol(s, .vCOMB1), rvol(s, .vCOMB2), rvol(s, .vCOMB3), rvol(s, .vCOMB4)
	lout := mul(c1, rload(s, .mLCOMB1)) + mul(c2, rload(s, .mLCOMB2)) + mul(c3, rload(s, .mLCOMB3)) + mul(c4, rload(s, .mLCOMB4))
	rout := mul(c1, rload(s, .mRCOMB1)) + mul(c2, rload(s, .mRCOMB2)) + mul(c3, rload(s, .mRCOMB3)) + mul(c4, rload(s, .mRCOMB4))

	// late reverb: two all-pass filters
	all_pass :: proc(s: ^Spu, x: i32, m: Reverb_Reg, d: Reverb_Reg, vol: i32) -> i32 {
		delayed := rload(s, m, rreg(s, d) * 8)
		x1 := clamp(x - mul(vol, delayed), -32768, 32767)
		rstore(s, m, x1)
		return mul(x1, vol) + delayed
	}
	apf1, apf2 := rvol(s, .vAPF1), rvol(s, .vAPF2)
	lout = all_pass(s, clamp(lout, -32768, 32767), .mLAPF1, .dAPF1, apf1)
	rout = all_pass(s, clamp(rout, -32768, 32767), .mRAPF1, .dAPF1, apf1)
	lout = all_pass(s, clamp(lout, -32768, 32767), .mLAPF2, .dAPF2, apf2)
	rout = all_pass(s, clamp(rout, -32768, 32767), .mRAPF2, .dAPF2, apf2)

	out_l := i32(i16(s.regs[0x184 >> 1]))
	out_r := i32(i16(s.regs[0x186 >> 1]))
	s.reverb_out = {clamp(mul(lout, out_l), -32768, 32767), clamp(mul(rout, out_r), -32768, 32767)}

	// advance through the work area
	next := (s.reverb_addr + 2) & (SPU_RAM_SIZE - 2)
	s.reverb_addr = max(s.reverb_base, next)
}
