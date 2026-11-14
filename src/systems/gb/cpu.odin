package gb

// Sharp SM83 (the Game Boy's 8080/Z80 hybrid). Every memory access costs one
// M-cycle via `read`/`write`; internal cycles call `tick` directly.

FLAG_Z :: 0x80
FLAG_N :: 0x40
FLAG_H :: 0x20
FLAG_C :: 0x10

Cpu :: struct {
	a, f, b, c, d, e, h, l: u8,
	sp, pc:   u16,
	ime:      bool,
	ime_next: bool, // EI takes effect after the following instruction
	halted:   bool,
	halt_bug: bool, // next opcode byte is read twice
	stopped:  bool,
}

cpu_reset :: proc(c: ^Console) {
	cpu := &c.cpu
	cpu^ = {}
	// Register values left behind by the boot ROM.
	if c.cgb {
		cpu.a, cpu.f = 0x11, 0x80
		cpu.b, cpu.c = 0x00, 0x00
		cpu.d, cpu.e = 0xFF, 0x56
		cpu.h, cpu.l = 0x00, 0x0D
	} else {
		cpu.a, cpu.f = 0x01, 0xB0
		cpu.b, cpu.c = 0x00, 0x13
		cpu.d, cpu.e = 0x00, 0xD8
		cpu.h, cpu.l = 0x01, 0x4D
	}
	cpu.sp = 0xFFFE
	cpu.pc = 0x0100
}

// --- helpers ----------------------------------------------------------------

@(private = "file")
fetch :: #force_inline proc(c: ^Console) -> u8 {
	v := read(c, c.cpu.pc)
	if c.cpu.halt_bug {
		c.cpu.halt_bug = false // PC fails to increment once
	} else {
		c.cpu.pc += 1
	}
	return v
}

@(private = "file")
fetch16 :: #force_inline proc(c: ^Console) -> u16 {
	lo := u16(fetch(c))
	return lo | u16(fetch(c)) << 8
}

@(private = "file")
push16 :: proc(c: ^Console, v: u16) {
	tick(c)
	c.cpu.sp -= 1
	write(c, c.cpu.sp, u8(v >> 8))
	c.cpu.sp -= 1
	write(c, c.cpu.sp, u8(v))
}

@(private = "file")
pop16 :: proc(c: ^Console) -> u16 {
	lo := u16(read(c, c.cpu.sp))
	c.cpu.sp += 1
	hi := u16(read(c, c.cpu.sp))
	c.cpu.sp += 1
	return lo | hi << 8
}

@(private = "file")
get_bc :: #force_inline proc(cpu: ^Cpu) -> u16 {return u16(cpu.b) << 8 | u16(cpu.c)}
@(private = "file")
get_de :: #force_inline proc(cpu: ^Cpu) -> u16 {return u16(cpu.d) << 8 | u16(cpu.e)}
@(private = "file")
get_hl :: #force_inline proc(cpu: ^Cpu) -> u16 {return u16(cpu.h) << 8 | u16(cpu.l)}
@(private = "file")
set_bc :: #force_inline proc(cpu: ^Cpu, v: u16) {cpu.b = u8(v >> 8); cpu.c = u8(v)}
@(private = "file")
set_de :: #force_inline proc(cpu: ^Cpu, v: u16) {cpu.d = u8(v >> 8); cpu.e = u8(v)}
@(private = "file")
set_hl :: #force_inline proc(cpu: ^Cpu, v: u16) {cpu.h = u8(v >> 8); cpu.l = u8(v)}

// Register pairs by the 2-bit field used in most opcodes (SP variant).
@(private = "file")
get_rp :: proc(cpu: ^Cpu, i: u8) -> u16 {
	switch i & 3 {
	case 0: return get_bc(cpu)
	case 1: return get_de(cpu)
	case 2: return get_hl(cpu)
	}
	return cpu.sp
}

@(private = "file")
set_rp :: proc(cpu: ^Cpu, i: u8, v: u16) {
	switch i & 3 {
	case 0: set_bc(cpu, v)
	case 1: set_de(cpu, v)
	case 2: set_hl(cpu, v)
	case 3: cpu.sp = v
	}
}

