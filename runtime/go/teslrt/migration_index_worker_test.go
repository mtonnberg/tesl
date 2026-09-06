package teslrt

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

type pgIndexTestService struct {
	cancel context.CancelFunc
	done   chan struct{}
	ready  chan PgMigrationControlState
	err    error
	pid    uint32
}

func pgStartIndexTestService(t *testing.T, f *pgControlTestFixture, current int, unique bool, expected PgMigrationControlState, settings pgIndexWorkerSettings) *pgIndexTestService {
	t.Helper()
	config := f.worker.Config().Copy()
	conn, err := pgx.ConnectConfig(f.ctx, config.Copy())
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(f.ctx)
	service := &pgIndexTestService{cancel: cancel, done: make(chan struct{}), ready: make(chan PgMigrationControlState, 2), pid: conn.PgConn().PID()}
	go func() {
		service.err = pgRunMigrationIndexWorkerWithSettings(ctx, conn, config, pgIndexExpansionTestHistory(f.namespace, current, unique), f.roles, expected,
			func(state PgMigrationControlState) error { service.ready <- state; return nil }, settings)
		close(service.done)
	}()
	t.Cleanup(func() {
		cancel()
		select {
		case <-service.done:
		case <-time.After(7 * time.Second):
			t.Error("index worker did not join its actors during cancellation")
		}
	})
	return service
}

func pgIndexTestSettings() pgIndexWorkerSettings {
	return pgIndexWorkerSettings{lease: 3 * time.Second, renew: 250 * time.Millisecond, poll: 100 * time.Millisecond, query: 2 * time.Second, cleanup: 3 * time.Second}
}

func pgIndexTestAwait(t *testing.T, f *pgControlTestFixture, service *pgIndexTestService, description string, condition func() bool) {
	t.Helper()
	ticker := time.NewTicker(10 * time.Millisecond)
	defer ticker.Stop()
	for {
		if condition() {
			return
		}
		select {
		case <-service.done:
			t.Fatalf("%s: worker exited: %v", description, service.err)
		case <-f.ctx.Done():
			t.Fatalf("%s: %v", description, f.ctx.Err())
		case <-ticker.C:
		}
	}
}

func pgIndexTestReady(t *testing.T, f *pgControlTestFixture, service *pgIndexTestService) {
	t.Helper()
	select {
	case state := <-service.ready:
		if state.Current < 2 {
			t.Fatalf("premature ready state: %+v", state)
		}
	case <-service.done:
		t.Fatalf("worker exited before readiness: %v", service.err)
	case <-f.ctx.Done():
		t.Fatal(f.ctx.Err())
	}
}

func pgIndexTestStop(t *testing.T, service *pgIndexTestService) {
	t.Helper()
	service.cancel()
	select {
	case <-service.done:
		if service.err != nil {
			t.Fatal(service.err)
		}
	case <-time.After(7 * time.Second):
		t.Fatal("worker cancellation was not bounded")
	}
}

func pgIndexTestWaitingBuild(t *testing.T, f *pgControlTestFixture, service *pgIndexTestService) (uint32, string) {
	t.Helper()
	var pid uint32
	var tag string
	pgIndexTestAwait(t, f, service, "CIC waiting for the real writer transaction", func() bool {
		err := f.installer.QueryRow(f.ctx, `select p.pid,a.application_name from pg_catalog.pg_stat_progress_create_index p
 join pg_catalog.pg_stat_activity a using(pid) where p.datid=(select oid from pg_catalog.pg_database where datname=current_database())
 and p.relid='notes_app.notes'::regclass and p.phase='waiting for writers before build'`).Scan(&pid, &tag)
		if errors.Is(err, pgx.ErrNoRows) {
			return false
		}
		if err != nil {
			t.Fatal(err)
		}
		return true
	})
	return pid, tag
}

func pgIndexTestWriter(t *testing.T, f *pgControlTestFixture, request *pgx.Conn) pgx.Tx {
	t.Helper()
	tx, err := request.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = tx.Rollback(context.Background()) })
	if _, err := tx.Exec(f.ctx, "insert into notes_app.notes(id,active) values('old-writer',false)"); err != nil {
		t.Fatal(err)
	}
	return tx
}

