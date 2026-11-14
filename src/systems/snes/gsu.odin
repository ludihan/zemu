package snes

// Super FX (GSU-1/GSU-2): the cartridge RISC coprocessor of Star Fox, Yoshi's
// Island, Stunt Race FX and others. Sixteen 16-bit registers (R15 is the
// program counter), a one-byte prefetch so the instruction after a branch
// always runs, a 512-byte instruction cache, a ROM read buffer refilled when
// R14 changes, and a plot unit that writes pixels straight into SNES
// character data in the cartridge RAM.

SFR_Z    :: u16(1 << 1)
SFR_CY   :: u16(1 << 2)
SFR_S    :: u16(1 << 3)
SFR_OV   :: u16(1 << 4)
SFR_G    :: u16(1 << 5)
SFR_R    :: u16(1 << 6)
SFR_ALT1 :: u16(1 << 8)
SFR_ALT2 :: u16(1 << 9)
SFR_IL   :: u16(1 << 10)
SFR_IH   :: u16(1 << 11)
SFR_B    :: u16(1 << 12)
SFR_IRQ  :: u16(1 << 15)

Gsu :: struct {
	r:          [16]u16,
	sfr:        u16,
	pbr:        u8,
	rombr:      u8,
	rambr:      u8,
	cbr:        u16,
	scbr:       u8,
	scmr:       u8,
	colr:       u8,
	por:        u8,
	bramr:      u8,
	cfgr:       u8,
	clsr:       u8,
	sreg, dreg: u8,
	rom_buffer: u8,
	ram_addr:   u16, // last RAM word address, for SBK
	pipe:       u8,   // prefetched opcode byte; R15 addresses it during an instruction
	r15_written: bool, // the instruction set R15, so it does not advance
	cache:      [512]u8,
	cache_valid: [32]bool,
	budget:     int, // GSU cycles available to run
	irq:        bool,
}

gsu_reset :: proc(g: ^Gsu) {
	g^ = {}
	g.pipe = 0x01 // NOP
}

// --- memory as the GSU sees it ------------------------------------------------

@(private = "file")
gsu_read :: proc(c: ^Console, bank: u8, addr: u16) -> u8 {
	cart := &c.cart
	b := int(bank & 0x7F)
	switch {
	case b < 0x40:
		off := b * 0x8000 + int(addr & 0x7FFF)
		return cart.rom[off % len(cart.rom)]
	case b < 0x60:
		off := (b - 0x40) * 0x10000 + int(addr)
		return cart.rom[off % len(cart.rom)]
	case b >= 0x70 && b <= 0x71 && len(cart.sram) > 0:
		return cart.sram[((b & 1) * 0x10000 + int(addr)) & cart.sram_mask]
	}
	return 0
}

@(private = "file")
ram_read :: #force_inline proc(c: ^Console, addr: u16) -> u8 {
	return gsu_read(c, 0x70 + c.gsu.rambr, addr)
}

@(private = "file")
ram_write :: proc(c: ^Console, addr: u16, v: u8) {
	cart := &c.cart
	if len(cart.sram) > 0 {
		cart.sram[(int(c.gsu.rambr & 1) * 0x10000 + int(addr)) & cart.sram_mask] = v
	}
}

@(private = "file")
refill_rom_buffer :: #force_inline proc(c: ^Console) {
	c.gsu.rom_buffer = gsu_read(c, c.gsu.rombr, c.gsu.r[14])
}

@(private = "file")
cache_flush :: proc(g: ^Gsu) {
	g.cache_valid = {}
}

// Opcode fetch through the instruction cache.
@(private = "file")
fetch_byte :: proc(c: ^Console, addr: u16) -> u8 {
	g := &c.gsu
	offset := addr - g.cbr
	if offset < 512 {
		line := offset >> 4
		if !g.cache_valid[line] {
			dp := offset & 0xFFF0
			sp := (g.cbr + dp) & 0xFFF0
			for n in u16(0) ..< 16 {
				g.cache[(dp + n) & 511] = gsu_read(c, g.pbr, sp + n)
			}
			g.cache_valid[line] = true
			g.budget -= 6
		} else {
			g.budget -= 1
		}
		return g.cache[offset]
	}
	g.budget -= 3
	return gsu_read(c, g.pbr, addr)
}

