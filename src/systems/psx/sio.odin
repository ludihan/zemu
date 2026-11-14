package psx

import "../../emu"

// Serial port 0: digital controllers and memory cards.

MEMCARD_SIZE   :: 128 * 1024
ACK_DELAY      :: 450 // CPU cycles from a byte transfer to the /ACK interrupt

Device :: enum u8 {
	None,
	Pad,
	Card,
}

Memory_Card :: struct {
	data:     [MEMCARD_SIZE]u8,
	fresh:    bool, // "new card" flag until the first write
	modified: bool, // written since load; only then is it worth saving
	present:  bool,
	cmd:      u8,
	sector:   u16,
	checksum: u8,
	last:     u8,
}

Sio :: struct {
	ctrl:       u16,
	mode:       u16,
	baud:       u16,
	rx:         u8,
	rx_full:    bool,
	irq:        bool,
	ack_timer:  int,
	device:     Device,
	step:       int,
	cards:      [2]Memory_Card,
}

sio_reset :: proc(s: ^Sio) {
	s.ctrl = 0
	s.mode = 0
	s.rx_full = false
	s.irq = false
	s.device = .None
	s.step = 0
	s.ack_timer = 0
	if !s.cards[0].present {
		s.cards[0] = {fresh = true, present = true}
		format_card(&s.cards[0])
	}
}

// Writes an empty, formatted directory so the BIOS and games accept the card.
@(private = "file")
format_card :: proc(card: ^Memory_Card) {
	card.data = {}
	card.data[0] = 'M'
	card.data[1] = 'C'
	card.data[127] = 'M' ~ 'C'
	for i in 1 ..< 16 {
		frame := card.data[i * 128:][:128]
		frame[0] = 0xA0 // free block
		frame[8] = 0xFF
		frame[9] = 0xFF
		x: u8 = 0
		for b in frame[:127] {x ~= b}
		frame[127] = x
	}
	for i in 16 ..< 36 {
		frame := card.data[i * 128:][:128]
		for k in 0 ..< 4 {frame[k] = 0xFF}
		frame[8] = 0xFF
		frame[9] = 0xFF
	}
	copy(card.data[63 * 128:], card.data[0:128]) // write test frame
}

pad_bytes :: proc(b: emu.Buttons) -> (lo, hi: u8) {
	lo, hi = 0xFF, 0xFF
	if .Select in b {lo &= ~u8(0x01)}
	if .Start in b  {lo &= ~u8(0x08)}
	if .Up in b     {lo &= ~u8(0x10)}
	if .Right in b  {lo &= ~u8(0x20)}
	if .Down in b   {lo &= ~u8(0x40)}
	if .Left in b   {lo &= ~u8(0x80)}
	if .L2 in b     {hi &= ~u8(0x01)}
	if .R2 in b     {hi &= ~u8(0x02)}
	if .L in b      {hi &= ~u8(0x04)}
	if .R in b      {hi &= ~u8(0x08)}
	if .X in b      {hi &= ~u8(0x10)} // triangle (north)
	if .A in b      {hi &= ~u8(0x20)} // circle (east)
	if .B in b      {hi &= ~u8(0x40)} // cross (south)
	if .Y in b      {hi &= ~u8(0x80)} // square (west)
	return
}

// Exchanges one byte with the selected device. Returns the reply and
// whether the device acknowledged (more bytes expected).
@(private = "file")
exchange :: proc(c: ^Console, tx: u8) -> (rx: u8, ack: bool) {
	s := &c.sio
	port := int((s.ctrl >> 13) & 1)

	if s.device == .None {
		switch tx {
		case 0x01:
			s.device = .Pad
			s.step = 0
		case 0x81:
			if !s.cards[port].present {
				return 0xFF, false
			}
			s.device = .Card
			s.step = 0
		case:
			return 0xFF, false
		}
	}

	switch s.device {
	case .None:
		return 0xFF, false
	case .Pad:
		lo, hi := pad_bytes(c.pads[port])
		step := s.step
		s.step += 1
		switch step {
		case 0: return 0xFF, true
		case 1: return 0x41, tx == 0x42 // digital pad ID
		case 2: return 0x5A, true
		case 3: return lo, true
		case 4:
			s.device = .None
			return hi, false
		}
		s.device = .None
		return 0xFF, false
	case .Card:
		return card_exchange(s, &s.cards[port], tx)
	}
	return 0xFF, false
}

