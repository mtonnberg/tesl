package teslrt

import (
	"context"
	"fmt"
	"math"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

type queueRuntimeJob struct{ Message string }
type queueRuntimeOtherJob struct{ Message string }
type pgQueueRuntimeFixture struct {
	*pgQueueOperationsFixture
	database *Database
	queue    *Queue
	backend  *pgQueueBackend
	db       *PostgresDB
}

// This private fixture publishes only the candidate after real restricted-role
// catalog/inventory verification and local App registration closure. Production
// App/WithDatabase still refuse format4. SQL callers represent the other binary.
func pgNewQueueRuntimeTest(t *testing.T, current, latest int) *pgQueueRuntimeFixture {
	t.Helper()
	return pgNewQueueRuntimeCodecsTest(t, current, latest, false)
}
func pgNewQueueRuntimeCodecsTest(t *testing.T, current, latest int, two bool) *pgQueueRuntimeFixture {
	t.Helper()
	var f *pgQueueOperationsFixture
	h, root := pgCandidateTestSource(t, current, false, "")
	if two {
		control, request, _, _ := pgQueueRegistrationSetup(t)
		h, root = pgQueueRegistrationSource(t, 2)
		pgQueueRegistrationRelink(t, h, root)
		pgQueueRegistrationAdvance(t, control, h, 2)
		f = &pgQueueOperationsFixture{control, request}
	} else {
		f = pgNewQueueOperationsTest(t, latest)
	}
	pgQueueRegistrationRelink(t, h, root)
	database := RegisterDatabaseIdentity(h.Database, NewDatabase("RenamedDatabase", PostgresConfig{Schema: h.Namespace, MigrationTopology: "Worker", User: f.roles.Request, RequestRole: f.roles.Request, WorkerRole: f.roles.Worker, ControlOwner: f.roles.Owner}, nil))
	RegisterDatabaseMigrationHistory(database, h.Family)
	queue := NewQueueOn(database, "AppLocalReminderJobs", 2, "", 0)
	listener := pubsubRuntimeOf(t, database)
	t.Cleanup(listener.Close)
	RegisterQueueSchema(queue, database, h.Family, "Notifications", current)
	source, err := h.QueueSourceInventory(current)
	if err != nil {
		t.Fatal(err)
	}
	payloads := source.Versions[0].Contracts[0].Payloads
	// Register in reverse contract order. Decoder selection and encoder type cache
	// must use checked job identity rather than either list's index.
	for i := len(payloads) - 1; i >= 0; i-- {
		p := payloads[i]
		encode := func(value any) any { job := value.(queueRuntimeJob); return map[string]any{"message": job.Message} }
		decode := func(value any) (any, error) {
			message, err := DecodeStringField(value, "message")
			return queueRuntimeJob{message}, err
		}
		if p.Job == "Rebuild" {
			encode = func(value any) any {
				job := value.(queueRuntimeOtherJob)
				return map[string]any{"message": job.Message}
			}
			decode = func(value any) (any, error) {
				message, err := DecodeStringField(value, "message")
				return queueRuntimeOtherJob{message}, err
			}
		}
		RegisterQueueSchemaJobCodec(queue, h.Family, "Notifications", p.Job, current, p.ContractHash, "Schema.Tasks.VCurrent."+p.Job, encode, decode)
	}
	if err := prepareAppRegistrationsForTest(database); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		databaseIdentities.Delete(h.Database)
		pgMigrationRegistrations.Lock()
		delete(pgMigrationClosedFamilies, h.Family)
		pgMigrationRegistrations.Unlock()
		queueSchemaOwners.Lock()
		delete(queueSchemaOwners.queues, database)
		queueSchemaOwners.Unlock()
		listener.Close()
		pgPubsubs.Delete(database)
	})
	config, err := pgxpool.ParseConfig(f.request.Config().ConnString())
	if err != nil {
		t.Fatal(err)
	}
	config.ConnConfig = f.request.Config().Copy()
	config.MaxConns = 4
	state, err := pgCandidateReadOnly(t, f.pgControlTestFixture, f.request, &h)
	if err != nil {
		t.Fatal(err)
	}
	db, err := pgOpenQueueCandidateRuntime(f.ctx, database, config, &pgMigrationAdmission{version: current, fenceNamespace: state.FenceNamespace, databaseUUID: state.DatabaseUUID, worker: f.roles.Request, roles: f.roles})
	if err != nil {
		t.Fatal(err)
	}
	pool := db.pool
	t.Cleanup(func() { listener.Close(); pool.Close() })
	return &pgQueueRuntimeFixture{f, database, queue, queue.backend.(*pgQueueBackend), db}
}
func (f *pgQueueRuntimeFixture) bound(body func()) {
	f.database.mutex.Lock()
	previous := f.database.open
	f.database.open = f.db
	f.database.mutex.Unlock()
	previousGlobal := boundDatabase.Swap(f.database)
	defer func() {
		boundDatabase.Store(previousGlobal)
		f.database.mutex.Lock()
		f.database.open = previous
		f.database.mutex.Unlock()
	}()
	body()
}
func (f *pgQueueRuntimeFixture) row(t *testing.T, id string) string {
	t.Helper()
	var result string
	if err := f.installer.QueryRow(f.ctx, "select row_to_json(j)::text from notes_app.tesl_jobs j where id=$1", id).Scan(&result); err != nil {
		t.Fatal(err)
	}
	return result
}
func TestQueueRuntimeUsesCheckedIdentityAndBooleanOwnership(t *testing.T) {
	f := pgNewQueueRuntimeTest(t, 3, 3)
	f.bound(func() {
		id := Enqueue(f.queue, queueRuntimeJob{"retained 雪"})
		var queue, job string
		var version int
		if err := f.installer.QueryRow(f.ctx, "select queue,job_type,schema_version from notes_app.tesl_jobs where id=$1", id).Scan(&queue, &job, &version); err != nil {
			t.Fatal(err)
		}
		if queue != "Notifications" || job != "Notify" || version != 3 {
			t.Fatal(queue, job, version)
		}
		got, payload, attempts, token, found := f.backend.dequeue(jobPending)
		if !found || got != id || payload.(queueRuntimeJob).Message != "retained 雪" || attempts != 0 {
			t.Fatal(got, payload, attempts, found)
		}
		if f.backend.complete(id, token+"0") || f.backend.fail(id, attempts, token+"0") {
			t.Fatal("stale token was treated as SQL row count success")
		}
		if !f.backend.complete(id, token) || f.backend.complete(id, token) {
			t.Fatal("completion must be true then false")
		}
		if f.backend.requeue("missing") {
			t.Fatal("absent requeue became true")
		}
		if n := PendingJobCount(f.queue); n.String() != "0" {
			t.Fatal(n)
		}
	})
}
func TestQueueRuntimeOldBinaryLeavesFutureJobsByteIdentical(t *testing.T) {
	f := pgNewQueueRuntimeTest(t, 1, 3)
	f.enqueue(t, f.request, 3, "newer")
	claimed := f.mustClaim(t, f.request, 3, jobPending)
	f.expire(t, claimed.ID)
	before := f.row(t, "newer")
	f.bound(func() {
		if got := ProcessNextJob(f.queue, func(any) JobOutcome { t.Fatal("future job dispatched"); return JobOutcome{} }); got.Ran {
			t.Fatal(got)
		}
		if PendingJobCount(f.queue).String() != "0" || len(DeadJobs(f.queue)) != 0 {
			t.Fatal("future metadata leaked")
		}
	})
	if after := f.row(t, "newer"); after != before {
		t.Fatal("old worker reclaimed or changed future attempt", before, after)
	}
}
func TestQueueRuntimeRetryRestampsAndDeadMetadataRemainsTyped(t *testing.T) {
	f := pgNewQueueRuntimeTest(t, 3, 3)
	f.enqueue(t, f.request, 1, "old")
	f.bound(func() {
		ProcessNextJob(f.queue, failJob)
		var version, attempts int
		if err := f.installer.QueryRow(f.ctx, "select schema_version,attempts from notes_app.tesl_jobs where id='old'").Scan(&version, &attempts); err != nil || version != 3 || attempts != 1 {
			t.Fatal(version, attempts, err)
		}
		ProcessNextJob(f.queue, failJob)
		entries := DeadJobs(f.queue)
		if len(entries) != 1 {
			t.Fatal(entries)
		}
		entry := entries[0]
		v, ok := DeadJobSourceVersion(entry).Value()
		job, known := DeadJobTypeName(entry).Value()
		if !ok || v.String() != "3" || !known || job != "Notify" || DeadJobReasonOf(entry).Tag != DeadJobReasonAttemptsExhausted || DeadJobAttempts(entry).String() != "2" {
			t.Fatal(entry)
		}
		if !Requeue(entry) || Requeue(entry) {
			t.Fatal("requeue result did not match live dead row")
		}
		ProcessNextJob(f.queue, okJob)
		if PendingJobCount(f.queue).String() != "0" || DeadJobCount(f.queue).String() != "0" {
			t.Fatal("completed retry remains")
		}
	})
}
func TestQueueRuntimeDecodeFailurePreservesBytesAndRejectsStaleRequeue(t *testing.T) {
	f := pgNewQueueRuntimeTest(t, 3, 3)
	f.enqueue(t, f.request, 1, "bad")
	if _, err := f.installer.Exec(f.ctx, "update notes_app.tesl_jobs set payload='{\"message\":42,\"retained\":\"雪\"}' where id='bad'"); err != nil {
		t.Fatal(err)
	}
	f.bound(func() {
		var payloadBefore string
		if err := f.installer.QueryRow(f.ctx, "select payload::text from notes_app.tesl_jobs where id='bad'").Scan(&payloadBefore); err != nil {
			t.Fatal(err)
		}
		output := captureStderr(t, func() {
			if out := ProcessNextJob(f.queue, okJob); out.Ran {
				t.Fatal("invalid payload reached handler")
			}
		})
		if !strings.Contains(output, "quarantined") {
			t.Fatal(output)
		}
		entries := DeadJobs(f.queue)
		if len(entries) != 1 {
			t.Fatal(entries)
		}
		entry := entries[0]
		version, _ := DeadJobSourceVersion(entry).Value()
		if version.String() != "1" || DeadJobReasonOf(entry).Tag != DeadJobReasonPayloadInvalid {
			t.Fatal(entry)
		}
		var after string
		if err := f.installer.QueryRow(f.ctx, "select payload::text from notes_app.tesl_jobs where id='bad'").Scan(&after); err != nil || after != payloadBefore {
			t.Fatal(after, err)
		}
		before := f.row(t, "bad")
		stale := entry
		stale.reason.Tag = DeadJobReasonAttemptsExhausted
		if Requeue(entry) || Requeue(stale) || ProcessNextDeadJob(f.queue, okJob).Ran {
			t.Fatal("quarantine retried")
		}
		if f.row(t, "bad") != before {
			t.Fatal("refused quarantine changed retained row")
		}
		if DeadJobCount(f.queue).String() != "1" {
			t.Fatal("quarantine not counted")
		}
	})
}
func TestQueueRuntimeTransactionsRetainAtomicityAndActualXID(t *testing.T) {
	f := pgNewQueueRuntimeTest(t, 3, 3)
	t.Setenv("TESL_QUEUE_VISIBILITY_TIMEOUT_MS", "100")
	f.bound(func() {
		failure := pgFacilityPanic(func() {
			WithTransaction(func() { Enqueue(f.queue, queueRuntimeJob{"rolled back"}); panic("rollback") })
		})
		if failure == nil || PendingJobCount(f.queue).String() != "0" {
			t.Fatal("enqueue survived rollback", failure)
		}
		id := Enqueue(f.queue, queueRuntimeJob{"atomic"})
		var token string
		failure = pgFacilityPanic(func() {
			WithTransaction(func() {
				got, _, _, claim, found := f.backend.dequeue(jobPending)
				token = claim
				if !found || got != id {
					t.Fatal(got, found)
				}
				// Same real transaction owns the row even with an expired lease.
				tx := currentTransactionFor(f.db)
				// Restricted requests cannot change protected leases. Wait for the actual
				// short claim lease while the application transaction retains its lock.
				if tx == nil {
					t.Fatal("claim did not use app transaction")
				}
				PgExec(f.db, "insert into notes_app.notes(id,active) values ('rolled-back-effect',true)", nil)
				PgExec(f.db, "select pg_sleep(0.15)", nil)
				if !f.backend.complete(id, claim) {
					t.Fatal("transactional complete lost ownership")
				}
				panic("rollback")
			})
		})
		if failure == nil || PendingJobCount(f.queue).String() != "1" || f.backend.complete(id, token) {
			t.Fatal("rolled-back attempt survived", failure)
		}
		if PgCount(f.db, "select count(*) from notes_app.notes where id='rolled-back-effect'", nil).String() != "0" {
			t.Fatal("business effect survived rollback")
		}
		WithTransaction(func() {
			if !ProcessNextJob(f.queue, func(any) JobOutcome {
				PgExec(f.db, "insert into notes_app.notes(id,active) values ('committed-effect',true)", nil)
				return JobOutcome{OK: true}
			}).OK {
				t.Fatal("commit worker failed")
			}
		})
		if PendingJobCount(f.queue).String() != "0" || PgCount(f.db, "select count(*) from notes_app.notes where id='committed-effect'", nil).String() != "1" {
			t.Fatal("committed job and business effect diverged")
		}
	})
}
func TestQueueRuntimeRefusesUnsafeBindingAndResetBeforeSQL(t *testing.T) {
	f := pgNewQueueRuntimeTest(t, 3, 3)
	f.bound(func() {
		id := Enqueue(f.queue, queueRuntimeJob{"keep"})
		before := f.row(t, id)
		if err := pgFacilityPanic(func() { ResetQueue(f.queue) }); err == nil {
			t.Fatal("protected reset allowed")
		}
		saved := f.backend.queueSchema
		f.backend.queueSchema = nil
		if err := pgFacilityPanic(func() { Enqueue(f.queue, queueRuntimeJob{"refuse"}) }); err == nil {
			t.Fatal("missing binding fell back to legacy")
		}
		f.backend.queueSchema = saved
		if after := f.row(t, id); after != before {
			t.Fatal("refusal mutated retained job")
		}
	})
	// The same declaration remains usable with Memory when no database is bound.
	Enqueue(f.queue, queueRuntimeJob{"test-only"})
	ResetQueue(f.queue)
	if PendingJobCount(f.queue).String() != "0" {
		t.Fatal("unbound Memory reset changed")
	}
}
func TestQueueRuntimeDurationAndBackoffBounds(t *testing.T) {
	for _, test := range []struct {
		policy            string
		initial, failures int
		want              int64
	}{
		{"", math.MaxInt, math.MaxInt, 0}, {"fixed", 0, 4, 0}, {"fixed", 3, 50, 3000},
		{"linear", 3, 2, 9000}, {"exponential", 3, 2, 12000}, {"exponential", 3, 63, pgQueueMaximumMillis},
		{"fixed", math.MaxInt, 1, pgQueueMaximumMillis}, {"linear", 1, math.MaxInt, pgQueueMaximumMillis},
		{"exponential", math.MaxInt, math.MaxInt, pgQueueMaximumMillis},
	} {
		t.Run(fmt.Sprint(test.policy, test.initial, test.failures), func(t *testing.T) {
			b := pgQueueBackend{backoff: test.policy, initialDelay: test.initial}
			if got := b.protectedRetryDelayMillis(test.failures); got != test.want {
				t.Fatal(got, test.want)
			}
		})
	}
	for _, millis := range []int64{600000, pgQueueMaximumMillis, pgQueueMaximumMillis + 1, math.MaxInt64} {
		t.Setenv("TESL_QUEUE_VISIBILITY_TIMEOUT_MS", fmt.Sprint(millis))
		if got := queueVisibilityTimeout().Milliseconds(); got != min(millis, pgQueueMaximumMillis) {
			t.Fatal(got, millis)
		}
	}
}
func TestQueueRuntimeRenewalUsesPinnedClient(t *testing.T) {
	f := pgNewQueueRuntimeTest(t, 3, 3)
	f.bound(func() {
		id := Enqueue(f.queue, queueRuntimeJob{"renew"})
		_, _, _, token, found := f.backend.dequeue(jobPending)
		if !found {
			t.Fatal("no claim")
		}
		client := f.backend.protectedQueue()
		f.database.mutex.Lock()
		f.database.open = nil
		f.database.mutex.Unlock()
		owned, err := client.renew(context.Background(), id, token, time.Second)
		f.database.mutex.Lock()
		f.database.open = f.db
		f.database.mutex.Unlock()
		if err != nil || !owned {
			t.Fatal(owned, err)
		}
		if !f.backend.complete(id, token) {
			t.Fatal("complete failed")
		}
		if owned, err = client.renew(context.Background(), id, token, time.Second); err != nil || owned {
			t.Fatal("renew after completion", owned, err)
		}
	})
}

