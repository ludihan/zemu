// Package gba emulates the Nintendo Game Boy Advance.
package gba

import "base:runtime"
import "../../emu"

CPU_CLOCK   :: 16_777_216
FRAME_CYCLES :: LINE_CYCLES * TOTAL_LINES

Console :: struct {
	cpu:          Cpu,
	ppu:          Ppu,
	sound:        Sound,
	save:         Save,
	rtc:          Rtc,
	timers:       [4]Timer,
	dma:          [4]Dma,
	bios:         [BIOS_SIZE]u8,
	ewram:        [EWRAM_SIZE]u8,
	iwram:        [IWRAM_SIZE]u8,
	palette:      [0x400]u8,
	vram:         [VRAM_SIZE]u8,
	oam:          [0x400]u8,
	io_misc:      [32]u16, // serial registers: stored, not emulated

	ie, if_:      u16,
	ime:          bool,
	waitcnt:      u16,
	postflg:      u8,
	keycnt:       u16,
	pad:          emu.Buttons,

	rom_n:        [3]int,
	rom_s:        [3]int,
	sram_wait:    int,
	prefetch:     bool,

	bios_latch:   u32,
	last_fetch:   u32,
	intr_wait:    u16,
	intr_wait_pc: u32,
	dma_cycles:   int,

	rom:          []u8,
	audio:        ^emu.Audio_Buffer,
	fingerprint:  u64,
	allocator:    runtime.Allocator,
	patches:      emu.Patch_List,
}

create :: proc(rom: []u8, allocator := context.allocator) -> (^Console, emu.Load_Error) {
	if len(rom) < 0xC0 {
		return nil, .Truncated
	}
	if len(rom) > MAX_ROM {
		return nil, .Bad_Header
	}
	c, err := new(Console, allocator)
	if err != nil {
		return nil, .Out_Of_Memory
	}
	c.allocator = allocator
	// Round up to an even size so 16-bit reads never straddle the end.
	c.rom = make([]u8, (len(rom) + 3) & ~int(3), allocator)
	copy(c.rom, rom)
	c.fingerprint = emu.fingerprint(rom)
	save_detect(&c.save, c.rom)
	rtc_detect(&c.rtc, c.rom)
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
	bios_init(c)
	cpu_reset(c)
	ppu_reset(&c.ppu)
	sound_reset(&c.sound)
	c.ewram = {}
	c.iwram = {}
	c.palette = {}
	c.vram = {}
	c.oam = {}
	c.timers = {}
	c.dma = {}
	c.ie, c.if_, c.ime = 0, 0, false
	c.waitcnt = 0
	c.keycnt = 0
	c.postflg = 1
	c.intr_wait = 0
	c.dma_cycles = 0
	c.bios_latch = 0xE129_F000 // what the BIOS leaves behind after booting
	c.save.flash = .Ready
	c.save.id_mode = false
	c.save.bank = 0
	c.save.eeprom = .Idle
	c.save.nbits = 0
	update_waitstates(c)
}

emu_patch :: #force_inline proc(c: ^Console, addr: u32, v: u8) -> u8 {
	return emu.patch_apply(&c.patches, addr, v)
}

halt_cycles :: proc(c: ^Console) -> int {
	// Skip ahead to the next PPU event, but keep timers reasonably fine
	// grained so sound FIFOs are fed on time.
	n := ppu_next_event(&c.ppu)
	return clamp(n, 1, 64)
}

run_frame :: proc(c: ^Console, input: emu.Input, audio: ^emu.Audio_Buffer) {
	c.pad = input.pads[0]
	c.audio = audio
	defer c.audio = nil
	keypad_check(c)
	budget := FRAME_CYCLES * 2
	for budget > 0 {
		n := cpu_step(c)
		n += c.dma_cycles
		c.dma_cycles = 0
		budget -= n
		timers_step(c, n)
		sound_step(&c.sound, n, c.audio)
		if ppu_step(c, n) {
			break
		}
	}
}

frame :: proc(c: ^Console) -> emu.Frame {
	return {pixels = c.ppu.framebuffer[:], width = SCREEN_W, height = SCREEN_H, pitch = SCREEN_W}
}

fps :: proc(c: ^Console) -> f64 {
	return f64(CPU_CLOCK) / f64(FRAME_CYCLES)
}

save_ram :: proc(c: ^Console) -> []u8 {
	n := save_size(&c.save)
	if n == 0 {
		return nil
	}
	return c.save.data[:n]
}

load_save_ram :: proc(c: ^Console, data: []u8) {
	if c.save.kind == .Eeprom && c.save.eeprom_addr_bits == 0 {
		c.save.eeprom_addr_bits = len(data) <= 0x200 ? 6 : 14
	}
	n := save_size(&c.save)
	copy(c.save.data[:n], data)
}

// Writes RAM for cheat codes (GameShark / Action Replay style).
poke :: proc(c: ^Console, addr: u32, v: u8) {
	switch addr >> 24 {
	case 0x02: c.ewram[addr & (EWRAM_SIZE - 1)] = v
	case 0x03: c.iwram[addr & (IWRAM_SIZE - 1)] = v
	}
}

// --- save states ---------------------------------------------------------------

save_state :: proc(c: ^Console, allocator := context.allocator) -> []u8 {
	data, _ := emu.state_write(.GBA, c.fingerprint, c, size_of(Console), {}, allocator)
	return data
}

load_state :: proc(c: ^Console, data: []u8) -> bool {
	if !emu.state_valid(data, .GBA, c.fingerprint, size_of(Console), {}) {
		return false
	}
	rom, audio, allocator, fp := c.rom, c.audio, c.allocator, c.fingerprint
	emu.state_read(data, c, size_of(Console), {})
	c.rom, c.audio, c.allocator, c.fingerprint = rom, audio, allocator, fp
	return true
}
