// Package psx emulates the Sony PlayStation (NTSC).
package psx

import "base:runtime"

import "../../emu"

CPU_CLOCK       :: 33_868_800
LINE_CYCLES     :: 2153 // CPU cycles per scanline (3413 GPU clocks)
LINES_PER_FRAME :: 263
VBLANK_LINE     :: 240
SAMPLE_CYCLES   :: 768 // CPU cycles per 44.1 kHz audio sample

RAM_SIZE  :: 2 * 1024 * 1024
BIOS_SIZE :: 512 * 1024

Irq :: enum u32 {
	Vblank = 0,
	Gpu    = 1,
	Cdrom  = 2,
	Dma    = 3,
	Timer0 = 4,
	Timer1 = 5,
	Timer2 = 6,
	Sio    = 7,
	Spu    = 9,
}

Console :: struct {
	cpu:          Cpu,
	gte:          Gte,
	gpu:          Gpu,
	spu:          Spu,
	cdrom:        Cdrom,
	sio:          Sio,
	mdec:         Mdec,
	timers:       [3]Timer,
	dma:          Dma,

	ram:          [RAM_SIZE]u8,
	scratch:      [1024]u8,
	bios:         [BIOS_SIZE]u8,
	has_bios:     bool,

	i_stat:       u32,
	i_mask:       u32,
	cache_control: u32,

	cycles:       u64,
	line_cycle:   int,
	line:         int,
	sample_cycle: int,
	frame_ready:  bool,

	exe:          []u8, // PS-X EXE waiting to be side-loaded
	pads:         [2]emu.Buttons,
	audio:        ^emu.Audio_Buffer,
	allocator:    runtime.Allocator,
	fingerprint:  u64, // ties save states to the BIOS + game
}

// Creates a console. `bios` may be empty only when booting an EXE directly.
// `disc` may be nil (no disc inserted).
create :: proc(bios: []u8, disc: ^Disc, exe: []u8, allocator := context.allocator) -> (^Console, emu.Load_Error) {
	if len(bios) != 0 && len(bios) != BIOS_SIZE {
		return nil, .Bad_Bios
	}
	if len(bios) == 0 && len(exe) == 0 {
		return nil, .Missing_Bios
	}
	c, err := new(Console, allocator)
	if err != nil {
		return nil, .Out_Of_Memory
	}
	c.allocator = allocator
	if len(bios) == BIOS_SIZE {
		copy(c.bios[:], bios)
		c.has_bios = true
	}
	if len(exe) > 0 {
		if !exe_valid(exe) {
			free(c, allocator)
			return nil, .Bad_Header
		}
		c.exe = make([]u8, len(exe), allocator)
		copy(c.exe, exe)
	}
	c.cdrom.disc = disc
	c.fingerprint = emu.fingerprint(bios) ~ emu.fingerprint(exe)
	if disc != nil {
		// The first data sectors (license + volume descriptor) identify a disc.
		sector: [SECTOR_SIZE]u8
		for lba in 4 ..< 17 {
			if disc_read_sector(disc, lba, &sector) {
				c.fingerprint ~= emu.fingerprint(sector[:]) * u64(lba)
			}
		}
	}
	reset(c)
	return c, .None
}

destroy :: proc(c: ^Console) {
	if c == nil {
		return
	}
	allocator := c.allocator
	delete(c.exe, allocator)
	mdec_destroy(&c.mdec)
	disc_close(c.cdrom.disc)
	free(c, allocator)
}

reset :: proc(c: ^Console) {
	cpu_reset(c)
	gpu_reset(&c.gpu)
	spu_reset(&c.spu)
	cdrom_reset(&c.cdrom)
	sio_reset(&c.sio)
	mdec_reset(&c.mdec)
	c.gte = {}
	c.timers = {}
	c.dma = {}
	c.dma.dpcr = 0x0765_4321
	c.i_stat = 0
	c.i_mask = 0
	c.line = 0
	c.line_cycle = 0
	if !c.has_bios && len(c.exe) > 0 {
		// No BIOS: start the program directly (homebrew / test programs).
		exe_load(c)
	}
}

