package nes

// Mappers beyond the original Nintendo boards: Konami VRC2/4/6, Sunsoft
// FME-7, MMC4, MMC5 and a handful of discrete-logic boards.

// --- Konami VRC IRQ (VRC4, VRC6) ------------------------------------------

Vrc_Irq :: struct {
	latch:     u8,
	control:   u8,
	counter:   u8,
	prescaler: int,
	pending:   bool,
}

@(private = "file")
vrc_irq_count :: proc(irq: ^Vrc_Irq) {
	if irq.counter == 0xFF {
		irq.counter = irq.latch
		irq.pending = true
	} else {
		irq.counter += 1
	}
}

// Advances the counter by one CPU cycle. In scanline mode a prescaler
// divides the CPU clock by 113.667 (341 PPU dots / 3).
vrc_irq_clock :: proc(irq: ^Vrc_Irq) {
	if irq.control & 0x02 == 0 {
		return
	}
	if irq.control & 0x04 != 0 {
		vrc_irq_count(irq)
		return
	}
	irq.prescaler -= 3
	if irq.prescaler <= 0 {
		irq.prescaler += 341
		vrc_irq_count(irq)
	}
}

vrc_irq_set_control :: proc(irq: ^Vrc_Irq, v: u8) {
	irq.control = v & 0x07
	irq.pending = false
	if v & 0x02 != 0 {
		irq.counter = irq.latch
		irq.prescaler = 341
	}
}

vrc_irq_ack :: proc(irq: ^Vrc_Irq) {
	irq.pending = false
	// bit 0 ("enable after acknowledge") is copied into the enable bit
	irq.control = (irq.control & ~u8(0x02)) | ((irq.control & 0x01) << 1)
}

// --- VRC2 / VRC4 (mappers 21, 22, 23, 25) ----------------------------------

Vrc :: struct {
	prg:      [2]u8,
	chr:      [8]u16,
	swap:     bool, // PRG swap mode (VRC4)
	irq:      Vrc_Irq,
}

// Boards wire different CPU address lines to the two register-select pins.
// Returns the register index 0-3 within a $x000 group.
@(private = "file")
vrc_register :: proc(mapper: int, a: u16) -> u16 {
	bit :: #force_inline proc(a: u16, n: uint) -> u16 {return (a >> n) & 1}
	switch mapper {
	case 21: return (bit(a, 1) | bit(a, 6)) | (bit(a, 2) | bit(a, 7)) << 1
	case 22: return bit(a, 1) | bit(a, 0) << 1
	case 23: return (bit(a, 0) | bit(a, 2)) | (bit(a, 1) | bit(a, 3)) << 1
	case 25: return (bit(a, 1) | bit(a, 3)) | (bit(a, 0) | bit(a, 2)) << 1
	case 26: return bit(a, 1) | bit(a, 0) << 1
	}
	return a & 3
}

vrc4_reset :: proc(cart: ^Cartridge) {
	cart.vrc = {}
	vrc4_update(cart)
}

@(private = "file")
vrc4_update :: proc(cart: ^Cartridge) {
	v := &cart.vrc
	if v.swap {
		cart_set_prg(cart, 0, -2, PRG_SLOT)
		cart_set_prg(cart, 2, int(v.prg[0]), PRG_SLOT)
	} else {
		cart_set_prg(cart, 0, int(v.prg[0]), PRG_SLOT)
		cart_set_prg(cart, 2, -2, PRG_SLOT)
	}
	cart_set_prg(cart, 1, int(v.prg[1]), PRG_SLOT)
	cart_set_prg(cart, 3, -1, PRG_SLOT)
	for bank, i in v.chr {
		b := int(bank)
		if cart.mapper == 22 {
			b >>= 1 // VRC2a ignores the lowest CHR bit
		}
		cart_set_chr(cart, i, b, CHR_SLOT)
	}
}

