package teslrt

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// This suite exercises the unpublished protected SQL directly using restricted
// request connections. The candidate worker registers later source inventories:
// production format selection and runtime dispatch remain closed.
type pgQueueOperationsFixture struct {
	*pgControlTestFixture
	request *pgx.Conn
}
type pgQueueOperationClient interface {
	QueryRow(context.Context, string, ...any) pgx.Row
}
type pgQueueClaimResult struct {
	ID, Job, Payload  string
	Version, Attempts int
	Token             string
	Sequence          int64
}

func pgNewQueueOperationsTest(t *testing.T, latest int) *pgQueueOperationsFixture {
	t.Helper()
	f, request := pgNewWorkerTest(t)
	h, root := pgCandidateTestSource(t, 1, false, "")
	registerQueueProjection(t, h, root)
	if _, err := pgInstallQueueCandidate(f.ctx, f.installer, h, f.roles); err != nil {
		t.Fatal(err)
	}
	plan, err := h.ExpansionPlan(1)
	if err != nil {
		t.Fatal(err)
	}
	if err = pgApplyExpansion(f.ctx, f.worker, plan, f.roles, 0, map[int]*pgExpansionIntent{}); err != nil {
		t.Fatal(err)
	}
	if latest > 1 {
		later, source := pgCandidateTestSource(t, latest, false, "")
		pgQueueRegistrationRelink(t, later, source)
		for version := 2; version <= latest; version++ {
			pgQueueRegistrationAdvance(t, f, later, version)
		}
	}
	return &pgQueueOperationsFixture{f, request}
}
func (f *pgQueueOperationsFixture) enqueue(t *testing.T, conn pgQueueOperationClient, v int, id string) {
	t.Helper()
	var actual string
	if err := conn.QueryRow(f.ctx, "select notes_app.tesl_queue_enqueue($1,'Notifications','Notify',$2,$3::jsonb)", v, id, `{"message":"retained 雪","nested":{"n":5}}`).Scan(&actual); err != nil || actual != id {
		t.Fatalf("enqueue %s: %s %v", id, actual, err)
	}
}
func (f *pgQueueOperationsFixture) claim(conn pgQueueOperationClient, v int, wanted string, lease int64) (pgQueueClaimResult, error) {
	var r pgQueueClaimResult
	err := conn.QueryRow(f.ctx, "select * from notes_app.tesl_queue_claim($1,'Notifications',$2,'fixture-worker',$3)", v, wanted, lease).Scan(&r.ID, &r.Job, &r.Payload, &r.Version, &r.Attempts, &r.Token, &r.Sequence)
	return r, err
}
func (f *pgQueueOperationsFixture) mustClaim(t *testing.T, conn pgQueueOperationClient, v int, wanted string) pgQueueClaimResult {
	t.Helper()
	r, err := f.claim(conn, v, wanted, 60000)
	if err != nil {
		t.Fatal(err)
	}
	return r
}
func (f *pgQueueOperationsFixture) boolean(t *testing.T, conn pgQueueOperationClient, want bool, sql string, args ...any) {
	t.Helper()
	var got bool
	if err := conn.QueryRow(f.ctx, sql, args...).Scan(&got); err != nil || got != want {
		t.Fatalf("%s: %v want %v: %v", sql, got, want, err)
	}
}
func (f *pgQueueOperationsFixture) complete(t *testing.T, conn pgQueueOperationClient, v int, c pgQueueClaimResult, want bool) {
	t.Helper()
	f.boolean(t, conn, want, "select notes_app.tesl_queue_complete($1,'Notifications',$2,$3,$4)", v, c.ID, c.Token, c.Sequence)
}
func (f *pgQueueOperationsFixture) expire(t *testing.T, id string) {
	t.Helper()
	if _, err := f.installer.Exec(f.ctx, "update notes_app.tesl_jobs set lease_until=clock_timestamp()-interval '1 second' where id=$1", id); err != nil {
		t.Fatal(err)
	}
}
func (f *pgQueueOperationsFixture) snapshot(t *testing.T) string {
	t.Helper()
	var value string
	if err := f.installer.QueryRow(f.ctx, "select coalesce(jsonb_agg(to_jsonb(j) order by seq),'[]')::text from notes_app.tesl_jobs j").Scan(&value); err != nil {
		t.Fatal(err)
	}
	return value
}
func TestQueueOperationsVersionIsolationAndRetry(t *testing.T) {
	f := pgNewQueueOperationsTest(t, 3)
	f.enqueue(t, f.request, 3, "newer")
	f.enqueue(t, f.request, 1, "older")
	newer := f.mustClaim(t, f.request, 3, "pending")
	if newer.ID != "newer" || newer.Version != 3 {
		t.Fatal(newer)
	}
	f.expire(t, newer.ID)
	before := f.snapshot(t)
	older := f.mustClaim(t, f.request, 1, "pending")
	if older.ID != "older" || older.Version != 1 {
		t.Fatal(older)
	}
	// Stale older processes cannot ACK, revive, or quarantine a newer attempt.
	f.complete(t, f.request, 1, newer, false)
	f.boolean(t, f.request, false, "select notes_app.tesl_queue_renew(1,'Notifications',$1,$2,$3,60000)", newer.ID, newer.Token, newer.Sequence)
	f.boolean(t, f.request, false, "select notes_app.tesl_queue_quarantine(1,'Notifications',$1,$2,$3)", newer.ID, newer.Token, newer.Sequence)
	var unchanged bool
	if err := f.installer.QueryRow(f.ctx, "select to_jsonb(j) = ($1::jsonb->0) from notes_app.tesl_jobs j where id='newer'", before).Scan(&unchanged); err != nil || !unchanged {
		t.Fatalf("old worker changed future row %v %v", unchanged, err)
	}
	f.complete(t, f.request, 1, older, true)
	if _, err := f.claim(f.request, 1, "pending", 60000); !errors.Is(err, pgx.ErrNoRows) {
		t.Fatalf("old worker reclaimed future row: %v", err)
	}
	reclaimed := f.mustClaim(t, f.request, 3, "pending")
	if reclaimed.ID != "newer" || reclaimed.Sequence != newer.Sequence+1 || reclaimed.Token == newer.Token {
		t.Fatal(reclaimed)
	}
	f.complete(t, f.request, 3, newer, false)
	f.complete(t, f.request, 3, reclaimed, true)
	f.enqueue(t, f.request, 1, "retry")
	c := f.mustClaim(t, f.request, 3, "pending")
	f.boolean(t, f.request, true, "select notes_app.tesl_queue_fail(3,'Notifications',$1,$2,$3,2,0)", c.ID, c.Token, c.Sequence)
	c = f.mustClaim(t, f.request, 3, "pending")
	if c.Version != 3 || c.Attempts != 1 {
		t.Fatalf("retry did not restamp current bytes: %+v", c)
	}
	f.boolean(t, f.request, true, "select notes_app.tesl_queue_fail(3,'Notifications',$1,$2,$3,2,0)", c.ID, c.Token, c.Sequence)
	if _, err := f.claim(f.request, 3, "pending", 60000); !errors.Is(err, pgx.ErrNoRows) {
		t.Fatal(err)
	}
	dead := f.mustClaim(t, f.request, 3, "dead")
	if dead.Attempts != 2 {
		t.Fatal(dead)
	}
	f.complete(t, f.request, 3, dead, true)
}
func TestQueueOperationsClaimFenceAndTransactionAuthority(t *testing.T) {
	for _, kind := range []string{"complete", "fail", "quarantine"} {
		t.Run(kind, func(t *testing.T) {
			f := pgNewQueueOperationsTest(t, 1)
			f.enqueue(t, f.request, 1, "short-lease")
			c := f.mustClaim(t, f.request, 1, "pending")
			f.expire(t, c.ID)
			var sql string
			args := []any{c.ID, c.Token, c.Sequence}
			switch kind {
			case "complete":
				sql = "select notes_app.tesl_queue_complete(1,'Notifications',$1,$2,$3)"
			case "fail":
				sql = "select notes_app.tesl_queue_fail(1,'Notifications',$1,$2,$3,3,0)"
			case "quarantine":
				sql = "select notes_app.tesl_queue_quarantine(1,'Notifications',$1,$2,$3)"
			}
			f.boolean(t, f.request, false, sql, args...)
			// Claim and mutation in one transaction may finish past its lease: the row
			// remains locked and the function proves transaction identity in PostgreSQL.
			tx, err := f.request.Begin(f.ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = tx.Rollback(f.ctx) }()
			c, err = f.claim(tx, 1, "pending", 1)
			if err != nil {
				t.Fatal(err)
			}
			if _, err = tx.Exec(f.ctx, "select pg_sleep(0.01)"); err != nil {
				t.Fatal(err)
			}
			f.boolean(t, tx, false, "select notes_app.tesl_queue_renew(1,'Notifications',$1,$2,$3,60000)", c.ID, c.Token, c.Sequence)
			f.boolean(t, tx, true, sql, c.ID, c.Token, c.Sequence)
			if err = tx.Commit(f.ctx); err != nil {
				t.Fatal(err)
			}
		})
	}
}
func TestQueueOperationsQuarantinePreservesPayloadAndIsNotRetryable(t *testing.T) {
	f := pgNewQueueOperationsTest(t, 1)
	f.enqueue(t, f.request, 1, "malformed-bytes")
	c := f.mustClaim(t, f.request, 1, "pending")
	f.boolean(t, f.request, true, "select notes_app.tesl_queue_quarantine(1,'Notifications',$1,$2,$3)", c.ID, c.Token, c.Sequence)
	for _, status := range []string{"pending", "dead"} {
		if _, err := f.claim(f.request, 1, status, 60000); !errors.Is(err, pgx.ErrNoRows) {
			t.Fatal(err)
		}
	}
	var payload, status, reason string
	var v, attempts int
	if err := f.installer.QueryRow(f.ctx, "select payload::text,status,dead_reason,schema_version,attempts from notes_app.tesl_jobs where id=$1", c.ID).Scan(&payload, &status, &reason, &v, &attempts); err != nil {
		t.Fatal(err)
	}
	if payload != c.Payload || status != "quarantined" || reason != "payload-invalid" || v != 1 || attempts != 0 {
		t.Fatalf("quarantine lost source: %s/%s/%s/%d/%d", payload, status, reason, v, attempts)
	}
	f.complete(t, f.request, 1, c, false)
}
func TestQueueOperationsSkipLockedAndRollback(t *testing.T) {
	f := pgNewQueueOperationsTest(t, 1)
	f.enqueue(t, f.request, 1, "locked")
	f.enqueue(t, f.request, 1, "available")
	c := f.mustClaim(t, f.request, 1, "pending")
	f.expire(t, c.ID)
	tx, err := f.installer.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(f.ctx) }()
	if _, err = tx.Exec(f.ctx, "select id from notes_app.tesl_jobs where id='locked' for update"); err != nil {
		t.Fatal(err)
	}
	if _, err = f.request.Exec(f.ctx, "set statement_timeout='1s'"); err != nil {
		t.Fatal(err)
	}
	other := f.mustClaim(t, f.request, 1, "pending")
	if other.ID != "available" {
		t.Fatal(other)
	}
	if err = tx.Rollback(f.ctx); err != nil {
		t.Fatal(err)
	}
	claimTx, err := f.request.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = claimTx.Rollback(f.ctx) }()
	claimed := f.mustClaim(t, claimTx, 1, "pending")
	if claimed.ID != "locked" {
		t.Fatal(claimed)
	}
	f.complete(t, claimTx, 1, claimed, true)
	if err = claimTx.Rollback(f.ctx); err != nil {
		t.Fatal(err)
	}
	reclaimed := f.mustClaim(t, f.request, 1, "pending")
	// Rolled-back sequence increments may repeat; random tokens must not.
	if reclaimed.Token == claimed.Token {
		t.Fatal("rolled-back attempt reused capability")
	}
	f.complete(t, f.request, 1, claimed, false)
	f.complete(t, f.request, 1, reclaimed, true)
}
func TestQueueOperationsRejectUninstalledRetiredUnknownAndWrongContract(t *testing.T) {
	for _, scenario := range []string{"uninstalled", "retired", "unknown", "missing-contract", "mismatched-bytes", "mismatched-hash"} {
		t.Run(scenario, func(t *testing.T) {
			f := pgNewQueueOperationsTest(t, 3)
			f.enqueue(t, f.request, 1, "retained")
			var sql string
			switch scenario {
			case "uninstalled":
				sql = "update notes_app.tesl_schema_state set current=0"
			case "retired":
				sql = "update notes_app.tesl_schema_state set min_version=2"
			case "unknown":
				sql = "update notes_app.tesl_queue_baseline set inventory_authority='unknown',established_by='format-upgrade',inventory_hash=null"
			case "missing-contract":
				sql = "delete from notes_app.tesl_queue_payloads where version=3; delete from notes_app.tesl_queue_contracts where version=3"
			case "mismatched-bytes":
				sql = "update notes_app.tesl_queue_payloads set contract=convert_to('different','UTF8'),contract_hash=encode(sha256(convert_to('different','UTF8')),'hex') where version=3"
			case "mismatched-hash":
				sql = "update notes_app.tesl_queue_versions set storage_snapshot_hash=repeat('f',64) where version=3"
			}
			if _, err := f.installer.Exec(f.ctx, sql); err != nil {
				t.Fatal(err)
			}
			before := f.snapshot(t)
			version := 3
			if scenario == "retired" {
				version = 1
			}
			_, err := f.claim(f.request, version, "pending", 60000)
			if scenario == "mismatched-bytes" {
				if !errors.Is(err, pgx.ErrNoRows) {
					t.Fatalf("incompatible payload reached worker: %v", err)
				}
			} else if err == nil || errors.Is(err, pgx.ErrNoRows) {
				t.Fatalf("bad admission was not refused: %v", err)
			}
			if before != f.snapshot(t) {
				t.Fatal("refusal mutated job")
			}
		})
	}
}
func TestQueueOperationsDirectWritesAndBadArguments(t *testing.T) {
	f := pgNewQueueOperationsTest(t, 1)
	for _, conn := range []*pgx.Conn{f.request, f.worker} {
		for _, sql := range []string{"select * from notes_app.tesl_jobs", "delete from notes_app.tesl_jobs", "update notes_app.tesl_jobs set schema_version=1", "select nextval('notes_app.tesl_jobs_seq_seq')"} {
			_, err := conn.Exec(f.ctx, sql)
			var denied *pgconn.PgError
			if !errors.As(err, &denied) || denied.Code != "42501" {
				t.Fatalf("direct access not denied by privileges: %s: %v", sql, err)
			}
		}
	}
	f.enqueue(t, f.request, 1, "untouched")
	before := f.snapshot(t)
	for _, sql := range []string{
		"select notes_app.tesl_queue_enqueue(1,'Notifications','Unknown','bad','{}')",
		"select notes_app.tesl_queue_enqueue(1,'Notifications','Notify','','{}')",
		"select notes_app.tesl_queue_enqueue(null,'Notifications','Notify','bad','{}')",
		"select * from notes_app.tesl_queue_claim(1,'Notifications','quarantined','worker',1000)",
		"select * from notes_app.tesl_queue_claim(1,'Notifications','pending','worker',0)",
		"select * from notes_app.tesl_queue_claim(1,'Notifications','pending','worker',9223372036855)",
		"select notes_app.tesl_queue_renew(1,'Notifications','untouched','token',1,0)",
		"select notes_app.tesl_queue_fail(1,'Notifications','untouched','token',1,0,0)",
	} {
		if _, err := f.request.Exec(f.ctx, sql); err == nil {
			t.Fatalf("invalid input accepted: %s", sql)
		}
		if before != f.snapshot(t) {
			t.Fatal("invalid input changed jobs")
		}
	}
}
func TestQueueOperationsNotificationCommitsWithEnqueue(t *testing.T) {
	f := pgNewQueueOperationsTest(t, 1)
	if _, err := f.worker.Exec(f.ctx, "listen tesl_queue"); err != nil {
		t.Fatal(err)
	}
	tx, err := f.request.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(f.ctx) }()
	f.enqueue(t, tx, 1, "rolled-back")
	if err = tx.Rollback(f.ctx); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(f.ctx, 30*time.Millisecond)
	_, err = f.worker.WaitForNotification(ctx)
	cancel()
	if err == nil {
		t.Fatal("rolled-back enqueue notified")
	}
	f.enqueue(t, f.request, 1, "committed")
	ctx, cancel = context.WithTimeout(f.ctx, time.Second)
	defer cancel()
	notification, err := f.worker.WaitForNotification(ctx)
	if err != nil || notification.Channel != queueNotifyChannel || notification.Payload != "Notifications" {
		t.Fatalf("notification %v: %v", notification, err)
	}
	if got := f.snapshot(t); strings.Contains(got, "rolled-back") {
		t.Fatalf("rolled back job persisted: %s", got)
	}
}

