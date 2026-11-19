#+build js
package zemu

// Web platform glue. The JS side lives in web/zemu.js (an Emscripten
// --js-library): downloads with fetch(), importing files with a file picker,
// and persisting the data folder to IndexedDB.
//
// Cores on the web are Emscripten side modules (.wasm) loaded with dlopen.
// The buildbot doesn't publish those, so the site hosts its own under
// cores/ with the same .index-extended listing; see scripts/build_web_cores.sh.

import "core:c"
import "core:strings"
import retro "libretro"

@(default_calling_convention = "c")
foreign {
	dlopen  :: proc(path: cstring, flags: c.int) -> rawptr ---
	dlsym   :: proc(handle: rawptr, name: cstring) -> rawptr ---
	dlclose :: proc(handle: rawptr) -> c.int ---
	dlerror :: proc() -> cstring ---

	zemu_js_fetch        :: proc(url, dest: cstring) ---
	zemu_js_import       :: proc(dest_dir: cstring) ---
	zemu_js_import_count :: proc() -> c.int ---
	zemu_js_fs_dirty     :: proc() ---
}

RTLD_NOW :: 2

// --- Cores -------------------------------------------------------------------

Core_Library :: rawptr

CORE_LIBRARY_EXT :: "wasm"

core_library_open :: proc(path: string) -> (lib: Core_Library, api: retro.Core_API, ok: bool) {
	lib = dlopen(tcstr(path), RTLD_NOW)
	if lib == nil {
		osd_message("COULD NOT LOAD CORE")
		return nil, {}, false
	}
	fns := ([^]rawptr)(&api)
	for sym, i in retro.CORE_SYMBOLS {
		fns[i] = dlsym(lib, sym)
		if fns[i] == nil {
			osd_message("NOT A LIBRETRO CORE")
			_ = dlclose(lib)
			return nil, {}, false
		}
	}
	return lib, api, true
}

core_library_close :: proc(lib: Core_Library) {
	_ = dlclose(lib)
}

// Relative to the page: the site serves cores/.index-extended, cores/info.zip
// and cores/<name>_libretro.wasm.zip.
web_cores_base_url :: proc() -> string {
	return "cores/"
}

// --- Downloads -----------------------------------------------------------------
// Same contract as Android: JS writes the file, then "<dest>.ok" or "<dest>.err".

Http_Impl :: struct {
	ok_marker:  string,
	err_marker: string,
}

http_impl_start :: proc(r: ^Http_Request) -> bool {
	r.impl.ok_marker = strings.concatenate({r.dest, ".ok"})
	r.impl.err_marker = strings.concatenate({r.dest, ".err"})
	_ = delete_file(r.dest)
	_ = delete_file(r.impl.ok_marker)
	_ = delete_file(r.impl.err_marker)
	zemu_js_fetch(tcstr(r.url), tcstr(r.dest))
	return true
}

http_impl_poll :: proc(r: ^Http_Request) {
	if file_exists(r.impl.ok_marker) {
		r.state = .Done
	} else if file_exists(r.impl.err_marker) {
		r.state = .Failed
	}
}

http_impl_free :: proc(r: ^Http_Request) {
	_ = delete_file(r.impl.ok_marker)
	_ = delete_file(r.impl.err_marker)
	delete(r.impl.ok_marker)
	delete(r.impl.err_marker)
}

// --- Importing files -----------------------------------------------------------

Import_Kind :: enum u8 {
	Rom,
	Core,
}

web_import_file :: proc(kind: Import_Kind) {
	zemu_js_import(tcstr(paths.roms if kind == .Rom else paths.cores))
}

// Called every frame: notice files the user imported.
web_update :: proc() {
	@(static) seen: c.int
	n := zemu_js_import_count()
	if n != seen {
		seen = n
		touch.games_dirty = true
		cores_scan()
		if ui.dialog == .Load do load_dialog_chdir(load_dlg.dir)
		osd_message("FILE IMPORTED")
	}
}

web_fs_dirty :: proc() {
	zemu_js_fs_dirty()
}