func pgIndexTestValid(t *testing.T, f *pgControlTestFixture, service *pgIndexTestService) pgMigrationIndexJob {
	t.Helper()
	var job pgMigrationIndexJob
	pgIndexTestAwait(t, f, service, "durable valid index", func() bool {
		jobs := pgIndexControlTestJobs(t, f)
		if len(jobs) != 1 {
			t.Fatalf("jobs: %+v", jobs)
		}
		job = jobs[0]
		return job.State == "valid" && job.Holder == ""
	})
	var valid bool
	if err := f.installer.QueryRow(f.ctx, `select indisvalid and indisready and indislive from pg_catalog.pg_index where indexrelid=pg_catalog.to_regclass($1)`, "notes_app."+job.Index.Name).Scan(&valid); err != nil || !valid {
		t.Fatalf("valid metadata without the physical ready/live result: %v %v", valid, err)
	}
	return job
}

func TestPgMigrationIndexWorkerBuildsConcurrentlyAndRenewsWhileBlocked(t *testing.T) {
	for _, unique := range []bool{false, true} {
		t.Run(fmt.Sprintf("unique=%v", unique), func(t *testing.T) {
			f, request := pgNewWorkerTest(t)
			f.install(t, 1)
			pgExpandIndexTest(t, f, 1, unique)
			f.call(t, "insert into notes_app.notes(id,active) values('retained',true)")
			state := pgExpandIndexTest(t, f, 2, unique)
			writer := pgIndexTestWriter(t, f, request)
			service := pgStartIndexTestService(t, f, 2, unique, state, pgIndexTestSettings())
			if !unique {
				pgIndexTestReady(t, f, service)
			}
			pid, tag := pgIndexTestWaitingBuild(t, f, service)
			initial := pgIndexControlTestJobs(t, f)[0]
			if initial.State != "building" || initial.Attempts != 1 || initial.ExpiresAt == nil || initial.Holder != tag {
				t.Fatalf("initial build: %+v", initial)
			}
			// Observe renewal beyond an entire original lease, without releasing the
			// writer. A startup deadline or a DDL statement_timeout cannot kill it.
			pgIndexTestAwait(t, f, service, "renewal while the DDL connection is blocked", func() bool {
				job := pgIndexControlTestJobs(t, f)[0]
				if job.Attempts != 1 || job.Token != initial.Token || job.Holder != tag {
					t.Fatalf("live work was replaced: %+v", job)
				}
				return job.ExpiresAt != nil && job.ExpiresAt.After(initial.ExpiresAt.Add(pgIndexTestSettings().lease))
			})
			var fences, jobLocks, heartbeats int
			if err := f.installer.QueryRow(f.ctx, `select count(*) filter(where objsubid=2),count(*) filter(where objsubid=1)
 from pg_catalog.pg_locks where pid=$1 and locktype='advisory' and granted and mode='ShareLock'`, pid).Scan(&fences, &jobLocks); err != nil || fences != 1 || jobLocks != 1 {
				t.Fatalf("DDL lifetime fence/job domains: %d %d %v", fences, jobLocks, err)
			}
			if err := f.installer.QueryRow(f.ctx, "select count(*) from notes_app.tesl_schema_instances where instance=$1 and version=2 and protocol_level=1 and compat_floor_seen=1", tag).Scan(&heartbeats); err != nil || heartbeats != 1 {
				t.Fatalf("missing worker heartbeat: %d %v", heartbeats, err)
			}
			if unique {
				select {
				case <-service.ready:
					t.Fatal("unique index became ready while the actual CIC was blocked")
				default:
				}
			}
			if err := writer.Commit(f.ctx); err != nil {
				t.Fatal(err)
			}
			job := pgIndexTestValid(t, f, service)
			if job.Attempts != 1 {
				t.Fatalf("completed index rebuilt: %+v", job)
			}
			if unique {
				pgIndexTestReady(t, f, service)
			}
			for _, version := range []int{1, 2} {
				if _, err := pgWaitForMigrationReadiness(f.ctx, request, pgIndexExpansionTestHistory(f.namespace, version, unique), f.roles); err != nil {
					t.Fatalf("V%d restart: %v", version, err)
				}
			}
			var rows int
			if err := request.QueryRow(f.ctx, "select count(*) from notes_app.notes where token is null").Scan(&rows); err != nil || rows != 2 {
				t.Fatalf("retained/old-writer rows: %d %v", rows, err)
			}
			pgIndexTestStop(t, service)
			var remaining int
			if err := f.installer.QueryRow(f.ctx, "select count(*) from pg_stat_activity where datname=current_database() and application_name=$1", tag).Scan(&remaining); err != nil || remaining != 0 {
				t.Fatalf("cancelled worker retained backends: %d %v", remaining, err)
			}
			select {
			case <-service.ready:
				t.Fatal("readiness callback repeated")
			default:
			}
		})
	}
}

