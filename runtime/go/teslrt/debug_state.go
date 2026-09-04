package teslrt

import (
	"fmt"
	"sort"
	"sync"
	"sync/atomic"
	"time"
)

type DebugDomainItem struct {
	Name  string     `json:"name"`
	Kind  string     `json:"kind"`
	Type  string     `json:"type,omitempty"`
	Value DebugValue `json:"value"`
}

type DebugDomainState struct {
	Queues  []DebugDomainItem `json:"queues,omitempty"`
	Caches  []DebugDomainItem `json:"caches,omitempty"`
	SSE     []DebugDomainItem `json:"sse,omitempty"`
	Email   []DebugDomainItem `json:"email,omitempty"`
	Workers []DebugDomainItem `json:"workers,omitempty"`
}

type DebugSQLCapture struct {
	Operation string       `json:"operation,omitempty"`
	SQL       string       `json:"sql"`
	Params    []DebugValue `json:"params,omitempty"`
	Table     string       `json:"table,omitempty"`
	Preview   string       `json:"preview,omitempty"`
	RowCount  int          `json:"row-count,omitempty"`
	ThisLine  bool         `json:"this-line,omitempty"`
}

type DebugRuntimeState struct {
	Domain DebugDomainState `json:"domain"`
	SQL    *DebugSQLCapture `json:"sql,omitempty"`
}

type DebugDomainProvider func() DebugDomainState

type debugProviderEntry struct {
	id       uint64
	provider DebugDomainProvider
}

var debugState = struct {
	sync.RWMutex
	providers []debugProviderEntry
	sql       map[uint64]debugSQLCaptureEntry
	nextID    uint64
}{sql: make(map[uint64]debugSQLCaptureEntry)}

type debugSQLCaptureEntry struct {
	id      uint64
	capture *DebugSQLCapture
}

func RegisterDebugDomainProvider(provider DebugDomainProvider) func() {
	debugState.Lock()
	debugState.nextID++
	id := debugState.nextID
	debugState.providers = append(debugState.providers, debugProviderEntry{id: id, provider: provider})
	debugState.Unlock()
	return func() {
		debugState.Lock()
		for index, registered := range debugState.providers {
			if registered.id == id {
				debugState.providers = append(debugState.providers[:index], debugState.providers[index+1:]...)
				break
			}
		}
		debugState.Unlock()
	}
}

func SetDebugSQLCapture(capture *DebugSQLCapture) {
	setDebugSQLCapture(debugExecutionID(), capture)
}

func ClearDebugSQLCapture() {
	clearDebugSQLCaptureForExecution(debugExecutionID())
}

func DebugRuntimeStateSnapshot() DebugRuntimeState {
	return debugRuntimeStateSnapshotForExecution(debugExecutionID())
}

// debugRuntimeStateSnapshotForExecution returns SQL state owned by one Tesl
// execution. Domain providers are process-wide and are sampled only after the
// debugger's cooperative execution barrier has completed.
func debugRuntimeStateSnapshotForExecution(execution uint64) DebugRuntimeState {
	debugState.RLock()
	providers := append([]debugProviderEntry(nil), debugState.providers...)
	sql := cloneDebugSQL(debugState.sql[execution].capture)
	debugState.RUnlock()
	state := DebugRuntimeState{SQL: sql}
	for _, provider := range providers {
		if provider.provider != nil {
			state.Domain = mergeDebugDomainState(state.Domain, provider.provider())
		}
	}
	return state
}

func setDebugSQLCapture(execution uint64, capture *DebugSQLCapture) uint64 {
	debugState.Lock()
	defer debugState.Unlock()
	if capture == nil {
		delete(debugState.sql, execution)
		return 0
	}
	debugState.nextID++
	id := debugState.nextID
	debugState.sql[execution] = debugSQLCaptureEntry{id: id, capture: cloneDebugSQL(capture)}
	return id
}

func clearDebugSQLCaptureForExecution(execution uint64) {
	debugState.Lock()
	delete(debugState.sql, execution)
	debugState.Unlock()
}

func updateDebugSQLCapture(execution, id uint64, rowCount int) {
	debugState.Lock()
	entry, present := debugState.sql[execution]
	if present && entry.id == id {
		entry.capture.RowCount = rowCount
		debugState.sql[execution] = entry
	}
	debugState.Unlock()
}

func mergeDebugDomainState(left, right DebugDomainState) DebugDomainState {
	left.Queues = append(left.Queues, cloneDebugDomainItems(right.Queues)...)
	left.Caches = append(left.Caches, cloneDebugDomainItems(right.Caches)...)
	left.SSE = append(left.SSE, cloneDebugDomainItems(right.SSE)...)
	left.Email = append(left.Email, cloneDebugDomainItems(right.Email)...)
	left.Workers = append(left.Workers, cloneDebugDomainItems(right.Workers)...)
	return left
}

func cloneDebugDomainItems(items []DebugDomainItem) []DebugDomainItem {
	clone := make([]DebugDomainItem, len(items))
	for index, item := range items {
		clone[index] = item
		clone[index].Value = cloneDebugValue(item.Value)
	}
	return clone
}

func cloneDebugValue(value DebugValue) DebugValue {
	value.Children = cloneDebugValues(value.Children)
	return value
}

func cloneDebugValues(values []DebugValue) []DebugValue {
	clone := make([]DebugValue, len(values))
	for index, value := range values {
		clone[index] = cloneDebugValue(value)
	}
	return clone
}