vrc4_write :: proc(cart: ^Cartridge, addr: u16, value: u8) {
	v := &cart.vrc
	r := vrc_register(cart.mapper, addr)
	switch addr & 0xF000 {
	case 0x8000:
		v.prg[0] = value & 0x1F
	case 0x9000:
		if r < 2 {
			if cart.mapper == 22 {
				cart_set_mirroring(cart, value & 1 != 0 ? .Horizontal : .Vertical)
			} else {
				switch value & 3 {
				case 0: cart_set_mirroring(cart, .Vertical)
				case 1: cart_set_mirroring(cart, .Horizontal)
				case 2: cart_set_mirroring(cart, .Single_Low)
				case 3: cart_set_mirroring(cart, .Single_High)
				}
			}
		} else if cart.mapper != 22 {
			v.swap = value & 0x02 != 0
		}
	case 0xA000:
		v.prg[1] = value & 0x1F
	case 0xB000 ..= 0xE000:
		i := int((addr & 0xF000) - 0xB000) >> 11 | int(r >> 1)
		if r & 1 == 0 {
			v.chr[i] = (v.chr[i] & 0x1F0) | u16(value & 0x0F)
		} else {
			v.chr[i] = (v.chr[i] & 0x00F) | u16(value & 0x1F) << 4
		}
	case 0xF000:
		switch r {
		case 0: v.irq.latch = (v.irq.latch & 0xF0) | (value & 0x0F)
		case 1: v.irq.latch = (v.irq.latch & 0x0F) | (value << 4)
		case 2: vrc_irq_set_control(&v.irq, value)
		case 3: vrc_irq_ack(&v.irq)
		}
	}
	cart.irq = v.irq.pending
	vrc4_update(cart)
}

// --- VRC6 (mappers 24, 26) with expansion audio ---------------------------

Vrc6_Pulse :: struct {
	volume:   u8,
	duty:     u8,
	constant: bool,
	period:   u16,
	enabled:  bool,
	timer:    u16,
	step:     u8,
}

Vrc6_Saw :: struct {
	rate:     u8,
	period:   u16,
	enabled:  bool,
	timer:    u16,
	step:     u8,
	acc:      u8,
}

Vrc6 :: struct {
	prg16:  u8,
	prg8:   u8,
	chr:    [8]u8,
	irq:    Vrc_Irq,
	halt:   bool,
	pulse:  [2]Vrc6_Pulse,
	saw:    Vrc6_Saw,
}

vrc6_reset :: proc(cart: ^Cartridge) {
	cart.vrc6 = {}
	vrc6_update(cart)
}

@(private = "file")
vrc6_update :: proc(cart: ^Cartridge) {
	v := &cart.vrc6
	cart_set_prg(cart, 0, int(v.prg16), 0x4000)
	cart_set_prg(cart, 2, int(v.prg8), PRG_SLOT)
	cart_set_prg(cart, 3, -1, PRG_SLOT)
	for bank, i in v.chr {
		cart_set_chr(cart, i, int(bank), CHR_SLOT)
	}
}

vrc6_write :: proc(cart: ^Cartridge, addr: u16, value: u8) {
	v := &cart.vrc6
	r := vrc_register(cart.mapper, addr)
	switch addr & 0xF000 {
	case 0x8000:
		v.prg16 = value & 0x0F
	case 0x9000, 0xA000:
		if addr & 0xF000 == 0x9000 && r == 3 {
			v.halt = value & 0x01 != 0
			break
		}
		p := &v.pulse[(addr >> 12) - 9]
		switch r {
		case 0:
			p.volume = value & 0x0F
			p.duty = (value >> 4) & 7
			p.constant = value & 0x80 != 0
		case 1:
			p.period = (p.period & 0xF00) | u16(value)
		case 2:
			p.period = (p.period & 0x0FF) | u16(value & 0x0F) << 8
			p.enabled = value & 0x80 != 0
			if !p.enabled {p.step = 0}
		}
	case 0xB000:
		s := &v.saw
		switch r {
		case 0: s.rate = value & 0x3F
		case 1: s.period = (s.period & 0xF00) | u16(value)
		case 2:
			s.period = (s.period & 0x0FF) | u16(value & 0x0F) << 8
			s.enabled = value & 0x80 != 0
			if !s.enabled {
				s.step = 0
				s.acc = 0
			}
		case 3:
			switch (value >> 2) & 3 {
			case 0: cart_set_mirroring(cart, .Vertical)
			case 1: cart_set_mirroring(cart, .Horizontal)
			case 2: cart_set_mirroring(cart, .Single_Low)
			case 3: cart_set_mirroring(cart, .Single_High)
			}
		}
	case 0xC000:
		v.prg8 = value & 0x1F
	case 0xD000, 0xE000:
		v.chr[int((addr & 0xF000) - 0xD000) >> 10 | int(r)] = value
	case 0xF000:
		switch r {
		case 0: v.irq.latch = value
		case 1: vrc_irq_set_control(&v.irq, value)
		case 2: vrc_irq_ack(&v.irq)
		}
	}
	cart.irq = v.irq.pending
	vrc6_update(cart)
}

