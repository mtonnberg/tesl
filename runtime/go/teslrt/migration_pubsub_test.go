package teslrt

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

func pgBroadcastFixture(t *testing.T, f *pgControlTestFixture) (*Database, *SseChannel) {
	t.Helper()
	var channel *SseChannel
	db := pgRowBaselineFixtureConfigured(t, f, nil, func(db *Database) {
		channel = NewSseChannelOn(db, "Updates")
	})
	t.Cleanup(func() { pubsubRuntimeOf(t, db).Close() })
	return db, channel
}

func TestWorkerBroadcastRuntime(t *testing.T) {
	shrinkPubsubIntervals(t)
	f, request := pgNewWorkerTest(t)
	db, channel := pgBroadcastFixture(t, f)
	if _, err := InstallPgCompiledRowBaseline(f.ctx, f.installer, db, f.roles); err != nil {
		t.Fatal(err)
	}
	if _, err := ExecutePgCompiledRowBaseline(f.ctx, f.worker, db, f.roles); err != nil {
		t.Fatal(err)
	}
	WithDatabase(db, func() {
		defer db.bound().closeRowPool()
		first := channel.register("key")
		defer channel.unregister("key", first)
		otherKey := channel.register("other")
		defer channel.unregister("other", otherKey)
		pid := awaitListener(t, db)
		// Independent process cursor: draining cannot consume another's event.
		secondChannel := NewSseChannel("Updates")
		second := secondChannel.register("key")
		receiver := &pgPubsub{ctx: f.ctx, channels: map[string][]*SseChannel{"Updates": {secondChannel}}}
		if err := receiver.prepareOn(db.bound(), request); err != nil {
			t.Fatal(err)
		}
		func() {
			defer func() {
				if got := recover(); got != "rollback broadcast" {
					t.Fatalf("unexpected transaction failure: %v", got)
				}
			}()
			WithTransaction(func() {
				Publish(channel, "key", "must roll back")
				panic("rollback broadcast")
			})
		}()
		if err := receiver.drainBroadcast(request, db.bound()); err != nil {
			t.Fatal(err)
		}
		expectNoEvent(t, first, 250*time.Millisecond)
		expectNoEvent(t, second, 50*time.Millisecond)
		WithTransaction(func() {
			Publish(channel, "key", "published")
			expectNoEvent(t, first, 50*time.Millisecond)
		})
		if got := expectEvent(t, first, 5*time.Second); got != "published" {
			t.Fatal(got)
		}
		if err := receiver.drainBroadcast(request, db.bound()); err != nil {
			t.Fatal(err)
		}
		if got := expectEvent(t, second, time.Second); got != "published" {
			t.Fatal(got)
		}
		if _, err := f.installer.Exec(f.ctx, "select pg_terminate_backend($1)", pid); err != nil {
			t.Fatal(err)
		}
		Publish(channel, "key", "reconnected")
		if got := expectEvent(t, first, 5*time.Second); got != "reconnected" {
			t.Fatal(got)
		}
		expectNoEvent(t, otherKey, 50*time.Millisecond)
		// Fault-inject old timestamps as Installer; Request cannot shorten retention.
		if _, err := f.installer.Exec(f.ctx, "update "+db.bound().QualifiedTable(pgBroadcastTable)+" set dispatched_at=clock_timestamp()-interval '2 hours'"); err != nil {
			t.Fatal(err)
		}
		if err := receiver.drainBroadcast(request, db.bound()); err != nil {
			t.Fatal(err)
		}
		if err := receiver.pruneBroadcast(request, db.bound()); err != nil {
			t.Fatal(err)
		}
		var remaining int
		if err := request.QueryRow(f.ctx, "select count(*) from "+db.bound().QualifiedTable(pgBroadcastTable)).Scan(&remaining); err != nil || remaining != 0 {
			t.Fatal("retention did not prune delivered rows", remaining, err)
		}
		Publish(channel, "key", "after-prune")
		if got := expectEvent(t, first, 5*time.Second); got != "after-prune" {
			t.Fatal(got)
		}
		fresh := &pgPubsub{ctx: f.ctx}
		if err := fresh.prepareOn(db.bound(), request); err != nil {
			t.Fatal(err)
		}
		if fresh.cursor() != 3 {
			t.Fatal("startup did not capture durable clock", fresh.cursor())
		}
	})
}

