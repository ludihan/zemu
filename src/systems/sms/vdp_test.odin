package sms

import "core:testing"

import "../../emu"

@(private = "file")
vdp_reg :: proc(c: ^Console, reg, v: u8) {
	port_out(c, 0xBF, v)
	port_out(c, 0xBF, 0x80 | reg)
}

@(private = "file")
vdp_seek :: proc(c: ^Console, addr: u16, code: u8) {
	port_out(c, 0xBF, u8(addr))
	port_out(c, 0xBF, u8(addr >> 8) & 0x3F | code << 6)
}

@(private = "file")
setup :: proc(t: ^testing.T, gg: bool) -> ^Console {
	rom := make([]u8, 0x8000) // all NOPs; the CPU never touches the VDP
	defer delete(rom)
	c, err := create(rom, gg ? .Game_Gear : .Master_System)
	testing.expect_value(t, err, emu.Load_Error.None)
	vdp_reg(c, 0, 0x04)  // mode 4
	vdp_reg(c, 1, 0x40)  // display on
	vdp_reg(c, 2, 0xFF)  // name table $3800
	vdp_reg(c, 5, 0xFF)  // sprite table $3F00
	vdp_reg(c, 6, 0xFB)
	vdp_reg(c, 7, 0x00)
	vdp_reg(c, 10, 0xFF)
	// tile 1: every pixel colour 1
	vdp_seek(c, 32, 1)
	for _ in 0 ..< 8 {
		port_out(c, 0xBE, 0xFF)
		port_out(c, 0xBE, 0x00)
		port_out(c, 0xBE, 0x00)
		port_out(c, 0xBE, 0x00)
	}
	// name table entry (0, 0) = tile 1
	vdp_seek(c, 0x3800, 1)
	port_out(c, 0xBE, 0x01)
	port_out(c, 0xBE, 0x00)
	// sprite 0 at x=16, top line 10, tile 1; sprite 1 ends the list
	vdp_seek(c, 0x3F00, 1)
	port_out(c, 0xBE, 9)
	port_out(c, 0xBE, 0xD0)
	vdp_seek(c, 0x3F80, 1)
	port_out(c, 0xBE, 16)
	port_out(c, 0xBE, 1)
	return c
}

@(test)
master_system_vdp_renders_tiles_sprites_and_scroll :: proc(t: ^testing.T) {
	c := setup(t, false)
	defer destroy(c)
	vdp_seek(c, 1, 3)
	port_out(c, 0xBE, 0x03) // colour 1: red
	vdp_seek(c, 17, 3)
	port_out(c, 0xBE, 0x0C) // colour 17 (sprite palette 1): green
	run_frame(c, {}, nil)
	fb := &c.vdp.framebuffer
	testing.expect_value(t, fb[0], 0xFF0000)
	testing.expect_value(t, fb[8], 0x000000)
	testing.expect_value(t, fb[10 * SCREEN_W + 16], 0x00FF00)
	testing.expect_value(t, fb[9 * SCREEN_W + 16], 0x000000)
	testing.expect(t, c.vdp.status & 0x80 != 0, "frame interrupt flag set at vblank")
	_ = vdp_read_status(&c.vdp)
	testing.expect_value(t, c.vdp.status, 0)

	vdp_reg(c, 8, 8) // scroll right by 8 pixels
	run_frame(c, {}, nil)
	testing.expect_value(t, fb[8], 0xFF0000)
	testing.expect_value(t, fb[0], 0x000000)
}

@(test)
game_gear_uses_12_bit_colours_and_a_viewport :: proc(t: ^testing.T) {
	c := setup(t, true)
	defer destroy(c)
	vdp_reg(c, 8, 48) // move tile (0,0) to x=48, the viewport's left edge
	vdp_reg(c, 9, 256 - 24 - 32) // and to y=24
	vdp_seek(c, 2, 3)
	port_out(c, 0xBE, 0x0F) // colour 1: R=15 G=0
	port_out(c, 0xBE, 0x08) //           B=8
	run_frame(c, {}, nil)
	f := frame(c)
	testing.expect_value(t, f.width, GG_W)
	testing.expect_value(t, f.height, GG_H)
	testing.expect_value(t, f.pixels[0], 0xFF0088)
}

