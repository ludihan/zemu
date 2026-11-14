package gb

import "../../emu"

CLOCK       :: 4_194_304
SAMPLE_RATE :: 48000

@(private = "file", rodata)
DUTY := [4]u8{0b00000001, 0b10000001, 0b10000111, 0b01111110}

@(private = "file", rodata)
NOISE_DIVISORS := [8]int{8, 16, 32, 48, 64, 80, 96, 112}

Envelope :: struct {
	initial: u8,
	up:      bool,
	period:  u8,
	volume:  u8,
	timer:   u8,
}

Square :: struct {
	enabled:  bool,
	dac:      bool,
	duty:     u8,
	step:     u8,
	freq:     u16,
	timer:    int,
	length:   int,
	length_on: bool,
	env:      Envelope,
	// sweep (channel 1 only)
	sweep_period: u8,
	sweep_down:   bool,
	sweep_shift:  u8,
	sweep_timer:  u8,
	sweep_on:     bool,
	shadow:       u16,
	negated:      bool, // a negate-mode calculation happened since trigger
}

Wave :: struct {
	enabled:  bool,
	dac:      bool,
	freq:     u16,
	timer:    int,
	pos:      u8,
	length:   int,
	length_on: bool,
	shift:    u8, // output level code
	ram:      [16]u8,
}

Noise :: struct {
	enabled:  bool,
	dac:      bool,
	timer:    int,
	length:   int,
	length_on: bool,
	env:      Envelope,
	shift:    u8,
	narrow:   bool,
	divisor:  u8,
	lfsr:     u16,
}

Apu :: struct {
	sq:        [2]Square,
	wave:      Wave,
	noise:     Noise,
	nr50, nr51: u8,
	power:     bool,
	seq_timer: int,
	seq_step:  u8,
	regs:      [0x30]u8, // raw register values for read-back

	acc_l, acc_r: f32,
	acc_n:     f32,
	phase:     int,
	hp:        [2]f32, // DC blocker state: previous input, previous output
	hp_out:    [2]f32,
}

apu_reset :: proc(a: ^Apu) {
	ram := a.wave.ram
	a^ = {}
	a.wave.ram = ram
	a.power = true
	a.nr50 = 0x77
	a.nr51 = 0xF3
	a.noise.lfsr = 0x7FFF
}

// --- registers --------------------------------------------------------------

@(private = "file", rodata)
READ_MASK := [0x30]u8 {
	0x80, 0x3F, 0x00, 0xFF, 0xBF, // NR10-NR14
	0xFF, 0x3F, 0x00, 0xFF, 0xBF, // NR20-NR24
	0x7F, 0xFF, 0x9F, 0xFF, 0xBF, // NR30-NR34
	0xFF, 0xFF, 0x00, 0x00, 0xBF, // NR40-NR44
	0x00, 0x00, 0x70,             // NR50-NR52
	0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
	0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // wave RAM handled separately
}

apu_read :: proc(a: ^Apu, addr: u16) -> u8 {
	if addr >= 0xFF30 {
		return a.wave.ram[addr - 0xFF30]
	}
	i := int(addr - 0xFF10)
	if addr == 0xFF26 {
		v: u8 = 0x70
		if a.power {v |= 0x80}
		if a.sq[0].enabled {v |= 0x01}
		if a.sq[1].enabled {v |= 0x02}
		if a.wave.enabled {v |= 0x04}
		if a.noise.enabled {v |= 0x08}
		return v
	}
	return a.regs[i] | READ_MASK[i]
}

@(private = "file")
write_envelope :: proc(e: ^Envelope, v: u8) -> (dac: bool) {
	e.initial = v >> 4
	e.up = v & 0x08 != 0
	e.period = v & 0x07
	return v & 0xF8 != 0
}

@(private = "file")
trigger_envelope :: proc(e: ^Envelope) {
	e.volume = e.initial
	e.timer = e.period
}

@(private = "file")
sweep_calc :: proc(s: ^Square) -> u16 {
	delta := s.shadow >> s.sweep_shift
	if s.sweep_down {
		s.negated = true
		return s.shadow - delta
	}
	r := u32(s.shadow) + u32(delta)
	if r > 2047 {
		s.enabled = false
	}
	return u16(r)
}

// NRx4 length handling, including the extra length clock that happens when
// length is enabled (or a channel triggered) during the half of the frame
// sequencer period in which the next step does not clock length.
@(private = "file")
write_length_control :: proc(a: ^Apu, length: ^int, length_on: ^bool, enabled: ^bool, max_len: int, v: u8) {
	was_on := length_on^
	length_on^ = v & 0x40 != 0
	first_half := a.seq_step & 1 == 1
	if first_half && !was_on && length_on^ && length^ > 0 {
		length^ -= 1
		if length^ == 0 && v & 0x80 == 0 {
			enabled^ = false
		}
	}
	if v & 0x80 != 0 && length^ == 0 {
		length^ = max_len
		if first_half && length_on^ {
			length^ -= 1
		}
	}
}

