// Package gb emulates the Nintendo Game Boy and Game Boy Color.
package gb

import "../../emu"

FRAME_DOTS :: 70224

Console :: struct {
	cpu:          Cpu,
	ppu:          Ppu,
	apu:          Apu,
	cart:         Cartridge,
	cgb:          bool,
	wram:         [8][0x1000]u8,
	hram:         [0x7F]u8,
	ie, if_:      u8,
	oam_read_inc: bool, // the current read also increments its pointer (OAM bug pattern)

	// timer
	div:          u16, // internal 16-bit divider; DIV is the high byte
	tima, tma, tac: u8,
	tima_reload:  int, // M-cycles until a pending overflow reload happens

	// joypad
	p1_select:    u8,
	buttons:      u8, // active-low: bit0 right/A .. bit3 down/start, low nibble dpad, high buttons
	joypad_pressed: bool,

	// serial (also how test ROMs report results)
	sb, sc:       u8,
	serial_timer: int,
	serial_out:   [1024]u8,
	serial_len:   int,

	// CGB
	svbk:         u8,
	key1:         u8,
	double_speed: bool,
	hdma_src, hdma_dst: u16,
	hdma_len:     int, // remaining 16-byte blocks for HBlank DMA
	hdma_active:  bool,

	audio:        ^emu.Audio_Buffer,
	fingerprint:  u64,
	patches:      emu.Patch_List, // Game Genie
}

// Which hardware to emulate. Auto follows the cartridge header (CGB for
// CGB-only and CGB-enhanced games).
Model :: enum u8 {
	Auto,
	Dmg,
	Cgb,
}

create :: proc(rom: []u8, model := Model.Auto, allocator := context.allocator) -> (^Console, emu.Load_Error) {
	c, err := new(Console, allocator)
	if err != nil {
		return nil, .Out_Of_Memory
	}
	if load_err := cart_load(&c.cart, rom, allocator); load_err != .None {
		free(c, allocator)
		return nil, load_err
	}
	switch model {
	case .Auto: c.cgb = c.cart.cgb
	case .Dmg:  c.cgb = false
	case .Cgb:  c.cgb = true
	}
	c.fingerprint = emu.fingerprint(rom)
	reset(c)
	return c, .None
}

destroy :: proc(c: ^Console, allocator := context.allocator) {
	if c == nil {
		return
	}
	cart_destroy(&c.cart, allocator)
	free(c, allocator)
}

reset :: proc(c: ^Console) {
	cart_reset(&c.cart)
	cpu_reset(c)
	ppu_reset(&c.ppu)
	c.apu.cgb = c.cgb
	apu_reset(&c.apu)
	c.ie = 0
	c.if_ = 0xE1
	c.div = 0xABCC
	c.tima, c.tma, c.tac = 0, 0, 0xF8
	c.svbk = 1
	c.key1 = 0
	c.double_speed = false
	c.hdma_active = false
	c.buttons = 0xFF
}

run_frame :: proc(c: ^Console, input: emu.Input, audio: ^emu.Audio_Buffer) {
	set_buttons(c, input.pads[0])
	c.audio = audio
	defer c.audio = nil
	c.ppu.frame_ready = false
	budget := FRAME_DOTS * 2
	for !c.ppu.frame_ready && budget > 0 {
		before := c.ppu.dot
		cpu_step(c)
		budget -= max(abs(c.ppu.dot - before), 4)
	}
}

frame :: proc(c: ^Console) -> emu.Frame {
	return {pixels = c.ppu.framebuffer[:], width = SCREEN_W, height = SCREEN_H, pitch = SCREEN_W}
}

save_ram :: proc(c: ^Console) -> []u8 {
	return c.cart.battery ? c.cart.ram : nil
}

load_save_ram :: proc(c: ^Console, data: []u8) {
	copy(c.cart.ram, data)
}

// Text the program has sent over the serial port (used by test ROMs).
serial_output :: proc(c: ^Console) -> string {
	return string(c.serial_out[:c.serial_len])
}

@(private = "file")
set_buttons :: proc(c: ^Console, b: emu.Buttons) {
	v: u8 = 0xFF
	if .Right in b  {v &= ~u8(0x01)}
	if .Left in b   {v &= ~u8(0x02)}
	if .Up in b     {v &= ~u8(0x04)}
	if .Down in b   {v &= ~u8(0x08)}
	if .A in b      {v &= ~u8(0x10)}
	if .B in b      {v &= ~u8(0x20)}
	if .Select in b {v &= ~u8(0x40)}
	if .Start in b  {v &= ~u8(0x80)}
	pressed := c.buttons & ~v
	if pressed != 0 {
		c.if_ |= 0x10
		c.joypad_pressed = true
	}
	c.buttons = v
}

