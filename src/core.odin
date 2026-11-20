package zemu

// Loading libretro cores and content, save RAM and save states.

import "core:c"
import "core:fmt"
import "core:strings"
import retro "libretro"

Core_Option_Value :: struct {
	value: cstring,
	label: string,
}

Core_Option :: struct {
	key:      cstring,
	desc:     string,
	info:     string,
	category: string,
	values:   [dynamic]Core_Option_Value,
	current:  int,
	default_: int,
	visible:  bool,
}

Core :: struct {
	lib:  Core_Library,
	api:  retro.Core_API,
	path: string,

	// From retro_get_system_info (cloned, the core's strings may move).
	name:          string,
	version:       string,
	extensions:    string, // "sfc|smc"
	need_fullpath: bool,
	block_extract: bool,

	av_info:      retro.System_AV_Info,
	pixel_format: retro.Pixel_Format,
	rotation:     int,

	support_no_game: bool,
	game_loaded:     bool,
	game_path:       string,
	game_data:       []byte,
	game_info:       retro.Game_Info,

	options:         [dynamic]Core_Option,
	options_updated: bool,

	frame_time_cb: retro.Frame_Time_Callback,
	shutdown_requested: bool,

	// Cstrings handed to the core must stay valid while it runs.
	system_dir_c: cstring,
	save_dir_c:   cstring,
	core_path_c:  cstring,
	game_path_c:  cstring,
}

core: Core
core_loaded: bool

core_load :: proc(path: string) -> bool {
	if core_loaded do core_unload()

	lib, api, ok := core_library_open(path)
	if !ok do return false

	if api.api_version() != retro.API_VERSION {
		osd_message("CORE HAS WRONG API VERSION")
		core_library_close(lib)
		return false
	}

	core = Core{lib = lib, api = api}
	core.path         = strings.clone(path)
	core.system_dir_c = strings.clone_to_cstring(paths.system)
	core.save_dir_c   = strings.clone_to_cstring(paths.saves)
	core.core_path_c  = strings.clone_to_cstring(path)
	core.pixel_format = .XRGB1555

	// System info is static, so read it first: the name keys the saved options,
	// which must be ready before the core declares its options.
	info: retro.System_Info
	core.api.get_system_info(&info)
	core.name          = strings.clone(string(info.library_name))
	core.version       = strings.clone(string(info.library_version))
	core.extensions    = strings.clone(string(info.valid_extensions))
	core.need_fullpath = info.need_fullpath
	core.block_extract = info.block_extract
	core_loaded = true
	core_options_load()

	core.api.set_environment(environment_cb)
	core.api.set_video_refresh(video_refresh_cb)
	core.api.set_audio_sample(audio_sample_cb)
	core.api.set_audio_sample_batch(audio_sample_batch_cb)
	core.api.set_input_poll(input_poll_cb)
	core.api.set_input_state(input_state_cb)
	core.api.init()
	fmt.printfln("loaded core %s %s (%s)", core.name, core.version, core.extensions)
	return true
}

core_unload :: proc() {
	if !core_loaded do return
	if core.game_loaded do core_unload_game()
	core_options_save()
	core.api.deinit()
	core_library_close(core.lib)

	delete(core.path); delete(core.name); delete(core.version); delete(core.extensions)
	delete(core.system_dir_c); delete(core.save_dir_c); delete(core.core_path_c)
	core_options_clear()
	core = {}
	core_loaded = false
}

// Does the loaded core accept files with this extension?
core_accepts :: proc(path: string) -> bool {
	if !core_loaded do return false
	ext := extension(path)
	exts := core.extensions
	for e in strings.split_iterator(&exts, "|") {
		if strings.equal_fold(e, ext) do return true
	}
	return false
}

