// Package snes emulates the Super Nintendo Entertainment System (NTSC).
package snes

import "base:intrinsics"

import "../../emu"

MASTER_CLOCK     :: 21_477_272
MASTER_CLOCK_PAL :: 21_281_370
APU_CLOCK       :: 1_024_000
LINE_CYCLES     :: 1364
LINES_PER_FRAME     :: 262
LINES_PER_FRAME_PAL :: 312
HDMA_DOT        :: 1104 // master cycle within the line where HBlank work happens
SAMPLE_RATE     :: 32000

Console :: struct {
	cpu:        Cpu,
	ppu:        Ppu,
	spc:        Spc,
	cart:       Cartridge,
	dma:        [8]Dma_Channel,
	wram:       [0x20000]u8,
	wram_addr:  u32,
	open_bus:   u8,

	// timing
	pending:    int, // master cycles spent by the CPU but not yet applied
	h:          int, // master cycle within the current line
	v:          int, // current line
	line_done:  bool, // HBlank work for this line already happened
	frame_ready: bool,
	frame_count: u64,
	apu_debt:   i64, // master clocks (scaled) the APU still has to run
	spc_sample_cycles: int,

	// CPU I/O registers
	nmitimen:   u8,
	nmi_flag:   bool,
	irq_flag:   bool,
	h_irq_done: bool,
	htime:      u16,
	vtime:      u16,
	wrmpya:     u8,
	wrdiv:      u16,
	rddiv:      u16,
	rdmpy:      u16,
	hdmaen:     u8,
	fast_rom:   bool,
	auto_joy_busy: int, // lines left while auto-joypad read is in progress
	joy:        [4]u16,
	joy_strobe: bool,
	joy_shift:  [2]u16,

	pads:       [2]emu.Buttons,
	audio:      ^emu.Audio_Buffer,
	fingerprint: u64, // hash of the ROM image, ties save states to the game
	pal:        bool,
	patches:    emu.Patch_List, // Game Genie
}

// `pal` forces PAL timing; otherwise the header's destination code decides.
create :: proc(rom: []u8, pal := false, allocator := context.allocator) -> (^Console, emu.Load_Error) {
	c, alloc_err := new(Console, allocator)
	if alloc_err != nil {
		return nil, .Out_Of_Memory
	}
	if err := cart_load(&c.cart, rom, allocator); err != .None {
		free(c, allocator)
		return nil, err
	}
	c.spc.dsp.ram = &c.spc.ram
	c.fingerprint = emu.fingerprint(rom)
	c.pal = pal || c.cart.pal
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
	for &b in c.wram {b = 0x55}
	// Zero in place: the PPU holds the framebuffers and is too big for a stack temporary.
	intrinsics.mem_zero(&c.ppu, size_of(Ppu))
	reset(c)
}

reset :: proc(c: ^Console) {
	ppu_reset(&c.ppu)
	spc_reset(&c.spc)
	c.dma = {}
	c.nmitimen = 0
	c.hdmaen = 0
	c.nmi_flag = false
	c.irq_flag = false
	c.fast_rom = false
	c.htime = 0x1FF
	c.vtime = 0x1FF
	c.h = 0
	c.v = 0
	c.pending = 0
	c.apu_debt = 0
	c.line_done = false
	cpu_reset(c)
}

// Runs until the start of the next vertical blank.
run_frame :: proc(c: ^Console, input: emu.Input, audio: ^emu.Audio_Buffer) {
	c.pads = input.pads
	c.audio = audio
	defer c.audio = nil
	c.frame_ready = false
	// A frame is ~357k master cycles; the cap protects against a wedged CPU.
	budget := LINE_CYCLES * LINES_PER_FRAME_PAL * 2
	for !c.frame_ready && budget > 0 {
		before := c.pending
		cpu_step(c)
		budget -= max(c.pending - before, 1)
		sync(c)
	}
}

frame :: proc(c: ^Console) -> emu.Frame {
	p := &c.ppu
	h := clamp(p.height, 1, MAX_HEIGHT)
	if p.hires_frame {
		return {pixels = p.fb_high[:HIRES_WIDTH * h], width = HIRES_WIDTH, height = h, pitch = HIRES_WIDTH}
	}
	return {pixels = p.fb_low[:SCREEN_WIDTH * h], width = SCREEN_WIDTH, height = h, pitch = SCREEN_WIDTH}
}

fps :: proc(c: ^Console) -> f64 {
	return c.pal ? 50.0070 : 60.0988
}

save_ram :: proc(c: ^Console) -> []u8 {
	return c.cart.battery ? c.cart.sram : nil
}

load_save_ram :: proc(c: ^Console, data: []u8) {
	copy(c.cart.sram, data)
}

// --- timing ----------------------------------------------------------------

