package teslrt

import (
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// The durable stores against the live cluster (skipped without one, like every other live
// test), plus the one property that needs no cluster: an UNBOUND durable store is the
// in-memory store, so a test block runs with no server anywhere.

// storeJob is a job record as the emitter would shape one: a string and an unbounded Int,
// so the JSONB round trip is exercised on the one value that would silently lose precision
// through a float.
type storeJob struct {
	Name  string
	Count Int
}

func registerStoreJobCodec(queue *Queue) {
	RegisterJobCodec(queue, "StoreJob",
		func(value any) any {
			// The emitter's shape: a one-value assertion, whose refusal is what the codec
			// probe reads as "not this type".
			job := value.(storeJob) //nolint:forcetypeassert // see above
			return map[string]any{"name": job.Name, "count": job.Count}
		},
		func(raw any) (any, error) {
			name, err := DecodeStringField(raw, "name")
			if err != nil {
				return nil, err
			}
			count, err := DecodeIntField(raw, "count")
			if err != nil {
				return nil, err
			}
			return storeJob{Name: name, Count: count}, nil
		})
}

// storeDatabase is a Postgres-backed declaration with no entities of its own: the durable
// stores create their tables lazily, so nothing is declared up front.
func storeDatabase(t *testing.T, name string) *Database {
	t.Helper()
	return &Database{Name: name, Config: liveCluster(t)}
}

func uniqueName(prefix string) string {
	return prefix + "_" + strings.ReplaceAll(UUIDv7(), "-", "")
}

func okJob(any) JobOutcome   { return JobOutcome{OK: true} }
func failJob(any) JobOutcome { return JobOutcome{OK: false, Message: "nope"} }

func expectInt(t *testing.T, label string, got Int, want int64) {
	t.Helper()
	if !Equal(got, FromInt64(want)) {
		t.Fatalf("%s: got %s, want %d", label, got.String(), want)
	}
}

// captureStderr runs `body` with os.Stderr redirected and answers what it wrote.
func captureStderr(t *testing.T, body func()) string {
	t.Helper()
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	previous := os.Stderr
	os.Stderr = writer
	collected := make(chan string, 1)
	go func() {
		data, _ := io.ReadAll(reader)
		collected <- string(data)
	}()
	func() {
		defer func() {
			os.Stderr = previous
			_ = writer.Close()
		}()
		body()
	}()
	return <-collected
}

// ── No cluster ────────────────────────────────────────────────────────────────

// A durable store whose database is not bound IS the in-memory store: no server is reached,
// and the behaviour is the Memory backend's to the letter. This is what keeps a `test` block
// over a Postgres-backed queue runnable on a machine with no cluster.
func TestDurableStoresFallBackToMemoryWhenUnbound(t *testing.T) {
	database := &Database{Name: "Unbound", Config: PostgresConfig{Host: "nowhere.invalid", Port: 1}}

	queue := NewQueueOn(database, "unbound", 2, "exponential", 60)
	registerStoreJobCodec(queue)
	if queue.durable() != nil {
		t.Fatal("an unbound queue reports a durable backend")
	}
	if queue.idleInterval() != 50*time.Millisecond {
		t.Fatalf("unbound idle interval is %v", queue.idleInterval())
	}
	EnqueueJob(queue, storeJob{Name: "one", Count: FromInt64(1)})
	expectInt(t, "pending", PendingJobCount(queue), 1)
	if outcome := ProcessNextJob(queue, failJob); !outcome.Ran || outcome.OK {
		t.Fatalf("first attempt: %+v", outcome)
	}
	// No backoff on the memory path: the retry is claimable at once.
	if outcome := ProcessNextJob(queue, failJob); !outcome.Ran {
		t.Fatal("the retry was not claimable immediately on the memory path")
	}
	expectInt(t, "dead", DeadJobCount(queue), 1)
	if dead := DeadJobs(queue); len(dead) != 1 || !Requeue(dead[0]) {
		t.Fatalf("dead letter: %+v", dead)
	}
	if outcome := ProcessNextJob(queue, okJob); !outcome.Ran || !outcome.OK {
		t.Fatalf("requeued job: %+v", outcome)
	}
	ResetQueue(queue)
	expectInt(t, "after reset", PendingJobCount(queue), 0)

	outbox := NewOutboxOn(database, testSettings("", 0))
	SendEmail(outbox, "to@example.com", "Hi", TextBody("body"))
	if messages := OutboxMessages(outbox); len(messages) != 1 || messages[0].To != "to@example.com" {
		t.Fatalf("unbound outbox: %+v", messages)
	}
	ResetOutbox(outbox)
	if len(OutboxMessages(outbox)) != 0 {
		t.Fatal("unbound outbox did not reset")
	}

	cache := NewCacheOn[string](database, "unbound", 0, func(s string) any { return s }, DecodeStringValue)
	CacheSet(cache, "k", "v")
	if hit := CacheGet(cache, "k"); !hit.IsSomething() || hit.SomethingValue != "v" {
		t.Fatalf("unbound cache: %+v", hit)
	}
	CacheInvalidatePrefix(cache, "k")
	if CacheGet(cache, "k").IsSomething() {
		t.Fatal("unbound cache did not invalidate")
	}
}

// RegisterJobCodec on a Memory queue has nothing to register and must not trap.
func TestRegisterJobCodecOnAMemoryQueueIsANoOp(t *testing.T) {
	queue := NewQueue("memory", 1)
	registerStoreJobCodec(queue)
	EnqueueJob(queue, storeJob{Name: "x", Count: FromInt64(1)})
	if outcome := ProcessNextJob(queue, okJob); !outcome.Ran {
		t.Fatal("memory queue lost its job")
	}
}

// The codec probe skips an encoder only for a TYPE ASSERTION refusal; any other panic is the
// encoder's own and must surface rather than read as "try the next codec".
func TestJobCodecProbeOnlySkipsTypeAssertions(t *testing.T) {
	wrongType := jobCodec{typeName: "Other", encode: func(v any) any {
		return v.(int) //nolint:forcetypeassert // the refusal under test
	}}
	if _, refused := tryEncode(wrongType, storeJob{}); !refused {
		t.Fatal("a type assertion failure was not read as a refusal")
	}
	broken := jobCodec{typeName: "Broken", encode: func(any) any { panic("encoder bug") }}
	defer func() {
		if recovered := recover(); recovered == nil || fmt.Sprint(recovered) != "encoder bug" {
			t.Fatalf("an encoder's own panic was swallowed: %v", recovered)
		}
	}()
	tryEncode(broken, storeJob{})
}

// ── Queue ─────────────────────────────────────────────────────────────────────

// (a) Two instances — two Queue values on two Database values with one configuration — work
// off one table: what A enqueues, B claims and completes, and A sees the backlog gone.
func TestDurableQueueIsSharedAcrossInstances(t *testing.T) {
	dbA, dbB := storeDatabase(t, "A"), storeDatabase(t, "B")
	name := uniqueName("shared")
	queueA := NewQueueOn(dbA, name, 3, "fixed", 0)
	queueB := NewQueueOn(dbB, name, 3, "fixed", 0)
	registerStoreJobCodec(queueA)
	registerStoreJobCodec(queueB)

	WithDatabase(dbA, func() {
		if queueA.idleInterval() != 5*time.Second {
			t.Fatalf("bound idle interval is %v", queueA.idleInterval())
		}
		ResetQueue(queueA)
		for index := range 20 {
			EnqueueJob(queueA, storeJob{Name: fmt.Sprintf("job-%02d", index), Count: FromInt64(int64(index))})
		}
		expectInt(t, "A pending", PendingJobCount(queueA), 20)
		if len(queueA.jobs) != 0 {
			t.Fatal("a durable enqueue landed in the in-memory store")
		}
	})
	seen := []string{}
	WithDatabase(dbB, func() {
		ran := DrainQueue(queueB, func(payload any) JobOutcome {
			job, ok := payload.(storeJob)
			if !ok {
				t.Fatalf("payload is %T", payload)
			}
			seen = append(seen, job.Name)
			return JobOutcome{OK: true}
		}, 100)
		expectInt(t, "B ran", ran, 20)
	})
	for index, name := range seen {
		if want := fmt.Sprintf("job-%02d", index); name != want {
			t.Fatalf("claim order: position %d is %s, want %s", index, name, want)
		}
	}
	WithDatabase(dbA, func() {
		expectInt(t, "A pending after B drained", PendingJobCount(queueA), 0)
		expectInt(t, "A dead", DeadJobCount(queueA), 0)
	})
}

// (b) `enqueue` inside `transaction { }` is the transaction's: a body that traps leaves no
// row, a body that returns leaves one.
func TestDurableEnqueueJoinsTheTransaction(t *testing.T) {
	database := storeDatabase(t, "Txn")
	queue := NewQueueOn(database, uniqueName("txn"), 1, "", 0)
	registerStoreJobCodec(queue)
	WithDatabase(database, func() {
		ResetQueue(queue)
		func() {
			defer func() {
				if recovered := recover(); recovered == nil {
					t.Fatal("the body's trap did not propagate")
				}
			}()
			WithTransaction(func() {
				EnqueueJob(queue, storeJob{Name: "rolled back", Count: FromInt64(1)})
				panic("boom")
			})
		}()
		expectInt(t, "after rollback", PendingJobCount(queue), 0)
		WithTransaction(func() {
			EnqueueJob(queue, storeJob{Name: "committed", Count: FromInt64(1)})
		})
		expectInt(t, "after commit", PendingJobCount(queue), 1)
	})
}

// (c) A failed attempt is not claimable until its backoff has passed.
func TestDurableQueueAppliesTheBackoff(t *testing.T) {
	database := storeDatabase(t, "Backoff")
	queue := NewQueueOn(database, uniqueName("backoff"), 3, "exponential", 1)
	registerStoreJobCodec(queue)
	WithDatabase(database, func() {
		ResetQueue(queue)
		EnqueueJob(queue, storeJob{Name: "slow", Count: FromInt64(1)})
		if outcome := ProcessNextJob(queue, failJob); !outcome.Ran || outcome.OK {
			t.Fatalf("first attempt: %+v", outcome)
		}
		if outcome := ProcessNextJob(queue, failJob); outcome.Ran {
			t.Fatal("the retry was claimable before its backoff passed")
		}
		expectInt(t, "pending during backoff", PendingJobCount(queue), 1)
		time.Sleep(1100 * time.Millisecond)
		if outcome := ProcessNextJob(queue, okJob); !outcome.Ran || !outcome.OK {
			t.Fatalf("retry after backoff: %+v", outcome)
		}
		expectInt(t, "pending after success", PendingJobCount(queue), 0)
	})
}

func TestRetryDelayFollowsTheDeclaredBackoff(t *testing.T) {
	cases := []struct {
		backoff  string
		attempts int
		want     int64
	}{
		{"exponential", 1, 60}, {"exponential", 2, 120}, {"exponential", 3, 240},
		{"linear", 1, 60}, {"linear", 3, 180},
		{"fixed", 1, 60}, {"fixed", 5, 60},
		{"", 1, 0}, {"", 4, 0},
	}
	for _, each := range cases {
		backend := &pgQueueBackend{backoff: each.backoff, initialDelay: 60}
		if got := backend.retryDelaySeconds(each.attempts); got != each.want {
			t.Errorf("%s after %d attempts: got %d, want %d", each.backoff, each.attempts, got, each.want)
		}
	}
}

// (d) maxAttempts exhausted → dead letter → listed → requeued → claimable with a fresh count.
func TestDurableQueueDeadLetterAndRequeue(t *testing.T) {
	database := storeDatabase(t, "Dead")
	queue := NewQueueOn(database, uniqueName("dead"), 2, "", 0)
	registerStoreJobCodec(queue)
	WithDatabase(database, func() {
		ResetQueue(queue)
		EnqueueJob(queue, storeJob{Name: "doomed", Count: FromInt64(1)})
		for attempt := range 2 {
			if outcome := ProcessNextJob(queue, failJob); !outcome.Ran {
				t.Fatalf("attempt %d was not claimable", attempt+1)
			}
		}
		if outcome := ProcessNextJob(queue, failJob); outcome.Ran {
			t.Fatal("a dead job was claimed by the ordinary worker")
		}
		expectInt(t, "pending", PendingJobCount(queue), 0)
		expectInt(t, "dead", DeadJobCount(queue), 1)
		dead := DeadJobs(queue)
		if len(dead) != 1 || dead[0].ID == "" {
			t.Fatalf("dead letter: %+v", dead)
		}
		if !Requeue(dead[0]) {
			t.Fatal("requeue answered false for a dead job")
		}
		if Requeue(dead[0]) {
			t.Fatal("requeue answered true for a job no longer dead")
		}
		expectInt(t, "pending after requeue", PendingJobCount(queue), 1)
		expectInt(t, "dead after requeue", DeadJobCount(queue), 0)
		// A fresh attempt count: two more failures are needed before it is dead again.
		if outcome := ProcessNextJob(queue, failJob); !outcome.Ran {
			t.Fatal("requeued job not claimable")
		}
		expectInt(t, "still pending", PendingJobCount(queue), 1)
		if outcome := ProcessNextJob(queue, okJob); !outcome.Ran || !outcome.OK {
			t.Fatalf("requeued job: %+v", outcome)
		}
	})
}

// The dead-letter worker claims dead jobs and removes them whatever the outcome.
func TestDurableDeadLetterWorkerConsumesDeadJobs(t *testing.T) {
	database := storeDatabase(t, "DeadWorker")
	queue := NewQueueOn(database, uniqueName("deadworker"), 1, "", 0)
	registerStoreJobCodec(queue)
	WithDatabase(database, func() {
		ResetQueue(queue)
		EnqueueJob(queue, storeJob{Name: "once", Count: FromInt64(1)})
		ProcessNextJob(queue, failJob)
		expectInt(t, "dead", DeadJobCount(queue), 1)
		if outcome := ProcessNextDeadJob(queue, failJob); !outcome.Ran {
			t.Fatal("the dead job was not claimed by the dead-letter worker")
		}
		expectInt(t, "dead after handling", DeadJobCount(queue), 0)
		if outcome := ProcessNextDeadJob(queue, okJob); outcome.Ran {
			t.Fatal("a removed dead job was claimed again")
		}
	})
}

// (e) A crash mid-job: the claim is never completed, and once the visibility timeout has
// passed another instance takes the same job over with its attempts intact.
func TestDurableQueueReclaimsAJobFromACrashedInstance(t *testing.T) {
	dbA, dbB := storeDatabase(t, "A"), storeDatabase(t, "B")
	name := uniqueName("crash")
	queueA := NewQueueOn(dbA, name, 3, "", 0)
	queueB := NewQueueOn(dbB, name, 3, "", 0)
	registerStoreJobCodec(queueA)
	registerStoreJobCodec(queueB)

	previousReclaim := queueReclaimInterval
	queueReclaimInterval = 0 // every claim sweeps, so the test does not wait a minute
	t.Cleanup(func() { queueReclaimInterval = previousReclaim })

	var claimedID string
	WithDatabase(dbA, func() {
		ResetQueue(queueA)
		EnqueueJob(queueA, storeJob{Name: "fragile", Count: FromInt64(1)})
		ProcessNextJob(queueA, failJob) // attempts = 1
		id, _, attempts, _, found := queueA.dequeue(jobPending)
		if !found || attempts != 1 {
			t.Fatalf("A's claim: found=%v attempts=%d", found, attempts)
		}
		claimedID = id
		// …and instance A dies here, never completing or failing the job.
	})
	WithDatabase(dbB, func() {
		if _, _, _, _, found := queueB.dequeue(jobPending); found {
			t.Fatal("B claimed a job A is still processing within the visibility window")
		}
		db := dbB.bound()
		PgExec(db, "update "+db.QualifiedTable(jobsTable)+" set lease_until=clock_timestamp()-interval '1 second' where id=$1", []any{claimedID})
		id, payload, attempts, claimToken, found := queueB.dequeue(jobPending)
		if !found {
			t.Fatal("B did not reclaim the abandoned job")
		}
		if id != claimedID {
			t.Fatalf("B reclaimed %s, A had %s", id, claimedID)
		}
		if attempts != 1 {
			t.Fatalf("attempts were not preserved across the reclaim: %d", attempts)
		}
		if job, ok := payload.(storeJob); !ok || job.Name != "fragile" {
			t.Fatalf("payload after reclaim: %#v", payload)
		}
		queueB.complete(id, claimToken)
		expectInt(t, "pending after completion", PendingJobCount(queueB), 0)
	})
}

// A dead-letter claim has a different origin from a normal claim. If its worker crashes, stale
// reclamation must put it back in the dead letter, never into the normal pending queue.
func TestDurableQueueReclaimsADeadJobToTheDeadLetter(t *testing.T) {
	dbA, dbB := storeDatabase(t, "DeadCrashA"), storeDatabase(t, "DeadCrashB")
	name := uniqueName("dead_crash")
	queueA := NewQueueOn(dbA, name, 1, "", 0)
	queueB := NewQueueOn(dbB, name, 1, "", 0)
	registerStoreJobCodec(queueA)
	registerStoreJobCodec(queueB)

	var claimedID string
	WithDatabase(dbA, func() {
		ResetQueue(queueA)
		EnqueueJob(queueA, storeJob{Name: "dead", Count: FromInt64(1)})
		ProcessNextJob(queueA, failJob)
		id, _, attempts, token, found := queueA.dequeue(jobDead)
		if !found || attempts != 1 || token == "" {
			t.Fatalf("dead claim: found=%v attempts=%d token=%q", found, attempts, token)
		}
		claimedID = id
		db := dbA.bound()
		rows := PgQuery(db, "select status from "+db.QualifiedTable(jobsTable)+" where id = $1",
			[]any{id}, scanText)
		if len(rows) != 1 || rows[0] != jobDeadProcessing {
			t.Fatalf("claimed dead job status = %v", rows)
		}
		PgExec(db, "update "+db.QualifiedTable(jobsTable)+
			" set locked_at = now() - interval '1 day', lease_until = now() - interval '1 day' where id = $1", []any{id})
	})
	WithDatabase(dbB, func() {
		backend := queueB.backend.(*pgQueueBackend)
		backend.lastReclaim.Store(0)
		if _, _, _, _, found := queueB.dequeue(jobPending); found {
			t.Fatal("a reclaimed dead-letter claim entered the normal pending queue")
		}
		expectInt(t, "dead after reclaim", DeadJobCount(queueB), 1)
		id, payload, attempts, token, found := queueB.dequeue(jobDead)
		if !found || id != claimedID || attempts != 1 || token == "" {
			t.Fatalf("reclaimed dead claim: id=%q found=%v attempts=%d token=%q", id, found, attempts, token)
		}
		if job, ok := payload.(storeJob); !ok || job.Name != "dead" {
			t.Fatalf("payload after dead reclaim: %#v", payload)
		}
		if !queueB.complete(id, token) {
			t.Fatal("the reclaimed dead job could not be completed")
		}
	})
}

// If reclamation fences a dead worker while its handler is still running, its completion must
// not disappear silently. workerIteration reports the lost ownership as a store failure and the
// reclaimed row remains available to another dead-letter worker.
func TestDurableDeadWorkerSurfacesAFencedCompletion(t *testing.T) {
	database := storeDatabase(t, "DeadFence")
	queue := NewQueueOn(database, uniqueName("dead_fence"), 1, "", 0)
	registerStoreJobCodec(queue)
	WithDatabase(database, func() {
		ResetQueue(queue)
		EnqueueJob(queue, storeJob{Name: "fenced", Count: FromInt64(1)})
		ProcessNextJob(queue, failJob)
		handlerEntered := make(chan struct{})
		releaseHandler := make(chan struct{})
		type iterationResult struct {
			outcome JobOutcome
			ok      bool
		}
		result := make(chan iterationResult, 1)
		var iteration iterationResult
		reported := captureStderr(t, func() {
			go func() {
				outcome, ok := workerIteration(queue, func(any) JobOutcome {
					close(handlerEntered)
					<-releaseHandler
					return JobOutcome{OK: true}
				}, true)
				result <- iterationResult{outcome: outcome, ok: ok}
			}()
			<-handlerEntered
			db := database.bound()
			table := db.QualifiedTable(jobsTable)
			PgExec(db, "update "+table+" set locked_at = now() - interval '1 day', lease_until = now() - interval '1 day' "+
				"where queue = $1 and status = 'dead_processing'", []any{queue.name})
			backend := queue.backend.(*pgQueueBackend)
			backend.lastReclaim.Store(0)
			backend.reclaimStuck(db, table)
			close(releaseHandler)
			iteration = <-result
		})
		if iteration.ok || iteration.outcome.Ran {
			t.Fatalf("fenced dead completion was not surfaced as a store failure: %+v", iteration)
		}
		if !strings.Contains(reported, "dead-letter completion lost ownership") {
			t.Fatalf("fenced dead completion was not reported: %q", reported)
		}
		expectInt(t, "dead after fenced completion", DeadJobCount(queue), 1)
		if outcome := ProcessNextDeadJob(queue, okJob); !outcome.Ran || !outcome.OK {
			t.Fatalf("the reclaimed dead job was not available to its replacement worker: %+v", outcome)
		}
	})
}

// A worker whose lease was replaced cannot complete or retry the replacement's active
// attempt. The row id is deliberately the same across both claims; only the token fences it.
func TestDurableQueueRejectsOutcomesFromAStaleClaim(t *testing.T) {
	database := storeDatabase(t, "QueueFence")
	queue := NewQueueOn(database, uniqueName("queue_fence"), 3, "", 0)
	registerStoreJobCodec(queue)
	WithDatabase(database, func() {
		ResetQueue(queue)
		EnqueueJob(queue, storeJob{Name: "leased", Count: FromInt64(1)})
		id, _, attempts, oldToken, found := queue.dequeue(jobPending)
		if !found || oldToken == "" {
			t.Fatalf("first claim: found=%v token=%q", found, oldToken)
		}

		db := database.bound()
		table := db.QualifiedTable(jobsTable)
		PgExec(db, "update "+table+" set locked_at = now() - interval '1 day', lease_until = now() - interval '1 day' where id = $1", []any{id})
		backend := queue.backend.(*pgQueueBackend)
		backend.lastReclaim.Store(0)
		backend.reclaimStuck(db, table)
		againID, _, againAttempts, newToken, found := queue.dequeue(jobPending)
		if !found || againID != id || newToken == "" || newToken == oldToken {
			t.Fatalf("replacement claim: id=%q token=%q, old id=%q token=%q", againID, newToken, id, oldToken)
		}
		if queue.complete(id, oldToken) {
			t.Fatal("stale completion deleted the replacement claim")
		}
		if queue.fail(id, attempts, oldToken) {
			t.Fatal("stale failure changed the replacement claim")
		}
		rows := PgQuery(db, "select status, claim_token, attempts from "+table+" where id = $1",
			[]any{id}, func(row pgx.CollectableRow) ([3]string, error) {
				var status, token string
				var attempts int32
				err := row.Scan(&status, &token, &attempts)
				return [3]string{status, token, strconv.Itoa(int(attempts))}, err
			})
		if len(rows) != 1 || rows[0] != [3]string{jobProcessing, newToken, strconv.Itoa(againAttempts)} {
			t.Fatalf("replacement changed by stale outcomes: %+v", rows)
		}
		if !queue.complete(id, newToken) {
			t.Fatal("the current claim could not complete its job")
		}
	})
}

// (f) A row whose job_type has no codec — written by a build that knew a type this one does
// not — is quarantined in the dead letter with a stderr line: not dropped, not a panic, and
// not a hot loop for either worker.
func TestDurableQueueQuarantinesAnUnknownJobType(t *testing.T) {
	database := storeDatabase(t, "Unknown")
	queue := NewQueueOn(database, uniqueName("unknown"), 3, "", 0)
	registerStoreJobCodec(queue)
	WithDatabase(database, func() {
		ResetQueue(queue)
		db := database.bound()
		PgExec(db, "insert into "+db.QualifiedTable(jobsTable)+
			" (id, queue, job_type, payload, status) values ($1, $2, 'Mystery', '{}'::jsonb, 'pending')",
			[]any{UUIDv7(), queue.name})
		EnqueueJob(queue, storeJob{Name: "after it", Count: FromInt64(2)})

		ran := 0
		reported := captureStderr(t, func() {
			for range 3 {
				if outcome := ProcessNextJob(queue, okJob); outcome.Ran {
					ran++
				}
			}
		})
		if ran != 1 {
			t.Fatalf("the decodable job behind the unknown one ran %d times", ran)
		}
		if !strings.Contains(reported, "Mystery") || !strings.Contains(reported, "quarantined") {
			t.Fatalf("stderr did not name the quarantined job: %q", reported)
		}
		if strings.Count(reported, "quarantined") != 1 {
			t.Fatalf("the unknown job was reported more than once: %q", reported)
		}
		expectInt(t, "pending", PendingJobCount(queue), 0)
		expectInt(t, "dead", DeadJobCount(queue), 1)
		if dead := DeadJobs(queue); len(dead) != 1 {
			t.Fatalf("dead letter: %+v", dead)
		}
		// The dead-letter worker cannot run it either, and does not spin on it.
		if outcome := ProcessNextDeadJob(queue, okJob); outcome.Ran {
			t.Fatal("an undecodable dead job was handed to the dead-letter worker")
		}
		expectInt(t, "still dead", DeadJobCount(queue), 1)
	})
}

// (g) A payload round-trips through its codec: the string and an Int past 2^53 come back
// exactly as they went in.
func TestDurableQueuePayloadRoundTrip(t *testing.T) {
	database := storeDatabase(t, "RoundTrip")
	queue := NewQueueOn(database, uniqueName("roundtrip"), 1, "", 0)
	registerStoreJobCodec(queue)
	large := FromInt64(1 << 60)
	WithDatabase(database, func() {
		ResetQueue(queue)
		EnqueueJob(queue, storeJob{Name: "précis \"quoted\"", Count: large})
		outcome := ProcessNextJob(queue, func(payload any) JobOutcome {
			job, ok := payload.(storeJob)
			if !ok {
				return JobOutcome{Message: fmt.Sprintf("payload is %T", payload)}
			}
			if job.Name != "précis \"quoted\"" || !Equal(job.Count, large) {
				return JobOutcome{Message: fmt.Sprintf("payload changed: %+v", job)}
			}
			return JobOutcome{OK: true}
		})
		if !outcome.Ran || !outcome.OK {
			t.Fatalf("round trip: %+v", outcome)
		}
	})
}

// A queue carrying two job types finds each payload's codec and dispatches the typed value.
func TestDurableQueueCarriesSeveralJobTypes(t *testing.T) {
	type otherJob struct{ Flag bool }
	database := storeDatabase(t, "Multi")
	queue := NewQueueOn(database, uniqueName("multi"), 1, "", 0)
	registerStoreJobCodec(queue)
	RegisterJobCodec(queue, "OtherJob",
		func(value any) any {
			return map[string]any{"flag": value.(otherJob).Flag} //nolint:forcetypeassert // the emitter's shape
		},
		func(raw any) (any, error) {
			flag, err := DecodeBoolField(raw, "flag")
			return otherJob{Flag: flag}, err
		})
	WithDatabase(database, func() {
		ResetQueue(queue)
		EnqueueJob(queue, otherJob{Flag: true})
		EnqueueJob(queue, storeJob{Name: "second", Count: FromInt64(2)})
		EnqueueJob(queue, otherJob{Flag: false})
		types := []string{}
		DrainQueue(queue, func(payload any) JobOutcome {
			types = append(types, fmt.Sprintf("%T", payload))
			return JobOutcome{OK: true}
		}, 10)
		if len(types) != 3 || !strings.HasSuffix(types[0], "otherJob") || !strings.HasSuffix(types[1], "storeJob") {
			t.Fatalf("dispatched types: %v", types)
		}
	})
}

// ── Outbox ────────────────────────────────────────────────────────────────────

// (h) The outbox: a send in a rolled-back transaction leaves no row; two instances deliver
// each pending message exactly once between them; a failed delivery is counted and backed
// off, and the fifth failure is dead.
func TestDurableOutboxIsTransactionalAndExactlyOnce(t *testing.T) {
	database := storeDatabase(t, "Mail")
	outboxA := NewOutboxOn(database, testSettings("smtp.example.com", 25))
	outboxB := NewOutboxOn(database, testSettings("smtp.example.com", 25))

	WithDatabase(database, func() {
		ResetOutbox(outboxA)
		func() {
			defer func() { _ = recover() }()
			WithTransaction(func() {
				SendEmail(outboxA, "lost@example.com", "Rolled back", TextBody("never sent"))
				panic("boom")
			})
		}()
		if messages := OutboxMessages(outboxA); len(messages) != 0 {
			t.Fatalf("a rolled-back send left a row: %+v", messages)
		}
		WithTransaction(func() {
			SendEmail(outboxA, "kept@example.com", "Committed", HTMLBody("<b>hi</b>"))
		})
		messages := OutboxMessages(outboxB)
		if len(messages) != 1 || messages[0].To != "kept@example.com" || messages[0].Body.Tag != EmailBodyHTML ||
			messages[0].Body.HTML != "<b>hi</b>" || messages[0].Status != EmailPending {
			t.Fatalf("committed send as B sees it: %+v", messages)
		}
		ResetOutbox(outboxA)

		const total = 3*emailClaimBatch + 7
		for index := range total {
			SendEmail(outboxA, fmt.Sprintf("user%03d@example.com", index), "Hello", TextBody("body"))
		}
		var mutex sync.Mutex
		delivered := map[string]int{}
		stub := func(_ SmtpSettings, message EmailMessage) error {
			mutex.Lock()
			delivered[message.To]++
			mutex.Unlock()
			time.Sleep(2 * time.Millisecond)
			return nil
		}
		outboxA.deliver = stub
		outboxB.deliver = stub
		var wait sync.WaitGroup
		for _, outbox := range []*Outbox{outboxA, outboxB} {
			wait.Add(1)
			go func() {
				defer wait.Done()
				deliverPending(outbox)
			}()
		}
		wait.Wait()
		if len(delivered) != total {
			t.Fatalf("%d of %d messages were delivered", len(delivered), total)
		}
		for recipient, times := range delivered {
			if times != 1 {
				t.Fatalf("%s was delivered %d times", recipient, times)
			}
		}
		for _, message := range OutboxMessages(outboxA) {
			if message.Status != EmailSent || message.SentAt.IsZero() {
				t.Fatalf("a delivered message is not marked sent: %+v", message)
			}
		}
		// A second pass finds nothing to do.
		deliverPending(outboxB)
		if len(delivered) != total {
			t.Fatal("a sent message was delivered again")
		}

		// Prune drops sent mail older than the window and keeps the rest.
		PruneSentEmail(outboxA, time.Hour)
		if remaining := len(OutboxMessages(outboxA)); remaining != total {
			t.Fatalf("prune removed fresh mail: %d left", remaining)
		}
		PruneSentEmail(outboxA, 0)
		if remaining := len(OutboxMessages(outboxA)); remaining != 0 {
			t.Fatalf("prune kept old sent mail: %d left", remaining)
		}

		// Failure: attempts, backoff, and dead at the fifth.
		SendEmail(outboxA, "flaky@example.com", "Retry", TextBody("body"))
		outboxA.deliver = func(SmtpSettings, EmailMessage) error { return errors.New("451 try later") }
		db := database.bound()
		table := db.QualifiedTable(outboxTable)
		for attempt := 1; attempt < emailMaxAttempts; attempt++ {
			deliverPending(outboxA)
			message := OutboxMessages(outboxA)[0]
			if message.Status != EmailPending || message.Attempts != attempt {
				t.Fatalf("after failure %d: %+v", attempt, message)
			}
			if !message.NextAttemptAt.After(time.Now().Add(time.Minute)) {
				t.Fatalf("no backoff after failure %d: next at %v", attempt, message.NextAttemptAt)
			}
			// Not due yet: another pass does not touch it.
			deliverPending(outboxA)
			if again := OutboxMessages(outboxA)[0]; again.Attempts != attempt {
				t.Fatalf("a message in backoff was retried: %+v", again)
			}
			PgExec(db, "update "+table+" set next_attempt_at = now()", nil)
		}
		deliverPending(outboxA)
		if final := OutboxMessages(outboxA)[0]; final.Status != EmailDead || final.Attempts != emailMaxAttempts {
			t.Fatalf("after the last failure: %+v", final)
		}
		ResetOutbox(outboxA)

		// No SMTP host configured: the mail waits, as on the memory path.
		unconfigured := NewOutboxOn(database, testSettings("", 0))
		unconfigured.deliver = func(SmtpSettings, EmailMessage) error { t.Fatal("delivered with no host"); return nil }
		SendEmail(unconfigured, "wait@example.com", "Later", TextBody("body"))
		deliverPending(unconfigured)
		if message := OutboxMessages(unconfigured)[0]; message.Status != EmailPending || message.Attempts != 0 {
			t.Fatalf("an unconfigured outbox touched its mail: %+v", message)
		}
		ResetOutbox(unconfigured)
	})
}

// A claimed message another instance abandoned is claimable again after the claim window; a
// fresh claim is not.
func TestDurableOutboxClaimIsExclusive(t *testing.T) {
	database := storeDatabase(t, "Claim")
	outbox := NewOutboxOn(database, testSettings("smtp.example.com", 25))
	WithDatabase(database, func() {
		ResetOutbox(outbox)
		SendEmail(outbox, "one@example.com", "One", TextBody("body"))
		backend, ok := outbox.backend.(*pgOutboxBackend)
		if !ok {
			t.Fatalf("backend is %T", outbox.backend)
		}
		first := backend.claimDue(10)
		if len(first) != 1 {
			t.Fatalf("first claim took %d", len(first))
		}
		if second := backend.claimDue(10); len(second) != 0 {
			t.Fatalf("a claimed message was claimed again: %+v", second)
		}
		db := database.bound()
		PgExec(db, "update "+db.QualifiedTable(outboxTable)+" set locked_at = now() - interval '11 minutes'", nil)
		if third := backend.claimDue(10); len(third) != 1 || third[0].id != first[0].id {
			t.Fatalf("an abandoned claim was not released: %+v", third)
		}
		ResetOutbox(outbox)
	})
}

// SMTP may finish after the claim window and after another worker has reclaimed the row. Its
// old result must not mark sent, increment attempts, or clear the replacement's lock.
func TestDurableOutboxRejectsOutcomesFromAStaleClaim(t *testing.T) {
	database := storeDatabase(t, "EmailFence")
	outbox := NewOutboxOn(database, testSettings("smtp.example.com", 25))
	WithDatabase(database, func() {
		ResetOutbox(outbox)
		SendEmail(outbox, "fenced@example.com", "Fence", TextBody("body"))
		backend := outbox.backend.(*pgOutboxBackend)
		first := backend.claimDue(1)
		if len(first) != 1 || first[0].claimToken == "" {
			t.Fatalf("first claim: %+v", first)
		}
		db := database.bound()
		table := db.QualifiedTable(outboxTable)
		PgExec(db, "update "+table+" set locked_at = now() - interval '11 minutes' where id = $1",
			[]any{int64(first[0].id)})
		second := backend.claimDue(1)
		if len(second) != 1 || second[0].id != first[0].id || second[0].claimToken == "" ||
			second[0].claimToken == first[0].claimToken {
			t.Fatalf("replacement claim: old=%+v new=%+v", first, second)
		}
		if backend.recordOutcome(first[0], nil) {
			t.Fatal("stale success marked the replacement sent")
		}
		if backend.recordOutcome(first[0], errors.New("stale failure")) {
			t.Fatal("stale failure changed the replacement")
		}
		current := OutboxMessages(outbox)
		if len(current) != 1 || current[0].Status != EmailPending || current[0].Attempts != 0 ||
			current[0].claimToken != second[0].claimToken {
			t.Fatalf("replacement changed by stale outcomes: %+v", current)
		}
		if !backend.recordOutcome(second[0], nil) {
			t.Fatal("the current claim could not record its outcome")
		}
	})
}

// ── Cache ─────────────────────────────────────────────────────────────────────

// (i) The cache: a write on instance A reads on instance B; a TTL expires; prefix
// invalidation is literal; reset empties this cache and no other.
func TestDurableCacheIsSharedAndLiteral(t *testing.T) {
	dbA, dbB := storeDatabase(t, "A"), storeDatabase(t, "B")
	name := uniqueName("cache")
	identity := func(s string) any { return s }
	cacheA := NewCacheOn[string](dbA, name, 0, identity, DecodeStringValue)
	cacheB := NewCacheOn[string](dbB, name, 0, identity, DecodeStringValue)
	other := NewCacheOn[string](dbA, name+"_other", 0, identity, DecodeStringValue)

	WithDatabase(dbA, func() {
		CacheReset(cacheA)
		CacheReset(other)
		CacheSet(cacheA, "greeting", "hello")
		CacheSetTTL(cacheA, "short", "lived", FromInt64(1))
		CacheSet(cacheA, "user_1_name", "alice")
		CacheSet(cacheA, "user_%_name", "wild")
		CacheSet(cacheA, "user_x_name", "carol")
		CacheSet(other, "greeting", "elsewhere")
		if len(cacheA.entries) != 0 {
			t.Fatal("a durable set landed in the in-memory map")
		}
	})
	WithDatabase(dbB, func() {
		if hit := CacheGet(cacheB, "greeting"); !hit.IsSomething() || hit.SomethingValue != "hello" {
			t.Fatalf("B does not see A's write: %+v", hit)
		}
		if hit := CacheGet(cacheB, "short"); !hit.IsSomething() || hit.SomethingValue != "lived" {
			t.Fatalf("TTL entry missing before expiry: %+v", hit)
		}
		if CacheGet(cacheB, "missing").IsSomething() {
			t.Fatal("a miss answered a value")
		}
		// `%` is a character, not a wildcard: only the one key with that literal prefix goes.
		CacheInvalidatePrefix(cacheB, "user_%")
		if CacheGet(cacheB, "user_%_name").IsSomething() {
			t.Fatal("the literal-prefix key survived invalidation")
		}
		for _, key := range []string{"user_1_name", "user_x_name"} {
			if !CacheGet(cacheB, key).IsSomething() {
				t.Fatalf("%s was invalidated by a %% read as a wildcard", key)
			}
		}
		CacheInvalidatePrefix(cacheB, "user_")
		for _, key := range []string{"user_1_name", "user_x_name"} {
			if CacheGet(cacheB, key).IsSomething() {
				t.Fatalf("%s survived its prefix invalidation", key)
			}
		}
		CacheSet(cacheB, "overwritten", "first")
		CacheSet(cacheB, "overwritten", "second")
		if hit := CacheGet(cacheB, "overwritten"); hit.SomethingValue != "second" {
			t.Fatalf("overwrite kept the first write: %+v", hit)
		}
		CacheDelete(cacheB, "overwritten")
		if CacheGet(cacheB, "overwritten").IsSomething() {
			t.Fatal("delete left the key")
		}
	})
	time.Sleep(1100 * time.Millisecond)
	WithDatabase(dbA, func() {
		if CacheGet(cacheA, "short").IsSomething() {
			t.Fatal("an expired entry was answered")
		}
		if hit := CacheGet(cacheA, "greeting"); !hit.IsSomething() {
			t.Fatal("an entry with no TTL expired")
		}
		CacheReset(cacheA)
		if CacheGet(cacheA, "greeting").IsSomething() {
			t.Fatal("reset left an entry")
		}
		if hit := CacheGet(other, "greeting"); !hit.IsSomething() || hit.SomethingValue != "elsewhere" {
			t.Fatalf("reset of one cache touched another: %+v", hit)
		}
		CacheReset(other)
	})
}

// A cache of a non-string type goes through its codec both ways, and an entry the codec no
// longer reads is a miss that is removed.
func TestDurableCacheUsesTheValueCodec(t *testing.T) {
	database := storeDatabase(t, "Codec")
	name := uniqueName("intcache")
	cache := NewCacheOn[Int](database, name, 0, func(n Int) any { return n }, DecodeIntValue)
	large := FromInt64(1 << 60)
	WithDatabase(database, func() {
		CacheReset(cache)
		CacheSet(cache, "big", large)
		if hit := CacheGet(cache, "big"); !hit.IsSomething() || !Equal(hit.SomethingValue, large) {
			t.Fatalf("Int did not round-trip: %+v", hit)
		}
		db := database.bound()
		PgExec(db, "update "+db.QualifiedTable(cacheTable)+" set value = '\"not a number\"'::jsonb "+
			"where cache_name = $1 and key = 'big'", []any{name})
		reported := captureStderr(t, func() {
			if CacheGet(cache, "big").IsSomething() {
				t.Fatal("an undecodable entry was answered")
			}
		})
		if !strings.Contains(reported, "cannot be decoded") {
			t.Fatalf("the undecodable entry was not reported: %q", reported)
		}
		counted := PgCount(db, "select count(*) from "+db.QualifiedTable(cacheTable)+" where cache_name = $1",
			[]any{name})
		expectInt(t, "rows after the undecodable read", counted, 0)
	})
}

// A durable queue's workers are woken by NOTIFY, not by polling: an enqueue committed on one
// instance rings the doorbell of a worker idling on another within the notification round
// trip. The fallback poll is set long so a wake within a second proves the notification path.
func TestDurableEnqueueWakesAWorkerOnAnotherInstance(t *testing.T) {
	dbA, dbB := liveDatabase(t), liveDatabase(t)
	name := "wake_" + strings.ToLower(UUIDv7()[:8])
	queueA := NewQueueOn(dbA, name, 1, "", 0)
	queueB := NewQueueOn(dbB, name, 1, "", 0)
	registerStoreJobCodec(queueA)
	registerStoreJobCodec(queueB)
	WithDatabase(dbB, func() {
		ResetQueue(queueB)
		// Drain a stale doorbell ring so the wait below measures the notification.
		select {
		case <-queueB.wake:
		default:
		}
		// B's listener needs to be connected before A publishes; give it a moment.
		deadline := time.Now().Add(5 * time.Second)
		for pubsubFor(dbB).ListenerPID() == 0 && time.Now().Before(deadline) {
			time.Sleep(20 * time.Millisecond)
		}
		if pubsubFor(dbB).ListenerPID() == 0 {
			t.Fatal("B's LISTEN connection did not come up")
		}
	})
	woke := make(chan time.Duration, 1)
	go func() {
		started := time.Now()
		queueB.waitForWork(30 * time.Second)
		woke <- time.Since(started)
	}()
	time.Sleep(100 * time.Millisecond)
	WithDatabase(dbA, func() {
		EnqueueJob(queueA, storeJob{Name: "ring", Count: FromInt64(1)})
	})
	select {
	case elapsed := <-woke:
		if elapsed > 2*time.Second {
			t.Fatalf("worker woke after %v — that is the fallback poll, not the notification", elapsed)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("a worker on another instance was not woken by the enqueue")
	}
	WithDatabase(dbB, func() {
		if outcome := ProcessNextJob(queueB, okJob); !outcome.Ran || !outcome.OK {
			t.Fatalf("B did not run the job A enqueued: %+v", outcome)
		}
	})
}