apu_write :: proc(a: ^Apu, addr: u16, v: u8) {
	if addr >= 0xFF30 {
		a.wave.ram[addr - 0xFF30] = v
		return
	}
	if !a.power && addr != 0xFF26 {
		// While powered off only the DMG length counters accept writes.
		switch addr {
		case 0xFF11: a.sq[0].length = 64 - int(v & 0x3F)
		case 0xFF16: a.sq[1].length = 64 - int(v & 0x3F)
		case 0xFF1B: a.wave.length = 256 - int(v)
		case 0xFF20: a.noise.length = 64 - int(v & 0x3F)
		}
		return
	}
	i := int(addr - 0xFF10)
	a.regs[i] = v
	switch addr {
	case 0xFF10:
		s := &a.sq[0]
		s.sweep_period = (v >> 4) & 7
		s.sweep_down = v & 0x08 != 0
		s.sweep_shift = v & 7
		if !s.sweep_down && s.negated {
			s.enabled = false // leaving negate mode after using it disables the channel
		}
	case 0xFF11, 0xFF16:
		s := &a.sq[(addr - 0xFF11) / 5]
		s.duty = v >> 6
		s.length = 64 - int(v & 0x3F)
	case 0xFF12, 0xFF17:
		s := &a.sq[(addr - 0xFF12) / 5]
		s.dac = write_envelope(&s.env, v)
		if !s.dac {s.enabled = false}
	case 0xFF13, 0xFF18:
		s := &a.sq[(addr - 0xFF13) / 5]
		s.freq = (s.freq & 0x700) | u16(v)
	case 0xFF14, 0xFF19:
		n := (addr - 0xFF14) / 5
		s := &a.sq[n]
		s.freq = (s.freq & 0xFF) | u16(v & 7) << 8
		write_length_control(a, &s.length, &s.length_on, &s.enabled, 64, v)
		if v & 0x80 != 0 {
			s.enabled = s.dac
			s.negated = false
			s.timer = (2048 - int(s.freq)) * 4
			trigger_envelope(&s.env)
			if n == 0 {
				s.shadow = s.freq
				s.sweep_timer = s.sweep_period == 0 ? 8 : s.sweep_period
				s.sweep_on = s.sweep_period != 0 || s.sweep_shift != 0
				if s.sweep_shift != 0 {
					_ = sweep_calc(s)
				}
			}
		}
	case 0xFF1A:
		a.wave.dac = v & 0x80 != 0
		if !a.wave.dac {a.wave.enabled = false}
	case 0xFF1B:
		a.wave.length = 256 - int(v)
	case 0xFF1C:
		a.wave.shift = (v >> 5) & 3
	case 0xFF1D:
		a.wave.freq = (a.wave.freq & 0x700) | u16(v)
	case 0xFF1E:
		w := &a.wave
		w.freq = (w.freq & 0xFF) | u16(v & 7) << 8
		write_length_control(a, &w.length, &w.length_on, &w.enabled, 256, v)
		if v & 0x80 != 0 {
			w.enabled = w.dac
			w.timer = (2048 - int(w.freq)) * 2
			w.pos = 0
		}
	case 0xFF20:
		a.noise.length = 64 - int(v & 0x3F)
	case 0xFF21:
		a.noise.dac = write_envelope(&a.noise.env, v)
		if !a.noise.dac {a.noise.enabled = false}
	case 0xFF22:
		a.noise.shift = v >> 4
		a.noise.narrow = v & 0x08 != 0
		a.noise.divisor = v & 7
	case 0xFF23:
		n := &a.noise
		write_length_control(a, &n.length, &n.length_on, &n.enabled, 64, v)
		if v & 0x80 != 0 {
			n.enabled = n.dac
			n.timer = NOISE_DIVISORS[n.divisor] << n.shift
			n.lfsr = 0x7FFF
			trigger_envelope(&n.env)
		}
	case 0xFF24:
		a.nr50 = v
	case 0xFF25:
		a.nr51 = v
	case 0xFF26:
		on := v & 0x80 != 0
		if a.power && !on {
			// Everything resets except wave RAM and (on DMG) the length counters.
			ram := a.wave.ram
			lengths := [4]int{a.sq[0].length, a.sq[1].length, a.wave.length, a.noise.length}
			a.sq = {}
			a.wave = {}
			a.noise = {}
			a.wave.ram = ram
			a.sq[0].length, a.sq[1].length, a.wave.length, a.noise.length = lengths[0], lengths[1], lengths[2], lengths[3]
			a.nr50 = 0
			a.nr51 = 0
			a.regs = {}
		}
		if !a.power && on {
			a.seq_step = 0
		}
		a.power = on
	}
}

// --- frame sequencer -------------------------------------------------------

@(private = "file")
clock_length :: proc(a: ^Apu) {
	for &s in a.sq {
		if s.length_on && s.length > 0 {
			s.length -= 1
			if s.length == 0 {s.enabled = false}
		}
	}
	if a.wave.length_on && a.wave.length > 0 {
		a.wave.length -= 1
		if a.wave.length == 0 {a.wave.enabled = false}
	}
	if a.noise.length_on && a.noise.length > 0 {
		a.noise.length -= 1
		if a.noise.length == 0 {a.noise.enabled = false}
	}
}

