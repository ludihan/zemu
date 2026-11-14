package sms

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

// Runs CP/M test programs (PRELIM, ZEXDOC, ZEXALL) on a flat 64 KiB memory
// with just enough BDOS to print. Point ZEMU_Z80_TESTS at a directory with
// prelim.com / zexdoc.com / zexall.com (e.g. from floooh/chips-test).

@(private = "file")
Cpm :: struct {
	mem: [0x10000]u8,
	out: strings.Builder,
}

@(private = "file")
cpm_read :: proc(user: rawptr, a: u16) -> u8 {return (^Cpm)(user).mem[a]}
@(private = "file")
cpm_write :: proc(user: rawptr, a: u16, v: u8) {(^Cpm)(user).mem[a] = v}
@(private = "file")
cpm_in :: proc(user: rawptr, p: u16) -> u8 {return 0xFF}
@(private = "file")
cpm_out :: proc(user: rawptr, p: u16, v: u8) {}

@(private = "file")
run_cpm :: proc(t: ^testing.T, path: string, max_steps: i64) -> (output: string, finished: bool) {
	prog, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		log.errorf("missing %s", path)
		return "", false
	}
	defer delete(prog)
	m := new(Cpm)
	defer free(m)
	m.out = strings.builder_make(context.temp_allocator)
	copy(m.mem[0x100:], prog)
	m.mem[0x0005] = 0xC9 // BDOS entry: RET (calls are intercepted below)
	m.mem[0x0000] = 0x76 // warm boot: HALT
	z: Z80
	z.bus = {user = m, read = cpm_read, write = cpm_write, input = cpm_in, output = cpm_out}
	z80_reset(&z)
	z.pc = 0x100
	z.sp = 0xF000
	for _ in 0 ..< max_steps {
		if z.pc == 0x0005 {
			switch z.c {
			case 2: strings.write_byte(&m.out, z.e)
			case 9:
				a := u16(z.d) << 8 | u16(z.e)
				for m.mem[a] != '$' {
					strings.write_byte(&m.out, m.mem[a])
					a += 1
				}
			}
		}
		if z.pc == 0 {
			return strings.to_string(m.out), true
		}
		z80_step(&z)
	}
	return strings.to_string(m.out), false
}

@(private = "file")
test_dir :: proc() -> (string, bool) {
	d := os.get_env("ZEMU_Z80_TESTS", context.temp_allocator)
	return d, d != ""
}

@(test)
z80_zexdoc :: proc(t: ^testing.T) {
	dir, ok := test_dir()
	if !ok {
		log.warn("ZEMU_Z80_TESTS not set")
		return
	}
	for name in ([]string{"zexdoc.com", "zexall.com"}) {
		path := fmt.tprintf("%s/%s", dir, name)
		if !testing.expectf(t, os.exists(path), "missing %s", path) {continue}
		out, done := run_cpm(t, path, 20_000_000_000)
		testing.expectf(t, done, "%s did not finish", name)
		testing.expectf(t, !strings.contains(out, "ERROR"), "%s reported errors:\n%s", name, out)
		testing.expectf(t, strings.contains(out, "Tests complete"), "%s output:\n%s", name, out)
	}
}
