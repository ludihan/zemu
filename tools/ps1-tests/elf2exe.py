#!/usr/bin/env python3
# Converts a linked ELF into a PS-X EXE: loadable segments, entry point, stack.
# Minimal ELF -> PS-X EXE converter (loadable segments, entry point, gp).
import struct, sys
elf = open(sys.argv[1], 'rb').read()
entry = struct.unpack_from('<I', elf, 24)[0]
phoff = struct.unpack_from('<I', elf, 28)[0]
phentsize, phnum = struct.unpack_from('<HH', elf, 42)
segs = []
for i in range(phnum):
    p_type, off, vaddr, paddr, filesz, memsz = struct.unpack_from('<6I', elf, phoff + i * phentsize)
    if p_type == 1 and memsz:
        segs.append((vaddr, elf[off:off + filesz], memsz))
lo = min(s[0] for s in segs)
hi = max(s[0] + len(s[1]) for s in segs)
body = bytearray(hi - lo)
for vaddr, data, _ in segs:
    body[vaddr - lo:vaddr - lo + len(data)] = data
body += b'\0' * ((-len(body)) % 2048)
gp = 0
symtab = None
hdr = bytearray(2048)
hdr[0:8] = b'PS-X EXE'
struct.pack_into('<IIII', hdr, 0x10, entry, gp, lo, len(body))
struct.pack_into('<II', hdr, 0x30, 0x801FFFF0, 0)
hdr[0x4C:0x4C + 20] = b'Sony Computer Entertainment Inc. for North America area'[:20]
open(sys.argv[2], 'wb').write(bytes(hdr) + bytes(body))