func TestPgMigrationIndexWorkerRealUniqueFailureCleansAndRetries(t *testing.T) {
	f, _ := pgNewWorkerTest(t)
	f.install(t, 1)
	pgExpandIndexTest(t, f, 1, true)
	state := pgExpandIndexTest(t, f, 2, true)
	// Fault injection by an operator: old admitted application writers only
	// omit NULL here, so cannot produce these conflicting non-null new keys.
	f.call(t, "insert into notes_app.notes(id,active,token) values('a',true,'duplicate'),('b',false,'duplicate')")
	settings := pgIndexTestSettings()
	settings.poll = 2 * time.Second
	service := pgStartIndexTestService(t, f, 2, true, state, settings)
	var failed pgMigrationIndexJob
	pgIndexTestAwait(t, f, service, "durable unique failure and invalid-remnant cleanup", func() bool {
		failed = pgIndexControlTestJobs(t, f)[0]
		var absent bool
		if err := f.installer.QueryRow(f.ctx, "select to_regclass('notes_app.token__v2') is null").Scan(&absent); err != nil {
			t.Fatal(err)
		}
		return failed.State == "failed" && failed.Holder == "" && absent
	})
	if !strings.Contains(failed.Error, "23505") || !strings.Contains(failed.Error, "duplicate") || failed.Attempts != 1 {
		t.Fatalf("failed attempt evidence: %+v", failed)
	}
	select {
	case <-service.ready:
		t.Fatal("failed unique build was announced ready")
	default:
	}
	f.call(t, "update notes_app.notes set token='repaired' where id='b'")
	job := pgIndexTestValid(t, f, service)
	pgIndexTestReady(t, f, service)
	if job.Attempts != 2 || job.Error != "" {
		t.Fatalf("repair did not preserve attempts/clear current error: %+v", job)
	}
	var rows int
	if err := f.worker.QueryRow(f.ctx, "select count(*) from notes_app.notes").Scan(&rows); err != nil || rows != 2 {
		t.Fatalf("failed index altered stored rows: %d %v", rows, err)
	}
	pgIndexTestStop(t, service)
}

func TestPgMigrationIndexWorkerReconnectsAfterEitherOwnedBackendDies(t *testing.T) {
	for _, which := range []string{"ddl", "coordinator"} {
		t.Run(which, func(t *testing.T) {
			f, request := pgNewWorkerTest(t)
			f.install(t, 1)
			pgExpandIndexTest(t, f, 1, false)
			state := pgExpandIndexTest(t, f, 2, false)
			writer := pgIndexTestWriter(t, f, request)
			service := pgStartIndexTestService(t, f, 2, false, state, pgIndexTestSettings())
			pgIndexTestReady(t, f, service)
			pid, oldTag := pgIndexTestWaitingBuild(t, f, service)
			oldJob := pgIndexControlTestJobs(t, f)[0]
			victim := pid
			if which == "coordinator" {
				if err := f.installer.QueryRow(f.ctx, "select pid from pg_stat_activity where datname=current_database() and application_name=$1 and pid<>$2", oldTag, pid).Scan(&victim); err != nil {
					t.Fatal(err)
				}
			}
			if _, err := f.installer.Exec(f.ctx, "select pg_terminate_backend($1)", victim); err != nil {
				t.Fatal(err)
			}
			pgIndexTestAwait(t, f, service, "fresh tag claims only after old executor backends disappear", func() bool {
				job := pgIndexControlTestJobs(t, f)[0]
				if job.Holder == "" || job.Holder == oldTag {
					return false
				}
				var remaining int
				if err := f.installer.QueryRow(f.ctx, "select count(*) from pg_stat_activity where datname=current_database() and application_name=$1", oldTag).Scan(&remaining); err != nil {
					t.Fatal(err)
				}
				if remaining != 0 || job.Token <= oldJob.Token {
					t.Fatalf("replacement preceded old-tag disappearance: remaining=%d job=%+v", remaining, job)
				}
				return true
			})
			if err := writer.Commit(f.ctx); err != nil {
				t.Fatal(err)
			}
			pgIndexTestValid(t, f, service)
			pgIndexTestStop(t, service)
			select {
			case <-service.ready:
				t.Fatal("reconnection repeated readiness callback")
			default:
			}
		})
	}
}

