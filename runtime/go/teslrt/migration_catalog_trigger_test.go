package teslrt

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"reflect"
	"slices"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

func pgTriggerCatalogTest(t *testing.T) *pgControlTestFixture {
	t.Helper()
	f := pgNewControlTest(t)
	f.install(t, 1)
	for _, statement := range []string{
		`create table notes_app.items(id text primary key, value text)`,
		`alter table notes_app.items owner to ` + quoteIdentifier(f.roles.Worker),
		`create function notes_app.invalidate() returns trigger language plpgsql volatile security definer set search_path='' as $$begin raise exception 'catalog inspection executed stored trigger code'; end$$`,
		`alter function notes_app.invalidate() owner to ` + quoteIdentifier(f.roles.Owner),
		`revoke all on function notes_app.invalidate() from public`,
		`grant execute on function notes_app.invalidate() to ` + quoteIdentifier(f.roles.Worker),
	} {
		if _, err := f.installer.Exec(f.ctx, statement); err != nil {
			t.Fatal(err)
		}
	}
	return f
}

const pgTriggerTestDefinition = `create trigger invalidate before update of value on notes_app.items for each row when (old.value is distinct from new.value) execute function notes_app.invalidate('source','å''雪')`

func pgTriggerObserved(t *testing.T, f *pgControlTestFixture, tx pgx.Tx, table string, roles []string) *pgCatalogTable {
	t.Helper()
	observed, err := pgReadMigrationTableForRoles(f.ctx, tx, f.namespace, table, roles)
	if err != nil || observed == nil {
		t.Fatalf("trigger observation: table=%v err=%v", observed, err)
	}
	return observed
}
func pgTriggerFingerprint(t *testing.T, f *pgControlTestFixture, observed *pgCatalogTable) string {
	t.Helper()
	report, err := pgFinishMigrationCatalogReport(PgMigrationCatalogReport{}, f.namespace, f.roles.Worker, []*pgCatalogTable{observed})
	if err != nil {
		t.Fatal(err)
	}
	return report.Fingerprint
}
func pgTriggerTestTx(t *testing.T, f *pgControlTestFixture) pgx.Tx {
	t.Helper()
	tx, err := f.installer.BeginTx(f.ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = tx.Rollback(context.Background()) })
	if err := pgControlSession(f.ctx, tx); err != nil {
		t.Fatal(err)
	}
	return tx
}

func TestPgMigrationTriggerCatalogNoTriggerFingerprintRemainsStable(t *testing.T) {
	f := pgTriggerCatalogTest(t)
	reader := pgCatalogTestReader(t, f)
	pgReadOnlyCatalogTestTransaction(t, f, reader, func(tx pgx.Tx) {
		table := pgTriggerObserved(t, f, tx, "items", nil)
		if table.TriggerDefinitions != nil || len(table.Triggers) != 0 {
			t.Fatal("invented trigger observation")
		}
		// The pre-observer encoded shape and domain remain identical, rather than
		// changing every installed no-trigger catalog fingerprint for this addition.
		legacy := struct {
			Name, Kind, Persistence, Owner, Method string
			RLS, ForceRLS, Partition, Inherits     bool
			Columns                                []pgCatalogColumn
			Indexes                                []pgCatalogIndex
			Constraints                            []pgCatalogConstraint
			Triggers, Policies, Rules              []string
		}{}
		canonical := pgCanonicalMigrationTable(table)
		encoded, err := json.Marshal(canonical)
		if err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(encoded, &legacy); err != nil {
			t.Fatal(err)
		}
		legacyEncoded, err := json.Marshal(legacy)
		if err != nil {
			t.Fatal(err)
		}
		if string(encoded) != string(legacyEncoded) {
			t.Fatal("no-trigger encoded shape changed")
		}
		framed, err := json.Marshal(struct {
			Namespace, Owner string
			Tables           []json.RawMessage
		}{f.namespace, f.roles.Worker, []json.RawMessage{legacyEncoded}})
		if err != nil {
			t.Fatal(err)
		}
		sum := sha256.Sum256(append([]byte("tesl-postgres-catalog-v1\x00"), framed...))
		if pgTriggerFingerprint(t, f, table) != hex.EncodeToString(sum[:]) {
			t.Fatal("no-trigger fingerprint changed")
		}
	})
}

