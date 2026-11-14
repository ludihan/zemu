package gba

import "core:fmt"
import "core:log"
import "core:os"
import "core:testing"

// ZEMU_GBA_TESTS points at a checkout of https://github.com/jsmolka/gba-tests.
// Each ROM stores the number of the first failed test in r12 (0 = all
// passed) and then spins on a branch-to-self.
@(private = "file")
run_rom :: proc(t: ^testing.T, path: string) -> (result: u32, finished: bool) {
	rom, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		log.errorf("missing %s", path)
		return 0, false
	}
	defer delete(rom)
	c, load_err := create(rom)
	if load_err != .None {
		log.errorf("%s: %v", path, load_err)
		return 0, false
	}
	defer destroy(c)
	for _ in 0 ..< 120 {
		run_frame(c, {}, nil)
	}
	pc := c.cpu.pc
	idle: bool
	if c.cpu.cpsr & FLAG_T != 0 {
		idle = read16(c, pc) == 0xE7FE
	} else {
		idle = read32(c, pc) == 0xEAFF_FFFE
	}
	return c.cpu.r[12], idle
}

@(test)
jsmolka_suite :: proc(t: ^testing.T) {
	dir := os.get_env("ZEMU_GBA_TESTS", context.temp_allocator)
	if dir == "" {
		log.warn("ZEMU_GBA_TESTS not set")
		return
	}
	roms := []string {
		"arm/arm.gba",
		"thumb/thumb.gba",
		"memory/memory.gba",
		"bios/bios.gba",
		"nes/nes.gba",
		"save/sram.gba",
		"save/flash64.gba",
		"save/flash128.gba",
		"save/none.gba",
	}
	for r in roms {
		result, idle := run_rom(t, fmt.tprintf("%s/%s", dir, r))
		testing.expectf(t, idle && result == 0, "%s: finished=%v failed test %d", r, idle, result)
	}
}

// ZEMU_GBA_FUZZ points at a checkout of https://github.com/DenSinH/FuzzARM.
// Every ROM runs 10000 random instruction tests and prints "End of testing"
// in the top-left corner when all pass (it stops on the first failure).
@(test)
fuzzarm_suite :: proc(t: ^testing.T) {
	dir := os.get_env("ZEMU_GBA_FUZZ", context.temp_allocator)
	if dir == "" {
		log.warn("ZEMU_GBA_FUZZ not set")
		return
	}
	// FNV-1a of the first 8 lines once "End of testing" is shown.
	EXPECTED :: 0x1a65869d38aa5ebe
	roms := []string{"ARM_Any", "ARM_DataProcessing", "THUMB_Any", "THUMB_DataProcessing", "FuzzARM"}
	for r in roms {
		path := fmt.tprintf("%s/%s.gba", dir, r)
		rom, err := os.read_entire_file(path, context.allocator)
		if err != nil {
			log.errorf("missing %s", path)
			continue
		}
		c, _ := create(rom)
		delete(rom)
		for _ in 0 ..< 1500 {
			run_frame(c, {}, nil)
		}
		h: u64 = 0xcbf29ce484222325
		for px in c.ppu.framebuffer[:SCREEN_W * 8] {
			h = (h ~ u64(px)) * 0x100000001b3
		}
		testing.expectf(t, h == EXPECTED, "%s: top lines hash %x", r, h)
		destroy(c)
	}
}

// Drives the RTC's serial protocol the way games do and reads the date.
@(test)
rtc_datetime :: proc(t: ^testing.T) {
	r: Rtc
	rtc_detect(&r, {})
	r.present = true
	rtc_write(&r, 0x0800_00C8, 1)
	rtc_write(&r, 0x0800_00C6, 7)
	rtc_write(&r, 0x0800_00C4, 1)
	rtc_write(&r, 0x0800_00C4, 5)
	cmd: u8 = 0x65 // 0110 + datetime (010) + read
	for i := 7; i >= 0; i -= 1 {
		bit := u16((cmd >> uint(i)) & 1) << 1
		rtc_write(&r, 0x0800_00C4, 4 | bit)
		rtc_write(&r, 0x0800_00C4, 5 | bit)
	}
	rtc_write(&r, 0x0800_00C6, 5) // SIO becomes an input
	bytes: [7]u8
	for i in 0 ..< 7 {
		for b in 0 ..< 8 {
			rtc_write(&r, 0x0800_00C4, 4)
			rtc_write(&r, 0x0800_00C4, 5)
			v, _ := rtc_read(&r, 0x0800_00C4)
			bytes[i] |= u8((v >> 1) & 1) << uint(b)
		}
	}
	month := int(bytes[1] >> 4) * 10 + int(bytes[1] & 0xF)
	day := int(bytes[2] >> 4) * 10 + int(bytes[2] & 0xF)
	minute := int(bytes[5] >> 4) * 10 + int(bytes[5] & 0xF)
	testing.expectf(t, month >= 1 && month <= 12 && day >= 1 && day <= 31 && minute < 60, "bad date %v", bytes)
	testing.expectf(t, bytes == r.clock, "read %v, clock %v", bytes, r.clock)
}

// Loading a state must reproduce exactly the frames that followed it.
@(test)
save_state_round_trip :: proc(t: ^testing.T) {
	dir := os.get_env("ZEMU_GBA_TESTS", context.temp_allocator)
	if dir == "" {
		return
	}
	rom, err := os.read_entire_file(fmt.tprintf("%s/ppu/stripes.gba", dir), context.allocator)
	if err != nil {
		return
	}
	defer delete(rom)
	c, _ := create(rom)
	defer destroy(c)
	for _ in 0 ..< 30 {run_frame(c, {}, nil)}
	state := save_state(c)
	defer delete(state)
	for _ in 0 ..< 30 {run_frame(c, {}, nil)}
	want := c.ppu.framebuffer
	want_pc := c.cpu.pc
	testing.expect(t, load_state(c, state))
	for _ in 0 ..< 30 {run_frame(c, {}, nil)}
	testing.expect(t, c.ppu.framebuffer == want && c.cpu.pc == want_pc, "state replay diverged")
	testing.expect(t, !load_state(c, state[:len(state) - 1]), "truncated state accepted")
}