func TestPgMigrationIndexWorkerCompetingWorkersDoNotRebuildValidResults(t *testing.T) {
	f, request := pgNewWorkerTest(t)
	f.install(t, 1)
	pgExpandIndexTest(t, f, 1, false)
	state := pgExpandIndexTest(t, f, 2, false)
	writer := pgIndexTestWriter(t, f, request)
	one := pgStartIndexTestService(t, f, 2, false, state, pgIndexTestSettings())
	pgIndexTestReady(t, f, one)
	_, tag := pgIndexTestWaitingBuild(t, f, one)
	initial := pgIndexControlTestJobs(t, f)[0]
	two := pgStartIndexTestService(t, f, 2, false, state, pgIndexTestSettings())
	pgIndexTestReady(t, f, two)
	var observed time.Time
	pgIndexTestAwait(t, f, two, "second worker heartbeat proves independent polling", func() bool {
		err := f.installer.QueryRow(f.ctx, "select last_seen from notes_app.tesl_schema_instances where instance<>$1 and instance like 'tesl-exec:%'", tag).Scan(&observed)
		if errors.Is(err, pgx.ErrNoRows) {
			return false
		}
		if err != nil {
			t.Fatal(err)
		}
		return true
	})
	pgIndexTestAwait(t, f, two, "competing worker completes another readiness poll", func() bool {
		var later time.Time
		if err := f.installer.QueryRow(f.ctx, "select last_seen from notes_app.tesl_schema_instances where instance<>$1 and instance like 'tesl-exec:%'", tag).Scan(&later); err != nil {
			t.Fatal(err)
		}
		return later.After(observed)
	})
	if job := pgIndexControlTestJobs(t, f)[0]; job.Token != initial.Token || job.Attempts != 1 || job.Holder != tag {
		t.Fatalf("competitor stole active work: %+v", job)
	}
	pgIndexTestStop(t, one)
	if err := writer.Commit(f.ctx); err != nil {
		t.Fatal(err)
	}
	job := pgIndexTestValid(t, f, two)
	if job.Token <= initial.Token {
		t.Fatalf("successor did not fence dead holder: %+v", job)
	}
	var oid uint32
	if err := f.installer.QueryRow(f.ctx, "select 'notes_app.active__v2'::regclass::oid").Scan(&oid); err != nil {
		t.Fatal(err)
	}
	pgIndexTestStop(t, two)
	three := pgStartIndexTestService(t, f, 2, false, state, pgIndexTestSettings())
	pgIndexTestReady(t, f, three)
	var again uint32
	if err := f.installer.QueryRow(f.ctx, "select 'notes_app.active__v2'::regclass::oid").Scan(&again); err != nil || again != oid {
		t.Fatalf("restart replaced successful physical index: %d %d %v", oid, again, err)
	}
	if later := pgIndexControlTestJobs(t, f)[0]; later.Attempts != job.Attempts || later.Token != job.Token {
		t.Fatalf("restart claimed immutable completed work: %+v", later)
	}
	pgIndexTestStop(t, three)
}

func TestPgMigrationIndexWorkerReconnectClassification(t *testing.T) {
	for _, err := range []error{nil, errors.New("catalog corruption"), context.Canceled, &pgconn.PgError{Code: "42501"}, &pgconn.PgError{Code: "23505"}, pgIndexRefuse("ABI differs"), &pgIndexWorkerRefusal{io.EOF}} {
		if pgIndexCanReconnect(err) {
			t.Errorf("logical refusal became retry: %v", err)
		}
	}
	for _, err := range []error{errPgIndexLeaseLost, errPgIndexSessionLost, io.EOF, io.ErrUnexpectedEOF, net.ErrClosed, context.DeadlineExceeded, &pgconn.PgError{Code: "08006"}, &pgconn.PgError{Code: "57P01"}} {
		if !pgIndexCanReconnect(err) {
			t.Errorf("transport loss did not retry: %v", err)
		}
	}
}

