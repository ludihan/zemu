// Bindings for the libretro API (libretro.h, API version 1).
// Only the parts a frontend needs are declared here.
package libretro

import "core:c"

API_VERSION :: 1

// ---------------------------------------------------------------------------
// Devices and input ids
// ---------------------------------------------------------------------------

DEVICE_TYPE_SHIFT :: 8
DEVICE_MASK       :: (1 << DEVICE_TYPE_SHIFT) - 1

Device :: enum c.uint {
	NONE     = 0,
	JOYPAD   = 1,
	MOUSE    = 2,
	KEYBOARD = 3,
	LIGHTGUN = 4,
	ANALOG   = 5,
	POINTER  = 6,
}

Joypad_Id :: enum c.uint {
	B      = 0,
	Y      = 1,
	SELECT = 2,
	START  = 3,
	UP     = 4,
	DOWN   = 5,
	LEFT   = 6,
	RIGHT  = 7,
	A      = 8,
	X      = 9,
	L      = 10,
	R      = 11,
	L2     = 12,
	R2     = 13,
	L3     = 14,
	R3     = 15,
}
DEVICE_ID_JOYPAD_MASK :: 256

DEVICE_INDEX_ANALOG_LEFT   :: 0
DEVICE_INDEX_ANALOG_RIGHT  :: 1
DEVICE_INDEX_ANALOG_BUTTON :: 2
DEVICE_ID_ANALOG_X         :: 0
DEVICE_ID_ANALOG_Y         :: 1

DEVICE_ID_POINTER_X       :: 0
DEVICE_ID_POINTER_Y       :: 1
DEVICE_ID_POINTER_PRESSED :: 2
DEVICE_ID_POINTER_COUNT   :: 3

// ---------------------------------------------------------------------------
// Misc enums
// ---------------------------------------------------------------------------

Region :: enum c.uint {
	NTSC = 0,
	PAL  = 1,
}

Memory :: enum c.uint {
	SAVE_RAM   = 0,
	RTC        = 1,
	SYSTEM_RAM = 2,
	VIDEO_RAM  = 3,
}

Pixel_Format :: enum c.int {
	XRGB1555 = 0, // 0RGB1555, native endian. Default if the core never sets one.
	XRGB8888 = 1,
	RGB565   = 2,
}

Language :: enum c.int {
	ENGLISH = 0,
}

Log_Level :: enum c.int {
	DEBUG = 0,
	INFO,
	WARN,
	ERROR,
}

Rumble_Effect :: enum c.int {
	STRONG = 0,
	WEAK   = 1,
}

// ---------------------------------------------------------------------------
// Environment commands
// ---------------------------------------------------------------------------

ENVIRONMENT_EXPERIMENTAL :: 0x10000
ENVIRONMENT_PRIVATE      :: 0x20000

