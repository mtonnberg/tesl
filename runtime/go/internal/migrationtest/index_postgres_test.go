package migrationtest

import (
	"context"
	"errors"
	"fmt"
	"runtime"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

func indexCatalog(t *testing.T, f *databaseFixture) (catalog, observed string, active bool) {
	t.Helper()
	var present, valid, expected bool
	err := f.conn.QueryRow(f.ctx, `select
  exists (select 1 from pg_class where oid=to_regclass($1)),
  coalesce((select indisvalid from pg_index where indexrelid=to_regclass($1)),false),
  coalesce((select not indisunique and indnkeyatts=1 and indnatts=1
             and pg_get_indexdef(indexrelid,1,true)='title' from pg_index where indexrelid=to_regclass($1)),false),
  exists (select 1 from pg_stat_progress_create_index where index_relid=to_regclass($1))`, f.schema+".notes_title_v8").Scan(&present, &valid, &expected, &active)
	if err != nil {
		t.Fatalf("index catalog: %v\n%s", err, f.dump())
	}
	if !present {
		return "absent", "", active
	}
	catalog, observed = "invalid", "different-key"
	if valid {
		catalog = "valid"
	}
	if expected {
		observed = "typed-title-key"
	}
	return
}

func assertIndexCatalog(t *testing.T, f *databaseFixture, m *Model) {
	t.Helper()
	catalog, observed, active := indexCatalog(t, f)
	job := m.Indexes["notes_title_v8"]
	if catalog != job.Catalog || observed != job.Observed || active != (job.Active != "") {
		t.Fatalf("PostgreSQL catalog=(%s,%s,active=%t), model=%+v\n%s", catalog, observed, active, job, f.dump())
	}
}

func awaitIndexStatement(t *testing.T, f *databaseFixture, done <-chan error, wantError bool) {
	t.Helper()
	select {
	case err := <-done:
		if (err != nil) != wantError {
			t.Fatalf("index statement error=%v, want error=%t\n%s", err, wantError, f.dump())
		}
	case <-f.ctx.Done():
		t.Fatalf("index statement: %v\n%s", f.ctx.Err(), f.dump())
	}
}

// Contract fixture hook. Its caller retains the exclusive DDL-job lock across
// this metadata check and the autocommit DROP; the model is a separate oracle.
func dropFixtureIndex(f *databaseFixture, conn *pgx.Conn, name string, target int) error {
	var allowed bool
	err := conn.QueryRow(f.ctx, `select i.state='terminal' and i.terminal_version=$2 and s.compat_floor>=i.terminal_version
		from `+f.schema+`.tesl_schema_index i cross join `+f.schema+`.tesl_schema_state s where i.name=$1 and s.id=1`, name, target).Scan(&allowed)
	if err != nil {
		return err
	}
	if !allowed {
		return fmt.Errorf("index removal identity or plan switch is not ready for V%d", target)
	}
	_, err = conn.Exec(f.ctx, "drop index concurrently if exists "+pgx.Identifier{f.schema, name}.Sanitize())
	return err
}

// INV-INDEX-RECOVERY, INV-INDEX-READY, INV-DDL-JOB, INV-LEASE; TR-INDEX-START, TR-INDEX-SUCCESS, TR-INDEX-BACKEND-DEATH, TR-INDEX-CLEANUP.
func TestPostgresActiveIndexBuildSurvivesLeaseTakeover(t *testing.T) {
	for _, outcome := range []string{"finishes", "backend-dies"} {
		t.Run(outcome, func(t *testing.T) {
			f := newDatabaseFixture(t)
			f.expanded(t, 8)
			m := plannedIndex(t)
			f.exec(t, "create table "+f.schema+".index_notes(id int primary key,title text)")
			f.exec(t, "insert into "+f.schema+".tesl_schema_leases(name,holder,token,expires_at) values ('index:notes_title_v8','first',1,clock_timestamp()+interval '1 hour')")
			writer, first, second := f.other(t), f.other(t), f.other(t)
			jobKey := int64(f.fence)
			for _, conn := range []*pgx.Conn{first, second} {
				f.execOn(t, conn, "select pg_advisory_lock_shared($1,8)", f.fence)
			}
			f.execOn(t, first, "select pg_advisory_lock_shared($1::bigint)", jobKey)
			f.execOn(t, writer, "begin; insert into "+f.schema+".index_notes values (1,'existing writer')")
			done := make(chan error, 1)
			go func() {
				_, err := first.Exec(f.ctx, "create index concurrently notes_title_v8 on "+f.schema+".index_notes(title)")
				done <- err
			}()
			// The open writer makes the build stop at a real PostgreSQL phase.
			// No timing assumption or production lease timeout establishes it.
			for {
				var blocked bool
				if err := f.conn.QueryRow(f.ctx, "select exists(select 1 from pg_stat_progress_create_index where pid=$1 and phase='waiting for writers before build')", first.PgConn().PID()).Scan(&blocked); err != nil {
					t.Fatalf("observe build: %v\n%s", err, f.dump())
				}
				if blocked {
					break
				}
				select {
				case err := <-done:
					t.Fatalf("index did not wait for the existing writer: %v\n%s", err, f.dump())
				default:
				}
				runtime.Gosched()
			}
			apply(t, m, indexOp("index-start", "first", 1))
			assertIndexCatalog(t, f, m)
			f.exec(t, "update "+f.schema+".tesl_schema_leases set expires_at='epoch' where name='index:notes_title_v8'")
			var token uint64
			if err := second.QueryRow(f.ctx, "update "+f.schema+".tesl_schema_leases set token=token+1,holder='second',expires_at=clock_timestamp()+interval '1 hour' where name='index:notes_title_v8' and expires_at<=clock_timestamp() returning token").Scan(&token); err != nil || token != 2 {
				t.Fatalf("lease takeover token=%d: %v", token, err)
			}
			apply(t, m, Op{Kind: "tick", Ticks: 10}, Op{Kind: "lease-acquire", ID: "index:notes_title_v8", Hash: "second", Ticks: 10})
			f.execOn(t, second, "select pg_advisory_lock_shared($1::bigint)", jobKey)
			apply(t, m, indexOp("index-enter", "second", token))
			denied(t, m, indexOp("index-cleanup", "second", token))
			assertIndexCatalog(t, f, m)
			if outcome == "backend-dies" {
				var signalled bool
				if err := f.conn.QueryRow(f.ctx, "select pg_terminate_backend($1)", first.PgConn().PID()).Scan(&signalled); err != nil || !signalled {
					t.Fatalf("terminate owned index backend: %t %v", signalled, err)
				}
				awaitIndexStatement(t, f, done, true)
				// A successful signal is not proof of death. Observe that all
				// locks and server-side work disappeared before taking action.
				waitIndexBackendGone(t, f, first.PgConn().PID())
				apply(t, m, indexOp("index-backend-death", "first", 1))
				assertIndexCatalog(t, f, m)
				f.execOn(t, writer, "commit")
				f.execOn(t, second, "drop index concurrently "+f.schema+".notes_title_v8")
				apply(t, m, indexOp("index-cleanup", "second", token))
				assertIndexCatalog(t, f, m)
				f.execOn(t, second, "create index concurrently notes_title_v8 on "+f.schema+".index_notes(title)")
				apply(t, m, indexOp("index-start", "second", token), indexOp("index-success", "second", token))
			} else {
				f.execOn(t, writer, "commit")
				awaitIndexStatement(t, f, done, false)
				apply(t, m, indexOp("index-success", "first", 1))
				denied(t, m, indexOp("index-verify", "first", 1))
				denied(t, m, indexOp("index-cleanup", "second", token))
				f.execOn(t, first, "select pg_advisory_unlock_shared($1::bigint)", jobKey)
				apply(t, m, indexOp("index-exit", "first", 1))
			}
			assertIndexCatalog(t, f, m)
			apply(t, m, indexOp("index-verify", "second", token))
			f.execOn(t, second, "select pg_advisory_unlock_shared($1::bigint)", jobKey)
			apply(t, m, indexOp("index-exit", "second", token))
		})
	}
}

func waitIndexBackendGone(t *testing.T, f *databaseFixture, pid uint32) {
	t.Helper()
	for {
		var present bool
		if err := f.conn.QueryRow(f.ctx, "select exists(select 1 from pg_stat_activity where pid=$1) or exists(select 1 from pg_locks where pid=$1)", pid).Scan(&present); err != nil {
			t.Fatalf("wait for backend exit: %v\n%s", err, f.dump())
		}
		if !present {
			return
		}
		runtime.Gosched()
	}
}

// INV-DDL-TERMINAL, INV-DDL-JOB; TR-INDEX-TERMINAL, TR-INDEX-DROP, TR-CONTRACT, TR-CRASH.
func TestPostgresContractWaitsForIndexVerificationAndPersistsTerminal(t *testing.T) {
	f := newDatabaseFixture(t)
	f.expanded(t, 8)
	m := plannedIndex(t)
	f.exec(t, "create table "+f.schema+".index_notes(id int primary key,title text)")
	f.exec(t, "insert into "+f.schema+".tesl_schema_index(name,state) values ('notes_title_v8','pending')")
	worker, contract := f.other(t), f.other(t)
	jobKey := int64(f.fence)
	f.execOn(t, worker, "select pg_advisory_lock_shared($1::bigint)", jobKey)
	f.execOn(t, worker, "create index concurrently notes_title_v8 on "+f.schema+".index_notes(title)")
	apply(t, m, indexOp("index-start", "first", 1), indexOp("index-success", "first", 1))
	assertIndexCatalog(t, f, m)
	f.exec(t, "begin")
	f.exec(t, "select pg_advisory_xact_lock($1,7)", f.fence)
	f.exec(t, "select "+f.schema+".tesl_advance_floor(7,8,'retirement',1,'tesl-1','fixture')")
	f.exec(t, "select "+f.schema+".tesl_begin_contract(8,'contract',1,'tesl-1','fixture')")
	f.exec(t, "commit")
	apply(t, m, Op{Kind: "retire-begin", Version: 8}, Op{Kind: "retire-commit", Version: 8}, Op{Kind: "contract-begin", Version: 8})
	done := make(chan error, 1)
	go func() {
		_, err := contract.Exec(f.ctx, "select pg_advisory_lock($1::bigint)", jobKey)
		done <- err
	}()
	for {
		var blocked bool
		if err := f.conn.QueryRow(f.ctx, "select exists(select 1 from pg_locks where pid=$1 and locktype='advisory' and not granted)", contract.PgConn().PID()).Scan(&blocked); err != nil {
			t.Fatalf("observe contract lock: %v\n%s", err, f.dump())
		}
		if blocked {
			break
		}
		select {
		case err := <-done:
			t.Fatalf("contract did not wait for worker catalog verification: %v", err)
		default:
		}
		runtime.Gosched()
	}
	denied(t, m, Op{Kind: "index-terminal", ID: "notes_title_v8", Version: 8})
	apply(t, m, indexOp("index-verify", "first", 1))
	f.execOn(t, worker, "select pg_advisory_unlock_shared($1::bigint)", jobKey)
	apply(t, m, indexOp("index-exit", "first", 1))
	awaitIndexStatement(t, f, done, false)
	f.execOn(t, contract, "update "+f.schema+".tesl_schema_index set state='terminal',terminal_version=8 where name='notes_title_v8'")
	apply(t, m, Op{Kind: "index-terminal", ID: "notes_title_v8", Version: 8})
	// Lose the coordinator after durable terminal, before autocommit DROP.
	if err := contract.Close(f.ctx); err != nil {
		t.Fatal(err)
	}
	apply(t, m, Op{Kind: "crash"})
	recovery := f.other(t)
	f.execOn(t, recovery, "select pg_advisory_lock($1::bigint)", jobKey)
	var terminal bool
	if err := recovery.QueryRow(f.ctx, "select state='terminal' and terminal_version=8 from "+f.schema+".tesl_schema_index where name='notes_title_v8'").Scan(&terminal); err != nil || !terminal {
		t.Fatalf("terminal lost after coordinator exit: %t %v", terminal, err)
	}
	if err := dropFixtureIndex(f, recovery, "notes_title_v8", 8); err != nil {
		t.Fatal(err)
	}
	apply(t, m, indexOp("index-drop", "", 0))
	assertIndexCatalog(t, f, m)
	f.execOn(t, recovery, "select pg_advisory_unlock($1::bigint)", jobKey)
	// A surviving same-version worker can acquire its shared lock after the
	// contract, so it must re-read terminal before considering any CREATE.
	f.execOn(t, worker, "select pg_advisory_lock_shared($1::bigint)", jobKey)
	if err := worker.QueryRow(f.ctx, "select state='terminal' from "+f.schema+".tesl_schema_index where name='notes_title_v8'").Scan(&terminal); err != nil || !terminal {
		t.Fatalf("stale worker lost terminal guard: %t %v", terminal, err)
	}
	denied(t, m, indexOp("index-enter", "first", 1))
	assertIndexCatalog(t, f, m)
}

// INV-DDL-JOB, INV-FENCE, INV-DDL-TERMINAL, INV-CONTRACT;
// TR-INDEX-ENTER, TR-INDEX-START, TR-INDEX-SUCCESS, TR-INDEX-VERIFY, TR-RETIRE, TR-INDEX-TERMINAL, TR-INDEX-DROP, TR-CRASH, TR-CONTRACT.
func TestPostgresSuccessorIndexWorkerSurvivesCreatingVersionRetirement(t *testing.T) {
	f := newDatabaseFixture(t)
	f.expanded(t, 8)
	f.expanded(t, 9)
	m := plannedIndex(t)
	apply(t, m, indexOp("index-exit", "first", 1), Op{Kind: "expand", Version: 9, Hash: "nine", Additive: true},
		Op{Kind: "tick", Ticks: 10}, Op{Kind: "lease-acquire", ID: "index:notes_title_v8", Hash: "successor", Ticks: 10})
	successor := func(kind string) Op {
		return Op{Kind: kind, ID: "notes_title_v8", Holder: "successor", Attempt: 2, Version: 9}
	}
	f.exec(t, "create table "+f.schema+".index_notes(id int primary key,title text)")
	f.exec(t, "insert into "+f.schema+".tesl_schema_index(name,state) values ('notes_title_v8','pending')")
	worker, writer, contract := f.other(t), f.other(t), f.other(t)
	jobKey := int64(f.fence)
	f.execOn(t, worker, "select pg_advisory_lock_shared($1,9)", f.fence)
	f.execOn(t, worker, "select "+f.schema+".tesl_admit(9)")
	f.execOn(t, worker, "select pg_advisory_lock_shared($1::bigint)", jobKey)
	apply(t, m, successor("index-enter"))
	f.execOn(t, writer, "begin; insert into "+f.schema+".index_notes values (1,'old row')")
	built := make(chan error, 1)
	go func() {
		_, err := worker.Exec(f.ctx, "create index concurrently notes_title_v8 on "+f.schema+".index_notes(title)")
		built <- err
	}()
	for {
		var waiting bool
		if err := f.conn.QueryRow(f.ctx, "select exists(select 1 from pg_stat_progress_create_index where pid=$1 and phase='waiting for writers before build')", worker.PgConn().PID()).Scan(&waiting); err != nil {
			t.Fatalf("index did not reach its server barrier: %v\n%s", err, f.dump())
		}
		if waiting {
			break
		}
		select {
		case err := <-built:
			t.Fatalf("index exited before the writer barrier: %v", err)
		default:
		}
		runtime.Gosched()
	}
	apply(t, m, successor("index-start"))
	assertIndexCatalog(t, f, m)
	f.exec(t, "begin")
	f.exec(t, "select pg_advisory_xact_lock($1,7),pg_advisory_xact_lock($1,8)", f.fence)
	f.exec(t, "select "+f.schema+".tesl_advance_floor(7,9,'retirement',1,'tesl-1','fixture')")
	f.exec(t, "commit")
	apply(t, m, Op{Kind: "retire-begin", Version: 9}, Op{Kind: "retire-commit", Version: 9})
	assertIndexCatalog(t, f, m)
	if _, err := f.conn.Exec(f.ctx, "select "+f.schema+".tesl_admit(8)"); err == nil {
		t.Fatal("retirement still admits the creating version")
	}
	var acquired bool
	if err := contract.QueryRow(f.ctx, "select pg_try_advisory_lock($1::bigint)", jobKey).Scan(&acquired); err != nil || acquired {
		t.Fatalf("contract passed the surviving V9 worker: %t %v", acquired, err)
	}
	denied(t, m, Op{Kind: "index-terminal", ID: "notes_title_v8", Version: 9})
	f.execOn(t, writer, "commit")
	awaitIndexStatement(t, f, built, false)
	apply(t, m, successor("index-success"), successor("index-verify"))
	assertIndexCatalog(t, f, m)
	f.execOn(t, worker, "select pg_advisory_unlock_shared($1::bigint)", jobKey)
	apply(t, m, successor("index-exit"))
	f.execOn(t, contract, "select pg_advisory_lock($1::bigint)", jobKey)
	f.execOn(t, contract, "update "+f.schema+".tesl_schema_index set state='terminal',terminal_version=9 where name='notes_title_v8'")
	apply(t, m, Op{Kind: "index-terminal", ID: "notes_title_v8", Version: 9})
	terminateBootstrapBackend(t, f, contract)
	apply(t, m, Op{Kind: "crash"})
	recovery := f.other(t)
	f.execOn(t, recovery, "select pg_advisory_lock($1::bigint)", jobKey)
	for _, target := range []int{8, 9} {
		if err := dropFixtureIndex(f, recovery, "notes_title_v8", target); err == nil {
			t.Fatalf("V%d removal passed without its matching plan switch", target)
		}
		assertIndexCatalog(t, f, m)
	}
	f.execOn(t, recovery, "select "+f.schema+".tesl_begin_contract(9,'contract-9',1,'tesl-1','fixture')")
	apply(t, m, Op{Kind: "contract-begin", Version: 9})
	for range 2 {
		if err := dropFixtureIndex(f, recovery, "notes_title_v8", 9); err != nil {
			t.Fatal(err)
		}
		apply(t, m, indexOp("index-drop", "", 0))
		assertIndexCatalog(t, f, m)
	}
}

// INV-UNIQUE-WINDOW, INV-INDEX-READY, INV-INDEX-RECOVERY; TR-INDEX-START, TR-INDEX-FAILURE, TR-INDEX-CLEANUP.
func TestPostgresFailedUniqueBuildCanRejectWritesBeforeItIsValid(t *testing.T) {
	f := newDatabaseFixture(t)
	f.exec(t, "create table "+f.schema+".unique_notes(id int primary key,title text)")
	f.exec(t, "insert into "+f.schema+".unique_notes values (1,'same')")
	// A test-only identity expression pauses the first index scan without
	// changing key equality. IMMUTABLE is needed solely to let PostgreSQL use
	// this synchronization hook in an index expression; no production function
	// may acquire locks while claiming to be immutable.
	f.exec(t, fmt.Sprintf(`create function %s.pause_index_key(value text) returns text
language plpgsql immutable as $$ begin
  perform pg_advisory_xact_lock_shared(%d,-300);
  return value;
end $$`, f.schema, f.fence))
	f.exec(t, "select pg_advisory_lock($1,-300)", f.fence)
	builder, app := f.other(t), f.other(t)
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_, _ = f.conn.Exec(ctx, "select pg_advisory_unlock($1,-300)", f.fence)
	})
	done := make(chan error, 1)
	go func() {
		_, err := builder.Exec(f.ctx, "create unique index concurrently notes_unique_v8 on "+f.schema+".unique_notes("+f.schema+".pause_index_key(title))")
		done <- err
	}()
	for {
		var paused bool
		if err := f.conn.QueryRow(f.ctx, "select exists(select 1 from pg_locks where pid=$1 and locktype='advisory' and classid=$2::oid and objid=(-300)::int::oid and objsubid=2 and not granted)", builder.PgConn().PID(), f.fence).Scan(&paused); err != nil {
			t.Fatalf("observe paused first index scan: %v\n%s", err, f.dump())
		}
		if paused {
			break
		}
		select {
		case err := <-done:
			t.Fatalf("index scan bypassed its deterministic pause: %v\n%s", err, f.dump())
		default:
		}
		runtime.Gosched()
	}
	var ready, valid bool
	if err := f.conn.QueryRow(f.ctx, "select indisready,indisvalid from pg_index where indexrelid=to_regclass($1)", f.schema+".notes_unique_v8").Scan(&ready, &valid); err != nil || ready || valid {
		t.Fatalf("unexpected first-scan state: ready=%t valid=%t %v", ready, valid, err)
	}
	// The old writer commits a duplicate outside the first scan's snapshot.
	// The index is not yet maintained by writes, so this statement succeeds.
	f.execOn(t, app, "insert into "+f.schema+".unique_notes values (2,'same')")
	f.exec(t, "select pg_advisory_unlock($1,-300)", f.fence)
	select {
	case err := <-done:
		var pgerr *pgconn.PgError
		if !errors.As(err, &pgerr) || pgerr.Code != "23505" {
			t.Fatalf("validation did not find the concurrent duplicate: %v\n%s", err, f.dump())
		}
	case <-f.ctx.Done():
		t.Fatalf("unique build did not finish: %v\n%s", f.ctx.Err(), f.dump())
	}
	if err := f.conn.QueryRow(f.ctx, "select indisready,indisvalid from pg_index where indexrelid=to_regclass($1)", f.schema+".notes_unique_v8").Scan(&ready, &valid); err != nil || !ready || valid {
		t.Fatalf("failed validation did not leave a ready invalid index: ready=%t valid=%t %v", ready, valid, err)
	}
	_, err := app.Exec(f.ctx, "insert into "+f.schema+".unique_notes values (3,'same')")
	var pgerr *pgconn.PgError
	if !errors.As(err, &pgerr) || pgerr.Code != "23505" {
		t.Fatalf("ready invalid index did not enforce uniqueness: %v", err)
	}
	// The failed build's real behavioral window ends only after cleanup.
	f.execOn(t, builder, "drop index concurrently "+f.schema+".notes_unique_v8")
	f.execOn(t, app, "insert into "+f.schema+".unique_notes values (3,'same')")
	var duplicates int
	if err := f.conn.QueryRow(f.ctx, "select count(*) from "+f.schema+".unique_notes where title='same'").Scan(&duplicates); err != nil || duplicates != 3 {
		t.Fatalf("cleanup failed to restore the old writer's schema behavior: rows=%d %v", duplicates, err)
	}
}
