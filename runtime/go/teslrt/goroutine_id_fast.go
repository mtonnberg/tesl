//go:build amd64 || arm64

package teslrt

import "sync"

// goroutineRecordWord reads the 8-byte word at offset in the current
// goroutine's runtime record (goroutine_id_*.s). The read happens in assembly,
// so no Go pointer into runtime memory is formed.
func goroutineRecordWord(offset uintptr) uint64

const goroutineIDSamples = 8

// goroutineIDSearchLimit bounds the search to the start of the record, which
// holds the id in every supported Go release.
const goroutineIDSearchLimit = 512

// discoverGoroutineIDOffset accepts an offset only if, on every sampled
// goroutine, it is the one place in the searched prefix holding exactly that
// goroutine's id. Any ambiguity or miss leaves the stack-header path in use.
func discoverGoroutineIDOffset() {
	matches := map[uintptr]int{}
	var mutex sync.Mutex
	var group sync.WaitGroup
	for range goroutineIDSamples {
		group.Add(1)
		go func() {
			defer group.Done()
			id := goroutineIDFromStack()
			found := []uintptr{}
			for offset := uintptr(0); offset < goroutineIDSearchLimit; offset += 8 {
				if goroutineRecordWord(offset) == id {
					found = append(found, offset)
				}
			}
			mutex.Lock()
			for _, offset := range found {
				matches[offset]++
			}
			mutex.Unlock()
		}()
	}
	group.Wait()
	chosen := -1
	for offset, count := range matches {
		if count != goroutineIDSamples {
			continue
		}
		if chosen >= 0 {
			return
		}
		chosen = int(offset)
	}
	if chosen >= 0 && fastGoroutineID(chosen) == goroutineIDFromStack() {
		goroutineIDOffset = chosen
	}
}

func fastGoroutineID(offset int) uint64 {
	return goroutineRecordWord(uintptr(offset))
}