// Returns the prefetched byte and prefetches the next one (immediates).
@(private = "file")
next_byte :: proc(c: ^Console) -> u8 {
	g := &c.gsu
	v := g.pipe
	g.r[15] += 1
	g.pipe = fetch_byte(c, g.r[15])
	g.r15_written = false
	return v
}

// SNES-side cache access ($3100-$32FF).
gsu_cache_read :: proc(g: ^Gsu, offset: u16) -> u8 {
	return g.cache[(offset + g.cbr) & 511]
}

gsu_cache_write :: proc(g: ^Gsu, offset: u16, v: u8) {
	a := (offset + g.cbr) & 511
	g.cache[a] = v
	if a & 15 == 15 {
		g.cache_valid[a >> 4] = true
	}
}

// --- SNES-side registers ($3000-$303F) ---------------------------------------------

gsu_reg_read :: proc(c: ^Console, a: u16) -> u8 {
	g := &c.gsu
	switch a {
	case 0x3000 ..= 0x301F:
		r := g.r[(a - 0x3000) >> 1]
		return a & 1 == 0 ? u8(r) : u8(r >> 8)
	case 0x3030: return u8(g.sfr)
	case 0x3031:
		v := u8(g.sfr >> 8)
		g.sfr &= ~SFR_IRQ
		g.irq = false
		c.cpu.irq_line = c.irq_flag
		return v
	case 0x3034: return g.pbr
	case 0x3036: return g.rombr
	case 0x303B: return 0x04 // VCR: GSU-2
	case 0x303C: return g.rambr
	case 0x303E: return u8(g.cbr)
	case 0x303F: return u8(g.cbr >> 8)
	case 0x3100 ..= 0x32FF: return gsu_cache_read(g, a - 0x3100)
	}
	return 0
}

gsu_reg_write :: proc(c: ^Console, a: u16, v: u8) {
	g := &c.gsu
	switch a {
	case 0x3000 ..= 0x301F:
		i := (a - 0x3000) >> 1
		if a & 1 == 0 {
			g.r[i] = (g.r[i] & 0xFF00) | u16(v)
		} else {
			g.r[i] = (g.r[i] & 0x00FF) | u16(v) << 8
		}
		if i == 14 {
			refill_rom_buffer(c)
		}
		if a == 0x301F { // writing R15's high byte starts the GSU
			g.sfr |= SFR_G
		}
	case 0x3030:
		was_running := g.sfr & SFR_G != 0
		g.sfr = (g.sfr & 0xFF00) | u16(v)
		if was_running && g.sfr & SFR_G == 0 {
			g.cbr = 0
			cache_flush(g)
		}
	case 0x3031: g.sfr = (g.sfr & 0x00FF) | u16(v) << 8
	case 0x3033: g.bramr = v & 1
	case 0x3034:
		g.pbr = v & 0x7F
		cache_flush(g)
	case 0x3037: g.cfgr = v
	case 0x3038: g.scbr = v
	case 0x3039: g.clsr = v & 1
	case 0x303A: g.scmr = v
	case 0x3100 ..= 0x32FF: gsu_cache_write(g, a - 0x3100, v)
	}
}

gsu_running :: #force_inline proc(c: ^Console) -> bool {
	return c.gsu.sfr & SFR_G != 0
}

// Runs the GSU for `master` master-clock cycles (21.48 MHz). The GSU runs
// at 10.74 MHz, or 21.48 MHz when CLSR is set.
gsu_run :: proc(c: ^Console, master: int) {
	g := &c.gsu
	if g.sfr & SFR_G == 0 {
		return
	}
	g.budget += g.clsr != 0 ? master : master / 2
	for g.budget > 0 && g.sfr & SFR_G != 0 {
		gsu_step(c)
	}
	if g.sfr & SFR_G == 0 {
		g.budget = 0
	}
}

// --- execution ----------------------------------------------------------------------