vrc6_clock :: proc(v: ^Vrc6) {
	vrc_irq_clock(&v.irq)
	if v.halt {
		return
	}
	for &p in v.pulse {
		if !p.enabled {
			continue
		}
		if p.timer == 0 {
			p.timer = p.period
			p.step = (p.step + 1) & 15
		} else {
			p.timer -= 1
		}
	}
	s := &v.saw
	if s.enabled {
		if s.timer == 0 {
			s.timer = s.period
			s.step += 1
			if s.step & 1 == 0 {
				s.acc += s.rate // every other clock
			}
			if s.step >= 14 {
				s.step = 0
				s.acc = 0
			}
		} else {
			s.timer -= 1
		}
	}
}

// Expansion audio level, 0..61.
vrc6_output :: proc(v: ^Vrc6) -> int {
	out := 0
	for p in v.pulse {
		if p.enabled && (p.constant || p.step <= p.duty) {
			out += int(p.volume)
		}
	}
	if v.saw.enabled {
		out += int(v.saw.acc >> 3)
	}
	return out
}

// --- Sunsoft FME-7 (mapper 69) --------------------------------------------

Fme7 :: struct {
	command:     u8,
	chr:         [8]u8,
	prg:         [3]u8,
	prg6:        u8, // $6000 window: bit 6 = RAM, bit 7 = RAM enabled, low bits = ROM bank
	irq_control: u8,
	irq_counter: u16,
}

fme7_reset :: proc(cart: ^Cartridge) {
	cart.fme7 = {}
	fme7_update(cart)
}

@(private = "file")
fme7_update :: proc(cart: ^Cartridge) {
	f := &cart.fme7
	for b, i in f.chr {
		cart_set_chr(cart, i, int(b), CHR_SLOT)
	}
	for b, i in f.prg {
		cart_set_prg(cart, i, int(b), PRG_SLOT)
	}
	cart_set_prg(cart, 3, -1, PRG_SLOT)
	count := max(len(cart.prg_rom) / PRG_SLOT, 1)
	cart.prg6_offset = (int(f.prg6 & 0x3F) %% count) * PRG_SLOT
	cart.prg6_rom = f.prg6 & 0x40 == 0
}

fme7_write :: proc(cart: ^Cartridge, addr: u16, value: u8) {
	f := &cart.fme7
	switch addr & 0xE000 {
	case 0x8000:
		f.command = value & 0x0F
	case 0xA000:
		switch f.command {
		case 0x0 ..= 0x7: f.chr[f.command] = value
		case 0x8:         f.prg6 = value
		case 0x9 ..= 0xB: f.prg[f.command - 9] = value & 0x3F
		case 0xC:
			switch value & 3 {
			case 0: cart_set_mirroring(cart, .Vertical)
			case 1: cart_set_mirroring(cart, .Horizontal)
			case 2: cart_set_mirroring(cart, .Single_Low)
			case 3: cart_set_mirroring(cart, .Single_High)
			}
		case 0xD:
			f.irq_control = value
			cart.irq = false
		case 0xE: f.irq_counter = (f.irq_counter & 0xFF00) | u16(value)
		case 0xF: f.irq_counter = (f.irq_counter & 0x00FF) | u16(value) << 8
		}
		fme7_update(cart)
	}
}

fme7_clock :: proc(cart: ^Cartridge) {
	f := &cart.fme7
	if f.irq_control & 0x80 == 0 {
		return
	}
	f.irq_counter -= 1
	if f.irq_counter == 0xFFFF && f.irq_control & 0x01 != 0 {
		cart.irq = true
	}
}

// --- MMC4 (mapper 10) -------------------------------------------------------

mmc4_update :: proc(cart: ^Cartridge) {
	m := &cart.mmc2
	cart_set_prg(cart, 0, int(m.prg), 0x4000)
	cart_set_prg(cart, 2, -1, 0x4000)
	cart_set_chr(cart, 0, int(m.chr[0 + int(m.latch[0])]), 0x1000)
	cart_set_chr(cart, 4, int(m.chr[2 + int(m.latch[1])]), 0x1000)
}

