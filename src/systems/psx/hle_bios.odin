package psx

import "core:strings"

// High-level BIOS for running PS-X EXEs without a BIOS image. When no BIOS
// is loaded, calls into the A0/B0/C0 function tables and exceptions taken
// at 0x80000080 are handled here, covering what homebrew SDKs (PSn00bSDK,
// PsyQ-style libraries) need: TTY output, critical sections, the
// interrupt hook (SetCustomExitFromException / ReturnFromException), events
// and a few library helpers.

Hle_Bios :: struct {
	custom_exit: u32,     // address of the hook's jmp_buf, 0 = none
	saved:       [32]u32, // CPU state at the last exception
	saved_hi:    u32,
	saved_lo:    u32,
	saved_epc:   u32,
	next_event:  u32,
	clear_pad:   bool,
	clear_rcnt:  bool,
	tty:         [8192]u8,
	tty_len:     int,
}

hle_reset :: proc(h: ^Hle_Bios) {
	tty, n := h.tty, h.tty_len
	h^ = {}
	h.tty, h.tty_len = tty, n
	h.clear_pad = true
	h.clear_rcnt = true
}

// Text the program printed through the BIOS.
tty_output :: proc(c: ^Console) -> string {
	return string(c.hle.tty[:c.hle.tty_len])
}

@(private = "file")
tty_put :: proc(c: ^Console, ch: u8) {
	h := &c.hle
	if h.tty_len < len(h.tty) {
		h.tty[h.tty_len] = ch
		h.tty_len += 1
	}
}

// Called before each instruction; handles the BIOS entry points.
// Returns true when it did something in place of the instruction.
hle_intercept :: proc(c: ^Console) -> bool {
	cpu := &c.cpu
	switch cpu.pc & 0x1FFF_FFFF {
	case 0xA0, 0xB0, 0xC0, 0x80:
		// A load still in its delay slot lands before the BIOS code would
		// run (its first instruction completes it); commit it now so it is
		// neither lost nor applied after our register changes.
		if cpu.load_reg != 0 {
			cpu.r[cpu.load_reg] = cpu.load_val
			cpu.load_reg = 0
		}
	}
	switch cpu.pc & 0x1FFF_FFFF {
	case 0xA0: table_call(c, 0xA0)
	case 0xB0: table_call(c, 0xB0)
	case 0xC0: table_call(c, 0xC0)
	case 0x80: exception_handler(c)
	case: return false
	}
	return true
}

@(private = "file")
jump :: proc(cpu: ^Cpu, addr: u32) {
	cpu.pc = addr
	cpu.next_pc = addr + 4
	cpu.branch = false
	cpu.in_delay = false
}

// RFE: pops the KU/IE mode stack.
@(private = "file")
rfe :: #force_inline proc(cpu: ^Cpu) {
	cpu.sr = (cpu.sr & ~u32(0x0F)) | ((cpu.sr >> 2) & 0x0F)
}

@(private = "file")
exception_handler :: proc(c: ^Console) {
	cpu := &c.cpu
	h := &c.hle
	#partial switch Exception((cpu.cause >> 2) & 0x1F) {
	case .Syscall:
		// The SR change is made in exception mode, before RFE: bit 2 (the
		// interrupt enable saved by the exception) becomes the live one.
		switch cpu.r[4] {
		case 1: // EnterCriticalSection: returns whether interrupts were on
			cpu.r[2] = cpu.sr & 0x404 == 0x404 ? 1 : 0
			cpu.sr &= ~u32(0x404)
		case 2: // ExitCriticalSection
			cpu.sr |= 0x404
		}
		rfe(cpu)
		jump(cpu, cpu.epc + 4)
	case .Interrupt:
		h.saved = cpu.r
		h.saved_hi, h.saved_lo = cpu.hi, cpu.lo
		h.saved_epc = cpu.epc
		if h.clear_rcnt {
			c.i_stat &= ~u32(0x70) // the default handler acknowledges the timers
		}
		if h.custom_exit != 0 {
			// Resume the hook as if its setjmp returned 1, still in exception
			// mode with interrupts off; it ends with ReturnFromException.
			b := h.custom_exit
			ra := read32_phys(c, b)
			cpu.r[29] = read32_phys(c, b + 4)
			cpu.r[30] = read32_phys(c, b + 8)
			for i in u32(0) ..< 8 {
				cpu.r[16 + i] = read32_phys(c, b + 12 + i * 4)
			}
			cpu.r[28] = read32_phys(c, b + 44)
			cpu.r[2] = 1
			jump(cpu, ra)
		} else {
			return_from_exception(c)
		}
	case:
		// Breaks and faults: skip the instruction rather than hang.
		rfe(cpu)
		jump(cpu, cpu.epc + 4)
	}
}