func TestQueueRuntimeReplacedAttemptCannotRenewCompleteOrFail(t *testing.T) {
	f := pgNewQueueRuntimeTest(t, 3, 3)
	f.bound(func() {
		id := Enqueue(f.queue, queueRuntimeJob{"replace"})
		_, _, attempts, old, found := f.backend.dequeue(jobPending)
		if !found {
			t.Fatal("missing claim")
		}
		f.expire(t, id)
		got, _, _, current, found := f.backend.dequeue(jobPending)
		if !found || got != id || current == old {
			t.Fatal(got, found, current, old)
		}
		before := f.row(t, id)
		renewed, err := f.backend.protectedQueue().renew(f.ctx, id, old, time.Second)
		if err != nil || renewed || f.backend.complete(id, old) || f.backend.fail(id, attempts, old) {
			t.Fatal("stale attempt kept authority", renewed, err)
		}
		if after := f.row(t, id); after != before {
			t.Fatal("stale attempt mutated replacement")
		}
		if !f.backend.complete(id, current) {
			t.Fatal("replacement lost authority")
		}
	})
}
func TestQueueRuntimeConcurrentPublicWorkersDispatchEachJobOnce(t *testing.T) {
	f := pgNewQueueRuntimeTest(t, 3, 3)
	f.bound(func() {
		const jobs = 24
		for i := range jobs {
			Enqueue(f.queue, queueRuntimeJob{fmt.Sprint(i)})
		}
		var mutex sync.Mutex
		seen := map[string]int{}
		errors := make(chan any, 4)
		var workers sync.WaitGroup
		for range 4 {
			workers.Go(func() {
				defer func() {
					if e := recover(); e != nil {
						errors <- e
					}
				}()
				for {
					out := ProcessNextJob(f.queue, func(value any) JobOutcome {
						mutex.Lock()
						seen[value.(queueRuntimeJob).Message]++
						mutex.Unlock()
						return JobOutcome{OK: true}
					})
					if !out.Ran {
						return
					}
				}
			})
		}
		workers.Wait()
		close(errors)
		for err := range errors {
			t.Fatal(err)
		}
		if len(seen) != jobs || PendingJobCount(f.queue).String() != "0" {
			t.Fatal("jobs missing", seen)
		}
		for job, count := range seen {
			if count != 1 {
				t.Fatal("duplicate dispatch", job, count)
			}
		}
	})
}
func TestQueueRuntimeSQLAcceptsFiniteDurationLimitAndRefusesOverflow(t *testing.T) {
	f := pgNewQueueRuntimeTest(t, 3, 3)
	f.bound(func() {
		id := Enqueue(f.queue, queueRuntimeJob{"bounded"})
		claim := f.mustClaim(t, f.request, 3, jobPending)
		f.boolean(t, f.request, true, "select notes_app.tesl_queue_renew(3,'Notifications',$1,$2,$3,$4)", id, claim.Token, claim.Sequence, pgQueueMaximumMillis)
		before := f.row(t, id)
		var owned bool
		if err := f.request.QueryRow(f.ctx, "select notes_app.tesl_queue_renew(3,'Notifications',$1,$2,$3,$4)", id, claim.Token, claim.Sequence, pgQueueMaximumMillis+1).Scan(&owned); err == nil {
			t.Fatal("oversized SQL lease accepted")
		}
		if before != f.row(t, id) {
			t.Fatal("invalid duration changed lease")
		}
		f.boolean(t, f.request, true, "select notes_app.tesl_queue_fail(3,'Notifications',$1,$2,$3,2,$4)", id, claim.Token, claim.Sequence, pgQueueMaximumMillis)
		var deferred bool
		if err := f.installer.QueryRow(f.ctx, "select next_attempt_at > clock_timestamp()+interval '290 years' and isfinite(next_attempt_at) from notes_app.tesl_jobs where id=$1", id).Scan(&deferred); err != nil || !deferred {
			t.Fatal("backoff overflowed", deferred, err)
		}
	})
}

