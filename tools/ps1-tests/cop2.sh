#!/bin/sh
# Writes assembler macros for the GTE instructions clang cannot assemble
# (cfc2, ctc2, cop2): they emit the raw encodings. LLVM looks macros up
# before instructions, so these take the instructions' place.
#   usage: cop2.sh gtereg.h > cop2.inc
reg() { printf '\t.ifc \\r,%s\n\t\t.set _zemu_n, %s\n\t.endif\n' "$1" "$2"; }
printf '.macro _zemu_reg r\n'
i=0
for n in zero at v0 v1 a0 a1 a2 a3 t0 t1 t2 t3 t4 t5 t6 t7 s0 s1 s2 s3 s4 s5 s6 s7 t8 t9 k0 k1 gp sp fp ra; do
	reg "\$$n" $i; reg "\$$i" $i; i=$((i+1))
done
reg '$s8' 30
sed -n '/control registers/,$p' "$1" | sed -n 's/^\.set[ 	]*\(C2_[A-Z0-9]*\),[ 	]*\$\([0-9]*\).*/\1 \2/p' |
	while read n v; do reg "$n" "$v"; done
printf '.endm\n'
cat <<'M'
.macro cfc2 rt, rd
	_zemu_reg \rt
	.set _zemu_t, _zemu_n
	_zemu_reg \rd
	.word 0x48400000 | (_zemu_t << 16) | (_zemu_n << 11)
.endm
.macro ctc2 rt, rd
	_zemu_reg \rt
	.set _zemu_t, _zemu_n
	_zemu_reg \rd
	.word 0x48C00000 | (_zemu_t << 16) | (_zemu_n << 11)
.endm
.macro cop2 op
	.word 0x4A000000 | (\op)
.endm
M
