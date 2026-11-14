package emu

// ROM patches from cheat devices that intercept cartridge reads (Game
// Genie). Codes that write RAM every frame (Pro Action Replay, GameShark)
// are applied by the frontend through each core's `poke` instead.

MAX_PATCHES :: 64

Patch :: struct {
	addr:    u32,
	value:   u8,
	compare: i16, // only replace when the original byte matches; -1 = always
}

Patch_List :: struct {
	items: [MAX_PATCHES]Patch,
	count: int,
}

patch_list_clear :: proc(l: ^Patch_List) {
	l.count = 0
}

patch_list_add :: proc(l: ^Patch_List, p: Patch) -> bool {
	if l.count >= MAX_PATCHES {
		return false
	}
	l.items[l.count] = p
	l.count += 1
	return true
}

// Returns the byte a cartridge read should see at `addr`.
patch_apply :: #force_inline proc(l: ^Patch_List, addr: u32, original: u8) -> u8 {
	for i in 0 ..< l.count {
		p := &l.items[i]
		if p.addr == addr && (p.compare < 0 || u8(p.compare) == original) {
			return p.value
		}
	}
	return original
}
