package ps2

import "core:testing"

// testdata/build.sh compiles cpu.c for the EE with clang and natively for
// the host; the emulated run must print exactly what the native one did.
@(test)
ee_runs_compiled_c :: proc(t: ^testing.T) {
	elf := #load("testdata/cpu.elf")
	expected := string(#load("testdata/cpu.expected"))
	c, err := create_from_elf(elf)
	testing.expect_value(t, err, nil)
	if c == nil {return}
	defer destroy(c)
	stopped := run_instructions(c, 5_000_000)
	testing.expect(t, stopped, "program did not finish")
	testing.expect_value(t, debug_output(c), expected)
}

// Executes one hand-encoded instruction with the given register contents.
@(private = "file")
exec :: proc(c: ^Console, op: u32) {
	write32(c, 0x0010_0000, op)
	c.ee.pc = 0x0010_0000
	c.ee.npc = 0x0010_0004
	ee_step(c)
}

@(private = "file")
mmi_op :: proc(rs, rt, rd: u32, sub: u32, funct: u32) -> u32 {
	return 0x1C << 26 | rs << 21 | rt << 16 | rd << 11 | sub << 6 | funct
}

@(test)
mmi_instructions :: proc(t: ^testing.T) {
	elf := #load("testdata/cpu.elf")
	c, _ := create_from_elf(elf)
	if c == nil {return}
	defer destroy(c)
	cpu := &c.ee
	a := make128(0x0004_0003_0002_0001, 0x0008_0007_0006_0005)
	b := make128(0xFFFF_7FFF_0010_0020, 0x8000_0001_0002_0003)

	cpu.gpr[1], cpu.gpr[2] = a, b
	exec(c, mmi_op(1, 2, 3, 0x04, 0x08)) // PADDH
	testing.expect_value(t, cpu.gpr[3], make128(0x0003_8002_0012_0021, 0x8008_0008_0008_0008))

	exec(c, mmi_op(1, 2, 3, 0x14, 0x08)) // PADDSH: saturates
	testing.expect_value(t, cpu.gpr[3], make128(0x0003_7FFF_0012_0021, 0x8008_0008_0008_0008))

	exec(c, mmi_op(1, 2, 3, 0x12, 0x08)) // PEXTLW
	testing.expect_value(t, cpu.gpr[3], make128(0x0002_0001_0010_0020, 0x0004_0003_FFFF_7FFF))

	exec(c, mmi_op(1, 2, 3, 0x0E, 0x09)) // PCPYLD
	testing.expect_value(t, cpu.gpr[3], make128(lo64(b), lo64(a)))

	exec(c, mmi_op(1, 2, 3, 0x0E, 0x29)) // PCPYUD
	testing.expect_value(t, cpu.gpr[3], make128(hi64(a), hi64(b)))

	exec(c, mmi_op(1, 2, 3, 0x12, 0x29)) // POR
	testing.expect_value(t, cpu.gpr[3], a | b)

	exec(c, mmi_op(0, 2, 3, 0x1B, 0x29)) // PCPYH
	testing.expect_value(t, cpu.gpr[3], make128(0x0020_0020_0020_0020, 0x0003_0003_0003_0003))

	// PMULTW: two signed 32x32 -> 64 products into rd, LO and HI
	cpu.gpr[1] = make128(0xFFFF_FFFE, 0x0001_0000)
	cpu.gpr[2] = make128(0x0000_0003, 0x0001_0000)
	exec(c, mmi_op(1, 2, 3, 0x0C, 0x09))
	testing.expect_value(t, cpu.gpr[3], make128(0xFFFF_FFFF_FFFF_FFFA, 0x0000_0001_0000_0000))

	// QFSRV with SA set by MTSAB to 4 bytes
	cpu.gpr[4] = 4
	exec(c, 0x01 << 26 | 4 << 21 | 0x18 << 16) // MTSAB r4, 0
	cpu.gpr[1] = make128(0x1111_1111_2222_2222, 0x3333_3333_4444_4444)
	cpu.gpr[2] = make128(0x5555_5555_6666_6666, 0x7777_7777_8888_8888)
	exec(c, mmi_op(1, 2, 3, 0x1B, 0x28))
	testing.expect_value(t, cpu.gpr[3], make128(0x8888_8888_5555_5555, 0x2222_2222_7777_7777))

	// MULT1 writes the upper halves of LO/HI
	cpu.gpr[1] = make128(7, 0)
	cpu.gpr[2] = make128(0xFFFF_FFFF, 0)
	exec(c, mmi_op(1, 2, 3, 0, 0x18))
	testing.expect_value(t, hi64(cpu.lo), 0xFFFF_FFFF_FFFF_FFF9)
	testing.expect_value(t, hi64(cpu.hi), 0xFFFF_FFFF_FFFF_FFFF)
}

@(test)
fpu_is_not_ieee :: proc(t: ^testing.T) {
	elf := #load("testdata/cpu.elf")
	c, _ := create_from_elf(elf)
	if c == nil {return}
	defer destroy(c)
	f := &c.ee.fpu
	f.r[1] = 0x3F80_0000 // 1.0
	f.r[2] = 0          // 0.0
	exec(c, 0x11 << 26 | 0x10 << 21 | 2 << 16 | 1 << 11 | 3 << 6 | 0x03) // DIV.S f3, f1, f2
	testing.expect_value(t, f.r[3], 0x7F7F_FFFF) // +max, not +Inf
	f.r[1] = 0x7F7F_FFFF
	exec(c, 0x11 << 26 | 0x10 << 21 | 1 << 16 | 1 << 11 | 3 << 6 | 0x00) // ADD.S f3, f1, f1
	testing.expect_value(t, f.r[3], 0x7F7F_FFFF) // overflow clamps
	f.r[1] = 0x4F80_0000 // 2^32
	exec(c, 0x11 << 26 | 0x10 << 21 | 0 << 16 | 1 << 11 | 3 << 6 | 0x24) // CVT.W.S
	testing.expect_value(t, f.r[3], 0x7FFF_FFFF)
}

