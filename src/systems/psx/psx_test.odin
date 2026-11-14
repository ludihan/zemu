package psx

import "core:fmt"
import "core:image"
import "core:image/png"
import "core:log"
import "core:os"
import "core:path/filepath"
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
			ref := int(img.pixels[i]) + int(img.pixels[i + 1]) + int(img.pixels[i + 2]) > 60
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
