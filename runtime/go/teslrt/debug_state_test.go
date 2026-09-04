package teslrt

import (
	"strings"
	"testing"
)

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

func TestDebugPgSqlCapturesParameterizedPlan(t *testing.T) {
	ClearDebugSQLCapture()
	plan := DebugPgSql(PgSql("select * from items where id = $1", func() []any {
		return []any{"item-7"}
	}))
	arguments := plan.arguments()
	if len(arguments) != 1 || arguments[0] != "item-7" {
		t.Fatalf("arguments = %#v", arguments)
	}
	state := DebugRuntimeStateSnapshot()
	if state.SQL == nil || state.SQL.SQL != "select * from items where id = $1" || state.SQL.Operation != "select" || state.SQL.Table != "items" || state.SQL.Preview != "select * from items where id = 'item-7'" || len(state.SQL.Params) != 1 || state.SQL.Params[0].Display != "item-7" {
		t.Fatalf("SQL capture = %#v", state.SQL)
	}
	plan.Capture(3)
	if state := DebugRuntimeStateSnapshot(); state.SQL == nil || state.SQL.RowCount != 3 {
		t.Fatalf("SQL row count = %#v", state.SQL)
	}
	ClearDebugSQLCapture()
}

func TestDebugSQLPreviewPreservesParameterBoundariesAndTableCase(t *testing.T) {
	ClearDebugSQLCapture()
	arguments := make([]any, 10)
	for index := range arguments {
		arguments[index] = "value-" + string(rune('a'+index))
	}
	plan := DebugPgSql(PgSql(`select $10, $1 from "MixedCase"`, func() []any {
		return arguments
	}))
	plan.arguments()
	state := DebugRuntimeStateSnapshot()
	if state.SQL == nil || state.SQL.Table != "MixedCase" || state.SQL.Preview != `select 'value-j', 'value-a' from "MixedCase"` {
		t.Fatalf("SQL preview = %#v", state.SQL)
	}
	ClearDebugSQLCapture()
}

// The `--debug` SQL capture renders every bound parameter into `Params` and `Preview`. A
// `secret` column's parameter used to be a bare plaintext string and appeared in both
// (whitebox campaign, 2026-09-02); it now travels as a SecretParam and renders redacted.
func TestDebugPgSqlRedactsSecretParameters(t *testing.T) {
	ClearDebugSQLCapture()
	plan := DebugPgSql(PgSql(`insert into creds ("id", "key") values ($1, $2)`, func() []any {
		return []any{"k1", PgSecret(MakeSecret("api-key-SECRET-999"))}
	}))
	arguments := plan.arguments()
	if len(arguments) != 2 {
		t.Fatalf("arguments = %#v", arguments)
	}
	if value, err := arguments[1].(SecretParam).Value(); err != nil || value != "api-key-SECRET-999" {
		t.Fatalf("the driver must still receive the plaintext, got %v %v", value, err)
	}
	state := DebugRuntimeStateSnapshot()
	if state.SQL == nil {
		t.Fatal("no SQL capture")
	}
	for _, text := range []string{state.SQL.Preview, state.SQL.Params[1].Display, state.SQL.Params[1].Type} {
		if strings.Contains(text, "SECRET-999") {
			t.Fatalf("the debug SQL capture rendered a secret parameter's plaintext: %#v", state.SQL)
		}
	}
	if state.SQL.Params[1].Display != SecretRedaction {
		t.Fatalf("secret parameter display = %q, want the redaction", state.SQL.Params[1].Display)
	}
	ClearDebugSQLCapture()
}
