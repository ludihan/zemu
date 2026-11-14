package main

import "core:fmt"
import "core:os"
import "core:strings"

import "emu"
import "systems/gb"
import "systems/nes"
import "systems/psx"
import "systems/sms"
import "systems/snes"

// Cheat codes. Game Genie codes patch cartridge ROM reads; Pro Action
// Replay / GameShark codes (and raw "ADDRESS:VALUE" codes) rewrite RAM
// before every frame.

MAX_CHEATS :: 64

Cheat_Kind :: enum u8 {
	Rom_Patch,
	Ram_Write8,
	Ram_Write16,
}

Cheat :: struct {
	code:    [32]u8,
	code_len: int,
	name:    [48]u8,
	name_len: int,
	enabled: bool,
	kind:    Cheat_Kind,
	addr:    u32,
	value:   u16,
	compare: i16,
}

Cheat_List :: struct {
	items: [MAX_CHEATS]Cheat,
	count: int,
	dirty: bool, // changed since last saved
}

cheat_code :: proc(c: ^Cheat) -> string {return string(c.code[:c.code_len])}
cheat_name :: proc(c: ^Cheat) -> string {return string(c.name[:c.name_len])}

// --- decoding ----------------------------------------------------------------

@(private = "file")
hex_value :: proc(s: string) -> (v: u32, ok: bool) {
	if len(s) == 0 || len(s) > 8 {
		return 0, false
	}
	for ch in s {
		d: u32
		switch ch {
		case '0' ..= '9': d = u32(ch - '0')
		case 'a' ..= 'f': d = u32(ch - 'a') + 10
		case 'A' ..= 'F': d = u32(ch - 'A') + 10
		case: return 0, false
		}
		v = v << 4 | d
	}
	return v, true
}

@(private = "file")
strip :: proc(code: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for ch in code {
		if ch != '-' && ch != ' ' && ch != ':' && ch != '=' {
			strings.write_rune(&b, ch)
		}
	}
	return strings.to_upper(strings.to_string(b), context.temp_allocator)
}

// NES Game Genie: 6 or 8 letters.
decode_nes_genie :: proc(code: string) -> (c: Cheat, ok: bool) {
	LETTERS :: "APZLGITYEOXUKSVN"
	s := strip(code)
	if len(s) != 6 && len(s) != 8 {
		return {}, false
	}
	n: [8]u32
	for ch, i in s {
		idx := strings.index_rune(LETTERS, ch)
		if idx < 0 {
			return {}, false
		}
		n[i] = u32(idx)
	}
	addr := 0x8000 + (((n[3] & 7) << 12) | ((n[5] & 7) << 8) | ((n[4] & 8) << 8) | ((n[2] & 7) << 4) | ((n[1] & 8) << 4) | (n[4] & 7) | (n[3] & 8))
	c.kind = .Rom_Patch
	c.addr = addr
	c.compare = -1
	if len(s) == 6 {
		c.value = u16(((n[1] & 7) << 4) | ((n[0] & 8) << 4) | (n[0] & 7) | (n[5] & 8))
	} else {
		c.value = u16(((n[1] & 7) << 4) | ((n[0] & 8) << 4) | (n[0] & 7) | (n[7] & 8))
		c.compare = i16(((n[7] & 7) << 4) | ((n[6] & 8) << 4) | (n[6] & 7) | (n[5] & 8))
	}
	return c, true
}

// SNES Game Genie ("DF85-1F6D"): substituted hex digits with the address
// bits scrambled.
decode_snes_genie :: proc(code: string) -> (c: Cheat, ok: bool) {
	SUBST :: "DF4709156BC8A23E"
	s := strip(code)
	if len(s) != 8 {
		return {}, false
	}
	raw: u32
	for ch in s {
		idx := strings.index_rune(SUBST, ch)
		if idx < 0 {
			return {}, false
		}
		raw = raw << 4 | u32(idx)
	}
	d := raw & 0xFFFFFF
	addr := ((d & 0x003C00) << 10) | ((d & 0x00003C) << 14) | ((d & 0xF00000) >> 8) | ((d & 0x000003) << 10) |
	        ((d & 0x00C000) >> 6) | ((d & 0x0F0000) >> 12) | ((d & 0x0003C0) >> 6)
	return {kind = .Rom_Patch, addr = addr, value = u16(raw >> 24), compare = -1}, true
}

// Game Boy Game Genie: "ABC-DEF" or "ABC-DEF-GHI".
decode_gb_genie :: proc(code: string) -> (c: Cheat, ok: bool) {
	s := strip(code)
	if len(s) != 6 && len(s) != 9 {
		return {}, false
	}
	v := hex_value(s[0:2]) or_return
	lo := hex_value(s[2:5]) or_return
	hi := hex_value(s[5:6]) or_return
	c = {kind = .Rom_Patch, value = u16(v), compare = -1}
	c.addr = ((hi ~ 0xF) << 12) | lo
	if c.addr >= 0x8000 {
		return {}, false
	}
	if len(s) == 9 {
		g := hex_value(s[6:7]) or_return
		i := hex_value(s[8:9]) or_return
		x := u8(g << 4 | i)
		x = x >> 2 | x << 6 // rotate right by two
		c.compare = i16(x ~ 0xBA)
	}
	return c, true
}

