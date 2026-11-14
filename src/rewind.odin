package main

// Rewind buffer. Every few frames a save state is captured; only the
// newest is kept whole. Older states are stored as run-length encoded XOR
// deltas (state[n] ~ state[n-1]), so each step back is one decode and XOR,
// and a frame or two of changes costs a few kilobytes instead of megabytes.

REWIND_BUDGET :: 128 * 1024 * 1024 // bytes of deltas kept

Rewind :: struct {
	current:  []u8, // newest full state
	deltas:   [dynamic][]u8,
	bytes:    int,
	counter:  int,
	interval: int,
}

rewind_reset :: proc(r: ^Rewind) {
	delete(r.current)
	r.current = nil
	for d in r.deltas {
		delete(d)
	}
	delete(r.deltas)
	r.deltas = nil
	r.bytes = 0
	r.counter = 0
}

// Appends a run-length encoded XOR of a and b: repeated
// [zero-run varint][literal-count varint][literal bytes].
@(private = "file")
encode_delta :: proc(a, b: []u8) -> []u8 {
	out := make([dynamic]u8, 0, 4096)
	put_varint :: proc(out: ^[dynamic]u8, v: int) {
		x := v
		for x >= 0x80 {
			append(out, u8(x) | 0x80)
			x >>= 7
		}
		append(out, u8(x))
	}
	i := 0
	n := len(a)
	for i < n {
		zero_start := i
		for i < n && a[i] == b[i] {
			i += 1
		}
		lit_start := i
		// a literal run ends at the next stretch of 8 unchanged bytes
		for i < n {
			if a[i] == b[i] {
				j := i
				for j < n && j - i < 8 && a[j] == b[j] {
					j += 1
				}
				if j - i >= 8 || j == n {
					break
				}
				i = j
			} else {
				i += 1
			}
		}
		put_varint(&out, lit_start - zero_start)
		put_varint(&out, i - lit_start)
		for k in lit_start ..< i {
			append(&out, a[k] ~ b[k])
		}
	}
	shrink(&out)
	return out[:]
}

// XORs a delta into `state` in place. Returns false if the delta is
// malformed or does not fit (the state is then unusable).
@(private = "file")
apply_delta :: proc(state: []u8, delta: []u8) -> bool {
	get_varint :: proc(d: []u8, pos: ^int) -> (v: int, ok: bool) {
		shift: uint = 0
		for pos^ < len(d) && shift < 63 {
			b := d[pos^]
			pos^ += 1
			v |= int(b & 0x7F) << shift
			if b & 0x80 == 0 {
				return v, true
			}
			shift += 7
		}
		return 0, false
	}
	pos := 0
	i := 0
	for pos < len(delta) {
		zeros := get_varint(delta, &pos) or_return
		count := get_varint(delta, &pos) or_return
		i += zeros
		if count < 0 || i + count > len(state) || pos + count > len(delta) {
			return false
		}
		for k in 0 ..< count {
			state[i + k] ~= delta[pos + k]
		}
		i += count
		pos += count
	}
	return true
}

// Records the machine state every `interval` frames.
rewind_capture :: proc(r: ^Rewind, m: Machine) {
	r.counter += 1
	if r.counter < r.interval {
		return
	}
	r.counter = 0
	s := machine_save_state(m)
	if s == nil {
		return
	}
	if r.current != nil && len(r.current) == len(s) {
		d := encode_delta(s, r.current)
		append(&r.deltas, d)
		r.bytes += len(d)
		// drop the oldest deltas when over budget
		drop := 0
		for r.bytes > REWIND_BUDGET && drop < len(r.deltas) - 1 {
			r.bytes -= len(r.deltas[drop])
			delete(r.deltas[drop])
			drop += 1
		}
		if drop > 0 {
			remove_range(&r.deltas, 0, drop)
		}
	} else if r.current != nil {
		rewind_reset(r) // different machine layout: start over
	}
	delete(r.current)
	r.current = s
}

// Steps back one snapshot and loads it. Returns false when the buffer is
// exhausted.
rewind_step :: proc(r: ^Rewind, m: Machine) -> bool {
	if r.current == nil {
		return false
	}
	if len(r.deltas) > 0 {
		d := pop(&r.deltas)
		r.bytes -= len(d)
		ok := apply_delta(r.current, d)
		delete(d)
		if !ok {
			rewind_reset(r)
			return false
		}
	}
	loaded := machine_load_state(m, r.current)
	r.counter = 0
	return loaded && len(r.deltas) > 0
}

// Seconds of history currently available.
rewind_seconds :: proc(r: ^Rewind, fps: f64) -> f64 {
	return f64(len(r.deltas) * r.interval) / fps
}
