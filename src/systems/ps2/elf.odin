package ps2

import "../../emu"

// Loads a 32-bit little-endian MIPS ELF executable into RAM.
elf_load :: proc(c: ^Console, data: []u8) -> (entry: u32, err: emu.Load_Error) {
	if len(data) < 52 || string(data[:4]) != "\x7fELF" {
		return 0, .Bad_Header
	}
	if data[4] != 1 || data[5] != 1 { // ELFCLASS32, little endian
		return 0, .Unsupported_Format
	}
	r16 :: proc(d: []u8, o: int) -> int {return int(d[o]) | int(d[o + 1]) << 8}
	r32 :: proc(d: []u8, o: int) -> u32 {
		return u32(d[o]) | u32(d[o + 1]) << 8 | u32(d[o + 2]) << 16 | u32(d[o + 3]) << 24
	}
	if r16(data, 18) != 8 { // EM_MIPS
		return 0, .Unsupported_Format
	}
	entry = r32(data, 24)
	phoff := int(r32(data, 28))
	phentsize := r16(data, 42)
	phnum := r16(data, 44)
	if phentsize < 32 || phoff < 0 || phoff + phnum * phentsize > len(data) {
		return 0, .Truncated
	}
	for i in 0 ..< phnum {
		ph := phoff + i * phentsize
		if r32(data, ph) != 1 { // PT_LOAD
			continue
		}
		offset := int(r32(data, ph + 4))
		vaddr := r32(data, ph + 8)
		filesz := int(r32(data, ph + 16))
		memsz := int(r32(data, ph + 20))
		dst := int(vaddr & 0x1FFF_FFFF)
		if offset < 0 || filesz < 0 || offset + filesz > len(data) || filesz > memsz ||
		   dst + memsz > RAM_SIZE {
			return 0, .Truncated
		}
		copy(c.ram[dst:][:filesz], data[offset:][:filesz])
		for k in filesz ..< memsz {
			c.ram[dst + k] = 0
		}
	}
	return entry, .None
}