// 8-bit operand by register index: B C D E H L (HL) A.
@(private = "file")
get_r :: proc(c: ^Console, i: u8) -> u8 {
	cpu := &c.cpu
	switch i & 7 {
	case 0: return cpu.b
	case 1: return cpu.c
	case 2: return cpu.d
	case 3: return cpu.e
	case 4: return cpu.h
	case 5: return cpu.l
	case 6: return read(c, get_hl(cpu))
	}
	return cpu.a
}

@(private = "file")
set_r :: proc(c: ^Console, i: u8, v: u8) {
	cpu := &c.cpu
	switch i & 7 {
	case 0: cpu.b = v
	case 1: cpu.c = v
	case 2: cpu.d = v
	case 3: cpu.e = v
	case 4: cpu.h = v
	case 5: cpu.l = v
	case 6: write(c, get_hl(cpu), v)
	case 7: cpu.a = v
	}
}

@(private = "file")
flags :: #force_inline proc(z, n, h, cy: bool) -> u8 {
	f: u8
	if z {f |= FLAG_Z}
	if n {f |= FLAG_N}
	if h {f |= FLAG_H}
	if cy {f |= FLAG_C}
	return f
}

@(private = "file")
condition :: #force_inline proc(cpu: ^Cpu, cc: u8) -> bool {
	switch cc & 3 {
	case 0: return cpu.f & FLAG_Z == 0
	case 1: return cpu.f & FLAG_Z != 0
	case 2: return cpu.f & FLAG_C == 0
	}
	return cpu.f & FLAG_C != 0
}

@(private = "file")
alu :: proc(cpu: ^Cpu, op: u8, v: u8) {
	a := cpu.a
	carry: u8 = cpu.f & FLAG_C != 0 ? 1 : 0
	switch op & 7 {
	case 0: // ADD
		r := u16(a) + u16(v)
		cpu.a = u8(r)
		cpu.f = flags(cpu.a == 0, false, (a & 0xF) + (v & 0xF) > 0xF, r > 0xFF)
	case 1: // ADC
		r := u16(a) + u16(v) + u16(carry)
		cpu.a = u8(r)
		cpu.f = flags(cpu.a == 0, false, (a & 0xF) + (v & 0xF) + carry > 0xF, r > 0xFF)
	case 2: // SUB
		cpu.a = a - v
		cpu.f = flags(cpu.a == 0, true, a & 0xF < v & 0xF, a < v)
	case 3: // SBC
		r := i16(a) - i16(v) - i16(carry)
		cpu.a = u8(r)
		cpu.f = flags(cpu.a == 0, true, i16(a & 0xF) - i16(v & 0xF) - i16(carry) < 0, r < 0)
	case 4: // AND
		cpu.a = a & v
		cpu.f = flags(cpu.a == 0, false, true, false)
	case 5: // XOR
		cpu.a = a ~ v
		cpu.f = flags(cpu.a == 0, false, false, false)
	case 6: // OR
		cpu.a = a | v
		cpu.f = flags(cpu.a == 0, false, false, false)
	case 7: // CP
		cpu.f = flags(a == v, true, a & 0xF < v & 0xF, a < v)
	}
}

// --- interrupts -------------------------------------------------------------

@(private = "file")
service_interrupt :: proc(c: ^Console) -> bool {
	cpu := &c.cpu
	pending := c.ie & c.if_ & 0x1F
	if pending == 0 {
		return false
	}
	cpu.halted = false
	if !cpu.ime {
		return false
	}
	cpu.ime = false
	tick(c)
	tick(c)
	// The vector is chosen after the high byte is pushed (it can be cancelled).
	cpu.sp -= 1
	write(c, cpu.sp, u8(cpu.pc >> 8))
	pending = c.ie & c.if_ & 0x1F
	cpu.sp -= 1
	write(c, cpu.sp, u8(cpu.pc))
	if pending == 0 {
		cpu.pc = 0
		return true
	}
	bit: u8 = 0
	for pending & (1 << bit) == 0 {
		bit += 1
	}
	c.if_ &= ~(u8(1) << bit)
	cpu.pc = 0x40 + u16(bit) * 8
	tick(c)
	return true
}

