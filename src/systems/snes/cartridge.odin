package snes

import "base:runtime"
import "../../emu"

Map_Mode :: enum u8 {
	Lo_Rom,
	Hi_Rom,
	Ex_Hi_Rom,
}

Cartridge :: struct {
	rom:       []u8,
	sram:      []u8,
	sram_mask: int,
	map_mode:  Map_Mode,
	fast_rom:  bool,
	title:     [21]u8,
	battery:   bool,
}

@(private = "file")
header_score :: proc(rom: []u8, offset: int, expect: Map_Mode) -> int {
	if offset + 0x40 > len(rom) {
		return -100
	}
	h := rom[offset:][:0x40]
	score := 0
	map_byte := h[0x15]
	checksum := int(h[0x1E]) | int(h[0x1F]) << 8
	complement := int(h[0x1C]) | int(h[0x1D]) << 8
	reset := int(h[0x3C]) | int(h[0x3D]) << 8

	if checksum + complement == 0xFFFF {score += 8}
	switch expect {
	case .Lo_Rom:    if map_byte & 0xEF == 0x20 {score += 4}
	case .Hi_Rom:    if map_byte & 0xEF == 0x21 {score += 4}
	case .Ex_Hi_Rom: if map_byte & 0xEF == 0x25 {score += 4}
	}
	if reset >= 0x8000 {score += 2} else {score -= 8}
	// The first instruction at reset is usually SEI or CLC/XCE.
	reset_offset := offset & ~int(0x7FFF) + (reset & 0x7FFF)
	if expect != .Lo_Rom {
		reset_offset = offset & ~int(0xFFFF) + reset
	}
	if reset_offset >= 0 && reset_offset < len(rom) {
		op := rom[reset_offset]
		if op == 0x78 || op == 0x18 || op == 0x5C || op == 0x9C || op == 0x4C {score += 2}
	}
	printable := 0
	for b in h[0x00:0x15] {
		if b >= 0x20 && b < 0x7F {printable += 1}
	}
	if printable == 21 {score += 2}
	if h[0x17] <= 0x0D {score += 1} // ROM size
	if h[0x18] <= 0x08 {score += 1} // RAM size
	return score
}

cart_load :: proc(cart: ^Cartridge, image: []u8, allocator := context.allocator) -> emu.Load_Error {
	data := image
	if len(data) % 1024 == 512 {
		data = data[512:] // copier header
	}
	if len(data) < 0x8000 {
		return .Truncated
	}

	lo := header_score(data, 0x7FC0, .Lo_Rom)
	hi := header_score(data, 0xFFC0, .Hi_Rom)
	ex := header_score(data, 0x40FFC0, .Ex_Hi_Rom)
	header := 0x7FC0
	cart.map_mode = .Lo_Rom
	if hi > lo && hi >= ex {
		header = 0xFFC0
		cart.map_mode = .Hi_Rom
	} else if ex > lo && ex > hi {
		header = 0x40FFC0
		cart.map_mode = .Ex_Hi_Rom
	}
	h := data[header:][:0x40]
	copy(cart.title[:], h[0x00:0x15])
	cart.fast_rom = h[0x15] & 0x10 != 0

	// $FFD6: low nibble 3-6 means a coprocessor (DSP-n, SuperFX, SA-1, ...)
	// sits on the cartridge. None of them are emulated, and the games do not
	// run without them, so refuse instead of crashing mysteriously later.
	chip := h[0x16]
	if chip & 0x0F >= 3 && chip & 0x0F <= 6 {
		return .Unsupported_Chip
	}
	switch chip & 0x0F {
	case 0x02, 0x05, 0x06: cart.battery = true
	}

	err: runtime.Allocator_Error
	cart.rom, err = make([]u8, len(data), allocator)
	if err != nil {
		return .Out_Of_Memory
	}
	copy(cart.rom, data)

	ram_kb := h[0x18]
	sram_size := ram_kb > 0 && ram_kb <= 8 ? 1024 << ram_kb : 0
	if sram_size > 0 {
		cart.sram, err = make([]u8, sram_size, allocator)
		if err != nil {
			delete(cart.rom, allocator)
			cart.rom = nil
			return .Out_Of_Memory
		}
		cart.sram_mask = sram_size - 1
		for &b in cart.sram {b = 0xFF}
	}
	return .None
}