@(private = "file")
card_exchange :: proc(s: ^Sio, card: ^Memory_Card, tx: u8) -> (u8, bool) {
	step := s.step
	s.step += 1
	flag: u8 = card.fresh ? 0x08 : 0x00
	if step == 0 {
		return 0xFF, true
	}
	if step == 1 {
		card.cmd = tx
		return flag, true
	}
	switch card.cmd {
	case 'R':
		switch step {
		case 2: return 0x5A, true
		case 3: return 0x5D, true
		case 4:
			card.sector = u16(tx) << 8
			return 0x00, true
		case 5:
			card.sector |= u16(tx)
			card.last = tx
			return u8(card.sector >> 8), true
		case 6: return 0x5C, true
		case 7: return 0x5D, true
		case 8:
			card.sector &= 0x3FF
			card.checksum = u8(card.sector >> 8) ~ u8(card.sector)
			return u8(card.sector >> 8), true
		case 9: return u8(card.sector), true
		case 10 ..< 138:
			b := card.data[int(card.sector) * 128 + (step - 10)]
			card.checksum ~= b
			return b, true
		case 138: return card.checksum, true
		case 139:
			s.device = .None
			return 0x47, false
		}
	case 'W':
		switch step {
		case 2: return 0x5A, true
		case 3: return 0x5D, true
		case 4:
			card.sector = u16(tx) << 8
			card.last = tx
			return 0x00, true
		case 5:
			card.sector = (card.sector | u16(tx)) & 0x3FF
			card.checksum = u8(card.sector >> 8) ~ u8(card.sector)
			prev := card.last
			card.last = tx
			return prev, true
		case 6 ..< 134:
			card.data[int(card.sector) * 128 + (step - 6)] = tx
			card.checksum ~= tx
			prev := card.last
			card.last = tx
			return prev, true
		case 134:
			prev := card.last
			card.last = tx // checksum byte from the host
			return prev, true
		case 135: return 0x5C, true
		case 136: return 0x5D, true
		case 137:
			card.fresh = false
			card.modified = true
			s.device = .None
			return 0x47, false
		}
	case 'S':
		@(static, rodata) ID := [8]u8{0x5A, 0x5D, 0x5C, 0x5D, 0x04, 0x00, 0x00, 0x80}
		if step - 2 < len(ID) {
			last := step - 2 == len(ID) - 1
			if last {s.device = .None}
			return ID[step - 2], !last
		}
	}
	s.device = .None
	return 0xFF, false
}

sio_read :: proc(c: ^Console, p: u32, size: u32) -> u32 {
	s := &c.sio
	switch p & 0xF {
	case 0x0:
		v := s.rx_full ? s.rx : 0xFF
		s.rx_full = false
		return u32(v) | (size > 1 ? 0xFFFF_FF00 : 0)
	case 0x4:
		v: u32 = 0x5 // TX ready, TX finished
		if s.rx_full {v |= 0x2}
		if s.irq {v |= 0x200}
		return v
	case 0x8:
		return u32(s.mode)
	case 0xA:
		return u32(s.ctrl)
	case 0xE:
		return u32(s.baud)
	}
	return 0
}

sio_write :: proc(c: ^Console, p: u32, v: u32, size: u32) {
	s := &c.sio
	switch p & 0xF {
	case 0x0:
		if s.ctrl & 0x0002 == 0 {
			// not selected: nothing answers
			s.rx = 0xFF
			s.rx_full = true
			return
		}
		rx, ack := exchange(c, u8(v))
		s.rx = rx
		s.rx_full = true
		if ack {
			s.ack_timer = ACK_DELAY
		}
	case 0x8:
		s.mode = u16(v)
	case 0xA:
		s.ctrl = u16(v)
		if v & 0x40 != 0 {
			s.ctrl = 0
			s.irq = false
			s.rx_full = false
			s.device = .None
		}
		if v & 0x10 != 0 {
			s.irq = false
		}
		if v & 0x0002 == 0 {
			s.device = .None // deselecting ends any transaction
		}
	case 0xE:
		s.baud = u16(v)
	}
}

sio_tick :: proc(c: ^Console, cycles: int) {
	s := &c.sio
	if s.ack_timer <= 0 {
		return
	}
	s.ack_timer -= cycles
	if s.ack_timer <= 0 {
		s.ack_timer = 0
		s.irq = true
		if s.ctrl & 0x1000 != 0 {
			request_irq(c, .Sio)
		}
	}
}
