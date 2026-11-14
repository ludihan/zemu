// Package ps2 emulates the Sony PlayStation 2. Work in progress: the
// Emotion Engine CPU runs ELF executables; the vector units, Graphics
// Synthesizer, IOP and BIOS boot are still to come.
package ps2

import "base:runtime"
import "../../emu"

EE_CLOCK :: 294_912_000

Console :: struct {
	ee:          Ee,
	vu0:         Vu,
	gs:          Gs,
	gif_fifo_lo: u64,
	ram:         []u8,
	bios:        []u8,
	scratch:     [SCRATCH_SIZE]u8,
	iop_ram:     [IOP_RAM_SIZE]u8,
	ee_regs:     [0x4000]u32,
	gs_priv:     [0x800]u32,
	hle_kernel:  bool, // no BIOS: SYSCALLs are handled directly
	debug_out:   [8192]u8,
	debug_len:   int,
	allocator:   runtime.Allocator,
}

// Creates a console running an ELF executable without a BIOS.
create_from_elf :: proc(elf: []u8, allocator := context.allocator) -> (^Console, emu.Load_Error) {
	c, err := new(Console, allocator)
	if err != nil {
		return nil, .Out_Of_Memory
	}
	c.allocator = allocator
	ram, ram_err := make([]u8, RAM_SIZE, allocator)
	if ram_err != nil {
		free(c, allocator)
		return nil, .Out_Of_Memory
	}
	c.ram = ram
	entry, load_err := elf_load(c, elf)
	if load_err != .None {
		destroy(c)
		return nil, load_err
	}
	c.hle_kernel = true
	px, px_err := make([]u32, 1024 * 1024, allocator)
	if px_err != nil {
		destroy(c)
		return nil, .Out_Of_Memory
	}
	c.gs.frame_px = px
	gs_reset(&c.gs)
	ee_reset(&c.ee, entry)
	vu_reset(&c.vu0)
	set64(&c.ee, 29, 0x01F0_0000) // stack near the top of RAM
	return c, .None
}

destroy :: proc(c: ^Console) {
	if c == nil {
		return
	}
	allocator := c.allocator
	delete(c.ram, allocator)
	delete(c.gs.frame_px, allocator)
	delete(c.bios, allocator)
	free(c, allocator)
}

// Instructions per video frame. The EE retires up to two per cycle at
// 294.912 MHz; one per cycle is a reasonable average for an interpreter.
FRAME_STEPS :: EE_CLOCK / 60

run_frame :: proc(c: ^Console, input: emu.Input, audio: ^emu.Audio_Buffer) {
	_, _ = input, audio
	for _ in 0 ..< FRAME_STEPS {
		ee_step(c)
	}
	vblank(c)
}

// Start of vertical blank: flag it in the GS and refresh the picture.
vblank :: proc(c: ^Console) {
	csr := &c.gs_priv[(GS_CSR - 0x1200_0000) >> 2]
	csr^ |= 0x08 // VSINT
	csr^ ~= 0x2000 // FIELD
	gs_read_out(c)
}

frame :: proc(c: ^Console) -> emu.Frame {
	return {pixels = c.gs.frame_px, width = c.gs.frame_w, height = c.gs.frame_h, pitch = c.gs.frame_w}
}

// Runs up to `n` EE instructions, stopping early when the program parks
// itself on a branch-to-self (the test programs' way of ending).
run_instructions :: proc(c: ^Console, n: int) -> (stopped: bool) {
	for _ in 0 ..< n {
		pc := c.ee.pc
		ee_step(c)
		if c.ee.pc == pc + 4 && c.ee.npc == pc && read32(c, pc) == 0x1000_FFFF {
			return true // "b ." with its delay slot
		}
	}
	return false
}

// Minimal kernel: just enough for bare test programs. Exit (syscall 4) and
// unknown calls park the CPU.
hle_syscall :: proc(c: ^Console) {
	cpu := &c.ee
	number := u32(lo64(cpu.gpr[3]))
	switch number {
	case:
		_ = number
	}
}
