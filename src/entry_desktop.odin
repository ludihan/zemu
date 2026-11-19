#+build !js
package zemu

import "base:runtime"
import "core:c"
import "core:os"
import sdl "vendor:sdl3"

when !IS_ANDROID {
	main :: proc() {
		app_ctx = context
		args := runtime.args__.([]cstring)
		os.exit(int(sdl.EnterAppMainCallbacks(c.int(len(args)), raw_data(args), app_init, app_iterate, app_event, app_quit)))
	}
}