@(private = "file")
return_from_exception :: proc(c: ^Console) {
	cpu := &c.cpu
	h := &c.hle
	cpu.r = h.saved
	cpu.r[0] = 0
	cpu.hi, cpu.lo = h.saved_hi, h.saved_lo
	rfe(cpu)
	jump(cpu, h.saved_epc)
}

@(private = "file")
read32_phys :: proc(c: ^Console, addr: u32) -> u32 {
	a := int(addr & 0x1F_FFFF) & (RAM_SIZE - 4)
	return u32(c.ram[a]) | u32(c.ram[a + 1]) << 8 | u32(c.ram[a + 2]) << 16 | u32(c.ram[a + 3]) << 24
}

@(private = "file")
read8_phys :: #force_inline proc(c: ^Console, addr: u32) -> u8 {
	return c.ram[int(addr & 0x1F_FFFF) & (RAM_SIZE - 1)]
}

@(private = "file")
write8_phys :: #force_inline proc(c: ^Console, addr: u32, v: u8) {
	c.ram[int(addr & 0x1F_FFFF) & (RAM_SIZE - 1)] = v
}

@(private = "file")
read_cstring :: proc(c: ^Console, addr: u32, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for i in u32(0) ..< 4096 {
		ch := read8_phys(c, addr + i)
		if ch == 0 {break}
		strings.write_byte(&b, ch)
	}
	return strings.to_string(b)
}

// printf with the argument list a1, a2, a3, then the stack (o32 ABI).
@(private = "file")
bios_printf :: proc(c: ^Console) {
	cpu := &c.cpu
	format := read_cstring(c, cpu.r[4])
	arg_index := 1
	next_arg :: proc(c: ^Console, i: ^int) -> u32 {
		n := i^
		i^ += 1
		if n < 4 {
			return c.cpu.r[4 + n]
		}
		return read32_phys(c, c.cpu.r[29] + u32(n) * 4)
	}
	out := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(format); i += 1 {
		ch := format[i]
		if ch != '%' || i + 1 >= len(format) {
			strings.write_byte(&out, ch)
			continue
		}
		i += 1
		zero := false
		left := false
		width := 0
		for i < len(format) && (format[i] == '0' || format[i] == '-') {
			if format[i] == '0' {zero = true} else {left = true}
			i += 1
		}
		for i < len(format) && format[i] >= '0' && format[i] <= '9' {
			width = width * 10 + int(format[i] - '0')
			i += 1
		}
		for i < len(format) && (format[i] == 'l' || format[i] == 'h') {
			i += 1
		}
		if i >= len(format) {break}
		piece: string
		switch format[i] {
		case 'd', 'i':
			v := i32(next_arg(c, &arg_index))
			piece = fmt_int(i64(v), 10, false)
		case 'u': piece = fmt_int(i64(next_arg(c, &arg_index)), 10, false)
		case 'x': piece = fmt_int(i64(next_arg(c, &arg_index)), 16, false)
		case 'X': piece = fmt_int(i64(next_arg(c, &arg_index)), 16, true)
		case 'p':
			piece = fmt_int(i64(next_arg(c, &arg_index)), 16, false)
			width = max(width, 8)
			zero = true
		case 'c': piece = strings.clone(string([]u8{u8(next_arg(c, &arg_index))}), context.temp_allocator)
		case 's': piece = read_cstring(c, next_arg(c, &arg_index))
		case '%': piece = "%"
		case: piece = format[i:i + 1]
		}
		pad := width - len(piece)
		if !left {
			for _ in 0 ..< pad {strings.write_byte(&out, zero ? '0' : ' ')}
		}
		strings.write_string(&out, piece)
		if left {
			for _ in 0 ..< pad {strings.write_byte(&out, ' ')}
		}
	}
	s := strings.to_string(out)
	for ch in transmute([]u8)s {
		tty_put(c, ch)
	}
	cpu.r[2] = u32(len(s))
}