@(private = "file")
clock_envelope :: proc(e: ^Envelope) {
	if e.period == 0 {
		return
	}
	if e.timer > 0 {
		e.timer -= 1
	}
	if e.timer == 0 {
		e.timer = e.period
		if e.up && e.volume < 15 {e.volume += 1}
		if !e.up && e.volume > 0 {e.volume -= 1}
	}
}

@(private = "file")
clock_sweep :: proc(s: ^Square) {
	if s.sweep_timer > 0 {
		s.sweep_timer -= 1
	}
	if s.sweep_timer != 0 {
		return
	}
	s.sweep_timer = s.sweep_period == 0 ? 8 : s.sweep_period
	if !s.sweep_on || s.sweep_period == 0 {
		return
	}
	nf := sweep_calc(s)
	if nf <= 2047 && s.sweep_shift != 0 {
		s.freq = nf
		s.shadow = nf
		_ = sweep_calc(s) // overflow check with the new value
	}
}

@(private = "file")
step_sequencer :: proc(a: ^Apu) {
	switch a.seq_step {
	case 0, 4:
		clock_length(a)
	case 2, 6:
		clock_length(a)
		clock_sweep(&a.sq[0])
	case 7:
		clock_envelope(&a.sq[0].env)
		clock_envelope(&a.sq[1].env)
		clock_envelope(&a.noise.env)
	}
	a.seq_step = (a.seq_step + 1) & 7
}

// --- per-clock update and mixing ----------------------------------------------

// Advances the APU by `cycles` 4.19 MHz clocks and pushes output samples.
apu_step :: proc(a: ^Apu, cycles: int, out: ^emu.Audio_Buffer) {
	for _ in 0 ..< cycles {
		if a.power {
			a.seq_timer += 1
			if a.seq_timer >= 8192 {
				a.seq_timer = 0
				step_sequencer(a)
			}
			for &s in a.sq {
				s.timer -= 1
				if s.timer <= 0 {
					s.timer += (2048 - int(s.freq)) * 4
					s.step = (s.step + 1) & 7
				}
			}
			w := &a.wave
			w.timer -= 1
			if w.timer <= 0 {
				w.timer += (2048 - int(w.freq)) * 2
				w.pos = (w.pos + 1) & 31
			}
			n := &a.noise
			n.timer -= 1
			if n.timer <= 0 {
				n.timer += NOISE_DIVISORS[n.divisor] << n.shift
				bit := (n.lfsr ~ (n.lfsr >> 1)) & 1
				n.lfsr = (n.lfsr >> 1) | bit << 14
				if n.narrow {
					n.lfsr = (n.lfsr & ~u16(0x40)) | bit << 6
				}
			}
		}
		mix(a, out)
	}
}

@(private = "file")
dac :: #force_inline proc(on: bool, level: u8) -> f32 {
	if !on {
		return 0
	}
	return f32(level) / 7.5 - 1
}

@(private = "file")
mix :: proc(a: ^Apu, out: ^emu.Audio_Buffer) {
	ch: [4]f32
	for s, i in a.sq {
		level: u8 = 0
		if s.enabled && (DUTY[s.duty] >> (7 - s.step)) & 1 != 0 {
			level = s.env.volume
		}
		ch[i] = dac(s.dac, level)
	}
	w := &a.wave
	sample := w.ram[w.pos >> 1]
	sample = w.pos & 1 == 0 ? sample >> 4 : sample & 0x0F
	wl: u8 = 0
	if w.enabled && w.shift != 0 {
		wl = sample >> (w.shift - 1)
	}
	ch[2] = dac(w.dac, wl)
	n := &a.noise
	nl: u8 = 0
	if n.enabled && n.lfsr & 1 == 0 {
		nl = n.env.volume
	}
	ch[3] = dac(n.dac, nl)

	l, r: f32
	for v, i in ch {
		if a.nr51 & (0x10 << uint(i)) != 0 {l += v}
		if a.nr51 & (0x01 << uint(i)) != 0 {r += v}
	}
	l *= f32((a.nr50 >> 4) & 7 + 1) / 8
	r *= f32(a.nr50 & 7 + 1) / 8
	a.acc_l += l
	a.acc_r += r
	a.acc_n += 1
	a.phase += SAMPLE_RATE
	if a.phase < CLOCK {
		return
	}
	a.phase -= CLOCK
	sl := a.acc_l / a.acc_n * 0.25
	sr := a.acc_r / a.acc_n * 0.25
	a.acc_l, a.acc_r, a.acc_n = 0, 0, 0
	// DC blocker: the GB's DACs sit at a non-zero level when idle
	samples := [2]f32{sl, sr}
	for &v, i in samples {
		y := v - a.hp[i] + 0.995 * a.hp_out[i]
		a.hp[i] = v
		a.hp_out[i] = y
		v = y
	}
	sl, sr = samples[0], samples[1]
	if out != nil {
		emu.audio_push(out, emu.sample_to_i16(sl), emu.sample_to_i16(sr))
	}
}
