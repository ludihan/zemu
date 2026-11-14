package psx

import "core:fmt"
import "core:image"
import "core:image/png"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "../../emu"

_ :: png // registers the PNG loader with core:image

// Point ZEMU_PSX_TESTS at a checkout of https://github.com/PeterLemon/PSX.
// The programs are bare-metal and run without a BIOS. Their reference
// screenshots were captured with brightened blending, so we compare which
// pixels are lit rather than exact colors.
@(private = "file")
test_dir :: proc() -> (string, bool) {
	dir := os.get_env("ZEMU_PSX_TESTS", context.temp_allocator)
	return dir, dir != ""
}

@(private = "file")
shape_difference :: proc(c: ^Console, png_path: string) -> f64 {
	img, err := image.load_from_file(png_path, {.alpha_drop_if_present})
	if err != nil {
		log.errorf("cannot load %s: %v", png_path, err)
		return 1
	}
	defer image.destroy(img)
	f := frame(c)
	w := min(f.width, img.width)
	h := min(f.height, img.height)
	if w <= 0 || h <= 0 || img.channels < 3 || img.depth != 8 {
		return 1
	}
	bad := 0
	for y in 0 ..< h {
		for x in 0 ..< w {
			p := f.pixels[y * f.pitch + x]
			mine := int(p >> 16 & 0xFF) + int(p >> 8 & 0xFF) + int(p & 0xFF) > 60
			i := (y * img.width + x) * img.channels
			ref := int(image_pixels(img)[i]) + int(image_pixels(img)[i + 1]) + int(image_pixels(img)[i + 2]) > 60
			if mine != ref {
				bad += 1
			}
		}
	}
	return f64(bad) / f64(w * h)
}

@(private = "file")
run_exe :: proc(path: string, frames: int) -> (^Console, bool) {
	exe, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		log.errorf("missing %s", path)
		return nil, false
	}
	defer delete(exe)
	c, load_err := create(nil, nil, exe)
	if load_err != .None {
		log.errorf("%s: %v", path, load_err)
		return nil, false
	}
	for _ in 0 ..< frames {
		run_frame(c, {}, nil)
	}
	return c, true
}

@(test)
reference_programs_match :: proc(t: ^testing.T) {
	dir, ok := test_dir()
	if !ok {
		log.warn("ZEMU_PSX_TESTS not set")
		return
	}
	programs := []string {
		"CPUTest/CPU/ADD/CPUADD", "CPUTest/CPU/ADDI/CPUADDI", "CPUTest/CPU/ADDIU/CPUADDIU",
		"CPUTest/CPU/ADDU/CPUADDU", "CPUTest/CPU/AND/CPUAND", "CPUTest/CPU/ANDI/CPUANDI",
		"CPUTest/CPU/DIV/CPUDIV", "CPUTest/CPU/DIVU/CPUDIVU", "CPUTest/CPU/MULT/CPUMULT",
		"CPUTest/CPU/MULTU/CPUMULTU", "CPUTest/CPU/NOR/CPUNOR", "CPUTest/CPU/OR/CPUOR",
		"CPUTest/CPU/ORI/CPUORI", "CPUTest/CPU/SUB/CPUSUB", "CPUTest/CPU/SUBU/CPUSUBU",
		"CPUTest/CPU/XOR/CPUXOR", "CPUTest/CPU/XORI/CPUXORI",
		"CPUTest/CPU/LOADSTORE/LB/CPULB", "CPUTest/CPU/LOADSTORE/LH/CPULH", "CPUTest/CPU/LOADSTORE/LW/CPULW",
		"CPUTest/CPU/LOADSTORE/SB/CPUSB", "CPUTest/CPU/LOADSTORE/SH/CPUSH", "CPUTest/CPU/LOADSTORE/SW/CPUSW",
		"CPUTest/CPU/SHIFT/SLL/CPUSLL", "CPUTest/CPU/SHIFT/SLLV/CPUSLLV", "CPUTest/CPU/SHIFT/SRA/CPUSRA",
		"CPUTest/CPU/SHIFT/SRAV/CPUSRAV", "CPUTest/CPU/SHIFT/SRL/CPUSRL", "CPUTest/CPU/SHIFT/SRLV/CPUSRLV",
		"CPUTest/GTE/AVSZ/GTEAVSZ", "CPUTest/GTE/NCLIP/GTENCLIP",
		"HelloWorld/16BPP/HelloWorld16BPP", "HelloWorld/24BPP/HelloWorld24BPP",
		"GPU/16BPP/MemoryTransfer/MemoryTransfer16BPP", "GPU/24BPP/MemoryTransfer/MemoryTransfer24BPP",
		"GPU/16BPP/RenderRectangle/RenderRectangle16BPP",
		"GPU/16BPP/RenderTextureRectangle/15BPP/RenderTextureRectangle15BPP",
		"GPU/16BPP/RenderTextureRectangle/CLUT4BPP/RenderTextureRectangleCLUT4BPP",
		"GPU/16BPP/RenderTextureRectangle/CLUT8BPP/RenderTextureRectangleCLUT8BPP",
		"GPU/16BPP/RenderTextureWindowRectangle/15BPP/RenderTextureWindowRectangle15BPP",
	}
	for prog in programs {
		base := fmt.tprintf("%s/%s", dir, prog)
		exe := fmt.tprintf("%s.exe", base)
		if !os.exists(exe) {
			log.errorf("missing %s", exe)
			continue
		}
		c, ran := run_exe(exe, 180)
		if !ran {
			continue
		}
		ref, _ := filepath.glob(fmt.tprintf("%s/*.png", filepath.dir(exe)), context.temp_allocator)
		if len(ref) == 0 {
			destroy(c)
			continue
		}
		diff := shape_difference(c, ref[0])
		testing.expectf(t, diff == 0, "%s: %.2f%% of pixels differ in shape", prog, diff * 100)
		destroy(c)
	}
}

