package nes

import "core:fmt"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"

import "../../emu"

// Test ROMs are not redistributed with zemu. Point ZEMU_NES_TESTS at a
// checkout of https://github.com/christopherpow/nes-test-roms to run these.
@(private = "file")
test_rom_dir :: proc() -> (string, bool) {
	dir := os.get_env("ZEMU_NES_TESTS", context.temp_allocator)
	return dir, dir != ""
}

@(private = "file")
hex :: proc(s: string) -> int {
	v, _ := strconv.parse_int(s, 16)
	return v
}

@(test)
nestest_matches_reference_log :: proc(t: ^testing.T) {
	dir, ok := test_rom_dir()
	if !ok {
		log.warn("ZEMU_NES_TESTS not set")
		return
	}
	rom, rom_err := os.read_entire_file(fmt.tprintf("%s/other/nestest.nes", dir), context.allocator)
	if !testing.expect(t, rom_err == nil, "nestest.nes missing") {return}
	defer delete(rom)
	ref_log, log_err := os.read_entire_file(fmt.tprintf("%s/other/nestest.log", dir), context.allocator)
	if !testing.expect(t, log_err == nil, "nestest.log missing") {return}
	defer delete(ref_log)

	c, err := create(rom)
	if !testing.expect_value(t, err, emu.Load_Error.None) {return}
	defer destroy(c)
	c.cpu.pc = 0xC000 // automated mode

	lines := strings.split_lines(string(ref_log), context.temp_allocator)
	checked := 0
	for line in lines {
		if len(line) < 80 {continue}
		want_pc := hex(line[0:4])
		a_at := strings.index(line, "A:")
		cyc_at := strings.index(line, "CYC:")
		if a_at < 0 || cyc_at < 0 {continue}
		regs := line[a_at:]
		want_a := hex(regs[2:4])
		want_x := hex(regs[7:9])
		want_y := hex(regs[12:14])
		want_p := hex(regs[17:19])
		want_s := hex(regs[23:25])
		want_cyc, _ := strconv.parse_int(strings.trim_space(line[cyc_at + 4:]), 10)

		got_p := int(transmute(u8)c.cpu.p) | 0x20
		if int(c.cpu.pc) != want_pc || int(c.cpu.a) != want_a || int(c.cpu.x) != want_x ||
		   int(c.cpu.y) != want_y || got_p != want_p || int(c.cpu.s) != want_s ||
		   int(c.cpu.cycles) != want_cyc {
			log.errorf("mismatch after %d instructions\n want: %s\n got:  PC:%04X A:%02X X:%02X Y:%02X P:%02X SP:%02X CYC:%d",
				checked, line, c.cpu.pc, c.cpu.a, c.cpu.x, c.cpu.y, got_p, c.cpu.s, c.cpu.cycles)
			return
		}
		cpu_step(c)
		checked += 1
	}
	testing.expect(t, checked > 8000, "log too short")
	// $02/$03 hold error codes for official/unofficial opcodes.
	testing.expect_value(t, c.ram[2], 0)
	testing.expect_value(t, c.ram[3], 0)
}

// Runs a blargg-style test ROM that reports through $6000 and returns its text.
@(private = "file")
run_blargg :: proc(t: ^testing.T, path: string, max_frames := 3000, offset: u64 = 1) -> (status: u8, text: string) {
	rom, rom_err := os.read_entire_file(path, context.allocator)
	if rom_err != nil {
		log.errorf("cannot read %s", path)
		return 0xFF, ""
	}
	defer delete(rom)
	c, err := create(rom)
	if err != .None {
		log.errorf("load failed: %v", err)
		return 0xFF, ""
	}
	defer destroy(c)
	c.ppu_offset = offset
	started := false
	reset_at := -1
	armed := true // one reset per $81 request: the byte stays $81 until the ROM restarts
	for frame in 0 ..< max_frames {
		run_frame(c, {}, nil)
		ram := c.cart.prg_ram[:]
		signature_ok := ram[1] == 0xDE && ram[2] == 0xB0 && ram[3] == 0x61
		if !signature_ok {continue}
		switch ram[0] {
		case 0x81:
			if reset_at < 0 && armed {
				reset_at = frame + 10
				armed = false
			}
		case 0x80:
			started = true
			armed = true
		case:
			if started {
				end := 4
				for end < len(ram) && ram[end] != 0 {end += 1}
				return ram[0], strings.clone(string(ram[4:end]), context.temp_allocator)
			}
		}
		if reset_at >= 0 && frame == reset_at {
			reset(c)
			reset_at = -1
		}
	}
	return 0xFE, "timeout"
}

