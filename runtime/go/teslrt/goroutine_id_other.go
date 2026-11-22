//go:build !amd64 && !arm64

package teslrt

func discoverGoroutineIDOffset() {}

func fastGoroutineID(int) uint64 { return goroutineIDFromStack() }
