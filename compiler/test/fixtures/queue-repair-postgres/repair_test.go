package teslqueueconversions

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	rt "tesl.generated/teslmodschemamailmigraterepair2/internal/teslrt"
)

const finalRepairDigest = "@@DIGEST@@"

func TestPostgresTypedQueueRepair(t *testing.T) {
	f := rt.OpenQueueConversionDBForTest(t, finalRepairDigest)
	due := time.Date(2099, 1, 2, 3, 4, 5, 0, time.UTC)
	for _, job := range []struct{ id, body, status string }{
		{"accepted", `{"oldText":"kept"}`, "pending"},
		{"repair", `{"oldText":""}`, "pending"},
		{"dead", `{"oldText":""}`, "dead"},
	} {
		if err := f.Enqueue(job.id, job.body, job.status, due); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := f.Installer.Exec(f.Context, "update mail.tesl_jobs set attempts=7 where id='dead'"); err != nil {
		t.Fatal(err)
	}
	for _, conn := range []*pgx.Conn{f.Request, f.Worker} {
		if _, err := conn.Exec(f.Context, "update mail.tesl_jobs set schema_version=2"); err == nil {
			t.Fatal("restricted role directly mutated jobs")
		}
		if _, err := conn.Exec(f.Context, "delete from mail.tesl_queue_conversion_receipts"); err == nil {
			t.Fatal("restricted role rewrote repair history")
		}
	}
	if _, err := f.Apply(f.Request, Conversion0, "accepted"); err == nil {
		t.Fatal("request role executed conversion")
	}
	if err := f.WrongDatabase(Conversion0, "accepted"); err == nil {
		t.Fatal("foreign database identity executed")
	}
	result, err := f.Apply(f.Worker, Conversion0, "accepted")
	if err != nil || result.Kind != "converted" {
		t.Fatal(result, err)
	}
	for _, id := range []string{"repair", "dead"} {
		result, err = f.Apply(f.Worker, Conversion0, id)
		if err != nil || result.Kind != "migration-rejected" {
			t.Fatal(result, err)
		}
		var version int
		var payload, status, reason string
		if err := f.Installer.QueryRow(f.Context, "select schema_version,payload::text,status,dead_reason from mail.tesl_jobs where id=$1", id).Scan(&version, &payload, &status, &reason); err != nil {
			t.Fatal(err)
		}
		if version != 1 || payload != `{"oldText": ""}` || status != "quarantined" || reason != "migration-rejected" {
			t.Fatal("rejection lost original", version, payload, status, reason)
		}
		before := f.Snapshot(t, id)
		if _, err := f.Apply(f.Worker, Conversion2, id); err == nil {
			t.Fatal("repair skipped predecessor")
		}
		if after := f.Snapshot(t, id); after != before {
			t.Fatal("failed repair mutated job or progress")
		}
		if done, err := f.Retire(f.Worker); err != nil || done {
			t.Fatal("rejected job did not block retirement", done, err)
		}
		result, err = f.Apply(f.Worker, Conversion1, id)
		if err != nil || result.Kind != "migration-rejected" {
			t.Fatal(result, err)
		}
		if done, err := f.Retire(f.Worker); err != nil || done {
			t.Fatal("rejected repair did not block retirement", done, err)
		}
		result, err = f.Apply(f.Worker, Conversion2, id)
		if err != nil || result.Kind != "converted" {
			t.Fatal(result, err)
		}
	}
	for _, id := range []string{"accepted", "repair", "dead"} {
		var version, attempts int
		var payload, status string
		var scheduled time.Time
		if err := f.Installer.QueryRow(f.Context, "select schema_version,payload::text,status,attempts,next_attempt_at from mail.tesl_jobs where id=$1", id).Scan(&version, &payload, &status, &attempts, &scheduled); err != nil {
			t.Fatal(err)
		}
		wanted := `{"message": "repaired", "priority": 9}`
		if id == "accepted" {
			wanted = `{"message": "kept", "priority": 7}`
		}
		wantedStatus, wantedAttempts := "pending", 0
		if id == "dead" {
			wantedStatus, wantedAttempts = "dead", 7
		}
		if version != 2 || payload != wanted || status != wantedStatus || attempts != wantedAttempts || !scheduled.Equal(due) {
			t.Fatal("conversion lost job state", id, version, payload, status, attempts, scheduled)
		}
	}
	f.RestartWorker(t)
	before := f.Snapshot(t, "repair")
	result, err = f.Apply(f.Worker, Conversion2, "repair")
	if err != nil || !result.Replayed || result.Kind != "converted" {
		t.Fatal("restart did not replay durable receipt", result, err)
	}
	if before != f.Snapshot(t, "repair") {
		t.Fatal("replay converted the job twice")
	}
	if done, err := f.Retire(f.Worker); err != nil || !done {
		t.Fatal("finished conversions could not retire", done, err)
	}
	if err := f.Enqueue("late", `{"oldText":"late"}`, "pending", due); err == nil {
		t.Fatal("retired writer enqueued an old payload")
	}
}

func TestPostgresRepairTransactionsAndOwnership(t *testing.T) {
	f := rt.OpenQueueConversionDBForTest(t, finalRepairDigest)
	if err := f.Enqueue("job", `{"oldText":""}`, "pending", time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	if _, err := f.Apply(f.Worker, Conversion0, "job"); err != nil {
		t.Fatal(err)
	}
	if _, err := f.Apply(f.Worker, Conversion1, "job"); err != nil {
		t.Fatal(err)
	}
	before := f.Snapshot(t, "job")
	tx, err := f.Worker.Begin(f.Context)
	if err != nil {
		t.Fatal(err)
	}
	result, err := f.ApplyTx(tx, Conversion2, "job")
	if err != nil || result.Kind != "converted" {
		t.Fatal(result, err)
	}
	other, err := f.Apply(f.Other, Conversion2, "job")
	if err != nil || other.Kind != "unavailable" {
		t.Fatal("competing worker acquired locked repair", other, err)
	}
	if err := tx.Rollback(f.Context); err != nil {
		t.Fatal(err)
	}
	if before != f.Snapshot(t, "job") {
		t.Fatal("rollback changed payload, version, attempt or receipt")
	}
	// A backend death after publication SQL but before COMMIT must have the same
	// rollback semantics as an explicit rollback, with no usable durable receipt.
	tx, err = f.Worker.Begin(f.Context)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.ApplyTx(tx, Conversion2, "job"); err != nil {
		t.Fatal(err)
	}
	var killed bool
	if err := f.Installer.QueryRow(f.Context, "select pg_catalog.pg_terminate_backend($1)", f.Worker.PgConn().PID()).Scan(&killed); err != nil || !killed {
		t.Fatal(killed, err)
	}
	if err := tx.Commit(f.Context); err == nil {
		t.Fatal("terminated backend committed")
	}
	f.RestartWorker(t)
	if before != f.Snapshot(t, "job") {
		t.Fatal("backend death left partial repair state")
	}
	f.StaleAttempt(t, Conversion2, "job")
	committed := f.Snapshot(t, "job")
	f.RestartWorker(t)
	result, err = f.Apply(f.Worker, Conversion2, "job")
	if err != nil || !result.Replayed {
		t.Fatal(result, err)
	}
	if committed != f.Snapshot(t, "job") {
		t.Fatal("post-commit retry changed the receipt")
	}
	// The exclusive retirement transaction fences an old enqueue until its new
	// floor commits; the waiting READ COMMITTED operation must reread that floor.
	retire, err := f.Worker.Begin(f.Context)
	if err != nil {
		t.Fatal(err)
	}
	if done, err := f.RetireTx(retire); err != nil || !done {
		t.Fatal(done, err)
	}
	late := make(chan error, 1)
	go func() { late <- f.Enqueue("late", `{"oldText":"late"}`, "pending", time.Now().UTC()) }()
	deadline := time.Now().Add(5 * time.Second)
	for {
		var blocked bool
		if err := f.Installer.QueryRow(f.Context, "select $1::integer=any(pg_catalog.pg_blocking_pids($2))", f.Worker.PgConn().PID(), f.Request.PgConn().PID()).Scan(&blocked); err != nil {
			t.Fatal(err)
		}
		if blocked {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("old enqueue did not wait for retirement")
		}
		time.Sleep(5 * time.Millisecond)
	}
	if err := retire.Commit(f.Context); err != nil {
		t.Fatal(err)
	}
	if err := <-late; err == nil {
		t.Fatal("waiting old enqueue used a pre-fence floor")
	}
}

func TestPostgresRepairRegistrationAfterRejection(t *testing.T) {
	f := rt.OpenQueueConversionRootForTest(t, Conversion0)
	if err := f.Enqueue("job", `{"oldText":""}`, "pending", time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	if result, err := f.Apply(f.Worker, Conversion0, "job"); err != nil || result.Kind != "migration-rejected" {
		t.Fatal(result, err)
	}
	before := f.Snapshot(t, "job")
	if _, err := f.Apply(f.Worker, Conversion1, "job"); err == nil {
		t.Fatal("uninstalled repair executed")
	}
	if err := f.Register(f.Worker, Conversion1); err == nil {
		t.Fatal("worker acquired installer authority")
	}
	if before != f.Snapshot(t, "job") {
		t.Fatal("refusal changed quarantine")
	}
	// Force failure on the second inserted repair to prove that registration
	// does not publish the valid first revision of an unsuccessful batch.
	if _, err := f.Installer.Exec(f.Context, "alter table mail.tesl_queue_conversion_sources add constraint fail_second check(revision<2)"); err != nil {
		t.Fatal(err)
	}
	if err := f.Register(f.Installer, Conversion2); err == nil {
		t.Fatal("registration ignored database failure")
	}
	var count int
	if err := f.Installer.QueryRow(f.Context, "select count(*) from mail.tesl_queue_conversion_sources").Scan(&count); err != nil || count != 1 {
		t.Fatal("partial repair registration survived", count, err)
	}
	if _, err := f.Installer.Exec(f.Context, "alter table mail.tesl_queue_conversion_sources drop constraint fail_second"); err != nil {
		t.Fatal(err)
	}
	if err := f.Register(f.Installer, Conversion1); err != nil {
		t.Fatal(err)
	}
	if result, err := f.Apply(f.Worker, Conversion1, "job"); err != nil || result.Kind != "migration-rejected" {
		t.Fatal(result, err)
	}
	before = f.Snapshot(t, "job")
	if err := f.Register(f.Installer, Conversion1); err != nil {
		t.Fatal("exact registration replay failed", err)
	}
	if before != f.Snapshot(t, "job") {
		t.Fatal("registration replay rewrote repair progress")
	}
	if done, err := f.Retire(f.Worker); err != nil || done {
		t.Fatal("rejected repair stopped blocking retirement", done, err)
	}
	if err := f.Register(f.Installer, Conversion2); err != nil {
		t.Fatal(err)
	}
	if result, err := f.Apply(f.Worker, Conversion2, "job"); err != nil || result.Kind != "converted" {
		t.Fatal(result, err)
	}
	var originals, receipts int
	if err := f.Installer.QueryRow(f.Context, "select count(distinct original),count(*) from mail.tesl_queue_conversion_receipts where job_id='job'").Scan(&originals, &receipts); err != nil || originals != 1 || receipts != 3 {
		t.Fatal("repair lineage lost original bytes or progress", originals, receipts, err)
	}
}

func TestPostgresRepairRefusesDifferentBindings(t *testing.T) {
	f := rt.OpenQueueConversionDBForTest(t, finalRepairDigest)
	otherDB := rt.OpenQueueConversionDBForTest(t, finalRepairDigest)
	for _, db := range []*rt.QueueConversionDBFixture{f, otherDB} {
		if err := db.Enqueue("job", `{"oldText":""}`, "pending", time.Now().UTC()); err != nil {
			t.Fatal(err)
		}
	}
	before, otherBefore := f.Snapshot(t, "job"), otherDB.Snapshot(t, "job")
	if _, err := f.Apply(otherDB.Worker, Conversion0, "job"); err == nil {
		t.Fatal("binding replayed against another database")
	}
	if _, _, err := f.QueueClaim(otherDB.Request, 1, "pending", 60000); err == nil {
		t.Fatal("queue context replayed against another database")
	}
	if before != f.Snapshot(t, "job") || otherBefore != otherDB.Snapshot(t, "job") {
		t.Fatal("cross-database refusal changed jobs")
	}
	for _, test := range []struct{ name, mutate, restore string }{
		{"family", `update mail.tesl_queue_conversion_scope set family='Schema.Foreign'`, `update mail.tesl_queue_conversion_scope set family='Schema.Mail'`},
		{"queue", `update mail.tesl_queue_conversion_scope set queue='Other'`, `update mail.tesl_queue_conversion_scope set queue='Jobs'`},
		{"job", `update mail.tesl_queue_conversion_scope set job_type='Other'`, `update mail.tesl_queue_conversion_scope set job_type='Delivery'`},
		{"versions", `update mail.tesl_queue_conversion_scope set from_version=2,to_version=3,floor=2`, `update mail.tesl_queue_conversion_scope set from_version=1,to_version=2,floor=1`},
	} {
		t.Run(test.name, func(t *testing.T) {
			if _, err := f.Installer.Exec(f.Context, test.mutate); err != nil {
				t.Fatal(err)
			}
			defer func() {
				if _, err := f.Installer.Exec(f.Context, test.restore); err != nil {
					t.Fatal(err)
				}
			}()
			if _, err := f.Apply(f.Worker, Conversion0, "job"); err == nil {
				t.Fatal("different installed binding executed")
			}
			if _, _, err := f.QueueClaim(f.Request, 1, "pending", 60000); err == nil {
				t.Fatal("queue claim ignored changed binding")
			}
			if err := f.Register(f.Installer, Conversion2); err == nil {
				t.Fatal("different installed binding registered")
			}
			if before != f.Snapshot(t, "job") {
				t.Fatal("binding refusal changed job")
			}
		})
	}
	var contract []byte
	if err := f.Installer.QueryRow(f.Context, "select contract from mail.tesl_queue_payloads where version=1").Scan(&contract); err != nil {
		t.Fatal(err)
	}
	if _, err := f.Installer.Exec(f.Context, "update mail.tesl_queue_payloads set contract=$1,contract_hash=pg_catalog.encode(pg_catalog.sha256($1),'hex') where version=1", []byte("rehashed foreign contract")); err != nil {
		t.Fatal(err)
	}
	if _, err := f.Apply(f.Worker, Conversion0, "job"); err == nil {
		t.Fatal("rehashed foreign payload contract executed")
	}
	if _, _, err := f.QueueClaim(f.Request, 1, "pending", 60000); err == nil {
		t.Fatal("queue claim ignored rehashed payload contract")
	}
	if err := f.Register(f.Installer, Conversion2); err == nil {
		t.Fatal("rehashed foreign payload contract registered")
	}
	if _, err := f.Installer.Exec(f.Context, "update mail.tesl_queue_payloads set contract=$1,contract_hash=pg_catalog.encode(pg_catalog.sha256($1),'hex') where version=1", contract); err != nil {
		t.Fatal(err)
	}
	if before != f.Snapshot(t, "job") {
		t.Fatal("contract refusal changed job")
	}
	tx, err := f.Worker.BeginTx(f.Context, pgx.TxOptions{IsoLevel: pgx.RepeatableRead})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.ApplyTx(tx, Conversion0, "job"); err == nil {
		t.Fatal("stale snapshot isolation accepted")
	}
	_ = tx.Rollback(f.Context)
	if before != f.Snapshot(t, "job") {
		t.Fatal("isolation refusal changed job")
	}
}

func TestPostgresMalformedPayloadCannotBecomeTypedRepair(t *testing.T) {
	f := rt.OpenQueueConversionDBForTest(t, finalRepairDigest)
	if err := f.Enqueue("invalid", `{"oldText":false}`, "pending", time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	result, err := f.Apply(f.Worker, Conversion0, "invalid")
	if err != nil || result.Kind != "payload-invalid" {
		t.Fatal(result, err)
	}
	var version int
	var reason, payload string
	if err := f.Installer.QueryRow(f.Context, "select schema_version,dead_reason,payload::text from mail.tesl_jobs where id='invalid'").Scan(&version, &reason, &payload); err != nil {
		t.Fatal(err)
	}
	if version != 1 || reason != "payload-invalid" || payload != `{"oldText": false}` {
		t.Fatal("invalid source was relabelled", version, reason, payload)
	}
	before := f.Snapshot(t, "invalid")
	if _, err := f.Apply(f.Worker, Conversion1, "invalid"); err == nil {
		t.Fatal("malformed bytes acquired typed repair authority")
	}
	if before != f.Snapshot(t, "invalid") {
		t.Fatal("failed typed repair modified malformed bytes")
	}
	if done, err := f.Retire(f.Worker); err != nil || done {
		t.Fatal("malformed quarantined job failed to block retirement", done, err)
	}
	result, err = f.Apply(f.Worker, Conversion0, "invalid")
	if err != nil || !result.Replayed || result.Kind != "payload-invalid" {
		t.Fatal(result, err)
	}
	if before != f.Snapshot(t, "invalid") {
		t.Fatal("invalid-source receipt replay mutated quarantine")
	}
}

func TestPostgresActiveClaimsAreNotRewritten(t *testing.T) {
	f := rt.OpenQueueConversionDBForTest(t, finalRepairDigest)
	for _, status := range []string{"pending", "dead"} {
		if err := f.Enqueue(status, `{"oldText":"kept"}`, status, time.Now().UTC()); err != nil {
			t.Fatal(err)
		}
		processing := "processing"
		if status == "dead" {
			processing = "dead_processing"
		}
		_, err := f.Installer.Exec(f.Context, `update mail.tesl_jobs set status=$2,locked_at=pg_catalog.clock_timestamp(),locked_by='old-worker',
 claim_token='old:1',claim_seq=1,claimed_by_version=1,claim_xid=pg_catalog.pg_current_xact_id(),
 lease_until=pg_catalog.clock_timestamp()+interval '1 hour' where id=$1`, status, processing)
		if err != nil {
			t.Fatal(err)
		}
		before := f.Snapshot(t, status)
		if _, err := f.Apply(f.Worker, Conversion0, status); err == nil || !strings.Contains(err.Error(), "unclaimed source job") {
			t.Fatal("active queue claimant was rewritten", err)
		}
		if before != f.Snapshot(t, status) {
			t.Fatal("conversion changed a live queue attempt")
		}
	}
	if done, err := f.Retire(f.Worker); err != nil || done {
		t.Fatal("live old claims did not block candidate retirement", done, err)
	}
}

func TestPostgresRepairedJobRunsThroughQueueLifecycle(t *testing.T) {
	f := rt.OpenQueueConversionDBForTest(t, finalRepairDigest)
	if err := f.Enqueue("job", `{"oldText":""}`, "pending", time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	if _, ok, err := f.QueueClaim(f.Request, 2, "pending", 60000); err != nil || ok {
		t.Fatal("new worker claimed incompatible old payload", ok, err)
	}
	old, ok, err := f.QueueClaim(f.Request, 1, "pending", 60000)
	if err != nil || !ok || old.Version != 1 {
		t.Fatal(old, ok, err)
	}
	if _, err := f.Request.Exec(f.Context, "select mail.tesl_queue_admit(1,'Jobs')"); err == nil {
		t.Fatal("queue context leaked past transaction commit")
	}
	if failed, err := f.QueueBoolean(f.Request, 1, "fail", old.ID, old.Token, old.Sequence, 2, int64(0)); err != nil || !failed {
		t.Fatal(failed, err)
	}
	for _, conversion := range []func() error{
		func() error { _, err := f.Apply(f.Worker, Conversion0, "job"); return err },
		func() error { _, err := f.Apply(f.Worker, Conversion1, "job"); return err },
		func() error { _, err := f.Apply(f.Worker, Conversion2, "job"); return err },
	} {
		if err := conversion(); err != nil {
			t.Fatal(err)
		}
	}
	if _, ok, err := f.QueueClaim(f.Request, 1, "pending", 60000); err != nil || ok {
		t.Fatal("old worker claimed repaired payload", ok, err)
	}
	current, ok, err := f.QueueClaim(f.Request, 2, "pending", 60000)
	if err != nil || !ok || current.Version != 2 || current.Attempts != 1 {
		t.Fatal(current, ok, err)
	}
	raw, err := rt.ParseJSON([]byte(current.Payload))
	if err != nil {
		t.Fatal(err)
	}
	job, valid := decodeNew0(raw).Value()
	if !valid || job.Body != "repaired" || job.Priority.String() != "9" {
		t.Fatal("current handler received wrong typed payload", job, valid)
	}
	if done, err := f.QueueBoolean(f.Request, 1, "complete", old.ID, old.Token, old.Sequence); err != nil || done {
		t.Fatal("old attempt completed current work", done, err)
	}
	if done, err := f.Retire(f.Worker); err != nil || !done {
		t.Fatal("surviving claimant blocked retirement", done, err)
	}
	if renewed, err := f.QueueBoolean(f.Request, 2, "renew", current.ID, current.Token, current.Sequence, int64(60000)); err != nil || !renewed {
		t.Fatal(renewed, err)
	}
	if done, err := f.QueueBoolean(f.Request, 2, "complete", current.ID, current.Token, current.Sequence); err != nil || !done {
		t.Fatal(done, err)
	}
	var jobs, receipts int
	if err := f.Installer.QueryRow(f.Context, "select (select count(*) from mail.tesl_jobs),(select count(*) from mail.tesl_queue_conversion_receipts)").Scan(&jobs, &receipts); err != nil || jobs != 0 || receipts != 3 {
		t.Fatal("completion lost repair history", jobs, receipts, err)
	}
	f.RestartWorker(t)
	result, err := f.Apply(f.Worker, Conversion2, "job")
	if err != nil || !result.Replayed || result.Kind != "converted" {
		t.Fatal("completion erased durable repair outcome", result, err)
	}
}

func TestPostgresAbandonedConversionDoesNotBlockQueueCompletion(t *testing.T) {
	f := rt.OpenQueueConversionDBForTest(t, finalRepairDigest)
	if err := f.Enqueue("job", `{"oldText":"kept"}`, "pending", time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	f.AbandonConversion(t, Conversion0, "job")
	claim, ok, err := f.QueueClaim(f.Request, 1, "pending", 60000)
	if err != nil || !ok {
		t.Fatal(claim, ok, err)
	}
	if done, err := f.QueueBoolean(f.Request, 1, "complete", claim.ID, claim.Token, claim.Sequence); err != nil || !done {
		t.Fatal("abandoned conversion blocked ordinary completion", done, err)
	}
	var attempts int
	if err := f.Installer.QueryRow(f.Context, "select count(*) from mail.tesl_queue_conversion_attempts").Scan(&attempts); err != nil || attempts != 0 {
		t.Fatal("orphan conversion attempt", attempts, err)
	}
}

func TestPostgresExpiredQueueClaimCanBeConverted(t *testing.T) {
	for _, status := range []string{"pending", "dead"} {
		t.Run(status, func(t *testing.T) {
			f := rt.OpenQueueConversionDBForTest(t, finalRepairDigest)
			if err := f.Enqueue("job", `{"oldText":"kept"}`, status, time.Now().UTC()); err != nil {
				t.Fatal(err)
			}
			claim, ok, err := f.QueueClaim(f.Request, 1, status, 40)
			if err != nil || !ok {
				t.Fatal(claim, ok, err)
			}
			deadline := time.Now().Add(5 * time.Second)
			for {
				var expired bool
				if err := f.Installer.QueryRow(f.Context, "select lease_until<=pg_catalog.clock_timestamp() from mail.tesl_jobs where id='job'").Scan(&expired); err != nil {
					t.Fatal(err)
				}
				if expired {
					break
				}
				if time.Now().After(deadline) {
					t.Fatal("claim did not expire")
				}
				time.Sleep(5 * time.Millisecond)
			}
			before := f.Snapshot(t, "job")
			tx, err := f.Worker.Begin(f.Context)
			if err != nil {
				t.Fatal(err)
			}
			if result, err := f.ApplyTx(tx, Conversion0, "job"); err != nil || result.Kind != "converted" {
				t.Fatal("expired claim prevented conversion", result, err)
			}
			if err := tx.Rollback(f.Context); err != nil {
				t.Fatal(err)
			}
			if before != f.Snapshot(t, "job") {
				t.Fatal("rollback did not restore expired claimant")
			}
			if progress, err := f.Batch(f.Context, f.Worker, Conversion0, 256); err != nil || progress.Converted != 1 || !progress.NoEligible {
				t.Fatal("batch did not discover the expired claim", progress, err)
			}
			for _, operation := range []string{"complete", "renew"} {
				args := []any{claim.ID, claim.Token, claim.Sequence}
				if operation == "renew" {
					args = append(args, int64(60000))
				}
				if changed, err := f.QueueBoolean(f.Request, 1, operation, args...); err != nil || changed {
					t.Fatal("expired old claimant changed converted job", operation, changed, err)
				}
			}
			current, ok, err := f.QueueClaim(f.Request, 2, status, 60000)
			if err != nil || !ok || current.Sequence <= claim.Sequence {
				t.Fatal(current, ok, err)
			}
			if done, err := f.QueueBoolean(f.Request, 2, "complete", current.ID, current.Token, current.Sequence); err != nil || !done {
				t.Fatal(done, err)
			}
		})
	}
}

func TestPostgresClaimTransactionKeepsCompletionRight(t *testing.T) {
	f := rt.OpenQueueConversionDBForTest(t, finalRepairDigest)
	if err := f.Enqueue("job", `{"oldText":"kept"}`, "pending", time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	f.ClaimTransactionOutlivesLease(t, Conversion0, "job")
	var jobs, receipts int
	if err := f.Installer.QueryRow(f.Context, "select (select count(*) from mail.tesl_jobs),(select count(*) from mail.tesl_queue_conversion_receipts)").Scan(&jobs, &receipts); err != nil || jobs != 0 || receipts != 0 {
		t.Fatal("conversion interfered with active handler transaction", jobs, receipts, err)
	}
}

func TestPostgresAutomaticConversionAndRepairBatches(t *testing.T) {
	f := rt.OpenQueueConversionDBForTest(t, finalRepairDigest)
	due := time.Date(2099, 1, 2, 3, 4, 5, 0, time.UTC)
	for _, job := range []struct{ id, body, status string }{
		{"accepted", `{"oldText":"kept"}`, "pending"},
		{"rejected", `{"oldText":""}`, "pending"},
		{"dead", `{"oldText":""}`, "dead"},
		{"invalid", `{"oldText":false}`, "pending"},
	} {
		if err := f.Enqueue(job.id, job.body, job.status, due); err != nil {
			t.Fatal(err)
		}
	}
	p, err := f.Batch(f.Context, f.Worker, Conversion0, 2)
	if err != nil || p.Selected != 2 || p.Converted != 1 || p.Rejected != 1 || p.NoEligible {
		t.Fatal("bounded first turn", p, err)
	}
	f.RestartWorker(t)
	p, err = f.Batch(f.Context, f.Worker, Conversion0, 256)
	if err != nil || p.Selected != 2 || p.Rejected != 1 || p.Invalid != 1 || !p.NoEligible {
		t.Fatal("restart did not resume from receipts", p, err)
	}
	p, err = f.Batch(f.Context, f.Worker, Conversion0, 256)
	if err != nil || p.Selected != 0 || !p.NoEligible {
		t.Fatal("rejected jobs caused a conversion hot loop", p, err)
	}
	p, err = f.Batch(f.Context, f.Worker, Conversion1, 256)
	if err != nil || p.Selected != 2 || p.Rejected != 2 || !p.NoEligible {
		t.Fatal("repair did not discover exact rejections", p, err)
	}
	p, err = f.Batch(f.Context, f.Worker, Conversion1, 256)
	if err != nil || p.Selected != 0 || !p.NoEligible {
		t.Fatal("repair repeated its own rejection", p, err)
	}
	p, err = f.Batch(f.Context, f.Worker, Conversion2, 256)
	if err != nil || p.Selected != 2 || p.Converted != 2 || !p.NoEligible {
		t.Fatal("later repair did not discover work", p, err)
	}
	for _, id := range []string{"accepted", "rejected", "dead"} {
		var body, status string
		var version int
		var scheduled time.Time
		if err := f.Installer.QueryRow(f.Context, "select payload::text,schema_version,status,next_attempt_at from mail.tesl_jobs where id=$1", id).Scan(&body, &version, &status, &scheduled); err != nil {
			t.Fatal(err)
		}
		raw, err := rt.ParseJSON([]byte(body))
		if err != nil {
			t.Fatal(err)
		}
		value, ok := decodeNew0(raw).Value()
		if !ok || version != 2 || !scheduled.Equal(due) {
			t.Fatal("batch lost typed payload or schedule", id, value, version, scheduled)
		}
		if (id == "dead") != (status == "dead") {
			t.Fatal("batch changed dead-job disposition", id, status)
		}
	}
	if _, ok, err := f.QueueClaim(f.Request, 2, "pending", 60000); err != nil || ok {
		t.Fatal("conversion made delayed work runnable early", ok, err)
	}
	if done, err := f.Retire(f.Worker); err != nil || done {
		t.Fatal("NoEligible was treated as finality despite malformed quarantine", done, err)
	}
}

func TestPostgresBatchSelectionAndCompetingWorkers(t *testing.T) {
	f := rt.OpenQueueConversionDBForTest(t, finalRepairDigest)
	for _, id := range []string{"first", "second", "third"} {
		if err := f.Enqueue(id, `{"oldText":"kept"}`, "pending", time.Now().UTC()); err != nil {
			t.Fatal(err)
		}
	}
	tx, err := f.Worker.Begin(f.Context)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(context.Background())
	id, _, err := f.SelectWork(tx, Conversion0, 0)
	if err != nil || id != "first" {
		t.Fatal(id, err)
	}
	p, err := f.Batch(f.Context, f.Other, Conversion0, 256)
	if err != nil || p.Converted != 2 || !p.NoEligible {
		t.Fatal("competing batch did not skip locked work", p, err)
	}
	if err := tx.Rollback(f.Context); err != nil {
		t.Fatal(err)
	}
	p, err = f.Batch(f.Context, f.Worker, Conversion0, 256)
	if err != nil || p.Converted != 1 || !p.NoEligible {
		t.Fatal("within-turn cursor lost earlier locked work", p, err)
	}
	for i := 0; i < 12; i++ {
		if err := f.Enqueue(fmt.Sprintf("race-%02d", i), `{"oldText":"kept"}`, "pending", time.Now().UTC()); err != nil {
			t.Fatal(err)
		}
	}
	type result struct {
		progress rt.QueueConversionBatchForTest
		err      error
	}
	results := make(chan result, 2)
	for _, conn := range []*pgx.Conn{f.Worker, f.Other} {
		go func(conn *pgx.Conn) { p, err := f.Batch(f.Context, conn, Conversion0, 256); results <- result{p, err} }(conn)
	}
	total := 0
	for range 2 {
		r := <-results
		if r.err != nil {
			t.Fatal(r.err)
		}
		total += r.progress.Converted
	}
	if total != 12 {
		t.Fatal("competing workers lost or duplicated conversion", total)
	}
	var receipts int
	if err := f.Installer.QueryRow(f.Context, "select count(*) from mail.tesl_queue_conversion_receipts").Scan(&receipts); err != nil || receipts != 15 {
		t.Fatal(receipts, err)
	}
}

func TestPostgresBatchFailurePreservesCommittedPrefix(t *testing.T) {
	f := rt.OpenQueueConversionDBForTest(t, finalRepairDigest)
	for _, id := range []string{"first", "fault", "last"} {
		if err := f.Enqueue(id, `{"oldText":"kept"}`, "pending", time.Now().UTC()); err != nil {
			t.Fatal(err)
		}
	}
	before := f.Snapshot(t, "fault")
	if _, err := f.Installer.Exec(f.Context, "alter table mail.tesl_queue_conversion_receipts add constraint fail_job check(job_id<>'fault')"); err != nil {
		t.Fatal(err)
	}
	p, err := f.Batch(f.Context, f.Worker, Conversion0, 256)
	if err == nil || p.Selected != 1 || p.Converted != 1 || p.NoEligible {
		t.Fatal("batch did not report its committed prefix", p, err)
	}
	if before != f.Snapshot(t, "fault") {
		t.Fatal("failed job retained a partial attempt or outcome")
	}
	var receipts int
	if err := f.Installer.QueryRow(f.Context, "select count(*) from mail.tesl_queue_conversion_receipts").Scan(&receipts); err != nil || receipts != 1 {
		t.Fatal("earlier committed receipt was lost", receipts, err)
	}
	if _, err := f.Installer.Exec(f.Context, "alter table mail.tesl_queue_conversion_receipts drop constraint fail_job"); err != nil {
		t.Fatal(err)
	}
	f.RestartWorker(t)
	p, err = f.Batch(f.Context, f.Worker, Conversion0, 256)
	if err != nil || p.Converted != 2 || !p.NoEligible {
		t.Fatal("batch restart did not resume failed and later work", p, err)
	}
}

func TestPostgresBatchBoundsCancellationAndLiveClaims(t *testing.T) {
	f := rt.OpenQueueConversionDBForTest(t, finalRepairDigest)
	if err := f.Enqueue("job", `{"oldText":"kept"}`, "pending", time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	before := f.Snapshot(t, "job")
	for _, limit := range []int{-1, 0, 257} {
		if p, err := f.Batch(f.Context, f.Worker, Conversion0, limit); err == nil || p.Selected != 0 {
			t.Fatal("invalid batch bound", p, err)
		}
	}
	ctx, cancel := context.WithCancel(f.Context)
	cancel()
	if p, err := f.Batch(ctx, f.Worker, Conversion0, 256); err == nil || p.Selected != 0 {
		t.Fatal("canceled worker published progress", p, err)
	}
	if p, err := f.Batch(f.Context, f.Request, Conversion0, 256); err == nil || p.Selected != 0 {
		t.Fatal("request role ran migration work", p, err)
	}
	if before != f.Snapshot(t, "job") {
		t.Fatal("invalid or canceled dispatch changed a job")
	}
	claim, ok, err := f.QueueClaim(f.Request, 1, "pending", 60000)
	if err != nil || !ok {
		t.Fatal(claim, ok, err)
	}
	p, err := f.Batch(f.Context, f.Worker, Conversion0, 256)
	if err != nil || p.Selected != 0 || !p.NoEligible {
		t.Fatal("batch stole a live claim", p, err)
	}
	if done, err := f.Retire(f.Worker); err != nil || done {
		t.Fatal("idle batch authorized retirement over a live claimant", done, err)
	}
	if done, err := f.QueueBoolean(f.Request, 1, "fail", claim.ID, claim.Token, claim.Sequence, 2, int64(0)); err != nil || !done {
		t.Fatal(done, err)
	}
	p, err = f.Batch(f.Context, f.Worker, Conversion0, 256)
	if err != nil || p.Converted != 1 || !p.NoEligible {
		t.Fatal("released claim was not discovered", p, err)
	}
}

func TestPostgresWorkerReopensWithoutInstaller(t *testing.T) {
	f := rt.OpenQueueConversionDBForTest(t, finalRepairDigest)
	if err := f.Enqueue("job", `{"oldText":""}`, "pending", time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	if _, err := f.Apply(f.Worker, Conversion0, "job"); err != nil {
		t.Fatal(err)
	}
	if _, err := f.Apply(f.Worker, Conversion1, "job"); err != nil {
		t.Fatal(err)
	}
	before := f.Snapshot(t, "job")
	f.RevokeTemporary(t)
	f.RestartWorker(t)
	f.ForgetScope()
	if err := f.Reopen(f.Request, finalRepairDigest); err == nil {
		t.Fatal("request login opened Worker authority")
	}
	if err := f.Reopen(f.Installer, finalRepairDigest); err == nil {
		t.Fatal("installer impersonated Worker startup")
	}
	if err := f.Reopen(f.Worker, finalRepairDigest); err != nil {
		t.Fatal(err)
	}
	if before != f.Snapshot(t, "job") {
		t.Fatal("opening Worker mutated durable state")
	}
	p, err := f.Batch(f.Context, f.Worker, Conversion2, 256)
	if err != nil || p.Converted != 1 {
		t.Fatal("reopened Worker could not resume repair", p, err)
	}
}

func TestPostgresWorkerReopenRejectsCatalogAndSourceDrift(t *testing.T) {
	for _, kind := range []string{"column", "relation", "function", "function-body", "cascade", "trigger", "sequence", "check", "column-grant", "schema-grant", "payload", "source", "parent", "database", "floor"} {
		t.Run(kind, func(t *testing.T) {
			f := rt.OpenQueueConversionDBForTest(t, finalRepairDigest)
			if err := f.Enqueue("job", `{"oldText":"kept"}`, "pending", time.Now().UTC()); err != nil {
				t.Fatal(err)
			}
			before := f.Snapshot(t, "job")
			f.MutateCatalog(t, kind)
			f.ForgetScope()
			err := f.Reopen(f.Worker, finalRepairDigest)
			if err == nil {
				t.Fatal("altered catalog or source acquired a Worker handle")
			}
			if strings.Contains(err.Error(), "snapshot must not execute") {
				t.Fatal("opener executed unverified snapshot body", err)
			}
			if before != f.Snapshot(t, "job") {
				t.Fatal("failed reopen changed jobs or progress")
			}
		})
	}
}

func TestPostgresWorkerReopensInNewProcess(t *testing.T) {
	f := rt.OpenQueueConversionDBForTest(t, finalRepairDigest)
	if err := f.Enqueue("job", `{"oldText":""}`, "pending", time.Now().UTC()); err != nil {
		t.Fatal(err)
	}
	if _, err := f.Apply(f.Worker, Conversion0, "job"); err != nil {
		t.Fatal(err)
	}
	if _, err := f.Apply(f.Worker, Conversion1, "job"); err != nil {
		t.Fatal(err)
	}
	f.RevokeTemporary(t)
	f.ForgetScope()
	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	command := exec.CommandContext(f.Context, binary, "-test.run=^TestPostgresWorkerProcessChild$", "-test.v")
	for _, value := range os.Environ() {
		if strings.HasPrefix(value, "TESL_MIGRATION_TEST_DSN=") || strings.HasPrefix(value, "TESL_TEST_POSTGRES_SHARED_") || strings.HasPrefix(value, "PG") {
			continue
		}
		command.Env = append(command.Env, value)
	}
	command.Env = append(command.Env, f.WorkerProcessEnvironment()...)
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("fresh worker: %v\n%s", err, output)
	}
	if !strings.Contains(string(output), "--- PASS: TestPostgresWorkerProcessChild") {
		t.Fatalf("child did not run: %s", output)
	}
	var version, receipts int
	if err := f.Installer.QueryRow(f.Context, "select schema_version,(select count(*) from mail.tesl_queue_conversion_receipts) from mail.tesl_jobs where id='job'").Scan(&version, &receipts); err != nil || version != 2 || receipts != 3 {
		t.Fatal("new process did not commit typed repair", version, receipts, err)
	}
}

func TestPostgresWorkerProcessChild(t *testing.T) {
	if os.Getenv("TESL_QUEUE_REPAIR_CHILD") != "1" {
		t.Skip("launched by process restart witness")
	}
	if os.Getenv("TESL_MIGRATION_TEST_DSN") != "" {
		t.Fatal("installer connection leaked into worker process")
	}
	f := rt.ReopenQueueWorkerProcessForTest(t, finalRepairDigest)
	p, err := f.Batch(f.Context, f.Worker, Conversion2, 256)
	if err != nil || p.Converted != 1 || !p.NoEligible {
		t.Fatal(p, err)
	}
}

func TestPostgresApplicationStagesExactQueueRepairHistory(t *testing.T) {
	f := rt.OpenApplicationQueueForTest(t)
	if _, err := f.Request.Exec(f.Context, "select mail.tesl_queue_enqueue(1,'Jobs','Delivery','job',$1::jsonb)", `{"oldText":""}`); err != nil {
		t.Fatal(err)
	}
	var original string
	if err := f.Installer.QueryRow(f.Context, "select pg_catalog.to_jsonb(j)::text from mail.tesl_jobs j where id='job'").Scan(&original); err != nil {
		t.Fatal(err)
	}
	if err := f.StageApplication(f.Worker, finalRepairDigest); err == nil {
		t.Fatal("Worker staged installer-owned application history")
	}
	if err := f.StageApplication(f.Request, finalRepairDigest); err == nil {
		t.Fatal("Request staged application history")
	}
	if _, err := f.Installer.Exec(f.Context, "alter table mail.tesl_row_queue_conversion_staging add constraint fail_later check(revision<2)"); err != nil {
		t.Fatal(err)
	}
	if err := f.StageApplication(f.Installer, finalRepairDigest); err == nil {
		t.Fatal("unexpected catalog accepted")
	}
	if _, err := f.Installer.Exec(f.Context, "alter table mail.tesl_row_queue_conversion_staging drop constraint fail_later"); err != nil {
		t.Fatal(err)
	}
	if err := f.StageApplication(f.Installer, finalRepairDigest); err != nil {
		t.Fatal(err)
	}
	if err := f.StageApplication(f.Installer, finalRepairDigest); err != nil {
		t.Fatal("exact staging replay failed", err)
	}
	if err := f.StageApplicationTarget(f.Worker); err == nil {
		t.Fatal("Worker registered a staged target")
	}
	for _, kind := range []string{"schema", "storage", "namespace", "callback", "missing", "duplicate", "reverse"} {
		if err := f.MutateApplicationTarget(t, kind); err == nil {
			t.Fatal("rehashed foreign target accepted", kind)
		}
	}
	if err := f.StageApplicationTarget(f.Installer); err != nil {
		t.Fatal("checked target did not bind to installed app", err)
	}
	if err := f.StageApplicationTarget(f.Installer); err != nil {
		t.Fatal("target staging replay failed", err)
	}
	var version, physical int
	if err := f.Worker.QueryRow(f.Context, "select current,(select count(*) from mail.tesl_row_physical) from mail.tesl_schema_state where id=1").Scan(&version, &physical); err != nil || version != 1 || physical != 1 {
		t.Fatal("target staging accidentally published an expansion", version, physical, err)
	}
	var count int
	if err := f.Worker.QueryRow(f.Context, `select count(*) from mail.tesl_row_queue_conversion_staging c
 join mail.tesl_schema_meta m on m.database_uuid=c.database_uuid and m.fence_ns=c.fence_ns
 join mail.tesl_row_queue_sources q on q.version=c.from_version and q.inventory_hash=c.inventory_hash and q.expansion_hash=c.expansion_hash
 join mail.tesl_queue_payloads p on p.version=c.from_version and p.queue=c.queue and p.job_type=c.job_type and p.contract=c.old_contract
 where c.from_version=1 and c.to_version=2`).Scan(&count); err != nil || count != 3 {
		t.Fatal("staging lost installed application authority", count, err)
	}
	if _, err := f.Worker.Exec(f.Context, "delete from mail.tesl_row_queue_conversion_staging"); err == nil {
		t.Fatal("Worker rewrote staged history")
	}
	var current string
	if err := f.Installer.QueryRow(f.Context, "select pg_catalog.to_jsonb(j)::text from mail.tesl_jobs j where id='job'").Scan(&current); err != nil || current != original {
		t.Fatal("staging changed a live V1 job", current, err)
	}
	// Rebinding to another installation identity must not pass as an idempotent
	// replay, even when callback and payload hashes still match.
	if _, err := f.Installer.Exec(f.Context, "update mail.tesl_row_queue_conversion_staging set database_uuid=pg_catalog.gen_random_uuid() where revision=2"); err != nil {
		t.Fatal(err)
	}
	if err := f.StageApplication(f.Installer, finalRepairDigest); err == nil {
		t.Fatal("foreign staged database identity accepted")
	}
	// An old catalog is rejected; this API never silently installs missing tables.
	if _, err := f.Installer.Exec(f.Context, "drop table mail.tesl_row_queue_conversion_staging"); err != nil {
		t.Fatal(err)
	}
	if err := f.StageApplication(f.Installer, finalRepairDigest); err == nil {
		t.Fatal("old database catalog silently adopted")
	}
}

func TestPostgresApplicationPreparesCheckedSuccessorInventory(t *testing.T) {
	f := rt.OpenApplicationQueueForTest(t)
	if err := f.StageApplicationRoot(f.Installer, Conversion0); err != nil {
		t.Fatal(err)
	}
	if err := f.StageApplicationTarget(f.Installer); err != nil {
		t.Fatal(err)
	}
	if _, err := f.Request.Exec(f.Context, "select mail.tesl_queue_enqueue(1,'Jobs','Delivery','job',$1::jsonb)", `{"oldText":""}`); err != nil {
		t.Fatal(err)
	}
	for _, conn := range []*pgx.Conn{f.Installer, f.Request} {
		if err := f.PrepareApplicationTarget(conn, ""); err == nil {
			t.Fatal("non-Worker prepared successor")
		}
	}
	for _, mutation := range []string{"schema", "missing", "unchanged", "additional"} {
		if err := f.PrepareApplicationTarget(f.Worker, mutation); err == nil {
			t.Fatal("different target inventory registered", mutation)
		}
		var versions, physical int
		if err := f.Worker.QueryRow(f.Context, "select (select count(*) from mail.tesl_queue_versions),(select count(*) from mail.tesl_row_physical)").Scan(&versions, &physical); err != nil || versions != 1 || physical != 1 {
			t.Fatal("failed registration left partial successor", versions, physical, err)
		}
	}
	if err := f.PrepareApplicationTarget(f.Worker, ""); err != nil {
		t.Fatal(err)
	}
	if err := f.PrepareApplicationTarget(f.Worker, ""); err != nil {
		t.Fatal("exact successor replay failed", err)
	}
	var current, versions, physical int
	var preserving bool
	if err := f.Worker.QueryRow(f.Context, "select current,(select count(*) from mail.tesl_queue_versions),(select count(*) from mail.tesl_row_physical),(select epoch_preserving from mail.tesl_row_physical where version=2) from mail.tesl_schema_state where id=1").Scan(&current, &versions, &physical, &preserving); err != nil || current != 1 || versions != 2 || physical != 2 || preserving {
		t.Fatal("successor preparation lost its pending narrowing state", current, versions, physical, preserving, err)
	}
	if _, err := f.Request.Exec(f.Context, "select mail.tesl_queue_admit(2,'Jobs')"); err == nil {
		t.Fatal("pending target acquired V2 admission")
	}
	f.ApplicationStatus(t)
	// A V1 transaction retaining a compiled compatibility plan must be drained
	// before the narrowing successor becomes visible to new requests.
	var fence int
	if err := f.Worker.QueryRow(f.Context, "select fence_ns from mail.tesl_schema_meta where id=1").Scan(&fence); err != nil {
		t.Fatal(err)
	}
	reader, err := f.Request.Begin(f.Context)
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Rollback(context.Background())
	if _, err := reader.Exec(f.Context, "select pg_catalog.pg_advisory_xact_lock_shared($1::integer,1)", -fence); err != nil {
		t.Fatal(err)
	}
	published := make(chan error, 1)
	go func() { published <- f.PublishApplicationTarget() }()
	deadline := time.Now().Add(5 * time.Second)
	for {
		var draining bool
		if err := f.Installer.QueryRow(f.Context, "select exists(select 1 from pg_catalog.pg_stat_activity where pid=$1 and query like '%pg_try_advisory_lock%')", f.Worker.PgConn().PID()).Scan(&draining); err != nil {
			t.Fatal(err)
		}
		if draining {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("publication never reached compatibility drain")
		}
		time.Sleep(5 * time.Millisecond)
	}
	select {
	case err := <-published:
		t.Fatal("publication crossed a live compatibility plan", err)
	default:
	}
	if err := f.Installer.QueryRow(f.Context, "select current from mail.tesl_schema_state where id=1").Scan(&current); err != nil || current != 1 {
		t.Fatal("successor published before drain", current, err)
	}
	if err := reader.Rollback(f.Context); err != nil {
		t.Fatal(err)
	}
	if err := <-published; err != nil {
		t.Fatal("successor publication failed", err)
	}
	if err := f.PublishApplicationTarget(); err != nil {
		t.Fatal("successor publication replay failed", err)
	}
	if err := f.StageApplication(f.Installer, finalRepairDigest); err != nil {
		t.Fatal("separate repair deployment could not append after V2 publication", err)
	}
	if err := f.StageApplication(f.Installer, finalRepairDigest); err != nil {
		t.Fatal("published repair staging replay failed", err)
	}
	var floor int
	if err := f.Request.QueryRow(f.Context, "select mail.tesl_queue_admit(2,'Jobs')").Scan(&floor); err != nil || floor != 1 {
		t.Fatal("published successor did not acquire bounded admission", floor, err)
	}
	f.ApplicationStatus(t)
	var body string
	var stamp int
	if err := f.Installer.QueryRow(f.Context, "select payload::text,schema_version from mail.tesl_jobs where id='job'").Scan(&body, &stamp); err != nil || stamp != 1 || body != `{"oldText": ""}` {
		t.Fatal("pending successor mutated old job", body, stamp, err)
	}
}

func TestPostgresApplicationConvertsRepairsAndCompletesStoredJob(t *testing.T) {
	f := rt.OpenApplicationQueueForTest(t)
	if err := f.StageApplicationRoot(f.Installer, Conversion0); err != nil {
		t.Fatal(err)
	}
	if err := f.StageApplicationTarget(f.Installer); err != nil {
		t.Fatal(err)
	}
	if _, err := f.Request.Exec(f.Context, "select mail.tesl_queue_enqueue(1,'Jobs','Delivery','job',$1::jsonb)", `{"oldText":""}`); err != nil {
		t.Fatal(err)
	}
	if err := f.OpenApplicationDispatch(f.Worker, finalRepairDigest); err == nil {
		t.Fatal("unpublished or unstaged repair acquired dispatch authority")
	}
	if err := f.PublishApplicationTarget(); err != nil {
		t.Fatal(err)
	}
	if err := f.OpenApplicationDispatch(f.Request, finalRepairDigest); err == nil {
		t.Fatal("Request acquired migration dispatch authority")
	}
	if err := f.OpenApplicationRoot(f.Worker, Conversion0); err != nil {
		t.Fatal(err)
	}
	if err := f.WrongDatabase(Conversion0, "job"); err == nil {
		t.Fatal("application conversion ignored database identity")
	}
	result, err := f.Apply(f.Worker, Conversion0, "job")
	if err != nil || result.Kind != "migration-rejected" {
		t.Fatal("published application did not reject its stored old payload", result, err)
	}
	var payload, reason string
	var version int
	if err := f.Installer.QueryRow(f.Context, "select payload::text,schema_version,dead_reason from mail.tesl_jobs where id='job'").Scan(&payload, &version, &reason); err != nil || payload != `{"oldText": ""}` || version != 1 || reason != "migration-rejected" {
		t.Fatal("application rejection lost historical bytes", payload, version, reason, err)
	}
	if done, err := f.QueueBoolean(f.Request, 2, "requeue", "job"); err != nil || done {
		t.Fatal("quarantined application job bypassed typed repair", done, err)
	}
	if _, err := f.Request.Exec(f.Context, "select mail.tesl_queue_enqueue(1,'Jobs','Delivery','abandoned',$1::jsonb)", `{"oldText":"kept"}`); err != nil {
		t.Fatal(err)
	}
	f.AbandonConversion(t, Conversion0, "abandoned")
	claim, ok, err := f.QueueClaim(f.Request, 1, "pending", 60000)
	if err != nil || !ok || claim.ID != "abandoned" {
		t.Fatal(claim, ok, err)
	}
	if done, err := f.QueueBoolean(f.Request, 1, "complete", claim.ID, claim.Token, claim.Sequence); err != nil || !done {
		t.Fatal("abandoned application attempt blocked normal completion", done, err)
	}
	if err := f.StageApplication(f.Installer, finalRepairDigest); err != nil {
		t.Fatal(err)
	}
	if err := f.OpenApplicationDispatch(f.Worker, finalRepairDigest); err != nil {
		t.Fatal(err)
	}
	if p, err := f.Batch(f.Context, f.Worker, Conversion1, 256); err != nil || p.Rejected != 1 {
		t.Fatal("application repair could not find its rejection", p, err)
	}
	before := f.Snapshot(t, "job")
	tx, err := f.Worker.Begin(f.Context)
	if err != nil {
		t.Fatal(err)
	}
	if r, err := f.ApplyTx(tx, Conversion2, "job"); err != nil || r.Kind != "converted" {
		t.Fatal(r, err)
	}
	var fence int
	var acquired bool
	if err := f.Installer.QueryRow(f.Context, "select fence_ns from mail.tesl_schema_meta where id=1").Scan(&fence); err != nil {
		t.Fatal(err)
	}
	if err := f.Request.QueryRow(f.Context, "select pg_catalog.pg_try_advisory_xact_lock($1::integer,1)", fence).Scan(&acquired); err != nil || acquired {
		t.Fatal("application repair did not hold the real source retirement fence", acquired, err)
	}
	if err := tx.Rollback(f.Context); err != nil {
		t.Fatal(err)
	}
	if before != f.Snapshot(t, "job") {
		t.Fatal("application repair rollback changed jobs or receipts")
	}
	if p, err := f.Batch(f.Context, f.Worker, Conversion2, 256); err != nil || p.Converted != 1 {
		t.Fatal("application repair did not update real jobs", p, err)
	}
	f.RestartWorker(t)
	if err := f.OpenApplicationDispatch(f.Worker, finalRepairDigest); err != nil {
		t.Fatal(err)
	}
	if r, err := f.Apply(f.Worker, Conversion2, "job"); err != nil || !r.Replayed || r.Kind != "converted" {
		t.Fatal("application repair receipt did not survive reconnect", r, err)
	}
	for _, conn := range []*pgx.Conn{f.Request, f.Worker} {
		if _, err := conn.Exec(f.Context, "select original from mail.tesl_row_queue_conversion_receipts"); err == nil {
			t.Fatal("raw historical payload leaked through control-table grants")
		}
	}
	current, ok, err := f.QueueClaim(f.Request, 2, "pending", 60000)
	if err != nil || !ok || current.Version != 2 {
		t.Fatal("normal queue protocol did not claim repaired application job", current, ok, err)
	}
	raw, err := rt.ParseJSON([]byte(current.Payload))
	if err != nil {
		t.Fatal(err)
	}
	value, valid := decodeNew0(raw).Value()
	if !valid || value.Body != "repaired" || value.Priority.String() != "9" {
		t.Fatal("wrong typed application payload", value, valid)
	}
	if done, err := f.QueueBoolean(f.Request, 2, "complete", current.ID, current.Token, current.Sequence); err != nil || !done {
		t.Fatal(done, err)
	}
	if r, err := f.Apply(f.Worker, Conversion2, "job"); err != nil || !r.Replayed || r.Kind != "converted" {
		t.Fatal("normal application completion erased conversion receipt", r, err)
	}
	if _, err := f.Request.Exec(f.Context, "select mail.tesl_queue_enqueue(2,'Jobs','Delivery','job',$1::jsonb)", `{"message":"reused","priority":9}`); err == nil {
		t.Fatal("completed application job identity reused its historical repair receipt")
	}
	f.ApplicationStatus(t)
}

func TestPostgresApplicationWorkerTurnFindsCompilerBoundCallbacks(t *testing.T) {
	f := rt.OpenApplicationQueueForTest(t)
	if err := f.StageApplicationRoot(f.Installer, Conversion0); err != nil {
		t.Fatal(err)
	}
	if err := f.StageApplicationTarget(f.Installer); err != nil {
		t.Fatal(err)
	}
	if err := f.PublishApplicationTarget(); err != nil {
		t.Fatal(err)
	}
	if _, err := f.Request.Exec(f.Context, "select mail.tesl_queue_enqueue(1,'Jobs','Delivery','turn',$1::jsonb)", `{"oldText":""}`); err != nil {
		t.Fatal(err)
	}
	if p, err := f.ApplicationTurnWithoutCode(Conversion0); err == nil || p.Selected != 0 || !strings.Contains(err.Error(), "not linked as checked executable code") {
		t.Fatal("source metadata became executable authority", p, err)
	}
	if p, err := f.ApplicationTurn(f.Request, 1); err == nil || p.Selected != 0 {
		t.Fatal("Request scheduled migration code", p, err)
	}
	if p, err := f.ApplicationTurn(f.Worker, 1); err != nil || p.Selected != 1 || p.Rejected != 1 {
		t.Fatal("worker did not resolve the staged migration callback", p, err)
	}
	if p, err := f.ApplicationTurn(f.Worker, 256); err != nil || p.Selected != 0 || !p.NoEligible {
		t.Fatal("unrepaired rejection became a hot loop", p, err)
	}
	if err := f.StageApplication(f.Installer, finalRepairDigest); err != nil {
		t.Fatal(err)
	}
	f.RestartWorker(t)
	if p, err := f.ApplicationTurn(f.Worker, 1); err != nil || p.Selected != 1 || p.Rejected != 1 {
		t.Fatal("first bounded repair turn", p, err)
	}
	if p, err := f.ApplicationTurn(f.Worker, 1); err != nil || p.Selected != 1 || p.Converted != 1 {
		t.Fatal("second bounded repair turn", p, err)
	}
	if p, err := f.ApplicationTurn(f.Worker, 256); err != nil || p.Selected != 0 || !p.NoEligible {
		t.Fatal("completed worker turn was not idle", p, err)
	}
	var body string
	var stamp int
	if err := f.Installer.QueryRow(f.Context, "select payload::text,schema_version from mail.tesl_jobs where id='turn'").Scan(&body, &stamp); err != nil || stamp != 2 || body != `{"message": "repaired", "priority": 9}` {
		t.Fatal("resolved typed code did not publish target payload", body, stamp, err)
	}
}

func TestPostgresApplicationQueueRetirementBlocksUntilRepair(t *testing.T) {
	f := rt.OpenApplicationQueueForTest(t)
	if err := f.StageApplicationRoot(f.Installer, Conversion0); err != nil {
		t.Fatal(err)
	}
	if err := f.StageApplicationTarget(f.Installer); err != nil {
		t.Fatal(err)
	}
	if err := f.PublishApplicationTarget(); err != nil {
		t.Fatal(err)
	}
	if _, err := f.Request.Exec(f.Context, "select mail.tesl_queue_enqueue(1,'Jobs','Delivery','retire',$1::jsonb)", `{"oldText":""}`); err != nil {
		t.Fatal(err)
	}
	if done, err := f.RetireApplication(f.Request); err == nil || done {
		t.Fatal("Request retired application history", done, err)
	}
	if done, err := f.RetireApplication(f.Worker); err != nil || done {
		t.Fatal("pending old job did not block retirement", done, err)
	}
	if p, err := f.ApplicationTurn(f.Worker, 1); err != nil || p.Rejected != 1 {
		t.Fatal(p, err)
	}
	if done, err := f.RetireApplication(f.Worker); err != nil || done {
		t.Fatal("quarantine did not block retirement", done, err)
	}
	if err := f.StageApplication(f.Installer, finalRepairDigest); err != nil {
		t.Fatal(err)
	}
	if p, err := f.ApplicationTurn(f.Worker, 1); err != nil || p.Rejected != 1 {
		t.Fatal(p, err)
	}
	if done, err := f.RetireApplication(f.Worker); err != nil || done {
		t.Fatal("rejected repair did not block retirement", done, err)
	}
	if p, err := f.ApplicationTurn(f.Worker, 1); err != nil || p.Converted != 1 {
		t.Fatal(p, err)
	}
	if err := f.OpenApplicationDispatch(f.Worker, finalRepairDigest); err != nil {
		t.Fatal(err)
	}
	claim, ok, err := f.QueueClaim(f.Request, 2, "pending", 60000)
	if err != nil || !ok {
		t.Fatal(claim, ok, err)
	}
	if done, err := f.RetireApplication(f.Worker); err != nil || !done {
		t.Fatal("surviving V2 claim blocked completed retirement", done, err)
	}
	if done, err := f.RetireApplication(f.Worker); err != nil || !done {
		t.Fatal("retirement replay failed", done, err)
	}
	var floor, compat, receipts int
	if err := f.Worker.QueryRow(f.Context, "select min_version,compat_floor,(select count(*) from mail.tesl_schema_versions where version=2 and step in ('retired','contracting','contracted')) from mail.tesl_schema_state where id=1").Scan(&floor, &compat, &receipts); err != nil || floor != 2 || compat != 2 || receipts != 3 {
		t.Fatal("queue retirement did not atomically advance real floors/receipts", floor, compat, receipts, err)
	}
	if _, err := f.Request.Exec(f.Context, "select mail.tesl_queue_enqueue(1,'Jobs','Delivery','late',$1::jsonb)", `{"oldText":"late"}`); err == nil {
		t.Fatal("retired V1 writer enqueued a job")
	}
	if err := f.StageApplication(f.Installer, finalRepairDigest); err == nil {
		t.Fatal("retired source accepted repair registration")
	}
	if p, err := f.ApplicationTurn(f.Worker, 256); err != nil || p.Selected != 0 {
		t.Fatal("retired edge still scheduled work", p, err)
	}
	if renewed, err := f.QueueBoolean(f.Request, 2, "renew", claim.ID, claim.Token, claim.Sequence, int64(60000)); err != nil || !renewed {
		t.Fatal("retirement revoked surviving V2 lease", renewed, err)
	}
	if completed, err := f.QueueBoolean(f.Request, 2, "complete", claim.ID, claim.Token, claim.Sequence); err != nil || !completed {
		t.Fatal(completed, err)
	}
	f.ApplicationStatus(t)
}

func TestPostgresPublicQueueWorkerConvertsRetainedPayload(t *testing.T) {
	f := rt.OpenPublicApplicationQueueForTest(t)
	if _, err := f.Request.Exec(f.Context, "select mail.tesl_queue_enqueue(1,'Jobs','Delivery','public-kept',$1::jsonb)", `{"oldText":"kept"}`); err != nil {
		t.Fatal(err)
	}
	if _, err := f.Request.Exec(f.Context, "select mail.tesl_queue_enqueue(1,'Jobs','Delivery','public-rejected',$1::jsonb)", `{"oldText":""}`); err != nil {
		t.Fatal(err)
	}
	stopWorker := f.StartPublicSuccessorWorker(t)
	deadline := time.Now().Add(15 * time.Second)
	for {
		var converted, rejected int
		if err := f.Installer.QueryRow(f.Context, "select count(*) filter(where schema_version=2 and payload->>'message'='kept'),count(*) filter(where schema_version=1 and status='quarantined' and dead_reason='migration-rejected') from mail.tesl_jobs").Scan(&converted, &rejected); err != nil {
			t.Fatal(err)
		}
		if converted == 1 && rejected == 1 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("public worker did not convert/reject retained jobs", converted, rejected)
		}
		time.Sleep(25 * time.Millisecond)
	}
	stopWorker()
	var receipts int
	if err := f.Installer.QueryRow(f.Context, "select count(*) from mail.tesl_row_queue_conversion_receipts").Scan(&receipts); err != nil || receipts != 2 {
		t.Fatal("public conversion did not retain its exact receipts", receipts, err)
	}
	if err := f.InstallPublicSuccessor(); err != nil {
		t.Fatal("published public installation replay failed", err)
	}
	if _, err := f.Installer.Exec(f.Context, "update mail.tesl_row_queue_conversion_staging set fence_ns=fence_ns+1"); err != nil {
		t.Fatal(err)
	}
	if err := f.InstallPublicSuccessor(); err == nil {
		t.Fatal("public install replay accepted altered installed source authority")
	}
	if _, err := f.Installer.Exec(f.Context, "update mail.tesl_row_queue_conversion_staging set fence_ns=fence_ns-1"); err != nil {
		t.Fatal(err)
	}
	var after int
	if err := f.Installer.QueryRow(f.Context, "select count(*) from mail.tesl_row_queue_conversion_receipts").Scan(&after); err != nil || after != receipts {
		t.Fatal("installation replay changed durable conversion receipts", after, err)
	}
	f.StartPublicSuccessorRequest(t)
	f.ApplicationStatus(t)
	if err := f.ContractPublicSuccessor(); err == nil || !strings.Contains(err.Error(), "blocked by old payloads") {
		t.Fatal("public queue Contract did not block rejected payload", err)
	}
	stopRepair := f.StartPublicSuccessorWorker(t, true)
	deadline = time.Now().Add(15 * time.Second)
	for {
		var repaired int
		if err := f.Installer.QueryRow(f.Context, "select count(*) from mail.tesl_jobs where id='public-rejected' and schema_version=2 and payload->>'message'='repaired' and status='pending'").Scan(&repaired); err != nil {
			t.Fatal(err)
		}
		if repaired == 1 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("public repaired deployment did not convert original quarantined payload")
		}
		time.Sleep(25 * time.Millisecond)
	}
	stopRepair()
	if err := f.InstallPublicSuccessor(true); err != nil {
		t.Fatal("public repair install replay failed", err)
	}
	if _, err := f.Installer.Exec(f.Context, "insert into mail.tesl_schema_instances values('public-old',1,1,clock_timestamp(),1)"); err != nil {
		t.Fatal(err)
	}
	if err := f.ContractPublicSuccessor(); err == nil || !strings.Contains(err.Error(), "recent retiring instances") {
		t.Fatal("public queue Contract ignored recent V1 instance", err)
	}
	if _, err := f.Installer.Exec(f.Context, "update mail.tesl_schema_instances set last_seen=clock_timestamp()-interval '31 seconds' where instance='public-old'"); err != nil {
		t.Fatal(err)
	}
	if err := f.ContractPublicSuccessor(); err != nil {
		t.Fatal("public queue Contract did not retire repaired edge", err)
	}
	if err := f.ContractPublicSuccessor(); err != nil {
		t.Fatal("public queue Contract replay failed", err)
	}
	var floor, compatibility int
	if err := f.Installer.QueryRow(f.Context, "select min_version,compat_floor from mail.tesl_schema_state").Scan(&floor, &compatibility); err != nil || floor != 2 || compatibility != 2 {
		t.Fatal("public retirement did not advance both admission floors", floor, compatibility, err)
	}
	stopRestart := f.StartPublicSuccessorWorker(t, true)
	stopRestart()
	if _, err := f.Request.Exec(f.Context, "select mail.tesl_queue_enqueue(1,'Jobs','Delivery','public-after-retirement',$1::jsonb)", `{"oldText":"late"}`); err == nil {
		t.Fatal("public retirement still admitted V1 enqueue")
	}
	f.ApplicationStatus(t)
}
