package snes

// Sony SPC700 sound CPU with 64 KiB of RAM, three timers and the S-DSP.

// Boot ROM mapped at $FFC0. This is an original routine (not Nintendo's IPL)
// that implements the same documented upload protocol:
//   - clear $00-$EF, set SP=$EF, signal ready with $AA/$BB in ports 0/1
//   - wait for $CC in port 0, then loop: ports 2/3 = address, port 1 = 0 to
//     jump there, non-zero to receive a block; each data byte arrives in
//     port 1 with its index in port 0, and is acknowledged by echoing port 0.
@(rodata)
BOOT_ROM := [64]u8 {
	0xCD, 0xEF,             // FFC0 mov x,#$EF
	0xBD,                   // FFC2 mov sp,x
	0xE8, 0x00,             // FFC3 mov a,#$00
	0xC6,                   // FFC5 mov (x),a
	0x1D,                   // FFC6 dec x
	0xD0, 0xFC,             // FFC7 bne $FFC5
	0x8F, 0xAA, 0xF4,       // FFC9 mov $F4,#$AA
	0x8F, 0xBB, 0xF5,       // FFCC mov $F5,#$BB
	0x78, 0xCC, 0xF4,       // FFCF cmp $F4,#$CC
	0xD0, 0xFB,             // FFD2 bne $FFCF
	0xBA, 0xF6,             // FFD4 start: movw ya,$F6     (destination address)
	0xDA, 0x00,             // FFD6 movw $00,ya
	0xBA, 0xF4,             // FFD8 movw ya,$F4           (a = port0, y = port1)
	0xC4, 0xF4,             // FFDA mov $F4,a             (acknowledge)
	0xDD,                   // FFDC mov a,y
	0x5D,                   // FFDD mov x,a
	0xD0, 0x03,             // FFDE bne $FFE3             (non-zero: transfer)
	0x1F, 0x00, 0x00,       // FFE0 jmp [$0000+x]         (x = 0: run uploaded code)
	0x8D, 0x00,             // FFE3 mov y,#0
	0x7E, 0xF4,             // FFE5 wait: cmp y,$F4
	0xF0, 0x04,             // FFE7 beq got
	0x10, 0xFA,             // FFE9 bpl wait              (data not there yet)
	0x2F, 0xE7,             // FFEB bra start             (port0 jumped ahead: new command)
	0xE4, 0xF5,             // FFED got: mov a,$F5
	0xCB, 0xF4,             // FFEF mov $F4,y
	0xD7, 0x00,             // FFF1 mov [$00]+y,a
	0xFC,                   // FFF3 inc y
	0xD0, 0xEF,             // FFF4 bne wait
	0xAB, 0x01,             // FFF6 inc $01
	0x2F, 0xEB,             // FFF8 bra wait
	0x00, 0x00, 0x00, 0x00, // FFFA unused
	0xC0, 0xFF,             // FFFE reset vector
}

@(rodata, private = "file")
CYCLES := [256]u8 {
	2, 8, 4, 5, 3, 4, 3, 6, 2, 6, 5, 4, 5, 4, 6, 8,
	2, 8, 4, 5, 4, 5, 5, 6, 5, 5, 6, 5, 2, 2, 4, 6,
	2, 8, 4, 5, 3, 4, 3, 6, 2, 6, 5, 4, 5, 4, 5, 4,
	2, 8, 4, 5, 4, 5, 5, 6, 5, 5, 6, 5, 2, 2, 3, 8,
	2, 8, 4, 5, 3, 4, 3, 6, 2, 6, 4, 4, 5, 4, 6, 6,
	2, 8, 4, 5, 4, 5, 5, 6, 5, 5, 4, 5, 2, 2, 4, 3,
	2, 8, 4, 5, 3, 4, 3, 6, 2, 6, 4, 4, 5, 4, 5, 5,
	2, 8, 4, 5, 4, 5, 5, 6, 5, 5, 5, 5, 2, 2, 3, 6,
	2, 8, 4, 5, 3, 4, 3, 6, 2, 6, 5, 4, 5, 2, 4, 5,
	2, 8, 4, 5, 4, 5, 5, 6, 5, 5, 5, 5, 2, 2, 12, 5,
	3, 8, 4, 5, 3, 4, 3, 6, 2, 6, 4, 4, 5, 2, 4, 4,
	2, 8, 4, 5, 4, 5, 5, 6, 5, 5, 5, 5, 2, 2, 3, 4,
	3, 8, 4, 5, 4, 5, 4, 7, 2, 5, 6, 4, 5, 2, 4, 9,
	2, 8, 4, 5, 5, 6, 6, 7, 4, 5, 5, 5, 2, 2, 6, 3,
	2, 8, 4, 5, 3, 4, 3, 6, 2, 4, 5, 3, 4, 3, 4, 3,
	2, 8, 4, 5, 4, 5, 5, 6, 3, 4, 5, 4, 2, 2, 4, 3,
}

