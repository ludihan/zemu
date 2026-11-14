package main

import "core:fmt"
import "core:os"
import "core:strings"

import "systems/snes"

// MSU-1 files sit next to a SNES game: game.msu is the data file and
// game-N.pcm the audio tracks. They are streamed, never loaded whole.
@(private = "file")
Msu1_Files :: struct {
	base:  string, // the game's path without its extension
	data:  ^os.File,
	track: ^os.File,
}

// Returns the media for the game at `rom_path`, or ok = false when it has
// no MSU-1 data file.
msu1_open :: proc(rom_path: string) -> (media: snes.Msu1_Media, ok: bool) {
	base := rom_path[:len(rom_path) - len(os.ext(rom_path))]
	data, err := os.open(fmt.tprintf("%s.msu", base))
	if err != nil {
		return {}, false
	}
	files := new(Msu1_Files)
	files.base = strings.clone(base)
	files.data = data
	media = {
		user       = files,
		read_data  = proc(user: rawptr, offset: u64, dst: []u8) -> int {
			f := (^Msu1_Files)(user)
			n, _ := os.read_at(f.data, dst, i64(offset))
			return n
		},
		open_track = proc(user: rawptr, track: u16) -> bool {
			f := (^Msu1_Files)(user)
			if f.track != nil {
				os.close(f.track)
				f.track = nil
			}
			t, err := os.open(fmt.tprintf("%s-%d.pcm", f.base, track))
			if err != nil {
				return false
			}
			f.track = t
			return true
		},
		read_track = proc(user: rawptr, offset: u64, dst: []u8) -> int {
			f := (^Msu1_Files)(user)
			if f.track == nil {
				return 0
			}
			n, _ := os.read_at(f.track, dst, i64(offset))
			return n
		},
		close      = proc(user: rawptr) {
			f := (^Msu1_Files)(user)
			if f.track != nil {os.close(f.track)}
			os.close(f.data)
			delete(f.base)
			free(f)
		},
	}
	return media, true
}