// A tiny hand-assembled program: VDP setup via OTIR, a PSG tone, then an
// IM 1 frame interrupt handler that counts frames in RAM.
@(test)
program_runs_interrupts_and_sound :: proc(t: ^testing.T) {
	rom := make([]u8, 0x8000)
	defer delete(rom)
	code := []u8 {
		0xF3,             // 0000 DI
		0x31, 0xF0, 0xDF, // 0001 LD SP,$DFF0
		0xED, 0x56,       // 0004 IM 1
		0x21, 0x00, 0x01, // 0006 LD HL,$0100
		0x06, 12,         // 0009 LD B,12
		0x0E, 0xBF,       // 000B LD C,$BF
		0xED, 0xB3,       // 000D OTIR
		0x3E, 0x8E,       // 000F LD A,$8E   ; tone 0 period low = $E
		0xD3, 0x7F,       // 0011 OUT ($7F),A
		0x3E, 0x0F,       // 0013 LD A,$0F   ; period high
		0xD3, 0x7F,       // 0015 OUT ($7F),A
		0x3E, 0x90,       // 0017 LD A,$90   ; volume 0 (loudest)
		0xD3, 0x7F,       // 0019 OUT ($7F),A
		0xFB,             // 001B EI
		0x76,             // 001C HALT
		0x18, 0xFD,       // 001D JR $001C
	}
	copy(rom, code)
	irq := []u8 {
		0xDB, 0xBF,       // 0038 IN A,($BF)  ; acknowledge
		0x21, 0x00, 0xC0, // 003A LD HL,$C000
		0x34,             // 003D INC (HL)
		0xFB,             // 003E EI
		0xC9,             // 003F RET
	}
	copy(rom[0x38:], irq)
	copy(rom[0x100:], []u8{0x04, 0x80, 0x60, 0x81, 0xFF, 0x82, 0xFF, 0x85, 0xFB, 0x86, 0x00, 0x87})

	c, err := create(rom, .Master_System)
	if !testing.expect_value(t, err, emu.Load_Error.None) {return}
	defer destroy(c)
	audio := new(emu.Audio_Buffer)
	defer free(audio)
	loud := 0
	for _ in 0 ..< 10 {
		audio.count = 0
		run_frame(c, {}, audio)
		for s in emu.audio_slice(audio) {
			if abs(int(s)) > 1000 {loud += 1}
		}
	}
	frames := int(c.ram[0])
	testing.expectf(t, frames >= 9 && frames <= 10, "counted %d frame interrupts in 10 frames", frames)
	testing.expectf(t, loud > 1000, "expected an audible tone, got %d loud samples", loud)
}

// The H counter counts pixel pairs and skips $94-$E8 during HBlank.
@(test)
h_counter_jumps :: proc(t: ^testing.T) {
	c := setup(t, false)
	defer destroy(c)
	c.line_cycles = 0
	testing.expect_value(t, port_in(c, 0x7F), 0x00)
	c.line_cycles = 196 // pixel 294 -> pair 147 = $93
	testing.expect_value(t, port_in(c, 0x7F), 0x93)
	c.line_cycles = 198 // pixel 297 -> pair 148 jumps to $E9
	testing.expect_value(t, port_in(c, 0x7F), 0xE9)
	c.line_cycles = LINE_CYCLES - 1 // last pair of the line
	testing.expect_value(t, port_in(c, 0x7F), 0xFF)
}

// Writes `data` to VRAM at `addr`.
@(private = "file")
vram_fill :: proc(c: ^Console, addr: u16, data: ..u8) {
	vdp_seek(c, addr, 1)
	for b in data {port_out(c, 0xBE, b)}
}

@(test)
tms9918_graphics_modes_and_sprites :: proc(t: ^testing.T) {
	rom := make([]u8, 0x8000)
	defer delete(rom)
	c, err := create(rom, .Master_System)
	if !testing.expect_value(t, err, emu.Load_Error.None) {return}
	defer destroy(c)
	WHITE, DARK_RED, LIGHT_BLUE, BLACK := u32(0xFFFFFF), u32(0xD4524D), u32(0x7D76FC), u32(0x000000)

	// Graphics I: names at $3800, patterns at $0000, colors at $2000
	vdp_reg(c, 0, 0x00)
	vdp_reg(c, 1, 0x40)
	vdp_reg(c, 2, 0x0E)
	vdp_reg(c, 3, 0x80)
	vdp_reg(c, 4, 0x00)
	vdp_reg(c, 5, 0x7E) // sprite attributes at $3F00
	vdp_reg(c, 6, 0x00)
	vdp_reg(c, 7, 0x04) // backdrop dark blue
	vram_fill(c, 0x3800, 9)                                    // name (0,0) = pattern 9
	vram_fill(c, 9 * 8, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0, 0xF0) // left half set
	vram_fill(c, 0x2000 + 1, 0xF6)                             // patterns 8-15: white on dark red
	vram_fill(c, 0x3F00, 0xD0)                                 // no sprites
	vdp_line(&c.vdp, 0)
	fb := c.vdp.framebuffer[:]
	testing.expect_value(t, fb[0], WHITE)
	testing.expect_value(t, fb[4], DARK_RED)

	// Graphics II: the bottom third uses its own patterns and colors
	vdp_reg(c, 0, 0x02)
	vdp_reg(c, 3, 0xFF) // colors at $2000, unmasked
	vdp_reg(c, 4, 0x03) // patterns at $0000, unmasked
	vram_fill(c, 0x3800 + 16 * 32, 3)                          // name (0, 16) = 3, bottom third
	vram_fill(c, (512 + 3) * 8, 0x0F)                          // its first row: right half
	vram_fill(c, 0x2000 + (512 + 3) * 8, 0x15)                 // black on light blue
	vdp_line(&c.vdp, 128)
	testing.expect_value(t, fb[128 * SCREEN_W + 0], LIGHT_BLUE)
	testing.expect_value(t, fb[128 * SCREEN_W + 4], BLACK)

	// a white 8x8 sprite at (16, 10) over it
	vram_fill(c, 0x3F00, 9, 16, 1, 0x0F, 0xD0)                 // y = 9 means line 10
	vram_fill(c, 0x0008, 0x80)                                 // sprite pattern 1, top row: one pixel
	vdp_line(&c.vdp, 10)
	testing.expect_value(t, fb[10 * SCREEN_W + 16], WHITE)
	testing.expect(t, fb[10 * SCREEN_W + 17] != WHITE, "only the set pixel is drawn")
}
