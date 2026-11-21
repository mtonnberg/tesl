#include "textflag.h"

// func goroutineRecordWord(offset uintptr) uint64
// Reads the 8-byte word at offset in the current goroutine's runtime record.
TEXT ·goroutineRecordWord(SB),NOSPLIT,$0-16
	MOVD offset+0(FP), R1
	MOVD (g)(R1), R0
	MOVD R0, ret+8(FP)
	RET
