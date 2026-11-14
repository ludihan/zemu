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