@(private = "file")
fmt_int :: proc(v: i64, base: u64, upper: bool) -> string {
	digits := upper ? "0123456789ABCDEF" : "0123456789abcdef"
	buf: [24]u8
	n := len(buf)
	neg := v < 0 && base == 10
	u := u64(neg ? -v : v)
	if base == 16 {u &= 0xFFFF_FFFF}
	for {
		n -= 1
		buf[n] = digits[u % base]
		u /= base
		if u == 0 {break}
	}
	if neg {
		n -= 1
		buf[n] = '-'
	}
	return strings.clone(string(buf[n:]), context.temp_allocator)
}

@(private = "file")
table_call :: proc(c: ^Console, table: u32) {
	cpu := &c.cpu
	h := &c.hle
	fn := cpu.r[9]
	a0, a1, a2 := cpu.r[4], cpu.r[5], cpu.r[6]
	v0: u32 = 0
	switch table {
	case 0xA0:
		switch fn {
		case 0x00, 0x01, 0x02, 0x03, 0x04: v0 = 0xFFFF_FFFF // file I/O: no devices
		case 0x17: // strcmp
			x, y := read_cstring(c, a0), read_cstring(c, a1)
			v0 = u32(i32(strings.compare(x, y)))
		case 0x1B: v0 = u32(len(read_cstring(c, a0))) // strlen
		case 0x2A: // memcpy
			for i in u32(0) ..< a2 {write8_phys(c, a0 + i, read8_phys(c, a1 + i))}
			v0 = a0
		case 0x2B: // memset
			for i in u32(0) ..< a2 {write8_phys(c, a0 + i, u8(a1))}
			v0 = a0
		case 0x3C: tty_put(c, u8(a0)); v0 = a0 // putchar
		case 0x3E: // puts
			for ch in transmute([]u8)read_cstring(c, a0) {tty_put(c, ch)}
			tty_put(c, '\n')
		case 0x3F: bios_printf(c); return_to(cpu); return
		case 0x44, 0x72, 0x70, 0x71: // FlushCache, _96_remove, _bu_init, _96_init
		}
	case 0xB0:
		switch fn {
		case 0x07: v0 = 1 // DeliverEvent
		case 0x08: // OpenEvent
			h.next_event += 1
			v0 = 0xF100_0000 | h.next_event
		case 0x09, 0x0A, 0x0C, 0x0D: v0 = 1 // CloseEvent, WaitEvent, EnableEvent, DisableEvent
		case 0x0B: v0 = 0 // TestEvent: nothing has happened
		case 0x12, 0x13, 0x14: v0 = 1 // InitPAD, StartPAD, StopPAD
		case 0x17: return_from_exception(c); return
		case 0x18: h.custom_exit = 0 // ResetEntryInt
		case 0x19: h.custom_exit = a0 // HookEntryInt / SetCustomExitFromException
		case 0x3D: tty_put(c, u8(a0)); v0 = a0 // putchar
		case 0x3F: // puts
			for ch in transmute([]u8)read_cstring(c, a0) {tty_put(c, ch)}
			tty_put(c, '\n')
		case 0x5B: // ChangeClearPad
			h.clear_pad = a0 != 0
		}
	case 0xC0:
		switch fn {
		case 0x0A: // ChangeClearRCnt(timer, flag): returns the old flag
			v0 = h.clear_rcnt ? 1 : 0
			h.clear_rcnt = a1 != 0
		}
	}
	cpu.r[2] = v0
	return_to(cpu)
}

@(private = "file")
return_to :: #force_inline proc(cpu: ^Cpu) {
	jump(cpu, cpu.r[31])
}
