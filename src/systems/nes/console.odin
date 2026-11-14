// Package nes emulates the Nintendo Entertainment System / Famicom (NTSC).
package nes

import "../../emu"

Console :: struct {
	cpu:       Cpu,
	ppu:       Ppu,
	apu:       Apu,
	cart:      Cartridge,
	ram:       [0x800]u8,
	vram:      [0x1000]u8, // 2 KiB console RAM + 2 KiB for four-screen carts
	open_bus:  u8,
	dmc_stall: int,

	pads:      [2]emu.Buttons,
	pad_shift: [2]u8,
	strobe:    bool,

	audio:     ^emu.Audio_Buffer, // only set while `run_frame` is running
	fingerprint: u64, // hash of the ROM image, ties save states to the game
}

// Creates a console from an iNES image. Returns nil and an error on failure.
create :: proc(rom: []u8, allocator := context.allocator) -> (^Console, emu.Load_Error) {
	c, alloc_err := new(Console, allocator)
	if alloc_err != nil {
		return nil, .Out_Of_Memory
	}
	if err := cart_load(&c.cart, rom, allocator); err != .None {
		free(c, allocator)
		return nil, err
	}
	c.fingerprint = emu.fingerprint(rom)
	power_on(c)
	return c, .None
}

destroy :: proc(c: ^Console, allocator := context.allocator) {
	if c == nil {
		return
	}
	cart_destroy(&c.cart, allocator)
	free(c, allocator)
}

power_on :: proc(c: ^Console) {
	c.ram = {}
	c.vram = {}
	ppu_reset(&c.ppu)
	apu_reset(&c.apu)
	cart_reset(&c.cart)
	cpu_power_on(c)
}

reset :: proc(c: ^Console) {
	ppu_reset(&c.ppu)
	apu_reset(&c.apu)
	cart_reset(&c.cart)
	cpu_reset(c)
}

// Runs until the PPU finishes a frame. Audio samples are appended to `audio`.
run_frame :: proc(c: ^Console, input: emu.Input, audio: ^emu.Audio_Buffer) {
	c.pads = input.pads
	c.audio = audio
	defer c.audio = nil

	c.ppu.frame_ready = false
	// A frame is ~29780 CPU cycles; the cap guards against a stuck PPU.
	start := c.cpu.cycles
	for !c.ppu.frame_ready && c.cpu.cycles - start < 40000 {
		cpu_step(c)
	}
}

// The visible picture. `crop_overscan` hides the 8 rows at the top and
// bottom that NTSC televisions did not show.
frame :: proc(c: ^Console, crop_overscan: bool) -> emu.Frame {
	if crop_overscan {
		return {
			pixels = c.ppu.framebuffer[8 * SCREEN_WIDTH:(SCREEN_HEIGHT - 8) * SCREEN_WIDTH],
			width  = SCREEN_WIDTH,
			height = SCREEN_HEIGHT - 16,
			pitch  = SCREEN_WIDTH,
		}
	}
	return {pixels = c.ppu.framebuffer[:], width = SCREEN_WIDTH, height = SCREEN_HEIGHT, pitch = SCREEN_WIDTH}
}

// Battery-backed RAM to persist, or nil when the cartridge has none.
save_ram :: proc(c: ^Console) -> []u8 {
	return c.cart.battery ? c.cart.prg_ram[:] : nil
}

load_save_ram :: proc(c: ^Console, data: []u8) {
	copy(c.cart.prg_ram[:], data)
}

// --- bus -------------------------------------------------------------------

// One CPU cycle: three PPU dots and one APU cycle.
tick :: proc(c: ^Console) {
	c.cpu.poll_nmi = c.cpu.nmi_pending
	c.cpu.poll_irq = irq_asserted(c)
	c.cpu.cycles += 1
	ppu_step(c)
	ppu_step(c)
	ppu_step(c)
	cart_cpu_clock(&c.cart)
	apu_step(c)

	line := ppu_nmi_line(&c.ppu)
	if line && !c.cpu.nmi_line {
		c.cpu.nmi_pending = true
	}
	c.cpu.nmi_line = line
}

irq_asserted :: #force_inline proc(c: ^Console) -> bool {
	return apu_irq(&c.apu) || c.cart.irq
}