// Applies CPU time spent so far to the PPU timeline and the APU.
sync :: proc(c: ^Console) {
	for c.pending > 0 {
		n := c.pending
		c.pending = 0
		advance(c, n)
	}
}

@(private = "file")
irq_mode :: #force_inline proc(c: ^Console) -> u8 {
	return (c.nmitimen >> 4) & 3
}

@(private = "file")
raise_irq :: proc(c: ^Console) {
	c.irq_flag = true
	c.cpu.irq_line = true
}

@(private = "file")
advance :: proc(c: ^Console, cycles: int) {
	run_apu(c, cycles)
	remaining := cycles
	for remaining > 0 {
		// step to the next event on this line (H-IRQ, HBlank work, line end)
		next := LINE_CYCLES
		mode := irq_mode(c)
		h_irq_at := int(c.htime) * 4 + 14
		if (mode == 1 || (mode == 3 && u16(c.v) == c.vtime)) && !c.h_irq_done && h_irq_at < LINE_CYCLES {
			next = min(next, max(h_irq_at, c.h + 1))
		}
		if !c.line_done {
			next = min(next, max(HDMA_DOT, c.h + 1))
		}
		step := min(remaining, next - c.h)
		if step <= 0 {
			step = 1
		}
		c.h += step
		remaining -= step

		if (mode == 1 || (mode == 3 && u16(c.v) == c.vtime)) && !c.h_irq_done && c.h >= h_irq_at {
			c.h_irq_done = true
			raise_irq(c)
		}
		if !c.line_done && c.h >= HDMA_DOT {
			c.line_done = true
			if c.v <= c.ppu.height {
				ppu_render_line(c, c.v)
				hdma_line(c)
			}
		}
		if c.h >= LINE_CYCLES {
			c.h -= LINE_CYCLES
			new_line(c)
		}
	}
}

@(private = "file")
new_line :: proc(c: ^Console) {
	c.v += 1
	c.line_done = false
	c.h_irq_done = false
	if c.v >= (c.pal ? LINES_PER_FRAME_PAL : LINES_PER_FRAME) {
		c.v = 0
		c.nmi_flag = false
		c.frame_count += 1
		ppu_frame_start(&c.ppu)
		hdma_init(c)
	}
	if c.v == c.ppu.height + 1 {
		// vertical blank
		c.nmi_flag = true
		if c.nmitimen & 0x80 != 0 {
			c.cpu.nmi_pending = true
		}
		ppu_vblank(&c.ppu)
		if c.nmitimen & 0x01 != 0 {
			auto_joypad(c)
		}
		c.frame_ready = true
	}
	if c.auto_joy_busy > 0 {
		c.auto_joy_busy -= 1
	}
	if irq_mode(c) == 2 && u16(c.v) == c.vtime {
		raise_irq(c)
	}
}

// Runs the sound CPU for the time equivalent of `master` main clocks.
@(private = "file")
run_apu :: proc(c: ^Console, master: int) {
	c.apu_debt += i64(master) * APU_CLOCK
	for c.apu_debt > 0 {
		cycles := spc_step(&c.spc)
		c.apu_debt -= i64(cycles) * (c.pal ? MASTER_CLOCK_PAL : MASTER_CLOCK)
		c.spc_sample_cycles += cycles
		for c.spc_sample_cycles >= 32 {
			c.spc_sample_cycles -= 32
			l, r := dsp_sample(&c.spc.dsp)
			if c.audio != nil {
				emu.audio_push(c.audio, l, r)
			}
		}
	}
}

// --- controllers -----------------------------------------------------------

@(private = "file")
pad_word :: proc(b: emu.Buttons) -> u16 {
	v: u16
	if .B in b      {v |= 0x8000}
	if .Y in b      {v |= 0x4000}
	if .Select in b {v |= 0x2000}
	if .Start in b  {v |= 0x1000}
	if .Up in b     {v |= 0x0800}
	if .Down in b   {v |= 0x0400}
	if .Left in b   {v |= 0x0200}
	if .Right in b  {v |= 0x0100}
	if .A in b      {v |= 0x0080}
	if .X in b      {v |= 0x0040}
	if .L in b      {v |= 0x0020}
	if .R in b      {v |= 0x0010}
	if v & 0x0C00 == 0x0C00 {v &= ~u16(0x0C00)}
	if v & 0x0300 == 0x0300 {v &= ~u16(0x0300)}
	return v
}

@(private = "file")
auto_joypad :: proc(c: ^Console) {
	c.joy[0] = pad_word(c.pads[0])
	c.joy[1] = pad_word(c.pads[1])
	c.joy[2] = 0
	c.joy[3] = 0
	c.joy_shift = {0, 0} // the serial ports have been read out
	c.auto_joy_busy = 3
}

