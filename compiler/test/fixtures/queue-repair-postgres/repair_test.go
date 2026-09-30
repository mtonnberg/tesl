package teslqueueconversions

import (
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