cpu_step :: proc(c: ^Console) {
	cpu := &c.cpu
	enable_after := cpu.ime_next
	cpu.ime_next = false

	if service_interrupt(c) {
		return
	}
	if cpu.halted || cpu.stopped {
		tick(c)
		if cpu.stopped && c.joypad_pressed {
			cpu.stopped = false
		}
		return
	}
	execute(c, fetch(c))
	if enable_after {
		cpu.ime = true
	}
}

// --- instructions -------------------------------------------------------------

@(private = "file")
execute :: proc(c: ^Console, op: u8) {
	cpu := &c.cpu
	switch op {
	case 0x40 ..= 0x7F:
		if op == 0x76 { // HALT
			if !cpu.ime && c.ie & c.if_ & 0x1F != 0 {
				cpu.halt_bug = true
			} else {
				cpu.halted = true
			}
			return
		}
		set_r(c, op >> 3, get_r(c, op))
	case 0x80 ..= 0xBF:
		alu(cpu, op >> 3, get_r(c, op))
	case 0xC6, 0xCE, 0xD6, 0xDE, 0xE6, 0xEE, 0xF6, 0xFE:
		alu(cpu, op >> 3, fetch(c))

	case 0x00: // NOP
	case 0x10: // STOP
		_ = fetch(c)
		if c.cgb && c.key1 & 1 != 0 {
			c.double_speed = !c.double_speed
			c.key1 = 0
			c.div = 0
		} else {
			cpu.stopped = true
		}
	case 0x01, 0x11, 0x21, 0x31: // LD rr,d16
		set_rp(cpu, op >> 4, fetch16(c))
	case 0x02: write(c, get_bc(cpu), cpu.a)
	case 0x12: write(c, get_de(cpu), cpu.a)
	case 0x22:
		hl := get_hl(cpu)
		write(c, hl, cpu.a)
		set_hl(cpu, hl + 1)
	case 0x32:
		hl := get_hl(cpu)
		write(c, hl, cpu.a)
		set_hl(cpu, hl - 1)
	case 0x0A: cpu.a = read(c, get_bc(cpu))
	case 0x1A: cpu.a = read(c, get_de(cpu))
	case 0x2A:
		hl := get_hl(cpu)
		cpu.a = read(c, hl)
		set_hl(cpu, hl + 1)
	case 0x3A:
		hl := get_hl(cpu)
		cpu.a = read(c, hl)
		set_hl(cpu, hl - 1)
	case 0x03, 0x13, 0x23, 0x33: // INC rr
		set_rp(cpu, op >> 4, get_rp(cpu, op >> 4) + 1)
		tick(c)
	case 0x0B, 0x1B, 0x2B, 0x3B: // DEC rr
		set_rp(cpu, op >> 4, get_rp(cpu, op >> 4) - 1)
		tick(c)
	case 0x09, 0x19, 0x29, 0x39: // ADD HL,rr
		hl := get_hl(cpu)
		v := get_rp(cpu, op >> 4)
		r := u32(hl) + u32(v)
		set_hl(cpu, u16(r))
		cpu.f = (cpu.f & FLAG_Z) | flags(false, false, (hl & 0xFFF) + (v & 0xFFF) > 0xFFF, r > 0xFFFF)
		tick(c)
	case 0x04, 0x0C, 0x14, 0x1C, 0x24, 0x2C, 0x34, 0x3C: // INC r
		v := get_r(c, op >> 3)
		r := v + 1
		set_r(c, op >> 3, r)
		cpu.f = (cpu.f & FLAG_C) | flags(r == 0, false, v & 0xF == 0xF, false)
	case 0x05, 0x0D, 0x15, 0x1D, 0x25, 0x2D, 0x35, 0x3D: // DEC r
		v := get_r(c, op >> 3)
		r := v - 1
		set_r(c, op >> 3, r)
		cpu.f = (cpu.f & FLAG_C) | flags(r == 0, true, v & 0xF == 0, false)
	case 0x06, 0x0E, 0x16, 0x1E, 0x26, 0x2E, 0x36, 0x3E: // LD r,d8
		set_r(c, op >> 3, fetch(c))
	case 0x07: // RLCA
		cy := cpu.a >> 7
		cpu.a = cpu.a << 1 | cy
		cpu.f = flags(false, false, false, cy != 0)
	case 0x0F: // RRCA
		cy := cpu.a & 1
		cpu.a = cpu.a >> 1 | cy << 7
		cpu.f = flags(false, false, false, cy != 0)
	case 0x17: // RLA
		cy := cpu.a >> 7
		cpu.a = cpu.a << 1 | (cpu.f & FLAG_C != 0 ? 1 : 0)
		cpu.f = flags(false, false, false, cy != 0)
	case 0x1F: // RRA
		cy := cpu.a & 1
		cpu.a = cpu.a >> 1 | (cpu.f & FLAG_C != 0 ? 0x80 : 0)
		cpu.f = flags(false, false, false, cy != 0)
	case 0x08: // LD (a16),SP
		addr := fetch16(c)
		write(c, addr, u8(cpu.sp))
		write(c, addr + 1, u8(cpu.sp >> 8))
	case 0x18: // JR
		off := i8(fetch(c))
		cpu.pc = u16(i32(cpu.pc) + i32(off))
		tick(c)
	case 0x20, 0x28, 0x30, 0x38: // JR cc
		off := i8(fetch(c))
		if condition(cpu, (op >> 3) & 3) {
			cpu.pc = u16(i32(cpu.pc) + i32(off))
			tick(c)
		}
	case 0x27: // DAA
		a := cpu.a
		adjust: u8 = 0
		cy := cpu.f & FLAG_C != 0
		if cpu.f & FLAG_N == 0 {
			if cy || a > 0x99 {adjust |= 0x60; cy = true}
			if cpu.f & FLAG_H != 0 || a & 0x0F > 9 {adjust |= 0x06}
			a += adjust
		} else {
			if cy {adjust |= 0x60}
			if cpu.f & FLAG_H != 0 {adjust |= 0x06}
			a -= adjust
		}
		cpu.a = a
		cpu.f = (cpu.f & FLAG_N) | flags(a == 0, false, false, cy)
	case 0x2F: // CPL
		cpu.a = ~cpu.a
		cpu.f |= FLAG_N | FLAG_H
	case 0x37: // SCF
		cpu.f = (cpu.f & FLAG_Z) | FLAG_C
	case 0x3F: // CCF
		cpu.f = (cpu.f & (FLAG_Z | FLAG_C)) ~ FLAG_C

	// --- control flow ---
	case 0xC3: // JP
		cpu.pc = fetch16(c)
		tick(c)
	case 0xC2, 0xCA, 0xD2, 0xDA:
		addr := fetch16(c)
		if condition(cpu, (op >> 3) & 3) {
			cpu.pc = addr
			tick(c)
		}
	case 0xE9: // JP HL
		cpu.pc = get_hl(cpu)
	case 0xCD: // CALL
		addr := fetch16(c)
		push16(c, cpu.pc)
		cpu.pc = addr
	case 0xC4, 0xCC, 0xD4, 0xDC:
		addr := fetch16(c)
		if condition(cpu, (op >> 3) & 3) {
			push16(c, cpu.pc)
			cpu.pc = addr
		}
	case 0xC9: // RET
		cpu.pc = pop16(c)
		tick(c)
	case 0xD9: // RETI
		cpu.pc = pop16(c)
		tick(c)
		cpu.ime = true
	case 0xC0, 0xC8, 0xD0, 0xD8:
		tick(c)
		if condition(cpu, (op >> 3) & 3) {
			cpu.pc = pop16(c)
			tick(c)
		}
	case 0xC7, 0xCF, 0xD7, 0xDF, 0xE7, 0xEF, 0xF7, 0xFF: // RST
		push16(c, cpu.pc)
		cpu.pc = u16(op & 0x38)

	// --- stack ---
	case 0xC5: push16(c, get_bc(cpu))
	case 0xD5: push16(c, get_de(cpu))
	case 0xE5: push16(c, get_hl(cpu))
	case 0xF5: push16(c, u16(cpu.a) << 8 | u16(cpu.f))
	case 0xC1: set_bc(cpu, pop16(c))
	case 0xD1: set_de(cpu, pop16(c))
	case 0xE1: set_hl(cpu, pop16(c))
	case 0xF1:
		v := pop16(c)
		cpu.a = u8(v >> 8)
		cpu.f = u8(v) & 0xF0

	// --- high memory and misc loads ---
	case 0xE0: write(c, 0xFF00 | u16(fetch(c)), cpu.a)
	case 0xF0: cpu.a = read(c, 0xFF00 | u16(fetch(c)))
	case 0xE2: write(c, 0xFF00 | u16(cpu.c), cpu.a)
	case 0xF2: cpu.a = read(c, 0xFF00 | u16(cpu.c))
	case 0xEA: write(c, fetch16(c), cpu.a)
	case 0xFA: cpu.a = read(c, fetch16(c))
	case 0xE8: // ADD SP,e
		off := u16(i16(i8(fetch(c))))
		sp := cpu.sp
		cpu.sp = sp + off
		cpu.f = flags(false, false, (sp & 0xF) + (off & 0xF) > 0xF, (sp & 0xFF) + (off & 0xFF) > 0xFF)
		tick(c)
		tick(c)
	case 0xF8: // LD HL,SP+e
		off := u16(i16(i8(fetch(c))))
		sp := cpu.sp
		set_hl(cpu, sp + off)
		cpu.f = flags(false, false, (sp & 0xF) + (off & 0xF) > 0xF, (sp & 0xFF) + (off & 0xFF) > 0xFF)
		tick(c)
	case 0xF9: // LD SP,HL
		cpu.sp = get_hl(cpu)
		tick(c)
	case 0xF3: // DI
		cpu.ime = false
		cpu.ime_next = false
	case 0xFB: // EI
		cpu.ime_next = true
	case 0xCB:
		execute_cb(c, fetch(c))
	case:
		// $D3 $DB $DD $E3 $E4 $EB $EC $ED $F4 $FC $FD lock up the CPU.
		cpu.halted = true
		cpu.ime = false
		c.ie = 0
	}
}

