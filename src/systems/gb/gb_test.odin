package gb

import "core:fmt"
import "core:image"
import "core:image/png"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

import "../../emu"

_ :: png

// ZEMU_GB_TESTS points at a directory containing checkouts of
// https://github.com/retrio/gb-test-roms (as gb-test-roms/) and the
// dmg-acid2 / cgb-acid2 release ROMs with their reference images.
@(private = "file")
test_dir :: proc() -> (string, bool) {
	dir := os.get_env("ZEMU_GB_TESTS", context.temp_allocator)
	return dir, dir != ""
}

@(private = "file")
load :: proc(path: string, model := Model.Auto) -> (^Console, bool) {
	rom, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		log.errorf("missing %s", path)
		return nil, false
	}
	defer delete(rom)
	c, load_err := create(rom, model)
	if load_err != .None {
		log.errorf("%s: %v", path, load_err)
		return nil, false
	}
	return c, true
}

@(test)
blargg_serial_suites :: proc(t: ^testing.T) {
	dir, ok := test_dir()
	if !ok {
		log.warn("ZEMU_GB_TESTS not set")
		return
	}
	roms := []string {
		"gb-test-roms/cpu_instrs/cpu_instrs.gb",
		"gb-test-roms/instr_timing/instr_timing.gb",
		"gb-test-roms/mem_timing/mem_timing.gb",
	}
	for r in roms {
		c, loaded := load(fmt.tprintf("%s/%s", dir, r))
		if !loaded {continue}
		result := "timeout"
		for _ in 0 ..< 60 * 60 {
			run_frame(c, {}, nil)
			out := serial_output(c)
			if strings.contains(out, "Passed") {
				result = "Passed"
				break
			}
			if strings.contains(out, "Failed") {
				result = out
				break
			}
		}
		testing.expectf(t, result == "Passed", "%s: %s", r, result)
		destroy(c)
	}
}

@(test)
acid2_matches_reference :: proc(t: ^testing.T) {
	dir, ok := test_dir()
	if !ok {
		log.warn("ZEMU_GB_TESTS not set")
		return
	}
	cases := [][2]string {
		{"dmg-acid2/dmg-acid2.gb", "dmg-acid2/img/reference-dmg.png"},
		{"cgb-acid2/cgb-acid2.gbc", "cgb-acid2/img/reference.png"},
	}
	for tc in cases {
		c, loaded := load(fmt.tprintf("%s/%s", dir, tc[0]))
		if !loaded {continue}
		for _ in 0 ..< 60 {run_frame(c, {}, nil)}
		img, err := image.load_from_file(fmt.tprintf("%s/%s", dir, tc[1]), {.alpha_drop_if_present})
		if !testing.expectf(t, err == nil, "reference %s: %v", tc[1], err) {
			destroy(c)
			continue
		}
		// DMG references use a grey palette, so compare shade *order*
		// (luminance rank) rather than exact colors.
		bad := 0
		for y in 0 ..< SCREEN_H {
			for x in 0 ..< SCREEN_W {
				p := c.ppu.framebuffer[y * SCREEN_W + x]
				i := (y * img.width + x) * img.channels
				if c.cgb {
					dr := abs(int(p >> 16 & 0xFF) - int(image_pixels(img)[i]))
					dg := abs(int(p >> 8 & 0xFF) - int(image_pixels(img)[i + 1]))
					db := abs(int(p & 0xFF) - int(image_pixels(img)[i + 2]))
					if dr + dg + db > 24 {bad += 1}
				} else {
					mine := shade_index(p)
					ref := 3 - int(image_pixels(img)[i]) / 64 // 255=lightest .. 0=darkest
					if mine != ref {bad += 1}
				}
			}
		}
		testing.expectf(t, bad == 0, "%s: %d pixels differ", tc[0], bad)
		image.destroy(img)
		destroy(c)
	}
}

@(private = "file")
shade_index :: proc(p: u32) -> int {
	switch p {
	case 0xE0F8D0: return 0
	case 0x88C070: return 1
	case 0x346856: return 2
	}
	return 3
}

@(test)
save_state_round_trip :: proc(t: ^testing.T) {
	dir, ok := test_dir()
	if !ok {
		log.warn("ZEMU_GB_TESTS not set")
		return
	}
	c, loaded := load(fmt.tprintf("%s/gb-test-roms/cpu_instrs/cpu_instrs.gb", dir))
	if !loaded {return}
	defer destroy(c)
	for _ in 0 ..< 30 {run_frame(c, {}, nil)}
	state := save_state(c)
	defer delete(state)
	for _ in 0 ..< 60 {run_frame(c, {}, nil)}
	want := c.ppu.framebuffer
	want_cpu := c.cpu
	testing.expect(t, load_state(c, state))
	for _ in 0 ..< 60 {run_frame(c, {}, nil)}
	testing.expect(t, c.ppu.framebuffer == want, "frames differ after reload")
	testing.expect_value(t, c.cpu, want_cpu)
	testing.expect(t, !load_state(c, state[:10]))
	_ = emu.Load_Error.None
}

