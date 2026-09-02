package teslrt

import (
	"fmt"
	"sort"
	"sync"
)

// An in-memory job queue: the `backend: Memory` counterpart of tesl/queue.rkt's store.
//
// Jobs are dequeued in ENQUEUE ORDER. That is parity, not a detail: Racket's store is a
// hash keyed by job id, and dequeuing it in hash order was a real bug (the PostgreSQL path
// is `order by created_at asc`), fixed there with a monotonic sequence number. This store
// keeps the sequence for the same reason.
//
// A payload is held as `any` because one queue may carry several job types; the emitter
// knows them statically and passes a dispatcher that type-switches.
type Queue struct {
	mutex       sync.Mutex
	name        string
	maxAttempts int
	nextSeq     int64
	jobs        map[string]*queuedJob
}

type queuedJob struct {
	payload  any
	status   string // "pending" | "processing" | "dead"
	attempts int
	seq      int64
}

// JobStatus values a test can ask about.
const (
	jobPending    = "pending"
	jobProcessing = "processing"
	jobDead       = "dead"
)

func NewQueue(name string, maxAttempts int) *Queue {
	if maxAttempts < 1 {
		maxAttempts = 1
	}
	return &Queue{name: name, maxAttempts: maxAttempts, jobs: map[string]*queuedJob{}}
}

// Enqueue stores a payload and answers the new job's id.
//
// The id is a UUID v7, NOT a counter: a process-local counter replayed ids after a restart,
// which let a committed job id collide with a fresh one (the same reasoning as the Racket
// side's move off gensym).
func Enqueue(queue *Queue, payload any) string {
	queue.mutex.Lock()
	defer queue.mutex.Unlock()
	id := UUIDv7()
	queue.nextSeq++
	queue.jobs[id] = &queuedJob{payload: payload, status: jobPending, seq: queue.nextSeq}
	return id
}

func PendingJobCount(queue *Queue) Int {
	return FromInt64(int64(queue.countWithStatus(jobPending)))
}

func DeadJobCount(queue *Queue) Int {
	return FromInt64(int64(queue.countWithStatus(jobDead)))
}

func (queue *Queue) countWithStatus(status string) int {
	queue.mutex.Lock()
	defer queue.mutex.Unlock()
	matched := 0
	for _, job := range queue.jobs {
		if job.status == status {
			matched++
		}
	}
	return matched
}

// dequeue claims the OLDEST job with `status`, marking it processing.
//
// The candidates carry their entry rather than being re-read from the map by id: a second
// lookup would be a map read whose success only the surrounding lock explains, which is
// exactly what nilaway (in the emitted-code gate) refuses to take on trust.
func (queue *Queue) dequeue(status string) (string, any, int, bool) {
	queue.mutex.Lock()
	defer queue.mutex.Unlock()
	type candidate struct {
		id    string
		entry *queuedJob
	}
	candidates := make([]candidate, 0, len(queue.jobs))
	for id, job := range queue.jobs {
		if job.status == status {
			candidates = append(candidates, candidate{id: id, entry: job})
		}
	}
	if len(candidates) == 0 {
		return "", nil, 0, false
	}
	oldest := candidates[0]
	for _, next := range candidates[1:] {
		if next.entry.seq < oldest.entry.seq {
			oldest = next
		}
	}
	oldest.entry.status = jobProcessing
	return oldest.id, oldest.entry.payload, oldest.entry.attempts, true
}

// DeadJob is one entry in a queue's dead letter. It is OPAQUE to Tesl — `deadJobs` is typed
// `List DeadJob` and the type has no accessors — so it carries the job's identity for the
// runtime's use and nothing a program can read: what a test does with the list is count it.
type DeadJob struct {
	ID string
	// The queue the job came out of. `requeue job` names no queue — the value carries it, as
	// Racket's dead-job carries its queue-spec — so this is what makes that call resolvable.
	queue *Queue
}

// DeadJobs is the dead letter's contents, oldest first. The order is by enqueue sequence
// rather than by map iteration, matching the PostgreSQL path's `order by created_at asc`.
func DeadJobs(queue *Queue) []DeadJob {
	queue.mutex.Lock()
	defer queue.mutex.Unlock()
	type entry struct {
		id  string
		seq int64
	}
	found := make([]entry, 0, len(queue.jobs))
	for id, job := range queue.jobs {
		if job.status == jobDead {
			found = append(found, entry{id: id, seq: job.seq})
		}
	}
	sort.Slice(found, func(left, right int) bool { return found[left].seq < found[right].seq })
	dead := make([]DeadJob, 0, len(found))
	for _, each := range found {
		dead = append(dead, DeadJob{ID: each.id, queue: queue})
	}
	return dead
}

// ResetQueue empties the store, for a test block that starts from a fresh queue. The
// sequence counter is deliberately NOT reset: it only has to be monotonic, and a counter that
// restarts is how job ids came to repeat once already.
func ResetQueue(queue *Queue) {
	queue.mutex.Lock()
	defer queue.mutex.Unlock()
	queue.jobs = map[string]*queuedJob{}
}

// JobOutcome is what a worker run produced, for the `expectJobOk` style assertions.
type JobOutcome struct {
	Ran     bool   // a job was claimed at all
	OK      bool   // the worker returned without rejecting or trapping
	Message string // the rejection or trap message, when OK is false
}

