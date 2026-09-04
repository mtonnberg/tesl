package teslrt

import (
	"sync/atomic"
	"testing"
	"time"
)

// A backend that traps on every operation until told otherwise: the shape of an unreachable
// database or a timed-out lease.
type flakyBackend struct {
	inner  *Queue
	broken atomic.Bool
	claims atomic.Int64
}

func (b *flakyBackend) trapIfBroken() {
	if b.broken.Load() {
		panic(RequestRejection{Status: 503, Message: "database busy, try again"})
	}
}
func (b *flakyBackend) active() bool { return true }
func (b *flakyBackend) enqueue(payload any) string {
	b.trapIfBroken()
	return Enqueue(b.inner, payload)
}
func (b *flakyBackend) complete(id, claimToken string) bool {
	b.trapIfBroken()
	return b.inner.complete(id, claimToken)
}
func (b *flakyBackend) fail(id string, attempts int, claimToken string) bool {
	b.trapIfBroken()
	return b.inner.fail(id, attempts, claimToken)
}
func (b *flakyBackend) count(status string) int         { return b.inner.countWithStatus(status) }
func (b *flakyBackend) deadJobs(queue *Queue) []DeadJob { return []DeadJob{} }
func (b *flakyBackend) requeue(id string) bool          { return false }
func (b *flakyBackend) reset()                          { ResetQueue(b.inner) }
func (b *flakyBackend) dequeue(status string) (string, any, int, string, bool) {
	b.claims.Add(1)
	b.trapIfBroken()
	return b.inner.dequeue(status)
}

// A store failure must not unwind the worker goroutine — as an unrecovered panic it took the
// whole process down, HTTP server included. The worker reports, backs off, and resumes once
// the store answers again.
func TestWorkerSurvivesAStoreFailureAndResumes(t *testing.T) {
	inner := NewQueue("flaky-inner", 1)
	backend := &flakyBackend{inner: inner}
	backend.broken.Store(true)
	queue := NewQueue("flaky", 1)
	queue.backend = backend

	var ran atomic.Int64
	startWorkers(queue, func(any) JobOutcome { ran.Add(1); return JobOutcome{OK: true} }, 1, false, nil)

	// The store traps on the first claim; the goroutine must still be alive to ring later.
	deadline := time.Now().Add(2 * time.Second)
	for backend.claims.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if backend.claims.Load() == 0 {
		t.Fatal("the worker never attempted a claim")
	}
	backend.broken.Store(false)
	Enqueue(inner, "job") // straight into the inner store; the doorbell is the queue's
	queue.Wake()
	deadline = time.Now().Add(5 * time.Second)
	for ran.Load() == 0 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if ran.Load() != 1 {
		t.Fatalf("worker did not resume after the store recovered (ran=%d)", ran.Load())
	}
}

func TestWorkerBackoffIsBoundedAndGrows(t *testing.T) {
	if workerBackoff(1) != time.Second || workerBackoff(2) != 2*time.Second || workerBackoff(3) != 4*time.Second {
		t.Fatalf("backoff = %v %v %v", workerBackoff(1), workerBackoff(2), workerBackoff(3))
	}
	if workerBackoff(50) != 30*time.Second {
		t.Fatalf("backoff cap = %v", workerBackoff(50))
	}
}
