package teslrt

import (
	"reflect"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

// Exercise the public Installer once with all three declarations, on fresh and
// pre-extension catalogs. Retry must preserve application and facility rows.
func TestWorkerCombinedFacilitiesInstaller(t *testing.T) {
	for _, origin := range []string{"fresh", "existing", "existing-email"} {
		t.Run(origin, func(t *testing.T) {
			f, request := pgNewWorkerTest(t)
			var cache *Cache[string]
			var outbox *Outbox
			var channel *SseChannel
			db := pgRowBaselineFixtureConfigured(t, f, nil, func(db *Database) {
				cache = NewCacheOnArtifact(db, "Combined.Results", 0, func(v string) any { return v }, DecodeStringValue, strings.Repeat("c", 64))
				outbox = NewOutboxOn(db, SmtpSettings{})
				channel = NewSseChannelOn(db, "Combined.Updates")
			})
			t.Cleanup(func() { pubsubRuntimeOf(t, db).Close() })
			b, err := pgCompiledRowBaseline(db)
			if err != nil {
				t.Fatal(err)
			}
			install := func() PgMigrationControlState {
				t.Helper()
				state, err := InstallPgCompiledRowBaseline(f.ctx, f.installer, db, f.roles)
				if err != nil {
					t.Fatal("combined Installer", err)
				}
				return state
			}
			work := func() {
				t.Helper()
				if _, err := ExecutePgCompiledRowBaseline(f.ctx, f.worker, db, f.roles); err != nil {
					t.Fatal("combined Worker", err)
				}
			}
			ns := quoteIdentifier(f.namespace) + "."
			if origin != "fresh" {
				install()
				work()
				if _, err := request.Exec(f.ctx, "insert into "+ns+"notes(id,title) values(1,'existing application row')"); err != nil {
					t.Fatal(err)
				}
				if origin == "existing-email" {
					if _, err := request.Exec(f.ctx, "select "+ns+"tesl_email_enqueue(1,'existing@example.test','keep','text','old body','')"); err != nil {
						t.Fatal(err)
					}
				}
				// Model a catalog installed by a pre-extension binary without
				// reopening the compiler's sealed App registration or changing ABI.
				if err := pgControlTransaction(f.ctx, f.installer, true, func(tx pgx.Tx) error {
					functions := pgBroadcastFunctions(f.namespace)
					tables := []string{pgArtifactCacheTable, pgBroadcastTable, pgBroadcastClock}
					if origin == "existing" {
						functions = append(functions, pgEmailFunctions(f.namespace)...)
						tables = append(tables, pgEmailTable, pgEmailState)
					}
					for _, fn := range functions {
						if _, err := tx.Exec(f.ctx, "drop function "+ns+quoteIdentifier(fn.name)+"("+pgControlArgumentTypes(fn)+")"); err != nil {
							return err
						}
					}
					for _, table := range tables {
						if _, err := tx.Exec(f.ctx, "drop table "+ns+quoteIdentifier(table)); err != nil {
							return err
						}
					}
					return tx.Commit(f.ctx)
				}); err != nil {
					t.Fatal(err)
				}
				if _, err := pgWaitForRowBaseline(f.ctx, request, b, f.roles); err == nil {
					t.Fatal("ready despite missing declared extensions")
				}
			}
			installed := install() // exactly one invocation must install ALL missing extensions
			wantCurrent := 1
			if origin == "fresh" {
				wantCurrent = 0
			}
			if installed.Format != pgRowControlFormat || installed.Current != wantCurrent {
				t.Fatal("Installer changed row readiness", installed)
			}
			if origin != "fresh" {
				var title string
				if err := request.QueryRow(f.ctx, "select title from "+ns+"notes where id=1").Scan(&title); err != nil || title != "existing application row" {
					t.Fatal("extension install changed existing application row", title, err)
				}
			}
			if origin == "existing-email" {
				var body string
				if err := f.installer.QueryRow(f.ctx, "select body_text from "+ns+pgEmailTable+" where recipient='existing@example.test'").Scan(&body); err != nil || body != "old body" {
					t.Fatal("extension install changed existing email", body, err)
				}
			}
			// Each verifier must work with Worker credentials, without data grants.
			if err := pgControlSnapshotMode(f.ctx, f.worker, pgx.ReadOnly, func(tx pgx.Tx) error {
				if _, err := pgInspectRowControl(f.ctx, tx, f.namespace, f.roles); err != nil {
					return err
				}
				names, functions, err := pgRowFacilityCatalog(f.ctx, tx, f.namespace, f.roles)
				if err == nil && (len(names) != 5 || len(functions) != 7) {
					t.Fatal("Installer skipped an extension", names, functions)
				}
				return err
			}); err != nil {
				t.Fatal(err)
			}
			work()
			if _, err := pgWaitForRowBaseline(f.ctx, request, b, f.roles); err != nil {
				t.Fatal("combined Request readiness", err)
			}
			if origin == "fresh" {
				if _, err := request.Exec(f.ctx, "insert into "+ns+"notes(id,title) values(1,'existing application row')"); err != nil {
					t.Fatal(err)
				}
			}
			WithDatabase(db, func() {
				defer db.bound().closeRowPool()
				CacheSet(cache, "key", "keep cache")
				outbox.backend.(*pgOutboxBackend).send(EmailMessage{To: "new@example.test", Subject: "keep", Body: TextBody("new body")})
				Publish(channel, "key", "keep event")
				if got := CacheGet(cache, "key"); !got.IsSomething() || got.SomethingValue != "keep cache" {
					t.Fatal("combined cache runtime", got)
				}
			})
			// Compare complete stored rows (including clocks, tokens and timestamps),
			// not just counts, across Installer and Worker retries.
			snapshot := func() []string {
				t.Helper()
				var values []string
				for _, table := range []string{"notes", pgArtifactCacheTable, pgEmailState, pgEmailTable, pgBroadcastClock, pgBroadcastTable, "tesl_row_baseline", "tesl_row_versions"} {
					var value string
					if err := f.installer.QueryRow(f.ctx, "select coalesce(jsonb_agg(to_jsonb(t) order by to_jsonb(t)::text),'[]'::jsonb)::text from "+ns+quoteIdentifier(table)+" t").Scan(&value); err != nil {
						t.Fatal(err)
					}
					values = append(values, value)
				}
				return values
			}
			before := snapshot()
			for range 2 {
				repeated := install()
				if repeated.DatabaseUUID != installed.DatabaseUUID {
					t.Fatal("Installer replaced installation identity")
				}
				work()
				if after := snapshot(); !reflect.DeepEqual(before, after) {
					t.Fatal("retry changed retained rows", before, after)
				}
			}
			// Role changes made by extension installation must not escape commit.
			var user, session string
			if err := f.installer.QueryRow(f.ctx, "select current_user,session_user").Scan(&user, &session); err != nil || user != session {
				t.Fatal("Installer role leaked", user, session, err)
			}
			for _, table := range []string{pgArtifactCacheTable, pgEmailState, pgEmailTable, pgBroadcastClock, pgBroadcastTable} {
				for _, privilege := range []string{"SELECT", "INSERT", "UPDATE", "DELETE", "TRUNCATE", "REFERENCES", "TRIGGER"} {
					want := table == pgArtifactCacheTable && (privilege == "SELECT" || privilege == "INSERT" || privilege == "UPDATE" || privilege == "DELETE") || table != pgEmailTable && table != pgArtifactCacheTable && privilege == "SELECT"
					var allowed bool
					if err := request.QueryRow(f.ctx, "select has_table_privilege(current_user,$1,$2)", ns+table, privilege).Scan(&allowed); err != nil || allowed != want {
						t.Fatal("Request privilege", table, privilege, allowed, want, err)
					}
					want = table == pgEmailState && privilege == "SELECT"
					if err := f.worker.QueryRow(f.ctx, "select has_table_privilege(current_user,$1,$2)", ns+table, privilege).Scan(&allowed); err != nil || allowed != want {
						t.Fatal("Worker privilege", table, privilege, allowed, want, err)
					}
				}
			}
			for _, fn := range append(pgEmailFunctions(f.namespace), pgBroadcastFunctions(f.namespace)...) {
				var owner, worker, req bool
				target := ns + fn.name + "(" + pgControlArgumentTypes(fn) + ")"
				if err := f.installer.QueryRow(f.ctx, "select has_function_privilege($1,$4,'EXECUTE'),has_function_privilege($2,$4,'EXECUTE'),has_function_privilege($3,$4,'EXECUTE')", f.roles.Owner, f.roles.Worker, f.roles.Request, target).Scan(&owner, &worker, &req); err != nil || !owner || worker || !req {
					t.Fatal("facility function permissions", target, owner, worker, req, err)
				}
			}
			// Catalogs remain recognized when a later binary has no declarations.
			// Use the read-only catalog API, without mutating sealed registration.
			if err := pgControlSnapshotMode(f.ctx, request, pgx.ReadOnly, func(tx pgx.Tx) error {
				_, err := pgInspectRowControl(f.ctx, tx, f.namespace, f.roles)
				return err
			}); err != nil {
				t.Fatal("retained optional storage", err)
			}
		})
	}
}
