package gba

import "core:math"

// High-level emulation of the BIOS software interrupts, so no copyrighted
// BIOS image is needed. Each call behaves like the real routine as seen from
// the game: same results, same registers changed.

software_interrupt :: proc(c: ^Console, number: u32, return_addr: u32) {
	cpu := &c.cpu
	r := &cpu.r
	c.bios_latch = 0xE3A0_2004 // the value the real BIOS leaves on the bus
	cpu.cycles += 20
	switch number {
	case 0x00: soft_reset(c)
	case 0x01: register_ram_reset(c, r[0])
	case 0x02, 0x03: // Halt, Stop
		cpu.halted = true
	case 0x04: intr_wait(c, r[0] != 0, u16(r[1]))
	case 0x05: intr_wait(c, true, IRQ_VBLANK)
	case 0x06: div(cpu, i32(r[0]), i32(r[1]))
	case 0x07: div(cpu, i32(r[1]), i32(r[0]))
	case 0x08: r[0] = isqrt(r[0])
	case 0x09: r[0] = u32(arctan(i32(r[0])))
	case 0x0A: r[0] = u32(arctan2(i32(r[0]), i32(r[1])))
	case 0x0B: cpu_set(c, r[0], r[1], r[2])
	case 0x0C: cpu_fast_set(c, r[0], r[1], r[2])
	case 0x0D: r[0] = 0xBAAE_187F // GetBiosChecksum
	case 0x0E: bg_affine_set(c, r[0], r[1], int(r[2]))
	case 0x0F: obj_affine_set(c, r[0], r[1], int(r[2]), r[3])
	case 0x10: bit_unpack(c, r[0], r[1], r[2])
	case 0x11: lz77(c, r[0], r[1], false)
	case 0x12: lz77(c, r[0], r[1], true)
	case 0x13: huffman(c, r[0], r[1])
	case 0x14: run_length(c, r[0], r[1], false)
	case 0x15: run_length(c, r[0], r[1], true)
	case 0x16: diff_unfilter(c, r[0], r[1], false, false)
	case 0x17: diff_unfilter(c, r[0], r[1], false, true)
	case 0x18: diff_unfilter(c, r[0], r[1], true, true)
	case 0x19: // SoundBias
		level: u16 = r[0] != 0 ? 0x200 : 0
		c.sound.bias = (c.sound.bias & ~u16(0x3FF)) | level
	case 0x1F: midi_key_to_freq(c)
	case:
		// The sound driver and multiboot calls are not emulated: games that
		// use the official sound driver ship their own copy in the ROM.
	}
	_ = return_addr
}

@(private = "file")
soft_reset :: proc(c: ^Console) {
	cpu := &c.cpu
	to_ram := read8(c, 0x0300_7FFA) != 0
	for i in 0x7E00 ..< 0x8000 {
		c.iwram[i] = 0
	}
	cpu_reset(c)
	cpu.pc = to_ram ? 0x0200_0000 : 0x0800_0000
	cpu.branched = true
}

@(private = "file")
register_ram_reset :: proc(c: ^Console, flags: u32) {
	if flags & 0x01 != 0 {c.ewram = {}}
	if flags & 0x02 != 0 {
		for i in 0 ..< IWRAM_SIZE - 0x200 {c.iwram[i] = 0}
	}
	if flags & 0x04 != 0 {c.palette = {}}
	if flags & 0x08 != 0 {c.vram = {}}
	if flags & 0x10 != 0 {c.oam = {}}
	if flags & 0x80 != 0 {
		ppu_reset(&c.ppu)
		c.ppu.dispcnt = 0x0080
	}
	if flags & 0x20 != 0 || flags & 0x40 != 0 {
		if flags & 0x40 != 0 {sound_reset(&c.sound)}
	}
}

// IntrWait: halts until one of `mask`'s interrupts has been acknowledged in
// the BIOS flag word at 0x03007FF8 by the game's handler.
@(private = "file")
intr_wait :: proc(c: ^Console, discard: bool, mask: u16) {
	c.ime = true
	if discard {
		flags := read16(c, 0x0300_7FF8)
		write16(c, 0x0300_7FF8, flags & ~mask)
	}
	c.intr_wait = mask
	c.intr_wait_pc = c.cpu.pc + (c.cpu.cpsr & FLAG_T != 0 ? 2 : 4)
	c.cpu.halted = true
}