// --- bus -------------------------------------------------------------------

@(private = "file")
access_cycles :: #force_inline proc(c: ^Console, addr: u32) -> int {
	bank := addr >> 16
	a := addr & 0xFFFF
	if bank & 0x40 == 0 {
		switch {
		case a < 0x2000: return 8
		case a < 0x4000: return 6
		case a < 0x4200: return 12
		case a < 0x6000: return 6
		case a < 0x8000: return 8
		}
		return bank & 0x80 != 0 && c.fast_rom ? 6 : 8
	}
	if bank >= 0xC0 && c.fast_rom {
		return 6
	}
	return 8
}

@(private = "file")
is_io :: #force_inline proc(addr: u32) -> bool {
	if addr & 0x400000 != 0 {
		return false
	}
	a := addr & 0xFFFF
	return a >= 0x2100 && a < 0x4400
}

// Timed CPU read: charges the access and keeps timing-sensitive I/O exact.
read :: proc(c: ^Console, addr: u32) -> u8 {
	c.pending += access_cycles(c, addr)
	if is_io(addr) {
		sync(c)
	}
	return bus_read(c, addr)
}

write :: proc(c: ^Console, addr: u32, v: u8) {
	c.pending += access_cycles(c, addr)
	if is_io(addr) {
		sync(c)
	}
	bus_write(c, addr, v)
}

// Side-effect-free read for vectors.
bus_peek :: proc(c: ^Console, addr: u32) -> u8 {
	v, _ := cart_read(&c.cart, u8(addr >> 16), u16(addr))
	return v
}

bus_read :: proc(c: ^Console, addr: u32) -> u8 {
	bank := u8(addr >> 16)
	a := u16(addr)
	v := c.open_bus
	switch {
	case bank == 0x7E || bank == 0x7F:
		v = c.wram[(u32(bank & 1) << 16) | u32(a)]
	case bank & 0x40 == 0 && a < 0x2000:
		v = c.wram[a]
	case bank & 0x40 == 0 && a >= 0x2100 && a < 0x2140:
		v = ppu_read(c, a)
	case bank & 0x40 == 0 && a >= 0x2140 && a < 0x2180:
		v = c.spc.port_out[a & 3]
	case bank & 0x40 == 0 && a == 0x2180:
		v = c.wram[c.wram_addr]
		c.wram_addr = (c.wram_addr + 1) & 0x1FFFF
	case bank & 0x40 == 0 && (a == 0x4016 || a == 0x4017):
		port := int(a - 0x4016)
		bit := u8(c.joy_shift[port] >> 15)
		c.joy_shift[port] = c.joy_shift[port] << 1 | 1
		v = (c.open_bus & 0xFC) | bit | (port == 1 ? 0x1C : 0)
	case bank & 0x40 == 0 && a >= 0x4200 && a < 0x4220:
		v = io_read(c, a)
	case bank & 0x40 == 0 && a >= 0x4300 && a < 0x4380:
		v = dma_read_reg(c, a)
	case:
		if cv, ok := cart_read(&c.cart, bank, a); ok {
			v = cv
			if c.patches.count > 0 {
				v = emu.patch_apply(&c.patches, addr & 0xFFFFFF, v)
			}
		}
	}
	c.open_bus = v
	return v
}

bus_write :: proc(c: ^Console, addr: u32, v: u8) {
	bank := u8(addr >> 16)
	a := u16(addr)
	c.open_bus = v
	switch {
	case bank == 0x7E || bank == 0x7F:
		c.wram[(u32(bank & 1) << 16) | u32(a)] = v
	case bank & 0x40 == 0 && a < 0x2000:
		c.wram[a] = v
	case bank & 0x40 == 0 && a >= 0x2100 && a < 0x2140:
		ppu_write(c, a, v)
	case bank & 0x40 == 0 && a >= 0x2140 && a < 0x2180:
		c.spc.port_in[a & 3] = v
	case bank & 0x40 == 0 && a == 0x2180:
		c.wram[c.wram_addr] = v
		c.wram_addr = (c.wram_addr + 1) & 0x1FFFF
	case bank & 0x40 == 0 && a == 0x2181:
		c.wram_addr = (c.wram_addr & 0x1FF00) | u32(v)
	case bank & 0x40 == 0 && a == 0x2182:
		c.wram_addr = (c.wram_addr & 0x100FF) | u32(v) << 8
	case bank & 0x40 == 0 && a == 0x2183:
		c.wram_addr = (c.wram_addr & 0x0FFFF) | u32(v & 1) << 16
	case bank & 0x40 == 0 && a == 0x4016:
		strobe := v & 1 != 0
		if c.joy_strobe && !strobe {
			c.joy_shift[0] = pad_word(c.pads[0])
			c.joy_shift[1] = pad_word(c.pads[1])
		}
		c.joy_strobe = strobe
	case bank & 0x40 == 0 && a >= 0x4200 && a < 0x4220:
		io_write(c, a, v)
	case bank & 0x40 == 0 && a >= 0x4300 && a < 0x4380:
		dma_write_reg(c, a, v)
	case:
		cart_write(&c.cart, bank, a, v)
	}
}