// --- timing ----------------------------------------------------------------

@(private = "file")
timer_bit :: #force_inline proc(tac: u8) -> u16 {
	@(static, rodata) BITS := [4]u16{1 << 9, 1 << 3, 1 << 5, 1 << 7}
	return BITS[tac & 3]
}

@(private = "file")
set_div :: proc(c: ^Console, v: u16) {
	// TIMA counts falling edges of the selected divider bit.
	old := c.div & timer_bit(c.tac) != 0 && c.tac & 4 != 0
	c.div = v
	now := c.div & timer_bit(c.tac) != 0 && c.tac & 4 != 0
	if old && !now {
		c.tima += 1
		if c.tima == 0 {
			c.tima_reload = 1
		}
	}
}

// One CPU M-cycle: timer, PPU, APU and DMA advance accordingly.
tick :: proc(c: ^Console) {
	if c.tima_reload > 0 {
		c.tima_reload -= 1
		if c.tima_reload == 0 {
			c.tima = c.tma
			c.if_ |= 0x04
		}
	}
	for _ in 0 ..< 4 {
		set_div(c, c.div + 1)
	}
	dots := c.double_speed ? 2 : 4
	ppu_step(c, dots)
	apu_step(&c.apu, dots, c.audio)
	if c.cart.has_rtc {
		rtc_tick(&c.cart.rtc, dots)
	}
	if c.serial_timer > 0 {
		c.serial_timer -= 4
		if c.serial_timer <= 0 {
			c.sc &= 0x7F
			c.sb = 0xFF
			c.if_ |= 0x08
		}
	}
}

// --- memory ------------------------------------------------------------------

read :: proc(c: ^Console, addr: u16) -> u8 {
	tick(c)
	switch addr {
	case 0xFE00 ..= 0xFEFF:
		if !c.cgb {
			if row := oam_scan_row(&c.ppu); row >= 0 {
				if c.oam_read_inc {
					oam_corrupt_read_inc(&c.ppu, row)
				} else {
					oam_corrupt_read(&c.ppu, row)
				}
			}
		}
		if oam_locked(&c.ppu) {
			return 0xFF
		}
	case 0x8000 ..= 0x9FFF:
		if vram_locked(&c.ppu) {
			return 0xFF
		}
	}
	return bus_read(c, addr)
}

write :: proc(c: ^Console, addr: u16, v: u8) {
	tick(c)
	switch addr {
	case 0xFE00 ..= 0xFEFF:
		if !c.cgb {
			if row := oam_scan_row(&c.ppu); row >= 0 {
				oam_corrupt_write(&c.ppu, row)
			}
		}
		if oam_locked(&c.ppu) {
			return
		}
	case 0x8000 ..= 0x9FFF:
		if vram_locked(&c.ppu) {
			return
		}
	}
	bus_write(c, addr, v)
}

// A 16-bit increment/decrement put `v` on the address bus (DMG OAM bug).
oam_bug_idu :: proc(c: ^Console, v: u16) {
	if !c.cgb && v >= 0xFE00 && v <= 0xFEFF {
		if row := oam_scan_row(&c.ppu); row >= 0 {
			oam_corrupt_write(&c.ppu, row)
		}
	}
}

@(private = "file")
wram_bank :: #force_inline proc(c: ^Console) -> int {
	if !c.cgb {
		return 1
	}
	return max(int(c.svbk & 7), 1)
}

bus_read :: proc(c: ^Console, addr: u16) -> u8 {
	switch addr {
	case 0x0000 ..= 0x7FFF:
		v := cart_read(&c.cart, addr)
		if c.patches.count > 0 {
			v = emu.patch_apply(&c.patches, u32(addr), v)
		}
		return v
	case 0xA000 ..= 0xBFFF:
		return cart_read(&c.cart, addr)
	case 0x8000 ..= 0x9FFF:
		return c.ppu.vram[c.cgb ? int(c.ppu.vbk & 1) : 0][addr - 0x8000]
	case 0xC000 ..= 0xCFFF, 0xE000 ..= 0xEFFF:
		return c.wram[0][addr & 0x0FFF]
	case 0xD000 ..= 0xDFFF, 0xF000 ..= 0xFDFF:
		return c.wram[wram_bank(c)][addr & 0x0FFF]
	case 0xFE00 ..= 0xFE9F:
		return c.ppu.oam[addr - 0xFE00]
	case 0xFEA0 ..= 0xFEFF:
		return 0
	case 0xFF80 ..= 0xFFFE:
		return c.hram[addr - 0xFF80]
	case 0xFFFF:
		return c.ie
	}
	return io_read(c, addr)
}