func TestQueueOperationsRetirementAfterFenceWaitIsObserved(t *testing.T) {
	f := pgNewQueueOperationsTest(t, 3)
	f.enqueue(t, f.request, 1, "must-remain")
	before := f.snapshot(t)
	tx, err := f.installer.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(f.ctx) }()
	var fence int
	if err = tx.QueryRow(f.ctx, "select fence_ns from notes_app.tesl_schema_meta where id=1").Scan(&fence); err != nil {
		t.Fatal(err)
	}
	if _, err = tx.Exec(f.ctx, "select pg_advisory_xact_lock($1,1)", fence); err != nil {
		t.Fatal(err)
	}
	// Query starts before retirement and waits on the version's fence. Its
	// admission snapshot must be refreshed after the wait, in the same statement.
	finished := make(chan error, 1)
	go func() { _, err := f.claim(f.request, 1, "pending", 60000); finished <- err }()
	waiting := false
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		if err = tx.QueryRow(f.ctx, "select exists(select 1 from pg_locks where pid=$1 and locktype='advisory' and not granted)", f.request.PgConn().PID()).Scan(&waiting); err != nil {
			t.Fatal(err)
		}
		if waiting {
			break
		}
		time.Sleep(time.Millisecond)
	}
	if !waiting {
		t.Fatal("claim did not reach the fence")
	}
	if _, err = tx.Exec(f.ctx, "update notes_app.tesl_schema_state set min_version=2 where id=1"); err != nil {
		t.Fatal(err)
	}
	if err = tx.Commit(f.ctx); err != nil {
		t.Fatal(err)
	}
	select {
	case err = <-finished:
		if err == nil || !strings.Contains(err.Error(), "retired") {
			t.Fatalf("stale pre-wait admission: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("fenced claim did not finish")
	}
	if before != f.snapshot(t) {
		t.Fatal("retired waiter changed retained payload")
	}
}
func TestQueueOperationsBusinessEffectsShareClaimTransaction(t *testing.T) {
	for _, commit := range []bool{false, true} {
		t.Run(fmt.Sprint(commit), func(t *testing.T) {
			f := pgNewQueueOperationsTest(t, 1)
			f.enqueue(t, f.request, 1, "business-effect")
			tx, err := f.request.Begin(f.ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = tx.Rollback(f.ctx) }()
			c := f.mustClaim(t, tx, 1, "pending")
			if _, err = tx.Exec(f.ctx, "insert into notes_app.notes(id,active) values('handled',true)"); err != nil {
				t.Fatal(err)
			}
			f.complete(t, tx, 1, c, true)
			if commit {
				err = tx.Commit(f.ctx)
			} else {
				err = tx.Rollback(f.ctx)
			}
			if err != nil {
				t.Fatal(err)
			}
			var effects, jobs int
			if err = f.installer.QueryRow(f.ctx, "select (select count(*) from notes_app.notes where id='handled'),(select count(*) from notes_app.tesl_jobs where id='business-effect')").Scan(&effects, &jobs); err != nil {
				t.Fatal(err)
			}
			if (commit && (effects != 1 || jobs != 0)) || (!commit && (effects != 0 || jobs != 1)) {
				t.Fatalf("split business/queue commit: %d effects, %d jobs", effects, jobs)
			}
		})
	}
}
func TestQueueOperationsRenewalAndAttemptCompareAndSwap(t *testing.T) {
	f := pgNewQueueOperationsTest(t, 1)
	f.enqueue(t, f.request, 1, "renew")
	c := f.mustClaim(t, f.request, 1, "pending")
	before := f.snapshot(t)
	f.boolean(t, f.request, false, "select notes_app.tesl_queue_renew(1,'Notifications',$1,$2,$3,60000)", c.ID, c.Token, c.Sequence+1)
	f.boolean(t, f.request, false, "select notes_app.tesl_queue_renew(1,'Notifications',$1,$2,$3,60000)", c.ID, "foreign-token", c.Sequence)
	f.boolean(t, f.request, false, "select notes_app.tesl_queue_complete(1,'Notifications',$1,$2,$3)", c.ID, c.Token, c.Sequence+1)
	f.boolean(t, f.request, false, "select notes_app.tesl_queue_fail(1,'Notifications',$1,$2,$3,1,0)", c.ID, "foreign-token", c.Sequence)
	if before != f.snapshot(t) {
		t.Fatal("stale token or attempt changed current claim")
	}
	f.boolean(t, f.request, true, "select notes_app.tesl_queue_renew(1,'Notifications',$1,$2,$3,60000)", c.ID, c.Token, c.Sequence)
	var stillSame bool
	if err := f.installer.QueryRow(f.ctx, "select claim_token=$1 and claim_seq=$2 and status='processing' and claimed_by_version=1 and lease_until>clock_timestamp() from notes_app.tesl_jobs where id=$3", c.Token, c.Sequence, c.ID).Scan(&stillSame); err != nil || !stillSame {
		t.Fatalf("renew changed claim identity: %v %v", stillSame, err)
	}
	f.complete(t, f.request, 1, c, true)
}

func TestQueueOperationsLeaseExpiryDuringUnchangedRowLock(t *testing.T) {
	for _, kind := range []string{"complete", "renew", "fail", "quarantine"} {
		t.Run(kind, func(t *testing.T) {
			f := pgNewQueueOperationsTest(t, 1)
			f.enqueue(t, f.request, 1, "held")
			c := f.mustClaim(t, f.request, 1, "pending")
			if _, err := f.installer.Exec(f.ctx, "update notes_app.tesl_jobs set lease_until=clock_timestamp()+interval '1 second' where id=$1", c.ID); err != nil {
				t.Fatal(err)
			}
			before := f.snapshot(t)
			held, err := f.installer.Begin(f.ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = held.Rollback(f.ctx) }()
			if _, err := held.Exec(f.ctx, "select id from notes_app.tesl_jobs where id=$1 for update", c.ID); err != nil {
				t.Fatal(err)
			}
			sql := "select notes_app.tesl_queue_" + kind + "(1,'Notifications',$1,$2,$3"
			switch kind {
			case "renew":
				sql += ",60000"
			case "fail":
				sql += ",3,0"
			}
			sql += ")"
			type result struct {
				changed bool
				err     error
			}
			done := make(chan result, 1)
			go func() {
				var changed bool
				err := f.request.QueryRow(f.ctx, sql, c.ID, c.Token, c.Sequence).Scan(&changed)
				done <- result{changed, err}
			}()
			for {
				var waiting, live bool
				if err := held.QueryRow(f.ctx, "select coalesce((select wait_event_type='Lock' from pg_stat_activity where pid=$1),false),(select lease_until>clock_timestamp() from notes_app.tesl_jobs where id=$2)", f.request.PgConn().PID(), c.ID).Scan(&waiting, &live); err != nil {
					t.Fatal(err)
				}
				if waiting {
					if !live {
						t.Fatal("waiter did not reach the row lock before expiry")
					}
					break
				}
				if !live {
					t.Fatal("query did not wait before expiry")
				}
				if _, err := held.Exec(f.ctx, "select pg_stat_clear_snapshot(),pg_sleep(0.005)"); err != nil {
					t.Fatal(err)
				}
			}
			if _, err := held.Exec(f.ctx, "select pg_sleep(greatest(0,extract(epoch from lease_until-clock_timestamp()))+0.03) from notes_app.tesl_jobs where id=$1", c.ID); err != nil {
				t.Fatal(err)
			}
			if err := held.Commit(f.ctx); err != nil {
				t.Fatal(err)
			}
			got := <-done
			if got.err != nil {
				t.Fatal(got.err)
			}
			if before != f.snapshot(t) {
				t.Fatal("expired operation changed the stored row")
			}
			if got.changed {
				t.Fatal("expired attempt mutated queue after waiting on an unchanged row lock")
			}
		})
	}
}

func TestQueueOperationsDeadMetadataAndRequeue(t *testing.T) {
	f := pgNewQueueOperationsTest(t, 3)
	f.enqueue(t, f.request, 1, "retryable")
	retryable := f.mustClaim(t, f.request, 1, "pending")
	f.boolean(t, f.request, true, "select notes_app.tesl_queue_fail(1,'Notifications',$1,$2,$3,1,0)", retryable.ID, retryable.Token, retryable.Sequence)
	f.enqueue(t, f.request, 1, "quarantined")
	quarantined := f.mustClaim(t, f.request, 1, "pending")
	f.boolean(t, f.request, true, "select notes_app.tesl_queue_quarantine(1,'Notifications',$1,$2,$3)", quarantined.ID, quarantined.Token, quarantined.Sequence)
	f.enqueue(t, f.request, 3, "future")
	future := f.mustClaim(t, f.request, 3, "pending")
	f.boolean(t, f.request, true, "select notes_app.tesl_queue_fail(3,'Notifications',$1,$2,$3,1,0)", future.ID, future.Token, future.Sequence)
	var count int
	if err := f.request.QueryRow(f.ctx, "select notes_app.tesl_queue_count(1,'Notifications','dead')").Scan(&count); err != nil || count != 2 {
		t.Fatalf("old visible count=%d %v", count, err)
	}
	rows, err := f.request.Query(f.ctx, "select * from notes_app.tesl_queue_dead_jobs(1,'Notifications')")
	if err != nil {
		t.Fatal(err)
	}
	type dead struct {
		ID, Job           string
		Version, Attempts int
		Reason            string
	}
	entries, err := pgx.CollectRows(rows, pgx.RowToStructByPos[dead])
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 2 || entries[0].ID != "retryable" || entries[0].Reason != "attempts-exhausted" || entries[0].Attempts != 1 || entries[1].ID != "quarantined" || entries[1].Reason != "payload-invalid" || entries[1].Version != 1 {
		t.Fatal(entries)
	}
	f.boolean(t, f.request, false, "select notes_app.tesl_queue_requeue(1,'Notifications','future')")
	f.boolean(t, f.request, false, "select notes_app.tesl_queue_requeue(3,'Notifications','quarantined')")
	f.boolean(t, f.request, true, "select notes_app.tesl_queue_requeue(3,'Notifications','retryable')")
	f.boolean(t, f.request, false, "select notes_app.tesl_queue_requeue(3,'Notifications','retryable')")
	c := f.mustClaim(t, f.request, 3, "pending")
	if c.ID != "retryable" || c.Version != 3 || c.Attempts != 0 {
		t.Fatal(c)
	}
	f.complete(t, f.request, 3, c, true)
	c = f.mustClaim(t, f.request, 3, "dead")
	f.boolean(t, f.request, false, "select notes_app.tesl_queue_requeue(3,'Notifications','future')")
	f.complete(t, f.request, 3, c, true)
	if _, err = f.installer.Exec(f.ctx, "update notes_app.tesl_schema_state set min_version=3"); err != nil {
		t.Fatal(err)
	}
	var id, reason string
	if err = f.request.QueryRow(f.ctx, "select job_id,reason from notes_app.tesl_queue_dead_jobs(3,'Notifications')").Scan(&id, &reason); err != nil || id != "quarantined" || reason != "payload-invalid" {
		t.Fatalf("old quarantine became invisible: %s %s %v", id, reason, err)
	}
}
func TestQueueOperationsClosedFunctionCatalog(t *testing.T) {
	f := pgNewQueueOperationsTest(t, 1)
	inspect := func() error {
		return pgControlSnapshotMode(f.ctx, f.request, pgx.ReadOnly, func(tx pgx.Tx) error {
			for _, fn := range pgQueueOperationFunctions(f.namespace) {
				if err := pgControlFunctionCatalog(f.ctx, tx, f.namespace, f.roles, fn); err != nil {
					return err
				}
			}
			return nil
		})
	}
	if err := inspect(); err != nil {
		t.Fatal(err)
	}
	if _, err := f.installer.Exec(f.ctx, "alter function notes_app.tesl_queue_claim(integer,text,text,text,bigint) stable"); err != nil {
		t.Fatal(err)
	}
	if err := inspect(); err == nil {
		t.Fatal("changed claim volatility accepted")
	}
	if _, err := f.installer.Exec(f.ctx, "alter function notes_app.tesl_queue_claim(integer,text,text,text,bigint) volatile; grant execute on function notes_app.tesl_queue_enqueue(integer,text,text,text,jsonb) to public"); err != nil {
		t.Fatal(err)
	}
	if err := inspect(); err == nil {
		t.Fatal("public queue write grant accepted")
	}
}
func TestQueueOperationsConcurrentClaimantsDoNotDuplicateJobs(t *testing.T) {
	f := pgNewQueueOperationsTest(t, 1)
	const total = 48
	for i := range total {
		f.enqueue(t, f.request, 1, fmt.Sprint("job-", i))
	}
	type result struct {
		ids []string
		err error
	}
	done := make(chan result, 2)
	for _, conn := range []*pgx.Conn{f.request, f.worker} {
		go func(conn *pgx.Conn) {
			got := result{}
			for {
				c, err := f.claim(conn, 1, "pending", 60000)
				if errors.Is(err, pgx.ErrNoRows) {
					done <- got
					return
				}
				if err != nil {
					got.err = err
					done <- got
					return
				}
				var completed bool
				err = conn.QueryRow(f.ctx, "select notes_app.tesl_queue_complete(1,'Notifications',$1,$2,$3)", c.ID, c.Token, c.Sequence).Scan(&completed)
				if err != nil || !completed {
					got.err = fmt.Errorf("completion %v: %w", completed, err)
					done <- got
					return
				}
				got.ids = append(got.ids, c.ID)
			}
		}(conn)
	}
	seen := map[string]bool{}
	for range 2 {
		result := <-done
		if result.err != nil {
			t.Fatal(result.err)
		}
		for _, id := range result.ids {
			if seen[id] {
				t.Fatalf("duplicate handler claim %s", id)
			}
			seen[id] = true
		}
	}
	if len(seen) != total || f.snapshot(t) != "[]" {
		t.Fatalf("lost jobs: %d/%d", len(seen), total)
	}
}
func TestQueueOperationsBackendLossRollsBackClaimAndBusinessEffect(t *testing.T) {
	f := pgNewQueueOperationsTest(t, 1)
	f.enqueue(t, f.request, 1, "recover")
	tx, err := f.request.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(f.ctx) }()
	c := f.mustClaim(t, tx, 1, "pending")
	if _, err = tx.Exec(f.ctx, "insert into notes_app.notes(id,active) values('uncommitted-effect',true)"); err != nil {
		t.Fatal(err)
	}
	f.complete(t, tx, 1, c, true)
	var killed bool
	if err = f.installer.QueryRow(f.ctx, "select pg_terminate_backend($1)", f.request.PgConn().PID()).Scan(&killed); err != nil || !killed {
		t.Fatalf("terminate request: %v %v", killed, err)
	}
	// The replacement request claims with a fresh token even if rollback reused
	// the transactional sequence value. Its acknowledgement commits independently.
	replacement, err := pgx.ConnectConfig(f.ctx, f.request.Config().Copy())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = replacement.Close(f.ctx) }()
	recovered := f.mustClaim(t, replacement, 1, "pending")
	if recovered.ID != c.ID || recovered.Token == c.Token {
		t.Fatal(recovered)
	}
	f.complete(t, replacement, 1, c, false)
	f.complete(t, replacement, 1, recovered, true)
	var effects int
	if err = f.installer.QueryRow(f.ctx, "select count(*) from notes_app.notes where id='uncommitted-effect'").Scan(&effects); err != nil || effects != 0 {
		t.Fatalf("business effect survived lost transaction: %d %v", effects, err)
	}
}

func TestQueueOperationsRejectTransactionSnapshotsThatCannotRefresh(t *testing.T) {
	f := pgNewQueueOperationsTest(t, 1)
	f.enqueue(t, f.request, 1, "retained")
	before := f.snapshot(t)
	for _, isolation := range []pgx.TxIsoLevel{pgx.RepeatableRead, pgx.Serializable} {
		t.Run(string(isolation), func(t *testing.T) {
			tx, err := f.request.BeginTx(f.ctx, pgx.TxOptions{IsoLevel: isolation})
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = tx.Rollback(f.ctx) }()
			if _, err = f.claim(tx, 1, "pending", 60000); err == nil || !strings.Contains(err.Error(), "read committed") {
				t.Fatalf("unrefreshable snapshot accepted: %v", err)
			}
			if err = tx.Rollback(f.ctx); err != nil {
				t.Fatal(err)
			}
			if before != f.snapshot(t) {
				t.Fatal("isolation refusal changed retained job")
			}
		})
	}
}