core_load_game :: proc(path: string) -> bool {
	if !core_loaded do return false
	if core.game_loaded do core_unload_game()

	core.game_path   = strings.clone(path)
	core.game_path_c = strings.clone_to_cstring(path)
	core.game_info   = {path = core.game_path_c}

	if !core.need_fullpath {
		data, ok := read_file(path)
		if !ok {
			osd_message("COULD NOT READ FILE")
			delete(core.game_path); delete(core.game_path_c)
			return false
		}
		// Zipped content the core can't open itself: hand it the first file inside.
		if extension(path) == "zip" && !core_accepts(path) {
			if inner, ok2 := zip_extract_first(data); ok2 {
				delete(data)
				data = inner
			}
		}
		core.game_data      = data
		core.game_info.data = raw_data(data)
		core.game_info.size = c.size_t(len(data))
	}

	if !core.api.load_game(&core.game_info) {
		osd_message("CORE FAILED TO LOAD GAME")
		delete(core.game_data); delete(core.game_path); delete(core.game_path_c)
		core.game_data = nil; core.game_path = ""; core.game_path_c = nil
		return false
	}
	core_after_game_loaded()
	return true
}

// For cores that set SUPPORT_NO_GAME (e.g. 2048, game engines without content).
core_start_no_game :: proc() -> bool {
	if !core_loaded || !core.support_no_game do return false
	if core.game_loaded do core_unload_game()
	if !core.api.load_game(nil) do return false
	core.game_path = strings.clone(core.name)
	core_after_game_loaded()
	return true
}

@(private="file")
core_after_game_loaded :: proc() {
	core.game_loaded = true
	core.shutdown_requested = false
	app.paused = false
	core.api.get_system_av_info(&core.av_info)
	for port in 0 ..< MAX_PORTS {
		core.api.set_controller_port_device(c.uint(port), c.uint(retro.Device.JOYPAD))
	}
	sram_load()
	audio_open(core.av_info.timing.sample_rate)
	video_reset()
	timing_reset()
	osd_message(fmt.tprintf("%s LOADED", strings.to_upper(stem(core.game_path), context.temp_allocator)))
}

core_unload_game :: proc() {
	if !core.game_loaded do return
	sram_save()
	core.api.unload_game()
	audio_close()
	delete(core.game_data); delete(core.game_path)
	if core.game_path_c != nil do delete(core.game_path_c)
	core.game_data = nil; core.game_path = ""; core.game_path_c = nil
	core.game_loaded = false
	core.frame_time_cb = {}
	core.shutdown_requested = false
	app.paused = false
	video_reset()
	cheats_clear()
}

core_reset :: proc() {
	if core.game_loaded {
		core.api.reset()
		osd_message("GAME RESET")
	}
}

core_run_frame :: proc() {
	if core.frame_time_cb.callback != nil {
		core.frame_time_cb.callback(core.frame_time_cb.reference)
	}
	core.api.run()
	audio_flush_samples()
}

// --- Save RAM ---------------------------------------------------------------

game_file_path :: proc(dir, suffix: string) -> string {
	return join_path(dir, fmt.tprintf("%s%s", stem(core.game_path), suffix), context.temp_allocator)
}

sram_load :: proc() {
	size := int(core.api.get_memory_size(c.uint(retro.Memory.SAVE_RAM)))
	ptr := core.api.get_memory_data(c.uint(retro.Memory.SAVE_RAM))
	if size == 0 || ptr == nil do return
	data, ok := read_file(game_file_path(paths.saves, ".srm"), context.temp_allocator)
	if !ok do return
	copy(([^]byte)(ptr)[:size], data)
}

sram_save :: proc() {
	if !core.game_loaded do return
	size := int(core.api.get_memory_size(c.uint(retro.Memory.SAVE_RAM)))
	ptr := core.api.get_memory_data(c.uint(retro.Memory.SAVE_RAM))
	if size == 0 || ptr == nil do return
	_ = write_file(game_file_path(paths.saves, ".srm"), ([^]byte)(ptr)[:size])
}

// --- Save states ------------------------------------------------------------

state_slot: int

state_path :: proc(slot: int) -> string {
	return game_file_path(paths.states, fmt.tprintf(".zs%d", slot))
}

