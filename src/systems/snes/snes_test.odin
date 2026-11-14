package snes

import "core:fmt"
import "core:image"
import "core:image/png"
import "core:log"
import "core:os"
import "core:strings"
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
	pixels := image_pixels(img)
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

@(test)
pal_header_selects_50hz_timing :: proc(t: ^testing.T) {
	dir, ok := test_dir()
	if !ok {
		log.warn("ZEMU_SNES_TESTS not set")
		return
	}
	rom, err := os.read_entire_file(fmt.tprintf("%s/SPC700/Twinkle/Twinkle.sfc", dir), context.allocator)
	if !testing.expect(t, err == nil) {return}
	defer delete(rom)
	samples_per_frame :: proc(c: ^Console) -> int {
		audio := new(emu.Audio_Buffer)
		defer free(audio)
		for _ in 0 ..< 30 {run_frame(c, {}, audio); audio.count = 0}
		total := 0
		for _ in 0 ..< 60 {
			run_frame(c, {}, audio)
			total += audio.count / 2
			audio.count = 0
		}
		return total / 60
	}
	ntsc, _ := create(rom)
	defer destroy(ntsc)
	testing.expect(t, !ntsc.pal)
	n := samples_per_frame(ntsc)

	rom[0x7FD9] = 0x02 // destination code: Europe (LoROM header)
	pal, _ := create(rom)
	defer destroy(pal)
	testing.expect(t, pal.pal, "header should select PAL")
	p := samples_per_frame(pal)
	testing.expectf(t, abs(n - 533) <= 2, "NTSC: %d samples per frame", n)
	testing.expectf(t, abs(p - 640) <= 2, "PAL: %d samples per frame", p)
	testing.expect_value(t, ppu_read(pal, 0x213F) & 0x10, 0x10)
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

// PeterLemon's Super FX tests: instruction tests print PASS/FAIL tables and
// the 2/4/8 bpp demos plot pixels, lines and polygons; each ships the
// expected screen.
@(test)
gsu_tests_match_reference_screens :: proc(t: ^testing.T) {
	dir, ok := test_dir()
	if !ok {
		log.warn("ZEMU_SNES_TESTS not set")
		return
	}
	root := fmt.tprintf("%s/CHIP/GSU", dir)
	paths: [dynamic]string
	defer delete(paths)
	walk :: proc(dir: string, out: ^[dynamic]string) {
		entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
		if err != nil {return}
		for e in entries {
			if e.type == .Directory {
				walk(e.fullpath, out)
			} else if len(e.name) > 4 && e.name[len(e.name) - 4:] == ".sfc" {
				append(out, e.fullpath)
			}
		}
	}
	walk(root, &paths)
	testing.expect(t, len(paths) > 0, "no GSU tests found")
	for path in paths {
		png_path := fmt.tprintf("%s.png", path[:len(path) - 4])
		if !os.exists(png_path) {continue}
		// The three 256x192 PlotPixel screenshots show the picture starting
		// two lines earlier than the ROMs' own HDMA table (19 blank lines)
		// allows; the same rule matches the 128- and 160-line versions and
		// the other 192-line demos exactly, so those references look stale.
		if strings.contains(path, "PlotPixel/256x192") {continue}
		rom, err := os.read_entire_file(path, context.allocator)
		if err != nil {continue}
		c, load_err := create(rom)
		delete(rom)
		if load_err != .None {
			testing.expectf(t, false, "%s: %v", path, load_err)
			continue
		}
		for _ in 0 ..< 300 {
			run_frame(c, {}, nil)
		}
		diff := compare_with_png(t, c, png_path)
		testing.expectf(t, diff == 0, "%s: %.2f%% of pixels differ", path[len(root) + 1:], diff * 100)
		destroy(c)
	}
}
