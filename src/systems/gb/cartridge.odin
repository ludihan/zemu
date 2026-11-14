package gb

import "base:runtime"
import "../../emu"

Mbc :: enum u8 {
	None,
	Mbc1,
	Mbc2,
	Mbc3,
	Mbc5,
}

Rtc :: struct {
	seconds:  i64,   // emulated time since the clock was set
	sub:      int,   // T-cycles toward the next second
	halted:   bool,
	latched:  [5]u8, // S, M, H, DL, DH
	latch_armed: bool,
}

Cartridge :: struct {
	rom:        []u8,
	ram:        []u8,
	mbc:        Mbc,
	battery:    bool,
	has_rtc:    bool,
	cgb:        bool, // runs in Game Boy Color mode
	ram_enabled: bool,
	rom_bank:   int,
	ram_bank:   int,
	mode:       u8, // MBC1 banking mode
	rom_banks:  int,
	rtc:        Rtc,
	title:      [16]u8,
}

cart_load :: proc(cart: ^Cartridge, rom: []u8, allocator := context.allocator) -> emu.Load_Error {
	if len(rom) < 0x8000 {
		return .Truncated
	}
	// The logo checksum at $0134-$014C must add up (the boot ROM checks it too).
	sum: u8 = 0
	for b in rom[0x134:0x14D] {
		sum = sum - b - 1
	}
	if sum != rom[0x14D] {
		return .Bad_Header
	}
	copy(cart.title[:], rom[0x134:0x144])
	cart.cgb = rom[0x143] & 0x80 != 0

	switch rom[0x147] {
	case 0x00, 0x08, 0x09:
		cart.mbc = .None
		cart.battery = rom[0x147] == 0x09
	case 0x01 ..= 0x03:
		cart.mbc = .Mbc1
		cart.battery = rom[0x147] == 0x03
	case 0x05, 0x06:
		cart.mbc = .Mbc2
		cart.battery = rom[0x147] == 0x06
	case 0x0F ..= 0x13:
		cart.mbc = .Mbc3
		cart.battery = rom[0x147] != 0x11 && rom[0x147] != 0x12
		cart.has_rtc = rom[0x147] <= 0x10
	case 0x19 ..= 0x1E:
		cart.mbc = .Mbc5
		cart.battery = rom[0x147] == 0x1B || rom[0x147] == 0x1E
	case:
		return .Unsupported_Mapper
	}

	ram_size := 0
	switch rom[0x149] {
	case 1: ram_size = 0x800
	case 2: ram_size = 0x2000
	case 3: ram_size = 0x8000
	case 4: ram_size = 0x20000
	case 5: ram_size = 0x10000
	}
	if cart.mbc == .Mbc2 {
		ram_size = 512 // built-in 512 x 4 bits
	}

	err: runtime.Allocator_Error
	// Round the ROM up to a power of two so bank masks never leave it.
	size := 0x8000
	for size < len(rom) {
		size *= 2
	}
	cart.rom, err = make([]u8, size, allocator)
	if err != nil {
		return .Out_Of_Memory
	}
	copy(cart.rom, rom)
	for i in len(rom) ..< size {
		cart.rom[i] = 0xFF
	}
	cart.rom_banks = size / 0x4000
	if ram_size > 0 {
		cart.ram, err = make([]u8, ram_size, allocator)
		if err != nil {
			delete(cart.rom, allocator)
			cart.rom = nil
			return .Out_Of_Memory
		}
	}
	cart_reset(cart)
	return .None
}

cart_destroy :: proc(cart: ^Cartridge, allocator := context.allocator) {
	delete(cart.rom, allocator)
	delete(cart.ram, allocator)
	cart.rom = nil
	cart.ram = nil
}

cart_reset :: proc(cart: ^Cartridge) {
	cart.ram_enabled = false
	cart.rom_bank = 1
	cart.ram_bank = 0
	cart.mode = 0
}

@(private = "file")
rom_byte :: #force_inline proc(cart: ^Cartridge, bank: int, addr: u16) -> u8 {
	b := bank & (cart.rom_banks - 1)
	return cart.rom[b * 0x4000 + int(addr & 0x3FFF)]
}

cart_read :: proc(cart: ^Cartridge, addr: u16) -> u8 {
	switch addr {
	case 0x0000 ..= 0x3FFF:
		if cart.mbc == .Mbc1 && cart.mode == 1 {
			return rom_byte(cart, cart.ram_bank << 5, addr)
		}
		return cart.rom[addr]
	case 0x4000 ..= 0x7FFF:
		bank := cart.rom_bank
		if cart.mbc == .Mbc1 {
			bank = (cart.ram_bank << 5) | (cart.rom_bank & 0x1F)
		}
		return rom_byte(cart, bank, addr)
	case 0xA000 ..= 0xBFFF:
		if !cart.ram_enabled {
			return 0xFF
		}
		if cart.mbc == .Mbc3 && cart.ram_bank >= 0x08 {
			i := cart.ram_bank - 0x08
			return i < 5 ? cart.rtc.latched[i] : 0xFF
		}
		if cart.mbc == .Mbc2 {
			return cart.ram[addr & 0x1FF] | 0xF0
		}
		if len(cart.ram) == 0 {
			return 0xFF
		}
		return ram_access(cart, addr)^
	}
	return 0xFF
}