// Decodes a code for `kind`. Accepted formats:
//   NES   Game Genie (6/8 letters), or raw AAAA:VV
//   SNES  Game Genie (XXXX-XXXX), Pro Action Replay (AAAAAAVV)
//   GB    Game Genie (ABC-DEF[-GHI]), GameShark (01VVLLHH)
//   PSX   GameShark (80AAAAAA VVVV, 30AAAAAA 00VV)
decode_cheat :: proc(kind: emu.System_Kind, code: string) -> (c: Cheat, ok: bool) {
	trimmed := strings.trim_space(code)
	// raw ADDRESS:VALUE works everywhere
	if colon := strings.index_any(trimmed, ":="); colon > 0 {
		addr := hex_value(strings.trim_space(trimmed[:colon])) or_return
		val := hex_value(strings.trim_space(trimmed[colon + 1:])) or_return
		if val > 0xFF {
			return {kind = .Ram_Write16, addr = addr, value = u16(val), compare = -1}, true
		}
		return {kind = .Ram_Write8, addr = addr, value = u16(val), compare = -1}, true
	}
	s := strip(trimmed)
	switch kind {
	case .NES:
		return decode_nes_genie(s)
	case .SNES:
		// Both formats are eight hex digits; Game Genie codes are written
		// with a dash (XXXX-XXXX), Action Replay codes without.
		if strings.contains(trimmed, "-") {
			return decode_snes_genie(s)
		}
		if len(s) == 8 {
			v := hex_value(s) or_return
			return {kind = .Ram_Write8, addr = v >> 8, value = u16(v & 0xFF), compare = -1}, true
		}
	case .GB:
		if len(s) == 8 && s[0] == '0' {
			v := hex_value(s) or_return
			addr := (v & 0xFF) << 8 | (v >> 8) & 0xFF
			return {kind = .Ram_Write8, addr = addr, value = u16((v >> 16) & 0xFF), compare = -1}, true
		}
		return decode_gb_genie(s)
	case .SMS, .GG:
		// Pro Action Replay: 00AAAAVV writes RAM every frame
		if len(s) == 8 {
			v := hex_value(s) or_return
			return {kind = .Ram_Write8, addr = (v >> 8) & 0xFFFF, value = u16(v & 0xFF), compare = -1}, true
		}
	case .PSX:
		if len(s) == 12 {
			op := s[0:2]
			addr := hex_value(s[2:8]) or_return
			val := hex_value(s[8:12]) or_return
			switch op {
			case "80": return {kind = .Ram_Write16, addr = addr, value = u16(val), compare = -1}, true
			case "30": return {kind = .Ram_Write8, addr = addr, value = u16(val & 0xFF), compare = -1}, true
			}
		}
	}
	return {}, false
}

// --- list management ---------------------------------------------------------

cheat_add :: proc(list: ^Cheat_List, kind: emu.System_Kind, code, name: string) -> bool {
	if list.count >= MAX_CHEATS {
		return false
	}
	c, ok := decode_cheat(kind, code)
	if !ok {
		return false
	}
	c.code_len = copy(c.code[:], strings.trim_space(code))
	c.name_len = copy(c.name[:], strings.trim_space(name))
	c.enabled = true
	list.items[list.count] = c
	list.count += 1
	list.dirty = true
	return true
}

cheat_remove :: proc(list: ^Cheat_List, index: int) {
	if index < 0 || index >= list.count {
		return
	}
	for i in index ..< list.count - 1 {
		list.items[i] = list.items[i + 1]
	}
	list.count -= 1
	list.dirty = true
}

// Pushes the enabled ROM patches into the core.
cheats_sync :: proc(m: Machine, list: ^Cheat_List) {
	patches: ^emu.Patch_List
	switch c in m {
	case ^nes.Console:  patches = &c.patches
	case ^snes.Console: patches = &c.patches
	case ^gb.Console:   patches = &c.patches
	case ^sms.Console:  patches = &c.patches
	case ^psx.Console:
	}
	if patches == nil {
		return
	}
	emu.patch_list_clear(patches)
	for i in 0 ..< list.count {
		ch := &list.items[i]
		if ch.enabled && ch.kind == .Rom_Patch {
			emu.patch_list_add(patches, {addr = ch.addr, value = u8(ch.value), compare = ch.compare})
		}
	}
}

// Applies the RAM codes; call before each frame.
cheats_apply :: proc(m: Machine, list: ^Cheat_List) {
	for i in 0 ..< list.count {
		ch := &list.items[i]
		if !ch.enabled || ch.kind == .Rom_Patch {
			continue
		}
		switch c in m {
		case ^nes.Console:  nes.poke(c, ch.addr, u8(ch.value))
		case ^snes.Console: snes.poke(c, ch.addr, u8(ch.value))
		case ^gb.Console:   gb.poke(c, ch.addr, u8(ch.value))
		case ^sms.Console:  sms.poke(c, ch.addr, u8(ch.value))
		case ^psx.Console:
			if ch.kind == .Ram_Write16 {
				psx.poke16(c, ch.addr, ch.value)
			} else {
				psx.poke8(c, ch.addr, u8(ch.value))
			}
		}
	}
}

// --- persistence: one "on|code|name" line per cheat ---------------------------

cheats_load :: proc(list: ^Cheat_List, kind: emu.System_Kind, path: string) {
	list^ = {}
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return
	}
	it := string(data)
	for line in strings.split_lines_iterator(&it) {
		parts := strings.split_n(line, "|", 3, context.temp_allocator)
		if len(parts) < 2 {
			continue
		}
		name := len(parts) == 3 ? parts[2] : ""
		if cheat_add(list, kind, parts[1], name) {
			list.items[list.count - 1].enabled = parts[0] == "1"
		}
	}
	list.dirty = false
}

cheats_save :: proc(list: ^Cheat_List, path: string) {
	if !list.dirty {
		return
	}
	if list.count == 0 {
		os.remove(path)
		list.dirty = false
		return
	}
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< list.count {
		c := &list.items[i]
		fmt.sbprintfln(&b, "%d|%s|%s", c.enabled ? 1 : 0, cheat_code(c), cheat_name(c))
	}
	if os.write_entire_file(path, strings.to_string(b)) == nil {
		list.dirty = false
	}
}