// Unlike the MMC2, both halves latch on an 8-byte range.
mmc4_latch :: proc(cart: ^Cartridge, a: u16) {
	m := &cart.mmc2
	half := int(a >> 12) & 1
	switch a & 0x0FF8 {
	case 0x0FD8: m.latch[half] = 0
	case 0x0FE8: m.latch[half] = 1
	case: return
	}
	cart_set_chr(cart, 0, int(m.chr[0 + int(m.latch[0])]), 0x1000)
	cart_set_chr(cart, 4, int(m.chr[2 + int(m.latch[1])]), 0x1000)
}

// --- Discrete boards -------------------------------------------------------

// Writes to $8000-$FFFF for simple latch boards. Returns false if the
// mapper is not one of them.
discrete_write :: proc(cart: ^Cartridge, addr: u16, value: u8) -> bool {
	switch cart.mapper {
	case 34: // BNROM (NINA-001 boards use $7FFD-$7FFF instead)
		cart_set_prg(cart, 0, int(value), 0x8000)
	case 71: // Camerica
		if addr >= 0xC000 {
			cart_set_prg(cart, 0, int(value & 0x0F), 0x4000)
		} else if addr & 0xF000 == 0x9000 {
			cart_set_mirroring(cart, value & 0x10 != 0 ? .Single_High : .Single_Low)
		}
	case 180: // UNROM with the switchable bank at $C000
		cart_set_prg(cart, 2, int(value & 0x07), 0x4000)
	case 232: // Camerica Quattro
		if addr < 0xC000 {
			cart.latch = (cart.latch & 0x03) | ((value >> 1) & 0x0C)
		} else {
			cart.latch = (cart.latch & 0x0C) | (value & 0x03)
		}
		outer := int(cart.latch & 0x0C)
		cart_set_prg(cart, 0, outer | int(cart.latch & 3), 0x4000)
		cart_set_prg(cart, 2, outer | 3, 0x4000)
	case:
		return false
	}
	return true
}

// Writes below $8000 for boards with registers there. Returns true when the
// write was a mapper register (and so does not reach PRG RAM).
low_register_write :: proc(cart: ^Cartridge, addr: u16, value: u8) -> bool {
	switch cart.mapper {
	case 34:
		if cart.chr_is_ram || addr < 0x7FFD {
			return false
		}
		switch addr {
		case 0x7FFD: cart_set_prg(cart, 0, int(value & 1), 0x8000)
		case 0x7FFE: cart_set_chr(cart, 0, int(value & 0x0F), 0x1000)
		case 0x7FFF: cart_set_chr(cart, 4, int(value & 0x0F), 0x1000)
		}
		return false // NINA-001 registers are also RAM
	case 79: // NINA-03/06
		if addr >= 0x4100 && addr < 0x6000 && addr & 0x0100 != 0 {
			cart_set_prg(cart, 0, int(value >> 3) & 1, 0x8000)
			cart_set_chr(cart, 0, int(value & 0x07), 0x2000)
			return true
		}
	case 87: // Jaleco/Konami: CHR bits are swapped
		if addr >= 0x6000 && addr < 0x8000 {
			cart_set_chr(cart, 0, int((value & 1) << 1 | (value >> 1) & 1), 0x2000)
			return true
		}
	case 140: // Jaleco JF-11/14
		if addr >= 0x6000 && addr < 0x8000 {
			cart_set_prg(cart, 0, int(value >> 4) & 3, 0x8000)
			cart_set_chr(cart, 0, int(value & 0x0F), 0x2000)
			return true
		}
	}
	return false
}

// --- MMC5 (mapper 5) ---------------------------------------------------------

Mmc5 :: struct {
	prg_mode:     u8,
	chr_mode:     u8,
	exram_mode:   u8,
	nt_mapping:   u8,
	fill_tile:    u8,
	fill_attr:    u8,
	prg_regs:     [5]u8, // $5113-$5117
	chr_regs:     [12]u16, // $5120-$512B
	chr_upper:    u8,
	last_chr_b:   bool, // the last CHR register written was in the B set
	irq_target:   u8,
	irq_enabled:  bool,
	irq_pending:  bool,
	in_frame:     bool,
	line:         u8,
	mul_a, mul_b: u8,
	exram:        [1024]u8,
	// extended attribute mode: the tile last fetched from a nametable
	ext_tile:     u16,
}