@(private = "file")
sr :: #force_inline proc(g: ^Gsu) -> u16 {return g.r[g.sreg]}

// Writes the destination register (R14 refills the ROM buffer; R15 jumps,
// with the prefetched byte still executing).
@(private = "file")
set_dr :: proc(c: ^Console, v: u16) {
	set_reg(c, c.gsu.dreg, v)
}

@(private = "file")
set_reg :: proc(c: ^Console, n: u8, v: u16) {
	g := &c.gsu
	g.r[n] = v
	switch n {
	case 14: refill_rom_buffer(c)
	case 15: g.r15_written = true
	}
}

@(private = "file")
flag :: #force_inline proc(g: ^Gsu, f: u16, on: bool) {
	if on {g.sfr |= f} else {g.sfr &= ~f}
}

@(private = "file")
set_sz :: #force_inline proc(g: ^Gsu, v: u16) {
	flag(g, SFR_S, v & 0x8000 != 0)
	flag(g, SFR_Z, v == 0)
}

@(private = "file")
reset_prefix :: #force_inline proc(g: ^Gsu) {
	g.sfr &= ~(SFR_ALT1 | SFR_ALT2 | SFR_B)
	g.sreg, g.dreg = 0, 0
}

@(private = "file")
color_of :: #force_inline proc(g: ^Gsu, source: u8) -> u8 {
	if g.por & 0x04 != 0 {return (g.colr & 0xF0) | (source >> 4)}
	if g.por & 0x08 != 0 {return (g.colr & 0xF0) | (source & 0x0F)}
	return source
}

@(private = "file")
pixel_address :: proc(g: ^Gsu, x, y: u8) -> (addr: int, bpp: int) {
	md := int(g.scmr & 3)
	ht := int((g.scmr >> 2) & 1) | int((g.scmr >> 4) & 2)
	if g.por & 0x10 != 0 {ht = 3}
	xi, yi := int(x), int(y)
	cn: int
	switch ht {
	case 0: cn = ((xi & 0xF8) << 1) + ((yi & 0xF8) >> 3)
	case 1: cn = ((xi & 0xF8) << 1) + ((xi & 0xF8) >> 1) + ((yi & 0xF8) >> 3)
	case 2: cn = ((xi & 0xF8) << 1) + (xi & 0xF8) + ((yi & 0xF8) >> 3)
	case 3: cn = ((yi & 0x80) << 2) + ((xi & 0x80) << 1) + ((yi & 0x78) << 1) + ((xi & 0x78) >> 3)
	}
	bpp = 2 << uint(md - (md >> 1)) // 2, 4, (4), 8
	addr = cn * bpp * 8 + int(g.scbr) * 1024 + (yi & 7) * 2
	return
}

@(private = "file")
plot :: proc(c: ^Console) {
	g := &c.gsu
	x, y := u8(g.r[1]), u8(g.r[2])
	md := g.scmr & 3
	if g.por & 0x01 == 0 { // transparency
		if md == 3 {
			if g.por & 0x08 != 0 {
				if g.colr & 0x0F == 0 {return}
			} else if g.colr == 0 {
				return
			}
		} else if g.colr & 0x0F == 0 {
			return
		}
	}
	color := g.colr
	if g.por & 0x02 != 0 && md != 3 {
		if (x ~ y) & 1 != 0 {color >>= 4}
		color &= 0x0F
	}
	addr, bpp := pixel_address(g, x, y)
	bit := u8(0x80) >> (x & 7)
	for n in 0 ..< bpp {
		a := u16(addr + (n >> 1) * 16 + (n & 1))
		v := gsu_read(c, 0x70, a)
		if color & (1 << uint(n)) != 0 {v |= bit} else {v &= ~bit}
		save := g.rambr
		g.rambr = 0
		ram_write(c, a, v)
		g.rambr = save
	}
}

@(private = "file")
rpix :: proc(c: ^Console) -> u8 {
	g := &c.gsu
	x, y := u8(g.r[1]), u8(g.r[2])
	addr, bpp := pixel_address(g, x, y)
	bit := u8(0x80) >> (x & 7)
	color: u8
	for n in 0 ..< bpp {
		if gsu_read(c, 0x70, u16(addr + (n >> 1) * 16 + (n & 1))) & bit != 0 {
			color |= 1 << uint(n)
		}
	}
	return color
}

