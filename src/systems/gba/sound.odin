package gba

import "../../emu"
import gb "../gb"

// Sound: the four Game Boy channels (reusing the gb package's APU, which is
// clocked at the same 4.19 MHz) plus the two Direct Sound FIFOs fed by DMA
// and timed by timer 0 or 1.

Fifo :: struct {
	data:  [32]i8,
	read:  int,
	count: int,
	level: i8, // sample currently being output
}

Sound :: struct {
	psg:       gb.Apu,
	fifo:      [2]Fifo,
	cnt_h:     u16, // SOUNDCNT_H
	bias:      u16, // SOUNDBIAS
	sub:       int, // CPU cycles not yet given to the PSG
	scratch:   emu.Audio_Buffer, // PSG samples waiting to be mixed
}

sound_reset :: proc(s: ^Sound) {
	s^ = {}
	s.psg.cgb = true // the GBA has the CGB wave RAM behaviour, without the DMG quirks
	gb.apu_reset(&s.psg)
	gb.apu_write(&s.psg, 0xFF26, 0x00) // the GBA starts with sound off
	s.bias = 0x200
}

// Byte offsets 0x60-0x9F to Game Boy register addresses (0 = none).
@(private = "file", rodata)
GB_REG := [0x40]u16 {
	0xFF10, 0, 0xFF11, 0xFF12, 0xFF13, 0xFF14, 0, 0,
	0xFF16, 0xFF17, 0, 0, 0xFF18, 0xFF19, 0, 0,
	0xFF1A, 0, 0xFF1B, 0xFF1C, 0xFF1D, 0xFF1E, 0, 0,
	0xFF20, 0xFF21, 0, 0, 0xFF22, 0xFF23, 0, 0,
	0xFF24, 0xFF25, 0, 0, 0xFF26, 0, 0, 0,
	0, 0, 0, 0, 0, 0, 0, 0,
	0xFF30, 0xFF31, 0xFF32, 0xFF33, 0xFF34, 0xFF35, 0xFF36, 0xFF37,
	0xFF38, 0xFF39, 0xFF3A, 0xFF3B, 0xFF3C, 0xFF3D, 0xFF3E, 0xFF3F,
}

sound_read8 :: proc(s: ^Sound, a: u32) -> u8 {
	switch a {
	case 0x82: return u8(s.cnt_h)
	case 0x83: return u8(s.cnt_h >> 8)
	case 0x88: return u8(s.bias)
	case 0x89: return u8(s.bias >> 8)
	}
	r := GB_REG[a - 0x60]
	if r == 0 {
		return 0
	}
	return gb.apu_read(&s.psg, r)
}

sound_write8 :: proc(s: ^Sound, a: u32, v: u8) {
	switch a {
	case 0x82:
		s.cnt_h = (s.cnt_h & 0xFF00) | u16(v)
		return
	case 0x83:
		s.cnt_h = (s.cnt_h & 0x00FF) | u16(v) << 8
		if v & 0x08 != 0 {s.fifo[0] = {}}
		if v & 0x80 != 0 {s.fifo[1] = {}}
		s.cnt_h &= ~u16(0x8800)
		return
	case 0x88:
		s.bias = (s.bias & 0xFF00) | u16(v)
		return
	case 0x89:
		s.bias = (s.bias & 0x00FF) | u16(v) << 8
		return
	}
	r := GB_REG[a - 0x60]
	if r != 0 {
		gb.apu_write(&s.psg, r, v)
	}
}

fifo_write8 :: proc(s: ^Sound, n: int, v: u8) {
	f := &s.fifo[n & 1]
	if f.count >= len(f.data) {
		return
	}
	f.data[(f.read + f.count) & 31] = i8(v)
	f.count += 1
}

// A timer overflowed: every FIFO clocked by it plays its next sample.
sound_timer_overflow :: proc(c: ^Console, timer: int) {
	s := &c.sound
	for n in 0 ..< 2 {
		sel := int((s.cnt_h >> (10 + 4 * uint(n))) & 1)
		if sel != timer {
			continue
		}
		f := &s.fifo[n]
		if f.count > 0 {
			f.level = f.data[f.read]
			f.read = (f.read + 1) & 31
			f.count -= 1
		}
		if f.count <= 16 {
			dma_fifo_request(c, n)
		}
	}
}

@(private = "file", rodata)
PSG_RATIO := [4]f32{0.25, 0.5, 1, 0}

sound_step :: proc(s: ^Sound, cycles: int, out: ^emu.Audio_Buffer) {
	s.sub += cycles
	n := s.sub >> 2
	if n == 0 {
		return
	}
	s.sub &= 3
	s.scratch.count = 0
	gb.apu_step(&s.psg, n, &s.scratch)
	if s.scratch.count == 0 {
		return
	}
	psg := PSG_RATIO[s.cnt_h & 3]
	ds: [2]f32
	for f, i in s.fifo {
		full := s.cnt_h & (0x04 << uint(i)) != 0
		ds[i] = f32(f.level) / 128 * (full ? 0.8 : 0.4)
	}
	l, r: f32
	if s.cnt_h & 0x0200 != 0 {l += ds[0]}
	if s.cnt_h & 0x0100 != 0 {r += ds[0]}
	if s.cnt_h & 0x2000 != 0 {l += ds[1]}
	if s.cnt_h & 0x1000 != 0 {r += ds[1]}
	samples := emu.audio_slice(&s.scratch)
	for i := 0; i + 1 < len(samples); i += 2 {
		sl := f32(samples[i]) / 32768 * psg + l
		sr := f32(samples[i + 1]) / 32768 * psg + r
		if out != nil {
			emu.audio_push(out, emu.sample_to_i16(sl), emu.sample_to_i16(sr))
		}
	}
	s.scratch.count = 0
}
