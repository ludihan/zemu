package emu

import "base:runtime"
import "core:mem"

// Save states are a raw image of a console struct plus any variable-size
// buffers it owns, behind a small header. They are only meant to be loaded
// by the same build of zemu: the header records the struct size and the
// sizes of the attached buffers, and loading refuses anything that does
// not match exactly, so a stale or foreign file can never be copied over
// memory of a different shape. Pointer fields are always restored from the
// live console by the caller after `state_read`.

STATE_MAGIC :: "ZEMUSTv1"

State_Header :: struct #packed {
	magic:       [8]u8,
	system:      System_Kind,
	fingerprint: u64, // identifies the game (a hash of the ROM)
	struct_size: u64,
	extra_sizes: [4]u64,
}

// Serializes `obj` and up to four extra buffers.
state_write :: proc(system: System_Kind, fingerprint: u64, obj: rawptr, size: int, extras: [][]u8, allocator := context.allocator) -> (state: []u8, err: runtime.Allocator_Error) {
	assert(len(extras) <= 4)
	total := size_of(State_Header) + size
	header := State_Header {
		system      = system,
		fingerprint = fingerprint,
		struct_size = u64(size),
	}
	copy(header.magic[:], STATE_MAGIC)
	for e, i in extras {
		header.extra_sizes[i] = u64(len(e))
		total += len(e)
	}
	buf := make([]u8, total, allocator) or_return
	mem.copy(raw_data(buf), &header, size_of(State_Header))
	off := size_of(State_Header)
	mem.copy(&buf[off], obj, size)
	off += size
	for e in extras {
		copy(buf[off:], e)
		off += len(e)
	}
	return buf, nil
}

// Checks a state against the expected layout. Returns false without
// touching anything when it does not match.
state_valid :: proc(data: []u8, system: System_Kind, fingerprint: u64, size: int, extras: [][]u8) -> bool {
	if len(data) < size_of(State_Header) || len(extras) > 4 {
		return false
	}
	header: State_Header
	mem.copy(&header, raw_data(data), size_of(State_Header))
	if string(header.magic[:]) != STATE_MAGIC || header.system != system ||
	   header.fingerprint != fingerprint || header.struct_size != u64(size) {
		return false
	}
	total := size_of(State_Header) + size
	for i in 0 ..< 4 {
		want := i < len(extras) ? u64(len(extras[i])) : 0
		if header.extra_sizes[i] != want {
			return false
		}
		total += int(want)
	}
	return len(data) == total
}

// Copies a validated state into `obj` and the extra buffers.
state_read :: proc(data: []u8, obj: rawptr, size: int, extras: [][]u8) {
	off := size_of(State_Header)
	mem.copy(obj, &data[off], size)
	off += size
	for e in extras {
		copy(e, data[off:][:len(e)])
		off += len(e)
	}
}

// FNV-1a, used to fingerprint ROM images for save states.
fingerprint :: proc(data: []u8) -> u64 {
	h: u64 = 0xcbf29ce484222325
	for b in data {
		h = (h ~ u64(b)) * 0x100000001b3
	}
	return h ~ u64(len(data))
}
