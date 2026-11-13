package main

import "core:fmt"
import sdl "vendor:sdl3"

WINDOW_TITLE  :: "Odin + SDL3"
WINDOW_WIDTH  :: 1280
WINDOW_HEIGHT :: 720

main :: proc() {
	if !sdl.Init({.VIDEO}) {
		fmt.eprintln("SDL_Init failed:", sdl.GetError())
		return
	}
	defer sdl.Quit()

	window := sdl.CreateWindow(WINDOW_TITLE, WINDOW_WIDTH, WINDOW_HEIGHT, {.RESIZABLE})
	if window == nil {
		fmt.eprintln("SDL_CreateWindow failed:", sdl.GetError())
		return
	}
	defer sdl.DestroyWindow(window)

	// nil lets SDL pick the best available rendering backend.
	renderer := sdl.CreateRenderer(window, nil)
	if renderer == nil {
		fmt.eprintln("SDL_CreateRenderer failed:", sdl.GetError())
		return
	}
	defer sdl.DestroyRenderer(renderer)

	// Sync presentation to the display's refresh rate.
	sdl.SetRenderVSync(renderer, 1)

	running := true
	for running {
		event: sdl.Event
		for sdl.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT:
				running = false
			case .KEY_DOWN:
				if event.key.key == sdl.K_ESCAPE {
					running = false
				}
			}
		}

		sdl.SetRenderDrawColor(renderer, 30, 30, 46, 255)
		sdl.RenderClear(renderer)

		// Draw here.

		sdl.RenderPresent(renderer)
	}
}