mmc5_reset :: proc(cart: ^Cartridge) {
	cart.mmc5 = {}
	cart.mmc5.prg_mode = 3
	cart.mmc5.chr_mode = 3
	cart.mmc5.prg_regs[4] = 0xFF
	mmc5_update_prg(cart)
	mmc5_update_chr(cart)
}

@(private = "file")
mmc5_update_prg :: proc(cart: ^Cartridge) {
	m := &cart.mmc5
	r := &m.prg_regs
	switch m.prg_mode {
	case 0:
		cart_set_prg(cart, 0, int(r[4] & 0x7C) >> 2, 0x8000)
	case 1:
		cart_set_prg(cart, 0, int(r[2] & 0x7E) >> 1, 0x4000)
		cart_set_prg(cart, 2, int(r[4] & 0x7E) >> 1, 0x4000)
	case 2:
		cart_set_prg(cart, 0, int(r[2] & 0x7E) >> 1, 0x4000)
		cart_set_prg(cart, 2, int(r[3] & 0x7F), PRG_SLOT)
		cart_set_prg(cart, 3, int(r[4] & 0x7F), PRG_SLOT)
	case 3:
		for i in 0 ..< 4 {
			cart_set_prg(cart, i, int(r[1 + i] & 0x7F), PRG_SLOT)
		}
	}
}

@(private = "file")
set_chr_b :: proc(cart: ^Cartridge, slot: int, bank: int, size: int) {
	count := max(len(cart.chr) / size, 1)
	b := bank %% count
	for i in 0 ..< size / CHR_SLOT {
		if slot + i < len(cart.chr_map_b) {
			cart.chr_map_b[slot + i] = (b * size + i * CHR_SLOT) %% len(cart.chr)
		}
	}
}

@(private = "file")
mmc5_update_chr :: proc(cart: ^Cartridge) {
	m := &cart.mmc5
	r := &m.chr_regs
	switch m.chr_mode {
	case 0:
		cart_set_chr(cart, 0, int(r[7]), 0x2000)
		set_chr_b(cart, 0, int(r[11]), 0x2000)
	case 1:
		cart_set_chr(cart, 0, int(r[3]), 0x1000)
		cart_set_chr(cart, 4, int(r[7]), 0x1000)
		set_chr_b(cart, 0, int(r[11]), 0x1000)
		set_chr_b(cart, 4, int(r[11]), 0x1000)
	case 2:
		for i in 0 ..< 4 {
			cart_set_chr(cart, i * 2, int(r[i * 2 + 1]), 0x800)
		}
		set_chr_b(cart, 0, int(r[9]), 0x800)
		set_chr_b(cart, 2, int(r[11]), 0x800)
		set_chr_b(cart, 4, int(r[9]), 0x800)
		set_chr_b(cart, 6, int(r[11]), 0x800)
	case 3:
		for i in 0 ..< 8 {
			cart_set_chr(cart, i, int(r[i]), CHR_SLOT)
		}
		for i in 0 ..< 4 {
			set_chr_b(cart, i, int(r[8 + i]), CHR_SLOT)
			set_chr_b(cart, i + 4, int(r[8 + i]), CHR_SLOT)
		}
	}
}

mmc5_cpu_read :: proc(cart: ^Cartridge, addr: u16, open_bus: u8) -> (u8, bool) {
	m := &cart.mmc5
	switch addr {
	case 0x5204:
		v: u8
		if m.irq_pending {v |= 0x80}
		if m.in_frame {v |= 0x40}
		m.irq_pending = false
		cart.irq = false
		return v, true
	case 0x5205:
		return u8(u16(m.mul_a) * u16(m.mul_b)), true
	case 0x5206:
		return u8((u16(m.mul_a) * u16(m.mul_b)) >> 8), true
	case 0x5C00 ..= 0x5FFF:
		if m.exram_mode >= 2 {
			return m.exram[addr - 0x5C00], true
		}
		return open_bus, true
	}
	return 0, false
}