// Checks (and consumes) the flags IntrWait is waiting for.
intr_wait_done :: proc(c: ^Console) -> bool {
	flags := read16(c, 0x0300_7FF8)
	hit := flags & c.intr_wait
	if hit == 0 {
		return false
	}
	write16(c, 0x0300_7FF8, flags & ~hit)
	c.intr_wait = 0
	return true
}

@(private = "file")
div :: proc(cpu: ^Cpu, num, den: i32) {
	if den == 0 {
		// The real BIOS never returns; give something harmless instead.
		cpu.r[0] = num < 0 ? 0xFFFF_FFFF : 1
		cpu.r[1] = u32(num)
		cpu.r[3] = 1
		return
	}
	if num == min(i32) && den == -1 {
		cpu.r[0] = u32(num)
		cpu.r[1] = 0
		cpu.r[3] = u32(num)
		return
	}
	q := num / den
	cpu.r[0] = u32(q)
	cpu.r[1] = u32(num % den)
	cpu.r[3] = u32(abs(q))
}

@(private = "file")
isqrt :: proc(v: u32) -> u32 {
	r: u32 = 0
	bit: u32 = 1 << 30
	n := v
	for bit > n {bit >>= 2}
	for bit != 0 {
		if n >= r + bit {
			n -= r + bit
			r = (r >> 1) + bit
		} else {
			r >>= 1
		}
		bit >>= 2
	}
	return r
}

// Polynomial approximation used by the BIOS (1.14 fixed point in, angle out).
@(private = "file")
arctan :: proc(x: i32) -> i32 {
	a := -((x * x) >> 14)
	b := ((0xA9 * a) >> 14) + 0x390
	b = ((b * a) >> 14) + 0x91C
	b = ((b * a) >> 14) + 0xFB6
	b = ((b * a) >> 14) + 0x16AA
	b = ((b * a) >> 14) + 0x2081
	b = ((b * a) >> 14) + 0x3651
	b = ((b * a) >> 14) + 0xA2F9
	return (x * b) >> 16
}

@(private = "file")
arctan2 :: proc(x, y: i32) -> u16 {
	if y == 0 {
		return x >= 0 ? 0 : 0x8000
	}
	if x == 0 {
		return y >= 0 ? 0x4000 : 0xC000
	}
	r: i32
	if y >= 0 {
		if x >= 0 {
			if x >= y {
				r = arctan((y << 14) / x)
			} else {
				r = 0x4000 - arctan((x << 14) / y)
			}
		} else if -x >= y {
			r = arctan((y << 14) / x) + 0x8000
		} else {
			r = 0x4000 - arctan((x << 14) / y)
		}
	} else {
		if x <= 0 {
			if -x > -y {
				r = arctan((y << 14) / x) + 0x8000
			} else {
				r = 0xC000 - arctan((x << 14) / y)
			}
		} else if x >= -y {
			r = arctan((y << 14) / x) + 0x10000
		} else {
			r = 0xC000 - arctan((x << 14) / y)
		}
	}
	return u16(r)
}

@(private = "file")
cpu_set :: proc(c: ^Console, src, dst, ctl: u32) {
	count := ctl & 0x1F_FFFF
	fill := ctl & (1 << 24) != 0
	if ctl & (1 << 26) != 0 {
		s, d := src & ~u32(3), dst & ~u32(3)
		v := read32(c, s)
		for _ in 0 ..< count {
			if !fill {v = read32(c, s); s += 4}
			write32(c, d, v)
			d += 4
		}
	} else {
		s, d := src & ~u32(1), dst & ~u32(1)
		v := read16(c, s)
		for _ in 0 ..< count {
			if !fill {v = read16(c, s); s += 2}
			write16(c, d, v)
			d += 2
		}
	}
}

@(private = "file")
cpu_fast_set :: proc(c: ^Console, src, dst, ctl: u32) {
	count := (ctl & 0x1F_FFFF + 7) & ~u32(7)
	fill := ctl & (1 << 24) != 0
	s, d := src & ~u32(3), dst & ~u32(3)
	v := read32(c, s)
	for _ in 0 ..< count {
		if !fill {v = read32(c, s); s += 4}
		write32(c, d, v)
		d += 4
	}
}