@(test)
blargg_suites :: proc(t: ^testing.T) {
	dir, ok := test_rom_dir()
	if !ok {
		log.warn("ZEMU_NES_TESTS not set")
		return
	}
	roms := []string {
		"instr_test-v5/all_instrs.nes",
		"instr_misc/instr_misc.nes",
		"instr_timing/instr_timing.nes",
		"cpu_dummy_writes/cpu_dummy_writes_oam.nes",
		"cpu_dummy_writes/cpu_dummy_writes_ppumem.nes",
		"cpu_interrupts_v2/rom_singles/1-cli_latency.nes",
		"apu_test/rom_singles/1-len_ctr.nes",
		"apu_test/rom_singles/2-len_table.nes",
		"apu_test/rom_singles/3-irq_flag.nes",
		"apu_test/rom_singles/4-jitter.nes",
		"apu_test/rom_singles/5-len_timing.nes",
		"apu_test/rom_singles/6-irq_flag_timing.nes",
		"apu_test/rom_singles/7-dmc_basics.nes",
		"apu_test/rom_singles/8-dmc_rates.nes",
		"cpu_interrupts_v2/rom_singles/2-nmi_and_brk.nes",
		"cpu_interrupts_v2/rom_singles/3-nmi_and_irq.nes",
		"cpu_interrupts_v2/rom_singles/4-irq_and_dma.nes",
		"cpu_interrupts_v2/rom_singles/5-branch_delays_irq.nes",
		"cpu_reset/registers.nes",
		"cpu_reset/ram_after_reset.nes",
		"cpu_exec_space/test_cpu_exec_space_ppuio.nes",
		"cpu_exec_space/test_cpu_exec_space_apu.nes",
		"apu_reset/4015_cleared.nes",
		"apu_reset/4017_timing.nes",
		"apu_reset/4017_written.nes",
		"apu_reset/irq_flag_cleared.nes",
		"apu_reset/len_ctrs_enabled.nes",
		"apu_reset/works_immediately.nes",
		"ppu_vbl_nmi/rom_singles/01-vbl_basics.nes",
		"ppu_vbl_nmi/rom_singles/02-vbl_set_time.nes",
		"ppu_vbl_nmi/rom_singles/03-vbl_clear_time.nes",
		"ppu_vbl_nmi/rom_singles/04-nmi_control.nes",
		"ppu_vbl_nmi/rom_singles/05-nmi_timing.nes",
		"ppu_vbl_nmi/rom_singles/06-suppression.nes",
		"ppu_vbl_nmi/rom_singles/07-nmi_on_timing.nes",
		"ppu_vbl_nmi/rom_singles/08-nmi_off_timing.nes",
		"ppu_vbl_nmi/rom_singles/09-even_odd_frames.nes",
		"ppu_vbl_nmi/rom_singles/10-even_odd_timing.nes",
		"ppu_open_bus/ppu_open_bus.nes",
		"oam_stress/oam_stress.nes",
		"oam_read/oam_read.nes",
		"mmc3_test_2/rom_singles/1-clocking.nes",
		"mmc3_test_2/rom_singles/2-details.nes",
		"mmc3_test_2/rom_singles/3-A12_clocking.nes",
		"mmc3_test_2/rom_singles/4-scanline_timing.nes",
		"mmc3_test_2/rom_singles/5-MMC3.nes",
	}
	for r in roms {
		status, text := run_blargg(t, fmt.tprintf("%s/%s", dir, r))
		if status != 0 {
			log.errorf("%s: status %d: %s", r, status, text)
		}
	}
}