cart_destroy :: proc(cart: ^Cartridge, allocator := context.allocator) {
	delete(cart.rom, allocator)
	delete(cart.sram, allocator)
	cart.rom = nil
	cart.sram = nil
}

// Maps an address past the end of the ROM the way the board's address lines
// mirror it (e.g. a 3 MiB ROM repeats its last 1 MiB).
@(private = "file")
rom_mirror :: proc(addr, size: int) -> int {
	if addr < size {
		return addr
	}
	a := addr
	s := size
	base := 0
	mask := 1 << 23
	for a >= s {
		for mask > 0 && a & mask == 0 {
			mask >>= 1
		}
		if mask == 0 {
			return base + a % max(s, 1)
		}
		a -= mask
		if s > mask {
			s -= mask
			base += mask
		}
		mask >>= 1
	}
	return base + a
}

@(private = "file")
rom_byte :: #force_inline proc(cart: ^Cartridge, offset: int) -> u8 {
	return cart.rom[rom_mirror(offset & 0xFFFFFF, len(cart.rom))]
}

// Reads from cartridge space. `ok` is false for unmapped addresses (open bus).
cart_read :: proc(cart: ^Cartridge, bank: u8, addr: u16) -> (value: u8, ok: bool) {
	b := int(bank)
	a := int(addr)
	switch cart.map_mode {
	case .Lo_Rom:
		if a >= 0x8000 {
			return rom_byte(cart, (b & 0x7F) * 0x8000 + (a - 0x8000)), true
		}
		if len(cart.sram) > 0 && (b & 0x7F) >= 0x70 && (b & 0x7F) <= 0x7D {
			return cart.sram[((b & 0x0F) * 0x8000 + a) & cart.sram_mask], true
		}
		if (b & 0x7F) >= 0x40 && (b & 0x7F) < 0x70 {
			return rom_byte(cart, (b & 0x7F) * 0x8000 + (a & 0x7FFF)), true
		}
	case .Hi_Rom, .Ex_Hi_Rom:
		hi_bank := b & 0x3F
		if cart.map_mode == .Ex_Hi_Rom && b < 0x80 {
			hi_bank += 0x40 // $00-$7D map the upper 4 MiB
		}
		if b & 0x7F >= 0x40 {
			return rom_byte(cart, hi_bank * 0x10000 + a), true
		}
		if a >= 0x8000 {
			return rom_byte(cart, hi_bank * 0x10000 + a), true
		}
		if len(cart.sram) > 0 && a >= 0x6000 && (b & 0x7F) >= 0x20 && (b & 0x7F) < 0x40 {
			return cart.sram[((b & 0x1F) * 0x2000 + (a - 0x6000)) & cart.sram_mask], true
		}
	}
	return 0, false
}

cart_write :: proc(cart: ^Cartridge, bank: u8, addr: u16, value: u8) {
	if len(cart.sram) == 0 {
		return
	}
	b := int(bank)
	a := int(addr)
	switch cart.map_mode {
	case .Lo_Rom:
		if a < 0x8000 && (b & 0x7F) >= 0x70 && (b & 0x7F) <= 0x7D {
			cart.sram[((b & 0x0F) * 0x8000 + a) & cart.sram_mask] = value
		}
	case .Hi_Rom, .Ex_Hi_Rom:
		if a >= 0x6000 && a < 0x8000 && (b & 0x7F) >= 0x20 && (b & 0x7F) < 0x40 {
			cart.sram[((b & 0x1F) * 0x2000 + (a - 0x6000)) & cart.sram_mask] = value
		}
	}
}