bus_write :: proc(c: ^Console, addr: u16, v: u8) {
	switch addr {
	case 0x0000 ..= 0x7FFF, 0xA000 ..= 0xBFFF:
		cart_write(&c.cart, addr, v)
	case 0x8000 ..= 0x9FFF:
		c.ppu.vram[c.cgb ? int(c.ppu.vbk & 1) : 0][addr - 0x8000] = v
	case 0xC000 ..= 0xCFFF, 0xE000 ..= 0xEFFF:
		c.wram[0][addr & 0x0FFF] = v
	case 0xD000 ..= 0xDFFF, 0xF000 ..= 0xFDFF:
		c.wram[wram_bank(c)][addr & 0x0FFF] = v
	case 0xFE00 ..= 0xFE9F:
		c.ppu.oam[addr - 0xFE00] = v
	case 0xFEA0 ..= 0xFEFF:
	case 0xFF80 ..= 0xFFFE:
		c.hram[addr - 0xFF80] = v
	case 0xFFFF:
		c.ie = v
	case:
		io_write(c, addr, v)
	}
}

@(private = "file")
io_read :: proc(c: ^Console, addr: u16) -> u8 {
	p := &c.ppu
	switch addr {
	case 0xFF00:
		v := c.p1_select | 0xCF
		if c.p1_select & 0x10 == 0 {v &= 0xF0 | (c.buttons & 0x0F)}
		if c.p1_select & 0x20 == 0 {v &= 0xF0 | (c.buttons >> 4)}
		return v
	case 0xFF01: return c.sb
	case 0xFF02: return c.sc | 0x7E
	case 0xFF04: return u8(c.div >> 8)
	case 0xFF05: return c.tima
	case 0xFF06: return c.tma
	case 0xFF07: return c.tac | 0xF8
	case 0xFF0F: return c.if_ | 0xE0
	case 0xFF10 ..= 0xFF3F: return apu_read(&c.apu, addr)
	case 0xFF40: return p.lcdc
	case 0xFF41: return ppu_read_stat(p)
	case 0xFF42: return p.scy
	case 0xFF43: return p.scx
	case 0xFF44: return p.ly
	case 0xFF45: return p.lyc
	case 0xFF47: return p.bgp
	case 0xFF48: return p.obp0
	case 0xFF49: return p.obp1
	case 0xFF4A: return p.wy
	case 0xFF4B: return p.wx
	}
	if !c.cgb {
		return 0xFF
	}
	switch addr {
	case 0xFF4D: return c.key1 | (c.double_speed ? 0x80 : 0) | 0x7E
	case 0xFF4F: return p.vbk | 0xFE
	case 0xFF55: return c.hdma_active ? u8(c.hdma_len - 1) & 0x7F : 0xFF
	case 0xFF68: return p.bcps | 0x40
	case 0xFF69: return p.bg_pal[p.bcps & 0x3F]
	case 0xFF6A: return p.ocps | 0x40
	case 0xFF6B: return p.ob_pal[p.ocps & 0x3F]
	case 0xFF6C: return p.opri | 0xFE
	case 0xFF70: return c.svbk | 0xF8
	}
	return 0xFF
}

