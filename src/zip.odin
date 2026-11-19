package zemu

// Minimal zip reader: enough for zipped ROMs and the buildbot's zipped cores
// and core info files. Supports stored and deflated entries.

import "core:compress/deflate"
import "core:encoding/endian"

Zip_Entry :: struct {
	name:              string, // points into the archive data
	method:            u16,
	compressed_size:   int,
	uncompressed_size: int,
	local_offset:      int,
}

@(private="file")
u16le :: proc(b: []byte, at: int) -> u16 {
	v, _ := endian.get_u16(b[at:], .Little)
	return v
}

@(private="file")
u32le :: proc(b: []byte, at: int) -> u32 {
	v, _ := endian.get_u32(b[at:], .Little)
	return v
}

// Lists the entries from the central directory. Names alias `data`.
zip_entries :: proc(data: []byte, allocator := context.allocator) -> (entries: [dynamic]Zip_Entry, ok: bool) {
	EOCD_SIG :: 0x06054b50
	CDIR_SIG :: 0x02014b50
	if len(data) < 22 do return nil, false

	// The end-of-central-directory record is within the last 64 KiB + 22 bytes.
	eocd := -1
	lowest := max(0, len(data) - 65557)
	for i := len(data) - 22; i >= lowest; i -= 1 {
		if u32le(data, i) == EOCD_SIG {
			eocd = i
			break
		}
	}
	if eocd < 0 do return nil, false

	count := int(u16le(data, eocd + 10))
	cdir := int(u32le(data, eocd + 16))
	entries = make([dynamic]Zip_Entry, 0, count, allocator)

	p := cdir
	for _ in 0 ..< count {
		if p + 46 > len(data) || u32le(data, p) != CDIR_SIG do break
		name_len  := int(u16le(data, p + 28))
		extra_len := int(u16le(data, p + 30))
		cmt_len   := int(u16le(data, p + 32))
		if p + 46 + name_len > len(data) do break
		append(&entries, Zip_Entry{
			name              = string(data[p + 46:][:name_len]),
			method            = u16le(data, p + 10),
			compressed_size   = int(u32le(data, p + 20)),
			uncompressed_size = int(u32le(data, p + 24)),
			local_offset      = int(u32le(data, p + 42)),
		})
		p += 46 + name_len + extra_len + cmt_len
	}
	return entries, true
}

zip_extract :: proc(data: []byte, e: Zip_Entry, allocator := context.allocator) -> (out: []byte, ok: bool) {
	LOCAL_SIG :: 0x04034b50
	h := e.local_offset
	if h + 30 > len(data) || u32le(data, h) != LOCAL_SIG do return nil, false
	start := h + 30 + int(u16le(data, h + 26)) + int(u16le(data, h + 28))
	if start + e.compressed_size > len(data) do return nil, false
	src := data[start:][:e.compressed_size]

	switch e.method {
	case 0:
		out = make([]byte, len(src), allocator)
		copy(out, src)
		return out, true
	case 8:
		buf: [dynamic]byte
		buf.allocator = allocator
		if err := deflate.inflate_raw(&buf, src, e.uncompressed_size, allocator = allocator); err != nil {
			delete(buf)
			return nil, false
		}
		return buf[:], true
	}
	return nil, false
}

// First regular file in the archive (zipped ROMs usually hold just one).
zip_extract_first :: proc(data: []byte, allocator := context.allocator) -> (out: []byte, ok: bool) {
	entries := zip_entries(data, context.temp_allocator) or_return
	for e in entries {
		if len(e.name) > 0 && e.name[len(e.name) - 1] != '/' {
			return zip_extract(data, e, allocator)
		}
	}
	return nil, false
}