// ProcessNextJob runs the next pending job through `handler` and applies the retry rule:
// success completes the job, failure increments attempts and either re-queues it or — once
// attempts reach maxAttempts — moves it to the dead letter. Identical to the Racket
// in-memory path, including that a TRAP counts as a failed attempt rather than propagating.
//
// The retry BACKOFF delay is deliberately not simulated here: the in-memory Racket path
// does not sleep either, and a test that had to wait for an exponential backoff would be a
// slow test rather than a truthful one.
func ProcessNextJob(queue *Queue, handler func(any) JobOutcome) JobOutcome {
	id, payload, attempts, found := queue.dequeue(jobPending)
	if !found {
		return JobOutcome{}
	}
	outcome := runJob(handler, payload)
	if outcome.OK {
		queue.complete(id)
	} else {
		queue.fail(id, attempts)
	}
	outcome.Ran = true
	return outcome
}

// ProcessNextDeadJob is the dead-letter counterpart: it claims a job that exhausted its
// attempts and hands it to the dead-letter worker. A dead job is REMOVED whatever the
// outcome — there is no second dead letter to fall into.
func ProcessNextDeadJob(queue *Queue, handler func(any) JobOutcome) JobOutcome {
	id, payload, _, found := queue.dequeue(jobDead)
	if !found {
		return JobOutcome{}
	}
	outcome := runJob(handler, payload)
	queue.complete(id)
	outcome.Ran = true
	return outcome
}

// DrainQueue processes pending jobs until none remain, and reports how many ran. It stops
// at `limit` attempts so a job that keeps failing back into the queue cannot spin forever.
func DrainQueue(queue *Queue, handler func(any) JobOutcome, limit int) Int {
	ran := 0
	for ran < limit {
		if outcome := ProcessNextJob(queue, handler); !outcome.Ran {
			break
		}
		ran++
	}
	return FromInt64(int64(ran))
}

// A worker that traps is a FAILED ATTEMPT, not a crashed process: the Racket path wraps the
// handler in `with-handlers` and calls fail-job!, so the queue keeps its retry semantics.
func runJob(handler func(any) JobOutcome, payload any) (outcome JobOutcome) {
	defer func() {
		if recovered := recover(); recovered != nil {
			outcome = JobOutcome{OK: false, Message: fmt.Sprint(recovered)}
		}
	}()
	return handler(payload)
}

func (queue *Queue) complete(id string) {
	queue.mutex.Lock()
	defer queue.mutex.Unlock()
	delete(queue.jobs, id)
}

func (queue *Queue) fail(id string, attempts int) {
	queue.mutex.Lock()
	defer queue.mutex.Unlock()
	job, found := queue.jobs[id]
	if !found {
		return
	}
	job.attempts = attempts + 1
	if job.attempts >= queue.maxAttempts {
		job.status = jobDead
	} else {
		job.status = jobPending
	}
}

// JobResult is what an api-test's `processNextJob` answers: the job that ran, and — when
// the worker rejected or trapped — the error alongside it. `JobFailed` carries BOTH, as it
// does on the Racket side (`JobFailed job error`), so a test can assert on the payload of a
// job that failed.
//
// Runtime-provided like Maybe and Either, since a JobResult crosses module boundaries.
type JobResult[Payload any] struct {
	Tag         JobResultTag
	OkJob       Payload
	FailedJob   Payload
	FailedError string
}

type JobResultTag int

const (
	JobResultOk JobResultTag = iota
	JobResultFailed
)

func JobOk[Payload any](job Payload) JobResult[Payload] {
	return JobResult[Payload]{Tag: JobResultOk, OkJob: job}
}

func JobFailed[Payload any](job Payload, failure string) JobResult[Payload] {
	return JobResult[Payload]{Tag: JobResultFailed, FailedJob: job, FailedError: failure}
}

// ExpectJobOk is the api-test assertion: the job, or a trap naming the worker's failure.
func ExpectJobOk[Payload any](result JobResult[Payload]) Payload {
	if result.Tag != JobResultOk {
		panic("expectJobOk: expected JobOk but the worker failed with " + result.FailedError)
	}
	return result.OkJob
}

// ExpectJobFailed is its counterpart: the job that failed, or a trap.
// ExpectJobFailed answers the ERROR, not the job: `tesl/api-test.rkt` returns
// `JobFailed-error` here, and a test written against it (`expect isNotNull err`) reads a
// message rather than a payload. The job is still reachable through the `JobResult` itself.
func ExpectJobFailed[Payload any](result JobResult[Payload]) string {
	if result.Tag != JobResultFailed {
		panic("expectJobFailed: expected JobFailed but the worker succeeded")
	}
	return result.FailedError
}

// EmptyQueue is the trap an api-test gets when it asks for a job and there is none — the
// same failure Racket raises, with the same hint, because the usual cause is that the HTTP
// action meant to enqueue the job did not run.
func EmptyQueue(queueName, who string) string {
	return fmt.Sprintf("%s: queue %s is empty — expected at least one pending job\n"+
		"hint: did the HTTP action that enqueues the job run and return a success status?",
		who, queueName)
}

// EnqueueJob is `enqueue`, whose Tesl type is Unit: the job id is not surfaced to the
// program (Racket's enqueue! answers void too), so the id stays internal to the store.
func EnqueueJob(queue *Queue, payload any) struct{} {
	Enqueue(queue, payload)
	return struct{}{}
}

// Requeue resets a dead job to pending with a fresh attempt count, so the workers pick it up
// again. It answers whether the job was there to reset — a job the dead letter no longer holds
// is `False` rather than a trap, which is Racket's answer for the same case.
func Requeue(job DeadJob) bool {
	if job.queue == nil {
		return false
	}
	job.queue.mutex.Lock()
	defer job.queue.mutex.Unlock()
	found, present := job.queue.jobs[job.ID]
	if !present {
		return false
	}
	found.status = jobPending
	found.attempts = 0
	return true
}
