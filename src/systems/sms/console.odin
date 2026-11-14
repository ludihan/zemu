// Package sms emulates the Sega Master System and Game Gear.
package sms

import "base:runtime"
import "../../emu"

LINE_CYCLES     :: 228
LINES_PER_FRAME :: 262
CART_RAM_SIZE   :: 0x8000

Console :: struct {
	z80:          Z80,
	vdp:          Vdp,
	psg:          Psg,
	rom:          []u8,
	rom_banks:    int,
	ram:          [0x2000]u8,
	cart_ram:     [CART_RAM_SIZE]u8,
	cart_ram_used: bool, // a game enabled cartridge RAM: worth saving
	mapper:       [4]u8, // $FFFC-$FFFF
	game_gear:    bool,
	io_control:   u8,
	pads:         [2]emu.Buttons,
	pause_held:   bool,
	line_cycles:  int,
	line:         int,
	frame_ready:  bool,
	audio:        ^emu.Audio_Buffer,
	fingerprint:  u64,
	allocator:    runtime.Allocator,
	patches:      emu.Patch_List,
}

create :: proc(rom: []u8, game_gear: bool, allocator := context.allocator) -> (^Console, emu.Load_Error) {
	data := rom
	if len(data) % 0x4000 == 512 {
		data = data[512:] // copier header
	}
	if len(data) < 0x2000 {
		return nil, .Truncated
	}
	c, err := new(Console, allocator)
	if err != nil {
		return nil, .Out_Of_Memory
	}
	c.allocator = allocator
	// Pad to a power-of-two number of 16 KiB banks so bank masks stay inside.
	size := 0x4000
	for size < len(data) {
		size *= 2
	}
	c.rom = make([]u8, size, allocator)
	copy(c.rom, data)
	for i in len(data) ..< size {
		c.rom[i] = 0xFF
	}
	c.rom_banks = size / 0x4000
	c.game_gear = game_gear
	c.vdp.game_gear = game_gear
	c.fingerprint = emu.fingerprint(data)
	c.z80.bus = {user = c, read = bus_read, write = bus_write, input = port_in, output = port_out}
	reset(c)
	return c, .None
}

destroy :: proc(c: ^Console) {
	if c == nil {
		return
	}
	allocator := c.allocator
	delete(c.rom, allocator)
	free(c, allocator)
}

reset :: proc(c: ^Console) {
	z80_reset(&c.z80)
	vdp_reset(&c.vdp)
	psg_reset(&c.psg)
	c.mapper = {0, 0, 1, 2}
	c.line = LINES_PER_FRAME - 1 // the first line transition starts line 0
	c.line_cycles = 0
	c.z80.sp = 0xDFF0
	c.z80.im = 1
}

run_frame :: proc(c: ^Console, input: emu.Input, audio: ^emu.Audio_Buffer) {
	c.pads = input.pads
	c.audio = audio
	defer c.audio = nil
	// The Master System's pause button is wired to the NMI line.
	pause := .Start in input.pads[0] && !c.game_gear
	if pause && !c.pause_held {
		c.z80.nmi_pending = true
	}
	c.pause_held = pause

	c.frame_ready = false
	budget := LINE_CYCLES * LINES_PER_FRAME * 2
	for !c.frame_ready && budget > 0 {
		c.z80.irq_line = vdp_irq(&c.vdp)
		n := z80_step(&c.z80)
		budget -= n
		psg_step(&c.psg, n, c.audio)
		c.line_cycles += n
		for c.line_cycles >= LINE_CYCLES {
			c.line_cycles -= LINE_CYCLES
			c.line = (c.line + 1) % LINES_PER_FRAME
			if vdp_line(&c.vdp, c.line) {
				c.frame_ready = true
			}
		}
	}
}

frame :: proc(c: ^Console) -> emu.Frame {
	if c.game_gear {
		return {pixels = c.vdp.gg_frame[:], width = GG_W, height = GG_H, pitch = GG_W}
	}
	return {pixels = c.vdp.framebuffer[:], width = SCREEN_W, height = SCREEN_H, pitch = SCREEN_W}
}

save_ram :: proc(c: ^Console) -> []u8 {
	return c.cart_ram_used ? c.cart_ram[:] : nil
}

load_save_ram :: proc(c: ^Console, data: []u8) {
	copy(c.cart_ram[:], data)
	c.cart_ram_used = true
}

// --- memory -------------------------------------------------------------------

@(private = "file")
rom_byte :: #force_inline proc(c: ^Console, bank: u8, addr: u16) -> u8 {
	b := int(bank) & (c.rom_banks - 1)
	return c.rom[b * 0x4000 + int(addr & 0x3FFF)]
}

bus_read :: proc(user: rawptr, addr: u16) -> u8 {
	c := (^Console)(user)
	v: u8
	switch addr {
	case 0x0000 ..= 0x03FF:
		v = c.rom[addr] // first 1 KiB is never paged
	case 0x0400 ..= 0x3FFF:
		v = rom_byte(c, c.mapper[1], addr)
	case 0x4000 ..= 0x7FFF:
		v = rom_byte(c, c.mapper[2], addr)
	case 0x8000 ..= 0xBFFF:
		if c.mapper[0] & 0x08 != 0 {
			bank := int(c.mapper[0] >> 2) & 1
			return c.cart_ram[bank * 0x4000 + int(addr & 0x3FFF)]
		}
		v = rom_byte(c, c.mapper[3], addr)
	case:
		return c.ram[addr & 0x1FFF]
	}
	if c.patches.count > 0 {
		v = emu.patch_apply(&c.patches, u32(addr), v)
	}
	return v
}

