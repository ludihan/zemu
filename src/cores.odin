package zemu

// Installed cores: what is in the cores directory, with display names and
// supported extensions from the libretro .info files (or from the core
// itself when no .info file is available).

import "core:slice"
import "core:strings"
import retro "libretro"

Core_Entry :: struct {
	path:        string,
	id:          string, // "snes9x" (file name without _libretro and platform suffixes)
	name:        string, // "Nintendo - SNES / SFC (Snes9x)"
	system:      string,
	extensions:  string, // "sfc|smc"
	no_game:     bool,
}

installed_cores: [dynamic]Core_Entry

// "snes9x_libretro_android.so" -> "snes9x"
core_id_from_file :: proc(file: string) -> string {
	s := file
	if dot := strings.last_index_byte(s, '.'); dot > 0 do s = s[:dot]
	if i := strings.index(s, "_libretro"); i > 0 do s = s[:i]
	return s
}

core_info_path :: proc(id: string) -> string {
	return join_path(paths.info, strings.concatenate({id, "_libretro.info"}, context.temp_allocator), context.temp_allocator)
}

free_core_entry :: proc(e: ^Core_Entry) {
	delete(e.path); delete(e.id); delete(e.name); delete(e.system); delete(e.extensions)
}

cores_scan :: proc() {
	for &e in installed_cores do free_core_entry(&e)
	clear(&installed_cores)

	entries := list_dir(paths.cores, context.temp_allocator)
	for d in entries {
		if d.is_dir || extension(d.name) != CORE_LIBRARY_EXT do continue
		e := Core_Entry{
			path = join_path(paths.cores, d.name),
			id   = strings.clone(core_id_from_file(d.name)),
		}
		if info, ok := core_info_read(e.id); ok {
			e.name       = short_core_name(info.display_name, context.allocator)
			e.system     = strings.clone(info.system)
			e.extensions = strings.clone(info.extensions)
			e.no_game    = info.no_game
		} else {
			core_probe(&e)
		}
		if e.name == "" do e.name = strings.clone(e.id)
		append(&installed_cores, e)
	}
	slice.sort_by(installed_cores[:], proc(a, b: Core_Entry) -> bool {
		return strings.compare(a.name, b.name) < 0
	})
}

Core_Info :: struct {
	display_name: string,
	system:       string,
	manufacturer: string,
	extensions:   string,
	no_game:      bool,
}

// "Nintendo - SNES / SFC (Snes9x 2010)" -> "Snes9x 2010 - SNES / SFC", so the
// part that tells cores apart comes first and survives truncation.
short_core_name :: proc(display: string, allocator := context.temp_allocator) -> string {
	open := strings.last_index_byte(display, '(')
	if open <= 0 || !strings.has_suffix(display, ")") do return strings.clone(display, allocator)
	inner := display[open + 1:len(display) - 1]
	system := strings.trim_space(display[:open])
	if dash := strings.index(system, " - "); dash >= 0 do system = system[dash + 3:]
	return strings.concatenate({inner, " - ", system}, allocator)
}

// Parses a libretro .info file (temp allocated strings).
core_info_read :: proc(id: string) -> (info: Core_Info, ok: bool) {
	data := read_file(core_info_path(id), context.temp_allocator) or_return
	return core_info_parse(string(data)), true
}

core_info_parse :: proc(text: string) -> (info: Core_Info) {
	t := text
	for line in strings.split_lines_iterator(&t) {
		eq := strings.index_byte(line, '=')
		if eq < 0 do continue
		k := strings.trim_space(line[:eq])
		v := strings.trim(strings.trim_space(line[eq + 1:]), "\"")
		switch k {
		case "display_name":         info.display_name = v
		case "systemname":           info.system = v
		case "manufacturer":         info.manufacturer = v
		case "supported_extensions": info.extensions = v
		case "supports_no_game":     info.no_game = v == "true"
		}
	}
	return
}

// No .info file: ask the core. retro_get_system_info may be called without
// initialising the core, so this is cheap and safe.
core_probe :: proc(e: ^Core_Entry) {
	when IS_WEB {
		return
	} else {
		lib, api, ok := core_library_open(e.path)
		if !ok do return
		defer core_library_close(lib)
		info: retro.System_Info
		api.get_system_info(&info)
		e.name = strings.concatenate({string(info.library_name), " ", string(info.library_version)})
		e.extensions = strings.clone(string(info.valid_extensions))
		// Without an .info file we can't ask; cores with no extensions run without content.
		e.no_game = e.extensions == ""
	}
}

// Cores that can open a file with this extension.
cores_for_extension :: proc(ext: string, allocator := context.temp_allocator) -> []int {
	res := make([dynamic]int, allocator)
	for e, i in installed_cores {
		exts := e.extensions
		for x in strings.split_iterator(&exts, "|") {
			if strings.equal_fold(x, ext) {
				append(&res, i)
				break
			}
		}
	}
	return res[:]
}

// Extensions some libretro core opens, from the .info files fetched with the
// core list. Lets the file browser show games no installed core opens yet.
catalog_exts: map[string]bool
catalog_exts_loaded: bool

catalog_exts_load :: proc() {
	for k in catalog_exts do delete(k)
	clear(&catalog_exts)
	catalog_exts_loaded = true
	for d in list_dir(paths.info, context.temp_allocator) {
		if d.is_dir || !strings.has_suffix(d.name, "_libretro.info") do continue
		info, ok := core_info_read(d.name[:len(d.name) - len("_libretro.info")])
		if !ok do continue
		exts := info.extensions
		for e in strings.split_iterator(&exts, "|") {
			l := strings.to_lower(strings.trim_space(e), context.temp_allocator)
			if l != "" && l not_in catalog_exts do catalog_exts[strings.clone(l)] = true
		}
	}
}

// Every extension some installed core accepts, plus zip (7z isn't supported).
known_extension :: proc(ext: string) -> bool {
	if ext == "zip" do return true
	return len(cores_for_extension(ext)) > 0
}

// Something a core could open: installed or available to download.
loadable_extension :: proc(ext: string) -> bool {
	if known_extension(ext) do return true
	if !catalog_exts_loaded do catalog_exts_load()
	return ext in catalog_exts
}

core_entry_index :: proc(path: string) -> int {
	for e, i in installed_cores do if e.path == path do return i
	return -1
}