state_save :: proc(slot: int) -> bool {
	if !core.game_loaded do return false
	size := int(core.api.serialize_size())
	if size == 0 {
		osd_message("CORE DOES NOT SUPPORT SAVE STATES")
		return false
	}
	buf := make([]byte, size, context.temp_allocator)
	if !core.api.serialize(raw_data(buf), c.size_t(size)) || !write_file(state_path(slot), buf) {
		osd_message("STATE SAVE FAILED")
		return false
	}
	osd_message(fmt.tprintf("STATE %d SAVED", slot))
	return true
}

state_load :: proc(slot: int) -> bool {
	if !core.game_loaded do return false
	data, ok := read_file(state_path(slot), context.temp_allocator)
	if !ok {
		osd_message(fmt.tprintf("STATE %d NOT FOUND", slot))
		return false
	}
	if !core.api.unserialize(raw_data(data), c.size_t(len(data))) {
		osd_message("STATE LOAD FAILED")
		return false
	}
	osd_message(fmt.tprintf("STATE %d LOADED", slot))
	return true
}

state_exists :: proc(slot: int) -> bool {
	return core.game_loaded && file_exists(state_path(slot))
}

// --- Core options -----------------------------------------------------------

core_options_clear :: proc() {
	for &o in core.options {
		delete(o.key); delete(o.desc); delete(o.info); delete(o.category)
		for v in o.values {
			delete(v.value); delete(v.label)
		}
		delete(o.values)
	}
	delete(core.options)
	core.options = nil
}

core_option_find :: proc(key: string) -> ^Core_Option {
	for &o in core.options {
		if string(o.key) == key do return &o
	}
	return nil
}

core_option_add :: proc(key, desc, info, category: string, values: []Core_Option_Value, default_value: string) {
	if core_option_find(key) != nil {
		// Already declared: the values were cloned for us, so free them.
		for v in values {
			delete(v.value); delete(v.label)
		}
		return
	}
	o := Core_Option{
		key      = strings.clone_to_cstring(key),
		desc     = strings.clone(desc),
		info     = strings.clone(info),
		category = strings.clone(category),
		visible  = true,
	}
	for v, i in values {
		append(&o.values, v)
		if string(v.value) == default_value do o.default_ = i
	}
	o.current = o.default_
	append(&core.options, o)
}

core_option_set :: proc(o: ^Core_Option, index: int) {
	if len(o.values) == 0 do return
	o.current = (index %% len(o.values))
	core.options_updated = true
}

core_options_path :: proc() -> string {
	return join_path(paths.base, fmt.tprintf("%s.opt", core.name), context.temp_allocator)
}

// Option values are saved per core as "key = value" lines.
core_options_save :: proc() {
	if !core_loaded || len(core.options) == 0 do return
	b := strings.builder_make(context.temp_allocator)
	for o in core.options {
		if len(o.values) == 0 do continue
		fmt.sbprintf(&b, "%s = %s\n", o.key, o.values[o.current].value)
	}
	_ = write_file(core_options_path(), b.buf[:])
}

core_options_load :: proc() {
	free_kv_map(&saved_options)
	saved_options = parse_kv_file(core_options_path())
}

free_kv_map :: proc(m: ^map[string]string) {
	for k, v in m {
		delete(k); delete(v)
	}
	delete(m^)
	m^ = nil
}

// Options are declared by the core during retro_init/load_game, after we read the
// file, so saved values are applied as each option gets registered.
saved_options: map[string]string

core_option_apply_saved :: proc(o: ^Core_Option) {
	if v, ok := saved_options[string(o.key)]; ok {
		for val, i in o.values {
			if string(val.value) == v do o.current = i
		}
	}
}

parse_kv_file :: proc(path: string) -> map[string]string {
	m := make(map[string]string)
	data, ok := read_file(path, context.temp_allocator)
	if !ok do return m
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' || l[0] == ';' do continue
		eq := strings.index_byte(l, '=')
		if eq < 0 do continue
		k := strings.trim_space(l[:eq])
		v := strings.trim_space(l[eq + 1:])
		v = strings.trim(v, "\"")
		m[strings.clone(k)] = strings.clone(v)
	}
	return m
}
