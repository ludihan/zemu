package psx

import "base:runtime"
import "core:os"
import "core:strconv"
import "core:strings"

import "../../emu"

SECTOR_SIZE :: 2352
PREGAP      :: 150 // sectors before track 1 (2 seconds)

Track :: struct {
	number:      int,
	audio:       bool,
	file:        int, // index into Disc.files
	file_offset: i64, // byte offset of the track's first sector (INDEX 01)
	sector_size: int, // 2352, or 2048 for ISO-style tracks
	start:       int, // disc LBA (0 = MSF 00:02:00) of INDEX 01
	length:      int, // sectors
}

Disc :: struct {
	files:     [dynamic]^os.File,
	tracks:    [dynamic]Track,
	sectors:   int, // total LBA count (end of the last track)
	allocator: runtime.Allocator,
}

// --- loading ---------------------------------------------------------------

disc_close :: proc(d: ^Disc) {
	if d == nil {
		return
	}
	for f in d.files {
		os.close(f)
	}
	allocator := d.allocator
	delete(d.files)
	delete(d.tracks)
	free(d, allocator)
}

@(private = "file")
parse_msf :: proc(s: string) -> (frames: int, ok: bool) {
	parts := strings.split(s, ":", context.temp_allocator)
	if len(parts) != 3 {
		return 0, false
	}
	m := strconv.parse_int(parts[0], 10) or_return
	sec := strconv.parse_int(parts[1], 10) or_return
	f := strconv.parse_int(parts[2], 10) or_return
	return (m * 60 + sec) * 75 + f, true
}

// Opens a .cue, .bin or .iso image.
disc_open :: proc(path: string, allocator := context.allocator) -> (^Disc, emu.Load_Error) {
	ext := strings.to_lower(os.ext(path), context.temp_allocator)
	d := new(Disc, allocator)
	d.allocator = allocator
	d.files = make([dynamic]^os.File, allocator)
	d.tracks = make([dynamic]Track, allocator)

	err: emu.Load_Error
	switch ext {
	case ".cue":
		err = load_cue(d, path)
	case ".iso":
		err = load_single(d, path, 2048)
	case:
		err = load_single(d, path, SECTOR_SIZE)
	}
	if err != .None {
		disc_close(d)
		return nil, err
	}
	return d, .None
}

@(private = "file")
add_file :: proc(d: ^Disc, path: string) -> (index: int, size: i64, ok: bool) {
	f, err := os.open(path)
	if err != nil {
		return 0, 0, false
	}
	sz, size_err := os.file_size(f)
	if size_err != nil {
		os.close(f)
		return 0, 0, false
	}
	append(&d.files, f)
	return len(d.files) - 1, sz, true
}

@(private = "file")
load_single :: proc(d: ^Disc, path: string, sector_size: int) -> emu.Load_Error {
	idx, size, ok := add_file(d, path)
	if !ok {
		return .Io
	}
	n := int(size / i64(sector_size))
	if n < 16 {
		return .Truncated
	}
	append(&d.tracks, Track{number = 1, file = idx, sector_size = sector_size, start = 0, length = n})
	d.sectors = n
	return .None
}