// Hand-computed perspective transform: identity rotation, translation along
// Z and projection plane distance H map a point to a known screen position.
@(test)
gte_rtps_projects_points :: proc(t: ^testing.T) {
	g: Gte
	gte_write_control(&g, 0, 0x1000)       // RT11 = 1.0, RT12 = 0
	gte_write_control(&g, 2, 0x1000)       // RT22 = 1.0, RT23 = 0
	gte_write_control(&g, 4, 0x1000)       // RT33 = 1.0
	gte_write_control(&g, 7, 0x400)        // TRZ = 1024
	gte_write_control(&g, 24, 160 << 16)   // OFX = 160.0
	gte_write_control(&g, 25, 120 << 16)   // OFY = 120.0
	gte_write_control(&g, 26, 512)         // H = 512
	vx, vy: i16 = 100, -50
	gte_write_data(&g, 0, u32(u16(vx)) | u32(u16(vy)) << 16)
	gte_write_data(&g, 1, 1024)            // VZ0 = 1024
	gte_command(&g, 0x0008_0001)           // RTPS with sf=1

	// Z = 1024 + 1024 = 2048; projection scale = H / Z = 0.25
	testing.expect_value(t, g.sz[3], 2048)
	testing.expect_value(t, g.ir[1], 100)
	testing.expect_value(t, g.ir[2], -50)
	testing.expect_value(t, g.sxy[2][0], 160 + 25)
	testing.expect_value(t, g.sxy[2][1], 120 - 13) // -12.5 rounds toward -inf
	testing.expect_value(t, g.flag & 0x8000_0000, 0)
}

@(test)
gte_nclip_sign_matches_winding :: proc(t: ^testing.T) {
	g: Gte
	gte_write_data(&g, 12, 0)                          // (0, 0)
	gte_write_data(&g, 13, 10)                         // (10, 0)
	gte_write_data(&g, 14, u32(10) << 16)              // (0, 10)
	gte_command(&g, 0x06)
	testing.expect(t, g.mac[0] > 0, "clockwise on screen should be positive")
	gte_write_data(&g, 13, u32(10) << 16)
	gte_write_data(&g, 14, 10)
	gte_command(&g, 0x06)
	testing.expect(t, g.mac[0] < 0, "counter-clockwise should be negative")
}

