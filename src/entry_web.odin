#+build js
package zemu

// Web entry. web/main.c's main() calls zemu_web_main; Emscripten owns the
// heap, so Odin allocates through its malloc instead of growing wasm memory
// itself.

import "base:runtime"
import "core:c"
import "core:mem"
import sdl "vendor:sdl3"

@(default_calling_convention = "c")
foreign {
	malloc        :: proc(size: c.size_t) -> rawptr ---
	aligned_alloc :: proc(align, size: c.size_t) -> rawptr ---
	realloc       :: proc(ptr: rawptr, size: c.size_t) -> rawptr ---
	free          :: proc(ptr: rawptr) ---
}

MALLOC_ALIGN :: 8

emscripten_allocator_proc :: proc(
	allocator_data: rawptr, mode: mem.Allocator_Mode, size, alignment: int,
	old_memory: rawptr, old_size: int, loc := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	alloc :: proc(size, alignment: int) -> rawptr {
		if alignment <= MALLOC_ALIGN do return malloc(c.size_t(size))
		// aligned_alloc wants size to be a multiple of the alignment.
		sz := (size + alignment - 1) & ~(alignment - 1)
		return aligned_alloc(c.size_t(alignment), c.size_t(sz))
	}
	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		if size == 0 do return nil, nil
		p := alloc(size, alignment)
		if p == nil do return nil, .Out_Of_Memory
		if mode == .Alloc do mem.zero(p, size)
		return ([^]byte)(p)[:size], nil
	case .Free:
		free(old_memory)
		return nil, nil
	case .Free_All:
		return nil, .Mode_Not_Implemented
	case .Resize, .Resize_Non_Zeroed:
		if old_memory == nil do return emscripten_allocator_proc(allocator_data, .Alloc if mode == .Resize else .Alloc_Non_Zeroed, size, alignment, nil, 0, loc)
		if size == 0 {
			free(old_memory)
			return nil, nil
		}
		p: rawptr
		if alignment <= MALLOC_ALIGN {
			p = realloc(old_memory, c.size_t(size))
		} else {
			p = alloc(size, alignment)
			if p != nil {
				mem.copy(p, old_memory, min(old_size, size))
				free(old_memory)
			}
		}
		if p == nil do return nil, .Out_Of_Memory
		if mode == .Resize && size > old_size do mem.zero(rawptr(uintptr(p) + uintptr(old_size)), size - old_size)
		return ([^]byte)(p)[:size], nil
	case .Query_Features:
		set := (^mem.Allocator_Mode_Set)(old_memory)
		if set != nil do set^ = {.Alloc, .Alloc_Non_Zeroed, .Free, .Resize, .Resize_Non_Zeroed, .Query_Features}
		return nil, nil
	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}
	return nil, nil
}

@(export)
zemu_web_main :: proc "c" (argc: c.int, argv: [^]cstring) {
	context = runtime.default_context()
	context.allocator = {procedure = emscripten_allocator_proc}
	runtime.init_global_temporary_allocator(4 * mem.Megabyte, context.allocator)
	context.temp_allocator = runtime.default_temp_allocator(&runtime.global_default_temp_allocator_data)
	#force_no_inline runtime._startup_runtime()
	app_ctx = context
	// Returns right away; SDL keeps running through the browser's frame loop.
	_ = sdl.EnterAppMainCallbacks(argc, argv, app_init, app_iterate, app_event, app_quit)
}