// Runs one video frame (until the start of vertical blank).
run_frame :: proc(c: ^Console, input: emu.Input, audio: ^emu.Audio_Buffer) {
	c.pads = input.pads
	c.audio = audio
	defer c.audio = nil
	c.frame_ready = false
	budget := LINE_CYCLES * LINES_PER_FRAME * 2
	for !c.frame_ready && budget > 0 {
		// Side-load an EXE once the BIOS has finished booting.
		if c.has_bios && len(c.exe) > 0 && c.cpu.pc == 0x8003_0000 {
			exe_load(c)
			delete(c.exe, c.allocator)
			c.exe = nil
		}
		n := cpu_step(c)
		budget -= n
		tick(c, n)
	}
}

frame :: proc(c: ^Console) -> emu.Frame {
	g := &c.gpu
	return {pixels = g.framebuffer[:g.out_w * g.out_h], width = g.out_w, height = g.out_h, pitch = g.out_w}
}

// Memory card in slot 1, persisted by the frontend like cartridge RAM.
// Returns nil when the card has not been written, so untouched cards are not
// saved for every program that is run.
save_ram :: proc(c: ^Console) -> []u8 {
	card := &c.sio.cards[0]
	return card.modified ? card.data[:] : nil
}

load_save_ram :: proc(c: ^Console, data: []u8) {
	if len(data) == MEMCARD_SIZE {
		copy(c.sio.cards[0].data[:], data)
		c.sio.cards[0].fresh = false
	}
}

gpu_check_irq :: proc(c: ^Console) {
	if c.gpu.irq_edge {
		c.gpu.irq_edge = false
		request_irq(c, .Gpu)
	}
}

request_irq :: proc(c: ^Console, irq: Irq) {
	c.i_stat |= 1 << u32(irq)
}

// --- timing ----------------------------------------------------------------

@(private = "file")
tick :: proc(c: ^Console, cycles: int) {
	c.cycles += u64(cycles)
	timers_tick(c, cycles)
	cdrom_tick(c, cycles)
	sio_tick(c, cycles)

	c.sample_cycle += cycles
	for c.sample_cycle >= SAMPLE_CYCLES {
		c.sample_cycle -= SAMPLE_CYCLES
		l, r := spu_sample(c)
		if c.audio != nil {
			emu.audio_push(c.audio, l, r)
		}
	}

	c.line_cycle += cycles
	for c.line_cycle >= LINE_CYCLES {
		c.line_cycle -= LINE_CYCLES
		new_line(c)
	}
}

@(private = "file")
new_line :: proc(c: ^Console) {
	timers_hblank(c)
	c.line += 1
	c.gpu.odd_line = !c.gpu.odd_line
	if c.line == VBLANK_LINE {
		request_irq(c, .Vblank)
		timers_vblank(c, true)
		gpu_build_frame(&c.gpu)
		c.frame_ready = true
	}
	if c.line >= LINES_PER_FRAME {
		c.line = 0
		c.gpu.field = !c.gpu.field
		timers_vblank(c, false)
	}
}

// --- memory map ------------------------------------------------------------

@(private = "file", rodata)
REGION_MASK := [8]u32 {
	0xFFFF_FFFF, 0xFFFF_FFFF, 0xFFFF_FFFF, 0xFFFF_FFFF, // KUSEG
	0x7FFF_FFFF, // KSEG0
	0x1FFF_FFFF, // KSEG1
	0xFFFF_FFFF, 0xFFFF_FFFF, // KSEG2
}

@(private = "file")
physical :: #force_inline proc(addr: u32) -> u32 {
	return addr & REGION_MASK[addr >> 29]
}

@(private = "file")
rd32 :: #force_inline proc(b: []u8, off: u32) -> u32 {
	return u32(b[off]) | u32(b[off + 1]) << 8 | u32(b[off + 2]) << 16 | u32(b[off + 3]) << 24
}

@(private = "file")
wr32 :: #force_inline proc(b: []u8, off: u32, v: u32) {
	b[off] = u8(v)
	b[off + 1] = u8(v >> 8)
	b[off + 2] = u8(v >> 16)
	b[off + 3] = u8(v >> 24)
}

