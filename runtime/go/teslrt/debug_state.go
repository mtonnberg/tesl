package teslrt

import "sync"

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
	sql       *DebugSQLCapture
	nextID    uint64
}{}

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
	debugState.Lock()
	debugState.sql = cloneDebugSQL(capture)
	debugState.Unlock()
}

func ClearDebugSQLCapture() {
	SetDebugSQLCapture(nil)
}

func DebugRuntimeStateSnapshot() DebugRuntimeState {
	debugState.RLock()
	providers := append([]debugProviderEntry(nil), debugState.providers...)
	sql := cloneDebugSQL(debugState.sql)
	debugState.RUnlock()
	state := DebugRuntimeState{SQL: sql}
	for _, provider := range providers {
		if provider.provider != nil {
			state.Domain = mergeDebugDomainState(state.Domain, provider.provider())
		}
	}
	return state
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
