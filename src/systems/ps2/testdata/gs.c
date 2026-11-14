// GS test: sets up a 640x448 display, then draws through GIF DMA a clear,
// a Gouraud triangle, a texture upload with a textured sprite and an
// alpha-blended sprite. The Odin test checks pixels in the result.
#include <stdint.h>

#define GS_REG(a) (*(volatile uint64_t *)(0xB2000000 + (a)))
#define PMODE    GS_REG(0x0000)
#define SMODE2   GS_REG(0x0020)
#define DISPFB2  GS_REG(0x0090)
#define DISPLAY2 GS_REG(0x00A0)
#define BGCOLOR  GS_REG(0x00E0)
#define D2_CHCR (*(volatile uint32_t *)0xB000A000)
#define D2_MADR (*(volatile uint32_t *)0xB000A010)
#define D2_QWC  (*(volatile uint32_t *)0xB000A020)

static uint64_t packet[512] __attribute__((aligned(16)));
static int n;

static void q(uint64_t lo, uint64_t hi) { packet[n++] = lo; packet[n++] = hi; }
static void ad(int reg, uint64_t v) { q(v, (uint64_t)reg); }
static uint64_t giftag(int nloop, int eop, int flg, int nreg, uint64_t regs_dummy) {
	(void)regs_dummy;
	return (uint64_t)nloop | (uint64_t)eop << 15 | (uint64_t)flg << 58 | (uint64_t)nreg << 60;
}
static void begin_ad(int count) { q(giftag(count, 1, 0, 1, 0), 0xE); }
static uint64_t xyz(int x, int y, uint32_t z) { return (uint64_t)(x << 4) | (uint64_t)(y << 4) << 16 | (uint64_t)z << 32; }
static uint64_t rgba(int r, int g, int b, int a) { return r | g << 8 | b << 16 | (uint64_t)a << 24 | (uint64_t)0x3F800000 << 32; }

static void kick(void) {
	__asm__ volatile("sync" ::: "memory"); // packet stores must land before DMA starts
	D2_MADR = (uint32_t)(uintptr_t)packet;
	D2_QWC = n / 2;
	D2_CHCR = 0x101;
	n = 0;
}

static void putc_(char c) { *(volatile uint8_t *)0xB000F180 = (uint8_t)c; }

int run(void) {
	SMODE2 = 1;
	PMODE = 0xFF62; // circuit 2 on
	DISPFB2 = 0 | (10 << 9) | (0 << 15);
	DISPLAY2 = (uint64_t)(2559) << 32 | (uint64_t)(447) << 44 | (3 << 23);

	begin_ad(12);
	ad(0x4C, 0 | (10 << 16) | (0ull << 24)); // FRAME_1: FBP 0, 640 wide, CT32
	ad(0x4E, 150 | (0ull << 24));             // ZBUF_1: Z32 after the frame
	ad(0x18, 0);                              // XYOFFSET_1
	ad(0x40, (639ull << 16) | (447ull << 48)); // SCISSOR_1: 0-639 x 0-447
	ad(0x47, (1ull << 16) | (1ull << 17));    // TEST_1: ZTE, always pass
	ad(0x1A, 1);                              // PRMODECONT
	ad(0x46, 1);                              // COLCLAMP
	ad(0x00, 6);                              // PRIM: sprite
	ad(0x01, rgba(16, 32, 64, 128));
	ad(0x05, xyz(0, 0, 0));
	ad(0x05, xyz(640, 448, 0));
	ad(0x3F, 0);                              // TEXFLUSH
	kick();

	// Gouraud triangle: red, green, blue corners
	begin_ad(7);
	ad(0x00, 3 | (1 << 3));
	ad(0x01, rgba(255, 0, 0, 128));
	ad(0x05, xyz(100, 50, 10));
	ad(0x01, rgba(0, 255, 0, 128));
	ad(0x05, xyz(300, 50, 10));
	ad(0x01, rgba(0, 0, 255, 128));
	ad(0x05, xyz(100, 250, 10));
	kick();

	// Upload a 16x16 checkerboard (white / magenta) at block 0x2000
	begin_ad(4);
	ad(0x50, (uint64_t)0x2000 << 32 | (uint64_t)1 << 48 | (uint64_t)0 << 56);
	ad(0x51, 0);
	ad(0x52, 16 | (uint64_t)16 << 32);
	ad(0x53, 0);
	q(giftag(16 * 16 / 4, 1, 2, 0, 0), 0);
	for (int y = 0; y < 16; y++)
		for (int x = 0; x < 16; x += 4) {
			uint32_t px[4];
			for (int k = 0; k < 4; k++)
				px[k] = (((x + k) / 4 + y / 4) & 1) ? 0x80FF00FF : 0x80FFFFFF;
			q(px[0] | (uint64_t)px[1] << 32, px[2] | (uint64_t)px[3] << 32);
		}
	kick();

	// Textured sprite (decal), 64x64 on screen from the 16x16 texture
	begin_ad(6);
	ad(0x06, 0x2000 | (1ull << 14) | (0ull << 20) | (4ull << 26) | (4ull << 30) | (1ull << 34) | (1ull << 35));
	ad(0x00, 6 | (1 << 4) | (1 << 8));
	ad(0x03, 0);
	ad(0x05, xyz(400, 100, 20));
	ad(0x03, (16 << 4) | ((uint64_t)(16 << 4) << 16));
	ad(0x05, xyz(464, 164, 20));
	kick();

	// Half-transparent white sprite over the top half of the triangle area
	begin_ad(5);
	ad(0x42, 0 | (1 << 2) | (0 << 4) | (1 << 6)); // (Cs - Cd) * As >> 7 + Cd
	ad(0x00, 6 | (1 << 6));
	ad(0x01, rgba(255, 255, 255, 64));
	ad(0x05, xyz(20, 300, 30));
	ad(0x05, xyz(60, 340, 30));
	kick();

	putc_('O'); putc_('K'); putc_('\n');
	return 0;
}
