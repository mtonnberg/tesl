package teslrt

import (
	"context"
	"strings"
	"testing"
)

func TestPgRowAccessRequiresExactSealedOwner(t *testing.T) {
	owner, other := &Database{}, &Database{}
	slot := NewPgRowAccessSlot[string]()
	expect := func(reason string, run func()) {
		t.Helper()
		var failure any
		func() { defer func() { failure = recover() }(); run() }()
		text, ok := failure.(string)
		if !ok || !strings.Contains(text, reason) {
			t.Fatalf("wrong typed access refusal: %v", failure)
		}
	}
	expect("missing compiled typed", func() { slot.access(owner) })
	registration := &pgRowRegistration{database: owner}
	slot.owners[owner] = &pgRowAccess[string]{sealed: func() bool { return registration.sealed }}
	expect("requires application preflight", func() { slot.access(owner) })
	registration.sealed = true
	if slot.access(owner) != slot.owners[owner] {
		t.Fatal("exact sealed owner was not retained")
	}
	expect("for database", func() { slot.access(other) })
}
func TestPgRowAccessRejectsAbsentTransactionAuthority(t *testing.T) {
	ctx := context.Background()
	if _, _, err := pgReadPhysicalRow[string, string](ctx, nil, nil, "one", false); err == nil {
		t.Fatal("missing transaction granted physical read")
	}
	if _, err := pgUpdatePhysicalRow[string, string](ctx, nil, nil, "one", func(value string) string { return value }); err == nil {
		t.Fatal("missing transaction granted locked update")
	}
}
func TestPgRowQueryOwnsFragmentsAndRefusesComputedPredicates(t *testing.T) {
	parts, fields := []string{" where ", "=$1"}, []string{"count"}
	query := PgRowSQL(parts, fields, nil)
	parts[0] = "arbitrary"
	fields[0] = "id"
	if query.parts[0] != " where " || query.fields[0] != "count" {
		t.Fatal("query retained caller mutable fragments")
	}
	if _, err := query.statement(nil, PgRowTransformDescriptor{}); err == nil || !strings.Contains(err.Error(), "unchanged stored field") {
		t.Fatal("computed query lost exact guard", err)
	}
	if _, err := (PgRowQuery{}).statement(nil, PgRowTransformDescriptor{}); err == nil {
		t.Fatal("missing query fragment shape accepted")
	}
}

func TestPgRowRMWBatchConfiguration(t *testing.T) {
	for _, test := range []struct {
		text string
		want int
	}{{"", 2000}, {"1", 1}, {"37", 37}} {
		t.Setenv("TESL_RMW_BATCH", test.text)
		got, err := pgRowRMWBatch()
		if err != nil || got != test.want {
			t.Fatalf("batch %q: %d %v", test.text, got, err)
		}
	}
	for _, text := range []string{"0", "-1", "1.5", "many", "999999999999999999999999999"} {
		t.Setenv("TESL_RMW_BATCH", text)
		if _, err := pgRowRMWBatch(); err == nil {
			t.Fatalf("invalid batch %q accepted", text)
		}
	}
}

func TestPgRowQueryRetainsFirstParameters(t *testing.T) {
	evaluations := 0
	query := PgRowSQL([]string{" where ", "=$1"}, []string{"id"}, func() []any { evaluations++; return []any{evaluations} }).capturedArguments()
	if evaluations != 0 {
		t.Fatal("query operands evaluated before first driver use")
	}
	first := query.args()
	first[0] = 99
	second := query.args()
	if evaluations != 1 || second[0] != 1 {
		t.Fatal("repeated use re-evaluated or exposed owned parameters", evaluations, second)
	}
}

func TestPgRowQuerySettledUsesCurrentProjection(t *testing.T) {
	entity := &pgRowPhysicalEntity{projection: []pgRowPhysicalField{{logical: "owner", physical: "Owner Current"}}}
	token := &pgRowTransactionAdmission{plan: &pgRowPhysicalPlan{settled: true}, entity: entity}
	query := PgRowSQL([]string{" where ", "=$1"}, []string{"owner"}, nil)
	sql, err := query.statement(token, PgRowTransformDescriptor{})
	if err != nil || sql != ` where "Owner Current"=$1` {
		t.Fatal("settled query used retired Rename source", sql, err)
	}
	query = PgRowSQL([]string{" where ", "=$1"}, []string{"author"}, nil)
	if _, err := query.statement(token, PgRowTransformDescriptor{}); err == nil {
		t.Fatal("settled query admitted retired field")
	}
}

func TestPgRowQueryMissingProjectionRefusesBeforeResolution(t *testing.T) {
	source := "id"
	descriptor := PgRowTransformDescriptor{FieldMapping: []PgRowFieldMapping{{Kind: "copy", Source: &source, Target: "id"}}}
	query := PgRowSQL([]string{" where ", "=$1"}, []string{"id"}, nil)
	for _, token := range []*pgRowTransactionAdmission{nil, {}, {plan: &pgRowPhysicalPlan{}}, {plan: &pgRowPhysicalPlan{settled: true}}} {
		if _, err := query.statement(token, descriptor); err == nil || !strings.Contains(err.Error(), "entity projection") {
			t.Fatal("missing query projection did not fail before resolution", err)
		}
	}
}
