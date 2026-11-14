package main

import "core:fmt"
import "core:os"
import "core:testing"

import "emu"
import "systems/nes"

@(test)
rewind_restores_exact_earlier_states :: proc(t: ^testing.T) {
	// A tiny program that keeps changing RAM: INC $00,X / INX / JMP loop.
	rom := make([]u8, 16 + 0x4000 + 0x2000)
	defer delete(rom)
	copy(rom, "NES\x1A")
	rom[4] = 1
	rom[5] = 1
	prg := rom[16:][:0x4000]
	copy(prg, []u8{0xF6, 0x00, 0xE8, 0x4C, 0x00, 0xC0})
	prg[0x3FFC] = 0x00 // reset vector -> $C000
	prg[0x3FFD] = 0xC0
	c, err := nes.create(rom)
	if !testing.expect_value(t, err, emu.Load_Error.None) {return}
	defer nes.destroy(c)
	m: Machine = c

	r := Rewind{interval = 1}
	defer rewind_reset(&r)
	history: [dynamic][]u8
	defer {
		for h in history {delete(h)}
		delete(history)
	}
	for _ in 0 ..< 20 {
		machine_run_frame(m, {}, nil)
		rewind_capture(&r, m)
		append(&history, machine_save_state(m))
	}
	full := len(history[0])
	testing.expectf(t, r.bytes < full * 19 / 4, "deltas should be much smaller than states (%d vs %d)", r.bytes, full * 19)

	// Each step back lands exactly on the previous snapshot.
	for i := len(history) - 2; i >= 0; i -= 1 {
		more := rewind_step(&r, m)
		now := machine_save_state(m)
		same := len(now) == len(history[i]) && string(now) == string(history[i])
		delete(now)
		testing.expectf(t, same, "state %d differs after rewinding", i)
		if i > 0 {testing.expect(t, more)}
	}
	testing.expect(t, !rewind_step(&r, m), "history should be exhausted")
}

// Rewind cost on real software, when the test ROMs are available.
@(test)
rewind_delta_sizes_are_small :: proc(t: ^testing.T) {
	path := os.get_env("ZEMU_SNES_TESTS", context.temp_allocator)
	if path == "" {
		return
	}
	m, err := machine_create(.SNES, fmt.tprintf("%s/PPU/Mode7/RotZoom/RotZoom.sfc", path), nil)
	if !testing.expect_value(t, err, emu.Load_Error.None) {return}
	defer machine_destroy(&m)
	r := Rewind{interval = 2}
	defer rewind_reset(&r)
	for _ in 0 ..< 240 {
		machine_run_frame(m, {}, nil)
		rewind_capture(&r, m)
	}
	per_snapshot := r.bytes / max(len(r.deltas), 1)
	seconds := REWIND_BUDGET / max(per_snapshot, 1) * r.interval / 60
	testing.expectf(t, seconds >= 60, "budget only holds %d s (%d bytes per snapshot)", seconds, per_snapshot)
}
