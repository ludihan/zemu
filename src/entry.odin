package zemu

// Platform entry points. Every platform ends up in SDL's main-callback loop
// (app_init / app_iterate / app_event / app_quit in main.odin).

import "base:runtime"
import "core:c"
import "core:os"
import sdl "vendor:sdl3"

IS_WEB     :: ODIN_ARCH == .wasm32 || ODIN_ARCH == .wasm64p32
IS_ANDROID :: ODIN_PLATFORM_SUBTARGET == .Android
IS_MOBILE  :: IS_ANDROID || ODIN_PLATFORM_SUBTARGET_IOS

when IS_ANDROID {
	// SDLActivity dlopens libmain.so and calls SDL_main on its own thread.
	@(export)
	SDL_main :: proc "c" (argc: c.int, argv: [^]cstring) -> c.int {
		context = runtime.default_context()
		app_ctx = context
		return sdl.EnterAppMainCallbacks(argc, argv, app_init, app_iterate, app_event, app_quit)
	}
} else when !IS_WEB {
	main :: proc() {
		app_ctx = context
		os.exit(int(sdl.EnterAppMainCallbacks(0, nil, app_init, app_iterate, app_event, app_quit)))
	}
}
