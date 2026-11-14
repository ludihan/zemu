package sms

import "core:math"

import "../../emu"

// Texas Instruments SN76489 (Sega variant): three square-wave channels and a
// noise channel, with the Game Gear's stereo panning register.

CPU_CLOCK   :: 3_579_545
SAMPLE_RATE :: 48000

Psg :: struct {
	period:    [4]u16, // tone periods; [3] holds the noise control bits
	volume:    [4]u8,  // attenuation 0 (loud) - 15 (off)
	counter:   [4]int,
	output:    [4]bool,
	lfsr:      u16,
	latched:   u8,     // channel * 2 + (1 if volume)
	stereo:    u8,     // Game Gear: bits 4-7 left, 0-3 right
	divider:   int,
	phase:     int,
	acc:       [2]f32,
	acc_n:     f32,
}

@(private = "file")
volume_table: [16]f32

@(init, private = "file")
build_volume :: proc "contextless" () {
	for i in 0 ..< 15 {
		volume_table[i] = f32(math.pow(10, -0.1 * f64(i))) // 2 dB per step
	}
	volume_table[15] = 0
}

psg_reset :: proc(p: ^Psg) {
	p^ = {}
	p.volume = {15, 15, 15, 15}
	p.lfsr = 0x8000
	p.stereo = 0xFF
}

psg_write :: proc(p: ^Psg, v: u8) {
	if v & 0x80 != 0 {
		p.latched = (v >> 4) & 7
		ch := p.latched >> 1
		if p.latched & 1 != 0 {
			p.volume[ch] = v & 0x0F
		} else if ch == 3 {
			p.period[3] = u16(v & 0x07)
			p.lfsr = 0x8000
		} else {
			p.period[ch] = (p.period[ch] & 0x3F0) | u16(v & 0x0F)
		}
		return
	}
	ch := p.latched >> 1
	if p.latched & 1 != 0 {
		p.volume[ch] = v & 0x0F
	} else if ch == 3 {
		p.period[3] = u16(v & 0x07)
		p.lfsr = 0x8000
	} else {
		p.period[ch] = (p.period[ch] & 0x00F) | u16(v & 0x3F) << 4
	}
}

// Advances by `cycles` CPU clocks and pushes 48 kHz samples.
psg_step :: proc(p: ^Psg, cycles: int, out: ^emu.Audio_Buffer) {
	for _ in 0 ..< cycles {
		p.divider += 1
		if p.divider >= 16 {
			p.divider = 0
			for ch in 0 ..< 3 {
				p.counter[ch] -= 1
				if p.counter[ch] <= 0 {
					per := int(p.period[ch])
					p.counter[ch] = per == 0 ? 1 : per
					p.output[ch] = !p.output[ch]
				}
			}
			p.counter[3] -= 1
			if p.counter[3] <= 0 {
				switch p.period[3] & 3 {
				case 0: p.counter[3] = 0x10
				case 1: p.counter[3] = 0x20
				case 2: p.counter[3] = 0x40
				case 3: p.counter[3] = max(int(p.period[2]), 1)
				}
				p.output[3] = !p.output[3]
				if p.output[3] { // the shift register clocks on one edge only
					white := p.period[3] & 4 != 0
					bit: u16 = white ? (p.lfsr ~ (p.lfsr >> 3)) & 1 : p.lfsr & 1
					p.lfsr = (p.lfsr >> 1) | bit << 15
				}
			}
		}

		l, r: f32
		for ch in 0 ..< 4 {
			high := ch == 3 ? p.lfsr & 1 != 0 : p.output[ch]
			if ch < 3 && p.period[ch] <= 1 {
				high = true // very high periods are used as a DC "sample" output
			}
			s := high ? volume_table[p.volume[ch]] : 0
			if p.stereo & (0x10 << uint(ch)) != 0 {l += s}
			if p.stereo & (0x01 << uint(ch)) != 0 {r += s}
		}
		p.acc[0] += l
		p.acc[1] += r
		p.acc_n += 1
		p.phase += SAMPLE_RATE
		if p.phase >= CPU_CLOCK {
			p.phase -= CPU_CLOCK
			sl := p.acc[0] / p.acc_n * 0.25
			sr := p.acc[1] / p.acc_n * 0.25
			p.acc = {}
			p.acc_n = 0
			if out != nil {
				emu.audio_push(out, emu.sample_to_i16(sl), emu.sample_to_i16(sr))
			}
		}
	}
}
