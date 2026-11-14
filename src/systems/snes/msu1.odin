package snes

// MSU-1: the streaming chip of homebrew, ROM hacks and fan translations. It
// gives the game a large read-only data file and CD-quality audio tracks
// (44.1 kHz stereo PCM) through eight registers at $2000-$2007.
//
// The core does not open files itself: the frontend hands it callbacks for
// the data file and the tracks. Only the chip's registers and playback
// position belong to the console's state.

Msu1_Media :: struct {
	user:       rawptr,
	// Reads up to len(dst) bytes of the data file from offset; returns how many.
	read_data:  proc(user: rawptr, offset: u64, dst: []u8) -> int,
	// Makes `track` the current track; false if it does not exist.
	open_track: proc(user: rawptr, track: u16) -> bool,
	// Reads from the current track file (header included) from offset.
	read_track: proc(user: rawptr, offset: u64, dst: []u8) -> int,
	close:      proc(user: rawptr),
}

MSU1_REVISION :: 2
MSU1_RATE :: 44100

@(private = "file")
CACHE :: 2048

Msu1 :: struct {
	present:     bool,
	seek:        u32, // offset written to $2000-$2003
	data_pos:    u64,
	track:       u16,
	volume:      u8,
	playing:     bool,
	repeat:      bool,
	error:       bool, // the selected track is missing or not an MSU1 file
	loop_frame:  u32,
	frame:       u32, // current sample frame of the track
	phase:       u32, // resampling: MSU1_RATE steps per output sample
	// read caches; refilled from the media as needed
	data_cache:  [CACHE]u8,
	data_start:  u64,
	data_len:    int,
	track_cache: [CACHE]u8,
	track_start: u64,
	track_len:   int,
}

msu1_reset :: proc(m: ^Msu1) {
	present := m.present
	m^ = {}
	m.present = present
}

msu1_read :: proc(c: ^Console, a: u16) -> u8 {
	m := &c.msu
	switch a & 7 {
	case 0:
		v := u8(MSU1_REVISION)
		if m.repeat {v |= 0x20}
		if m.playing {v |= 0x10}
		if m.error {v |= 0x08}
		return v // seeks and track loads finish at once: never busy
	case 1:
		v := data_byte(c, m.data_pos)
		m.data_pos += 1
		return v
	case:
		id := "S-MSU1"
		return id[int(a & 7) - 2]
	}
}

msu1_write :: proc(c: ^Console, a: u16, v: u8) {
	m := &c.msu
	switch a & 7 {
	case 0 ..= 3:
		shift := u32(a & 3) * 8
		m.seek = (m.seek & ~(u32(0xFF) << shift)) | u32(v) << shift
		if a & 7 == 3 {
			m.data_pos = u64(m.seek)
		}
	case 4:
		m.track = (m.track & 0xFF00) | u16(v)
	case 5:
		m.track = (m.track & 0x00FF) | u16(v) << 8
		load_track(c)
	case 6:
		m.volume = v
	case 7:
		m.repeat = v & 0x02 != 0
		m.playing = v & 0x01 != 0 && !m.error
	}
}

@(private = "file")
load_track :: proc(c: ^Console) {
	m := &c.msu
	media := &c.msu_media
	m.playing = false
	m.repeat = false
	m.frame = 0
	m.phase = 0
	m.track_len = 0
	m.error = true
	if media.open_track == nil || !media.open_track(media.user, m.track) {
		return
	}
	header: [8]u8
	if media.read_track(media.user, 0, header[:]) != 8 || string(header[:4]) != "MSU1" {
		return
	}
	m.loop_frame = u32(header[4]) | u32(header[5]) << 8 | u32(header[6]) << 16 | u32(header[7]) << 24
	m.error = false
}

@(private = "file")
data_byte :: proc(c: ^Console, pos: u64) -> u8 {
	m := &c.msu
	if pos < m.data_start || pos >= m.data_start + u64(m.data_len) {
		m.data_start = pos
		m.data_len = 0
		if c.msu_media.read_data != nil {
			m.data_len = max(c.msu_media.read_data(c.msu_media.user, pos, m.data_cache[:]), 0)
		}
		if m.data_len == 0 {
			return 0 // past the end of the data file
		}
	}
	return m.data_cache[pos - m.data_start]
}

// One stereo frame of the track, or ok = false past its end.
@(private = "file")
track_frame :: proc(c: ^Console, frame: u32) -> (l, r: i16, ok: bool) {
	m := &c.msu
	pos := 8 + u64(frame) * 4
	if pos < m.track_start || pos + 4 > m.track_start + u64(m.track_len) {
		m.track_start = pos
		m.track_len = max(c.msu_media.read_track(c.msu_media.user, pos, m.track_cache[:]), 0)
		if m.track_len < 4 {
			return 0, 0, false
		}
	}
	b := m.track_cache[pos - m.track_start:]
	return i16(u16(b[0]) | u16(b[1]) << 8), i16(u16(b[2]) | u16(b[3]) << 8), true
}

// The track's next output sample at the console's audio rate, scaled by the
// volume register; silence when nothing plays.
msu1_sample :: proc(c: ^Console) -> (l, r: i32) {
	m := &c.msu
	if !m.playing || m.error {
		return 0, 0
	}
	fl, fr, ok := track_frame(c, m.frame)
	if !ok {
		if m.repeat && m.loop_frame != m.frame {
			m.frame = m.loop_frame
			fl, fr, ok = track_frame(c, m.frame)
		}
		if !ok {
			m.playing = false
			return 0, 0
		}
	}
	m.phase += MSU1_RATE
	for m.phase >= SAMPLE_RATE {
		m.phase -= SAMPLE_RATE
		m.frame += 1
	}
	vol := i32(m.volume)
	return i32(fl) * vol / 255, i32(fr) * vol / 255
}
