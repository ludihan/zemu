package nes

import "base:runtime"
import "../../emu"

Mirroring :: enum u8 {
	Horizontal,
	Vertical,
	Single_Low,
	Single_High,
	Four_Screen,
}

PRG_SLOT :: 0x2000 // 8 KiB CPU windows at $8000/$A000/$C000/$E000
CHR_SLOT :: 0x400  // 1 KiB PPU windows at $0000..$1FFF

Mmc1 :: struct {
	shift:            u8,
	shift_count:      u8,
	control:          u8,
	chr0, chr1:       u8,
	prg:              u8,
	last_write_cycle: u64,
}

Mmc3 :: struct {
	bank_select: u8,
	regs:        [8]u8,
	irq_latch:   u8,
	irq_counter: u8,
	irq_reload:  bool,
	irq_enabled: bool,
}

Mmc2 :: struct {
	prg:   u8,
	chr:   [4]u8, // $FD/$FE banks for the $0000 and $1000 halves
	latch: [2]u8, // per half: 0 selects the $FD bank, 1 the $FE bank
}

Cartridge :: struct {
	mapper:     int,
	prg_rom:    []u8,
	chr:        []u8, // CHR ROM, or CHR RAM when `chr_is_ram`
	chr_is_ram: bool,
	prg_ram:    [0x2000]u8,
	battery:    bool,
	mirroring:  Mirroring,
	// Byte offsets into prg_rom / chr / nametable RAM for each slot. They are
	// only ever written by the cart_set_* helpers, which reduce the bank number
	// modulo the bank count, so every lookup stays inside its slice.
	prg_map:    [4]int,
	chr_map:    [8]int,
	nt_map:     [4]int,
	irq:        bool,
	a12_high:   bool,
	a12_low_at: u64, // PPU dot at which A12 last went low
	latch:      u8, // simple discrete-logic mappers
	mmc1:       Mmc1,
	mmc3:       Mmc3,
	mmc2:       Mmc2,
}

SUPPORTED_MAPPERS :: [?]int{0, 1, 2, 3, 4, 7, 9, 11, 66}

mapper_supported :: proc(m: int) -> bool {
	for s in SUPPORTED_MAPPERS {
		if s == m {return true}
	}
	return false
}

// Parses an iNES / NES 2.0 image. The cartridge owns copies of the ROM data,
// so `rom` may be freed afterwards.
cart_load :: proc(cart: ^Cartridge, rom: []u8, allocator := context.allocator) -> emu.Load_Error {
	if len(rom) < 16 || rom[0] != 'N' || rom[1] != 'E' || rom[2] != 'S' || rom[3] != 0x1A {
		return .Bad_Header
	}
	flags6, flags7 := rom[6], rom[7]
	is_nes2 := flags7 & 0x0C == 0x08

	mapper := int(flags6 >> 4) | int(flags7 & 0xF0)
	prg_units := int(rom[4])
	chr_units := int(rom[5])
	if is_nes2 {
		mapper |= int(rom[8] & 0x0F) << 8
		// Exponent-multiplier sizes (nibble 0xF) are only used by homebrew oddities.
		if rom[9] & 0x0F != 0x0F {prg_units |= int(rom[9] & 0x0F) << 8}
		if rom[9] & 0xF0 != 0xF0 {chr_units |= int(rom[9] >> 4) << 8}
	} else if (rom[12] | rom[13] | rom[14] | rom[15]) != 0 {
		// Old dumps with "DiskDude!" garbage in the header: drop the high nibble.
		mapper &= 0x0F
	}

	if !mapper_supported(mapper) {
		return .Unsupported_Mapper
	}
	if prg_units == 0 {
		return .Bad_Header
	}

	offset := 16
	if flags6 & 0x04 != 0 {
		offset += 512 // trainer, ignored
	}
	prg_size := prg_units * 0x4000
	chr_size := chr_units * 0x2000
	if len(rom) < offset + prg_size + chr_size {
		return .Truncated
	}

	err: runtime.Allocator_Error
	cart.prg_rom, err = make([]u8, prg_size, allocator)
	if err != nil {
		return .Out_Of_Memory
	}
	copy(cart.prg_rom, rom[offset:][:prg_size])
	offset += prg_size

	if chr_size == 0 {
		cart.chr, err = make([]u8, 0x2000, allocator)
		cart.chr_is_ram = true
	} else {
		cart.chr, err = make([]u8, chr_size, allocator)
		if err == nil {
			copy(cart.chr, rom[offset:][:chr_size])
		}
	}
	if err != nil {
		delete(cart.prg_rom, allocator)
		cart.prg_rom = nil
		return .Out_Of_Memory
	}

	cart.mapper = mapper
	cart.battery = flags6 & 0x02 != 0
	switch {
	case flags6 & 0x08 != 0: cart.mirroring = .Four_Screen
	case flags6 & 0x01 != 0: cart.mirroring = .Vertical
	case:                    cart.mirroring = .Horizontal
	}
	cart_reset(cart)
	return .None
}

