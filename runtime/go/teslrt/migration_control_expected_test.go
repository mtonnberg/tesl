package teslrt

import (
	"context"
	"encoding/json"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

func pgControlExpectedSpecs() []pgMigrationControlTable {
	specs := append([]pgMigrationControlTable{}, pgMigrationControlTables...)
	return append(specs, pgMigrationFenceRegistry)
}

func pgControlExpectedNamespace(f *pgControlTestFixture, spec pgMigrationControlTable) string {
	if spec == pgMigrationFenceRegistry {
		return "public"
	}
	return f.namespace
}

func pgControlExpectedTransaction(t *testing.T, f *pgControlTestFixture, conn *pgx.Conn, readOnly bool) pgx.Tx {
	t.Helper()
	options := pgx.TxOptions{IsoLevel: pgx.RepeatableRead}
	if readOnly {
		options.AccessMode = pgx.ReadOnly
	}
	tx, err := conn.BeginTx(f.ctx, options)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = tx.Rollback(ctx)
	})
	if err := pgControlSession(f.ctx, tx); err != nil {
		t.Fatal(err)
	}
	return tx
}

// INV-PRIVILEGE, INV-REGISTRY-SHAPE: every closed descriptor is compared with
// PostgreSQL's independent DDL probe on each mandatory supported-major lane.
func TestPgMigrationControlReadOnlyExpectationsMatchServerProbes(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	tx := pgControlExpectedTransaction(t, f, f.worker, false)
	metadata, err := pgReadCatalogExpectations(f.ctx, tx)
	if err != nil {
		t.Fatal(err)
	}
	for _, spec := range pgControlExpectedSpecs() {
		namespace := pgControlExpectedNamespace(f, spec)
		actual, err := pgReadMigrationTable(f.ctx, tx, namespace, spec.name)
		if err != nil || actual == nil {
			t.Fatalf("%s: %v", spec.name, err)
		}
		expected, err := pgExpectedControlTable(metadata, f.roles.Owner, spec)
		if err != nil {
			t.Fatal(err)
		}
		actual, expected = pgCanonicalMigrationTable(actual), pgCanonicalMigrationTable(expected)
		if !reflect.DeepEqual(actual, expected) {
			got, _ := json.MarshalIndent(actual, "", "  ")
			want, _ := json.MarshalIndent(expected, "", "  ")
			t.Fatalf("%s closed expectation differs from installed catalog\nactual: %s\nexpected: %s", spec.name, got, want)
		}
		if err := pgControlTableCatalog(f.ctx, tx, namespace, f.roles.Owner, f.roles.Worker, spec); err != nil {
			t.Fatalf("%s original server-created probe: %v", spec.name, err)
		}
		if err := pgControlTableCatalogReadOnly(f.ctx, tx, namespace, f.roles.Owner, f.roles.Worker, spec); err != nil {
			t.Fatalf("%s read-only comparison: %v", spec.name, err)
		}
	}
}

// INV-PRIVILEGE: request-style catalog inspection cannot depend on temporary or
// persistent DDL authority, even if the login happens to have SELECT grants.
func TestPgMigrationControlReadOnlyRequiresNoTemporaryPrivilege(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	var database string
	if err := f.installer.QueryRow(f.ctx, "select current_database()").Scan(&database); err != nil {
		t.Fatal(err)
	}
	for _, statement := range []string{
		"revoke temporary on database " + quoteIdentifier(database) + " from public",
		"revoke create on schema public from public",
		"revoke create on schema " + quoteIdentifier(f.namespace) + " from " + quoteIdentifier(f.roles.Worker),
	} {
		if _, err := f.installer.Exec(f.ctx, statement); err != nil {
			t.Fatal(err)
		}
	}
	tx := pgControlExpectedTransaction(t, f, f.worker, true)
	var temporary, namespaceCreate, publicCreate bool
	var before uint32
	if err := tx.QueryRow(f.ctx, `select pg_catalog.has_database_privilege(current_user,current_database(),'TEMP'),
 pg_catalog.has_schema_privilege(current_user,$1,'CREATE'), pg_catalog.has_schema_privilege(current_user,'public','CREATE'),
 pg_catalog.pg_my_temp_schema()`, f.namespace).Scan(&temporary, &namespaceCreate, &publicCreate, &before); err != nil {
		t.Fatal(err)
	}
	if temporary || namespaceCreate || publicCreate || before != 0 {
		t.Fatalf("inspection login still has DDL authority or a temporary schema: %v %v %v %d", temporary, namespaceCreate, publicCreate, before)
	}
	for _, spec := range pgControlExpectedSpecs() {
		if err := pgControlTableCatalogReadOnly(f.ctx, tx, pgControlExpectedNamespace(f, spec), f.roles.Owner, f.roles.Worker, spec); err != nil {
			t.Fatalf("read-only login could not inspect %s: %v", spec.name, err)
		}
	}
	var after uint32
	if err := tx.QueryRow(f.ctx, "select pg_catalog.pg_my_temp_schema()").Scan(&after); err != nil || after != before {
		t.Fatalf("read-only verification created a temporary schema: %d %v", after, err)
	}
	if err := tx.Commit(f.ctx); err != nil {
		t.Fatalf("read-only verification damaged the caller transaction: %v", err)
	}
}