func TestPgMigrationTriggerCatalogReadOnlyCompleteObservation(t *testing.T) {
	f := pgTriggerCatalogTest(t)
	if _, err := f.installer.Exec(f.ctx, pgTriggerTestDefinition); err != nil {
		t.Fatal(err)
	}
	reader := pgCatalogTestReader(t, f)
	pgReadOnlyCatalogTestTransaction(t, f, reader, func(tx pgx.Tx) {
		table := pgTriggerObserved(t, f, tx, "items", []string{f.roles.Worker, f.roles.Owner, f.roles.Worker})
		if len(table.TriggerDefinitions) != 1 || !reflect.DeepEqual(table.Triggers, []string{"invalidate"}) {
			t.Fatal(table)
		}
		tr := table.TriggerDefinitions[0]
		if tr.Relation != (pgCatalogRelationReference{Namespace: f.namespace, Name: "items", Kind: "r"}) || tr.Name != "invalidate" || tr.Type != 19 || tr.Enabled != "O" || tr.Internal || tr.Deferrable || tr.InitiallyDeferred || !tr.HasCondition ||
			!reflect.DeepEqual(tr.Columns, []int{2}) || tr.ArgumentCount != 2 || tr.ArgumentsHex != hex.EncodeToString([]byte("source\x00å'雪\x00")) ||
			tr.OldTransitionTable != nil || tr.NewTransitionTable != nil || tr.Constraint != nil || tr.ConstraintRelation != nil || tr.ConstraintIndex != nil || tr.Parent != nil ||
			!strings.Contains(tr.Definition, "old.value IS DISTINCT FROM new.value") {
			t.Fatalf("incomplete trigger: %+v", tr)
		}
		fn := tr.Function
		if fn.Namespace != f.namespace || fn.Name != "invalidate" || fn.Owner != f.roles.Owner || fn.Language != "plpgsql" || fn.Kind != "f" || fn.Arguments != "" || fn.IdentityArguments != "" || fn.Result != "trigger" ||
			fn.Volatility != "v" || fn.Parallel != "u" || !fn.SecurityDefiner || fn.Strict || fn.Leakproof || fn.SetReturning || fn.ArgumentCount != 0 || fn.DefaultCount != 0 ||
			fn.ResultType != (pgCatalogTypeReference{Namespace: "pg_catalog", Name: "trigger", Kind: "p"}) || fn.VariadicType != nil || fn.Support != nil || fn.SQLBody != nil ||
			!strings.Contains(fn.Source, "catalog inspection executed stored trigger code") || !strings.Contains(fn.Definition, "SECURITY DEFINER") || !reflect.DeepEqual(fn.Configuration, []string{`search_path=""`}) {
			t.Fatalf("incomplete function: %+v", fn)
		}
		if len(fn.ACL) != 2 || len(fn.Roles) != 2 {
			t.Fatalf("ACL/role observation: %+v", fn)
		}
		for _, a := range fn.ACL {
			if a.Grantee == "PUBLIC" || a.Privilege != "EXECUTE" || a.Grantable {
				t.Fatal(a)
			}
		}
		for _, r := range fn.Roles {
			if !r.Exists || !r.Execute || r.Superuser || r.CreateRole {
				t.Fatal(r)
			}
			if r.Role == f.roles.Worker && (r.MemberOfOwner || r.InheritsOwner || r.CanSetOwner || r.GrantExecute) {
				t.Fatal(r)
			}
		}
		expected := []PgMigrationCatalogTable{{Name: "items", Columns: []PgMigrationCatalogColumn{{Name: "id", Type: "text", PrimaryKey: true}, {Name: "value", Type: "text", Nullable: true}}}}
		report, ready, err := pgInspectMigrationCatalogWithIndexJobsInTx(f.ctx, tx, f.namespace, f.roles.Worker, expected, nil, 1)
		if err != nil || ready || !slices.ContainsFunc(report.Drift, func(i PgMigrationCatalogIssue) bool {
			return i.Object == "invalidate" && i.Reason == "unrecorded trigger"
		}) {
			t.Fatalf("observer enabled an unrecorded trigger: ready=%v report=%+v err=%v", ready, report, err)
		}
		if _, err := pgReadMigrationTableForRoles(f.ctx, tx, f.namespace, "items", []string{"missing_catalog_role"}); err == nil {
			t.Fatal("missing declared role disappeared")
		}
	})
}