ENVIRONMENT_SET_ROTATION                     :: 1
ENVIRONMENT_GET_OVERSCAN                     :: 2
ENVIRONMENT_GET_CAN_DUPE                     :: 3
ENVIRONMENT_SET_MESSAGE                      :: 6
ENVIRONMENT_SHUTDOWN                         :: 7
ENVIRONMENT_SET_PERFORMANCE_LEVEL            :: 8
ENVIRONMENT_GET_SYSTEM_DIRECTORY             :: 9
ENVIRONMENT_SET_PIXEL_FORMAT                 :: 10
ENVIRONMENT_SET_INPUT_DESCRIPTORS            :: 11
ENVIRONMENT_SET_KEYBOARD_CALLBACK            :: 12
ENVIRONMENT_SET_DISK_CONTROL_INTERFACE       :: 13
ENVIRONMENT_SET_HW_RENDER                    :: 14
ENVIRONMENT_GET_VARIABLE                     :: 15
ENVIRONMENT_SET_VARIABLES                    :: 16
ENVIRONMENT_GET_VARIABLE_UPDATE              :: 17
ENVIRONMENT_SET_SUPPORT_NO_GAME              :: 18
ENVIRONMENT_GET_LIBRETRO_PATH                :: 19
ENVIRONMENT_SET_FRAME_TIME_CALLBACK          :: 21
ENVIRONMENT_SET_AUDIO_CALLBACK               :: 22
ENVIRONMENT_GET_RUMBLE_INTERFACE             :: 23
ENVIRONMENT_GET_INPUT_DEVICE_CAPABILITIES    :: 24
ENVIRONMENT_GET_LOG_INTERFACE                :: 27
ENVIRONMENT_GET_PERF_INTERFACE               :: 28
ENVIRONMENT_GET_CORE_ASSETS_DIRECTORY        :: 30
ENVIRONMENT_GET_SAVE_DIRECTORY               :: 31
ENVIRONMENT_SET_SYSTEM_AV_INFO               :: 32
ENVIRONMENT_SET_PROC_ADDRESS_CALLBACK        :: 33
ENVIRONMENT_SET_SUBSYSTEM_INFO               :: 34
ENVIRONMENT_SET_CONTROLLER_INFO              :: 35
ENVIRONMENT_SET_MEMORY_MAPS                  :: 36 | ENVIRONMENT_EXPERIMENTAL
ENVIRONMENT_SET_GEOMETRY                     :: 37
ENVIRONMENT_GET_USERNAME                     :: 38
ENVIRONMENT_GET_LANGUAGE                     :: 39
ENVIRONMENT_SET_SUPPORT_ACHIEVEMENTS         :: 42 | ENVIRONMENT_EXPERIMENTAL
ENVIRONMENT_SET_SERIALIZATION_QUIRKS         :: 44
ENVIRONMENT_GET_VFS_INTERFACE                :: 45 | ENVIRONMENT_EXPERIMENTAL
ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE           :: 47 | ENVIRONMENT_EXPERIMENTAL
ENVIRONMENT_GET_FASTFORWARDING               :: 49 | ENVIRONMENT_EXPERIMENTAL
ENVIRONMENT_GET_TARGET_REFRESH_RATE          :: 50 | ENVIRONMENT_EXPERIMENTAL
ENVIRONMENT_GET_INPUT_BITMASKS               :: 51 | ENVIRONMENT_EXPERIMENTAL
ENVIRONMENT_GET_CORE_OPTIONS_VERSION         :: 52
ENVIRONMENT_SET_CORE_OPTIONS                 :: 53
ENVIRONMENT_SET_CORE_OPTIONS_INTL            :: 54
ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY         :: 55
ENVIRONMENT_GET_PREFERRED_HW_RENDER          :: 56
ENVIRONMENT_GET_DISK_CONTROL_INTERFACE_VERSION :: 57
ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE   :: 58
ENVIRONMENT_GET_MESSAGE_INTERFACE_VERSION    :: 59
ENVIRONMENT_SET_MESSAGE_EXT                  :: 60
ENVIRONMENT_GET_INPUT_MAX_USERS              :: 61
ENVIRONMENT_SET_AUDIO_BUFFER_STATUS_CALLBACK :: 62
ENVIRONMENT_SET_MINIMUM_AUDIO_LATENCY        :: 63
ENVIRONMENT_SET_FASTFORWARDING_OVERRIDE      :: 64
ENVIRONMENT_SET_CONTENT_INFO_OVERRIDE        :: 65
ENVIRONMENT_GET_GAME_INFO_EXT                :: 66
ENVIRONMENT_SET_CORE_OPTIONS_V2              :: 67
ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL         :: 68
ENVIRONMENT_SET_CORE_OPTIONS_UPDATE_DISPLAY_CALLBACK :: 69
ENVIRONMENT_SET_VARIABLE                     :: 70
ENVIRONMENT_GET_THROTTLE_STATE               :: 71 | ENVIRONMENT_EXPERIMENTAL

// ---------------------------------------------------------------------------
// Structures
// ---------------------------------------------------------------------------

System_Info :: struct {
	library_name:     cstring,
	library_version:  cstring,
	valid_extensions: cstring, // "sfc|smc|..."
	need_fullpath:    bool,
	block_extract:    bool,
}

Game_Geometry :: struct {
	base_width:   c.uint,
	base_height:  c.uint,
	max_width:    c.uint,
	max_height:   c.uint,
	aspect_ratio: f32, // <= 0 means base_width / base_height
}

System_Timing :: struct {
	fps:         f64,
	sample_rate: f64,
}

System_AV_Info :: struct {
	geometry: Game_Geometry,
	timing:   System_Timing,
}

Game_Info :: struct {
	path: cstring,
	data: rawptr,
	size: c.size_t,
	meta: cstring,
}

Variable :: struct {
	key:   cstring,
	value: cstring,
}

Message :: struct {
	msg:    cstring,
	frames: c.uint,
}

Message_Ext :: struct {
	msg:      cstring,
	duration: c.uint, // milliseconds
	priority: c.uint,
	level:    Log_Level,
	target:   c.int,
	type:     c.int,
	progress: i8,
}

NUM_CORE_OPTION_VALUES_MAX :: 128

Core_Option_Value :: struct {
	value: cstring,
	label: cstring,
}

Core_Option_Definition :: struct {
	key:           cstring,
	desc:          cstring,
	info:          cstring,
	values:        [NUM_CORE_OPTION_VALUES_MAX]Core_Option_Value,
	default_value: cstring,
}

Core_Options_Intl :: struct {
	us:    [^]Core_Option_Definition,
	local: [^]Core_Option_Definition,
}

Core_Option_V2_Category :: struct {
	key:  cstring,
	desc: cstring,
	info: cstring,
}