// INV-PRIVILEGE, INV-REGISTRY-SHAPE: closed descriptors refuse behavior-changing
// catalog and ACL mutations instead of accepting a same-named control object.
func TestPgMigrationControlReadOnlyRefusesCatalogMutations(t *testing.T) {
	f := pgNewControlTest(t)
	f.install(t, 1)
	cases := []struct{ name, table, statement string }{
		{"extra column", "tesl_schema_state", "alter table notes_app.tesl_schema_state add column extra text"},
		{"column type", "tesl_schema_state", "alter table notes_app.tesl_schema_state alter column min_version type bigint"},
		{"nullability", "tesl_schema_state", "alter table notes_app.tesl_schema_state alter column min_version drop not null"},
		{"default", "tesl_schema_state", "alter table notes_app.tesl_schema_state alter column compat_floor set default 1"},
		{"extra check", "tesl_schema_state", "alter table notes_app.tesl_schema_state add constraint extra check (min_version >= 0)"},
		{"missing check", "tesl_schema_state", "alter table notes_app.tesl_schema_state drop constraint tesl_schema_state_id_check"},
		{"deferred key", "tesl_schema_state", "alter table notes_app.tesl_schema_state drop constraint tesl_schema_state_pkey; alter table notes_app.tesl_schema_state add primary key (id) deferrable initially deferred"},
		{"extra index", "tesl_schema_state", "create index unexpected_state_idx on notes_app.tesl_schema_state(min_version)"},
		{"row policy", "tesl_schema_state", "alter table notes_app.tesl_schema_state enable row level security"},
		{"owner", "tesl_schema_state", "alter table notes_app.tesl_schema_state owner to " + quoteIdentifier(f.roles.Worker)},
		{"table grant", "tesl_schema_state", "grant update on notes_app.tesl_schema_state to " + quoteIdentifier(f.roles.Worker)},
		{"column grant", "tesl_schema_state", "grant update(min_version) on notes_app.tesl_schema_state to " + quoteIdentifier(f.roles.Worker)},
		{"identity mode", "tesl_fence_namespaces", "alter table public.tesl_fence_namespaces alter column fence_ns set generated by default"},
		{"sequence increment", "tesl_fence_namespaces", "alter sequence public.tesl_fence_namespaces_fence_ns_seq increment by 2"},
		{"sequence start", "tesl_fence_namespaces", "alter sequence public.tesl_fence_namespaces_fence_ns_seq start with 2"},
		{"sequence max", "tesl_fence_namespaces", "alter sequence public.tesl_fence_namespaces_fence_ns_seq maxvalue 2147483646"},
		{"sequence cache", "tesl_fence_namespaces", "alter sequence public.tesl_fence_namespaces_fence_ns_seq cache 2"},
		{"sequence cycle", "tesl_fence_namespaces", "alter sequence public.tesl_fence_namespaces_fence_ns_seq cycle"},
		{"sequence grant", "tesl_fence_namespaces", "grant usage on sequence public.tesl_fence_namespaces_fence_ns_seq to " + quoteIdentifier(f.roles.Worker)},
	}
	for _, scenario := range cases {
		t.Run(scenario.name, func(t *testing.T) {
			tx := pgControlExpectedTransaction(t, f, f.installer, false)
			if _, err := tx.Exec(f.ctx, scenario.statement); err != nil {
				t.Fatal(err)
			}
			for _, spec := range pgControlExpectedSpecs() {
				if spec.name != scenario.table {
					continue
				}
				if err := pgControlTableCatalogReadOnly(f.ctx, tx, pgControlExpectedNamespace(f, spec), f.roles.Owner, f.roles.Worker, spec); err == nil {
					t.Fatal("modified catalog accepted")
				}
			}
			var alive int
			if err := tx.QueryRow(f.ctx, "select 1").Scan(&alive); err != nil || alive != 1 {
				t.Fatalf("catalog refusal aborted caller transaction: %d %v", alive, err)
			}
		})
	}
}

func TestPgMigrationControlReadOnlyRejectsUnknownSpecifications(t *testing.T) {
	for _, spec := range []pgMigrationControlTable{
		{name: "unknown", columns: "id integer"},
		{name: pgMigrationControlTables[0].name, columns: pgMigrationControlTables[0].columns + ", extra text"},
	} {
		if _, err := pgExpectedControlTable(nil, "owner", spec); err == nil || !strings.Contains(err.Error(), "unsupported") {
			t.Fatalf("unknown closed specification was accepted: %v", err)
		}
		if err := pgControlTableCatalogReadOnly(context.Background(), nil, "notes", "owner", "request", spec); err == nil {
			t.Fatal("unknown specification reached the database")
		}
	}
}