func TestPgMigrationTriggerCatalogMutationFingerprints(t *testing.T) {
	f := pgTriggerCatalogTest(t)
	if _, err := f.installer.Exec(f.ctx, pgTriggerTestDefinition); err != nil {
		t.Fatal(err)
	}
	replaceTrigger := func(def string) string { return `drop trigger invalidate on notes_app.items; ` + def }
	cases := []struct{ name, sql string }{
		{"disabled", `alter table notes_app.items disable trigger invalidate`},
		{"replica", `alter table notes_app.items enable replica trigger invalidate`},
		{"always", `alter table notes_app.items enable always trigger invalidate`},
		{"timing", replaceTrigger(strings.Replace(pgTriggerTestDefinition, "before update", "after update", 1))},
		{"columns", replaceTrigger(strings.Replace(pgTriggerTestDefinition, "update of value", "update of id", 1))},
		{"arguments", replaceTrigger(strings.Replace(pgTriggerTestDefinition, "'source'", "'other'", 1))},
		{"when", replaceTrigger(strings.Replace(pgTriggerTestDefinition, "is distinct from", "is not distinct from", 1))},
		{"events_and_statement", replaceTrigger(`create trigger invalidate after insert or update or delete or truncate on notes_app.items for each statement execute function notes_app.invalidate()`)},
		{"function_body", `create or replace function notes_app.invalidate() returns trigger language plpgsql volatile security definer set search_path='' as $$begin return new; end$$`},
		{"function_identity", `create function notes_app.other_invalidator() returns trigger language plpgsql as $$begin raise exception 'catalog inspection executed stored trigger code'; end$$; ` + replaceTrigger(strings.Replace(pgTriggerTestDefinition, "notes_app.invalidate(", "notes_app.other_invalidator(", 1))},
		{"function_language", `create or replace function notes_app.invalidate() returns trigger language internal as 'suppress_redundant_updates_trigger'`},
		{"function_security", `alter function notes_app.invalidate() security invoker`},
		{"function_strict", `alter function notes_app.invalidate() strict`},
		{"function_leakproof", `alter function notes_app.invalidate() leakproof`},
		{"function_volatility", `alter function notes_app.invalidate() stable`},
		{"function_parallel", `alter function notes_app.invalidate() parallel safe`},
		{"function_configuration", `alter function notes_app.invalidate() set search_path='public'`},
		{"function_cost", `alter function notes_app.invalidate() cost 42`},
		{"function_owner", `alter function notes_app.invalidate() owner to ` + quoteIdentifier(f.roles.Worker)},
		{"public_execute", `grant execute on function notes_app.invalidate() to public`},
		{"execute_grant_option", `grant execute on function notes_app.invalidate() to ` + quoteIdentifier(f.roles.Worker) + ` with grant option`},
		{"execute_revoked", `revoke execute on function notes_app.invalidate() from ` + quoteIdentifier(f.roles.Worker)},
		{"owner_membership", `grant ` + quoteIdentifier(f.roles.Owner) + ` to ` + quoteIdentifier(f.roles.Worker)},
		{"schema_usage", `revoke usage on schema notes_app from ` + quoteIdentifier(f.roles.Worker)},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			tx := pgTriggerTestTx(t, f)
			old := pgTriggerObserved(t, f, tx, "items", []string{f.roles.Worker})
			before := pgTriggerFingerprint(t, f, old)
			if _, err := tx.Exec(f.ctx, tc.sql); err != nil {
				t.Fatal(err)
			}
			changed := pgTriggerObserved(t, f, tx, "items", []string{f.roles.Worker})
			if !reflect.DeepEqual(old.Triggers, changed.Triggers) || reflect.DeepEqual(old.TriggerDefinitions, changed.TriggerDefinitions) || before == pgTriggerFingerprint(t, f, changed) {
				t.Fatalf("same-named trigger/function mutation escaped observation: %s", tc.name)
			}
		})
	}
}

