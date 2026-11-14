package nes

import "../../emu"

CPU_CLOCK     :: 1_789_773.0
CPU_CLOCK_PAL :: 1_662_607.0
SAMPLE_RATE   :: 48000

@(rodata, private = "file")
LENGTH_TABLE := [32]u8 {
	10, 254, 20, 2, 40, 4, 80, 6, 160, 8, 60, 10, 14, 12, 26, 14,
	12, 16, 24, 18, 48, 20, 96, 22, 192, 24, 72, 26, 16, 28, 32, 30,
}

@(rodata, private = "file")
DUTY_TABLE := [4][8]u8 {
	{0, 1, 0, 0, 0, 0, 0, 0},
	{0, 1, 1, 0, 0, 0, 0, 0},
	{0, 1, 1, 1, 1, 0, 0, 0},
	{1, 0, 0, 1, 1, 1, 1, 1},
}

@(rodata, private = "file")
TRIANGLE_TABLE := [32]u8 {
	15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0,
	0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
}

@(rodata, private = "file")
NOISE_PERIODS := [2][16]u16 {
	{4, 8, 16, 32, 64, 96, 128, 160, 202, 254, 380, 508, 762, 1016, 2034, 4068},
	{4, 8, 14, 30, 60, 88, 118, 148, 188, 236, 354, 472, 708, 944, 1890, 3778}, // PAL
}

@(rodata, private = "file")
DMC_RATES := [2][16]u16 {
	{428, 380, 340, 320, 286, 254, 226, 214, 190, 160, 142, 128, 106, 84, 72, 54},
	{398, 354, 316, 298, 276, 236, 210, 198, 176, 148, 132, 118, 98, 78, 66, 50}, // PAL
}

// Frame counter steps in CPU cycles: quarter, half, quarter, IRQ, last,
// IRQ end (4-step), and the 5-step mode's last step and wrap.
@(rodata, private = "file")
FRAME_STEPS := [2][8]u32 {
	{7457, 14913, 22371, 29828, 29829, 29830, 37281, 37282},
	{8313, 16627, 24939, 33252, 33253, 33254, 41565, 41566}, // PAL
}

Envelope :: struct {
	start:   bool,
	loop:    bool, // also the length counter halt flag
	constant: bool,
	volume:  u8,
	divider: u8,
	decay:   u8,
}

Pulse :: struct {
	enabled:      bool,
	duty:         u8,
	step:         u8,
	timer:        u16,
	period:       u16,
	length:       u8,
	env:          Envelope,
	sweep_enabled: bool,
	sweep_period: u8,
	sweep_negate: bool,
	sweep_shift:  u8,
	sweep_reload: bool,
	sweep_divider: u8,
	ones_complement: bool, // pulse 1 negates with one's complement
}

Triangle :: struct {
	enabled:        bool,
	control:        bool,
	linear_reload_value: u8,
	linear:         u8,
	linear_reload:  bool,
	length:         u8,
	timer:          u16,
	period:         u16,
	step:           u8,
}

Noise :: struct {
	enabled: bool,
	mode:    bool,
	shift:   u16,
	timer:   u16,
	period:  u16,
	length:  u8,
	env:     Envelope,
}

Dmc :: struct {
	enabled:     bool,
	irq_enabled: bool,
	irq:         bool,
	loop:        bool,
	rate:        u16,
	timer:       u16,
	output:      u8,
	sample_addr: u16,
	sample_len:  u16,
	addr:        u16,
	remaining:   u16,
	buffer:      u8,
	buffer_full: bool,
	shift:       u8,
	bits:        u8,
	silent:      bool,
}

Apu :: struct {
	pulse:       [2]Pulse,
	triangle:    Triangle,
	noise:       Noise,
	dmc:         Dmc,
	frame_mode5: bool,
	frame_irq_inhibit: bool,
	frame_irq:   bool,
	frame_cycle: u32,
	frame_reset_delay: u8, // $4017 writes take effect 3-4 CPU cycles later
	odd_cycle:   bool,

	// resampling
	sample_acc:   f32,
	sample_count: f32,
	sample_phase: f64,
	hp_prev_in:   f32,
	hp_prev_out:  f32,
	lp_out:       f32,
	pal:          bool,
	// Length reloads and halt-flag changes land after the current cycle's
	// length clock (index: pulse 1, pulse 2, triangle, noise).
	pending_reload: [4]u8,
	reload_dirty:   [4]bool,
	pending_halt:   [4]bool,
	halt_dirty:     [4]bool,
	length_clocked: bool,
}

@(private = "file")
pulse_table: [31]f32
@(private = "file")
tnd_table: [203]f32

