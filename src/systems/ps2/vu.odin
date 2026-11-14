package ps2

// Vector unit 0 as seen from the EE (COP2). Only the register file and the
// transfer instructions exist so far; VU0 macro-mode arithmetic and VU1 come
// in a later milestone.

Vu :: struct {
	vf: [32]u128, // four f32 lanes each; vf0 is (0, 0, 0, 1)
	vi: [16]u32,
}

vu_reset :: proc(v: ^Vu) {
	v^ = {}
	v.vf[0] = u128(0x3F80_0000) << 96
}

cop2 :: proc(c: ^Console, op: u32) {
	cpu := &c.ee
	rt := (op >> 16) & 31
	rd := (op >> 11) & 31
	switch (op >> 21) & 31 {
	case 0x01: cpu.gpr[rt] = c.vu0.vf[rd] // QMFC2
	case 0x02: set32(cpu, rt, rd < 16 ? c.vu0.vi[rd] : 0) // CFC2
	case 0x05: // QMTC2
		if rd != 0 {c.vu0.vf[rd] = cpu.gpr[rt]}
	case 0x06: // CTC2
		if rd != 0 && rd < 16 {c.vu0.vi[rd] = u32(lo64(cpu.gpr[rt]))}
	case 0x08: // BC2F/BC2T and likely forms: VU0 is never busy here
		off := u32(i64(i16(u16(op))) << 2)
		switch rt & 3 {
		case 0: cpu.target, cpu.jump = cpu.pc + 4 + off, true
		case 1:
		case 2: cpu.target, cpu.jump = cpu.pc + 4 + off, true
		case 3: cpu.annul = true
		}
	case:
		// VU0 macro instructions: not emulated yet
	}
}
