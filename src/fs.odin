package zemu

// Portable file helpers built on SDL so they behave the same on desktop,
// Android (internal storage) and the web (Emscripten FS).

import "core:c"
import "core:slice"
import "core:strings"
import sdl "vendor:sdl3"

Paths :: struct {
	base:   string, // writable per-user directory, ends with '/'
	cores:  string,
	system: string,
	saves:  string,
	states: string,
	info:   string,
	roms:   string, // imported games (mobile/web); desktop users browse anywhere
	config: string, // config file path
}

paths: Paths

paths_init :: proc() {
	pref := sdl.GetPrefPath("zemu", "zemu")
	base: string
	if pref != nil {
		base = strings.clone(string(cstring(pref)))
		sdl.free(pref)
	} else {
		base = "./zemu-data/"
	}
	paths.base   = base
	paths.cores  = join_path(base, "cores")
	paths.system = join_path(base, "system")
	paths.saves  = join_path(base, "saves")
	paths.states = join_path(base, "states")
	paths.info   = join_path(base, "info")
	paths.roms   = join_path(base, "roms")
	paths.config = join_path(base, "zemu.cfg")
	for dir in ([]string{paths.cores, paths.system, paths.saves, paths.states, paths.info, paths.roms}) {
		make_dir(dir)
	}
}

join_path :: proc(a, b: string, allocator := context.allocator) -> string {
	if a == "" do return strings.clone(b, allocator)
	if strings.has_suffix(a, "/") || strings.has_suffix(a, "\\") {
		return strings.concatenate({a, b}, allocator)
	}
	return strings.concatenate({a, "/", b}, allocator)
}

// Returns the last path component.
base_name :: proc(path: string) -> string {
	i := max(strings.last_index_byte(path, '/'), strings.last_index_byte(path, '\\'))
	return path[i + 1:]
}

// Returns the directory part of a path, without the trailing separator.
dir_name :: proc(path: string) -> string {
	i := max(strings.last_index_byte(path, '/'), strings.last_index_byte(path, '\\'))
	if i < 0 do return "."
	if i == 0 do return "/"
	return path[:i]
}

// File name without directory and extension.
stem :: proc(path: string) -> string {
	name := base_name(path)
	if dot := strings.last_index_byte(name, '.'); dot > 0 {
		return name[:dot]
	}
	return name
}

// Lowercased extension without the dot (temp allocated).
extension :: proc(path: string) -> string {
	name := base_name(path)
	if dot := strings.last_index_byte(name, '.'); dot >= 0 {
		return strings.to_lower(name[dot + 1:], context.temp_allocator)
	}
	return ""
}

tcstr :: proc(s: string) -> cstring {
	return strings.clone_to_cstring(s, context.temp_allocator)
}

make_dir :: proc(path: string) {
	_ = sdl.CreateDirectory(tcstr(path))
}

file_exists :: proc(path: string) -> bool {
	info: sdl.PathInfo
	return sdl.GetPathInfo(tcstr(path), &info) && info.type == .FILE
}

dir_exists :: proc(path: string) -> bool {
	info: sdl.PathInfo
	return sdl.GetPathInfo(tcstr(path), &info) && info.type == .DIRECTORY
}

read_file :: proc(path: string, allocator := context.allocator) -> (data: []byte, ok: bool) {
	size: uint
	raw := sdl.LoadFile(tcstr(path), &size)
	if raw == nil do return nil, false
	defer sdl.free(raw)
	data = make([]byte, int(size), allocator)
	copy(data, ([^]byte)(raw)[:size])
	return data, true
}

write_file :: proc(path: string, data: []byte) -> bool {
	return sdl.SaveFile(tcstr(path), raw_data(data), uint(len(data)))
}

delete_file :: proc(path: string) -> bool {
	return sdl.RemovePath(tcstr(path))
}

Dir_Entry :: struct {
	name:   string,
	is_dir: bool,
	size:   u64,
}

// Lists a directory, directories first, both sorted case-insensitively.
list_dir :: proc(path: string, allocator := context.allocator) -> []Dir_Entry {
	Ctx :: struct {
		entries: [dynamic]Dir_Entry,
		dir:     string,
	}
	ctx := Ctx{dir = path}
	ctx.entries = make([dynamic]Dir_Entry, allocator)

	cb :: proc "c" (userdata: rawptr, dirname, fname: cstring) -> sdl.EnumerationResult {
		ctx := (^Ctx)(userdata)
		context = app_ctx
		name := string(fname)
		if name == "." || name == ".." do return .CONTINUE
		full := strings.concatenate({string(dirname), name}, context.temp_allocator)
		info: sdl.PathInfo
		_ = sdl.GetPathInfo(tcstr(full), &info)
		append(&ctx.entries, Dir_Entry{
			name   = strings.clone(name, ctx.entries.allocator),
			is_dir = info.type == .DIRECTORY,
			size   = u64(info.size),
		})
		return .CONTINUE
	}
	_ = sdl.EnumerateDirectory(tcstr(path), cb, &ctx)

	slice.sort_by(ctx.entries[:], proc(a, b: Dir_Entry) -> bool {
		if a.is_dir != b.is_dir do return a.is_dir
		return strings.compare(strings.to_lower(a.name, context.temp_allocator), strings.to_lower(b.name, context.temp_allocator)) < 0
	})
	return ctx.entries[:]
}

free_dir_entries :: proc(entries: []Dir_Entry, allocator := context.allocator) {
	for e in entries do delete(e.name, allocator)
	delete(entries, allocator)
}

_ :: c
