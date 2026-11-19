#+build !js
package zemu

// Cores are shared libraries (.so / .dll / .dylib) loaded at runtime.

import "core:fmt"
import retro "libretro"
import sdl "vendor:sdl3"

Core_Library :: ^sdl.SharedObject

CORE_LIBRARY_EXT :: "dll" when ODIN_OS == .Windows else "dylib" when ODIN_OS == .Darwin else "so"

core_library_open :: proc(path: string) -> (lib: Core_Library, api: retro.Core_API, ok: bool) {
	lib = sdl.LoadObject(tcstr(path))
	if lib == nil {
		fmt.eprintln("could not load core:", sdl.GetError())
		osd_message("COULD NOT LOAD CORE")
		return nil, {}, false
	}
	fns := transmute([^]rawptr)&api
	for sym, i in retro.CORE_SYMBOLS {
		fns[i] = rawptr(sdl.LoadFunction(lib, sym))
		if fns[i] == nil {
			fmt.eprintln("core is missing", sym)
			osd_message("NOT A LIBRETRO CORE")
			sdl.UnloadObject(lib)
			return nil, {}, false
		}
	}
	return lib, api, true
}

core_library_close :: proc(lib: Core_Library) {
	sdl.UnloadObject(lib)
}