@(private = "file")
execute_cb :: proc(c: ^Console, op: u8) {
	cpu := &c.cpu
	r := op & 7
	bit := (op >> 3) & 7
	switch op >> 6 {
	case 0:
		v := get_r(c, r)
		cy: u8
		res: u8
		switch bit {
		case 0: cy = v >> 7; res = v << 1 | cy                                       // RLC
		case 1: cy = v & 1; res = v >> 1 | cy << 7                                   // RRC
		case 2: cy = v >> 7; res = v << 1 | (cpu.f & FLAG_C != 0 ? 1 : 0)           // RL
		case 3: cy = v & 1; res = v >> 1 | (cpu.f & FLAG_C != 0 ? 0x80 : 0)         // RR
		case 4: cy = v >> 7; res = v << 1                                            // SLA
		case 5: cy = v & 1; res = (v >> 1) | (v & 0x80)                              // SRA
		case 6: cy = 0; res = v >> 4 | v << 4                                        // SWAP
		case 7: cy = v & 1; res = v >> 1                                             // SRL
		}
		set_r(c, r, res)
		cpu.f = flags(res == 0, false, false, cy != 0)
	case 1: // BIT
		v := get_r(c, r)
		cpu.f = (cpu.f & FLAG_C) | flags(v & (1 << bit) == 0, false, true, false)
	case 2: // RES
		set_r(c, r, get_r(c, r) & ~(u8(1) << bit))
	case 3: // SET
		set_r(c, r, get_r(c, r) | (u8(1) << bit))
	}
}
