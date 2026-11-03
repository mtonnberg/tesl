package teslrt

import (
	"bytes"
	"context"
	"strings"
	"sync"
)

type pgRowAppOutput struct {
	mutex   sync.Mutex
	data    bytes.Buffer
	changed chan struct{}
}

func (b *pgRowAppOutput) Write(p []byte) (int, error) {
	b.mutex.Lock()
	defer b.mutex.Unlock()
	n, err := b.data.Write(p)
	if b.changed != nil {
		close(b.changed)
	}
	b.changed = make(chan struct{})
	return n, err
}
func (b *pgRowAppOutput) String() string {
	b.mutex.Lock()
	defer b.mutex.Unlock()
	return b.data.String()
}

// HTTP completion and the parent's stderr-copy goroutine are independent.
// Await the observed output event rather than assuming the pipe has drained.
func (b *pgRowAppOutput) WaitContains(ctx context.Context, text string) bool {
	for {
		b.mutex.Lock()
		if strings.Contains(b.data.String(), text) {
			b.mutex.Unlock()
			return true
		}
		if b.changed == nil {
			b.changed = make(chan struct{})
		}
		changed := b.changed
		b.mutex.Unlock()
		select {
		case <-ctx.Done():
			return false
		case <-changed:
		}
	}
}
