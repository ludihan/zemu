package ps2

// GS local memory: 4 MiB organised in 8 KiB pages of 32 blocks. Pixels are
// swizzled inside blocks and blocks inside pages, differently for each
// pixel format, so data written in one format and read in another lands
// where real hardware would put it.

GS_MEM_WORDS :: 1024 * 1024

PSMCT32  :: 0x00
PSMCT24  :: 0x01
PSMCT16  :: 0x02
PSMCT16S :: 0x0A
PSMT8    :: 0x13
PSMT4    :: 0x14
PSMT8H   :: 0x1B
PSMT4HL  :: 0x24
PSMT4HH  :: 0x2C
PSMZ32   :: 0x30
PSMZ24   :: 0x31
PSMZ16   :: 0x32
PSMZ16S  :: 0x3A

@(private = "file", rodata)
BLOCK32 := [4][8]u32 {
	{0, 1, 4, 5, 16, 17, 20, 21},
	{2, 3, 6, 7, 18, 19, 22, 23},
	{8, 9, 12, 13, 24, 25, 28, 29},
	{10, 11, 14, 15, 26, 27, 30, 31},
}

@(private = "file", rodata)
BLOCKZ32 := [4][8]u32 {
	{24, 25, 28, 29, 8, 9, 12, 13},
	{26, 27, 30, 31, 10, 11, 14, 15},
	{16, 17, 20, 21, 0, 1, 4, 5},
	{18, 19, 22, 23, 2, 3, 6, 7},
}

@(private = "file", rodata)
COLUMN32 := [8][8]u32 {
	{0, 1, 4, 5, 8, 9, 12, 13},
	{2, 3, 6, 7, 10, 11, 14, 15},
	{16, 17, 20, 21, 24, 25, 28, 29},
	{18, 19, 22, 23, 26, 27, 30, 31},
	{32, 33, 36, 37, 40, 41, 44, 45},
	{34, 35, 38, 39, 42, 43, 46, 47},
	{48, 49, 52, 53, 56, 57, 60, 61},
	{50, 51, 54, 55, 58, 59, 62, 63},
}

@(private = "file", rodata)
BLOCK16 := [8][4]u32 {
	{0, 2, 8, 10},
	{1, 3, 9, 11},
	{4, 6, 12, 14},
	{5, 7, 13, 15},
	{16, 18, 24, 26},
	{17, 19, 25, 27},
	{20, 22, 28, 30},
	{21, 23, 29, 31},
}

@(private = "file", rodata)
BLOCK16S := [8][4]u32 {
	{0, 2, 16, 18},
	{1, 3, 17, 19},
	{8, 10, 24, 26},
	{9, 11, 25, 27},
	{4, 6, 20, 22},
	{5, 7, 21, 23},
	{12, 14, 28, 30},
	{13, 15, 29, 31},
}

@(private = "file", rodata)
BLOCKZ16 := [8][4]u32 {
	{24, 26, 16, 18},
	{25, 27, 17, 19},
	{28, 30, 20, 22},
	{29, 31, 21, 23},
	{8, 10, 0, 2},
	{9, 11, 1, 3},
	{12, 14, 4, 6},
	{13, 15, 5, 7},
}

@(private = "file", rodata)
BLOCKZ16S := [8][4]u32 {
	{24, 26, 8, 10},
	{25, 27, 9, 11},
	{16, 18, 0, 2},
	{17, 19, 1, 3},
	{28, 30, 12, 14},
	{29, 31, 13, 15},
	{20, 22, 4, 6},
	{21, 23, 5, 7},
}

@(private = "file", rodata)
COLUMN16 := [8][16]u32 {
	{0, 2, 8, 10, 16, 18, 24, 26, 1, 3, 9, 11, 17, 19, 25, 27},
	{4, 6, 12, 14, 20, 22, 28, 30, 5, 7, 13, 15, 21, 23, 29, 31},
	{32, 34, 40, 42, 48, 50, 56, 58, 33, 35, 41, 43, 49, 51, 57, 59},
	{36, 38, 44, 46, 52, 54, 60, 62, 37, 39, 45, 47, 53, 55, 61, 63},
	{64, 66, 72, 74, 80, 82, 88, 90, 65, 67, 73, 75, 81, 83, 89, 91},
	{68, 70, 76, 78, 84, 86, 92, 94, 69, 71, 77, 79, 85, 87, 93, 95},
	{96, 98, 104, 106, 112, 114, 120, 122, 97, 99, 105, 107, 113, 115, 121, 123},
	{100, 102, 108, 110, 116, 118, 124, 126, 101, 103, 109, 111, 117, 119, 125, 127},
}