mmc5_cpu_write :: proc(cart: ^Cartridge, addr: u16, value: u8) {
	m := &cart.mmc5
	switch addr {
	case 0x5100: m.prg_mode = value & 3; mmc5_update_prg(cart)
	case 0x5101: m.chr_mode = value & 3; mmc5_update_chr(cart)
	case 0x5104: m.exram_mode = value & 3
	case 0x5105: m.nt_mapping = value
	case 0x5106: m.fill_tile = value
	case 0x5107: m.fill_attr = value & 3
	case 0x5113 ..= 0x5117:
		m.prg_regs[addr - 0x5113] = value
		mmc5_update_prg(cart)
	case 0x5120 ..= 0x512B:
		m.chr_regs[addr - 0x5120] = u16(value) | u16(m.chr_upper) << 8
		m.last_chr_b = addr >= 0x5128
		mmc5_update_chr(cart)
	case 0x5130: m.chr_upper = value & 3
	case 0x5203: m.irq_target = value
	case 0x5204:
		m.irq_enabled = value & 0x80 != 0
		cart.irq = m.irq_enabled && m.irq_pending
	case 0x5205: m.mul_a = value
	case 0x5206: m.mul_b = value
	case 0x5C00 ..= 0x5FFF:
		if m.exram_mode != 3 {
			m.exram[addr - 0x5C00] = value
		}
	}
}

// Called by the PPU at the start of each rendered scanline (and with
// line == -1 when rendering ends for the frame).
mmc5_scanline :: proc(cart: ^Cartridge, line: int, rendering: bool) {
	m := &cart.mmc5
	if !rendering || line < 0 || line >= 240 {
		m.in_frame = false
		return
	}
	if !m.in_frame {
		m.in_frame = true
		m.line = 0
		m.irq_pending = false
		cart.irq = false
		return
	}
	m.line += 1
	if m.line == m.irq_target && m.irq_target != 0 {
		m.irq_pending = true
		if m.irq_enabled {
			cart.irq = true
		}
	}
}

// Nametable access through the MMC5's per-quadrant mapping.
mmc5_nt_read :: proc(cart: ^Cartridge, vram: []u8, addr: u16) -> u8 {
	m := &cart.mmc5
	a := addr & 0x0FFF
	quadrant := (a >> 10) & 3
	offset := a & 0x3FF
	is_attr := offset >= 0x3C0
	if !is_attr {
		m.ext_tile = offset
	} else if m.exram_mode == 1 && !cart.sprite_fetch {
		// extended attributes: palette from ExRAM, same for all four quadrants
		pal := m.exram[m.ext_tile] >> 6
		return pal | pal << 2 | pal << 4 | pal << 6
	}
	switch (m.nt_mapping >> (quadrant * 2)) & 3 {
	case 0: return vram[offset]
	case 1: return vram[0x400 + offset]
	case 2: return m.exram_mode <= 1 ? m.exram[offset] : 0
	case 3:
		if is_attr {
			a := m.fill_attr
			return a | a << 2 | a << 4 | a << 6
		}
		return m.fill_tile
	}
	return 0
}

mmc5_nt_write :: proc(cart: ^Cartridge, vram: []u8, addr: u16, value: u8) {
	m := &cart.mmc5
	a := addr & 0x0FFF
	offset := a & 0x3FF
	switch (m.nt_mapping >> (((a >> 10) & 3) * 2)) & 3 {
	case 0: vram[offset] = value
	case 1: vram[0x400 + offset] = value
	case 2: if m.exram_mode <= 1 {m.exram[offset] = value}
	}
}

mmc5_chr_read :: proc(cart: ^Cartridge, a: u16) -> u8 {
	m := &cart.mmc5
	if m.exram_mode == 1 && !cart.sprite_fetch {
		// extended attributes: a 4 KiB bank per tile from ExRAM
		bank := int(m.exram[m.ext_tile] & 0x3F) | int(m.chr_upper) << 6
		count := max(len(cart.chr) / 0x1000, 1)
		return cart.chr[(bank %% count) * 0x1000 + int(a & 0x0FFF)]
	}
	use_b: bool
	if cart.sprite_16 {
		use_b = !cart.sprite_fetch
	} else {
		use_b = m.last_chr_b
	}
	slot := (a >> 10) & 7
	offset := use_b ? cart.chr_map_b[slot] : cart.chr_map[slot]
	return cart.chr[offset + int(a & 0x3FF)]
}
