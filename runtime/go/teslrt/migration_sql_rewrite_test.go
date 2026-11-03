package teslrt

import (
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

func TestRowBaselineSQLRewriteKeepsNamespaceData(t *testing.T) {
	for _, namespace := range []string{"mail", "ep is distinct from true", "begin\n", "tenant if kind is null", `quote" tesl_queue_conversion_begin`} {
		t.Run(namespace, func(t *testing.T) {
			ns := quoteIdentifier(namespace) + "."
			body := "declare r " + ns + "tesl_schema_state%rowtype;\nbegin\n if ep is distinct from true then return; end if;\nend"
			want := "declare r " + ns + "tesl_schema_state%rowtype;\nbegin\n if (v=1 and ep is distinct from true) then return; end if;\nend"
			if got := pgRewriteMigrationSQL(body, namespace, "ep is distinct from true", "(v=1 and ep is distinct from true)", 1); got != want {
				t.Fatalf("predicate rewrite changed namespace data:\n%s", got)
			}
			qualified := "select * from " + ns + "old_table; select * from " + ns + "old_table"
			for _, count := range []int{0, 1, -1} {
				want := strings.Replace(qualified, ns+"old_table", ns+"new_table", count)
				got := pgRewriteMigrationSQL(qualified, namespace, ns+"old_table", ns+"new_table", count)
				if got != want || strings.IndexByte(got, 0) >= 0 {
					t.Fatalf("qualified rewrite lost replacement count or namespace: %q", got)
				}
			}
			prefix := "declare r " + ns + "tesl_jobs%rowtype;\nbegin\n"
			before, after, found := pgCutMigrationSQL(prefix+" if kind is null then return; end if;\nend", namespace, " if kind is null")
			if !found || before != prefix || after != " then return; end if;\nend" {
				t.Fatalf("SQL cut treated namespace as a fragment: %q %q %v", before, after, found)
			}
		})
	}
}

func TestRowBaselineSQLRewriteRejectsInternalToken(t *testing.T) {
	if pgMigrationIdentifier("namespace\x00") {
		t.Fatal("namespace validation admitted the internal token")
	}
	for i := range 4 {
		t.Run(string(rune('a'+i)), func(t *testing.T) {
			inputs := []string{"select old", "mail", "old", "new"}
			inputs[i] += "\x00"
			defer func() {
				if recover() == nil {
					t.Fatal("SQL rewrite admitted its internal token")
				}
			}()
			pgRewriteMigrationSQL(inputs[0], inputs[1], inputs[2], inputs[3], -1)
		})
	}
	for i := range 3 {
		t.Run("cut-"+string(rune('a'+i)), func(t *testing.T) {
			inputs := []string{"select old", "mail", "old"}
			inputs[i] += "\x00"
			defer func() {
				if recover() == nil {
					t.Fatal("SQL cut admitted its internal token")
				}
			}()
			pgCutMigrationSQL(inputs[0], inputs[1], inputs[2])
		})
	}
}

// Valid PostgreSQL identifiers are data, even when they contain SQL fragments.
// Cover installation, execution and the actual Request catalog verification.
func TestPgRowBaselineNamespaceSQLTokensAreData(t *testing.T) {
	for _, namespace := range []string{
		"tenant_tesl_queue_conversion_begin",
		"tenant_tesl_queue_conversion_finish",
		"tenant_tesl_queue_conversion_next",
		"tenant_tesl_queue_conversion_receipts",
		"tenant_tesl_queue_conversion_attempts",
		"tenant_tesl_row_queue_conversion_failures",
		"tenant_tesl_row_queue_discards",
		"ep is distinct from true",
		"begin\n",
		"tenant if kind is null",
		`quote" tesl_queue_conversion_begin`,
	} {
		t.Run(namespace, func(t *testing.T) {
			f, request := pgNewWorkerTest(t)
			f.namespace = namespace
			database := pgRowBaselineFixture(t, f)
			if _, err := InstallPgCompiledRowBaseline(f.ctx, f.installer, database, f.roles); err != nil {
				t.Fatal(err)
			}
			if _, err := ExecutePgCompiledRowBaseline(f.ctx, f.worker, database, f.roles); err != nil {
				t.Fatal(err)
			}
			baseline, err := pgCompiledRowBaseline(database)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := pgWaitForRowBaseline(f.ctx, request, baseline, f.roles); err != nil {
				t.Fatal(err)
			}
			for _, fn := range pgRowQueueConversionFunctions(namespace) {
				target := pgx.Identifier{namespace, fn.name}.Sanitize() + "(" + pgControlArgumentTypes(fn) + ")"
				var allowed bool
				if err := request.QueryRow(f.ctx, "select pg_catalog.has_function_privilege(current_user,$1,'EXECUTE')", target).Scan(&allowed); err != nil || allowed {
					t.Fatalf("namespace changed Request conversion permissions: %s %v %v", fn.name, allowed, err)
				}
				if strings.IndexByte(fn.body, 0) >= 0 {
					t.Fatal("SQL definition retained an internal namespace token")
				}
			}
		})
	}
}