func TestQueueRuntimeMultipleCodecsUseIdentityAndContinueAfterQuarantine(t *testing.T) {
	f := pgNewQueueRuntimeCodecsTest(t, 2, 2, true)
	f.bound(func() {
		bad := Enqueue(f.queue, queueRuntimeJob{"bad"})
		good := Enqueue(f.queue, queueRuntimeOtherJob{"other"})
		again := Enqueue(f.queue, queueRuntimeJob{"same encoder cached"})
		if _, err := f.installer.Exec(f.ctx, "update notes_app.tesl_jobs set payload='{\"message\":false}' where id=$1", bad); err != nil {
			t.Fatal(err)
		}
		var received []any
		out := captureStderr(t, func() {
			first := ProcessNextJob(f.queue, func(value any) JobOutcome { received = append(received, value); return JobOutcome{OK: true} })
			if !first.Ran || !first.OK {
				t.Fatal(first)
			}
		})
		if !strings.Contains(out, "quarantined") || len(received) != 1 || received[0] != (queueRuntimeOtherJob{"other"}) {
			t.Fatal(out, received)
		}
		next := ProcessNextJob(f.queue, func(value any) JobOutcome { received = append(received, value); return JobOutcome{OK: true} })
		if !next.OK || received[1] != (queueRuntimeJob{"same encoder cached"}) {
			t.Fatal(next, received)
		}
		var count int
		if err := f.installer.QueryRow(f.ctx, "select count(*) from notes_app.tesl_jobs where id=any($1::text[])", []string{good, again}).Scan(&count); err != nil || count != 0 {
			t.Fatal(count, err)
		}
		dead := DeadJobs(f.queue)
		if len(dead) != 1 || dead[0].ID != bad || DeadJobReasonOf(dead[0]).Tag != DeadJobReasonPayloadInvalid {
			t.Fatal(dead)
		}
	})
}

func TestQueueRuntimePoolReconnectRechecksIdentityAndPrivileges(t *testing.T) {
	for _, mutation := range []string{"database identity", "role escalation"} {
		t.Run(mutation, func(t *testing.T) {
			f := pgNewQueueRuntimeTest(t, 3, 3)
			statement := "update notes_app.tesl_schema_meta set database_uuid='11111111-1111-1111-1111-111111111111'"
			if mutation == "role escalation" {
				statement = "grant " + quoteIdentifier(f.roles.Worker) + " to " + quoteIdentifier(f.roles.Request)
			}
			if _, err := f.installer.Exec(f.ctx, statement); err != nil {
				t.Fatal(err)
			}
			f.db.pool.Reset()
			ctx, cancel := context.WithTimeout(f.ctx, time.Second)
			defer cancel()
			if err := f.db.pool.Ping(ctx); err == nil {
				t.Fatal("replacement connection skipped candidate identity/catalog verification")
			}
			if f.db.pool.Stat().AcquiredConns() != 0 {
				t.Fatal("refused connection leaked a pool lease")
			}
		})
	}
}
