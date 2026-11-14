package gba

import "core:time"

// Seiko S-3511 real-time clock on the cartridge's GPIO port (0x080000C4-C9),
// used by Pokémon Ruby/Sapphire/Emerald, Boktai and a few others. Pins:
// bit 0 SCK, bit 1 SIO, bit 2 CS. Bits travel LSB first, values in BCD.

Rtc :: struct {
	present:   bool,
	pins:      u8, // last value the game wrote
	direction: u8, // 1 = pin driven by the game
	readable:  bool,
	out_sio:   u8,
	step:      int,
	bits:      u8,
	bits_read: int,
	command:   u8,
	reading:   bool,
	remaining: int,
	control:   u8,
	clock:     [7]u8, // year, month, day, weekday, hour, minute, second
}

@(private = "file", rodata)
RTC_BYTES := [8]int{0, 0, 7, 0, 1, 0, 3, 0}

@(private = "file")
RTC_GAMES := [?]string{"AXV", "AXP", "BPE", "U3I", "U32", "U33", "BKA", "BR4"}

rtc_detect :: proc(r: ^Rtc, rom: []u8) {
	r^ = {}
	r.control = 0x40 // 24-hour mode
	if len(rom) < 0xB0 {
		return
	}
	code := string(rom[0xAC:0xAF])
	for g in RTC_GAMES {
		if code == g {
			r.present = true
		}
	}
}

@(private = "file")
bcd :: proc(v: int) -> u8 {
	return u8((v / 10) << 4 | (v % 10))
}

@(private = "file")
latch_time :: proc(r: ^Rtc) {
	now := time.now()
	y, mon, d := time.date(now)
	h, m, s := time.clock(now)
	hour := h
	if r.control & 0x40 == 0 {
		hour %= 12
	}
	r.clock = {
		bcd(y % 100), bcd(int(mon)), bcd(d), bcd(int(time.weekday(now))),
		bcd(hour) | (h >= 12 ? 0x80 : 0), bcd(m), bcd(s),
	}
}

@(private = "file")
begin_command :: proc(r: ^Rtc) {
	if r.remaining == 0 {
		// The command byte is sent MSB first, so read LSB first it appears
		// bit-reversed: magic 0110 in the low nibble, R/W in bit 7.
		if r.bits & 0x0F != 0x06 {
			return
		}
		r.command = (r.bits >> 4) & 7
		r.reading = r.bits & 0x80 != 0
		switch r.command {
		case 0: r.control = 0 // reset
		case 2, 6: latch_time(r)
		}
		r.remaining = RTC_BYTES[r.command]
	} else {
		if r.command == 4 {
			r.control = r.bits
		}
		r.remaining -= 1
		if r.remaining <= 0 {
			r.command = 0
		}
	}
	r.bits = 0
}

@(private = "file")
output_bit :: proc(r: ^Rtc) -> u8 {
	b: u8
	switch r.command {
	case 4: b = r.control
	case 2, 6:
		i := 7 - r.remaining
		if i >= 0 && i < 7 {b = r.clock[i]}
	}
	return (b >> uint(r.bits_read)) & 1
}

@(private = "file")
update :: proc(r: ^Rtc) {
	p := r.pins
	switch r.step {
	case 0:
		if p & 5 == 1 {r.step = 1}
	case 1:
		if p & 5 == 5 {
			r.step = 2
		} else if p & 5 != 1 {
			r.step = 0
		}
	case 2:
		if p & 1 == 0 {
			r.bits &= ~(u8(1) << uint(r.bits_read))
			r.bits |= ((p >> 1) & 1) << uint(r.bits_read)
		} else if p & 4 != 0 {
			if !r.reading || r.remaining == 0 {
				r.bits_read += 1
				if r.bits_read == 8 {
					r.bits_read = 0
					begin_command(r)
				}
			} else {
				r.out_sio = output_bit(r)
				r.bits_read += 1
				if r.bits_read == 8 {
					r.bits_read = 0
					r.remaining -= 1
					if r.remaining <= 0 {
						r.command = 0
						r.reading = false
					}
				}
			}
		} else {
			r.bits_read, r.remaining, r.command, r.reading = 0, 0, 0, false
			r.step = int(p & 1)
		}
	}
}

// Returns true when the address is a GPIO register the RTC handles.
rtc_read :: proc(r: ^Rtc, addr: u32) -> (u16, bool) {
	if !r.present || !r.readable || addr < 0x0800_00C4 || addr > 0x0800_00C9 {
		return 0, false
	}
	switch addr & ~u32(1) {
	case 0x0800_00C4:
		v := r.pins & r.direction
		if r.direction & 2 == 0 {
			v |= r.out_sio << 1
		}
		return u16(v), true
	case 0x0800_00C6: return u16(r.direction), true
	case 0x0800_00C8: return 1, true
	}
	return 0, false
}

rtc_write :: proc(r: ^Rtc, addr: u32, v: u16) {
	if !r.present {
		return
	}
	switch addr & ~u32(1) {
	case 0x0800_00C4:
		r.pins = (r.pins & ~r.direction) | (u8(v) & r.direction & 0xF)
		update(r)
	case 0x0800_00C6: r.direction = u8(v) & 0xF
	case 0x0800_00C8: r.readable = v & 1 != 0
	}
}