fetch_word :: proc(c: ^Console, addr: u32) -> u32 {
	p := physical(addr)
	if p < 0x0080_0000 {
		return rd32(c.ram[:], p & (RAM_SIZE - 4))
	}
	if p >= 0x1FC0_0000 && p < 0x1FC8_0000 {
		return rd32(c.bios[:], (p - 0x1FC0_0000) & (BIOS_SIZE - 4))
	}
	return load32(c, addr)
}

// Generic access of 1, 2 or 4 bytes; returns the value zero-extended.
@(private = "file")
bus_load :: proc(c: ^Console, addr: u32, size: u32) -> u32 {
	p := physical(addr)
	switch {
	case p < 0x0080_0000:
		off := p & (RAM_SIZE - 1)
		return read_sized(c.ram[:], off, size)
	case p >= 0x1F80_0000 && p < 0x1F80_0400:
		return read_sized(c.scratch[:], p & 0x3FF, size)
	case p >= 0x1F80_1000 && p < 0x1F80_3000:
		return io_read(c, p, size)
	case p >= 0x1FC0_0000 && p < 0x1FC8_0000:
		return read_sized(c.bios[:], p - 0x1FC0_0000, size)
	case p >= 0x1F00_0000 && p < 0x1F80_0000:
		return size == 4 ? 0xFFFF_FFFF : (size == 2 ? 0xFFFF : 0xFF) // expansion 1
	case addr == 0xFFFE_0130:
		return c.cache_control
	}
	return 0
}

@(private = "file")
bus_store :: proc(c: ^Console, addr: u32, v: u32, size: u32) {
	p := physical(addr)
	switch {
	case p < 0x0080_0000:
		write_sized(c.ram[:], p & (RAM_SIZE - 1), v, size)
	case p >= 0x1F80_0000 && p < 0x1F80_0400:
		write_sized(c.scratch[:], p & 0x3FF, v, size)
	case p >= 0x1F80_1000 && p < 0x1F80_3000:
		io_write(c, p, v, size)
	case addr == 0xFFFE_0130:
		c.cache_control = v
	}
}

@(private = "file")
read_sized :: #force_inline proc(b: []u8, off: u32, size: u32) -> u32 {
	n := u32(len(b))
	switch size {
	case 1: return u32(b[off % n])
	case 2:
		o := off & ~u32(1)
		return u32(b[o % n]) | u32(b[(o + 1) % n]) << 8
	}
	o := off & ~u32(3)
	return rd32(b, o % n)
}

@(private = "file")
write_sized :: #force_inline proc(b: []u8, off: u32, v: u32, size: u32) {
	n := u32(len(b))
	switch size {
	case 1:
		b[off % n] = u8(v)
	case 2:
		o := off & ~u32(1)
		b[o % n] = u8(v)
		b[(o + 1) % n] = u8(v >> 8)
	case 4:
		wr32(b, (off & ~u32(3)) % n, v)
	}
}

load8  :: proc(c: ^Console, addr: u32) -> u8  {return u8(bus_load(c, addr, 1))}
load16 :: proc(c: ^Console, addr: u32) -> u16 {return u16(bus_load(c, addr, 2))}
load32 :: proc(c: ^Console, addr: u32) -> u32 {return bus_load(c, addr, 4)}
store8  :: proc(c: ^Console, addr: u32, v: u8)  {bus_store(c, addr, u32(v), 1)}
store16 :: proc(c: ^Console, addr: u32, v: u16) {bus_store(c, addr, u32(v), 2)}
store32 :: proc(c: ^Console, addr: u32, v: u32) {bus_store(c, addr, v, 4)}

// Word access to main RAM for DMA (addresses wrap within 2 MiB).
ram_read32 :: proc(c: ^Console, addr: u32) -> u32 {
	return rd32(c.ram[:], addr & (RAM_SIZE - 4))
}

ram_write32 :: proc(c: ^Console, addr: u32, v: u32) {
	wr32(c.ram[:], addr & (RAM_SIZE - 4), v)
}

// --- I/O ports -------------------------------------------------------------

