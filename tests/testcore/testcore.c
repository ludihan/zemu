// A tiny libretro core for testing frontends: no content needed, draws an
// animated gradient with a square you move with the d-pad, beeps on A.
// Build (desktop):  cc -O2 -shared -fPIC -o testcore_libretro.so testcore.c
// Build (web):      emcc -O2 -fPIC -sSIDE_MODULE=1 -o testcore_libretro.wasm testcore.c

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <math.h>

#define RETRO_API_VERSION 1
#define RETRO_DEVICE_JOYPAD 1
#define RETRO_ENVIRONMENT_SET_PIXEL_FORMAT 10
#define RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME 18
#define RETRO_PIXEL_FORMAT_XRGB8888 1

struct retro_system_info { const char *library_name, *library_version, *valid_extensions; bool need_fullpath, block_extract; };
struct retro_game_geometry { unsigned base_width, base_height, max_width, max_height; float aspect_ratio; };
struct retro_system_timing { double fps, sample_rate; };
struct retro_system_av_info { struct retro_game_geometry geometry; struct retro_system_timing timing; };
struct retro_game_info { const char *path; const void *data; size_t size; const char *meta; };

typedef bool (*retro_environment_t)(unsigned cmd, void *data);
typedef void (*retro_video_refresh_t)(const void *data, unsigned width, unsigned height, size_t pitch);
typedef void (*retro_audio_sample_t)(int16_t left, int16_t right);
typedef size_t (*retro_audio_sample_batch_t)(const int16_t *data, size_t frames);
typedef void (*retro_input_poll_t)(void);
typedef int16_t (*retro_input_state_t)(unsigned port, unsigned device, unsigned index, unsigned id);

#define W 256
#define H 224
#define RATE 44100

static retro_environment_t env_cb;
static retro_video_refresh_t video_cb;
static retro_audio_sample_batch_t audio_cb;
static retro_input_poll_t poll_cb;
static retro_input_state_t input_cb;
static uint32_t fb[W * H];
static int frame, px = W / 2, py = H / 2;
static double phase;

void retro_set_environment(retro_environment_t cb) {
	env_cb = cb;
	bool yes = true;
	cb(RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME, &yes);
}
void retro_set_video_refresh(retro_video_refresh_t cb) { video_cb = cb; }
void retro_set_audio_sample(retro_audio_sample_t cb) { (void)cb; }
void retro_set_audio_sample_batch(retro_audio_sample_batch_t cb) { audio_cb = cb; }
void retro_set_input_poll(retro_input_poll_t cb) { poll_cb = cb; }
void retro_set_input_state(retro_input_state_t cb) { input_cb = cb; }

void retro_init(void) {}
void retro_deinit(void) {}
unsigned retro_api_version(void) { return RETRO_API_VERSION; }

void retro_get_system_info(struct retro_system_info *info) {
	memset(info, 0, sizeof(*info));
	info->library_name = "ZEMU Test Core";
	info->library_version = "1.0";
	info->valid_extensions = "";
}

void retro_get_system_av_info(struct retro_system_av_info *info) {
	info->geometry = (struct retro_game_geometry){W, H, W, H, 4.0f / 3.0f};
	info->timing = (struct retro_system_timing){60.0, RATE};
}

void retro_set_controller_port_device(unsigned port, unsigned device) { (void)port; (void)device; }
void retro_reset(void) { px = W / 2; py = H / 2; }

void retro_run(void) {
	poll_cb();
	if (input_cb(0, RETRO_DEVICE_JOYPAD, 0, 4)) py -= 2; // up
	if (input_cb(0, RETRO_DEVICE_JOYPAD, 0, 5)) py += 2; // down
	if (input_cb(0, RETRO_DEVICE_JOYPAD, 0, 6)) px -= 2; // left
	if (input_cb(0, RETRO_DEVICE_JOYPAD, 0, 7)) px += 2; // right
	px = px < 8 ? 8 : px > W - 8 ? W - 8 : px;
	py = py < 8 ? 8 : py > H - 8 ? H - 8 : py;
	bool beep = input_cb(0, RETRO_DEVICE_JOYPAD, 0, 8); // A

	for (int y = 0; y < H; y++) {
		for (int x = 0; x < W; x++) {
			uint32_t r = (x + frame) & 255, g = (y * 2 + frame / 2) & 255, b = 160;
			fb[y * W + x] = (r << 16) | (g << 8) | b;
		}
	}
	for (int y = py - 8; y < py + 8; y++)
		for (int x = px - 8; x < px + 8; x++)
			fb[y * W + x] = beep ? 0xFFFF40 : 0xFFFFFF;
	video_cb(fb, W, H, W * sizeof(uint32_t));

	static int16_t samples[RATE / 60 * 2];
	for (int i = 0; i < RATE / 60; i++) {
		int16_t s = beep ? (int16_t)(sin(phase) * 6000) : 0;
		phase += 2 * 3.14159265 * 440.0 / RATE;
		samples[i * 2] = samples[i * 2 + 1] = s;
	}
	audio_cb(samples, RATE / 60);
	frame++;
}

size_t retro_serialize_size(void) { return sizeof(int) * 3; }
bool retro_serialize(void *data, size_t size) {
	if (size < retro_serialize_size()) return false;
	int *d = data; d[0] = frame; d[1] = px; d[2] = py;
	return true;
}
bool retro_unserialize(const void *data, size_t size) {
	if (size < retro_serialize_size()) return false;
	const int *d = data; frame = d[0]; px = d[1]; py = d[2];
	return true;
}
void retro_cheat_reset(void) {}
void retro_cheat_set(unsigned index, bool enabled, const char *code) { (void)index; (void)enabled; (void)code; }

bool retro_load_game(const struct retro_game_info *game) {
	(void)game;
	int fmt = RETRO_PIXEL_FORMAT_XRGB8888;
	return env_cb(RETRO_ENVIRONMENT_SET_PIXEL_FORMAT, &fmt);
}
bool retro_load_game_special(unsigned type, const struct retro_game_info *info, size_t num) { (void)type; (void)info; (void)num; return false; }
void retro_unload_game(void) {}
unsigned retro_get_region(void) { return 0; }
void *retro_get_memory_data(unsigned id) { (void)id; return NULL; }
size_t retro_get_memory_size(unsigned id) { (void)id; return 0; }
