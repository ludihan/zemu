package psx

// CD-ROM controller: command/response protocol over four I/O ports, data
// sector reads into the data FIFO, CD-DA playback and XA-ADPCM streaming.

READ_CYCLES_1X     :: CPU_CLOCK / 75
FIRST_RESPONSE     :: 25_000
MAX_PENDING        :: 8
CD_AUDIO_CAPACITY  :: 16384 // stereo frames buffered for the SPU

Response :: struct {
	delay: int,
	irq:   u8,
	data:  [16]u8,
	len:   int,
}

Cdrom :: struct {
	disc:        ^Disc,
	index:       u8,
	params:      [16]u8,
	param_len:   int,
	response:    [16]u8,
	resp_len:    int,
	resp_pos:    int,
	irq_enable:  u8,
	irq_flag:    u8,
	busy:        bool,

	pending:     [MAX_PENDING]Response,
	pending_len: int,

	stat:        u8,
	mode:        u8,
	motor:       bool,
	setloc:      int, // target LBA from Setloc
	setloc_dirty: bool,
	pos:         int, // current head position (LBA)
	reading:     bool,
	playing:     bool,
	read_timer:  int,
	muted:       bool,
	filter_file: u8,
	filter_chan: u8,

	sector:      [SECTOR_SIZE]u8, // last sector read
	sector_valid: bool,
	fifo:        [SECTOR_SIZE]u8,
	fifo_len:    int,
	fifo_pos:    int,

	// volumes (CD left/right to SPU left/right), applied on write to 1803.3
	vol_pending: [4]u8,
	vol:         [4]u8,

	// decoded CD-DA / XA samples waiting for the SPU (44.1 kHz stereo)
	audio:       [CD_AUDIO_CAPACITY][2]i16,
	audio_read:  int,
	audio_write: int,
	audio_count: int,
	xa_prev:     [2][2]i32,
	xa_phase:    f64,
	xa_last:     [2]i16,
}

cdrom_reset :: proc(cd: ^Cdrom) {
	disc := cd.disc
	cd^ = {}
	cd.disc = disc
	cd.stat = disc == nil ? 0x10 : 0x00
	cd.vol = {0x80, 0, 0, 0x80}
}

@(private = "file")
stat_byte :: proc(cd: ^Cdrom) -> u8 {
	s: u8 = 0
	if cd.disc == nil {
		s |= 0x10 // shell open / no disc
	} else if cd.motor {
		s |= 0x02
	}
	if cd.reading {s |= 0x20}
	if cd.playing {s |= 0x80}
	return s
}

@(private = "file")
queue :: proc(cd: ^Cdrom, delay: int, irq: u8, data: ..u8) {
	if cd.pending_len >= MAX_PENDING {
		return
	}
	r := Response{delay = delay, irq = irq}
	r.len = min(len(data), 16)
	copy(r.data[:], data)
	cd.pending[cd.pending_len] = r
	cd.pending_len += 1
}

@(private = "file")
update_irq :: proc(c: ^Console) {
	cd := &c.cdrom
	if cd.irq_flag & cd.irq_enable & 0x1F != 0 {
		request_irq(c, .Cdrom)
	}
}

// --- ports ---------------------------------------------------------------

cdrom_read :: proc(c: ^Console, p: u32) -> u8 {
	cd := &c.cdrom
	switch p & 3 {
	case 0:
		v := cd.index
		if cd.param_len == 0 {v |= 0x08}
		if cd.param_len < 16 {v |= 0x10}
		if cd.resp_pos < cd.resp_len {v |= 0x20}
		if cd.fifo_pos < cd.fifo_len {v |= 0x40}
		if cd.busy {v |= 0x80}
		return v
	case 1:
		if cd.resp_pos < cd.resp_len {
			v := cd.response[cd.resp_pos]
			cd.resp_pos += 1
			return v
		}
		return 0
	case 2:
		if cd.fifo_pos < cd.fifo_len {
			v := cd.fifo[cd.fifo_pos]
			cd.fifo_pos += 1
			return v
		}
		return 0
	case 3:
		if cd.index & 1 == 0 {
			return cd.irq_enable | 0xE0
		}
		return cd.irq_flag | 0xE0
	}
	return 0
}

