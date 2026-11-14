package main

import "core:testing"

import "emu"
import "systems/nes"

@(test)
nes_game_genie_decodes_known_codes :: proc(t: ^testing.T) {
	// Super Mario Bros. "infinite lives" code
	c, ok := decode_cheat(.NES, "SXIOPO")
	testing.expect(t, ok)
	testing.expect_value(t, c.kind, Cheat_Kind.Rom_Patch)
	testing.expect_value(t, c.addr, 0x91D9)
	testing.expect_value(t, c.value, 0xAD)
	testing.expect_value(t, c.compare, -1)
	_, ok = decode_cheat(.NES, "SXIOP") // wrong length
	testing.expect(t, !ok)
	_, ok = decode_cheat(.NES, "QQQQQQ") // not Game Genie letters
	testing.expect(t, !ok)
	c8, ok8 := decode_cheat(.NES, "SXIOPOZA")
	testing.expect(t, ok8)
	testing.expect(t, c8.compare >= 0, "8-letter codes carry a compare byte")
}

@(test)
game_boy_codes_decode :: proc(t: ^testing.T) {
	// Built from the documented layout: value $3E at $4A12 (F nibble = 4 ^ F),
	// compare $55 encoded as ($55 ^ $BA) rotated left by two = $BF.
	c, ok := decode_cheat(.GB, "3EA-12B")
	testing.expect(t, ok)
	testing.expect_value(t, c.addr, 0x4A12)
	testing.expect_value(t, c.value, 0x3E)
	c, ok = decode_cheat(.GB, "3EA-12B-B0F")
	testing.expect(t, ok)
	testing.expect_value(t, c.compare, 0x55)
	// GameShark: type 01, value $63, address $D158 (stored little-endian)
	g, gok := decode_cheat(.GB, "016358D1")
	testing.expect(t, gok)
	testing.expect_value(t, g.kind, Cheat_Kind.Ram_Write8)
	testing.expect_value(t, g.addr, 0xD158)
	testing.expect_value(t, g.value, 0x63)
}

@(test)
snes_and_psx_codes_decode :: proc(t: ^testing.T) {
	// Pro Action Replay: bank $7E, address $0DBF, value $09
	c, ok := decode_cheat(.SNES, "7E0DBF09")
	testing.expect(t, ok)
	testing.expect_value(t, c.kind, Cheat_Kind.Ram_Write8)
	testing.expect_value(t, c.addr, 0x7E0DBF)
	testing.expect_value(t, c.value, 0x09)
	// Game Genie: the all-"D" code is all-zero data
	g, gok := decode_cheat(.SNES, "DDDD-DDDD")
	testing.expect(t, gok)
	testing.expect_value(t, g.kind, Cheat_Kind.Rom_Patch)
	testing.expect_value(t, g.addr, 0)
	testing.expect_value(t, g.value, 0)
	p, pok := decode_cheat(.PSX, "800B1234 03E7")
	testing.expect(t, pok)
	testing.expect_value(t, p.kind, Cheat_Kind.Ram_Write16)
	testing.expect_value(t, p.addr, 0x0B1234)
	testing.expect_value(t, p.value, 999)
	r, rok := decode_cheat(.NES, "0075:09")
	testing.expect(t, rok)
	testing.expect_value(t, r.addr, 0x75)
	testing.expect_value(t, r.value, 9)
}

@(test)
cheats_patch_rom_reads_and_poke_ram :: proc(t: ^testing.T) {
	rom := make([]u8, 16 + 0x8000 + 0x2000)
	defer delete(rom)
	copy(rom, "NES\x1A")
	rom[4] = 2
	rom[5] = 1
	c, err := nes.create(rom)
	if !testing.expect_value(t, err, emu.Load_Error.None) {return}
	defer nes.destroy(c)
	m: Machine = c
	list: Cheat_List
	testing.expect(t, cheat_add(&list, .NES, "SXIOPO", "lives"))
	testing.expect(t, cheat_add(&list, .NES, "0075:09", ""))
	cheats_sync(m, &list)
	cheats_apply(m, &list)
	testing.expect_value(t, nes.bus_read(c, 0x91D9), 0xAD)
	testing.expect_value(t, c.ram[0x75], 9)
	list.items[0].enabled = false
	cheats_sync(m, &list)
	testing.expect_value(t, nes.bus_read(c, 0x91D9), 0x00)
}