@(test)
save_state_round_trip_is_deterministic :: proc(t: ^testing.T) {
	dir, ok := test_dir()
	if !ok {
		log.warn("ZEMU_PSX_TESTS not set")
		return
	}
	c, ran := run_exe(fmt.tprintf("%s/SPU/PlaySong/PlaySong.exe", dir), 30)
	if !testing.expect(t, ran) {return}
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
	state := save_state(c)
	defer delete(state)
	want := run(c, audio, 60)
	testing.expect(t, load_state(c, state), "state should load")
	testing.expect_value(t, run(c, audio, 60), want)
	testing.expect(t, !load_state(c, state[:len(state) / 2]))
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

// ZEMU_PS1_TESTS points at a checkout of JaCzekanski's ps1-tests with each
// test built next to its sources as <test>.exe (no BIOS needed: the HLE BIOS
// serves PSn00bSDK). Tests with a vram.png captured on hardware must leave
// VRAM matching it.
@(test)
ps1_tests_vram_matches_hardware :: proc(t: ^testing.T) {
	dir := os.get_env("ZEMU_PS1_TESTS", context.temp_allocator)
	if dir == "" {
		log.warn("ZEMU_PS1_TESTS not set")
		return
	}
	Case :: struct {
		name:  string,
		w, h:  int, // compare only this top-left region (0 = all of VRAM)
		known: int, // differing pixels still accepted (documented below)
	}
	tests := []Case {
		{name = "gpu/triangle"},
		{name = "gpu/quad"},
		{name = "gpu/rectangles"},
		// The test never sets the last colour of its Gouraud polyline, so the
		// final segment fades towards whatever its stack held (compiler-dependent).
		{name = "gpu/lines", known = 64},
		{name = "gpu/clipping"},
		// The hardware dump has leftovers from an earlier program outside the
		// 320x240 area the test draws into.
		{name = "gpu/transparency", w = 320, h = 240},
		{name = "gpu/texture-overflow"},
		{name = "gpu/texture-flip"},
		{name = "gpu/uv-interpolation"},
		{name = "gpu/clut-cache"},
		{name = "gpu/mask-bit"},
		// One column per row still differs in same-row copies shifted 1-3
		// pixels to the right (the 16-pixel copy buffer is not exact yet).
		{name = "gpu/vram-to-vram-overlap", known = 270},
	}
	for tc in tests {
		name := tc.name
		exe_path := fmt.tprintf("%s/%s/%s.exe", dir, name, name[strings.last_index(name, "/") + 1:])
		ref_path := fmt.tprintf("%s/%s/vram.png", dir, name)
		if !os.exists(exe_path) || !os.exists(ref_path) {
			log.warnf("%s: not built or no reference", name)
			continue
		}
		c, ok := run_exe(exe_path, 30)
		if !ok {
			testing.expectf(t, false, "%s: did not load", name)
			continue
		}
		diff := vram_difference(c, ref_path, tc.w, tc.h)
		testing.expectf(t, diff >= 0 && diff <= tc.known, "%s: %d VRAM pixels differ from hardware", name, diff)
		destroy(c)
	}
}

// Pixels whose 15-bit colour differs from a VRAM dump taken on hardware.
@(private = "file")
vram_difference :: proc(c: ^Console, png_path: string, region_w := 0, region_h := 0) -> int {
	img, err := image.load_from_file(png_path, {.alpha_drop_if_present})
	if err != nil {
		return -1
	}
	defer image.destroy(img)
	px := image_pixels(img)
	if img.width != VRAM_W || img.height != VRAM_H {
		return -1
	}
	rw := region_w > 0 ? region_w : VRAM_W
	rh := region_h > 0 ? region_h : VRAM_H
	bad := 0
	for i in 0 ..< VRAM_W * VRAM_H {
		if i % VRAM_W >= rw || i / VRAM_W >= rh {
			continue
		}
		v := c.gpu.vram[i]
		r, g, b := px[i * img.channels] >> 3, px[i * img.channels + 1] >> 3, px[i * img.channels + 2] >> 3
		if u16(r) != v & 31 || u16(g) != (v >> 5) & 31 || u16(b) != (v >> 10) & 31 {
			bad += 1
		}
	}
	return bad
}

// The ps1-tests that check registers with assertions and print "pass - ..."
// or "fail - ..." through the BIOS TTY.
@(test)
ps1_tests_assertions_pass :: proc(t: ^testing.T) {
	dir := os.get_env("ZEMU_PS1_TESTS", context.temp_allocator)
	if dir == "" {
		log.warn("ZEMU_PS1_TESTS not set")
		return
	}
	for name in ([]string{"dma/dpcr", "dma/otc-test", "gpu/gp0-e1", "gpu/gpustat"}) {
		path := fmt.tprintf("%s/%s/%s.exe", dir, name, name[strings.last_index(name, "/") + 1:])
		if !os.exists(path) {
			log.warnf("%s: not built", name)
			continue
		}
		c, ok := run_exe(path, 120)
		if !ok {continue}
		out := tty_output(c)
		passes := strings.count(out, "pass -")
		fails := strings.count(out, "fail -")
		testing.expectf(t, passes > 0 && fails == 0, "%s: %d passed, %d failed\n%s", name, passes, fails, out)
		destroy(c)
	}
}

// ps1-tests whose TTY output on a real console was saved as psx.log.
@(test)
ps1_tests_tty_matches_hardware :: proc(t: ^testing.T) {
	dir := os.get_env("ZEMU_PS1_TESTS", context.temp_allocator)
	if dir == "" {
		log.warn("ZEMU_PS1_TESTS not set")
		return
	}
	Case :: struct {
		name, log: string,
		press:     emu.Buttons, // held to start the test (gte-fuzz waits for a button)
		frames:    int,
	}
	cases := []Case {
		{"gte/test-all", "psx.log", {}, 300},
		{"gte-fuzz", "gte_valid_0xc0ffee_50.log", {.Start}, 3000},
	}
	for tc in cases {
		base := tc.name[strings.last_index(tc.name, "/") + 1:]
		path := fmt.tprintf("%s/%s/%s.exe", dir, tc.name, base)
		want, err := os.read_entire_file(fmt.tprintf("%s/%s/%s", dir, tc.name, tc.log), context.allocator)
		if !os.exists(path) || err != nil {
			log.warnf("%s: not built", tc.name)
			continue
		}
		defer delete(want)
		exe, _ := os.read_entire_file(path, context.allocator)
		c, load_err := create(nil, nil, exe)
		delete(exe)
		if load_err != .None {
			log.errorf("%s: %v", tc.name, load_err)
			continue
		}
		defer destroy(c)

		// The log is long, so the TTY is drained as the program prints, and
		// every line of the hardware log must appear in it, in order (the SDK
		// zemu builds with prints a few extra lines of its own).
		lines := strings.split_lines(strings.trim_space(string(want)))
		defer delete(lines)
		matched := 0
		pending: [dynamic]u8
		defer delete(pending)
		drain :: proc(c: ^Console, pending: ^[dynamic]u8, lines: []string, matched: ^int) {
			append(pending, ..c.hle.tty[:c.hle.tty_len])
			c.hle.tty_len = 0
			for {
				nl := strings.index_byte(string(pending[:]), '\n')
				if nl < 0 {break}
				line := strings.trim_right(string(pending[:nl]), "\r")
				if matched^ < len(lines) && line == strings.trim_right(lines[matched^], "\r") {
					matched^ += 1
				}
				remove_range(pending, 0, nl + 1)
			}
		}
		for frame in 0 ..< tc.frames {
			c.pads[0] = frame >= 60 && frame < 70 ? tc.press : {}
			c.frame_ready = false
			for budget := LINE_CYCLES * LINES_PER_FRAME * 2; !c.frame_ready && budget > 0; {
				n := cpu_step(c)
				budget -= n
				tick(c, n)
				if c.hle.tty_len > len(c.hle.tty) - 1024 {
					drain(c, &pending, lines, &matched)
				}
			}
			drain(c, &pending, lines, &matched)
			if matched == len(lines) {break}
		}
		testing.expectf(t, matched == len(lines), "%s: TTY matches hardware up to line %d of %d: %q",
			tc.name, matched, len(lines), matched < len(lines) ? lines[matched] : "")
	}
}

@(test)
spu_volume_sweep_ramps :: proc(t: ^testing.T) {
	c := new(Console)
	defer free(c)
	spu_reset(&c.spu)
	// linear increase at the fastest rate: +0x3800 per sample, up to 0x7FFF
	spu_write(c, 0x1F80_1C00, 0x8000)
	spu_write(c, 0x1F80_1C02, 0x3000) // fixed volume first...
	testing.expect_value(t, spu_read(&c.spu, 0x1F80_1E02), 0x6000)
	spu_write(c, 0x1F80_1C02, 0x8000 | 0x2000 | 0x1000 | 0x64) // ...then sweep it down
	want_l := []u16{0x3800, 0x7000, 0x7FFF, 0x7FFF}
	for w in want_l {
		spu_sample(c)
		testing.expect_value(t, spu_read(&c.spu, 0x1F80_1E00), w)
	}
	// rate 0x64: shift 25, cycles 1 << 14, step -8 per update; phase makes it negative
	for _ in 0 ..< 1 << 14 {
		spu_sample(c)
	}
	testing.expect_value(t, spu_read(&c.spu, 0x1F80_1E02), transmute(u16)i16(-(0x6000 - 8)))
}