cdrom_write :: proc(c: ^Console, p: u32, v: u8) {
	cd := &c.cdrom
	reg := p & 3
	if reg == 0 {
		cd.index = v & 3
		return
	}
	switch reg << 4 | u32(cd.index) {
	case 0x10:
		command(c, v)
	case 0x11, 0x12: // sound map (XA from the CPU), not used by games we support
	case 0x13: cd.vol_pending[3] = v // right -> right
	case 0x20:
		if cd.param_len < 16 {
			cd.params[cd.param_len] = v
			cd.param_len += 1
		}
	case 0x21:
		cd.irq_enable = v & 0x1F
		update_irq(c)
	case 0x22: cd.vol_pending[0] = v // left -> left
	case 0x23: cd.vol_pending[2] = v // right -> left
	case 0x30:
		if v & 0x80 != 0 {
			load_fifo(cd)
		} else {
			cd.fifo_len = 0
			cd.fifo_pos = 0
		}
	case 0x31:
		cd.irq_flag &= ~(v & 0x1F)
		if v & 0x40 != 0 {
			cd.param_len = 0
		}
	case 0x32: cd.vol_pending[1] = v // left -> right
	case 0x33:
		if v & 0x20 != 0 {
			cd.vol = cd.vol_pending
		}
		cd.muted = v & 0x01 != 0
	}
}

@(private = "file")
load_fifo :: proc(cd: ^Cdrom) {
	if !cd.sector_valid {
		return
	}
	if cd.mode & 0x20 != 0 {
		copy(cd.fifo[:], cd.sector[12:12 + 0x924])
		cd.fifo_len = 0x924
	} else {
		copy(cd.fifo[:], cd.sector[24:24 + 0x800])
		cd.fifo_len = 0x800
	}
	cd.fifo_pos = 0
}

cdrom_dma_read :: proc(cd: ^Cdrom) -> u32 {
	v: u32
	for i in 0 ..< 4 {
		b: u8
		if cd.fifo_pos < cd.fifo_len {
			b = cd.fifo[cd.fifo_pos]
			cd.fifo_pos += 1
		}
		v |= u32(b) << (u32(i) * 8)
	}
	return v
}

// --- commands --------------------------------------------------------------

@(private = "file")
read_period :: proc(cd: ^Cdrom) -> int {
	return cd.mode & 0x80 != 0 ? READ_CYCLES_1X / 2 : READ_CYCLES_1X
}