@(init, private = "file")
build_mixer_tables :: proc "contextless" () {
	for i in 1 ..< len(pulse_table) {
		pulse_table[i] = 95.52 / (8128.0 / f32(i) + 100)
	}
	for i in 1 ..< len(tnd_table) {
		tnd_table[i] = 163.67 / (24329.0 / f32(i) + 100)
	}
}

@(private = "file")
region :: #force_inline proc(a: ^Apu) -> int {
	return a.pal ? 1 : 0
}

apu_reset :: proc(a: ^Apu) {
	pal := a.pal
	a^ = {}
	a.pal = pal
	a.noise.shift = 1
	a.noise.period = NOISE_PERIODS[region(a)][0]
	a.dmc.rate = DMC_RATES[region(a)][0]
	a.dmc.silent = true
	a.dmc.bits = 8
	a.pulse[0].ones_complement = true
}

// --- register writes -------------------------------------------------------

apu_write :: proc(a: ^Apu, addr: u16, v: u8) {
	switch addr {
	case 0x4000 ..= 0x4007:
		p := &a.pulse[(addr >> 2) & 1]
		switch addr & 3 {
		case 0:
			p.duty = v >> 6
			a.pending_halt[(addr >> 2) & 1] = v & 0x20 != 0
			a.halt_dirty[(addr >> 2) & 1] = true
			p.env.constant = v & 0x10 != 0
			p.env.volume = v & 0x0F
		case 1:
			p.sweep_enabled = v & 0x80 != 0
			p.sweep_period = (v >> 4) & 7
			p.sweep_negate = v & 0x08 != 0
			p.sweep_shift = v & 7
			p.sweep_reload = true
		case 2:
			p.period = (p.period & 0x700) | u16(v)
		case 3:
			p.period = (p.period & 0x0FF) | (u16(v & 7) << 8)
			if p.enabled {
				a.pending_reload[(addr >> 2) & 1] = LENGTH_TABLE[v >> 3]
				a.reload_dirty[(addr >> 2) & 1] = true
			}
			p.step = 0
			p.env.start = true
		}
	case 0x4008:
		a.pending_halt[2] = v & 0x80 != 0
		a.halt_dirty[2] = true
		a.triangle.linear_reload_value = v & 0x7F
	case 0x400A:
		a.triangle.period = (a.triangle.period & 0x700) | u16(v)
	case 0x400B:
		a.triangle.period = (a.triangle.period & 0x0FF) | (u16(v & 7) << 8)
		if a.triangle.enabled {
			a.pending_reload[2] = LENGTH_TABLE[v >> 3]
			a.reload_dirty[2] = true
		}
		a.triangle.linear_reload = true
	case 0x400C:
		a.pending_halt[3] = v & 0x20 != 0
		a.halt_dirty[3] = true
		a.noise.env.constant = v & 0x10 != 0
		a.noise.env.volume = v & 0x0F
	case 0x400E:
		a.noise.mode = v & 0x80 != 0
		a.noise.period = NOISE_PERIODS[region(a)][v & 0x0F]
	case 0x400F:
		if a.noise.enabled {
			a.pending_reload[3] = LENGTH_TABLE[v >> 3]
			a.reload_dirty[3] = true
		}
		a.noise.env.start = true
	case 0x4010:
		a.dmc.irq_enabled = v & 0x80 != 0
		a.dmc.loop = v & 0x40 != 0
		a.dmc.rate = DMC_RATES[region(a)][v & 0x0F]
		if !a.dmc.irq_enabled {a.dmc.irq = false}
	case 0x4011:
		a.dmc.output = v & 0x7F
	case 0x4012:
		a.dmc.sample_addr = 0xC000 + u16(v) * 64
	case 0x4013:
		a.dmc.sample_len = u16(v) * 16 + 1
	case 0x4015:
		a.pulse[0].enabled = v & 0x01 != 0
		a.pulse[1].enabled = v & 0x02 != 0
		a.triangle.enabled = v & 0x04 != 0
		a.noise.enabled = v & 0x08 != 0
		a.dmc.enabled = v & 0x10 != 0
		if !a.pulse[0].enabled {a.pulse[0].length = 0}
		if !a.pulse[1].enabled {a.pulse[1].length = 0}
		if !a.triangle.enabled {a.triangle.length = 0}
		if !a.noise.enabled {a.noise.length = 0}
		a.dmc.irq = false
		if !a.dmc.enabled {
			a.dmc.remaining = 0
		} else if a.dmc.remaining == 0 {
			a.dmc.addr = a.dmc.sample_addr
			a.dmc.remaining = a.dmc.sample_len
		}
	case 0x4017:
		a.frame_mode5 = v & 0x80 != 0
		a.frame_irq_inhibit = v & 0x40 != 0
		if a.frame_irq_inhibit {a.frame_irq = false}
		a.frame_reset_delay = a.odd_cycle ? 4 : 5
	}
}

