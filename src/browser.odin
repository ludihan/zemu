package main

import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"

import "gui"

Browse_Purpose :: enum u8 {
	Rom,
	Psx_Bios,
}

Browser :: struct {
	purpose:    Browse_Purpose,
	dir:        string, // owned by `arena`
	files:      [dynamic]gui.List_Item,
	dirs:       [dynamic]gui.List_Item,
	file_list:  gui.List_State,
	dir_list:   gui.List_State,
	focus_dirs: bool,
	show_all:   bool,
	error:      string,
	// Everything for the current listing lives here and is freed at once on
	// the next refresh, so there is nothing to track entry by entry.
	arena:      virtual.Arena,
}

browser_destroy :: proc(b: ^Browser) {
	virtual.arena_destroy(&b.arena)
	b^ = {}
}

@(private = "file")
entry_less :: proc(a, b: gui.List_Item) -> bool {
	return strings.compare(strings.to_lower(a.text, context.temp_allocator), strings.to_lower(b.text, context.temp_allocator)) < 0
}

// Lists `dir`. On failure the previous directory is kept when possible.
browser_open :: proc(b: ^Browser, dir: string) {
	path := strings.clone(dir, context.temp_allocator)
	if path == "" || !os.is_dir(path) {
		cwd, err := os.get_working_directory(context.temp_allocator)
		path = err == nil ? cwd : "."
	}

	virtual.arena_free_all(&b.arena)
	alloc := virtual.arena_allocator(&b.arena)
	b.files = make([dynamic]gui.List_Item, alloc)
	b.dirs = make([dynamic]gui.List_Item, alloc)
	b.error = ""

	abs, abs_err := os.get_absolute_path(path, alloc)
	b.dir = abs_err == nil ? abs : strings.clone(path, alloc)

	infos, err := os.read_all_directory_by_path(b.dir, context.temp_allocator)
	if err != nil {
		b.error = "Cannot read this directory"
	}

	if parent := os.dir(b.dir); parent != b.dir {
		append(&b.dirs, gui.List_Item{text = "..", icon = gui.Symbol.Folder})
	}
	for fi in infos {
		if len(fi.name) == 0 || fi.name[0] == '.' {
			continue // hidden files
		}
		name := strings.clone(fi.name, alloc)
		if fi.type == .Directory {
			append(&b.dirs, gui.List_Item{text = name, icon = gui.Symbol.Folder})
		} else if b.show_all || browser_accepts(b, fi.name) {
			append(&b.files, gui.List_Item{text = name})
		}
	}
	slice.sort_by(b.files[:], entry_less)
	start := len(b.dirs) > 0 && b.dirs[0].text == ".." ? 1 : 0
	slice.sort_by(b.dirs[start:], entry_less)

	b.file_list = {}
	b.dir_list = {}
	b.focus_dirs = len(b.files) == 0
}

browser_accepts :: proc(b: ^Browser, name: string) -> bool {
	switch b.purpose {
	case .Rom:
		return is_supported_file(name)
	case .Psx_Bios:
		ext := strings.to_lower(os.ext(name), context.temp_allocator)
		return ext == ".bin" || ext == ".rom"
	}
	return false
}

browser_refresh :: proc(b: ^Browser) {
	dir := strings.clone(b.dir, context.temp_allocator)
	browser_open(b, dir)
}

// Enters the selected directory.
browser_enter_dir :: proc(b: ^Browser) {
	if len(b.dirs) == 0 {
		return
	}
	i := clamp(b.dir_list.selected, 0, len(b.dirs) - 1)
	name := b.dirs[i].text
	target: string
	if name == ".." {
		target = strings.clone(os.dir(b.dir), context.temp_allocator)
	} else {
		joined, _ := os.join_path({b.dir, name}, context.temp_allocator)
		target = joined
	}
	browser_open(b, target)
}

// Full path of the selected file, allocated with the temp allocator.
browser_selected_file :: proc(b: ^Browser) -> (string, bool) {
	if len(b.files) == 0 {
		return "", false
	}
	i := clamp(b.file_list.selected, 0, len(b.files) - 1)
	p, err := os.join_path({b.dir, b.files[i].text}, context.temp_allocator)
	return p, err == nil
}