cart_destroy :: proc(cart: ^Cartridge, allocator := context.allocator) {
	delete(cart.prg_rom, allocator)
	delete(cart.chr, allocator)
	cart.prg_rom = nil
	cart.chr = nil
}

// --- bank helpers ----------------------------------------------------------

// Maps `size` bytes (a multiple of PRG_SLOT) starting at CPU slot `slot`.
cart_set_prg :: proc(cart: ^Cartridge, slot: int, bank: int, size: int) {
	count := max(len(cart.prg_rom) / size, 1)
	b := bank %% count
	for i in 0 ..< size / PRG_SLOT {
		if slot + i < len(cart.prg_map) {
			cart.prg_map[slot + i] = (b * size + i * PRG_SLOT) %% len(cart.prg_rom)
		}
	}
}

cart_set_chr :: proc(cart: ^Cartridge, slot: int, bank: int, size: int) {
	count := max(len(cart.chr) / size, 1)
	b := bank %% count
	for i in 0 ..< size / CHR_SLOT {
		if slot + i < len(cart.chr_map) {
			cart.chr_map[slot + i] = (b * size + i * CHR_SLOT) %% len(cart.chr)
		}
	}
}

cart_set_mirroring :: proc(cart: ^Cartridge, m: Mirroring) {
	cart.mirroring = m
	switch m {
	case .Horizontal:  cart.nt_map = {0, 0, 0x400, 0x400}
	case .Vertical:    cart.nt_map = {0, 0x400, 0, 0x400}
	case .Single_Low:  cart.nt_map = {0, 0, 0, 0}
	case .Single_High: cart.nt_map = {0x400, 0x400, 0x400, 0x400}
	case .Four_Screen: cart.nt_map = {0, 0x400, 0x800, 0xC00}
	}
}

cart_reset :: proc(cart: ^Cartridge) {
	cart.irq = false
	cart.latch = 0
	cart_set_mirroring(cart, cart.mirroring)
	cart_set_prg(cart, 0, 0, 0x4000)
	cart_set_prg(cart, 2, -1, 0x4000) // last 16 KiB
	cart_set_chr(cart, 0, 0, 0x2000)

	switch cart.mapper {
	case 1:
		cart.mmc1 = {}
		cart.mmc1.control = 0x0C
		mmc1_update(cart)
	case 4:
		cart.mmc3 = {}
		cart.mmc3.regs = {0, 2, 4, 5, 6, 7, 0, 1}
		mmc3_update(cart)
	case 7:
		cart_set_prg(cart, 0, 0, 0x8000)
		cart_set_mirroring(cart, .Single_Low)
	case 9:
		cart.mmc2 = {}
		cart.mmc2.latch = {1, 1}
		mmc2_update(cart)
	case 11, 66:
		cart_set_prg(cart, 0, 0, 0x8000)
	}
}

// --- CPU side --------------------------------------------------------------

cart_cpu_read :: proc(cart: ^Cartridge, addr: u16, open_bus: u8) -> u8 {
	switch addr {
	case 0x6000 ..= 0x7FFF:
		return cart.prg_ram[addr & 0x1FFF]
	case 0x8000 ..= 0xFFFF:
		slot := int(addr >> 13) & 3
		return cart.prg_rom[cart.prg_map[slot] + int(addr & 0x1FFF)]
	}
	return open_bus
}

cart_cpu_write :: proc(cart: ^Cartridge, addr: u16, value: u8, cpu_cycle: u64) {
	if addr >= 0x6000 && addr < 0x8000 {
		cart.prg_ram[addr & 0x1FFF] = value
		return
	}
	if addr < 0x8000 {
		return
	}
	switch cart.mapper {
	case 1:
		mmc1_write(cart, addr, value, cpu_cycle)
	case 2:
		cart_set_prg(cart, 0, int(value), 0x4000)
	case 3:
		cart_set_chr(cart, 0, int(value), 0x2000)
	case 4:
		mmc3_write(cart, addr, value)
	case 7:
		cart_set_prg(cart, 0, int(value & 0x07), 0x8000)
		cart_set_mirroring(cart, value & 0x10 != 0 ? .Single_High : .Single_Low)
	case 9:
		mmc2_write(cart, addr, value)
	case 11:
		cart_set_prg(cart, 0, int(value & 0x03), 0x8000)
		cart_set_chr(cart, 0, int(value >> 4), 0x2000)
	case 66:
		cart_set_prg(cart, 0, int(value >> 4) & 0x03, 0x8000)
		cart_set_chr(cart, 0, int(value & 0x03), 0x2000)
	}
}