PSW_C :: 0x01
PSW_Z :: 0x02
PSW_I :: 0x04
PSW_H :: 0x08
PSW_B :: 0x10
PSW_P :: 0x20
PSW_V :: 0x40
PSW_N :: 0x80

Timer :: struct {
	enabled: bool,
	target:  u8,
	stage:   u8,
	output:  u8,
}

Spc :: struct {
	a, x, y, sp: u8,
	psw:         u8,
	pc:          u16,
	ram:         [0x10000]u8,
	port_in:     [4]u8, // written by the main CPU
	port_out:    [4]u8, // read by the main CPU
	control:     u8,
	dsp_addr:    u8,
	timers:      [3]Timer,
	timer_div:   [3]int,
	stopped:     bool,
	extra:       int, // extra cycles from taken branches
	dsp:         Dsp,
}

spc_reset :: proc(s: ^Spc) {
	s.a = 0
	s.x = 0
	s.y = 0
	s.sp = 0xEF
	s.psw = 0x02
	s.control = 0x80
	s.stopped = false
	s.timers = {}
	s.timer_div = {}
	s.port_in = {}
	s.port_out = {}
	s.pc = u16(BOOT_ROM[62]) | u16(BOOT_ROM[63]) << 8
	dsp_reset(&s.dsp)
}

// --- memory ----------------------------------------------------------------

spc_read :: proc(s: ^Spc, addr: u16) -> u8 {
	switch addr {
	case 0xF0, 0xF1, 0xFA, 0xFB, 0xFC:
		return 0
	case 0xF2:
		return s.dsp_addr
	case 0xF3:
		return dsp_read(&s.dsp, s.dsp_addr & 0x7F)
	case 0xF4 ..= 0xF7:
		return s.port_in[addr - 0xF4]
	case 0xFD ..= 0xFF:
		t := &s.timers[addr - 0xFD]
		v := t.output
		t.output = 0
		return v
	case 0xFFC0 ..= 0xFFFF:
		if s.control & 0x80 != 0 {
			return BOOT_ROM[addr - 0xFFC0]
		}
	}
	return s.ram[addr]
}

spc_write :: proc(s: ^Spc, addr: u16, v: u8) {
	switch addr {
	case 0xF1:
		for i in 0 ..< 3 {
			on := v & (1 << uint(i)) != 0
			if on && !s.timers[i].enabled {
				s.timers[i].stage = 0
				s.timers[i].output = 0
			}
			s.timers[i].enabled = on
		}
		if v & 0x10 != 0 {
			s.port_in[0] = 0
			s.port_in[1] = 0
		}
		if v & 0x20 != 0 {
			s.port_in[2] = 0
			s.port_in[3] = 0
		}
		s.control = v
	case 0xF2:
		s.dsp_addr = v
	case 0xF3:
		if s.dsp_addr < 0x80 {
			dsp_write(&s.dsp, s.dsp_addr, v)
		}
	case 0xF4 ..= 0xF7:
		s.port_out[addr - 0xF4] = v
	case 0xFA ..= 0xFC:
		s.timers[addr - 0xFA].target = v
	}
	// Writes always land in RAM, even under the boot ROM and I/O registers.
	s.ram[addr] = v
}

