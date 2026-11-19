package zemu

// Frame pacing: run the core at its own rate regardless of the display's
// refresh rate, using an accumulator driven by the real clock.

import sdl "vendor:sdl3"

Timing :: struct {
	last_ns:      u64,
	acc:          f64, // seconds of emulation owed
	fast_forward: bool,
	ff_toggle:    bool,
	// FPS counter
	fps_frames:   int,
	fps_time:     f64,
	fps:          f64,
}

timing: Timing

FAST_FORWARD_FRAMES :: 6
MAX_CATCHUP_FRAMES  :: 3

timing_reset :: proc() {
	timing.last_ns = sdl.GetTicksNS()
	timing.acc = 0
}

// How many core frames to run this iteration.
timing_frames_due :: proc() -> int {
	now := sdl.GetTicksNS()
	dt := f64(now - timing.last_ns) / 1e9
	timing.last_ns = now
	dt = min(dt, 0.25)

	timing.fps_time += dt
	if timing.fps_time >= 1 {
		timing.fps = f64(timing.fps_frames) / timing.fps_time
		timing.fps_frames = 0
		timing.fps_time = 0
	}

	if timing.fast_forward {
		timing.acc = 0
		return FAST_FORWARD_FRAMES
	}

	fps := core.av_info.timing.fps
	if fps <= 0 do fps = 60
	frame := 1 / fps
	timing.acc += dt
	// Display refresh close to the core's rate: run exactly one frame per
	// vsync and let audio rate control absorb the difference. Avoids judder.
	if abs(dt - frame) < frame * 0.05 && timing.acc < frame * 2 {
		timing.acc = 0
		return 1
	}
	n := 0
	for timing.acc >= frame && n < MAX_CATCHUP_FRAMES {
		timing.acc -= frame
		n += 1
	}
	if n == MAX_CATCHUP_FRAMES do timing.acc = 0
	return n
}