@(private = "file")
command :: proc(c: ^Console, cmd: u8) {
	cd := &c.cdrom
	params := cd.params[:cd.param_len]
	cd.param_len = 0
	cd.busy = true
	no_disc := cd.disc == nil

	switch cmd {
	case 0x01: // Getstat
		queue(cd, FIRST_RESPONSE, 3, stat_byte(cd))
	case 0x02: // Setloc
		if len(params) >= 3 {
			m := int(from_bcd(params[0]))
			s := int(from_bcd(params[1]))
			f := int(from_bcd(params[2]))
			cd.setloc = (m * 60 + s) * 75 + f - PREGAP
			cd.setloc_dirty = true
		}
		queue(cd, FIRST_RESPONSE, 3, stat_byte(cd))
	case 0x03: // Play (CD-DA)
		if len(params) >= 1 && params[0] != 0 && cd.disc != nil {
			track := int(from_bcd(params[0]))
			for t in cd.disc.tracks {
				if t.number == track {
					cd.pos = t.start
				}
			}
		} else if cd.setloc_dirty {
			cd.pos = cd.setloc
		}
		cd.setloc_dirty = false
		cd.reading = false
		cd.playing = !no_disc
		cd.motor = true
		cd.read_timer = read_period(cd)
		queue(cd, FIRST_RESPONSE, 3, stat_byte(cd))
	case 0x04, 0x05: // Forward / Backward
		queue(cd, FIRST_RESPONSE, 3, stat_byte(cd))
	case 0x06, 0x1B: // ReadN / ReadS
		if no_disc {
			queue(cd, FIRST_RESPONSE, 5, 0x11, 0x80)
			break
		}
		if cd.setloc_dirty {
			cd.pos = cd.setloc
			cd.setloc_dirty = false
		}
		cd.playing = false
		cd.reading = true
		cd.motor = true
		cd.read_timer = read_period(cd) + 30_000 // seek time
		queue(cd, FIRST_RESPONSE, 3, stat_byte(cd))
	case 0x07: // MotorOn
		cd.motor = true
		queue(cd, FIRST_RESPONSE, 3, stat_byte(cd))
		queue(cd, 80_000, 2, stat_byte(cd))
	case 0x08: // Stop
		first := stat_byte(cd)
		cd.reading = false
		cd.playing = false
		cd.motor = false
		queue(cd, FIRST_RESPONSE, 3, first)
		queue(cd, 100_000, 2, stat_byte(cd))
	case 0x09: // Pause
		first := stat_byte(cd)
		was_active := cd.reading || cd.playing
		cd.reading = false
		cd.playing = false
		queue(cd, FIRST_RESPONSE, 3, first)
		queue(cd, was_active ? read_period(cd) * 2 : 8_000, 2, stat_byte(cd))
	case 0x0A: // Init
		cd.mode = 0
		cd.reading = false
		cd.playing = false
		cd.motor = !no_disc
		queue(cd, FIRST_RESPONSE, 3, stat_byte(cd))
		queue(cd, 120_000, 2, stat_byte(cd))
	case 0x0B: // Mute
		cd.muted = true
		queue(cd, FIRST_RESPONSE, 3, stat_byte(cd))
	case 0x0C: // Demute
		cd.muted = false
		queue(cd, FIRST_RESPONSE, 3, stat_byte(cd))
	case 0x0D: // Setfilter
		if len(params) >= 2 {
			cd.filter_file = params[0]
			cd.filter_chan = params[1]
		}
		queue(cd, FIRST_RESPONSE, 3, stat_byte(cd))
	case 0x0E: // Setmode
		if len(params) >= 1 {
			cd.mode = params[0]
		}
		queue(cd, FIRST_RESPONSE, 3, stat_byte(cd))
	case 0x0F: // Getparam
		queue(cd, FIRST_RESPONSE, 3, stat_byte(cd), cd.mode, 0, cd.filter_file, cd.filter_chan)
	case 0x10: // GetlocL
		h := cd.sector[12:20]
		queue(cd, FIRST_RESPONSE, 3, h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
	case 0x11: // GetlocP
		track_no: u8 = 1
		rel := cd.pos
		if cd.disc != nil {
			if t, ok := disc_track_at(cd.disc, cd.pos); ok {
				track_no = u8(t.number)
				rel = cd.pos - t.start
			}
		}
		abs := cd.pos + PREGAP
		queue(cd, FIRST_RESPONSE, 3,
			to_bcd(track_no), 0x01,
			to_bcd(u8(rel / 75 / 60)), to_bcd(u8(rel / 75 % 60)), to_bcd(u8(rel % 75)),
			to_bcd(u8(abs / 75 / 60)), to_bcd(u8(abs / 75 % 60)), to_bcd(u8(abs % 75)))
	case 0x13: // GetTN
		last: u8 = 1
		if cd.disc != nil && len(cd.disc.tracks) > 0 {
			last = u8(cd.disc.tracks[len(cd.disc.tracks) - 1].number)
		}
		queue(cd, FIRST_RESPONSE, 3, stat_byte(cd), 0x01, to_bcd(last))
	case 0x14: // GetTD
		track := len(params) >= 1 ? int(from_bcd(params[0])) : 0
		lba := 0
		if cd.disc != nil {
			lba = cd.disc.sectors
			for t in cd.disc.tracks {
				if t.number == track {
					lba = t.start
				}
			}
		}
		msf := lba + PREGAP
		queue(cd, FIRST_RESPONSE, 3, stat_byte(cd), to_bcd(u8(msf / 75 / 60)), to_bcd(u8(msf / 75 % 60)))
	case 0x15, 0x16: // SeekL / SeekP
		cd.pos = cd.setloc
		cd.setloc_dirty = false
		cd.reading = false
		cd.playing = false
		cd.motor = true
		queue(cd, FIRST_RESPONSE, 3, stat_byte(cd))
		queue(cd, 100_000, 2, stat_byte(cd))
	case 0x19: // Test
		sub := len(params) >= 1 ? params[0] : 0
		if sub == 0x20 {
			queue(cd, FIRST_RESPONSE, 3, 0x94, 0x09, 0x19, 0xC0)
		} else {
			queue(cd, FIRST_RESPONSE, 3, stat_byte(cd))
		}
	case 0x1A: // GetID
		if no_disc {
			queue(cd, FIRST_RESPONSE, 5, 0x08, 0x40, 0, 0, 0, 0, 0, 0)
			break
		}
		queue(cd, FIRST_RESPONSE, 3, stat_byte(cd))
		queue(cd, 40_000, 2, 0x02, 0x00, 0x20, 0x00, 'S', 'C', 'E', 'A')
	case 0x1E: // ReadTOC
		queue(cd, FIRST_RESPONSE, 3, stat_byte(cd))
		queue(cd, 200_000, 2, stat_byte(cd))
	case:
		queue(cd, FIRST_RESPONSE, 5, stat_byte(cd) | 0x01, 0x40) // invalid command
	}
}

// --- time ------------------------------------------------------------------

cdrom_tick :: proc(c: ^Console, cycles: int) {
	cd := &c.cdrom
	// Deliver at most one queued response at a time, and only after the
	// previous interrupt was acknowledged.
	if cd.pending_len > 0 {
		head := &cd.pending[0]
		head.delay -= cycles
		if head.delay <= 0 && cd.irq_flag & 0x07 == 0 {
			copy(cd.response[:], head.data[:head.len])
			cd.resp_len = head.len
			cd.resp_pos = 0
			cd.irq_flag = (cd.irq_flag & ~u8(7)) | head.irq
			for i in 1 ..< cd.pending_len {
				cd.pending[i - 1] = cd.pending[i]
			}
			cd.pending_len -= 1
			cd.busy = cd.pending_len > 0
			update_irq(c)
		}
	}

	if !(cd.reading || cd.playing) {
		return
	}
	cd.read_timer -= cycles
	if cd.read_timer > 0 {
		return
	}
	cd.read_timer += read_period(cd)
	if cd.reading {
		read_next_sector(c)
	} else {
		play_next_sector(cd)
	}
}

@(private = "file")
read_next_sector :: proc(c: ^Console) {
	cd := &c.cdrom
	ok := disc_read_sector(cd.disc, cd.pos, &cd.sector)
	cd.pos += 1
	if !ok {
		cd.reading = false
		queue(cd, 0, 5, stat_byte(cd) | 0x01, 0x04)
		return
	}
	submode := cd.sector[18]
	is_audio_sector := submode & 0x04 != 0
	if cd.mode & 0x40 != 0 && is_audio_sector {
		// XA-ADPCM: optionally filtered by file/channel, sent to the SPU.
		if cd.mode & 0x08 == 0 || (cd.sector[16] == cd.filter_file && cd.sector[17] == cd.filter_chan) {
			decode_xa(cd)
		}
		return
	}
	cd.sector_valid = true
	// A new INT1 replaces one that the game has not read yet.
	if cd.pending_len < MAX_PENDING {
		queue(cd, 0, 1, stat_byte(cd))
	}
}

@(private = "file")
push_audio :: #force_inline proc(cd: ^Cdrom, l, r: i16) {
	if cd.audio_count >= CD_AUDIO_CAPACITY {
		return
	}
	cd.audio[cd.audio_write] = {l, r}
	cd.audio_write = (cd.audio_write + 1) % CD_AUDIO_CAPACITY
	cd.audio_count += 1
}