// Advances the timers by `cycles` SPC clocks.
@(private = "file")
spc_tick_timers :: proc(s: ^Spc, cycles: int) {
	@(static, rodata) PERIOD := [3]int{128, 128, 16}
	for i in 0 ..< 3 {
		s.timer_div[i] += cycles
		for s.timer_div[i] >= PERIOD[i] {
			s.timer_div[i] -= PERIOD[i]
			t := &s.timers[i]
			if !t.enabled {
				continue
			}
			t.stage += 1
			if t.stage == t.target { // target 0 means 256
				t.stage = 0
				t.output = (t.output + 1) & 0x0F
			}
		}
	}
}

// --- addressing helpers ----------------------------------------------------

@(private = "file")
fetch :: #force_inline proc(s: ^Spc) -> u8 {
	v := spc_read(s, s.pc)
	s.pc += 1
	return v
}

@(private = "file")
fetch16 :: #force_inline proc(s: ^Spc) -> u16 {
	lo := u16(fetch(s))
	return lo | u16(fetch(s)) << 8
}

@(private = "file")
dp :: #force_inline proc(s: ^Spc, offset: u8) -> u16 {
	return (s.psw & PSW_P != 0 ? 0x100 : 0) | u16(offset)
}

@(private = "file")
read_dp16 :: proc(s: ^Spc, offset: u8) -> u16 {
	lo := u16(spc_read(s, dp(s, offset)))
	return lo | u16(spc_read(s, dp(s, offset + 1))) << 8
}

@(private = "file")
write_dp16 :: proc(s: ^Spc, offset: u8, v: u16) {
	spc_write(s, dp(s, offset), u8(v))
	spc_write(s, dp(s, offset + 1), u8(v >> 8))
}

@(private = "file")
push :: proc(s: ^Spc, v: u8) {
	spc_write(s, 0x100 | u16(s.sp), v)
	s.sp -= 1
}

@(private = "file")
pop :: proc(s: ^Spc) -> u8 {
	s.sp += 1
	return spc_read(s, 0x100 | u16(s.sp))
}

@(private = "file")
set_nz :: #force_inline proc(s: ^Spc, v: u8) {
	s.psw &= ~u8(PSW_N | PSW_Z)
	if v == 0 {s.psw |= PSW_Z}
	s.psw |= v & 0x80
}

@(private = "file")
set_nz16 :: #force_inline proc(s: ^Spc, v: u16) {
	s.psw &= ~u8(PSW_N | PSW_Z)
	if v == 0 {s.psw |= PSW_Z}
	if v & 0x8000 != 0 {s.psw |= PSW_N}
}

@(private = "file")
set_flag :: #force_inline proc(s: ^Spc, f: u8, on: bool) {
	if on {s.psw |= f} else {s.psw &= ~f}
}

@(private = "file")
adc :: proc(s: ^Spc, a, b: u8) -> u8 {
	r := u16(a) + u16(b) + u16(s.psw & PSW_C)
	res := u8(r)
	set_flag(s, PSW_C, r > 0xFF)
	set_flag(s, PSW_V, (~(a ~ b) & (a ~ res) & 0x80) != 0)
	set_flag(s, PSW_H, ((a ~ b ~ res) & 0x10) != 0)
	set_nz(s, res)
	return res
}

@(private = "file")
sbc :: proc(s: ^Spc, a, b: u8) -> u8 {
	return adc(s, a, ~b)
}

@(private = "file")
cmp :: proc(s: ^Spc, a, b: u8) {
	set_flag(s, PSW_C, a >= b)
	set_nz(s, a - b)
}

@(private = "file")
branch :: proc(s: ^Spc, taken: bool) {
	offset := i8(fetch(s))
	if taken {
		s.pc = u16(i32(s.pc) + i32(offset))
		s.extra += 2
	}
}