func TestWorkerBroadcastConcurrentCommitAndRollback(t *testing.T) {
	f, request := pgNewWorkerTest(t)
	db, _ := pgBroadcastFixture(t, f)
	if _, err := InstallPgCompiledRowBaseline(f.ctx, f.installer, db, f.roles); err != nil {
		t.Fatal(err)
	}
	if _, err := ExecutePgCompiledRowBaseline(f.ctx, f.worker, db, f.roles); err != nil {
		t.Fatal(err)
	}
	other, err := pgx.ConnectConfig(f.ctx, request.Config().Copy())
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close(context.Background())
	connection := &PostgresDB{schema: f.namespace, migration: &pgMigrationAdmission{version: 1}}
	for _, rollback := range []bool{false, true} {
		tx, err := request.Begin(f.ctx)
		if err != nil {
			t.Fatal(err)
		}
		seq, err := pgWriteBroadcast(f.ctx, tx, connection, "Updates", "key", `"first"`)
		if err != nil {
			t.Fatal(err)
		}
		result := make(chan error, 1)
		go func() {
			second, err := other.Begin(f.ctx)
			if err == nil {
				defer second.Rollback(context.Background())
				_, err = pgWriteBroadcast(f.ctx, second, connection, "Updates", "key", `"second"`)
				if err == nil {
					err = second.Commit(f.ctx)
				}
			}
			result <- err
		}()
		select {
		case err := <-result:
			t.Fatalf("second publisher passed uncommitted clock: %v", err)
		case <-time.After(100 * time.Millisecond):
		}
		if rollback {
			err = tx.Rollback(f.ctx)
		} else {
			err = tx.Commit(f.ctx)
		}
		if err != nil {
			t.Fatal(err)
		}
		if err := <-result; err != nil {
			t.Fatal(err)
		}
		var payload string
		if err := request.QueryRow(f.ctx, "select payload::text from "+connection.QualifiedTable(pgBroadcastTable)+" where dispatch_seq=$1", seq).Scan(&payload); err != nil {
			t.Fatal(err)
		}
		want := `"first"`
		if rollback {
			want = `"second"`
		}
		if payload != want {
			t.Fatalf("rollback/commit order: got %s, want %s", payload, want)
		}
	}
}

