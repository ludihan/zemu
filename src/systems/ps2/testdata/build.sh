#!/usr/bin/env sh
# Rebuilds the PS2 test programs (needs clang and ld.lld with the MIPS
# target) and their expected output from a native build of the same source.
set -e
cd "$(dirname "$0")"
FLAGS="-target mips64el-none-elf -mabi=n32 -march=mips3 -mno-abicalls -fno-pic -ffreestanding -nostdlib -msoft-float -O2"
for t in cpu; do
	clang $FLAGS -c start.S -o start.o
	clang $FLAGS -c $t.c -o $t.o
	ld.lld -m elf32ltsmipn32 -Ttext=0x00100000 -e _start start.o $t.o -o $t.elf
	clang -DHOST -O2 $t.c -o $t.host
	./$t.host > $t.expected
	rm -f start.o $t.o $t.host
done
