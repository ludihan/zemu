	.set noreorder
	.text
	.globl _start
_start:
	lui $gp, %hi(_gp)
	addiu $gp, $gp, %lo(_gp)
	jal run
	nop
1:	b 1b
	nop