func TestWorkerBroadcastCatalogAndACL(t *testing.T) {
	for _, drift := range []string{
		"alter table %s add column extra text",
		"alter table %s set unlogged",
		"alter table %s alter column payload drop not null",
		"create index unexpected_sse_index on %s(channel)",
		"grant select on %s to public",
		"grant truncate on %s to %s",
		"grant insert,update,delete on %s to %s",
		"grant select(payload) on %s to %s",
		"grant select on %s to %s with grant option",
	} {
		t.Run(drift, func(t *testing.T) {
			f, _ := pgNewWorkerTest(t)
			db, _ := pgBroadcastFixture(t, f)
			if _, err := InstallPgCompiledRowBaseline(f.ctx, f.installer, db, f.roles); err != nil {
				t.Fatal(err)
			}
			err := pgControlTransaction(f.ctx, f.installer, true, func(tx pgx.Tx) error {
				if _, err := tx.Exec(f.ctx, "set local role "+quoteIdentifier(f.roles.Owner)); err != nil {
					return err
				}
				args := []any{pgx.Identifier{f.namespace, pgBroadcastTable}.Sanitize()}
				if strings.Count(drift, "%s") == 2 {
					args = append(args, quoteIdentifier(f.roles.Request))
				}
				if _, err := tx.Exec(f.ctx, fmt.Sprintf(drift, args...)); err != nil {
					return err
				}
				if _, err := pgVerifyBroadcast(f.ctx, tx, f.namespace, f.roles, true); err == nil {
					t.Fatal("SSE catalog drift accepted")
				}
				return nil
			})
			if err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestWorkerBroadcastProtectedMutationBoundary(t *testing.T) {
	f, request := pgNewWorkerTest(t)
	db, _ := pgBroadcastFixture(t, f)
	if _, err := InstallPgCompiledRowBaseline(f.ctx, f.installer, db, f.roles); err != nil {
		t.Fatal(err)
	}
	if _, err := ExecutePgCompiledRowBaseline(f.ctx, f.worker, db, f.roles); err != nil {
		t.Fatal(err)
	}
	ns := quoteIdentifier(f.namespace) + "."
	for _, sql := range []string{
		"insert into " + ns + pgBroadcastClock + " values('broadcast',0)",
		"update " + ns + pgBroadcastClock + " set value=0",
		"delete from " + ns + pgBroadcastClock,
		"truncate " + ns + pgBroadcastClock,
		"insert into " + ns + pgBroadcastTable + " values(99,'Updates','key','null'::jsonb,clock_timestamp())",
		"update " + ns + pgBroadcastTable + " set dispatch_seq=99",
		"delete from " + ns + pgBroadcastTable,
		"truncate " + ns + pgBroadcastTable,
		"select " + ns + "tesl_row_admit_version(1)",
	} {
		if _, err := request.Exec(f.ctx, sql); err == nil {
			t.Fatal("Request bypassed protected mutation boundary", sql)
		}
	}
	for _, fn := range pgBroadcastFunctions(f.namespace) {
		name := ns + quoteIdentifier(fn.name) + "(" + pgControlArgumentTypes(fn) + ")"
		var allowed bool
		if err := f.worker.QueryRow(f.ctx, "select pg_catalog.has_function_privilege(current_user,$1,'EXECUTE')", name).Scan(&allowed); err != nil || allowed {
			t.Fatal("Worker acquired SSE execution", name, allowed, err)
		}
	}
	publish := "select " + ns + "tesl_sse_publish($1::integer,'Updates','key','\"event\"'::jsonb)"
	prune := "select " + ns + "tesl_sse_prune($1::integer,0::bigint)"
	for _, sql := range []string{publish, prune} {
		if _, err := f.worker.Exec(f.ctx, sql, 1); err == nil {
			t.Fatal("Worker executed SSE mutation", sql)
		}
		for _, version := range []int{0, 2} {
			if _, err := request.Exec(f.ctx, sql, version); err == nil {
				t.Fatal("direct routine bypassed version admission", version, sql)
			}
		}
		tx, err := request.BeginTx(f.ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := tx.Exec(f.ctx, sql, 1); err == nil {
			t.Fatal("direct routine admitted stale-snapshot isolation", sql)
		}
		_ = tx.Rollback(f.ctx)
	}
	var fence int
	if err := request.QueryRow(f.ctx, "select fence_ns from "+ns+"tesl_schema_meta where id=1").Scan(&fence); err != nil {
		t.Fatal(err)
	}
	for _, sql := range []string{publish, prune} {
		tx, err := request.Begin(f.ctx)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := tx.Exec(f.ctx, sql, 1); err != nil {
			t.Fatal("valid protected operation failed", err)
		}
		for _, key := range []int{-fence, fence} {
			var acquired bool
			if err := f.installer.QueryRow(f.ctx, "select pg_catalog.pg_try_advisory_xact_lock($1::integer,1)", key).Scan(&acquired); err != nil || acquired {
				t.Fatal("direct routine omitted transaction fence", key, acquired, err)
			}
		}
		if err := tx.Commit(f.ctx); err != nil {
			t.Fatal(err)
		}
	}
	var rows int
	if err := request.QueryRow(f.ctx, "select count(*) from "+ns+pgBroadcastTable).Scan(&rows); err != nil || rows != 1 {
		t.Fatal("prune removed an unexpired event", rows, err)
	}
	if _, err := f.installer.Exec(f.ctx, "update "+ns+"tesl_schema_state set min_version=2,compat_floor=2"); err != nil {
		t.Fatal(err)
	}
	for _, sql := range []string{publish, prune} {
		if _, err := request.Exec(f.ctx, sql, 1); err == nil {
			t.Fatal("direct routine admitted retired release", sql)
		}
	}
}

func TestWorkerBroadcastFunctionCatalog(t *testing.T) {
	for _, change := range []string{"body", "search-path", "invoker", "owner", "public", "worker", "grant-option", "overload"} {
		t.Run(change, func(t *testing.T) {
			f, _ := pgNewWorkerTest(t)
			db, _ := pgBroadcastFixture(t, f)
			if _, err := InstallPgCompiledRowBaseline(f.ctx, f.installer, db, f.roles); err != nil {
				t.Fatal(err)
			}
			fn := pgBroadcastFunctions(f.namespace)[0]
			target := pgx.Identifier{f.namespace, fn.name}.Sanitize() + "(" + pgControlArgumentTypes(fn) + ")"
			var sql string
			switch change {
			case "body":
				fn.body = "begin return 0; end"
				sql = strings.Replace(pgControlFunctionSQL(f.namespace, f.roles.Owner, fn), "create function", "create or replace function", 1)
			case "search-path":
				sql = "alter function " + target + " set search_path=public"
			case "invoker":
				sql = "alter function " + target + " security invoker"
			case "owner":
				sql = "alter function " + target + " owner to " + quoteIdentifier(f.roles.Worker)
			case "public":
				sql = "grant execute on function " + target + " to public"
			case "worker":
				sql = "grant execute on function " + target + " to " + quoteIdentifier(f.roles.Worker)
			case "grant-option":
				sql = "grant execute on function " + target + " to " + quoteIdentifier(f.roles.Request) + " with grant option"
			case "overload":
				sql = "create function " + pgx.Identifier{f.namespace, fn.name}.Sanitize() + "() returns integer language sql as 'select 0'"
			}
			if err := pgControlTransaction(f.ctx, f.installer, true, func(tx pgx.Tx) error {
				if _, err := tx.Exec(f.ctx, sql); err != nil {
					return err
				}
				if _, err := pgVerifyBroadcast(f.ctx, tx, f.namespace, f.roles, true); err == nil {
					t.Fatal("altered SSE routine accepted", change)
				}
				return nil
			}); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestWorkerBroadcastClockCorruptionRefused(t *testing.T) {
	for _, corruption := range []string{"missing", "behind"} {
		t.Run(corruption, func(t *testing.T) {
			f, request := pgNewWorkerTest(t)
			db, _ := pgBroadcastFixture(t, f)
			if _, err := InstallPgCompiledRowBaseline(f.ctx, f.installer, db, f.roles); err != nil {
				t.Fatal(err)
			}
			if _, err := ExecutePgCompiledRowBaseline(f.ctx, f.worker, db, f.roles); err != nil {
				t.Fatal(err)
			}
			connection := &PostgresDB{schema: f.namespace, migration: &pgMigrationAdmission{version: 1}}
			if _, err := pgWriteBroadcast(f.ctx, request, connection, "Updates", "key", `"committed"`); err != nil {
				t.Fatal(err)
			}
			clock := connection.QualifiedTable(pgBroadcastClock)
			for _, sql := range []string{"insert into " + clock + " values('other',0)", "update " + clock + " set value=-1"} {
				if _, err := f.installer.Exec(f.ctx, sql); err == nil {
					t.Fatal("invalid singleton shape accepted", sql)
				}
			}
			sql := "update " + clock + " set value=0"
			if corruption == "missing" {
				sql = "delete from " + clock
			}
			if _, err := f.installer.Exec(f.ctx, sql); err != nil {
				t.Fatal(err)
			}
			if _, err := pgReadBroadcastClock(f.ctx, request, connection); err == nil {
				t.Fatal("reader accepted corrupt clock")
			}
			if _, err := pgWriteBroadcast(f.ctx, request, connection, "Updates", "key", `"bad"`); err == nil {
				t.Fatal("publisher repaired or ignored corrupt clock")
			}
			if _, err := request.Exec(f.ctx, "select "+connection.QualifiedTable("tesl_sse_prune")+"(1,1::bigint)"); err == nil {
				t.Fatal("pruner ignored corrupt clock")
			}
			if _, err := InstallPgCompiledRowBaseline(f.ctx, f.installer, db, f.roles); err == nil {
				t.Fatal("Installer accepted or reset corrupt clock")
			}
		})
	}
}

func TestWorkerBroadcastInstallerExtension(t *testing.T) {
	f, request := pgNewWorkerTest(t)
	db, _ := pgBroadcastFixture(t, f)
	if _, err := InstallPgCompiledRowBaseline(f.ctx, f.installer, db, f.roles); err != nil {
		t.Fatal(err)
	}
	qualified := pgx.Identifier{f.namespace, pgBroadcastTable}.Sanitize()
	clock := pgx.Identifier{f.namespace, pgBroadcastClock}.Sanitize()
	if err := pgControlTransaction(f.ctx, f.installer, true, func(tx pgx.Tx) error {
		for _, fn := range pgBroadcastFunctions(f.namespace) {
			if _, err := tx.Exec(f.ctx, "drop function "+pgx.Identifier{f.namespace, fn.name}.Sanitize()+"("+pgControlArgumentTypes(fn)+")"); err != nil {
				return err
			}
		}
		if _, err := tx.Exec(f.ctx, "set local role "+quoteIdentifier(f.roles.Owner)+"; drop table "+qualified+","+clock); err != nil {
			return err
		}
		return tx.Commit(f.ctx)
	}); err != nil {
		t.Fatal(err)
	}
	tx, err := request.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pgVerifyBroadcast(f.ctx, tx, f.namespace, f.roles, true); err == nil {
		t.Fatal("request accepted missing broadcast storage")
	}
	_ = tx.Rollback(f.ctx)
	if _, err := request.Exec(f.ctx, "create table "+qualified+"(dispatch_seq bigint)"); err == nil {
		t.Fatal("request created broadcast storage")
	}
	for range 2 {
		if _, err := InstallPgCompiledRowBaseline(f.ctx, f.installer, db, f.roles); err != nil {
			t.Fatal("Installer failed to add/verify extension", err)
		}
	}
}
