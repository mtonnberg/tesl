package teslrt

import (
	"sync"
	"testing"
)

// The fast goroutine id must equal the stack-header id on every goroutine,
// including ones started long after discovery and deep inside call stacks.
func TestGoroutineIDMatchesStackHeader(t *testing.T) {
	if goroutineID() != goroutineIDFromStack() {
		t.Fatal("goroutine id differs on the test goroutine")
	}
	var group sync.WaitGroup
	for i := range 200 {
		group.Add(1)
		go func() {
			defer group.Done()
			var descend func(int)
			descend = func(depth int) {
				if depth > 0 {
					descend(depth - 1)
					return
				}
				if got, want := goroutineID(), goroutineIDFromStack(); got != want {
					t.Errorf("goroutine id %d, stack header says %d", got, want)
				}
			}
			descend(i % 60)
		}()
	}
	group.Wait()
	t.Logf("fast path offset %d", goroutineIDOffset)
}

func BenchmarkGoroutineID(b *testing.B) {
	for b.Loop() {
		goroutineID()
	}
}

func BenchmarkGoroutineIDFromStack(b *testing.B) {
	for b.Loop() {
		goroutineIDFromStack()
	}
}