func cloneDebugSQL(capture *DebugSQLCapture) *DebugSQLCapture {
	if capture == nil {
		return nil
	}
	clone := *capture
	clone.Params = cloneDebugValues(capture.Params)
	return &clone
}

func debugValueOf(value any) DebugValue {
	return DebugValue{Type: fmt.Sprintf("%T", value), Display: fmt.Sprint(value)}
}

func RegisterDebugQueue(queue *Queue) func() {
	return RegisterDebugDomainProvider(func() DebugDomainState {
		queue.mutex.Lock()
		defer queue.mutex.Unlock()
		jobs := make([]DebugValue, 0, len(queue.jobs))
		pending, dead := 0, 0
		ordered := make([]*queuedJob, 0, len(queue.jobs))
		for _, job := range queue.jobs {
			ordered = append(ordered, job)
		}
		sort.Slice(ordered, func(left, right int) bool { return ordered[left].seq < ordered[right].seq })
		for _, job := range ordered {
			if job.status == jobPending {
				pending++
			}
			if job.status == jobDead {
				dead++
			}
			jobs = append(jobs, DebugValue{Type: "Job", Display: fmt.Sprintf("%s — %s", job.status, debugValueOf(job.payload).Display)})
		}
		return DebugDomainState{Queues: []DebugDomainItem{{
			Name: queue.name, Kind: "queue", Type: "Queue",
			Value: DebugValue{Type: "Queue", Display: fmt.Sprintf("%d pending, %d dead", pending, dead), Children: jobs},
		}}}
	})
}

func RegisterDebugCache[V any](cache *Cache[V], name string) func() {
	return RegisterDebugDomainProvider(func() DebugDomainState {
		cache.mutex.Lock()
		defer cache.mutex.Unlock()
		children := make([]DebugValue, 0, len(cache.entries))
		now := time.Now().Unix()
		for key, entry := range cache.entries {
			if entry.expiresAt != 0 && now > entry.expiresAt {
				continue
			}
			children = append(children, DebugValue{Type: "CacheEntry", Display: key + " = " + debugValueOf(entry.value).Display})
		}
		sort.Slice(children, func(left, right int) bool { return children[left].Display < children[right].Display })
		return DebugDomainState{Caches: []DebugDomainItem{{
			Name: name, Kind: "cache", Type: "Cache",
			Value: DebugValue{Type: "Cache", Display: fmt.Sprintf("%d entries", len(children)), Children: children},
		}}}
	})
}

func RegisterDebugSSE(channel *SseChannel) func() {
	return RegisterDebugDomainProvider(func() DebugDomainState {
		channel.mutex.Lock()
		defer channel.mutex.Unlock()
		children := make([]DebugValue, 0, len(channel.listeners))
		for key, listeners := range channel.listeners {
			children = append(children, DebugValue{Type: "SSEKey", Display: fmt.Sprintf("%s: %d connected client(s)", key, len(listeners))})
		}
		sort.Slice(children, func(left, right int) bool { return children[left].Display < children[right].Display })
		return DebugDomainState{SSE: []DebugDomainItem{{
			Name: channel.name, Kind: "sse", Type: "SseChannel",
			Value: DebugValue{Type: "SseChannel", Display: fmt.Sprintf("%d connected client(s)", channel.active), Children: children},
		}}}
	})
}

func RegisterDebugOutbox(outbox *Outbox, name string) func() {
	return RegisterDebugDomainProvider(func() DebugDomainState {
		outbox.mutex.Lock()
		defer outbox.mutex.Unlock()
		children := make([]DebugValue, 0, len(outbox.messages))
		for _, message := range outbox.messages {
			children = append(children, DebugValue{Type: "Email", Display: fmt.Sprintf("email -> %s [%d]", message.Subject, message.Status)})
		}
		return DebugDomainState{Email: []DebugDomainItem{{
			Name: name, Kind: "email", Type: "Outbox",
			Value: DebugValue{Type: "Outbox", Display: fmt.Sprintf("%d messages", len(children)), Children: children},
		}}}
	})
}

func RegisterDebugWorkers(queue *Queue, total int, dead bool) func() {
	pool := &debugWorkerPool{queue: queue, total: total, dead: dead}
	return registerDebugWorkerPool(pool)
}

type debugWorkerPool struct {
	queue  *Queue
	total  int
	dead   bool
	active atomic.Int64
}

func registerDebugWorkerPool(pool *debugWorkerPool) func() {
	return RegisterDebugDomainProvider(func() DebugDomainState {
		label := pool.queue.name + " workers"
		if pool.dead {
			label = pool.queue.name + " dead workers"
		}
		return DebugDomainState{Workers: []DebugDomainItem{{
			Name: label, Kind: "worker", Type: "WorkerPool",
			Value: DebugValue{Type: "WorkerPool", Display: fmt.Sprintf("%d live / %d total", pool.active.Load(), pool.total)},
		}}}
	})
}

func DebugStartWorkers(queue *Queue, handler func(any) JobOutcome, concurrency int, dead bool) struct{} {
	if concurrency < 1 {
		concurrency = 1
	}
	pool := &debugWorkerPool{queue: queue, total: concurrency, dead: dead}
	remove := registerDebugWorkerPool(pool)
	_ = remove
	return startWorkers(queue, handler, concurrency, dead, func(active bool) {
		if active {
			pool.active.Add(1)
		} else {
			pool.active.Add(-1)
		}
	})
}