// Operand of the ALU group (OR/AND/EOR/CMP/ADC/SBC), by column.
@(private = "file")
alu_operand_a :: proc(s: ^Spc, col: u8, odd_row: bool) -> u8 {
	if !odd_row {
		switch col {
		case 4: return spc_read(s, dp(s, fetch(s)))
		case 5: return spc_read(s, fetch16(s))
		case 6: return spc_read(s, dp(s, s.x))
		case 7:
			ptr := fetch(s) + s.x
			lo := u16(spc_read(s, dp(s, ptr)))
			addr := lo | u16(spc_read(s, dp(s, ptr + 1))) << 8
			return spc_read(s, addr)
		case 8: return fetch(s)
		}
	} else {
		switch col {
		case 4: return spc_read(s, dp(s, fetch(s) + s.x))
		case 5: return spc_read(s, fetch16(s) + u16(s.x))
		case 6: return spc_read(s, fetch16(s) + u16(s.y))
		case 7:
			ptr := fetch(s)
			lo := u16(spc_read(s, dp(s, ptr)))
			addr := (lo | u16(spc_read(s, dp(s, ptr + 1))) << 8) + u16(s.y)
			return spc_read(s, addr)
		}
	}
	return 0
}

@(private = "file")
alu :: proc(s: ^Spc, kind: u8, a, b: u8) -> (result: u8, store: bool) {
	switch kind {
	case 0: result = a | b; set_nz(s, result); return result, true
	case 1: result = a & b; set_nz(s, result); return result, true
	case 2: result = a ~ b; set_nz(s, result); return result, true
	case 3: cmp(s, a, b); return a, false
	case 4: return adc(s, a, b), true
	case 5: return sbc(s, a, b), true
	}
	return a, false
}

@(private = "file")
shift :: proc(s: ^Spc, kind: u8, v: u8) -> u8 {
	r: u8
	switch kind {
	case 0: set_flag(s, PSW_C, v & 0x80 != 0); r = v << 1
	case 1: r = v << 1 | (s.psw & PSW_C); set_flag(s, PSW_C, v & 0x80 != 0)
	case 2: set_flag(s, PSW_C, v & 1 != 0); r = v >> 1
	case 3: r = v >> 1 | (s.psw & PSW_C) << 7; set_flag(s, PSW_C, v & 1 != 0)
	}
	set_nz(s, r)
	return r
}

@(private = "file")
mem_bit :: proc(s: ^Spc) -> (addr: u16, bit: u8) {
	w := fetch16(s)
	return w & 0x1FFF, u8(w >> 13)
}

// Executes one instruction and returns the SPC cycles it took.
spc_step :: proc(s: ^Spc) -> int {
	if s.stopped {
		spc_tick_timers(s, 2)
		return 2
	}
	s.extra = 0
	op := fetch(s)
	execute(s, op)
	cycles := int(CYCLES[op]) + s.extra
	spc_tick_timers(s, cycles)
	return cycles
}