@(private = "file")
io_read :: proc(c: ^Console, a: u16) -> u8 {
	switch a {
	case 0x4210:
		v := u8(0x02) | (c.open_bus & 0x70)
		if c.nmi_flag {v |= 0x80}
		c.nmi_flag = false
		return v
	case 0x4211:
		v := c.open_bus & 0x7F
		if c.irq_flag {v |= 0x80}
		c.irq_flag = false
		c.cpu.irq_line = false
		return v
	case 0x4212:
		v := c.open_bus & 0x3E
		if c.v > c.ppu.height {v |= 0x80}
		if c.h >= HDMA_DOT - 8 || c.h < 4 {v |= 0x40}
		if c.auto_joy_busy > 0 {v |= 0x01}
		return v
	case 0x4213: return 0xFF
	case 0x4214: return u8(c.rddiv)
	case 0x4215: return u8(c.rddiv >> 8)
	case 0x4216: return u8(c.rdmpy)
	case 0x4217: return u8(c.rdmpy >> 8)
	case 0x4218 ..= 0x421F:
		j := c.joy[(a - 0x4218) / 2]
		return (a & 1 == 0) ? u8(j) : u8(j >> 8)
	}
	return c.open_bus
}

@(private = "file")
io_write :: proc(c: ^Console, a: u16, v: u8) {
	switch a {
	case 0x4200:
		was_enabled := c.nmitimen & 0x80 != 0
		c.nmitimen = v
		if !was_enabled && v & 0x80 != 0 && c.nmi_flag {
			c.cpu.nmi_pending = true
		}
		if v & 0x30 == 0 {
			c.irq_flag = false
			c.cpu.irq_line = false
		}
	case 0x4201:
		if v & 0x80 == 0 {
			ppu_latch_counters(c)
		}
	case 0x4202:
		c.wrmpya = v
	case 0x4203:
		c.rdmpy = u16(c.wrmpya) * u16(v)
		c.rddiv = u16(v)
	case 0x4204:
		c.wrdiv = (c.wrdiv & 0xFF00) | u16(v)
	case 0x4205:
		c.wrdiv = (c.wrdiv & 0x00FF) | u16(v) << 8
	case 0x4206:
		if v == 0 {
			c.rddiv = 0xFFFF
			c.rdmpy = c.wrdiv
		} else {
			c.rddiv = c.wrdiv / u16(v)
			c.rdmpy = c.wrdiv % u16(v)
		}
	case 0x4207: c.htime = (c.htime & 0x100) | u16(v)
	case 0x4208: c.htime = (c.htime & 0x0FF) | u16(v & 1) << 8
	case 0x4209: c.vtime = (c.vtime & 0x100) | u16(v)
	case 0x420A: c.vtime = (c.vtime & 0x0FF) | u16(v & 1) << 8
	case 0x420B: dma_run(c, v)
	case 0x420C: c.hdmaen = v
	case 0x420D: c.fast_rom = v & 1 != 0
	}
}

// --- save states -----------------------------------------------------------

// Serializes the whole machine; cartridge SRAM travels alongside.
save_state :: proc(c: ^Console, allocator := context.allocator) -> []u8 {
	data, _ := emu.state_write(.SNES, c.fingerprint, c, size_of(Console), {c.cart.sram}, allocator)
	return data
}

load_state :: proc(c: ^Console, data: []u8) -> bool {
	if !emu.state_valid(data, .SNES, c.fingerprint, size_of(Console), {c.cart.sram}) {
		return false
	}
	rom, sram, audio, fp := c.cart.rom, c.cart.sram, c.audio, c.fingerprint
	emu.state_read(data, c, size_of(Console), {c.cart.sram})
	c.cart.rom, c.cart.sram, c.audio, c.fingerprint = rom, sram, audio, fp
	c.spc.dsp.ram = &c.spc.ram // interior pointer must point at this console
	return true
}

// Writes a byte for RAM cheat codes (Pro Action Replay).
poke :: proc(c: ^Console, addr: u32, v: u8) {
	bank := u8(addr >> 16)
	a := u16(addr)
	switch {
	case bank == 0x7E || bank == 0x7F:
		c.wram[(u32(bank & 1) << 16) | u32(a)] = v
	case bank & 0x40 == 0 && a < 0x2000:
		c.wram[a] = v
	case:
		cart_write(&c.cart, bank, a, v) // SRAM
	}
}
