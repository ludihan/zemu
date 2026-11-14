package main

import "core:fmt"
import "core:os"
import "core:testing"

import "emu"
import "systems/snes"

// PeterLemon's MSU-1 audio demo selects track 0 and plays it on repeat;
// the console's output must carry the track's samples.
@(test)
msu1_plays_audio_track :: proc(t: ^testing.T) {
	path := os.get_env("ZEMU_SNES_TESTS", context.temp_allocator)
	if path == "" {
		return
	}
	m, err := machine_create(.SNES, fmt.tprintf("%s/MSU/AUDIO/AUDIO.sfc", path), nil)
	if !testing.expect_value(t, err, emu.Load_Error.None) {return}
	defer machine_destroy(&m)
	c := m.(^snes.Console)
	testing.expect(t, c.msu.present, "AUDIO.msu should be found next to the ROM")

	audio := new(emu.Audio_Buffer)
	defer free(audio)
	for _ in 0 ..< 60 {
		emu.audio_clear(audio)
		machine_run_frame(m, {}, audio)
	}
	testing.expect(t, c.msu.playing && c.msu.repeat && !c.msu.error, "track 0 should be playing on repeat")
	testing.expect(t, c.msu.frame > 44100 / 2, "playback should have advanced")

	// The last frame's output is the track (the SPC program is silent).
	pcm, read_err := os.read_entire_file(fmt.tprintf("%s/MSU/AUDIO/AUDIO-0.pcm", path), context.allocator)
	if !testing.expect(t, read_err == nil) {return}
	defer delete(pcm)
	loud := 0
	for i := 0; i < audio.count; i += 2 {
		if abs(int(audio.samples[i])) > 256 {loud += 1}
	}
	testing.expectf(t, loud > audio.count / 8, "MSU-1 audio should be audible (%d of %d samples)", loud, audio.count / 2)
	// The sample just played is the track's at the current position.
	pos := 8 + int(c.msu.frame - 1) * 4
	want := i16(u16(pcm[pos]) | u16(pcm[pos + 1]) << 8)
	got := audio.samples[audio.count - 2]
	testing.expectf(t, abs(int(got) - int(want)) <= 2, "last sample %d, track has %d", got, want)
}
