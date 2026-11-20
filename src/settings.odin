package zemu

// User settings, saved as "key = value" lines in zemu.cfg.

import "core:fmt"
import "core:strconv"
import "core:strings"
import sdl "vendor:sdl3"

Settings :: struct {
	// Video
	scale_mode:    Scale_Mode,
	video_filter:  bool, // bilinear instead of nearest
	fullscreen:    bool,
	vsync:         bool,
	show_fps:      bool,
	// Sound
	mute:          bool,
	// Input
	keys:          [NUM_BUTTONS]sdl.Scancode,
	stick_as_dpad: bool,
	touch_opacity: int, // percent, mobile on-screen pad
	// GUI
	snow:          bool,
	gui_color:     [3]u8, // window colour, like ZSNES' GUI OPTS colour sliders
	ui_override:   UI_Override,
	// Paths / state
	last_dir:      string,
	last_core:     string,
	recent:        [dynamic]string, // recently played: "core_path|game_path"
}

UI_Override :: enum u8 {
	Auto,
	Desktop,
	Touch,
}

settings: Settings

settings_defaults :: proc() {
	settings.scale_mode    = .Aspect
	settings.video_filter  = false
	settings.vsync         = true
	settings.keys          = DEFAULT_KEYS
	settings.stick_as_dpad = true
	settings.touch_opacity = 60
	settings.snow          = true
	settings.gui_color     = {40, 56, 160}
}

settings_load :: proc() {
	settings_defaults()
	m := parse_kv_file(paths.config)
	defer free_kv_map(&m)

	get_bool :: proc(m: map[string]string, key: string, dst: ^bool) {
		if v, ok := m[key]; ok do dst^ = v == "true" || v == "1"
	}
	get_int :: proc(m: map[string]string, key: string) -> (int, bool) {
		if v, ok := m[key]; ok do return strconv.parse_int(v)
		return 0, false
	}

	if v, ok := get_int(m, "scale_mode"); ok do settings.scale_mode = Scale_Mode(clamp(v, 0, len(Scale_Mode) - 1))
	if v, ok := get_int(m, "ui"); ok do settings.ui_override = UI_Override(clamp(v, 0, len(UI_Override) - 1))
	if v, ok := get_int(m, "touch_opacity"); ok do settings.touch_opacity = clamp(v, 0, 100)
	get_bool(m, "video_filter", &settings.video_filter)
	get_bool(m, "fullscreen", &settings.fullscreen)
	get_bool(m, "vsync", &settings.vsync)
	get_bool(m, "show_fps", &settings.show_fps)
	get_bool(m, "mute", &settings.mute)
	get_bool(m, "stick_as_dpad", &settings.stick_as_dpad)
	get_bool(m, "snow", &settings.snow)
	if v, ok := m["gui_color"]; ok {
		s := v
		i := 0
		for part in strings.split_iterator(&s, ",") {
			if i >= 3 do break
			n, _ := strconv.parse_int(strings.trim_space(part))
			settings.gui_color[i] = u8(clamp(n, 0, 255))
			i += 1
		}
	}
	for name, b in BUTTON_NAMES {
		if v, ok := m[fmt.tprintf("key_%s", name)]; ok {
			settings.keys[b] = sdl.GetScancodeFromName(tcstr(v))
		}
	}
	if v, ok := m["last_dir"]; ok do settings.last_dir = strings.clone(v)
	if v, ok := m["last_core"]; ok do settings.last_core = strings.clone(v)
	for i in 0 ..< MAX_RECENT {
		if v, ok := m[fmt.tprintf("recent_%d", i)]; ok do append(&settings.recent, strings.clone(v))
	}
}

MAX_RECENT :: 10

settings_save :: proc() {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "scale_mode = %d\n", int(settings.scale_mode))
	fmt.sbprintf(&b, "ui = %d\n", int(settings.ui_override))
	fmt.sbprintf(&b, "touch_opacity = %d\n", settings.touch_opacity)
	fmt.sbprintf(&b, "video_filter = %v\n", settings.video_filter)
	fmt.sbprintf(&b, "fullscreen = %v\n", settings.fullscreen)
	fmt.sbprintf(&b, "vsync = %v\n", settings.vsync)
	fmt.sbprintf(&b, "show_fps = %v\n", settings.show_fps)
	fmt.sbprintf(&b, "mute = %v\n", settings.mute)
	fmt.sbprintf(&b, "stick_as_dpad = %v\n", settings.stick_as_dpad)
	fmt.sbprintf(&b, "snow = %v\n", settings.snow)
	fmt.sbprintf(&b, "gui_color = %d,%d,%d\n", settings.gui_color[0], settings.gui_color[1], settings.gui_color[2])
	for name, i in BUTTON_NAMES {
		sc := settings.keys[i]
		fmt.sbprintf(&b, "key_%s = %s\n", name, sdl.GetScancodeName(sc) if sc != .UNKNOWN else "")
	}
	fmt.sbprintf(&b, "last_dir = %s\n", settings.last_dir)
	fmt.sbprintf(&b, "last_core = %s\n", settings.last_core)
	for r, i in settings.recent {
		fmt.sbprintf(&b, "recent_%d = %s\n", i, r)
	}
	_ = write_file(paths.config, b.buf[:])
}

set_last_dir :: proc(dir: string) {
	delete(settings.last_dir)
	settings.last_dir = strings.clone(dir)
}

set_last_core :: proc(path: string) {
	delete(settings.last_core)
	settings.last_core = strings.clone(path)
}

recent_add :: proc(core_path, game_path: string) {
	entry := fmt.tprintf("%s|%s", core_path, game_path)
	// One entry per game, remembering the core it was last played with.
	for i := len(settings.recent) - 1; i >= 0; i -= 1 {
		if _, gp := split_recent(settings.recent[i]); gp == game_path {
			delete(settings.recent[i])
			ordered_remove(&settings.recent, i)
		}
	}
	inject_at(&settings.recent, 0, strings.clone(entry))
	for len(settings.recent) > MAX_RECENT {
		delete(pop(&settings.recent))
	}
}
