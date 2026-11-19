package zemu

// Audio output through an SDL audio stream at the core's sample rate.
// SDL resamples to the device; we nudge the playback ratio to keep the
// queue near a target latency (dynamic rate control).

import "core:c"
import "core:fmt"
import sdl "vendor:sdl3"

Audio :: struct {
	stream:      ^sdl.AudioStream,
	sample_rate: f64,
	pending:     [dynamic]i16, // from the single-sample callback
	muted:       bool,
}

audio: Audio

AUDIO_TARGET_MS :: 64
AUDIO_MAX_MS    :: 250
AUDIO_DRC_MAX   :: 0.005

audio_open :: proc(sample_rate: f64) {
	audio_close()
	if sample_rate <= 0 do return
	spec := sdl.AudioSpec{format = .S16, channels = 2, freq = c.int(sample_rate + 0.5)}
	audio.stream = sdl.OpenAudioDeviceStream(sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, nil, nil)
	if audio.stream == nil {
		fmt.eprintln("could not open audio:", sdl.GetError())
		return
	}
	audio.sample_rate = sample_rate
	_ = sdl.ResumeAudioStreamDevice(audio.stream)
}

audio_close :: proc() {
	if audio.stream != nil {
		sdl.DestroyAudioStream(audio.stream)
		audio.stream = nil
	}
	clear(&audio.pending)
}

audio_queued_ms :: proc() -> f64 {
	if audio.stream == nil || audio.sample_rate <= 0 do return 0
	bytes := sdl.GetAudioStreamQueued(audio.stream)
	return f64(bytes) / 4 / audio.sample_rate * 1000
}

audio_push :: proc(samples: []i16) {
	if audio.stream == nil || len(samples) == 0 do return
	if settings.mute || audio.muted do return
	// While fast-forwarding, keep only what fits in the latency budget.
	if timing.fast_forward && audio_queued_ms() > AUDIO_TARGET_MS do return
	_ = sdl.PutAudioStreamData(audio.stream, raw_data(samples), c.int(len(samples) * size_of(i16)))
}

audio_sample_cb :: proc "c" (left, right: i16) {
	context = app_ctx
	append(&audio.pending, left, right)
}

audio_sample_batch_cb :: proc "c" (data: [^]i16, frames: c.size_t) -> c.size_t {
	context = app_ctx
	audio_push(data[:frames * 2])
	return frames
}

audio_flush_samples :: proc() {
	if len(audio.pending) > 0 {
		audio_push(audio.pending[:])
		clear(&audio.pending)
	}
}

// Called once per displayed frame.
audio_update_rate :: proc() {
	if audio.stream == nil do return
	q := audio_queued_ms()
	if q > AUDIO_MAX_MS {
		_ = sdl.ClearAudioStream(audio.stream)
		q = 0
	}
	// Above target: play slightly faster to drain. Below: slightly slower.
	d := clamp((q - AUDIO_TARGET_MS) / AUDIO_TARGET_MS, -1, 1)
	_ = sdl.SetAudioStreamFrequencyRatio(audio.stream, f32(1 + d * AUDIO_DRC_MAX))
}

// Stop sound immediately, e.g. when the GUI opens.
audio_pause :: proc(paused: bool) {
	if audio.stream == nil do return
	if paused {
		_ = sdl.PauseAudioStreamDevice(audio.stream)
		_ = sdl.ClearAudioStream(audio.stream)
	} else {
		_ = sdl.ResumeAudioStreamDevice(audio.stream)
	}
}
