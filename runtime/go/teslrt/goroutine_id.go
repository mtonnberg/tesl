package teslrt

import "sync"

// Transactions and migration execution budgets are keyed by goroutine. Reading
// the id from a formatted stack trace (goroutineIDFromStack) unwinds and prints
// the whole stack under a runtime lock: about 20µs at an ordinary request depth,
// paid at every database call and at every entry into a metered migration
// function. Where the architecture allows, goroutineID instead reads the id from
// the runtime's goroutine record, at an offset found once and accepted only if
// it matches goroutineIDFromStack on several goroutines.
var goroutineIDOnce sync.Once

// goroutineIDOffset is the verified offset of the id in the goroutine record,
// or -1 when the fast path is unavailable.
var goroutineIDOffset = -1

func goroutineID() uint64 {
	goroutineIDOnce.Do(discoverGoroutineIDOffset)
	if goroutineIDOffset >= 0 {
		return fastGoroutineID(goroutineIDOffset)
	}
	return goroutineIDFromStack()
}
