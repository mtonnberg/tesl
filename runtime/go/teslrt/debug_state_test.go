package teslrt

import "testing"

func TestDebugRuntimeStateProviderAndSQLCapture(t *testing.T) {
	remove := RegisterDebugDomainProvider(func() DebugDomainState {
		return DebugDomainState{Queues: []DebugDomainItem{{
			Name: "jobs", Kind: "queue", Type: "Queue",
			Value: DebugValue{Type: "Queue", Display: "1 pending"},
		}}}
	})
	defer remove()
	SetDebugSQLCapture(&DebugSQLCapture{
		Operation: "select", SQL: "select 1", Table: "items", RowCount: 1,
	})
	defer ClearDebugSQLCapture()

	state := DebugRuntimeStateSnapshot()
	if len(state.Domain.Queues) != 1 || state.Domain.Queues[0].Name != "jobs" {
		t.Fatalf("domain state = %#v", state.Domain)
	}
	if state.SQL == nil || state.SQL.Operation != "select" || state.SQL.RowCount != 1 {
		t.Fatalf("SQL state = %#v", state.SQL)
	}
	remove()
	ClearDebugSQLCapture()
	state = DebugRuntimeStateSnapshot()
	if len(state.Domain.Queues) != 0 || state.SQL != nil {
		t.Fatalf("state after cleanup = %#v", state)
	}
}