@(private = "file")
stop :: proc(c: ^Console) {
	g := &c.gsu
	g.sfr &= ~SFR_G
	g.pipe = 0x01
	if g.cfgr & 0x80 == 0 { // IRQ not masked
		g.sfr |= SFR_IRQ
		g.irq = true
		c.cpu.irq_line = true
	}
}

gsu_step :: proc(c: ^Console) {
	g := &c.gsu
	op := g.pipe
	g.pipe = fetch_byte(c, g.r[15])
	g.r15_written = false
	alt := (g.sfr >> 8) & 3 // ALT1 = 1, ALT2 = 2, ALT3 = 3
	n := op & 0x0F
	prefix := false
	switch op {
	case 0x00:
		stop(c)
	case 0x01: // NOP
	case 0x02: // CACHE
		if g.cbr != g.r[15] & 0xFFF0 {
			g.cbr = g.r[15] & 0xFFF0
			cache_flush(g)
		}
	case 0x03: // LSR
		v := sr(g)
		flag(g, SFR_CY, v & 1 != 0)
		r := v >> 1
		set_dr(c, r)
		set_sz(g, r)
	case 0x04: // ROL
		v := sr(g)
		r := v << 1 | (g.sfr & SFR_CY != 0 ? 1 : 0)
		flag(g, SFR_CY, v & 0x8000 != 0)
		set_dr(c, r)
		set_sz(g, r)
	case 0x05 ..= 0x0F: // branches: displacement is relative to the following byte
		disp := u16(i16(i8(next_byte(c))))
		taken: bool
		s := g.sfr & SFR_S != 0
		ov := g.sfr & SFR_OV != 0
		switch op {
		case 0x05: taken = true
		case 0x06: taken = s == ov
		case 0x07: taken = s != ov
		case 0x08: taken = g.sfr & SFR_Z == 0
		case 0x09: taken = g.sfr & SFR_Z != 0
		case 0x0A: taken = !s
		case 0x0B: taken = s
		case 0x0C: taken = g.sfr & SFR_CY == 0
		case 0x0D: taken = g.sfr & SFR_CY != 0
		case 0x0E: taken = !ov
		case 0x0F: taken = ov
		}
		if taken {
			set_reg(c, 15, g.r[15] + disp) // relative to the byte after the displacement
		}
	case 0x10 ..= 0x1F: // TO / MOVE
		if g.sfr & SFR_B != 0 {
			set_reg(c, n, sr(g))
		} else {
			g.dreg = n
			prefix = true
		}
	case 0x20 ..= 0x2F: // WITH
		g.sreg, g.dreg = n, n
		g.sfr |= SFR_B
		prefix = true
	case 0x30 ..= 0x3B: // STW / STB (Rn)
		addr := g.r[n]
		g.ram_addr = addr
		v := sr(g)
		ram_write(c, addr, u8(v))
		if alt != 1 {
			ram_write(c, addr ~ 1, u8(v >> 8))
		}
	case 0x3C: // LOOP
		g.r[12] -= 1
		set_sz(g, g.r[12])
		if g.r[12] != 0 {
			set_reg(c, 15, g.r[13])
		}
	case 0x3D:
		g.sfr = (g.sfr & ~SFR_ALT2) | SFR_ALT1
		prefix = true
	case 0x3E:
		g.sfr = (g.sfr & ~SFR_ALT1) | SFR_ALT2
		prefix = true
	case 0x3F:
		g.sfr |= SFR_ALT1 | SFR_ALT2
		prefix = true
	case 0x40 ..= 0x4B: // LDW / LDB (Rn)
		addr := g.r[n]
		g.ram_addr = addr
		if alt == 1 {
			set_dr(c, u16(ram_read(c, addr)))
		} else {
			set_dr(c, u16(ram_read(c, addr)) | u16(ram_read(c, addr ~ 1)) << 8)
		}
	case 0x4C: // PLOT / RPIX
		if alt == 1 {
			v := u16(rpix(c))
			set_dr(c, v)
			set_sz(g, v)
		} else {
			plot(c)
			g.r[1] += 1
		}
	case 0x4D: // SWAP
		v := sr(g)
		r := v >> 8 | v << 8
		set_dr(c, r)
		set_sz(g, r)
	case 0x4E: // COLOR / CMODE
		if alt == 1 {
			g.por = u8(sr(g))
		} else {
			g.colr = color_of(g, u8(sr(g)))
		}
	case 0x4F: // NOT
		r := ~sr(g)
		set_dr(c, r)
		set_sz(g, r)
	case 0x50 ..= 0x5F: // ADD / ADC / ADD # / ADC #
		a := u32(sr(g))
		b := alt >= 2 ? u32(n) : u32(g.r[n])
		carry := u32(alt & 1 != 0 && g.sfr & SFR_CY != 0 ? 1 : 0)
		r := a + b + carry
		flag(g, SFR_OV, (~(a ~ b) & (a ~ r) & 0x8000) != 0)
		flag(g, SFR_CY, r > 0xFFFF)
		set_sz(g, u16(r))
		set_dr(c, u16(r))
	case 0x60 ..= 0x6F: // SUB / SBC / SUB # / CMP
		a := i32(sr(g))
		b := alt == 2 ? i32(n) : i32(g.r[n])
		borrow := i32(alt == 1 && g.sfr & SFR_CY == 0 ? 1 : 0)
		r := a - b - borrow
		flag(g, SFR_OV, ((a ~ b) & (a ~ r) & 0x8000) != 0)
		flag(g, SFR_CY, r >= 0)
		set_sz(g, u16(r))
		if alt != 3 {
			set_dr(c, u16(r))
		}
	case 0x70: // MERGE
		r := (g.r[7] & 0xFF00) | (g.r[8] >> 8)
		flag(g, SFR_S, r & 0x8080 != 0)
		flag(g, SFR_OV, r & 0xC0C0 != 0)
		flag(g, SFR_CY, r & 0xE0E0 != 0)
		flag(g, SFR_Z, r & 0xF0F0 != 0)
		set_dr(c, r)
	case 0x71 ..= 0x7F: // AND / BIC / AND # / BIC #
		b := alt >= 2 ? u16(n) : g.r[n]
		if alt & 1 != 0 {b = ~b}
		r := sr(g) & b
		set_sz(g, r)
		set_dr(c, r)
	case 0x80 ..= 0x8F: // MULT / UMULT (8x8)
		b := alt >= 2 ? u16(n) : g.r[n]
		r: u16
		if alt & 1 != 0 {
			r = u16(u8(sr(g))) * u16(u8(b))
		} else {
			r = u16(i16(i8(u8(sr(g)))) * i16(i8(u8(b))))
		}
		set_sz(g, r)
		set_dr(c, r)
		g.budget -= g.cfgr & 0x20 != 0 ? 0 : 1
	case 0x90: // SBK
		v := sr(g)
		ram_write(c, g.ram_addr, u8(v))
		ram_write(c, g.ram_addr ~ 1, u8(v >> 8))
	case 0x91 ..= 0x94: // LINK #n
		g.r[11] = g.r[15] + u16(n)
	case 0x95: // SEX
		r := u16(i16(i8(u8(sr(g)))))
		set_sz(g, r)
		set_dr(c, r)
	case 0x96: // ASR / DIV2
		v := sr(g)
		flag(g, SFR_CY, v & 1 != 0)
		r := u16(i16(v) >> 1)
		if alt == 1 && v == 0xFFFF {r = 0}
		set_sz(g, r)
		set_dr(c, r)
	case 0x97: // ROR
		v := sr(g)
		r := v >> 1 | (g.sfr & SFR_CY != 0 ? 0x8000 : 0)
		flag(g, SFR_CY, v & 1 != 0)
		set_sz(g, r)
		set_dr(c, r)
	case 0x98 ..= 0x9D: // JMP / LJMP
		if alt == 1 {
			g.pbr = u8(g.r[n] & 0x7F)
			set_reg(c, 15, sr(g))
			g.cbr = g.r[15] & 0xFFF0
			cache_flush(g)
		} else {
			set_reg(c, 15, g.r[n])
		}
	case 0x9E: // LOB
		r := sr(g) & 0xFF
		flag(g, SFR_S, r & 0x80 != 0)
		flag(g, SFR_Z, r == 0)
		set_dr(c, r)
	case 0x9F: // FMULT / LMULT
		r := i32(i16(sr(g))) * i32(i16(g.r[6]))
		if alt == 1 {
			g.r[4] = u16(r)
		}
		hi := u16(u32(r) >> 16)
		flag(g, SFR_CY, (u32(r) >> 15) & 1 != 0)
		set_sz(g, hi)
		set_dr(c, hi)
		g.budget -= g.cfgr & 0x20 != 0 ? 3 : 7
	case 0xA0 ..= 0xAF: // IBT / LMS / SMS
		imm := next_byte(c)
		switch alt {
		case 1:
			addr := u16(imm) << 1
			g.ram_addr = addr
			set_reg(c, n, u16(ram_read(c, addr)) | u16(ram_read(c, addr ~ 1)) << 8)
		case 2:
			addr := u16(imm) << 1
			g.ram_addr = addr
			ram_write(c, addr, u8(g.r[n]))
			ram_write(c, addr ~ 1, u8(g.r[n] >> 8))
		case:
			set_reg(c, n, u16(i16(i8(imm))))
		}
	case 0xB0 ..= 0xBF: // FROM / MOVES
		if g.sfr & SFR_B != 0 {
			v := g.r[n]
			flag(g, SFR_OV, v & 0x80 != 0)
			set_sz(g, v)
			set_dr(c, v)
		} else {
			g.sreg = n
			prefix = true
		}
	case 0xC0: // HIB
		r := sr(g) >> 8
		flag(g, SFR_S, r & 0x80 != 0)
		flag(g, SFR_Z, r == 0)
		set_dr(c, r)
	case 0xC1 ..= 0xCF: // OR / XOR / OR # / XOR #
		b := alt >= 2 ? u16(n) : g.r[n]
		r := alt & 1 != 0 ? sr(g) ~ b : sr(g) | b
		set_sz(g, r)
		set_dr(c, r)
	case 0xD0 ..= 0xDE: // INC
		r := g.r[n] + 1
		set_sz(g, r)
		set_reg(c, n, r)
	case 0xDF: // GETC / RAMB / ROMB
		switch alt {
		case 2: g.rambr = u8(sr(g) & 1)
		case 3: g.rombr = u8(sr(g) & 0x7F)
		case: g.colr = color_of(g, g.rom_buffer)
		}
	case 0xE0 ..= 0xEE: // DEC
		r := g.r[n] - 1
		set_sz(g, r)
		set_reg(c, n, r)
	case 0xEF: // GETB / GETBH / GETBL / GETBS
		b := g.rom_buffer
		r: u16
		switch alt {
		case 0: r = u16(b)
		case 1: r = u16(b) << 8 | (sr(g) & 0xFF)
		case 2: r = (sr(g) & 0xFF00) | u16(b)
		case 3: r = u16(i16(i8(b)))
		}
		set_dr(c, r)
	case 0xF0 ..= 0xFF: // IWT / LM / SM
		lo := next_byte(c)
		hi := next_byte(c)
		imm := u16(lo) | u16(hi) << 8
		switch alt {
		case 1:
			g.ram_addr = imm
			set_reg(c, n, u16(ram_read(c, imm)) | u16(ram_read(c, imm ~ 1)) << 8)
		case 2:
			g.ram_addr = imm
			ram_write(c, imm, u8(g.r[n]))
			ram_write(c, imm ~ 1, u8(g.r[n] >> 8))
		case:
			set_reg(c, n, imm)
		}
	}
	if !prefix {
		reset_prefix(g)
	}
	if !g.r15_written {
		g.r[15] += 1
	}
}
