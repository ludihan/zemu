package zemu

import "base:runtime"
import "core:c"
import "core:fmt"
import sdl "vendor:sdl3"

APP_NAME    :: "ZEMU"
APP_VERSION :: "0.1"

App :: struct {
	window:   ^sdl.Window,
	renderer: ^sdl.Renderer,
	running:  bool,
}

app: App
app_ctx: runtime.Context

app_init :: proc "c" (appstate: ^rawptr, argc: c.int, argv: [^]cstring) -> sdl.AppResult {
	context = app_ctx
	_ = sdl.SetAppMetadata(APP_NAME, APP_VERSION, "dev.zemu.libretro")
	if !sdl.Init({.VIDEO, .AUDIO, .GAMEPAD}) {
		fmt.eprintln("SDL_Init failed:", sdl.GetError())
		return .FAILURE
	}
	flags: sdl.WindowFlags = {.RESIZABLE, .HIGH_PIXEL_DENSITY}
	if !sdl.CreateWindowAndRenderer(APP_NAME, 256 * 3, 224 * 3, flags, &app.window, &app.renderer) {
		fmt.eprintln("CreateWindowAndRenderer failed:", sdl.GetError())
		return .FAILURE
	}
	_ = sdl.SetRenderVSync(app.renderer, 1)
	app.running = true
	return .CONTINUE
}

app_iterate :: proc "c" (appstate: rawptr) -> sdl.AppResult {
	context = app_ctx
	if !app.running do return .SUCCESS
	_ = sdl.SetRenderDrawColor(app.renderer, 0, 0, 0, 255)
	_ = sdl.RenderClear(app.renderer)
	_ = sdl.RenderPresent(app.renderer)
	free_all(context.temp_allocator)
	return .CONTINUE
}

app_event :: proc "c" (appstate: rawptr, event: ^sdl.Event) -> sdl.AppResult {
	context = app_ctx
	#partial switch event.type {
	case .QUIT:
		return .SUCCESS
	}
	return .CONTINUE
}

app_quit :: proc "c" (appstate: rawptr, result: sdl.AppResult) {
	context = app_ctx
	sdl.Quit()
}