@(private = "file")
ram_access :: proc(cart: ^Cartridge, addr: u16) -> ^u8 {
	bank := cart.ram_bank
	if cart.mbc == .Mbc1 && cart.mode == 0 {
		bank = 0
	}
	off := (bank * 0x2000 + int(addr & 0x1FFF)) % len(cart.ram)
	return &cart.ram[off]
}

cart_write :: proc(cart: ^Cartridge, addr: u16, v: u8) {
	switch addr {
	case 0x0000 ..= 0x1FFF:
		if cart.mbc == .Mbc2 {
			if addr & 0x100 == 0 {
				cart.ram_enabled = v & 0x0F == 0x0A
			} else {
				cart.rom_bank = max(int(v & 0x0F), 1)
			}
			return
		}
		cart.ram_enabled = v & 0x0F == 0x0A
	case 0x2000 ..= 0x3FFF:
		switch cart.mbc {
		case .None:
		case .Mbc1:
			cart.rom_bank = max(int(v & 0x1F), 1)
		case .Mbc2:
			if addr & 0x100 != 0 {
				cart.rom_bank = max(int(v & 0x0F), 1)
			}
		case .Mbc3:
			cart.rom_bank = max(int(v & 0x7F), 1)
		case .Mbc5:
			if addr < 0x3000 {
				cart.rom_bank = (cart.rom_bank & 0x100) | int(v)
			} else {
				cart.rom_bank = (cart.rom_bank & 0xFF) | int(v & 1) << 8
			}
		}
	case 0x4000 ..= 0x5FFF:
		switch cart.mbc {
		case .None, .Mbc2:
		case .Mbc1: cart.ram_bank = int(v & 0x03)
		case .Mbc3: cart.ram_bank = int(v & 0x0F)
		case .Mbc5: cart.ram_bank = int(v & 0x0F)
		}
	case 0x6000 ..= 0x7FFF:
		switch cart.mbc {
		case .Mbc1:
			cart.mode = v & 1
		case .Mbc3:
			if v == 0 {
				cart.rtc.latch_armed = true
			} else if v == 1 && cart.rtc.latch_armed {
				rtc_latch(&cart.rtc)
				cart.rtc.latch_armed = false
			}
		case .None, .Mbc2, .Mbc5:
		}
	case 0xA000 ..= 0xBFFF:
		if !cart.ram_enabled {
			return
		}
		if cart.mbc == .Mbc3 && cart.ram_bank >= 0x08 {
			rtc_write(&cart.rtc, cart.ram_bank - 0x08, v)
			return
		}
		if cart.mbc == .Mbc2 {
			cart.ram[addr & 0x1FF] = v & 0x0F
			return
		}
		if len(cart.ram) > 0 {
			ram_access(cart, addr)^ = v
		}
	}
}

// --- MBC3 real-time clock (driven by emulated time) -----------------------

rtc_tick :: proc(rtc: ^Rtc, cycles: int) {
	if rtc.halted {
		return
	}
	rtc.sub += cycles
	for rtc.sub >= 4_194_304 {
		rtc.sub -= 4_194_304
		rtc.seconds += 1
	}
}

@(private = "file")
rtc_latch :: proc(rtc: ^Rtc) {
	s := rtc.seconds
	days := s / 86400
	rtc.latched[0] = u8(s % 60)
	rtc.latched[1] = u8(s / 60 % 60)
	rtc.latched[2] = u8(s / 3600 % 24)
	rtc.latched[3] = u8(days)
	dh := u8((days >> 8) & 1)
	if rtc.halted {dh |= 0x40}
	if days > 511 {dh |= 0x80}
	rtc.latched[4] = dh
}

@(private = "file")
rtc_write :: proc(rtc: ^Rtc, reg: int, v: u8) {
	s := rtc.seconds
	sec := s % 60
	mins := s / 60 % 60
	hours := s / 3600 % 24
	days := s / 86400
	switch reg {
	case 0: sec = i64(v % 60); rtc.sub = 0
	case 1: mins = i64(v % 60)
	case 2: hours = i64(v % 24)
	case 3: days = (days & 0x100) | i64(v)
	case 4:
		days = (days & 0xFF) | i64(v & 1) << 8
		rtc.halted = v & 0x40 != 0
	case: return
	}
	rtc.seconds = days * 86400 + hours * 3600 + mins * 60 + sec
	if reg < 5 {
		rtc.latched[reg] = v
	}
}
