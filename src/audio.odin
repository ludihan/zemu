package main

import sdl "vendor:sdl3"

import "emu"

Audio :: struct {
	stream:      ^sdl.AudioStream,
	sample_rate: int,
	buffer:      emu.Audio_Buffer,
}

// (Re)opens the output stream for a core's native sample rate. SDL resamples
// to the device rate.
audio_open :: proc(a: ^Audio, sample_rate: int) -> bool {
	if a.stream != nil && a.sample_rate == sample_rate {
		sdl.ClearAudioStream(a.stream)
		return true
	}
	audio_close(a)
	spec := sdl.AudioSpec {
		format   = .S16LE when ODIN_ENDIAN == .Little else .S16BE,
		channels = 2,
		freq     = i32(sample_rate),
	}
	a.stream = sdl.OpenAudioDeviceStream(sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, nil, nil)
	if a.stream == nil {
		return false
	}
	a.sample_rate = sample_rate
	sdl.ResumeAudioStreamDevice(a.stream)
	return true
}

audio_close :: proc(a: ^Audio) {
	if a.stream != nil {
		sdl.DestroyAudioStream(a.stream)
		a.stream = nil
	}
	a.sample_rate = 0
}

// Milliseconds of audio waiting to be played.
audio_queued_ms :: proc(a: ^Audio) -> f64 {
	if a.stream == nil || a.sample_rate == 0 {
		return 0
	}
	bytes := sdl.GetAudioStreamQueued(a.stream)
	return f64(bytes) / 4.0 / f64(a.sample_rate) * 1000.0
}

AUDIO_TARGET_MS :: 60.0
AUDIO_MAX_MS    :: 250.0

// Sends the samples a core produced this frame, with gentle rate control:
// the stream plays slightly faster or slower to keep latency near the target
// instead of drifting until it underruns or piles up.
audio_submit :: proc(a: ^Audio, enabled: bool, volume: int, fast_forward: bool) {
	defer emu.audio_clear(&a.buffer)
	if a.stream == nil {
		return
	}
	samples := emu.audio_slice(&a.buffer)
	if !enabled || fast_forward || len(samples) == 0 {
		return
	}
	queued := audio_queued_ms(a)
	if queued > AUDIO_MAX_MS {
		sdl.ClearAudioStream(a.stream)
		queued = 0
	}
	ratio := 1.0 + (queued - AUDIO_TARGET_MS) / AUDIO_TARGET_MS * 0.005
	sdl.SetAudioStreamFrequencyRatio(a.stream, f32(clamp(ratio, 0.99, 1.01)))
	sdl.SetAudioStreamGain(a.stream, f32(volume) / 100.0)
	sdl.PutAudioStreamData(a.stream, raw_data(samples), i32(len(samples) * size_of(i16)))
}