Core_Option_V2_Definition :: struct {
	key:              cstring,
	desc:             cstring,
	desc_categorized: cstring,
	info:             cstring,
	info_categorized: cstring,
	category_key:     cstring,
	values:           [NUM_CORE_OPTION_VALUES_MAX]Core_Option_Value,
	default_value:    cstring,
}

Core_Options_V2 :: struct {
	categories:  [^]Core_Option_V2_Category,
	definitions: [^]Core_Option_V2_Definition,
}

Core_Options_V2_Intl :: struct {
	us:    ^Core_Options_V2,
	local: ^Core_Options_V2,
}

Core_Option_Display :: struct {
	key:     cstring,
	visible: bool,
}

Frame_Time_Callback :: struct {
	callback:  proc "c" (usec: i64),
	reference: i64,
}

Rumble_Interface :: struct {
	set_rumble_state: proc "c" (port: c.uint, effect: Rumble_Effect, strength: u16) -> bool,
}

Audio_Buffer_Status_Callback :: struct {
	callback: proc "c" (active: bool, occupancy: c.uint, underrun_likely: bool),
}

Fastforwarding_Override :: struct {
	ratio:        f32,
	fastforward:  bool,
	notification: bool,
	inhibit_toggle: bool,
}

// ---------------------------------------------------------------------------
// Callbacks the frontend gives to the core
// ---------------------------------------------------------------------------

Environment_Proc        :: #type proc "c" (cmd: c.uint, data: rawptr) -> bool
Video_Refresh_Proc      :: #type proc "c" (data: rawptr, width, height: c.uint, pitch: c.size_t)
Audio_Sample_Proc       :: #type proc "c" (left, right: i16)
Audio_Sample_Batch_Proc :: #type proc "c" (data: [^]i16, frames: c.size_t) -> c.size_t
Input_Poll_Proc         :: #type proc "c" ()
Input_State_Proc        :: #type proc "c" (port, device, index, id: c.uint) -> i16

// Passed by cores to video_refresh when the frame is a duplicate of the last one.
HW_FRAME_BUFFER_VALID :: rawptr(~uintptr(0))

// ---------------------------------------------------------------------------
// The core's exported API, resolved at load time.
// ---------------------------------------------------------------------------

Core_API :: struct {
	set_environment:        proc "c" (cb: Environment_Proc),
	set_video_refresh:      proc "c" (cb: Video_Refresh_Proc),
	set_audio_sample:       proc "c" (cb: Audio_Sample_Proc),
	set_audio_sample_batch: proc "c" (cb: Audio_Sample_Batch_Proc),
	set_input_poll:         proc "c" (cb: Input_Poll_Proc),
	set_input_state:        proc "c" (cb: Input_State_Proc),

	init:            proc "c" (),
	deinit:          proc "c" (),
	api_version:     proc "c" () -> c.uint,
	get_system_info: proc "c" (info: ^System_Info),
	get_system_av_info: proc "c" (info: ^System_AV_Info),
	set_controller_port_device: proc "c" (port, device: c.uint),
	reset:           proc "c" (),
	run:             proc "c" (),

	serialize_size: proc "c" () -> c.size_t,
	serialize:      proc "c" (data: rawptr, size: c.size_t) -> bool,
	unserialize:    proc "c" (data: rawptr, size: c.size_t) -> bool,

	cheat_reset: proc "c" (),
	cheat_set:   proc "c" (index: c.uint, enabled: bool, code: cstring),

	load_game:         proc "c" (game: ^Game_Info) -> bool,
	load_game_special: proc "c" (game_type: c.uint, info: [^]Game_Info, num_info: c.size_t) -> bool,
	unload_game:       proc "c" (),
	get_region:        proc "c" () -> c.uint,

	get_memory_data: proc "c" (id: c.uint) -> rawptr,
	get_memory_size: proc "c" (id: c.uint) -> c.size_t,
}

// Symbol name for each Core_API field, in declaration order.
CORE_SYMBOLS := [?]cstring{
	"retro_set_environment",
	"retro_set_video_refresh",
	"retro_set_audio_sample",
	"retro_set_audio_sample_batch",
	"retro_set_input_poll",
	"retro_set_input_state",
	"retro_init",
	"retro_deinit",
	"retro_api_version",
	"retro_get_system_info",
	"retro_get_system_av_info",
	"retro_set_controller_port_device",
	"retro_reset",
	"retro_run",
	"retro_serialize_size",
	"retro_serialize",
	"retro_unserialize",
	"retro_cheat_reset",
	"retro_cheat_set",
	"retro_load_game",
	"retro_load_game_special",
	"retro_unload_game",
	"retro_get_region",
	"retro_get_memory_data",
	"retro_get_memory_size",
}

#assert(len(CORE_SYMBOLS) * size_of(rawptr) == size_of(Core_API))