// --- PPU side --------------------------------------------------------------

cart_chr_read :: proc(cart: ^Cartridge, addr: u16) -> u8 {
	a := addr & 0x1FFF
	v := cart.chr[cart.chr_map[a >> 10] + int(a & 0x3FF)]
	if cart.mapper == 9 {
		mmc2_latch(cart, a)
	}
	return v
}

cart_chr_write :: proc(cart: ^Cartridge, addr: u16, value: u8) {
	if cart.chr_is_ram {
		a := addr & 0x1FFF
		cart.chr[cart.chr_map[a >> 10] + int(a & 0x3FF)] = value
	}
}

// Index into the console's 4 KiB nametable RAM for a $2000-$2FFF address.
cart_nt_index :: #force_inline proc(cart: ^Cartridge, addr: u16) -> int {
	a := addr & 0x0FFF
	return cart.nt_map[a >> 10] + int(a & 0x3FF)
}

// Watches PPU address line A12. The MMC3 clocks its scanline counter on a
// rising edge that follows at least ~3 CPU cycles of A12 being low, which is
// what filters out the short dips between background pattern fetches.
cart_ppu_address :: proc(cart: ^Cartridge, addr: u16, dot: u64) {
	if cart.mapper != 4 {
		return
	}
	high := addr & 0x1000 != 0
	if high && !cart.a12_high && dot - cart.a12_low_at >= 9 {
		mmc3_clock(cart)
	} else if !high && cart.a12_high {
		cart.a12_low_at = dot
	}
	cart.a12_high = high
}

@(private = "file")
mmc3_clock :: proc(cart: ^Cartridge) {
	m := &cart.mmc3
	if m.irq_counter == 0 || m.irq_reload {
		m.irq_counter = m.irq_latch
		m.irq_reload = false
	} else {
		m.irq_counter -= 1
	}
	if m.irq_counter == 0 && m.irq_enabled {
		cart.irq = true
	}
}

// --- MMC1 ------------------------------------------------------------------

mmc1_write :: proc(cart: ^Cartridge, addr: u16, value: u8, cpu_cycle: u64) {
	m := &cart.mmc1
	// Writes on consecutive CPU cycles (read-modify-write instructions) are ignored.
	consecutive := cpu_cycle == m.last_write_cycle + 1
	m.last_write_cycle = cpu_cycle
	if value & 0x80 != 0 {
		m.shift = 0
		m.shift_count = 0
		m.control |= 0x0C
		mmc1_update(cart)
		return
	}
	if consecutive {
		return
	}
	m.shift |= (value & 1) << m.shift_count
	m.shift_count += 1
	if m.shift_count < 5 {
		return
	}
	switch (addr >> 13) & 3 {
	case 0: m.control = m.shift
	case 1: m.chr0 = m.shift
	case 2: m.chr1 = m.shift
	case 3: m.prg = m.shift
	}
	m.shift = 0
	m.shift_count = 0
	mmc1_update(cart)
}

mmc1_update :: proc(cart: ^Cartridge) {
	m := &cart.mmc1
	switch m.control & 3 {
	case 0: cart_set_mirroring(cart, .Single_Low)
	case 1: cart_set_mirroring(cart, .Single_High)
	case 2: cart_set_mirroring(cart, .Vertical)
	case 3: cart_set_mirroring(cart, .Horizontal)
	}
	// SUROM/SXROM: CHR bank bit 4 selects the 256 KiB PRG half.
	outer := 0
	if len(cart.prg_rom) > 0x40000 {
		outer = int(m.chr0 & 0x10) << 0 // bank units of 16 KiB: 0x10 * 16 KiB = 256 KiB
	}
	prg := int(m.prg & 0x0F)
	switch (m.control >> 2) & 3 {
	case 0, 1:
		cart_set_prg(cart, 0, (outer + (prg & 0x0E)) / 2, 0x8000)
	case 2:
		cart_set_prg(cart, 0, outer, 0x4000)
		cart_set_prg(cart, 2, outer + prg, 0x4000)
	case 3:
		cart_set_prg(cart, 0, outer + prg, 0x4000)
		cart_set_prg(cart, 2, outer + 0x0F, 0x4000)
	}
	if m.control & 0x10 == 0 {
		cart_set_chr(cart, 0, int(m.chr0 >> 1), 0x2000)
	} else {
		cart_set_chr(cart, 0, int(m.chr0), 0x1000)
		cart_set_chr(cart, 4, int(m.chr1), 0x1000)
	}
}

