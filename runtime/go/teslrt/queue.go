package teslrt

import (
	"container/heap"
	"fmt"
	"sort"
	"sync"
	"time"
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
//
// BOUND. The store is in-process memory, and an HTTP endpoint that enqueues is a path from
// the network into it; a pending backlog past maxPendingJobs makes `enqueue` trap rather than
// grow without limit. The trap is loud by design — a queue that full is a system that has
// stopped keeping up, and dropping the job silently would hide exactly that.
//
// CLAIM. The oldest pending (or dead) job is found through a min-heap on the sequence number
// rather than a scan of every job, so a claim is O(log n) against a large backlog instead of
// O(n) per claim (quadratic to drain). The heaps are indexes over `jobs`; the map stays the
// record, which is also what the debugger's domain dump reads.
type Queue struct {
	mutex       sync.Mutex
	name        string
	maxAttempts int
	maxPending  int
	nextSeq     int64
	jobs        map[string]*queuedJob
	pendingHeap seqHeap
	deadHeap    seqHeap
	pending     int
	// backend is the DURABLE store, when the declaration names a Postgres-backed database
	// (`NewQueueOn` in pgstores.go attaches it); nil for a Memory queue. Every public
	// operation asks `durable()` first and falls through to the in-memory store above when
	// the backend is absent OR its database is not bound — a `test` block without
	// `with database` keeps running on memory, a served program bound by `main`'s App
	// runs against the table.
	backend queueBackend
	// wake is the worker doorbell: a buffered(1) channel `Enqueue` (and, for a durable
	// queue, the LISTEN loop on a `tesl_queue` notification from any instance) signals, and
	// an idle worker waits on with a fallback timeout — so a job is picked up within the
	// notification round trip rather than at the next poll, and an idle queue costs no
	// polling. tesl/queue.rkt did the same with a semaphore fed by a LISTEN thread.
	wake chan struct{}
}

// queueBackend is what a durable job store answers. The interface is deliberately the
// in-memory store's own vocabulary (status strings, attempts, DeadJob values) so the
// public functions below dispatch with one `if` and neither path grows a semantics of its
// own. It names no driver type: this file ships with every program, the Postgres
// implementation (pgstores.go) only with one that declares a Postgres database.
type queueBackend interface {
	// active reports whether the store's database is bound right now.
	active() bool
	enqueue(payload any) string
	dequeue(status string) (id string, payload any, attempts int, claimToken string, found bool)
	complete(id, claimToken string) bool
	fail(id string, attempts int, claimToken string) bool
	count(status string) int
	deadJobs(queue *Queue) []DeadJob
	requeue(id string) bool
	reset()
}

// durable answers the backend this call runs against, or nil for the in-memory path.
func (queue *Queue) durable() queueBackend {
	if backend := queue.backend; backend != nil && backend.active() {
		return backend
	}
	return nil
}

type queuedJob struct {
	id       string
	payload  any
	status   string // "pending" | "processing" | "dead" | "dead_processing"
	attempts int
	seq      int64
}

// JobStatus values a test can ask about.
const (
	jobPending    = "pending"
	jobProcessing = "processing"
	jobDead       = "dead"
	// A distinct in-flight state preserves which queue a stale claim must return to.
	jobDeadProcessing = "dead_processing"
)

// maxPendingJobs bounds one Memory queue's pending backlog.
const maxPendingJobs = 100000

// seqHeap orders jobs by sequence number, oldest first. An entry is claimed lazily: a job
// whose status no longer matches the heap it sits in (it was reset, or requeued out of the
// dead letter) is skipped when it surfaces, which keeps every transition O(log n) with no
// index bookkeeping.
type seqHeap []*queuedJob

func (h seqHeap) Len() int           { return len(h) }
func (h seqHeap) Less(i, j int) bool { return h[i].seq < h[j].seq }
func (h seqHeap) Swap(i, j int)      { h[i], h[j] = h[j], h[i] }
func (h *seqHeap) Push(x any)        { *h = append(*h, x.(*queuedJob)) }
func (h *seqHeap) Pop() (popped any) {
	old := *h
	n := len(old)
	popped = old[n-1]
	// The vacated slot is not nil-ed: nilaway forbids a nil in a slice of `*queuedJob`, and
	// the slot is overwritten by the next push (the backing array is bounded by the heap's
	// high-water mark, which the queue's pending cap bounds in turn).
	*h = old[:n-1]
	return popped
}
func (h *seqHeap) push(job *queuedJob) { heap.Push(h, job) }

// pop answers the oldest job still in `status` and still in the store, discarding stale
// entries on the way.
func (h *seqHeap) pop(jobs map[string]*queuedJob, status string) (*queuedJob, bool) {
	for h.Len() > 0 {
		job := heap.Pop(h).(*queuedJob)
		if current, present := jobs[job.id]; present && current == job && job.status == status {
			return job, true
		}
	}
	return nil, false
}

func NewQueue(name string, maxAttempts int) *Queue {
	if maxAttempts < 1 {
		maxAttempts = 1
	}
	return &Queue{name: name, maxAttempts: maxAttempts, maxPending: maxPendingJobs,
		jobs: map[string]*queuedJob{}, wake: make(chan struct{}, 1)}
}

// Wake rings the worker doorbell without blocking: a doorbell already rung stays rung once.
func (queue *Queue) Wake() {
	select {
	case queue.wake <- struct{}{}:
	default:
	}
}

// waitForWork blocks an idle worker until the doorbell rings or `fallback` elapses — the
// fallback is what catches a notification lost to a reconnecting LISTEN connection.
func (queue *Queue) waitForWork(fallback time.Duration) {
	timer := time.NewTimer(fallback)
	defer timer.Stop()
	select {
	case <-queue.wake:
	case <-timer.C:
	}
}

// Queue metrics, named as tesl/queue.rkt named them so a dashboard survives the backend
// change: a counter per enqueue and per outcome, and the worker's run time.
func queueMetric(name, queue string, delta int64) {
	Counter(name, FromInt64(delta), []Tuple2[string, string]{{Tuple2First: "tesl.queue", Tuple2Second: queue}})
}

// Enqueue stores a payload and answers the new job's id.
//
// The id is a UUID v7, NOT a counter: a process-local counter replayed ids after a restart,
// which let a committed job id collide with a fresh one (the same reasoning as the Racket
// side's move off gensym).
func Enqueue(queue *Queue, payload any) string {
	queueMetric("tesl.queue.enqueued", queue.name, 1)
	if backend := queue.durable(); backend != nil {
		id := backend.enqueue(payload)
		// Local workers wake now; workers on other instances wake on the NOTIFY the
		// backend queued with the row (delivered when the enclosing transaction commits).
		queue.Wake()
		return id
	}
	queue.mutex.Lock()
	defer queue.mutex.Unlock()
	if queue.pending >= queue.maxPending {
		panic(fmt.Sprintf("enqueue: queue %s is full — %d jobs are pending and the in-memory "+
			"store is bounded at %d; workers are not keeping up with producers",
			queue.name, queue.pending, queue.maxPending))
	}
	id := UUIDv7()
	queue.nextSeq++
	job := &queuedJob{id: id, payload: payload, status: jobPending, seq: queue.nextSeq}
	queue.jobs[id] = job
	queue.pendingHeap.push(job)
	queue.pending++
	queue.Wake()
	return id
}

func PendingJobCount(queue *Queue) Int {
	if backend := queue.durable(); backend != nil {
		return FromInt64(int64(backend.count(jobPending)))
	}
	queue.mutex.Lock()
	defer queue.mutex.Unlock()
	return FromInt64(int64(queue.pending))
}

func DeadJobCount(queue *Queue) Int {
	if backend := queue.durable(); backend != nil {
		return FromInt64(int64(backend.count(jobDead)))
	}
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

// dequeue claims the OLDEST job with `status`, marking it processing. The heap hands back
// the job itself, not an id to re-read from the map: a second lookup would be a map read
// whose success only the surrounding lock explains, which is exactly what nilaway (in the
// emitted-code gate) refuses to take on trust.
func (queue *Queue) dequeue(status string) (string, any, int, string, bool) {
	if backend := queue.durable(); backend != nil {
		return backend.dequeue(status)
	}
	queue.mutex.Lock()
	defer queue.mutex.Unlock()
	index := &queue.pendingHeap
	if status == jobDead {
		index = &queue.deadHeap
	}
	job, found := index.pop(queue.jobs, status)
	if !found {
		return "", nil, 0, "", false
	}
	if status == jobPending {
		queue.pending--
	}
	job.status = jobProcessing
	if status == jobDead {
		job.status = jobDeadProcessing
	}
	return job.id, job.payload, job.attempts, "", true
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
	if backend := queue.durable(); backend != nil {
		return backend.deadJobs(queue)
	}
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
	if backend := queue.durable(); backend != nil {
		backend.reset()
		return
	}
	queue.mutex.Lock()
	defer queue.mutex.Unlock()
	queue.jobs = map[string]*queuedJob{}
	queue.pendingHeap = nil
	queue.deadHeap = nil
	queue.pending = 0
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
// The retry BACKOFF delay is deliberately not simulated on the in-memory path: the in-memory
// Racket path does not sleep either, and a test that had to wait for an exponential backoff
// would be a slow test rather than a truthful one. The durable store applies it as the row's
// `next_attempt_at` (pgstores.go), which the claim respects.
func ProcessNextJob(queue *Queue, handler func(any) JobOutcome) JobOutcome {
	id, payload, attempts, claimToken, found := queue.dequeue(jobPending)
	if !found {
		return JobOutcome{}
	}
	started := time.Now()
	outcome := runJob(handler, payload)
	Histogram("tesl.queue.job.duration", time.Since(started).Seconds(),
		[]Tuple2[string, string]{{Tuple2First: "tesl.queue", Tuple2Second: queue.name}})
	if outcome.OK {
		if queue.complete(id, claimToken) {
			queueMetric("tesl.queue.completed", queue.name, 1)
		}
	} else {
		if queue.fail(id, attempts, claimToken) {
			queueMetric("tesl.queue.failed", queue.name, 1)
		}
	}
	outcome.Ran = true
	return outcome
}

// ProcessNextDeadJob is the dead-letter counterpart: it claims a job that exhausted its
// attempts and hands it to the dead-letter worker. A dead job is REMOVED whatever the handler
// outcome — there is no second dead letter to fall into. A fenced completion is a store failure,
// not a handler outcome, and is surfaced so the replacement claim is not mistaken for removal.
func ProcessNextDeadJob(queue *Queue, handler func(any) JobOutcome) JobOutcome {
	id, payload, _, claimToken, found := queue.dequeue(jobDead)
	if !found {
		return JobOutcome{}
	}
	outcome := runJob(handler, payload)
	if !queue.complete(id, claimToken) {
		panic("queue " + queue.name + ": dead-letter completion lost ownership of job " + id)
	}
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

func (queue *Queue) complete(id, claimToken string) bool {
	if backend := queue.durable(); backend != nil {
		return backend.complete(id, claimToken)
	}
	queue.mutex.Lock()
	defer queue.mutex.Unlock()
	if _, found := queue.jobs[id]; !found {
		return false
	}
	delete(queue.jobs, id)
	return true
}

func (queue *Queue) fail(id string, attempts int, claimToken string) bool {
	if backend := queue.durable(); backend != nil {
		return backend.fail(id, attempts, claimToken)
	}
	queue.mutex.Lock()
	defer queue.mutex.Unlock()
	job, found := queue.jobs[id]
	if !found {
		return false
	}
	job.attempts = attempts + 1
	if job.attempts >= queue.maxAttempts {
		job.status = jobDead
		queue.deadHeap.push(job)
	} else {
		// The job keeps its sequence number, so a retry goes back to the FRONT of the
		// line — the order the scan-based claim always had.
		job.status = jobPending
		queue.pendingHeap.push(job)
		queue.pending++
	}
	return true
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
//
// "There" means IN the dead letter: a job a dead-letter worker has already claimed is in
// flight, and resetting it to pending would run it twice — once more by an ordinary worker,
// while the dead-letter worker's completion then deleted whichever copy was left. So an
// in-flight job answers `False` too: from the dead letter's point of view it has left.
func Requeue(job DeadJob) bool {
	if job.queue == nil {
		return false
	}
	if backend := job.queue.durable(); backend != nil {
		return backend.requeue(job.ID)
	}
	job.queue.mutex.Lock()
	defer job.queue.mutex.Unlock()
	found, present := job.queue.jobs[job.ID]
	if !present || found.status != jobDead {
		return false
	}
	found.status = jobPending
	found.attempts = 0
	job.queue.pendingHeap.push(found)
	job.queue.pending++
	return true
}
