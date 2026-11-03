package teslrt

import (
	"context"
	"fmt"
	"os"
	"time"
)

// StartWorkers activates a queue's workers: `concurrency` goroutines, each claiming and running
// one job at a time. `dead` selects the dead-letter worker instead of the ordinary one.
func StartWorkers(queue *Queue, handler func(any) JobOutcome, concurrency int, dead bool) struct{} {
	return startWorkers(queue, handler, concurrency, dead, nil)
}

func startWorkers(queue *Queue, handler func(any) JobOutcome, concurrency int, dead bool, activity func(bool)) struct{} {
	if concurrency < 1 {
		concurrency = 1
	}
	scope := currentRuntimeWorkers()
	ctx := context.Background()
	if scope != nil {
		ctx = scope.context()
	}
	for range concurrency {
		run := func() {
			failures := 0
			for scope == nil || scope.beginIteration() {
				if activity != nil {
					activity(true)
				}
				outcome, ok := workerIteration(queue, handler, dead)
				if !ok {
					// Store failures retain their existing retry behavior; shutdown
					// interrupts this wait without canceling an active handler.
					failures++
					queue.waitForWorker(ctx, workerBackoff(failures))
				} else {
					failures = 0
					if !outcome.Ran {
						queue.waitForWorker(ctx, queue.idleInterval())
					}
				}
				if activity != nil {
					activity(false)
				}
			}
		}
		if scope == nil {
			go run()
		} else {
			scope.start(run)
		}
	}
	return struct{}{}
}

// workerIteration claims and runs one job, answering ok=false when the STORE trapped (the
// job's own trap is already a JobOutcome). The trap is reported once per occurrence.
func workerIteration(queue *Queue, handler func(any) JobOutcome, dead bool) (outcome JobOutcome, ok bool) {
	defer func() {
		if trap := recover(); trap != nil {
			fmt.Fprintf(os.Stderr, "tesl: queue %s: worker could not reach the job store: %v\n",
				queue.name, trap)
			outcome, ok = JobOutcome{}, false
		}
	}()
	if dead {
		return ProcessNextDeadJob(queue, handler), true
	}
	return ProcessNextJob(queue, handler), true
}

// workerBackoff is how long a worker waits after `failures` consecutive store failures:
// 1 s, 2 s, 4 s … capped at 30 s, and cut short by the doorbell like any other wait.
func workerBackoff(failures int) time.Duration {
	wait := time.Second << min(failures-1, 5)
	if wait > 30*time.Second {
		return 30 * time.Second
	}
	return wait
}

// idleInterval is how long a worker that found nothing waits before asking again. Against
// the in-memory store a claim is a mutex and a heap pop, so 50 ms keeps a test's turnaround
// short; against a durable store every claim is a round trip to the server, and N workers
// each polling twenty times a second is a steady load for an idle queue, so one second.
func (queue *Queue) idleInterval() time.Duration {
	// The FALLBACK wait: the doorbell (`Enqueue` locally, a `tesl_queue` NOTIFY from any
	// instance) wakes a worker earlier. Against the durable store the poll is only insurance
	// against a notification lost while the LISTEN connection reconnects — tesl/queue.rkt's
	// poller used the same five seconds.
	if queue.durable() != nil {
		return 5 * time.Second
	}
	return 50 * time.Millisecond
}

// A scoped worker must wake even if no job arrives and its normal polling/backoff
// interval is long. The ordinary unscoped Memory loop keeps a Background context.
func (queue *Queue) waitForWorker(ctx context.Context, fallback time.Duration) {
	if ctx.Done() == nil {
		queue.waitForWork(fallback)
		return
	}
	timer := time.NewTimer(fallback)
	defer timer.Stop()
	select {
	case <-ctx.Done():
	case <-queue.wake:
	case <-timer.C:
	}
}
