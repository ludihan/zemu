package zemu

// The environment callback: how cores ask the frontend for things.

import "core:c"
import "core:fmt"
import "core:strings"
import retro "libretro"

environment_cb :: proc "c" (cmd: c.uint, data: rawptr) -> bool {
	context = app_ctx

	switch cmd {
	case retro.ENVIRONMENT_GET_CAN_DUPE:
		(^bool)(data)^ = true
		return true

	case retro.ENVIRONMENT_GET_OVERSCAN:
		(^bool)(data)^ = false
		return true

	case retro.ENVIRONMENT_SET_ROTATION:
		core.rotation = int((^c.uint)(data)^) % 4
		return true

	case retro.ENVIRONMENT_SET_MESSAGE:
		msg := (^retro.Message)(data)
		osd_message(string(msg.msg), f32(msg.frames) / 60)
		return true

	case retro.ENVIRONMENT_SET_MESSAGE_EXT:
		msg := (^retro.Message_Ext)(data)
		osd_message(string(msg.msg), f32(msg.duration) / 1000)
		return true

	case retro.ENVIRONMENT_GET_MESSAGE_INTERFACE_VERSION:
		(^c.uint)(data)^ = 1
		return true

	case retro.ENVIRONMENT_SHUTDOWN:
		core.shutdown_requested = true
		return true

	case retro.ENVIRONMENT_SET_PERFORMANCE_LEVEL:
		return true

	case retro.ENVIRONMENT_GET_SYSTEM_DIRECTORY, retro.ENVIRONMENT_GET_CORE_ASSETS_DIRECTORY:
		(^cstring)(data)^ = core.system_dir_c
		return true

	case retro.ENVIRONMENT_GET_SAVE_DIRECTORY:
		(^cstring)(data)^ = core.save_dir_c
		return true

	case retro.ENVIRONMENT_GET_LIBRETRO_PATH:
		(^cstring)(data)^ = core.core_path_c
		return true

	case retro.ENVIRONMENT_GET_USERNAME:
		(^cstring)(data)^ = "ZEMU"
		return true

	case retro.ENVIRONMENT_GET_LANGUAGE:
		(^retro.Language)(data)^ = .ENGLISH
		return true

	case retro.ENVIRONMENT_SET_PIXEL_FORMAT:
		f := (^retro.Pixel_Format)(data)^
		if f < .XRGB1555 || f > .RGB565 do return false
		core.pixel_format = f
		return true

	case retro.ENVIRONMENT_SET_INPUT_DESCRIPTORS, retro.ENVIRONMENT_SET_CONTROLLER_INFO,
	     retro.ENVIRONMENT_SET_SUBSYSTEM_INFO, retro.ENVIRONMENT_SET_MEMORY_MAPS,
	     retro.ENVIRONMENT_SET_SUPPORT_ACHIEVEMENTS, retro.ENVIRONMENT_SET_SERIALIZATION_QUIRKS,
	     retro.ENVIRONMENT_SET_CONTENT_INFO_OVERRIDE, retro.ENVIRONMENT_SET_MINIMUM_AUDIO_LATENCY:
		return true

	case retro.ENVIRONMENT_SET_SUPPORT_NO_GAME:
		core.support_no_game = (^bool)(data)^
		return true

	case retro.ENVIRONMENT_SET_FRAME_TIME_CALLBACK:
		core.frame_time_cb = (^retro.Frame_Time_Callback)(data)^
		return true

	case retro.ENVIRONMENT_SET_SYSTEM_AV_INFO:
		core.av_info = (^retro.System_AV_Info)(data)^
		if core.game_loaded {
			audio_open(core.av_info.timing.sample_rate)
			timing_reset()
		}
		video_reset()
		return true

	case retro.ENVIRONMENT_SET_GEOMETRY:
		g := (^retro.Game_Geometry)(data)^
		core.av_info.geometry.base_width   = g.base_width
		core.av_info.geometry.base_height  = g.base_height
		core.av_info.geometry.aspect_ratio = g.aspect_ratio
		return true

	case retro.ENVIRONMENT_GET_INPUT_BITMASKS:
		return true

	case retro.ENVIRONMENT_GET_INPUT_MAX_USERS:
		(^c.uint)(data)^ = MAX_PORTS
		return true

	case retro.ENVIRONMENT_GET_INPUT_DEVICE_CAPABILITIES:
		(^u64)(data)^ = (1 << u64(retro.Device.JOYPAD)) | (1 << u64(retro.Device.ANALOG))
		return true

	case retro.ENVIRONMENT_GET_RUMBLE_INTERFACE:
		(^retro.Rumble_Interface)(data)^ = {set_rumble_state = rumble_cb}
		return true

	case retro.ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE:
		if data != nil do (^c.int)(data)^ = 3 // video | audio
		return true

	case retro.ENVIRONMENT_GET_FASTFORWARDING:
		if data != nil do (^bool)(data)^ = timing.fast_forward
		return true

	case retro.ENVIRONMENT_GET_TARGET_REFRESH_RATE:
		(^f32)(data)^ = 60
		return true

	case retro.ENVIRONMENT_GET_THROTTLE_STATE:
		// struct retro_throttle_state { unsigned mode; float rate; }
		Throttle :: struct { mode: c.uint, rate: f32 }
		t := (^Throttle)(data)
		t.mode = 2 if timing.fast_forward else 0 // FAST_FORWARD / NONE
		t.rate = f32(core.av_info.timing.fps)
		return true

	// --- Core options ---
	case retro.ENVIRONMENT_GET_CORE_OPTIONS_VERSION:
		(^c.uint)(data)^ = 2
		return true

	case retro.ENVIRONMENT_SET_VARIABLES:
		env_set_variables((^retro.Variable)(data))
		return true

	case retro.ENVIRONMENT_SET_CORE_OPTIONS:
		env_set_core_options_v1(([^]retro.Core_Option_Definition)(data))
		return true

	case retro.ENVIRONMENT_SET_CORE_OPTIONS_INTL:
		intl := (^retro.Core_Options_Intl)(data)
		env_set_core_options_v1(intl.us)
		return true

	case retro.ENVIRONMENT_SET_CORE_OPTIONS_V2:
		if data != nil do env_set_core_options_v2((^retro.Core_Options_V2)(data))
		return true

	case retro.ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL:
		intl := (^retro.Core_Options_V2_Intl)(data)
		if intl.us != nil do env_set_core_options_v2(intl.us)
		return true

	case retro.ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY:
		d := (^retro.Core_Option_Display)(data)
		if d != nil && d.key != nil {
			if o := core_option_find(string(d.key)); o != nil do o.visible = d.visible
		}
		return true

	case retro.ENVIRONMENT_SET_CORE_OPTIONS_UPDATE_DISPLAY_CALLBACK:
		return false

	case retro.ENVIRONMENT_GET_VARIABLE:
		v := (^retro.Variable)(data)
		if v == nil || v.key == nil do return false
		o := core_option_find(string(v.key))
		if o == nil || len(o.values) == 0 {
			v.value = nil
			return false
		}
		v.value = o.values[o.current].value
		return true

	case retro.ENVIRONMENT_SET_VARIABLE:
		if data == nil do return true // query: supported
		v := (^retro.Variable)(data)
		o := core_option_find(string(v.key))
		if o == nil do return false
		for val, i in o.values {
			if string(val.value) == string(v.value) {
				o.current = i
				core.options_updated = true
				return true
			}
		}
		return false

	case retro.ENVIRONMENT_GET_VARIABLE_UPDATE:
		(^bool)(data)^ = core.options_updated
		core.options_updated = false
		return true
	}

	return false
}