// --- MMC3 ------------------------------------------------------------------

mmc3_write :: proc(cart: ^Cartridge, addr: u16, value: u8) {
	m := &cart.mmc3
	even := addr & 1 == 0
	switch addr {
	case 0x8000 ..= 0x9FFF:
		if even {
			m.bank_select = value
		} else {
			m.regs[m.bank_select & 7] = value
		}
		mmc3_update(cart)
	case 0xA000 ..= 0xBFFF:
		if even && cart.mirroring != .Four_Screen {
			cart_set_mirroring(cart, value & 1 != 0 ? .Horizontal : .Vertical)
		}
	case 0xC000 ..= 0xDFFF:
		if even {
			m.irq_latch = value
		} else {
			m.irq_counter = 0
			m.irq_reload = true
		}
	case 0xE000 ..= 0xFFFF:
		if even {
			m.irq_enabled = false
			cart.irq = false
		} else {
			m.irq_enabled = true
		}
	}
}

mmc3_update :: proc(cart: ^Cartridge) {
	m := &cart.mmc3
	r := &m.regs
	if m.bank_select & 0x40 == 0 {
		cart_set_prg(cart, 0, int(r[6]), PRG_SLOT)
		cart_set_prg(cart, 2, -2, PRG_SLOT)
	} else {
		cart_set_prg(cart, 0, -2, PRG_SLOT)
		cart_set_prg(cart, 2, int(r[6]), PRG_SLOT)
	}
	cart_set_prg(cart, 1, int(r[7]), PRG_SLOT)
	cart_set_prg(cart, 3, -1, PRG_SLOT)

	base := m.bank_select & 0x80 != 0 ? 4 : 0
	cart_set_chr(cart, base + 0, int(r[0] & 0xFE), CHR_SLOT)
	cart_set_chr(cart, base + 1, int(r[0] | 0x01), CHR_SLOT)
	cart_set_chr(cart, base + 2, int(r[1] & 0xFE), CHR_SLOT)
	cart_set_chr(cart, base + 3, int(r[1] | 0x01), CHR_SLOT)
	other := 4 - base
	cart_set_chr(cart, other + 0, int(r[2]), CHR_SLOT)
	cart_set_chr(cart, other + 1, int(r[3]), CHR_SLOT)
	cart_set_chr(cart, other + 2, int(r[4]), CHR_SLOT)
	cart_set_chr(cart, other + 3, int(r[5]), CHR_SLOT)
}

// --- MMC2 (Punch-Out!!) ----------------------------------------------------

mmc2_write :: proc(cart: ^Cartridge, addr: u16, value: u8) {
	m := &cart.mmc2
	switch addr {
	case 0xA000 ..= 0xAFFF: m.prg = value & 0x0F
	case 0xB000 ..= 0xBFFF: m.chr[0] = value & 0x1F
	case 0xC000 ..= 0xCFFF: m.chr[1] = value & 0x1F
	case 0xD000 ..= 0xDFFF: m.chr[2] = value & 0x1F
	case 0xE000 ..= 0xEFFF: m.chr[3] = value & 0x1F
	case 0xF000 ..= 0xFFFF:
		cart_set_mirroring(cart, value & 1 != 0 ? .Horizontal : .Vertical)
	}
	mmc2_update(cart)
}

mmc2_update :: proc(cart: ^Cartridge) {
	m := &cart.mmc2
	cart_set_prg(cart, 0, int(m.prg), PRG_SLOT)
	cart_set_prg(cart, 1, -3, PRG_SLOT)
	cart_set_prg(cart, 2, -2, PRG_SLOT)
	cart_set_prg(cart, 3, -1, PRG_SLOT)
	cart_set_chr(cart, 0, int(m.chr[0 + int(m.latch[0])]), 0x1000)
	cart_set_chr(cart, 4, int(m.chr[2 + int(m.latch[1])]), 0x1000)
}

mmc2_latch :: proc(cart: ^Cartridge, a: u16) {
	m := &cart.mmc2
	changed := true
	switch {
	case a == 0x0FD8:                  m.latch[0] = 0
	case a == 0x0FE8:                  m.latch[0] = 1
	case a >= 0x1FD8 && a <= 0x1FDF:   m.latch[1] = 0
	case a >= 0x1FE8 && a <= 0x1FEF:   m.latch[1] = 1
	case:                              changed = false
	}
	if changed {
		cart_set_chr(cart, 0, int(m.chr[0 + int(m.latch[0])]), 0x1000)
		cart_set_chr(cart, 4, int(m.chr[2 + int(m.latch[1])]), 0x1000)
	}
}