@(private = "file")
load_cue :: proc(d: ^Disc, path: string) -> emu.Load_Error {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return .Io
	}
	dir := os.dir(path)

	current_file := -1
	file_size: i64 = 0
	file_base := 0 // disc LBA where the current file starts
	pregap_total := 0
	sector_size := SECTOR_SIZE
	have_track := false
	track: Track

	finish_file :: proc(d: ^Disc, file_base: ^int, file_size: i64, sector_size: int) {
		if file_size > 0 {
			file_base^ += int(file_size / i64(sector_size))
		}
	}

	it := string(data)
	for raw_line in strings.split_lines_iterator(&it) {
		line := strings.trim_space(raw_line)
		fields := strings.fields(line, context.temp_allocator)
		if len(fields) == 0 {
			continue
		}
		switch strings.to_upper(fields[0], context.temp_allocator) {
		case "FILE":
			first := strings.index_byte(line, '"')
			last := strings.last_index_byte(line, '"')
			name: string
			if first >= 0 && last > first {
				name = line[first + 1:last]
			} else if len(fields) >= 2 {
				name = fields[1]
			}
			if have_track {
				append(&d.tracks, track)
				have_track = false
			}
			if current_file >= 0 {
				finish_file(d, &file_base, file_size, sector_size)
			}
			full, _ := os.join_path({dir, name}, context.temp_allocator)
			idx, sz, ok := add_file(d, full)
			if !ok {
				return .Io
			}
			current_file = idx
			file_size = sz
		case "TRACK":
			if len(fields) < 3 || current_file < 0 {
				return .Bad_Header
			}
			if have_track {
				append(&d.tracks, track)
			}
			n, _ := strconv.parse_int(fields[1], 10)
			mode := strings.to_upper(fields[2], context.temp_allocator)
			sector_size = strings.has_suffix(mode, "2048") ? 2048 : SECTOR_SIZE
			track = Track {
				number      = n,
				audio       = mode == "AUDIO",
				file        = current_file,
				sector_size = sector_size,
			}
			have_track = true
		case "PREGAP":
			if len(fields) >= 2 {
				gap, _ := parse_msf(fields[1])
				pregap_total += gap
			}
		case "INDEX":
			if len(fields) < 3 || !have_track {
				continue
			}
			idx_num, _ := strconv.parse_int(fields[1], 10)
			pos, ok := parse_msf(fields[2])
			if !ok {
				return .Bad_Header
			}
			if idx_num == 1 {
				track.file_offset = i64(pos) * i64(track.sector_size)
				track.start = file_base + pos + pregap_total
			}
		}
	}
	if have_track {
		append(&d.tracks, track)
	}
	if current_file >= 0 {
		finish_file(d, &file_base, file_size, sector_size)
	}
	if len(d.tracks) == 0 {
		return .Bad_Header
	}
	// Track lengths run up to the next track (or the end of its file).
	for i in 0 ..< len(d.tracks) {
		t := &d.tracks[i]
		size, _ := os.file_size(d.files[t.file])
		file_end := int((size - t.file_offset) / i64(t.sector_size))
		if i + 1 < len(d.tracks) && d.tracks[i + 1].file == t.file {
			t.length = d.tracks[i + 1].start - t.start
		} else {
			t.length = file_end
		}
		t.length = max(t.length, 0)
	}
	last := d.tracks[len(d.tracks) - 1]
	d.sectors = last.start + last.length
	return .None
}

// --- reading ---------------------------------------------------------------

disc_track_at :: proc(d: ^Disc, lba: int) -> (^Track, bool) {
	for &t in d.tracks {
		if lba >= t.start && lba < t.start + t.length {
			return &t, true
		}
	}
	return nil, false
}

// Reads the raw 2352-byte sector at `lba`. ISO tracks are wrapped in a
// synthesized Mode 2 Form 1 header so the drive logic sees one format.
disc_read_sector :: proc(d: ^Disc, lba: int, out: ^[SECTOR_SIZE]u8) -> bool {
	if d == nil {
		return false
	}
	t, ok := disc_track_at(d, lba)
	if !ok {
		out^ = {}
		return false
	}
	offset := t.file_offset + i64(lba - t.start) * i64(t.sector_size)
	if t.sector_size == SECTOR_SIZE {
		n, err := os.read_at(d.files[t.file], out[:], offset)
		return err == nil && n == SECTOR_SIZE
	}
	out^ = {}
	for i in 1 ..< 11 {out[i] = 0xFF} // sync pattern
	msf := lba + PREGAP
	out[12] = to_bcd(u8(msf / 75 / 60))
	out[13] = to_bcd(u8(msf / 75 % 60))
	out[14] = to_bcd(u8(msf % 75))
	out[15] = 2 // mode 2
	out[18] = 0x08 // submode: data
	out[22] = 0x08
	n, err := os.read_at(d.files[t.file], out[24:24 + 2048], offset)
	return err == nil && n == 2048
}

to_bcd :: #force_inline proc(v: u8) -> u8 {
	return (v / 10) << 4 | v % 10
}

from_bcd :: #force_inline proc(v: u8) -> u8 {
	return (v >> 4) * 10 + (v & 0x0F)
}