@(private = "file", rodata)
BLOCK8 := [4][8]u32 {
	{0, 1, 4, 5, 16, 17, 20, 21},
	{2, 3, 6, 7, 18, 19, 22, 23},
	{8, 9, 12, 13, 24, 25, 28, 29},
	{10, 11, 14, 15, 26, 27, 30, 31},
}

@(private = "file", rodata)
BLOCK4 := [8][4]u32 {
	{0, 2, 8, 10},
	{1, 3, 9, 11},
	{4, 6, 12, 14},
	{5, 7, 13, 15},
	{16, 18, 24, 26},
	{17, 19, 25, 27},
	{20, 22, 28, 30},
	{21, 23, 29, 31},
}

// Word address of a 32-bit pixel. `bp` is in blocks (64 words), `bw` in
// units of 64 pixels.
addr32 :: proc(bp, bw: u32, x, y: u32, z: bool) -> u32 {
	page := (y >> 5) * max(bw, 1) + (x >> 6)
	block := z ? BLOCKZ32[(y >> 3) & 3][(x >> 3) & 7] : BLOCK32[(y >> 3) & 3][(x >> 3) & 7]
	return (bp * 64 + page * 2048 + block * 64 + COLUMN32[y & 7][x & 7]) & (GS_MEM_WORDS - 1)
}

// Halfword address of a 16-bit pixel (pages are 64x64).
addr16 :: proc(bp, bw: u32, x, y: u32, psm: u32) -> u32 {
	page := (y >> 6) * max(bw, 1) + (x >> 6)
	by, bx := (y >> 3) & 7, (x >> 4) & 3
	block: u32
	switch psm {
	case PSMCT16S: block = BLOCK16S[by][bx]
	case PSMZ16: block = BLOCKZ16[by][bx]
	case PSMZ16S: block = BLOCKZ16S[by][bx]
	case: block = BLOCK16[by][bx]
	}
	return (bp * 128 + page * 4096 + block * 128 + COLUMN16[y & 7][x & 15]) & (GS_MEM_WORDS * 2 - 1)
}

// Byte address of an 8-bit texel (pages are 128x64, blocks 16x16).
addr8 :: proc(bp, bw: u32, x, y: u32) -> u32 {
	page := (y >> 6) * max(bw >> 1, 1) + (x >> 7)
	block := BLOCK8[(y >> 4) & 3][(x >> 4) & 7]
	// The byte order inside a block is an approximation of the hardware's
	// column interleave: 8-bit data round-trips correctly, but reading it
	// back through another format does not yet match the real GS.
	col := (y >> 2) & 3
	cy, cx := y & 3, x & 15
	off := col * 64 + ((cy & 1) * 4 + ((cx & 7) >> 1) * 8 + (cx >> 3) * 2 + (cx & 1) + (cy >> 1) * 32)
	if col & 1 != 0 {
		off ~= 4 // odd columns swap halves
	}
	return (bp * 256 + page * 8192 + block * 256 + off) & (GS_MEM_WORDS * 4 - 1)
}

// Nibble address of a 4-bit texel (pages 128x128, blocks 32x16).
addr4 :: proc(bp, bw: u32, x, y: u32) -> u32 {
	page := (y >> 7) * max(bw >> 1, 1) + (x >> 7)
	block := BLOCK4[(y >> 4) & 7][(x >> 5) & 3]
	off := ((y & 15) * 32 + (x & 31)) // linear inside the block (approximate, as for 8-bit)
	return (bp * 512 + page * 16384 + block * 512 + off) & (GS_MEM_WORDS * 8 - 1)
}

