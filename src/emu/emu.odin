// Package emu holds the types shared between the frontend and every emulated
// system: controller state, the video frame a core hands back, and the audio
// sample buffer a core fills while it runs.
//
// Cores never talk to SDL. They receive an `Input`, advance one video frame,
// write samples into an `Audio_Buffer` and expose their picture as a `Frame`.
package emu

Button :: enum u8 {
	Up,
	Down,
	Left,
	Right,
	A,      // East face button (SNES A, NES A, PlayStation Circle)
	B,      // South face button (SNES B, NES B, PlayStation Cross)
	X,      // North face button (SNES X, PlayStation Triangle)
	Y,      // West face button (SNES Y, PlayStation Square)
	L,
	R,
	L2,
	R2,
	Select,
	Start,
}

Buttons :: bit_set[Button; u16]

MAX_PADS :: 2

Input :: struct {
	pads: [MAX_PADS]Buttons,
}

// A view into a core-owned pixel buffer. Pixels are 0x00RRGGBB.
// `pitch` is measured in pixels, not bytes.
Frame :: struct {
	pixels: []u32,
	width:  int,
	height: int,
	pitch:  int,
}

// Returns true when the frame can be read without leaving `pixels`.
frame_is_valid :: proc(f: Frame) -> bool {
	if f.width <= 0 || f.height <= 0 || f.pitch < f.width {
		return false
	}
	return (f.height - 1) * f.pitch + f.width <= len(f.pixels)
}

AUDIO_BUFFER_FRAMES :: 8192

// Interleaved stereo signed 16-bit samples. Fixed capacity, so a misbehaving
// core can never grow it without bound: extra samples are dropped.
Audio_Buffer :: struct {
	samples: [AUDIO_BUFFER_FRAMES * 2]i16,
	count:   int, // number of i16 values written (2 per stereo frame)
}

audio_push :: #force_inline proc "contextless" (buf: ^Audio_Buffer, left, right: i16) {
	if buf.count + 2 <= len(buf.samples) {
		buf.samples[buf.count] = left
		buf.samples[buf.count + 1] = right
		buf.count += 2
	}
}

audio_clear :: #force_inline proc "contextless" (buf: ^Audio_Buffer) {
	buf.count = 0
}

audio_slice :: proc(buf: ^Audio_Buffer) -> []i16 {
	return buf.samples[:buf.count]
}

// Converts a float sample in roughly [-1, 1] to i16 with saturation.
sample_to_i16 :: #force_inline proc "contextless" (s: f32) -> i16 {
	v := s * 32767
	if v > 32767 {
		return 32767
	}
	if v < -32768 {
		return -32768
	}
	return i16(v)
}

clamp_i16 :: #force_inline proc "contextless" (v: i32) -> i16 {
	return i16(clamp(v, -32768, 32767))
}

System_Kind :: enum u8 {
	NES,
	SNES,
	PSX,
	GB,
	SMS,
	GG,
}

System_Info :: struct {
	name:         string,
	short_name:   string,
	extensions:   []string,
	fps:          f64,
	sample_rate:  int,
	// Display aspect ratio of the full picture as shown on a CRT.
	aspect:       f32,
	needs_bios:   bool,
}

SYSTEM_INFO := [System_Kind]System_Info {
	.NES = {
		name        = "Nintendo Entertainment System",
		short_name  = "NES",
		extensions  = {".nes"},
		fps         = 60.0988,
		sample_rate = 48000,
		aspect      = 4.0 / 3.0,
	},
	.SNES = {
		name        = "Super Nintendo",
		short_name  = "SNES",
		extensions  = {".sfc", ".smc"},
		fps         = 60.0988,
		sample_rate = 32000,
		aspect      = 4.0 / 3.0,
	},
	.PSX = {
		name        = "PlayStation",
		short_name  = "PSX",
		extensions  = {".cue", ".bin", ".iso", ".exe", ".psx"},
		fps         = 59.826,
		sample_rate = 44100,
		aspect      = 4.0 / 3.0,
		needs_bios  = true,
	},
	.GB = {
		name        = "Game Boy / Game Boy Color",
		short_name  = "GB",
		extensions  = {".gb", ".gbc"},
		fps         = 59.7275,
		sample_rate = 48000,
		aspect      = 10.0 / 9.0,
	},
	.SMS = {
		name        = "Sega Master System",
		short_name  = "SMS",
		extensions  = {".sms"},
		fps         = 59.9227,
		sample_rate = 48000,
		aspect      = 4.0 / 3.0,
	},
	.GG = {
		name        = "Sega Game Gear",
		short_name  = "GG",
		extensions  = {".gg"},
		fps         = 59.9227,
		sample_rate = 48000,
		aspect      = 4.0 / 3.0,
	},
}

Load_Error :: enum u8 {
	None,
	Bad_Header,
	Truncated,
	Unsupported_Mapper,
	Unsupported_Chip,
	Unsupported_Format,
	Missing_Bios,
	Bad_Bios,
	Io,
	Out_Of_Memory,
}

LOAD_ERROR_TEXT := [Load_Error]string {
	.None               = "OK",
	.Bad_Header         = "Not a valid ROM image",
	.Truncated          = "ROM file is truncated",
	.Unsupported_Mapper = "Unsupported cartridge mapper",
	.Unsupported_Chip   = "Needs an enhancement chip that is not emulated",
	.Unsupported_Format = "Unsupported file format",
	.Missing_Bios       = "BIOS not found (set it in CONFIG > PATHS)",
	.Bad_Bios           = "BIOS image is invalid (must be 512 KB)",
	.Io                 = "Could not read file",
	.Out_Of_Memory      = "Out of memory",
}
