#!/bin/sh
# Builds JaCzekanski's ps1-tests with clang/lld (no GCC MIPS toolchain
# needed) so the PS1 core can be checked against their hardware VRAM dumps.
#
#   PSN00BSDK  checkout of Lameguy64/PSn00bSDK at tag v0.19 (the API the
#              tests were written against)
#   PS1_TESTS  checkout of JaCzekanski/ps1-tests
#
# Each test is written next to its sources as <name>.exe; then run the
# zemu tests with ZEMU_PS1_TESTS=$PS1_TESTS.
#
# clang cannot assemble cfc2, ctc2 or cop2, so cop2.sh supplies macros that
# emit their encodings, for assembly files and for inline assembly in C.
set -e
SDK=${PSN00BSDK:?set PSN00BSDK}/libpsn00b
TESTS=${PS1_TESTS:?set PS1_TESTS}
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
sh "$HERE/cop2.sh" "$SDK/include/gtereg.h" > "$WORK/cop2.inc"
printf '__asm__(".include \"%s\"");\n' "$WORK/cop2.inc" > "$WORK/cop2.h"
# headers of an older PSn00bSDK that the GTE tests include but do not use
mkdir -p "$WORK/inc" && : > "$WORK/inc/asm.h" && : > "$WORK/inc/gtereg_s.h"

FLAGS="-target mipsel-none-elf -march=mips1 -mabi=32 -msoft-float -G0 -fno-pic -mno-abicalls \
 -ffreestanding -fno-builtin -nostdlib -fdata-sections -ffunction-sections -fsigned-char -O2 -w \
 -I$SDK/include -I$TESTS/common -I$WORK/inc -D__PLAYSTATION__ -DSDK_LIBRARY_NAME=\"psn00b\""

compile() { # source object
	case $1 in
		*.cpp) clang++ $FLAGS -include "$WORK/cop2.h" -fno-exceptions -fno-rtti -std=c++17 -c "$1" -o "$2" ;;
		*.c)   clang $FLAGS -include "$WORK/cop2.h" -c "$1" -o "$2" ;;
		*) # GNU as moves a "nop; jr" pair's nop into the delay slot; LLVM pads
		   # with another nop instead, which breaks one-line jump table entries
		   sed 's/^\([ 	]*\)\([^#]*; *nop; *jr \$ra; *nop\)[ 	\r]*$/\1.set noreorder; \2; .set reorder/' "$1" > "$2.s"
		   clang $FLAGS -I"$(dirname "$1")" -x assembler-with-cpp -include "$WORK/cop2.inc" -c "$2.s" -o "$2" ;;
	esac
}

echo "libpsn00b..."
mkdir -p "$WORK/lib"
for d in libc psxapi psxgpu psxgte psxetc psxpress psxspu psxcd psxsio; do
	for f in $(find "$SDK/$d" -name '*.c' -o -name '*.s' -o -name '*.cpp'); do
		o="$WORK/lib/$(echo "$f" | sed "s|$SDK/||; s|/|_|g").o"
		compile "$f" "$o" 2>/dev/null || rm -f "$o" # a few unused files do not build
	done
done

for main in "$TESTS"/gpu/*/main.c* "$TESTS"/dma/*/main.c* "$TESTS"/timers/main.c* "$TESTS"/cpu/*/main.c* "$TESTS"/gte/*/main.c* "$TESTS"/gte-fuzz/main.c*; do
	[ -f "$main" ] || continue
	dir=$(dirname "$main")
	name=$(basename "$dir")
	obj="$WORK/$name"
	mkdir -p "$obj"
	ok=1
	for f in "$dir"/*.c "$dir"/*.cpp "$dir"/*.s "$TESTS"/common/*.c "$TESTS"/common/*.cpp; do
		[ -f "$f" ] || continue
		compile "$f" "$obj/$(basename "$f").o" 2>/dev/null || { ok=0; break; }
	done
	[ $ok = 1 ] || { echo "skip $name (does not compile)"; continue; }
	extra=""
	llvm-nm "$obj/main.cpp.o" 2>/dev/null | grep -q " T _Z4mainv" && extra="--defsym=main=_Z4mainv"
	if ld.lld -m elf32ltsmip -T "$SDK/ldscripts/exe.ld" --gc-sections $extra -o "$obj/test.elf" "$obj"/*.o "$WORK"/lib/*.o 2>/dev/null; then
		python3 "$HERE/elf2exe.py" "$obj/test.elf" "$dir/$name.exe"
		echo "built $name"
	else
		echo "skip $name (needs libraries this build lacks)"
	fi
done
