// EE CPU test program. Built twice: for the PS2 (see build.sh) and natively;
// both builds must print exactly the same text.
#include <stdint.h>

#ifdef HOST
#include <stdio.h>
static void out(char c) { putchar(c); }
#else
static void out(char c) { *(volatile uint8_t *)0xB000F180 = (uint8_t)c; }
#endif

static void puts_(const char *s) { while (*s) out(*s++); }

static void hex(uint64_t v) {
	for (int i = 60; i >= 0; i -= 4) out("0123456789abcdef"[(v >> i) & 15]);
	out('\n');
}

static uint32_t crc32(const uint8_t *p, int n) {
	uint32_t c = 0xFFFFFFFFu;
	for (int i = 0; i < n; i++) {
		c ^= p[i];
		for (int k = 0; k < 8; k++) c = (c >> 1) ^ (0xEDB88320u & -(c & 1));
	}
	return ~c;
}

static void sort(int32_t *a, int n) {
	for (int i = 1; i < n; i++) {
		int32_t v = a[i];
		int j = i - 1;
		while (j >= 0 && a[j] > v) { a[j + 1] = a[j]; j--; }
		a[j + 1] = v;
	}
}

struct __attribute__((packed)) unaligned { uint8_t pad; uint32_t w; uint64_t d; };

static volatile int32_t vol_a = -123456789, vol_b = 1000;
static volatile uint64_t vol_c = 0x8000000000000001ull;
static volatile struct unaligned un = {1, 0xDEADBEEF, 0x0123456789ABCDEFull};

int run(void) {
	uint8_t buf[256];
	for (int i = 0; i < 256; i++) buf[i] = (uint8_t)(i * 7 + 3);
	hex(crc32(buf, 256));

	int32_t a = vol_a, b = vol_b;
	hex((uint64_t)(int64_t)(a / b));
	hex((uint64_t)(int64_t)(a % b));
	hex((uint64_t)((uint32_t)a / (uint32_t)b));
	hex((uint64_t)(int64_t)a * (uint64_t)(int64_t)b);
	hex((uint64_t)((int64_t)a >> 7));
	hex((uint64_t)((uint32_t)a >> 7));

	uint64_t c = vol_c;
	hex(c + 0xFFFFFFFFull);
	hex(c << 33);
	hex(c >> 17);
	hex((uint64_t)((int64_t)c >> 40));
	hex(c * 3);
	hex((uint64_t)((int64_t)c < 0));

	hex(un.w);
	hex(un.d);
	un.w = 0x11223344;
	un.d = 0x5566778899AABBCCull;
	hex(un.w ^ (uint32_t)un.d);

	int32_t arr[16];
	uint32_t seed = 12345;
	for (int i = 0; i < 16; i++) { seed = seed * 1103515245u + 12345u; arr[i] = (int32_t)(seed >> 8) - 4000000; }
	sort(arr, 16);
	uint64_t sum = 0;
	for (int i = 0; i < 16; i++) sum = sum * 31 + (uint32_t)arr[i];
	hex(sum);

	puts_("PASS\n");
	return 0;
}

#ifdef HOST
int main(void) { return run(); }
#endif
