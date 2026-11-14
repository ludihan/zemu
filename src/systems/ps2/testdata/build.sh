#!/usr/bin/env sh
# Rebuilds the PS2 test programs (needs clang and ld.lld with the MIPS
# target). Programs with a HOST build also get their expected output from a
# native build of the same source.
set -e
cd "$(dirname "$0")"
FLAGS="-target mips64el-none-elf -mabi=n32 -march=mips3 -mno-abicalls -fno-pic -ffreestanding -nostdlib -msoft-float -O2"
clang $FLAGS -c start.S -o start.o
for t in cpu gs; do
	clang $FLAGS -c $t.c -o $t.o
	ld.lld -m elf32ltsmipn32 -Ttext=0x00100000 -e _start start.o $t.o -o $t.elf
	rm -f $t.o
done
clang -DHOST -O2 cpu.c -o cpu.host
./cpu.host > cpu.expected
rm -f start.o cpu.host