@(private = "file")
frame_hash :: proc(c: ^Console) -> u64 {
	h: u64 = 0xcbf29ce484222325
	for p in c.ppu.framebuffer {
		h = (h ~ u64(p)) * 0x100000001b3
	}
	return h
}

@(test)
save_state_round_trip_is_deterministic :: proc(t: ^testing.T) {
	dir, ok := test_rom_dir()
	if !ok {
		log.warn("ZEMU_NES_TESTS not set")
		return
	}
	rom, err := os.read_entire_file(fmt.tprintf("%s/spritecans-2011/spritecans.nes", dir), context.allocator)
	if !testing.expect(t, err == nil) {return}
	defer delete(rom)
	c, _ := create(rom)
	defer destroy(c)
	for _ in 0 ..< 120 {run_frame(c, {}, nil)}
	state := save_state(c)
	defer delete(state)
	for _ in 0 ..< 90 {run_frame(c, {}, nil)}
	want := frame_hash(c)

	testing.expect(t, load_state(c, state), "state should load")
	for _ in 0 ..< 90 {run_frame(c, {}, nil)}
	testing.expect_value(t, frame_hash(c), want)

	// Truncated or altered states are refused and leave the console alone.
	testing.expect(t, !load_state(c, state[:len(state) - 1]))
	bad := make([]u8, len(state))
	defer delete(bad)
	copy(bad, state)
	bad[9] ~= 0xFF // fingerprint byte
	testing.expect(t, !load_state(c, bad))
	testing.expect(t, !load_state(c, nil))
}

// Builds an iNES image whose every 8 KiB PRG bank and 1 KiB CHR bank starts
// with its own bank number, so mappings can be checked by reading memory.
@(private = "file")
synthetic_rom :: proc(mapper: int, prg_16k, chr_8k: int) -> []u8 {
	size := 16 + prg_16k * 0x4000 + chr_8k * 0x2000
	rom := make([]u8, size)
	copy(rom, "NES\x1A")
	rom[4] = u8(prg_16k)
	rom[5] = u8(chr_8k)
	rom[6] = u8(mapper & 0x0F) << 4
	rom[7] = u8(mapper & 0xF0)
	for b in 0 ..< prg_16k * 2 {
		rom[16 + b * 0x2000] = u8(b)
	}
	chr := 16 + prg_16k * 0x4000
	for b in 0 ..< chr_8k * 8 {
		rom[chr + b * 0x400] = u8(b)
	}
	return rom
}

@(private = "file")
prg_bank_at :: proc(c: ^Console, addr: u16) -> u8 {
	return cart_cpu_read(&c.cart, addr, 0)
}

@(private = "file")
chr_bank_at :: proc(c: ^Console, addr: u16) -> u8 {
	return cart_chr_read(&c.cart, addr)
}

@(test)
vrc4_banking_and_irq :: proc(t: ^testing.T) {
	rom := synthetic_rom(23, 8, 16)
	defer delete(rom)
	c, err := create(rom)
	if !testing.expect_value(t, err, emu.Load_Error.None) {return}
	defer destroy(c)
	cart := &c.cart
	cart_cpu_write(cart, 0x8000, 5, 0) // PRG 0
	cart_cpu_write(cart, 0xA000, 7, 0) // PRG 1
	testing.expect_value(t, prg_bank_at(c, 0x8000), 5)
	testing.expect_value(t, prg_bank_at(c, 0xA000), 7)
	testing.expect_value(t, prg_bank_at(c, 0xC000), 14) // second to last
	testing.expect_value(t, prg_bank_at(c, 0xE000), 15)
	cart_cpu_write(cart, 0x9002, 0x02, 0) // swap mode
	testing.expect_value(t, prg_bank_at(c, 0x8000), 14)
	testing.expect_value(t, prg_bank_at(c, 0xC000), 5)
	// CHR bank 3 = 0x2A, written as two nibbles (mapper 23 uses A0/A1)
	cart_cpu_write(cart, 0xC002, 0x0A, 0)
	cart_cpu_write(cart, 0xC003, 0x02, 0)
	testing.expect_value(t, chr_bank_at(c, 0x0C00), 0x2A)
	// IRQ in cycle mode fires after (256 - latch) CPU cycles
	cart_cpu_write(cart, 0xF000, 0x0C, 0)
	cart_cpu_write(cart, 0xF001, 0x0F, 0) // latch = 0xFC
	cart_cpu_write(cart, 0xF002, 0x06, 0) // enable, cycle mode
	for _ in 0 ..< 3 {cart_cpu_clock(cart)}
	testing.expect(t, !cart.irq)
	cart_cpu_clock(cart)
	testing.expect(t, cart.irq)
	cart_cpu_write(cart, 0xF003, 0, 0)
	testing.expect(t, !cart.irq)
}