// Untimed bus read. Use `read` from the CPU so the clock advances.
bus_read :: proc(c: ^Console, addr: u16) -> u8 {
	v := c.open_bus
	switch addr {
	case 0x0000 ..= 0x1FFF:
		v = c.ram[addr & 0x07FF]
	case 0x2000 ..= 0x3FFF:
		v = ppu_reg_read(c, addr)
	case 0x4015:
		v = (apu_read_status(&c.apu) & 0xDF) | (c.open_bus & 0x20)
	case 0x4016, 0x4017:
		port := int(addr - 0x4016)
		if c.strobe {
			c.pad_shift[port] = pad_bits(c.pads[port])
		}
		bit := c.pad_shift[port] & 1
		c.pad_shift[port] = (c.pad_shift[port] >> 1) | 0x80 // reads 1 after 8 bits
		v = (c.open_bus & 0xE0) | bit
	case 0x4020 ..= 0xFFFF:
		v = cart_cpu_read(&c.cart, addr, c.open_bus)
	}
	c.open_bus = v
	return v
}

bus_write :: proc(c: ^Console, addr: u16, value: u8) {
	c.open_bus = value
	switch addr {
	case 0x0000 ..= 0x1FFF:
		c.ram[addr & 0x07FF] = value
	case 0x2000 ..= 0x3FFF:
		ppu_reg_write(c, addr, value)
	case 0x4014:
		oam_dma(c, value)
	case 0x4016:
		c.strobe = value & 1 != 0
		if c.strobe {
			c.pad_shift[0] = pad_bits(c.pads[0])
			c.pad_shift[1] = pad_bits(c.pads[1])
		}
	case 0x4000 ..= 0x4013, 0x4015, 0x4017:
		apu_write(&c.apu, addr, value)
	case 0x4018 ..= 0xFFFF:
		cart_cpu_write(&c.cart, addr, value, c.cpu.cycles)
	}
}

@(private = "file")
oam_dma :: proc(c: ^Console, page: u8) {
	tick(c)
	if c.cpu.cycles & 1 != 0 {
		tick(c)
	}
	base := u16(page) << 8
	for i in u16(0) ..< 256 {
		tick(c)
		v := bus_read(c, base + i)
		tick(c)
		c.ppu.oam[c.ppu.oam_addr] = v
		c.ppu.oam_addr += 1
	}
	flush_dmc_stall(c)
}

// Applies cycles the CPU lost to DMC sample fetches.
flush_dmc_stall :: proc(c: ^Console) {
	for c.dmc_stall > 0 {
		c.dmc_stall -= 1
		tick(c)
	}
}

@(private = "file")
pad_bits :: proc(b: emu.Buttons) -> u8 {
	v: u8
	if .A in b      {v |= 0x01}
	if .B in b      {v |= 0x02}
	if .Select in b {v |= 0x04}
	if .Start in b  {v |= 0x08}
	if .Up in b     {v |= 0x10}
	if .Down in b   {v |= 0x20}
	if .Left in b   {v |= 0x40}
	if .Right in b  {v |= 0x80}
	// Opposite directions cannot both be held on a real pad; some games crash.
	if v & 0x30 == 0x30 {v &= ~u8(0x30)}
	if v & 0xC0 == 0xC0 {v &= ~u8(0xC0)}
	return v
}

// --- save states -----------------------------------------------------------

// Serializes the whole machine. CHR RAM is the only state kept outside
// the struct.
save_state :: proc(c: ^Console, allocator := context.allocator) -> []u8 {
	data, _ := emu.state_write(.NES, c.fingerprint, c, size_of(Console), {chr_ram(c)}, allocator)
	return data
}

load_state :: proc(c: ^Console, data: []u8) -> bool {
	if !emu.state_valid(data, .NES, c.fingerprint, size_of(Console), {chr_ram(c)}) {
		return false
	}
	// Fields that point outside the struct keep their live values.
	prg, chr, audio, fp := c.cart.prg_rom, c.cart.chr, c.audio, c.fingerprint
	emu.state_read(data, c, size_of(Console), {chr_ram(c)})
	c.cart.prg_rom, c.cart.chr, c.audio, c.fingerprint = prg, chr, audio, fp
	return true
}

@(private = "file")
chr_ram :: proc(c: ^Console) -> []u8 {
	return c.cart.chr_is_ram ? c.cart.chr : nil
}