func TestPgMigrationIndexWorkerTimingConfiguration(t *testing.T) {
	t.Setenv("TESL_LEASE_TTL_S", "")
	t.Setenv("TESL_SCHEMA_POLL_S", "")
	settings, err := pgIndexWorkerConfiguration()
	if err != nil || settings.lease != 30*time.Second || settings.renew != 5*time.Second || settings.poll != 5*time.Second {
		t.Fatalf("defaults: %+v %v", settings, err)
	}
	for _, name := range []string{"TESL_LEASE_TTL_S", "TESL_SCHEMA_POLL_S"} {
		for _, value := range []string{"0", "-1", "601", "1.5", "1s", "garbage"} {
			t.Run(name+"/"+value, func(t *testing.T) {
				t.Setenv(name, value)
				if _, err := pgIndexWorkerConfiguration(); err == nil {
					t.Fatal("invalid timing accepted")
				}
			})
		}
	}
	t.Setenv("TESL_LEASE_TTL_S", "1")
	settings, err = pgIndexWorkerConfiguration()
	if err != nil || settings.renew != time.Second/3 || settings.query != time.Second/3 {
		t.Fatalf("short lease must retain renewal margin: %+v %v", settings, err)
	}
}

func TestPgMigrationIndexWorkerJobLockHashUsesStableFramedDomain(t *testing.T) {
	if got := pgMigrationDDLJobKey("123e4567-e89b-12d3-a456-426614174000", strings.Repeat("a", 64)); got != -6447004862075377196 {
		t.Fatalf("job lock wire vector changed: %d", got)
	}
	if got := pgMigrationDDLJobKey("雪", "quote\""); got != 1970044606415187354 {
		t.Fatalf("UTF-8 byte framing changed: %d", got)
	}
	if pgMigrationDDLJobKey("ab", "c") == pgMigrationDDLJobKey("a", "bc") {
		t.Fatal("field boundaries disappeared")
	}
}

func TestPgMigrationIndexWorkerRefusesABIAndPhysicalDriftBeforeClaim(t *testing.T) {
	for _, fault := range []string{"abi", "wrong-shape"} {
		t.Run(fault, func(t *testing.T) {
			f, _ := pgNewWorkerTest(t)
			f.install(t, 1)
			pgExpandIndexTest(t, f, 1, false)
			state := pgExpandIndexTest(t, f, 2, false)
			history := pgIndexExpansionTestHistory(f.namespace, 2, false)
			if fault == "abi" {
				history.SourceCompilerABI = "tesl-source-abi-v1:" + strings.Repeat("b", 64)
				history.HistoryJSON = strings.ReplaceAll(history.HistoryJSON, pgTestSourceABI, history.SourceCompilerABI)
			} else {
				f.call(t, "create index active__v2 on notes_app.notes(id)")
			}
			config := f.worker.Config().Copy()
			conn, err := pgx.ConnectConfig(f.ctx, config.Copy())
			if err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(f.ctx, 3*time.Second)
			defer cancel()
			ready := false
			err = pgRunMigrationIndexWorkerWithSettings(ctx, conn, config, history, f.roles, state, func(PgMigrationControlState) error { ready = true; return nil }, pgIndexTestSettings())
			if err == nil || ready || ctx.Err() != nil {
				t.Fatalf("unsafe executor did not refuse before work: err=%v ready=%v deadline=%v", err, ready, ctx.Err())
			}
			job := pgIndexControlTestJobs(t, f)[0]
			if job.Attempts != 0 || job.Token != 0 || job.Holder != "" || job.State != "pending" {
				t.Fatalf("refusal claimed or executed work: %+v", job)
			}
		})
	}
}