@(private = "file")
bg_affine_set :: proc(c: ^Console, src, dst: u32, count: int) {
	s, d := src, dst
	for _ in 0 ..< min(count, 0x1000) {
		ox := i32(read32(c, s))
		oy := i32(read32(c, s + 4))
		cx := i32(i16(read16(c, s + 8)))
		cy := i32(i16(read16(c, s + 10)))
		sx := f64(i16(read16(c, s + 12))) / 256
		sy := f64(i16(read16(c, s + 14))) / 256
		theta := f64(read16(c, s + 16) >> 8) / 128 * math.PI
		s += 20
		// The matrix is truncated first and the start point computed from
		// the truncated values, as the BIOS does.
		a := i32(math.cos(theta) * sx * 256)
		b := i32(-math.sin(theta) * sx * 256)
		cc := i32(math.sin(theta) * sy * 256)
		dd := i32(math.cos(theta) * sy * 256)
		rx := ox - (a * cx + b * cy)
		ry := oy - (cc * cx + dd * cy)
		write16(c, d, u16(i16(a)))
		write16(c, d + 2, u16(i16(b)))
		write16(c, d + 4, u16(i16(cc)))
		write16(c, d + 6, u16(i16(dd)))
		write32(c, d + 8, u32(rx))
		write32(c, d + 12, u32(ry))
		d += 16
	}
}

@(private = "file")
obj_affine_set :: proc(c: ^Console, src, dst: u32, count: int, stride: u32) {
	s, d := src, dst
	for _ in 0 ..< min(count, 0x1000) {
		sx := f64(i16(read16(c, s))) / 256
		sy := f64(i16(read16(c, s + 2))) / 256
		theta := f64(read16(c, s + 4) >> 8) / 128 * math.PI
		s += 8
		write16(c, d, u16(i16(math.cos(theta) * sx * 256)))
		write16(c, d + stride, u16(i16(-math.sin(theta) * sx * 256)))
		write16(c, d + stride * 2, u16(i16(math.sin(theta) * sy * 256)))
		write16(c, d + stride * 3, u16(i16(math.cos(theta) * sy * 256)))
		d += stride * 4
	}
}

// --- decompression ----------------------------------------------------------

// Output helper: byte-granular for WRAM, buffered into halfwords for VRAM,
// which ignores byte writes.
@(private = "file")
Writer :: struct {
	c:     ^Console,
	addr:  u32,
	vram:  bool,
	half:  u16,
	odd:   bool,
}

@(private = "file")
put :: proc(w: ^Writer, b: u8) {
	if !w.vram {
		write8(w.c, w.addr, b)
		w.addr += 1
		return
	}
	if !w.odd {
		w.half = u16(b)
		w.odd = true
		return
	}
	w.half |= u16(b) << 8
	write16(w.c, w.addr, w.half)
	w.addr += 2
	w.odd = false
}

// Reads back an already-written output byte (LZ77 back references).
@(private = "file")
peek :: proc(w: ^Writer, back: u32) -> u8 {
	if w.vram && w.odd {
		if back == 1 {return u8(w.half)}
		return read8(w.c, w.addr - (back - 1))
	}
	return read8(w.c, w.addr - back)
}

// Decompressed sizes are capped at the largest RAM a game could target.
@(private = "file")
MAX_OUT :: 0x40000

@(private = "file")
lz77 :: proc(c: ^Console, src, dst: u32, vram: bool) {
	header := read32(c, src)
	size := min(header >> 8, MAX_OUT)
	s := src + 4
	w := Writer{c = c, addr = dst, vram = vram}
	written: u32 = 0
	for written < size {
		flags := read8(c, s)
		s += 1
		for bit := 7; bit >= 0 && written < size; bit -= 1 {
			if flags & (1 << uint(bit)) == 0 {
				put(&w, read8(c, s))
				s += 1
				written += 1
				continue
			}
			b0 := u32(read8(c, s))
			b1 := u32(read8(c, s + 1))
			s += 2
			length := (b0 >> 4) + 3
			disp := ((b0 & 0xF) << 8 | b1) + 1
			for _ in 0 ..< length {
				if written >= size {break}
				put(&w, peek(&w, disp))
				written += 1
			}
		}
	}
}