@(test)
fme7_banking_and_irq :: proc(t: ^testing.T) {
	rom := synthetic_rom(69, 8, 16)
	defer delete(rom)
	c, err := create(rom)
	if !testing.expect_value(t, err, emu.Load_Error.None) {return}
	defer destroy(c)
	cart := &c.cart
	write :: proc(cart: ^Cartridge, cmd, v: u8) {
		cart_cpu_write(cart, 0x8000, cmd, 0)
		cart_cpu_write(cart, 0xA000, v, 0)
	}
	write(cart, 0x9, 3)
	write(cart, 0xB, 9)
	write(cart, 0x5, 0x33)
	write(cart, 0x8, 4) // ROM bank 4 at $6000
	testing.expect_value(t, prg_bank_at(c, 0x8000), 3)
	testing.expect_value(t, prg_bank_at(c, 0xC000), 9)
	testing.expect_value(t, prg_bank_at(c, 0xE000), 15)
	testing.expect_value(t, prg_bank_at(c, 0x6000), 4)
	testing.expect_value(t, chr_bank_at(c, 0x1400), 0x33)
	write(cart, 0xE, 2)
	write(cart, 0xF, 0)
	write(cart, 0xD, 0x81)
	for _ in 0 ..< 2 {cart_cpu_clock(cart)}
	testing.expect(t, !cart.irq)
	cart_cpu_clock(cart) // 2 -> 1 -> 0 -> 0xFFFF fires
	testing.expect(t, cart.irq)
}

@(test)
vrc6_audio_produces_output :: proc(t: ^testing.T) {
	rom := synthetic_rom(24, 8, 16)
	defer delete(rom)
	c, _ := create(rom)
	defer destroy(c)
	cart := &c.cart
	cart_cpu_write(cart, 0x9000, 0x7F, 0) // pulse 1: duty 7, volume 15
	cart_cpu_write(cart, 0x9001, 0x40, 0)
	cart_cpu_write(cart, 0x9002, 0x80, 0) // enable
	high := 0
	for _ in 0 ..< 2000 {
		cart_cpu_clock(cart)
		if vrc6_output(&cart.vrc6) > 0 {high += 1}
	}
	testing.expect(t, high > 600 && high < 1400, "pulse should be on about half the time")
}

@(test)
pal_apu_suite :: proc(t: ^testing.T) {
	dir, ok := test_rom_dir()
	if !ok {
		log.warn("ZEMU_NES_TESTS not set")
		return
	}
	roms := []string {
		"01.len_ctr.nes", "02.len_table.nes", "03.irq_flag.nes", "04.clock_jitter.nes",
		"05.len_timing_mode0.nes", "06.len_timing_mode1.nes", "07.irq_flag_timing.nes",
		"08.irq_timing.nes", "10.len_halt_timing.nes", "11.len_reload_timing.nes",
	}
	for r in roms {
		rom, err := os.read_entire_file(fmt.tprintf("%s/pal_apu_tests/%s", dir, r), context.allocator)
		if !testing.expectf(t, err == nil, "missing %s", r) {continue}
		c, _ := create(rom, pal = true)
		delete(rom)
		// These older tests leave their result code in $F8 (1 = passed).
		for _ in 0 ..< 900 {
			run_frame(c, {}, nil)
		}
		testing.expectf(t, c.ram[0xF8] == 1, "%s: result %d", r, c.ram[0xF8])
		destroy(c)
	}
}