@(private = "file")
execute :: proc(s: ^Spc, op: u8) {
	lo := op & 0x0F
	hi := op >> 4

	// ALU group: OR/AND/EOR/CMP/ADC/SBC in rows 0-B, columns 4-9.
	if hi < 0xC && lo >= 4 && lo <= 9 {
		kind := hi >> 1
		odd := hi & 1 != 0
		switch {
		case lo <= 7 || (lo == 8 && !odd):
			b := alu_operand_a(s, lo, odd)
			r, st := alu(s, kind, s.a, b)
			if st {s.a = r}
		case lo == 8: // dp,#imm
			imm := fetch(s)
			addr := dp(s, fetch(s))
			r, st := alu(s, kind, spc_read(s, addr), imm)
			if st {spc_write(s, addr, r)}
		case lo == 9 && !odd: // dp,dp
			src := spc_read(s, dp(s, fetch(s)))
			addr := dp(s, fetch(s))
			r, st := alu(s, kind, spc_read(s, addr), src)
			if st {spc_write(s, addr, r)}
		case lo == 9: // (X),(Y)
			src := spc_read(s, dp(s, s.y))
			addr := dp(s, s.x)
			r, st := alu(s, kind, spc_read(s, addr), src)
			if st {spc_write(s, addr, r)}
		}
		return
	}

	// Shifts/rotates: rows 0,2,4,6 (+1), columns B and C.
	if hi < 8 && (lo == 0xB || lo == 0xC) {
		kind := hi >> 1
		odd := hi & 1 != 0
		switch {
		case lo == 0xB && !odd:
			addr := dp(s, fetch(s))
			spc_write(s, addr, shift(s, kind, spc_read(s, addr)))
		case lo == 0xC && !odd:
			addr := fetch16(s)
			spc_write(s, addr, shift(s, kind, spc_read(s, addr)))
		case lo == 0xB:
			addr := dp(s, fetch(s) + s.x)
			spc_write(s, addr, shift(s, kind, spc_read(s, addr)))
		case:
			s.a = shift(s, kind, s.a)
		}
		return
	}

	switch lo {
	case 0x1: // TCALL n
		push(s, u8(s.pc >> 8))
		push(s, u8(s.pc))
		vec := 0xFFDE - u16(hi) * 2
		s.pc = u16(spc_read(s, vec)) | u16(spc_read(s, vec + 1)) << 8
		return
	case 0x2: // SET1 / CLR1 dp.bit
		addr := dp(s, fetch(s))
		bit := u8(1) << (hi >> 1)
		v := spc_read(s, addr)
		spc_write(s, addr, hi & 1 == 0 ? v | bit : v & ~bit)
		return
	case 0x3: // BBS / BBC dp.bit, rel
		v := spc_read(s, dp(s, fetch(s)))
		bit := v & (u8(1) << (hi >> 1)) != 0
		branch(s, hi & 1 == 0 ? bit : !bit)
		return
	}

	switch op {
	case 0x00: // NOP
	case 0x10: branch(s, s.psw & PSW_N == 0)
	case 0x30: branch(s, s.psw & PSW_N != 0)
	case 0x50: branch(s, s.psw & PSW_V == 0)
	case 0x70: branch(s, s.psw & PSW_V != 0)
	case 0x90: branch(s, s.psw & PSW_C == 0)
	case 0xB0: branch(s, s.psw & PSW_C != 0)
	case 0xD0: branch(s, s.psw & PSW_Z == 0)
	case 0xF0: branch(s, s.psw & PSW_Z != 0)
	case 0x2F: branch(s, true)

	case 0x20: s.psw &= ~u8(PSW_P)
	case 0x40: s.psw |= PSW_P
	case 0x60: s.psw &= ~u8(PSW_C)
	case 0x80: s.psw |= PSW_C
	case 0xA0: s.psw |= PSW_I
	case 0xC0: s.psw &= ~u8(PSW_I)
	case 0xE0: s.psw &= ~u8(PSW_V | PSW_H)
	case 0xED: s.psw ~= PSW_C

	case 0x0A, 0x2A, 0x4A, 0x6A, 0x8A, 0xAA: // OR1/AND1/EOR1/MOV1 C, (/)mem.bit
		addr, bit := mem_bit(s)
		b := (spc_read(s, addr) >> bit) & 1 != 0
		c := s.psw & PSW_C != 0
		switch op {
		case 0x0A: c = c || b
		case 0x2A: c = c || !b
		case 0x4A: c = c && b
		case 0x6A: c = c && !b
		case 0x8A: c = c != b
		case 0xAA: c = b
		}
		set_flag(s, PSW_C, c)
	case 0xCA: // MOV1 mem.bit, C
		addr, bit := mem_bit(s)
		v := spc_read(s, addr)
		if s.psw & PSW_C != 0 {v |= 1 << bit} else {v &= ~(u8(1) << bit)}
		spc_write(s, addr, v)
	case 0xEA: // NOT1 mem.bit
		addr, bit := mem_bit(s)
		spc_write(s, addr, spc_read(s, addr) ~ (u8(1) << bit))

	case 0x0E, 0x4E: // TSET1 / TCLR1 !abs
		addr := fetch16(s)
		v := spc_read(s, addr)
		set_nz(s, s.a - v)
		spc_write(s, addr, op == 0x0E ? v | s.a : v & ~s.a)

	case 0x0D: push(s, s.psw)
	case 0x2D: push(s, s.a)
	case 0x4D: push(s, s.x)
	case 0x6D: push(s, s.y)
	case 0x8E: s.psw = pop(s)
	case 0xAE: s.a = pop(s)
	case 0xCE: s.x = pop(s)
	case 0xEE: s.y = pop(s)

	case 0x0F: // BRK
		push(s, u8(s.pc >> 8))
		push(s, u8(s.pc))
		push(s, s.psw)
		s.psw |= PSW_B
		s.psw &= ~u8(PSW_I)
		s.pc = u16(spc_read(s, 0xFFDE)) | u16(spc_read(s, 0xFFDF)) << 8
	case 0x1F: // JMP [!abs+X]
		addr := fetch16(s) + u16(s.x)
		s.pc = u16(spc_read(s, addr)) | u16(spc_read(s, addr + 1)) << 8
	case 0x5F: s.pc = fetch16(s)
	case 0x3F: // CALL
		target := fetch16(s)
		push(s, u8(s.pc >> 8))
		push(s, u8(s.pc))
		s.pc = target
	case 0x4F: // PCALL
		target := 0xFF00 | u16(fetch(s))
		push(s, u8(s.pc >> 8))
		push(s, u8(s.pc))
		s.pc = target
	case 0x6F:
		lo8 := u16(pop(s))
		s.pc = lo8 | u16(pop(s)) << 8
	case 0x7F:
		s.psw = pop(s)
		lo8 := u16(pop(s))
		s.pc = lo8 | u16(pop(s)) << 8

	case 0x1A, 0x3A: // DECW / INCW dp
		off := fetch(s)
		v := read_dp16(s, off)
		v = op == 0x3A ? v + 1 : v - 1
		write_dp16(s, off, v)
		set_nz16(s, v)
	case 0x5A: // CMPW YA, dp
		w := read_dp16(s, fetch(s))
		ya := u16(s.y) << 8 | u16(s.a)
		set_flag(s, PSW_C, ya >= w)
		set_nz16(s, ya - w)
	case 0x7A, 0x9A: // ADDW / SUBW YA, dp
		w := u32(read_dp16(s, fetch(s)))
		ya := u32(s.y) << 8 | u32(s.a)
		r: u32
		if op == 0x7A {
			r = ya + w
			set_flag(s, PSW_C, r > 0xFFFF)
			set_flag(s, PSW_V, (~(ya ~ w) & (ya ~ r) & 0x8000) != 0)
			set_flag(s, PSW_H, ((ya ~ w ~ r) & 0x1000) != 0)
		} else {
			r = ya - w
			set_flag(s, PSW_C, ya >= w)
			set_flag(s, PSW_V, ((ya ~ w) & (ya ~ r) & 0x8000) != 0)
			set_flag(s, PSW_H, ((ya ~ w ~ r) & 0x1000) == 0)
		}
		r &= 0xFFFF
		s.a = u8(r)
		s.y = u8(r >> 8)
		set_nz16(s, u16(r))
	case 0xBA: // MOVW YA, dp
		w := read_dp16(s, fetch(s))
		s.a = u8(w)
		s.y = u8(w >> 8)
		set_nz16(s, w)
	case 0xDA: // MOVW dp, YA
		write_dp16(s, fetch(s), u16(s.y) << 8 | u16(s.a))

	case 0x1D: s.x -= 1; set_nz(s, s.x)
	case 0x3D: s.x += 1; set_nz(s, s.x)
	case 0xDC: s.y -= 1; set_nz(s, s.y)
	case 0xFC: s.y += 1; set_nz(s, s.y)
	case 0x9C: s.a -= 1; set_nz(s, s.a)
	case 0xBC: s.a += 1; set_nz(s, s.a)
	case 0x8B, 0x9B, 0xAB, 0xBB, 0x8C, 0xAC: // DEC/INC dp, dp+X, !abs
		addr: u16
		switch op {
		case 0x8B, 0xAB: addr = dp(s, fetch(s))
		case 0x9B, 0xBB: addr = dp(s, fetch(s) + s.x)
		case:            addr = fetch16(s)
		}
		v := spc_read(s, addr)
		v = (op == 0xAB || op == 0xBB || op == 0xAC) ? v + 1 : v - 1
		spc_write(s, addr, v)
		set_nz(s, v)

	case 0x1E: cmp(s, s.x, spc_read(s, fetch16(s)))
	case 0x3E: cmp(s, s.x, spc_read(s, dp(s, fetch(s))))
	case 0xC8: cmp(s, s.x, fetch(s))
	case 0x5E: cmp(s, s.y, spc_read(s, fetch16(s)))
	case 0x7E: cmp(s, s.y, spc_read(s, dp(s, fetch(s))))
	case 0xAD: cmp(s, s.y, fetch(s))

	case 0x2E: // CBNE dp, rel
		v := spc_read(s, dp(s, fetch(s)))
		branch(s, s.a != v)
	case 0xDE: // CBNE dp+X, rel
		v := spc_read(s, dp(s, fetch(s) + s.x))
		branch(s, s.a != v)
	case 0x6E: // DBNZ dp, rel
		addr := dp(s, fetch(s))
		v := spc_read(s, addr) - 1
		spc_write(s, addr, v)
		branch(s, v != 0)
	case 0xFE: // DBNZ Y, rel
		s.y -= 1
		branch(s, s.y != 0)

	case 0xCF: // MUL YA
		r := u16(s.y) * u16(s.a)
		s.a = u8(r)
		s.y = u8(r >> 8)
		set_nz(s, s.y)
	case 0x9E: // DIV YA, X
		ya := u32(s.y) << 8 | u32(s.a)
		x := u32(s.x)
		set_flag(s, PSW_H, (s.y & 15) >= (s.x & 15))
		set_flag(s, PSW_V, s.y >= s.x)
		if u32(s.y) < x << 1 {
			s.a = u8(ya / x)
			s.y = u8(ya % x)
		} else {
			s.a = u8(255 - (ya - (x << 9)) / (256 - x))
			s.y = u8(x + (ya - (x << 9)) % (256 - x))
		}
		set_nz(s, s.a)
	case 0x9F: // XCN
		s.a = s.a >> 4 | s.a << 4
		set_nz(s, s.a)
	case 0xDF: // DAA
		if s.psw & PSW_C != 0 || s.a > 0x99 {
			s.a += 0x60
			s.psw |= PSW_C
		}
		if s.psw & PSW_H != 0 || s.a & 0x0F > 9 {
			s.a += 0x06
		}
		set_nz(s, s.a)
	case 0xBE: // DAS
		if s.psw & PSW_C == 0 || s.a > 0x99 {
			s.a -= 0x60
			s.psw &= ~u8(PSW_C)
		}
		if s.psw & PSW_H == 0 || s.a & 0x0F > 9 {
			s.a -= 0x06
		}
		set_nz(s, s.a)

	// --- MOV ---
	case 0x5D: s.x = s.a; set_nz(s, s.x)
	case 0x7D: s.a = s.x; set_nz(s, s.a)
	case 0xDD: s.a = s.y; set_nz(s, s.a)
	case 0xFD: s.y = s.a; set_nz(s, s.y)
	case 0x9D: s.x = s.sp; set_nz(s, s.x)
	case 0xBD: s.sp = s.x
	case 0x8D: s.y = fetch(s); set_nz(s, s.y)
	case 0xCD: s.x = fetch(s); set_nz(s, s.x)
	case 0xE8: s.a = fetch(s); set_nz(s, s.a)
	case 0x8F: // MOV dp, #imm
		imm := fetch(s)
		spc_write(s, dp(s, fetch(s)), imm)
	case 0xFA: // MOV dp, dp
		v := spc_read(s, dp(s, fetch(s)))
		spc_write(s, dp(s, fetch(s)), v)
	case 0xAF: // MOV (X)+, A
		spc_write(s, dp(s, s.x), s.a)
		s.x += 1
	case 0xBF: // MOV A, (X)+
		s.a = spc_read(s, dp(s, s.x))
		s.x += 1
		set_nz(s, s.a)
	case 0xC4: spc_write(s, dp(s, fetch(s)), s.a)
	case 0xC5: spc_write(s, fetch16(s), s.a)
	case 0xC6: spc_write(s, dp(s, s.x), s.a)
	case 0xC7:
		ptr := fetch(s) + s.x
		addr := u16(spc_read(s, dp(s, ptr))) | u16(spc_read(s, dp(s, ptr + 1))) << 8
		spc_write(s, addr, s.a)
	case 0xC9: spc_write(s, fetch16(s), s.x)
	case 0xCB: spc_write(s, dp(s, fetch(s)), s.y)
	case 0xCC: spc_write(s, fetch16(s), s.y)
	case 0xD4: spc_write(s, dp(s, fetch(s) + s.x), s.a)
	case 0xD5: spc_write(s, fetch16(s) + u16(s.x), s.a)
	case 0xD6: spc_write(s, fetch16(s) + u16(s.y), s.a)
	case 0xD7:
		ptr := fetch(s)
		addr := (u16(spc_read(s, dp(s, ptr))) | u16(spc_read(s, dp(s, ptr + 1))) << 8) + u16(s.y)
		spc_write(s, addr, s.a)
	case 0xD8: spc_write(s, dp(s, fetch(s)), s.x)
	case 0xD9: spc_write(s, dp(s, fetch(s) + s.y), s.x)
	case 0xDB: spc_write(s, dp(s, fetch(s) + s.x), s.y)
	case 0xE4: s.a = spc_read(s, dp(s, fetch(s))); set_nz(s, s.a)
	case 0xE5: s.a = spc_read(s, fetch16(s)); set_nz(s, s.a)
	case 0xE6: s.a = spc_read(s, dp(s, s.x)); set_nz(s, s.a)
	case 0xE7:
		ptr := fetch(s) + s.x
		addr := u16(spc_read(s, dp(s, ptr))) | u16(spc_read(s, dp(s, ptr + 1))) << 8
		s.a = spc_read(s, addr)
		set_nz(s, s.a)
	case 0xE9: s.x = spc_read(s, fetch16(s)); set_nz(s, s.x)
	case 0xEB: s.y = spc_read(s, dp(s, fetch(s))); set_nz(s, s.y)
	case 0xEC: s.y = spc_read(s, fetch16(s)); set_nz(s, s.y)
	case 0xF4: s.a = spc_read(s, dp(s, fetch(s) + s.x)); set_nz(s, s.a)
	case 0xF5: s.a = spc_read(s, fetch16(s) + u16(s.x)); set_nz(s, s.a)
	case 0xF6: s.a = spc_read(s, fetch16(s) + u16(s.y)); set_nz(s, s.a)
	case 0xF7:
		ptr := fetch(s)
		addr := (u16(spc_read(s, dp(s, ptr))) | u16(spc_read(s, dp(s, ptr + 1))) << 8) + u16(s.y)
		s.a = spc_read(s, addr)
		set_nz(s, s.a)
	case 0xF8: s.x = spc_read(s, dp(s, fetch(s))); set_nz(s, s.x)
	case 0xF9: s.x = spc_read(s, dp(s, fetch(s) + s.y)); set_nz(s, s.x)
	case 0xFB: s.y = spc_read(s, dp(s, fetch(s) + s.x)); set_nz(s, s.y)

	case 0xEF, 0xFF: // SLEEP / STOP
		s.stopped = true
	}
}