// blargg's sound tests report through cartridge RAM: a signature at
// $A001-$A003, the status at $A000 and text from $A004.
@(test)
blargg_sound_suite :: proc(t: ^testing.T) {
	dir, ok := test_dir()
	if !ok {
		log.warn("ZEMU_GB_TESTS not set")
		return
	}
	roms := []string {
		"01-registers", "02-len ctr", "03-trigger", "04-sweep", "05-sweep details",
		"06-overflow on trigger", "07-len sweep period sync", "08-len ctr during power",
		"09-wave read while on", "10-wave trigger while on", "11-regs after power",
		"12-wave write while on",
	}
	for name in roms {
		c, loaded := load(fmt.tprintf("%s/gb-test-roms/dmg_sound/rom_singles/%s.gb", dir, name))
		if !loaded {continue}
		status := -1
		for _ in 0 ..< 60 * 40 {
			run_frame(c, {}, nil)
			ram := c.cart.ram
			if len(ram) > 4 && ram[1] == 0xDE && ram[2] == 0xB0 && ram[3] == 0x61 && ram[0] != 0x80 {
				status = int(ram[0])
				break
			}
		}
		testing.expectf(t, status == 0, "%s: status %d", name, status)
		destroy(c)
	}
}

// core:image changed `Image.pixels` from a bytes.Buffer to a [dynamic]byte;
// this accepts either so the tests build with older and newer Odin releases.
@(private = "file")
image_pixels :: proc(img: ^image.Image) -> []u8 {
	when type_of(img.pixels) == [dynamic]byte {
		return img.pixels[:]
	} else {
		return img.pixels.buf[:]
	}
}


// The other blargg suites that report through cartridge RAM. The OAM bug
// tests are for the DMG (their headers also allow CGB mode).
@(test)
blargg_ram_protocol_suites :: proc(t: ^testing.T) {
	dir, ok := test_dir()
	if !ok {
		log.warn("ZEMU_GB_TESTS not set")
		return
	}
	Case :: struct {
		path:  string,
		model: Model,
	}
	cases := []Case {
		{"cgb_sound/rom_singles/01-registers.gb", .Auto},
		{"cgb_sound/rom_singles/02-len ctr.gb", .Auto},
		{"cgb_sound/rom_singles/03-trigger.gb", .Auto},
		{"cgb_sound/rom_singles/04-sweep.gb", .Auto},
		{"cgb_sound/rom_singles/05-sweep details.gb", .Auto},
		{"cgb_sound/rom_singles/06-overflow on trigger.gb", .Auto},
		{"cgb_sound/rom_singles/07-len sweep period sync.gb", .Auto},
		{"cgb_sound/rom_singles/08-len ctr during power.gb", .Auto},
		{"cgb_sound/rom_singles/09-wave read while on.gb", .Auto},
		{"cgb_sound/rom_singles/10-wave trigger while on.gb", .Auto},
		{"cgb_sound/rom_singles/11-regs after power.gb", .Auto},
		{"cgb_sound/rom_singles/12-wave.gb", .Auto},
		{"oam_bug/rom_singles/1-lcd_sync.gb", .Dmg},
		{"oam_bug/rom_singles/2-causes.gb", .Dmg},
		{"oam_bug/rom_singles/3-non_causes.gb", .Dmg},
		{"oam_bug/rom_singles/4-scanline_timing.gb", .Dmg},
		{"oam_bug/rom_singles/5-timing_bug.gb", .Dmg},
		{"oam_bug/rom_singles/6-timing_no_bug.gb", .Dmg},
		{"oam_bug/rom_singles/8-instr_effect.gb", .Dmg},
		{"mem_timing-2/mem_timing.gb", .Auto},
	}
	for tc in cases {
		c, loaded := load(fmt.tprintf("%s/gb-test-roms/%s", dir, tc.path), tc.model)
		if !loaded {continue}
		status := -1
		for _ in 0 ..< 60 * 30 {
			run_frame(c, {}, nil)
			ram := c.cart.ram
			if len(ram) > 4 && ram[1] == 0xDE && ram[2] == 0xB0 && ram[3] == 0x61 && ram[0] != 0x80 {
				status = int(ram[0])
				break
			}
		}
		testing.expectf(t, status == 0, "%s: status %d", tc.path, status)
		destroy(c)
	}
}