// --- pixel access -----------------------------------------------------------

gs_read_pixel :: proc(g: ^Gs, bp, bw, psm: u32, x, y: u32) -> u32 {
	switch psm {
	case PSMCT32, PSMZ32: return g.mem[addr32(bp, bw, x, y, psm == PSMZ32)]
	case PSMCT24, PSMZ24: return g.mem[addr32(bp, bw, x, y, psm == PSMZ24)] & 0xFF_FFFF
	case PSMCT16, PSMCT16S, PSMZ16, PSMZ16S:
		a := addr16(bp, bw, x, y, psm)
		return (g.mem[a >> 1] >> ((a & 1) * 16)) & 0xFFFF
	case PSMT8:
		a := addr8(bp, bw, x, y)
		return (g.mem[a >> 2] >> ((a & 3) * 8)) & 0xFF
	case PSMT4:
		a := addr4(bp, bw, x, y)
		return (g.mem[a >> 3] >> ((a & 7) * 4)) & 0xF
	case PSMT8H: return g.mem[addr32(bp, bw, x, y, false)] >> 24
	case PSMT4HL: return (g.mem[addr32(bp, bw, x, y, false)] >> 24) & 0xF
	case PSMT4HH: return g.mem[addr32(bp, bw, x, y, false)] >> 28
	}
	return 0
}

gs_write_pixel :: proc(g: ^Gs, bp, bw, psm: u32, x, y: u32, v: u32, mask: u32 = 0) {
	switch psm {
	case PSMCT32, PSMZ32:
		a := addr32(bp, bw, x, y, psm == PSMZ32)
		g.mem[a] = (g.mem[a] & mask) | (v & ~mask)
	case PSMCT24, PSMZ24:
		a := addr32(bp, bw, x, y, psm == PSMZ24)
		m := mask | 0xFF00_0000
		g.mem[a] = (g.mem[a] & m) | (v & ~m)
	case PSMCT16, PSMCT16S, PSMZ16, PSMZ16S:
		a := addr16(bp, bw, x, y, psm)
		shift := (a & 1) * 16
		m := (u32(0xFFFF) & ~mask) << shift
		g.mem[a >> 1] = (g.mem[a >> 1] & ~m) | ((v << shift) & m)
	case PSMT8:
		a := addr8(bp, bw, x, y)
		shift := (a & 3) * 8
		g.mem[a >> 2] = (g.mem[a >> 2] & ~(u32(0xFF) << shift)) | (v & 0xFF) << shift
	case PSMT4:
		a := addr4(bp, bw, x, y)
		shift := (a & 7) * 4
		g.mem[a >> 3] = (g.mem[a >> 3] & ~(u32(0xF) << shift)) | (v & 0xF) << shift
	case PSMT8H:
		a := addr32(bp, bw, x, y, false)
		g.mem[a] = (g.mem[a] & 0x00FF_FFFF) | (v & 0xFF) << 24
	case PSMT4HL:
		a := addr32(bp, bw, x, y, false)
		g.mem[a] = (g.mem[a] & ~u32(0x0F00_0000)) | (v & 0xF) << 24
	case PSMT4HH:
		a := addr32(bp, bw, x, y, false)
		g.mem[a] = (g.mem[a] & ~u32(0xF000_0000)) | (v & 0xF) << 28
	}
}

// 16-bit 1:5:5:5 colour to 32-bit RGBA (alpha from TEXA when sampling).
rgba16_to_32 :: #force_inline proc(c: u32, ta0, ta1: u32, aem: bool) -> u32 {
	r := (c & 0x1F) << 3
	g := ((c >> 5) & 0x1F) << 3
	b := ((c >> 10) & 0x1F) << 3
	a := c & 0x8000 != 0 ? ta1 : ta0
	if aem && c & 0x7FFF == 0 {
		a = 0
	}
	return r | g << 8 | b << 16 | a << 24
}

rgba32_to_16 :: #force_inline proc(c: u32) -> u32 {
	return (c >> 3) & 0x1F | ((c >> 11) & 0x1F) << 5 | ((c >> 19) & 0x1F) << 10 | (c >> 31) << 15
}
