// Emscripten entry for the web build, plus the three functions Odin's js
// runtime imports from "odin_env" (normally provided by odin.js).

#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <unistd.h>
#include <emscripten.h>

extern void zemu_web_main(int argc, char **argv);

void odin_env_write(uint32_t fd, const uint8_t *data, size_t len) __asm__("odin_env..write");
void odin_env_write(uint32_t fd, const uint8_t *data, size_t len) {
	write(fd == 1 ? 1 : 2, data, len);
}

double odin_env_sin(double x) __asm__("odin_env..sin");
double odin_env_sin(double x) {
	return sin(x);
}

void odin_env_rand_bytes(uint8_t *buf, size_t len) __asm__("odin_env..rand_bytes");
void odin_env_rand_bytes(uint8_t *buf, size_t len) {
	EM_ASM({ crypto.getRandomValues(HEAPU8.subarray($0, $0 + $1)); }, buf, len);
}

// Arguments come from the page URL: index.html?arg=<core>&arg=<game>
int main(int argc, char **argv) {
	zemu_web_main(argc, argv);
	return 0;
}
