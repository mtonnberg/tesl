package teslrt

import (
	"bytes"
	"sync"
)

type pgRowAppOutput struct {
	mutex sync.Mutex
	data  bytes.Buffer
}

func (b *pgRowAppOutput) Write(p []byte) (int, error) {
	b.mutex.Lock()
	defer b.mutex.Unlock()
	return b.data.Write(p)
}
func (b *pgRowAppOutput) String() string {
	b.mutex.Lock()
	defer b.mutex.Unlock()
	return b.data.String()
}