// Legacy SET_VARIABLES: { "key", "Description; value1|value2|value3" }, first value is default.
@(private="file")
env_set_variables :: proc(vars: ^retro.Variable) {
	for v := ([^]retro.Variable)(vars); v[0].key != nil; v = v[1:] {
		spec := string(v[0].value)
		semi := strings.index(spec, "; ")
		if semi < 0 do continue
		desc := spec[:semi]
		rest := spec[semi + 2:]
		values: [dynamic]Core_Option_Value
		values.allocator = context.temp_allocator
		for val in strings.split_iterator(&rest, "|") {
			append(&values, Core_Option_Value{value = strings.clone_to_cstring(val), label = strings.clone(val)})
		}
		default_ := string(values[0].value) if len(values) > 0 else ""
		core_option_add(string(v[0].key), desc, "", "", values[:], default_)
		if o := core_option_find(string(v[0].key)); o != nil do core_option_apply_saved(o)
	}
}

@(private="file")
collect_values :: proc(src: []retro.Core_Option_Value) -> []Core_Option_Value {
	values: [dynamic]Core_Option_Value
	values.allocator = context.temp_allocator
	for v in src {
		if v.value == nil do break
		label := v.label if v.label != nil else v.value
		append(&values, Core_Option_Value{value = strings.clone_to_cstring(string(v.value)), label = strings.clone(string(label))})
	}
	return values[:]
}

@(private="file")
env_set_core_options_v1 :: proc(defs: [^]retro.Core_Option_Definition) {
	if defs == nil do return
	for i := 0; defs[i].key != nil; i += 1 {
		d := &defs[i]
		core_option_add(string(d.key), string(d.desc), string(d.info), "", collect_values(d.values[:]), string(d.default_value))
		if o := core_option_find(string(d.key)); o != nil do core_option_apply_saved(o)
	}
}

@(private="file")
env_set_core_options_v2 :: proc(opts: ^retro.Core_Options_V2) {
	defs := opts.definitions
	if defs == nil do return
	for i := 0; defs[i].key != nil; i += 1 {
		d := &defs[i]
		core_option_add(string(d.key), string(d.desc), string(d.info), string(d.category_key),
			collect_values(d.values[:]), string(d.default_value))
		if o := core_option_find(string(d.key)); o != nil do core_option_apply_saved(o)
	}
}

_ :: fmt