@(private = "file")
play_next_sector :: proc(cd: ^Cdrom) {
	buf: [SECTOR_SIZE]u8
	if !disc_read_sector(cd.disc, cd.pos, &buf) {
		cd.playing = false
		return
	}
	cd.pos += 1
	for i in 0 ..< SECTOR_SIZE / 4 {
		l := i16(u16(buf[i * 4]) | u16(buf[i * 4 + 1]) << 8)
		r := i16(u16(buf[i * 4 + 2]) | u16(buf[i * 4 + 3]) << 8)
		push_audio(cd, l, r)
	}
}

// Pops one stereo sample of CD audio for the SPU mixer.
cdrom_audio_sample :: proc(cd: ^Cdrom) -> (i32, i32) {
	if cd.audio_count == 0 {
		return 0, 0
	}
	s := cd.audio[cd.audio_read]
	cd.audio_read = (cd.audio_read + 1) % CD_AUDIO_CAPACITY
	cd.audio_count -= 1
	if cd.muted {
		return 0, 0
	}
	l, r := i32(s[0]), i32(s[1])
	out_l := (l * i32(cd.vol[0]) + r * i32(cd.vol[2])) >> 7
	out_r := (l * i32(cd.vol[1]) + r * i32(cd.vol[3])) >> 7
	return clamp(out_l, -32768, 32767), clamp(out_r, -32768, 32767)
}

