package sms

import "core:testing"

// A 128 KiB image whose banks start with their own number.
@(private = "file")
banked_rom :: proc(codemasters: bool) -> []u8 {
	rom := make([]u8, 8 * 0x4000)
	for b in 0 ..< 8 {
		rom[b * 0x4000] = u8(b)
		rom[b * 0x4000 + 0x2000] = u8(0x80 | b)
	}
	if codemasters {
		sum := 0x1234
		rom[0x7FE6], rom[0x7FE7] = u8(sum), u8(sum >> 8)
		inverse := 0x10000 - sum
		rom[0x7FE8], rom[0x7FE9] = u8(inverse), u8(inverse >> 8)
	}
	return rom
}

@(test)
codemasters_mapper_switches_all_three_slots :: proc(t: ^testing.T) {
	rom := banked_rom(true)
	defer delete(rom)
	c, err := create(rom, false)
	if !testing.expect_value(t, err, nil) {return}
	defer destroy(c)
	testing.expect_value(t, c.mapper_kind, Mapper_Kind.Codemasters)

	// power-on banks 0, 1, 0
	testing.expect_value(t, bus_read(c, 0x0000), 0)
	testing.expect_value(t, bus_read(c, 0x4000), 1)
	testing.expect_value(t, bus_read(c, 0x8000), 0)

	bus_write(c, 0x0000, 5) // no fixed first kilobyte, unlike the Sega mapper
	bus_write(c, 0x4000, 6)
	bus_write(c, 0x8000, 7)
	testing.expect_value(t, bus_read(c, 0x0000), 5)
	testing.expect_value(t, bus_read(c, 0x4000), 6)
	testing.expect_value(t, bus_read(c, 0x8000), 7)
	testing.expect_value(t, bus_read(c, 0xA000), 0x87)

	// bit 7 of the $4000 register puts 8 KiB of cartridge RAM at $A000
	bus_write(c, 0x4000, 0x80 | 2)
	testing.expect_value(t, bus_read(c, 0x4000), 2)
	bus_write(c, 0xA123, 0x5A)
	testing.expect_value(t, bus_read(c, 0xA123), 0x5A)
	testing.expect_value(t, bus_read(c, 0x8000), 7) // $8000-$9FFF stays ROM
	testing.expect(t, save_ram(c) != nil, "cartridge RAM was used")
	bus_write(c, 0x4000, 2)
	testing.expect_value(t, bus_read(c, 0xA000), 0x87)

	// the Sega registers are plain RAM here
	bus_write(c, 0xFFFF, 3)
	testing.expect_value(t, bus_read(c, 0x8000), 7)
}

@(test)
sega_mapper_is_the_default :: proc(t: ^testing.T) {
	rom := banked_rom(false)
	defer delete(rom)
	c, err := create(rom, false)
	if !testing.expect_value(t, err, nil) {return}
	defer destroy(c)
	testing.expect_value(t, c.mapper_kind, Mapper_Kind.Sega)
	bus_write(c, 0xFFFF, 3)
	testing.expect_value(t, bus_read(c, 0x8000), 3)
	bus_write(c, 0x0000, 5) // ROM: ignored
	testing.expect_value(t, bus_read(c, 0x0000), 0)
}
