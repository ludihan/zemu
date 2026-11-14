package snes

import "core:fmt"
import "core:image"
import "core:image/png"
import "core:log"
import "core:os"
import "core:testing"

import "../../emu"

_ :: png // registers the PNG loader with core:image

// Point ZEMU_SNES_TESTS at a checkout of https://github.com/PeterLemon/SNES.
// Each CPU test ships a screenshot of the expected final screen.
@(private = "file")
test_dir :: proc() -> (string, bool) {
	dir := os.get_env("ZEMU_SNES_TESTS", context.temp_allocator)
	return dir, dir != ""
}

// Fraction of pixels that differ noticeably from the reference image.
@(private = "file")
compare_with_png :: proc(t: ^testing.T, c: ^Console, png_path: string) -> f64 {
	img, err := image.load_from_file(png_path, {.alpha_drop_if_present})
	if err != nil {
		log.errorf("cannot load %s: %v", png_path, err)
		return 1
	}
	defer image.destroy(img)
	f := frame(c)
	if img.width != f.width || img.height != f.height || img.channels < 3 || img.depth != 8 {
		log.errorf("%s: size %dx%d, frame %dx%d", png_path, img.width, img.height, f.width, f.height)
		return 1
	}
	pixels := img.pixels[:]
	bad := 0
	for y in 0 ..< f.height {
		for x in 0 ..< f.width {
			p := f.pixels[y * f.pitch + x]
			i := (y * img.width + x) * img.channels
			dr := abs(int(p >> 16 & 0xFF) - int(pixels[i]))
			dg := abs(int(p >> 8 & 0xFF) - int(pixels[i + 1]))
			db := abs(int(p & 0xFF) - int(pixels[i + 2]))
			if dr + dg + db > 48 {
				bad += 1
			}
		}
	}
	return f64(bad) / f64(f.width * f.height)
}

@(test)
cpu_tests_match_reference_screens :: proc(t: ^testing.T) {
	dir, ok := test_dir()
	if !ok {
		log.warn("ZEMU_SNES_TESTS not set")
		return
	}
	// MSC asks for a manual reset before showing its last result.
	names := []string {
		"ADC", "AND", "ASL", "BIT", "BRA", "CMP", "DEC", "EOR", "INC", "JMP", "LDR", "LSR",
		"MOV", "ORA", "PHL", "PSR", "RET", "ROL", "ROR", "SBC", "STR", "TRN",
	}
	for name in names {
		base := fmt.tprintf("%s/CPUTest/CPU/%s/CPU%s", dir, name, name)
		rom, err := os.read_entire_file(fmt.tprintf("%s.sfc", base), context.allocator)
		if err != nil {
			log.errorf("missing %s.sfc", base)
			continue
		}
		c, load_err := create(rom)
		delete(rom)
		if load_err != .None {
			log.errorf("%s: %v", name, load_err)
			continue
		}
		for _ in 0 ..< 600 {
			run_frame(c, {}, nil)
		}
		diff := compare_with_png(t, c, fmt.tprintf("%s.png", base))
		testing.expectf(t, diff == 0, "%s: %.2f%% of pixels differ", name, diff * 100)
		destroy(c)
	}
}

@(test)
boot_rom_uploads_and_produces_sound :: proc(t: ^testing.T) {
	dir, ok := test_dir()
	if !ok {
		log.warn("ZEMU_SNES_TESTS not set")
		return
	}
	rom, err := os.read_entire_file(fmt.tprintf("%s/SPC700/Twinkle/Twinkle.sfc", dir), context.allocator)
	if !testing.expect(t, err == nil, "missing Twinkle.sfc") {
		return
	}
	defer delete(rom)
	c, load_err := create(rom)
	if !testing.expect_value(t, load_err, emu.Load_Error.None) {
		return
	}
	defer destroy(c)
	audio := new(emu.Audio_Buffer)
	defer free(audio)
	loud := 0
	for _ in 0 ..< 120 {
		audio.count = 0
		run_frame(c, {}, audio)
		for s in audio.samples[:audio.count] {
			if abs(int(s)) > 256 {
				loud += 1
			}
		}
	}
	testing.expectf(t, loud > 10000, "expected audible output, got %d loud samples", loud)
}

@(test)
save_state_round_trip_is_deterministic :: proc(t: ^testing.T) {
	dir, ok := test_dir()
	if !ok {
		log.warn("ZEMU_SNES_TESTS not set")
		return
	}
	rom, err := os.read_entire_file(fmt.tprintf("%s/SPC700/FFVIIPrelude/FFVIIPrelude.sfc", dir), context.allocator)
	if !testing.expect(t, err == nil) {return}
	defer delete(rom)
	c, _ := create(rom)
	defer destroy(c)
	audio := new(emu.Audio_Buffer)
	defer free(audio)
	run :: proc(c: ^Console, audio: ^emu.Audio_Buffer, frames: int) -> u64 {
		h: u64 = 0xcbf29ce484222325
		for _ in 0 ..< frames {
			audio.count = 0
			run_frame(c, {}, audio)
			for s in audio.samples[:audio.count] {
				h = (h ~ u64(u16(s))) * 0x100000001b3
			}
		}
		return h
	}
	run(c, audio, 100)
	state := save_state(c)
	defer delete(state)
	want := run(c, audio, 60)
	testing.expect(t, load_state(c, state), "state should load")
	testing.expect_value(t, run(c, audio, 60), want) // identical audio afterwards
	testing.expect(t, !load_state(c, state[:100]))
}