apu_read_status :: proc(a: ^Apu) -> u8 {
	v: u8
	if a.pulse[0].length > 0 {v |= 0x01}
	if a.pulse[1].length > 0 {v |= 0x02}
	if a.triangle.length > 0 {v |= 0x04}
	if a.noise.length > 0 {v |= 0x08}
	if a.dmc.remaining > 0 {v |= 0x10}
	if a.frame_irq {v |= 0x40}
	if a.dmc.irq {v |= 0x80}
	a.frame_irq = false
	return v
}

// --- frame sequencer -------------------------------------------------------

@(private = "file")
clock_envelope :: proc(e: ^Envelope) {
	if e.start {
		e.start = false
		e.decay = 15
		e.divider = e.volume
		return
	}
	if e.divider > 0 {
		e.divider -= 1
		return
	}
	e.divider = e.volume
	if e.decay > 0 {
		e.decay -= 1
	} else if e.loop {
		e.decay = 15
	}
}

@(private = "file")
envelope_volume :: #force_inline proc(e: ^Envelope) -> u8 {
	return e.constant ? e.volume : e.decay
}

@(private = "file")
sweep_target :: proc(p: ^Pulse) -> int {
	change := int(p.period >> p.sweep_shift)
	if p.sweep_negate {
		return int(p.period) - change - (p.ones_complement ? 1 : 0)
	}
	return int(p.period) + change
}

@(private = "file")
pulse_muted :: proc(p: ^Pulse) -> bool {
	return p.period < 8 || sweep_target(p) > 0x7FF
}

@(private = "file")
quarter_frame :: proc(a: ^Apu) {
	clock_envelope(&a.pulse[0].env)
	clock_envelope(&a.pulse[1].env)
	clock_envelope(&a.noise.env)
	t := &a.triangle
	if t.linear_reload {
		t.linear = t.linear_reload_value
	} else if t.linear > 0 {
		t.linear -= 1
	}
	if !t.control {
		t.linear_reload = false
	}
}

@(private = "file")
half_frame :: proc(a: ^Apu) {
	a.length_clocked = true
	for &p in a.pulse {
		if p.length > 0 && !p.env.loop {p.length -= 1}
		if p.sweep_divider == 0 && p.sweep_enabled && p.sweep_shift > 0 && !pulse_muted(&p) {
			target := sweep_target(&p)
			p.period = u16(max(target, 0))
		}
		if p.sweep_divider == 0 || p.sweep_reload {
			p.sweep_divider = p.sweep_period
			p.sweep_reload = false
		} else {
			p.sweep_divider -= 1
		}
	}
	if a.triangle.length > 0 && !a.triangle.control {a.triangle.length -= 1}
	if a.noise.length > 0 && !a.noise.env.loop {a.noise.length -= 1}
}

@(private = "file")
step_frame_counter :: proc(a: ^Apu) {
	if a.frame_reset_delay > 0 {
		a.frame_reset_delay -= 1
		if a.frame_reset_delay == 0 {
			a.frame_cycle = 0
			if a.frame_mode5 {
				quarter_frame(a)
				half_frame(a)
			}
		}
	}
	a.frame_cycle += 1
	st := &FRAME_STEPS[region(a)]
	if !a.frame_mode5 {
		switch a.frame_cycle {
		case st[0], st[2]: quarter_frame(a)
		case st[1]: quarter_frame(a); half_frame(a)
		case st[3]: if !a.frame_irq_inhibit {a.frame_irq = true}
		case st[4]:
			quarter_frame(a)
			half_frame(a)
			if !a.frame_irq_inhibit {a.frame_irq = true}
		case st[5]:
			if !a.frame_irq_inhibit {a.frame_irq = true}
			a.frame_cycle = 0
		}
	} else {
		switch a.frame_cycle {
		case st[0], st[2]: quarter_frame(a)
		case st[1], st[6]: quarter_frame(a); half_frame(a)
		case st[7]: a.frame_cycle = 0
		}
	}
}

// --- per-cycle channel clocks ----------------------------------------------