// --- XA-ADPCM --------------------------------------------------------------

@(private = "file", rodata)
XA_K0 := [4]i32{0, 60, 115, 98}
@(private = "file", rodata)
XA_K1 := [4]i32{0, 0, -52, -55}

@(private = "file")
decode_xa :: proc(cd: ^Cdrom) {
	coding := cd.sector[19]
	stereo := coding & 0x01 != 0
	half_rate := coding & 0x04 != 0
	eight_bit := coding & 0x10 != 0
	data := cd.sector[24:]

	decoded: [2][4032]i16 // 18 groups x up to 224 samples per channel
	counts: [2]int
	for group in 0 ..< 18 {
		g := data[group * 128:][:128]
		units := eight_bit ? 4 : 8
		for unit in 0 ..< units {
			header := g[4 + unit]
			shift := u32(header & 0x0F)
			if shift > 12 {shift = 9}
			filter := int((header >> 4) & 3)
			ch := stereo ? unit & 1 : 0
			for i in 0 ..< 28 {
				word := g[16 + i * 4:]
				raw: i32
				if eight_bit {
					raw = i32(i8(word[unit])) << 8
				} else {
					b := word[unit / 2]
					nibble := unit & 1 == 0 ? b & 0x0F : b >> 4
					raw = i32(i16(u16(nibble) << 12))
				}
				s := (raw >> shift) + ((cd.xa_prev[ch][0] * XA_K0[filter] + cd.xa_prev[ch][1] * XA_K1[filter] + 32) >> 6)
				s = clamp(s, -32768, 32767)
				cd.xa_prev[ch][1] = cd.xa_prev[ch][0]
				cd.xa_prev[ch][0] = s
				if counts[ch] < len(decoded[ch]) {
					decoded[ch][counts[ch]] = i16(s)
					counts[ch] += 1
				}
			}
		}
	}

	// Resample 37.8 / 18.9 kHz to 44.1 kHz with linear interpolation.
	in_rate := half_rate ? 18900.0 : 37800.0
	step := in_rate / 44100.0
	n := counts[0]
	if stereo {n = min(counts[0], counts[1])}
	for cd.xa_phase < f64(n) {
		i := int(cd.xa_phase)
		frac := cd.xa_phase - f64(i)
		sample :: proc(buf: []i16, i: int, frac: f64, prev: i16) -> i16 {
			a := i == 0 ? f64(prev) : f64(buf[i - 1])
			b := f64(buf[i])
			return i16(a + (b - a) * frac)
		}
		l := sample(decoded[0][:], i, frac, cd.xa_last[0])
		r := stereo ? sample(decoded[1][:], i, frac, cd.xa_last[1]) : l
		push_audio(cd, l, r)
		cd.xa_phase += step
	}
	cd.xa_phase -= f64(n)
	if n > 0 {
		cd.xa_last[0] = decoded[0][n - 1]
		cd.xa_last[1] = stereo ? decoded[1][n - 1] : decoded[0][n - 1]
	}
}