func TestPgMigrationTriggerCatalogEffectiveRoleClosure(t *testing.T) {
	f := pgTriggerCatalogTest(t)
	if _, err := f.installer.Exec(f.ctx, pgTriggerTestDefinition); err != nil {
		t.Fatal(err)
	}
	t.Run("unrelated_role_is_not_catalog_drift", func(t *testing.T) {
		tx := pgTriggerTestTx(t, f)
		old := pgTriggerObserved(t, f, tx, "items", []string{f.roles.Worker})
		if _, err := tx.Exec(f.ctx, "create role "+quoteIdentifier(f.roles.Worker+"_unrelated")); err != nil {
			t.Fatal(err)
		}
		fresh := pgTriggerObserved(t, f, tx, "items", []string{f.roles.Worker})
		if !reflect.DeepEqual(old, fresh) || pgTriggerFingerprint(t, f, old) != pgTriggerFingerprint(t, f, fresh) {
			t.Fatal("unrelated role changed fingerprint")
		}
	})
	t.Run("inherited_execute_is_observed", func(t *testing.T) {
		tx := pgTriggerTestTx(t, f)
		group := quoteIdentifier(f.roles.Worker + "_group")
		if _, err := tx.Exec(f.ctx, "create role "+group+`; revoke execute on function notes_app.invalidate() from `+quoteIdentifier(f.roles.Worker)+`; grant execute on function notes_app.invalidate() to `+group); err != nil {
			t.Fatal(err)
		}
		old := pgTriggerObserved(t, f, tx, "items", []string{f.roles.Worker})
		if old.TriggerDefinitions[0].Function.Roles[0].Execute {
			t.Fatal("ungranted member can execute")
		}
		if _, err := tx.Exec(f.ctx, "grant "+group+" to "+quoteIdentifier(f.roles.Worker)); err != nil {
			t.Fatal(err)
		}
		fresh := pgTriggerObserved(t, f, tx, "items", []string{f.roles.Worker})
		a, b := old.TriggerDefinitions[0].Function, fresh.TriggerDefinitions[0].Function
		if !b.Roles[0].Execute || !reflect.DeepEqual(a.ACL, b.ACL) || pgTriggerFingerprint(t, f, old) == pgTriggerFingerprint(t, f, fresh) {
			t.Fatal("effective execute did not track inherited grant")
		}
	})
}