@(private = "file")
io_read :: proc(c: ^Console, p: u32, size: u32) -> u32 {
	switch p {
	case 0x1F80_1040 ..= 0x1F80_104F:
		return sio_read(c, p, size)
	case 0x1F80_1070:
		return c.i_stat
	case 0x1F80_1074:
		return c.i_mask
	case 0x1F80_1080 ..= 0x1F80_10FF:
		return dma_read(c, p)
	case 0x1F80_1100 ..= 0x1F80_112F:
		return timer_read(c, p)
	case 0x1F80_1800 ..= 0x1F80_1803:
		v := u32(cdrom_read(c, p))
		if size > 1 {
			// wider reads see the same byte repeated
			v |= v << 8
			if size == 4 {v |= v << 16}
		}
		return v
	case 0x1F80_1810:
		return gpu_read(&c.gpu)
	case 0x1F80_1814:
		return gpu_status(&c.gpu)
	case 0x1F80_1820:
		return mdec_read_data(c)
	case 0x1F80_1824:
		return mdec_status(&c.mdec)
	case 0x1F80_1C00 ..= 0x1F80_1FFF:
		v := u32(spu_read(&c.spu, p))
		if size == 4 {
			v |= u32(spu_read(&c.spu, p + 2)) << 16
		}
		return v
	case 0x1F80_1060:
		return 0x0000_0B88 // RAM size config
	}
	return 0
}

@(private = "file")
io_write :: proc(c: ^Console, p: u32, v: u32, size: u32) {
	switch p {
	case 0x1F80_1040 ..= 0x1F80_104F:
		sio_write(c, p, v, size)
	case 0x1F80_1070:
		c.i_stat &= v // writing 0 acknowledges
	case 0x1F80_1074:
		c.i_mask = v & 0x7FF
	case 0x1F80_1080 ..= 0x1F80_10FF:
		dma_write(c, p, v)
	case 0x1F80_1100 ..= 0x1F80_112F:
		timer_write(c, p, v)
	case 0x1F80_1800 ..= 0x1F80_1803:
		cdrom_write(c, p, u8(v))
	case 0x1F80_1810:
		gpu_gp0(&c.gpu, v)
		gpu_check_irq(c)
	case 0x1F80_1814:
		gpu_gp1(&c.gpu, v)
	case 0x1F80_1820:
		mdec_write_command(c, v)
	case 0x1F80_1824:
		mdec_write_control(&c.mdec, v)
	case 0x1F80_1C00 ..= 0x1F80_1FFF:
		spu_write(c, p, u16(v))
		if size == 4 {
			spu_write(c, p + 2, u16(v >> 16))
		}
	}
}

// --- save states -----------------------------------------------------------

save_state :: proc(c: ^Console, allocator := context.allocator) -> []u8 {
	data, _ := emu.state_write(.PSX, c.fingerprint, c, size_of(Console), {}, allocator)
	return data
}

load_state :: proc(c: ^Console, data: []u8) -> bool {
	if !emu.state_valid(data, .PSX, c.fingerprint, size_of(Console), {}) {
		return false
	}
	// Everything that points outside the struct keeps its live value. The
	// MDEC FIFOs are transient and are emptied.
	exe, disc, audio, allocator, fp := c.exe, c.cdrom.disc, c.audio, c.allocator, c.fingerprint
	mdec_in, mdec_out := c.mdec.input, c.mdec.output
	emu.state_read(data, c, size_of(Console), {})
	c.exe, c.cdrom.disc, c.audio, c.allocator, c.fingerprint = exe, disc, audio, allocator, fp
	c.mdec.input, c.mdec.output = mdec_in, mdec_out
	clear(&c.mdec.input)
	clear(&c.mdec.output)
	c.mdec.out_pos = 0
	return true
}

// Writes RAM for GameShark codes.
poke8 :: proc(c: ^Console, addr: u32, v: u8) {
	c.ram[addr & (RAM_SIZE - 1)] = v
}

poke16 :: proc(c: ^Console, addr: u32, v: u16) {
	a := addr & (RAM_SIZE - 2)
	c.ram[a] = u8(v)
	c.ram[a + 1] = u8(v >> 8)
}