func TestPgMigrationIndexWorkerExpiresAndRemovesEveryStuckHolderBackend(t *testing.T) {
	f, request := pgNewWorkerTest(t)
	f.install(t, 1)
	pgExpandIndexTest(t, f, 1, false)
	state := pgExpandIndexTest(t, f, 2, false)
	writer := pgIndexTestWriter(t, f, request)
	job := pgIndexControlTestJobs(t, f)[0]
	oldTag := "tesl-exec:stopped-holder"
	config := f.worker.Config().Copy()
	config.RuntimeParams["application_name"] = oldTag
	oldDDL, err := pgx.ConnectConfig(f.ctx, config.Copy())
	if err != nil {
		t.Fatal(err)
	}
	oldControl, err := pgx.ConnectConfig(f.ctx, config.Copy())
	if err != nil {
		_ = oldDDL.Close(f.ctx)
		t.Fatal(err)
	}
	oldPID := oldDDL.PgConn().PID()
	if _, err := oldDDL.Exec(f.ctx, "select pg_advisory_lock_shared($1::int,$2::int)", state.FenceNamespace, 2); err != nil {
		t.Fatal(err)
	}
	var token int64
	if err := oldControl.QueryRow(f.ctx, "select notes_app.tesl_claim_index($1,2,$2,200)", job.ID, pgTestSourceABI).Scan(&token); err != nil || token < 1 {
		t.Fatalf("old claim: %d %v", token, err)
	}
	if err := pgIndexRecord(f.ctx, oldControl, f.namespace, pgMigrationIndexJob{ID: job.ID, Token: token}, "building", nil); err != nil {
		t.Fatal(err)
	}
	// This holder's coordinator is deliberately idle and never renews, while
	// its separately owned autocommit DDL backend continues waiting in the server.
	oldContext, stopOld := context.WithCancel(f.ctx)
	oldDone := make(chan struct{})
	var oldError error
	go func() {
		_, oldError = oldDDL.Exec(oldContext, "create index concurrently active__v2 on notes_app.notes(active)")
		close(oldDone)
	}()
	t.Cleanup(func() {
		stopOld()
		_ = oldDDL.PgConn().Conn().Close()
		select {
		case <-oldDone:
		case <-time.After(5 * time.Second):
			t.Error("stopped holder DDL did not end")
		}
		_ = oldDDL.Close(context.Background())
		_ = oldControl.Close(context.Background())
	})
	// The test oracle observes server progress, not a sleep that merely hopes
	// the background CREATE INDEX reached its dangerous active phase.
	watch := &pgIndexTestService{done: make(chan struct{})}
	pid, tag := pgIndexTestWaitingBuild(t, f, watch)
	if pid != oldPID || tag != oldTag {
		t.Fatalf("unexpected old builder: %d %s", pid, tag)
	}
	pgIndexTestAwait(t, f, watch, "old holder expired on the PostgreSQL clock", func() bool {
		var expired bool
		if err := f.installer.QueryRow(f.ctx, "select expires_at<=clock_timestamp() from notes_app.tesl_schema_leases where name='index:active__v2'").Scan(&expired); err != nil {
			t.Fatal(err)
		}
		return expired
	})
	service := pgStartIndexTestService(t, f, 2, false, state, pgIndexTestSettings())
	pgIndexTestReady(t, f, service)
	pgIndexTestAwait(t, f, service, "takeover follows full-tag disappearance", func() bool {
		current := pgIndexControlTestJobs(t, f)[0]
		if current.Holder == "" || current.Holder == oldTag {
			return false
		}
		var remaining int
		if err := f.installer.QueryRow(f.ctx, "select count(*) from pg_stat_activity where datname=current_database() and application_name=$1", oldTag).Scan(&remaining); err != nil {
			t.Fatal(err)
		}
		if remaining != 0 || current.Token <= token {
			t.Fatalf("takeover retained a stale backend/token: %d %+v", remaining, current)
		}
		return true
	})
	select {
	case <-oldDone:
		if oldError == nil {
			t.Fatal("expired active statement survived termination")
		}
	case <-f.ctx.Done():
		t.Fatal(f.ctx.Err())
	}
	if err := writer.Commit(f.ctx); err != nil {
		t.Fatal(err)
	}
	finished := pgIndexTestValid(t, f, service)
	if finished.Attempts != 2 {
		t.Fatalf("takeover did not clean/rebuild exactly the invalid failed attempt: %+v", finished)
	}
	pgIndexTestStop(t, service)
}