@(private = "file")
run_length :: proc(c: ^Console, src, dst: u32, vram: bool) {
	header := read32(c, src)
	size := min(header >> 8, MAX_OUT)
	s := src + 4
	w := Writer{c = c, addr = dst, vram = vram}
	written: u32 = 0
	for written < size {
		flag := read8(c, s)
		s += 1
		if flag & 0x80 != 0 {
			length := u32(flag & 0x7F) + 3
			v := read8(c, s)
			s += 1
			for _ in 0 ..< length {
				if written >= size {break}
				put(&w, v)
				written += 1
			}
		} else {
			length := u32(flag & 0x7F) + 1
			for _ in 0 ..< length {
				if written >= size {break}
				put(&w, read8(c, s))
				s += 1
				written += 1
			}
		}
	}
}

@(private = "file")
huffman :: proc(c: ^Console, src, dst: u32) {
	header := read32(c, src)
	size := min(header >> 8, MAX_OUT)
	bits := header & 0xF
	if bits != 4 && bits != 8 {
		return
	}
	tree_size := u32(read8(c, src + 4))
	root := src + 5
	s := src + 4 + (tree_size + 1) * 2
	d := dst
	out: u32 = 0
	out_bits: u32 = 0
	written: u32 = 0
	node_addr := root
	node := read8(c, root)
	for written < size {
		word := read32(c, s)
		s += 4
		for i := 31; i >= 0 && written < size; i -= 1 {
			child := (node_addr & ~u32(1)) + u32(node & 0x3F) * 2 + 2
			is_data: bool
			if (word >> uint(i)) & 1 != 0 {
				child += 1
				is_data = node & 0x40 != 0
			} else {
				is_data = node & 0x80 != 0
			}
			if !is_data {
				node_addr = child
				node = read8(c, child)
				continue
			}
			out |= u32(read8(c, child)) << out_bits
			out_bits += bits
			node_addr = root
			node = read8(c, root)
			if out_bits == 32 {
				write32(c, d, out)
				d += 4
				written += 4
				out, out_bits = 0, 0
			}
		}
	}
}

@(private = "file")
diff_unfilter :: proc(c: ^Console, src, dst: u32, sixteen: bool, vram: bool) {
	header := read32(c, src)
	size := min(header >> 8, MAX_OUT)
	s := src + 4
	if sixteen {
		d := dst
		acc: u16 = 0
		for i: u32 = 0; i < size; i += 2 {
			acc += read16(c, s)
			s += 2
			write16(c, d, acc)
			d += 2
		}
		return
	}
	w := Writer{c = c, addr = dst, vram = vram}
	acc: u8 = 0
	for _ in 0 ..< size {
		acc += read8(c, s)
		s += 1
		put(&w, acc)
	}
}

@(private = "file")
bit_unpack :: proc(c: ^Console, src, dst, info: u32) {
	length := u32(read16(c, info))
	src_width := u32(read8(c, info + 2))
	dst_width := u32(read8(c, info + 3))
	offset_word := read32(c, info + 4)
	offset := offset_word & 0x7FFF_FFFF
	zero_too := offset_word & 0x8000_0000 != 0
	switch src_width {
	case 1, 2, 4, 8:
	case: return
	}
	switch dst_width {
	case 1, 2, 4, 8, 16, 32:
	case: return
	}
	d := dst
	out: u32 = 0
	out_bits: u32 = 0
	mask := (u32(1) << src_width) - 1
	for i in 0 ..< min(length, MAX_OUT) {
		b := u32(read8(c, src + i))
		for shift: u32 = 0; shift < 8; shift += src_width {
			v := (b >> shift) & mask
			if v != 0 || zero_too {
				v += offset
			}
			if dst_width < 32 {
				v &= (u32(1) << dst_width) - 1
			}
			out |= v << out_bits
			out_bits += dst_width
			if out_bits >= 32 {
				write32(c, d, out)
				d += 4
				out, out_bits = 0, 0
			}
		}
	}
}

@(private = "file")
midi_key_to_freq :: proc(c: ^Console) {
	r := &c.cpu.r
	base := f64(read32(c, r[0] + 4))
	key := f64(r[1])
	fine := f64(r[2] & 0xFF) / 256
	r[0] = u32(base / math.pow(2, (180 - key - fine) / 12))
}