@(private = "file")
io_write :: proc(c: ^Console, addr: u16, v: u8) {
	p := &c.ppu
	switch addr {
	case 0xFF00: c.p1_select = v & 0x30
	case 0xFF01: c.sb = v
	case 0xFF02:
		c.sc = v
		if v & 0x81 == 0x81 { // transfer with the internal clock
			if c.serial_len < len(c.serial_out) {
				c.serial_out[c.serial_len] = c.sb
				c.serial_len += 1
			}
			c.serial_timer = 4096 // 8 bits at 8192 Hz
		}
	case 0xFF04: set_div(c, 0)
	case 0xFF05:
		c.tima = v
		c.tima_reload = 0
	case 0xFF06: c.tma = v
	case 0xFF07:
		// changing the selected bit can also produce a falling edge
		old := c.div & timer_bit(c.tac) != 0 && c.tac & 4 != 0
		c.tac = v & 7
		now := c.div & timer_bit(c.tac) != 0 && c.tac & 4 != 0
		if old && !now {
			c.tima += 1
			if c.tima == 0 {c.tima_reload = 1}
		}
	case 0xFF0F: c.if_ = v & 0x1F
	case 0xFF10 ..= 0xFF3F: apu_write(&c.apu, addr, v)
	case 0xFF40: ppu_write_lcdc(c, v)
	case 0xFF41:
		p.stat = v & 0x78
		ppu_stat_written(c)
	case 0xFF42: p.scy = v
	case 0xFF43: p.scx = v
	case 0xFF45:
		p.lyc = v
		ppu_stat_written(c)
	case 0xFF46: oam_dma(c, v)
	case 0xFF47: p.bgp = v
	case 0xFF48: p.obp0 = v
	case 0xFF49: p.obp1 = v
	case 0xFF4A: p.wy = v
	case 0xFF4B: p.wx = v
	}
	if !c.cgb {
		return
	}
	switch addr {
	case 0xFF4D: c.key1 = v & 1
	case 0xFF4F: p.vbk = v & 1
	case 0xFF51: c.hdma_src = (c.hdma_src & 0x00FF) | u16(v) << 8
	case 0xFF52: c.hdma_src = (c.hdma_src & 0xFF00) | u16(v & 0xF0)
	case 0xFF53: c.hdma_dst = (c.hdma_dst & 0x00FF) | u16(v & 0x1F) << 8
	case 0xFF54: c.hdma_dst = (c.hdma_dst & 0xFF00) | u16(v & 0xF0)
	case 0xFF55:
		blocks := int(v & 0x7F) + 1
		if c.hdma_active && v & 0x80 == 0 {
			c.hdma_active = false // cancel a running HBlank DMA
		} else if v & 0x80 != 0 {
			c.hdma_active = true
			c.hdma_len = blocks
		} else {
			for _ in 0 ..< blocks {
				hdma_block(c)
			}
		}
	case 0xFF68: p.bcps = v & 0xBF
	case 0xFF69:
		p.bg_pal[p.bcps & 0x3F] = v
		if p.bcps & 0x80 != 0 {p.bcps = 0x80 | ((p.bcps + 1) & 0x3F)}
	case 0xFF6A: p.ocps = v & 0xBF
	case 0xFF6B:
		p.ob_pal[p.ocps & 0x3F] = v
		if p.ocps & 0x80 != 0 {p.ocps = 0x80 | ((p.ocps + 1) & 0x3F)}
	case 0xFF6C: p.opri = v & 1
	case 0xFF70: c.svbk = v & 7
	}
}

@(private = "file")
oam_dma :: proc(c: ^Console, page: u8) {
	src := u16(page) << 8
	for i in u16(0) ..< 0xA0 {
		c.ppu.oam[i] = bus_read(c, src + i)
	}
}

@(private = "file")
hdma_block :: proc(c: ^Console) {
	bank := int(c.ppu.vbk & 1)
	for _ in 0 ..< 16 {
		c.ppu.vram[bank][c.hdma_dst & 0x1FFF] = bus_read(c, c.hdma_src)
		c.hdma_src += 1
		c.hdma_dst = (c.hdma_dst + 1) & 0x1FFF
	}
}

// Called by the PPU at the start of each HBlank.
hdma_hblank :: proc(c: ^Console) {
	if !c.hdma_active {
		return
	}
	hdma_block(c)
	c.hdma_len -= 1
	if c.hdma_len <= 0 {
		c.hdma_active = false
	}
}

// --- save states -------------------------------------------------------------

save_state :: proc(c: ^Console, allocator := context.allocator) -> []u8 {
	data, _ := emu.state_write(.GB, c.fingerprint, c, size_of(Console), {c.cart.ram}, allocator)
	return data
}

load_state :: proc(c: ^Console, data: []u8) -> bool {
	if !emu.state_valid(data, .GB, c.fingerprint, size_of(Console), {c.cart.ram}) {
		return false
	}
	rom, ram, audio, fp := c.cart.rom, c.cart.ram, c.audio, c.fingerprint
	emu.state_read(data, c, size_of(Console), {c.cart.ram})
	c.cart.rom, c.cart.ram, c.audio, c.fingerprint = rom, ram, audio, fp
	return true
}

// Writes a byte for RAM cheat codes (GameShark).
poke :: proc(c: ^Console, addr: u32, v: u8) {
	a := u16(addr)
	if a >= 0x8000 {
		bus_write(c, a, v)
	}
}