func TestPgMigrationTriggerCatalogConstraintTransitionsAndParent(t *testing.T) {
	f := pgTriggerCatalogTest(t)
	tx := pgTriggerTestTx(t, f)
	for _, statement := range []string{
		`create constraint trigger deferred_check after update on notes_app.items deferrable initially deferred for each row execute function notes_app.invalidate()`,
		`create trigger transitions after update on notes_app.items referencing old table as previous_rows new table as current_rows for each statement execute function notes_app.invalidate()`,
		`create table notes_app.parent_items(id integer primary key) partition by range(id)`,
		`create table notes_app.child_items partition of notes_app.parent_items for values from (0) to (10)`,
		`create trigger partition_trigger before update on notes_app.parent_items for each row execute function notes_app.invalidate()`,
		`create table notes_app.referencing_items(id integer references notes_app.parent_items(id))`,
	} {
		if _, err := tx.Exec(f.ctx, statement); err != nil {
			t.Fatal(err)
		}
	}
	table := pgTriggerObserved(t, f, tx, "items", nil)
	if len(table.TriggerDefinitions) != 2 {
		t.Fatal(table)
	}
	constraint, transitions := table.TriggerDefinitions[0], table.TriggerDefinitions[1]
	if constraint.Name != "deferred_check" || !constraint.Deferrable || !constraint.InitiallyDeferred || constraint.Constraint == nil || constraint.Constraint.Name != "deferred_check" || constraint.Constraint.Kind != "t" || !constraint.Constraint.Deferrable || !constraint.Constraint.InitiallyDeferred {
		t.Fatalf("constraint trigger incomplete: %+v", constraint)
	}
	if transitions.Name != "transitions" || transitions.Type != 16 || transitions.OldTransitionTable == nil || *transitions.OldTransitionTable != "previous_rows" || transitions.NewTransitionTable == nil || *transitions.NewTransitionTable != "current_rows" {
		t.Fatalf("transition trigger incomplete: %+v", transitions)
	}
	child := pgTriggerObserved(t, f, tx, "child_items", nil)
	if !slices.ContainsFunc(child.TriggerDefinitions, func(tr pgCatalogTrigger) bool {
		return tr.Name == "partition_trigger" && tr.Parent != nil && *tr.Parent == (pgCatalogTriggerReference{Namespace: f.namespace, Table: "parent_items", Name: "partition_trigger"})
	}) {
		t.Fatalf("partition trigger parent missing: %+v", child.TriggerDefinitions)
	}
	foreign := pgTriggerObserved(t, f, tx, "referencing_items", nil)
	if len(foreign.TriggerDefinitions) != 2 {
		t.Fatal(foreign)
	}
	for _, tr := range foreign.TriggerDefinitions {
		if !tr.Internal || tr.Constraint == nil || tr.Constraint.Kind != "f" || tr.ConstraintIndex == nil || tr.ConstraintRelation == nil || tr.Function.Namespace != "pg_catalog" || tr.Function.Language != "internal" || tr.Function.ResultType.Name != "trigger" {
			t.Fatalf("internal FK trigger incomplete: %+v", tr)
		}
	}
}

func TestPgMigrationTriggerCatalogExactInvalidationLocation(t *testing.T) {
	f := pgTriggerCatalogTest(t)
	f.call(t, `create table notes_app.generation_items(id text primary key,value text,_tesl_v smallint not null default 1)`)
	f.call(t, `create table notes_app.wrong_items(id text primary key,value text,_tesl_v smallint not null default 1)`)
	rule := pgInstallRowGenerationTestRule(t, f, "generation_items", 1, 2, []string{"value"})
	reader := pgCatalogTestReader(t, f)
	pgReadOnlyCatalogTestTransaction(t, f, reader, func(tx pgx.Tx) {
		actual := pgTriggerObserved(t, f, tx, "generation_items", nil)
		if len(actual.TriggerDefinitions) != 1 {
			t.Fatal(actual)
		}
		if err := rule.checkTrigger(actual.TriggerDefinitions[0], f.roles.Worker); err != nil {
			t.Fatalf("actual generated invalidation rejected: %v", err)
		}
	})
	f.call(t, "create trigger "+quoteIdentifier(rule.functionName())+" before update on notes_app.wrong_items for each row execute function "+pgx.Identifier{f.namespace, rule.functionName()}.Sanitize()+"()")
	pgReadOnlyCatalogTestTransaction(t, f, reader, func(tx pgx.Tx) {
		wrong := pgTriggerObserved(t, f, tx, "wrong_items", nil)
		if len(wrong.TriggerDefinitions) != 1 {
			t.Fatal(wrong)
		}
		if err := rule.checkTrigger(wrong.TriggerDefinitions[0], f.roles.Worker); err == nil {
			t.Fatal("identical trigger/function on wrong table accepted")
		}
	})
}
