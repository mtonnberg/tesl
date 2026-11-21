#include "textflag.h"

// func goroutineRecordWord(offset uintptr) uint64
// Reads the 8-byte word at offset in the current goroutine's runtime record.
TEXT ·goroutineRecordWord(SB),NOSPLIT,$0-16
	MOVQ (TLS), AX
	MOVQ offset+0(FP), BX
	MOVQ (AX)(BX*1), AX
	MOVQ AX, ret+8(FP)
	RET