// Advances the APU by one CPU cycle. DMC sample fetches go through `c`.
apu_step :: proc(c: ^Console) {
	a := &c.apu
	step_frame_counter(a)

	// Triangle runs at CPU rate.
	t := &a.triangle
	if t.timer == 0 {
		t.timer = t.period
		if t.length > 0 && t.linear > 0 && t.period >= 2 {
			t.step = (t.step + 1) & 31
		}
	} else {
		t.timer -= 1
	}

	a.odd_cycle = !a.odd_cycle
	if a.odd_cycle {
		for &p in a.pulse {
			if p.timer == 0 {
				p.timer = p.period
				p.step = (p.step + 1) & 7
			} else {
				p.timer -= 1
			}
		}
		n := &a.noise
		if n.timer == 0 {
			n.timer = n.period / 2
			bit: u16 = n.mode ? 6 : 1
			feedback := (n.shift ~ (n.shift >> bit)) & 1
			n.shift = (n.shift >> 1) | (feedback << 14)
		} else {
			n.timer -= 1
		}
	}

	step_dmc(c)
	apply_pending_length(a)
	mix_sample(c)
}

// A reload written on the cycle the counter is clocked is dropped if the
// counter was non-zero; halt changes take effect after the clock.
@(private = "file")
apply_pending_length :: proc(a: ^Apu) {
	lengths := [4]^u8{&a.pulse[0].length, &a.pulse[1].length, &a.triangle.length, &a.noise.length}
	for i in 0 ..< 4 {
		if a.reload_dirty[i] {
			a.reload_dirty[i] = false
			if !(a.length_clocked && lengths[i]^ != 0) {
				lengths[i]^ = a.pending_reload[i]
			}
		}
		if a.halt_dirty[i] {
			a.halt_dirty[i] = false
			switch i {
			case 0, 1: a.pulse[i].env.loop = a.pending_halt[i]
			case 2:    a.triangle.control = a.pending_halt[i]
			case 3:    a.noise.env.loop = a.pending_halt[i]
			}
		}
	}
	a.length_clocked = false
}

@(private = "file")
step_dmc :: proc(c: ^Console) {
	d := &c.apu.dmc
	if !d.buffer_full && d.remaining > 0 {
		d.buffer = bus_read(c, d.addr)
		c.dmc_stall += 4
		d.buffer_full = true
		d.addr = d.addr == 0xFFFF ? 0x8000 : d.addr + 1
		d.remaining -= 1
		if d.remaining == 0 {
			if d.loop {
				d.addr = d.sample_addr
				d.remaining = d.sample_len
			} else if d.irq_enabled {
				d.irq = true
			}
		}
	}
	if d.timer > 0 {
		d.timer -= 1
		return
	}
	d.timer = d.rate - 1
	if !d.silent {
		if d.shift & 1 != 0 {
			if d.output <= 125 {d.output += 2}
		} else {
			if d.output >= 2 {d.output -= 2}
		}
	}
	d.shift >>= 1
	d.bits -= 1
	if d.bits == 0 {
		d.bits = 8
		if d.buffer_full {
			d.silent = false
			d.shift = d.buffer
			d.buffer_full = false
		} else {
			d.silent = true
		}
	}
}

@(private = "file")
mix_sample :: proc(c: ^Console) {
	a := &c.apu
	p_out: [2]u8
	for &p, i in a.pulse {
		if p.length > 0 && !pulse_muted(&p) && DUTY_TABLE[p.duty][p.step] != 0 {
			p_out[i] = envelope_volume(&p.env)
		}
	}
	tri := TRIANGLE_TABLE[a.triangle.step]
	noise: u8
	if a.noise.length > 0 && a.noise.shift & 1 == 0 {
		noise = envelope_volume(&a.noise.env)
	}
	pulse := pulse_table[p_out[0] + p_out[1]]
	tnd := tnd_table[3 * int(tri) + 2 * int(noise) + int(a.dmc.output)]

	a.sample_acc += pulse + tnd + cart_audio(&c.cart)
	a.sample_count += 1
	clock := a.pal ? CPU_CLOCK_PAL : CPU_CLOCK
	a.sample_phase += SAMPLE_RATE
	if a.sample_phase < clock {
		return
	}
	a.sample_phase -= clock
	s := a.sample_acc / a.sample_count
	a.sample_acc = 0
	a.sample_count = 0

	// DC-blocking high-pass (~37 Hz) followed by a gentle low-pass.
	hp := s - a.hp_prev_in + 0.9952 * a.hp_prev_out
	a.hp_prev_in = s
	a.hp_prev_out = hp
	a.lp_out += (hp - a.lp_out) * 0.75
	out := emu.sample_to_i16(a.lp_out * 1.6)
	if c.audio != nil {
		emu.audio_push(c.audio, out, out)
	}
}

apu_irq :: #force_inline proc(a: ^Apu) -> bool {
	return a.frame_irq || a.dmc.irq
}
