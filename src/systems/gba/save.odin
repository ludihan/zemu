package gba

// Cartridge save memory: battery SRAM, Flash (64 or 128 KiB) and serial
// EEPROM (512 bytes or 8 KiB). The type is found from the library ID string
// the official SDK embeds in every ROM.

Save_Kind :: enum u8 {
	None,
	Sram,
	Flash64,
	Flash128,
	Eeprom,
}

SAVE_MAX :: 0x20000

Flash_State :: enum u8 {
	Ready,
	Cmd1, // got 0xAA at 0x5555
	Cmd2, // got 0x55 at 0x2AAA
	Erase_Ready, Erase1, Erase2,
	Write,
	Bank,
}

Eeprom_State :: enum u8 {
	Idle,
	Command,
	Read_Out,
}

Save :: struct {
	kind:     Save_Kind,
	data:     [SAVE_MAX]u8,
	dirty:    bool,
	// Flash
	flash:    Flash_State,
	id_mode:  bool,
	bank:     int,
	// EEPROM
	eeprom_addr_bits: int, // 6 or 14; 0 until the first DMA says
	eeprom:   Eeprom_State,
	bits:     u128,
	nbits:    int,
	out_bits: u64,
	out_left: int,
}

save_size :: proc(s: ^Save) -> int {
	switch s.kind {
	case .None:     return 0
	case .Sram:     return 0x8000
	case .Flash64:  return 0x10000
	case .Flash128: return 0x20000
	case .Eeprom:   return s.eeprom_addr_bits == 6 ? 0x200 : 0x2000
	}
	return 0
}

@(private = "file")
contains :: proc(rom: []u8, needle: string) -> bool {
	n := len(needle)
	for i := 0; i + n <= len(rom); i += 4 { // the strings are word aligned
		if string(rom[i:i + n]) == needle {
			return true
		}
	}
	return false
}

save_detect :: proc(s: ^Save, rom: []u8) {
	s^ = {}
	switch {
	case contains(rom, "EEPROM_V"):
		s.kind = .Eeprom
	case contains(rom, "FLASH1M_V"):
		s.kind = .Flash128
	case contains(rom, "FLASH_V"), contains(rom, "FLASH512_V"):
		s.kind = .Flash64
	case contains(rom, "SRAM_V"), contains(rom, "SRAM_F_V"):
		s.kind = .Sram
	}
	for &b in s.data {
		b = 0xFF // erased Flash / fresh EEPROM read as ones
	}
}

save_read8 :: proc(c: ^Console, addr: u32) -> u8 {
	s := &c.save
	a := int(addr & 0xFFFF)
	#partial switch s.kind {
	case .Sram:
		return s.data[a & 0x7FFF]
	case .Flash64, .Flash128:
		if s.id_mode && a < 2 {
			if s.kind == .Flash128 {
				return a == 0 ? 0x62 : 0x13 // Sanyo
			}
			return a == 0 ? 0x32 : 0x1B // Panasonic
		}
		return s.data[s.bank * 0x10000 + a]
	}
	return 0xFF
}

save_write8 :: proc(c: ^Console, addr: u32, v: u8) {
	s := &c.save
	a := int(addr & 0xFFFF)
	#partial switch s.kind {
	case .Sram:
		s.data[a & 0x7FFF] = v
		s.dirty = true
	case .Flash64, .Flash128:
		flash_write(s, a, v)
	}
}

@(private = "file")
flash_write :: proc(s: ^Save, a: int, v: u8) {
	switch s.flash {
	case .Write:
		s.data[s.bank * 0x10000 + a] &= v // programming only clears bits
		s.dirty = true
		s.flash = .Ready
		return
	case .Bank:
		if a == 0 && s.kind == .Flash128 {
			s.bank = int(v & 1)
		}
		s.flash = .Ready
		return
	case .Ready, .Erase_Ready:
		if v == 0xF0 {
			s.id_mode = false // a bare reset command leaves ID mode too
		}
		if a == 0x5555 && v == 0xAA {
			s.flash = s.flash == .Erase_Ready ? .Erase1 : .Cmd1
		}
		return
	case .Cmd1, .Erase1:
		if a == 0x2AAA && v == 0x55 {
			s.flash = s.flash == .Erase1 ? .Erase2 : .Cmd2
		} else {
			s.flash = .Ready
		}
		return
	case .Erase2:
		s.flash = .Ready
		if a == 0x5555 && v == 0x10 { // chip erase
			for &b in s.data[:save_size(s)] {b = 0xFF}
			s.dirty = true
		} else if v == 0x30 { // 4 KiB sector erase
			base := s.bank * 0x10000 + (a & 0xF000)
			for &b in s.data[base:][:0x1000] {b = 0xFF}
			s.dirty = true
		}
		return
	case .Cmd2:
	}
	s.flash = .Ready
	if a != 0x5555 {
		return
	}
	switch v {
	case 0x90: s.id_mode = true
	case 0xF0: s.id_mode = false
	case 0x80: s.flash = .Erase_Ready
	case 0xA0: s.flash = .Write
	case 0xB0: s.flash = .Bank
	}
}

// --- EEPROM -------------------------------------------------------------------

eeprom_detect :: proc(s: ^Save, count: int) {
	if s.eeprom_addr_bits != 0 {
		return
	}
	switch count {
	case 9, 73: s.eeprom_addr_bits = 6
	case 17, 81: s.eeprom_addr_bits = 14
	}
}

eeprom_write :: proc(s: ^Save, v: u16) {
	if s.eeprom_addr_bits == 0 {
		s.eeprom_addr_bits = 14 // CPU-driven access before any DMA: assume large
	}
	bit := u128(v & 1)
	if s.eeprom == .Read_Out {
		return
	}
	s.bits = s.bits << 1 | bit
	s.nbits += 1
	ab := s.eeprom_addr_bits
	if s.nbits < 2 {
		return
	}
	cmd := int(s.bits >> uint(s.nbits - 2)) & 3
	switch cmd {
	case 3: // read request: 2 + address + stop bit
		if s.nbits == 2 + ab + 1 {
			addr := int(s.bits >> 1) & ((1 << uint(ab)) - 1)
			base := (addr * 8) & (save_size(s) - 1)
			out: u64
			for i in 0 ..< 8 {
				out = out << 8 | u64(s.data[base + i])
			}
			s.out_bits = out
			s.out_left = 68 // four junk bits, then 64 data bits
			s.eeprom = .Read_Out
			s.bits, s.nbits = 0, 0
		}
	case 2: // write: 2 + address + 64 data + stop bit
		if s.nbits == 2 + ab + 64 + 1 {
			data := u64(s.bits >> 1)
			addr := int(s.bits >> 65) & ((1 << uint(ab)) - 1)
			base := (addr * 8) & (save_size(s) - 1)
			for i in 0 ..< 8 {
				s.data[base + i] = u8(data >> uint(56 - i * 8))
			}
			s.dirty = true
			s.bits, s.nbits = 0, 0
		}
	case:
		s.bits, s.nbits = 0, 0
	}
}

eeprom_read :: proc(s: ^Save) -> u16 {
	if s.eeprom != .Read_Out {
		return 1 // ready
	}
	s.out_left -= 1
	if s.out_left <= 0 {
		s.eeprom = .Idle
	}
	if s.out_left >= 64 {
		return 0
	}
	return u16(s.out_bits >> uint(s.out_left)) & 1
}