bus_write :: proc(user: rawptr, addr: u16, v: u8) {
	c := (^Console)(user)
	switch addr {
	case 0x8000 ..= 0xBFFF:
		if c.mapper[0] & 0x08 != 0 {
			bank := int(c.mapper[0] >> 2) & 1
			c.cart_ram[bank * 0x4000 + int(addr & 0x3FFF)] = v
			c.cart_ram_used = true
		}
	case 0xC000 ..= 0xFFFF:
		c.ram[addr & 0x1FFF] = v
		if addr >= 0xFFFC {
			c.mapper[addr - 0xFFFC] = v
		}
	}
}

// --- I/O ports -------------------------------------------------------------------

@(private = "file")
pad_port_a :: proc(c: ^Console) -> u8 {
	v: u8 = 0xFF
	p1, p2 := c.pads[0], c.pads[1]
	if .Up in p1    {v &= ~u8(0x01)}
	if .Down in p1  {v &= ~u8(0x02)}
	if .Left in p1  {v &= ~u8(0x04)}
	if .Right in p1 {v &= ~u8(0x08)}
	if .B in p1     {v &= ~u8(0x10)} // button 1
	if .A in p1     {v &= ~u8(0x20)} // button 2
	if .Up in p2    {v &= ~u8(0x40)}
	if .Down in p2  {v &= ~u8(0x80)}
	return v
}

@(private = "file")
pad_port_b :: proc(c: ^Console) -> u8 {
	v: u8 = 0xFF
	p2 := c.pads[1]
	if .Left in p2  {v &= ~u8(0x01)}
	if .Right in p2 {v &= ~u8(0x02)}
	if .B in p2     {v &= ~u8(0x04)}
	if .A in p2     {v &= ~u8(0x08)}
	// TH lines: an export console reads back what was written when they are
	// set as outputs (games use this to detect a Japanese console).
	if c.io_control & 0x02 == 0 {
		v = (v & ~u8(0x40)) | ((c.io_control >> 1) & 0x40)
	}
	if c.io_control & 0x08 == 0 {
		v = (v & ~u8(0x80)) | (c.io_control & 0x80)
	}
	return v
}

port_in :: proc(user: rawptr, port: u16) -> u8 {
	c := (^Console)(user)
	p := u8(port)
	if c.game_gear && p <= 0x06 {
		switch p {
		case 0x00:
			v: u8 = 0x7F | 0x40 // bit 6: export console
			if .Start in c.pads[0] {v &= 0x7F} else {v |= 0x80}
			return v
		case 0x01 ..= 0x05: return 0x00
		case 0x06: return c.psg.stereo
		}
	}
	switch p & 0xC1 {
	case 0x40: return vdp_v_counter(&c.vdp)
	case 0x41: return h_counter(c)
	case 0x80: return vdp_read_data(&c.vdp)
	case 0x81: return vdp_read_status(&c.vdp)
	case 0xC0: return pad_port_a(c)
	case 0xC1: return pad_port_b(c)
	}
	return 0xFF
}

// The VDP's horizontal counter: 342 pixels per line (1.5 per CPU cycle),
// counted in pairs, with the count jumping from $93 to $E9 during the
// horizontal blank so it reads $00-$93 then $E9-$FF.
@(private = "file")
h_counter :: proc(c: ^Console) -> u8 {
	pixel := c.line_cycles * 342 / LINE_CYCLES
	hc := pixel >> 1
	if hc > 0x93 {
		hc += 0xE9 - 0x94
	}
	return u8(hc)
}

port_out :: proc(user: rawptr, port: u16, v: u8) {
	c := (^Console)(user)
	p := u8(port)
	if c.game_gear && p <= 0x06 {
		if p == 0x06 {
			c.psg.stereo = v
		}
		return
	}
	switch p & 0xC1 {
	case 0x01: c.io_control = v
	case 0x40, 0x41: psg_write(&c.psg, v)
	case 0x80: vdp_write_data(&c.vdp, v)
	case 0x81: vdp_write_control(&c.vdp, v)
	}
}

// Writes RAM for cheat codes.
poke :: proc(c: ^Console, addr: u32, v: u8) {
	if addr >= 0xC000 && addr <= 0xFFFF {
		c.ram[addr & 0x1FFF] = v
	}
}

fps :: proc(c: ^Console) -> f64 {
	return f64(CPU_CLOCK) / f64(LINE_CYCLES * LINES_PER_FRAME)
}

// --- save states ---------------------------------------------------------------

save_state :: proc(c: ^Console, allocator := context.allocator) -> []u8 {
	data, _ := emu.state_write(.SMS, c.fingerprint, c, size_of(Console), {}, allocator)
	return data
}

load_state :: proc(c: ^Console, data: []u8) -> bool {
	if !emu.state_valid(data, .SMS, c.fingerprint, size_of(Console), {}) {
		return false
	}
	rom, audio, allocator, fp, bus := c.rom, c.audio, c.allocator, c.fingerprint, c.z80.bus
	emu.state_read(data, c, size_of(Console), {})
	c.rom, c.audio, c.allocator, c.fingerprint = rom, audio, allocator, fp
	c.z80.bus = bus
	c.z80.bus.user = c // the bus points back at this console
	return true
}
