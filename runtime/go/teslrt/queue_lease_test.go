package teslrt

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"testing"
	"time"
)

// INV-ATTEMPT; TR-RENEW. These schedules advance by channel messages, not sleeps.
func TestQueueRenewalsStopOnOwnershipLoss(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	ticks := make(chan time.Time)
	calls := make(chan struct{}, 3)
	reported := make(chan error, 1)
	done := make(chan struct{})
	go func() {
		defer close(done)
		count := 0
		queueRenewals(ctx, ticks, func(context.Context) (bool, error) { count++; calls <- struct{}{}; return count < 3, nil }, func(err error) { reported <- err })
	}()
	for range 3 {
		select {
		case ticks <- time.Time{}:
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		}
		select {
		case <-calls:
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		}
	}
	select {
	case err := <-reported:
		if err == nil {
			t.Fatal("ownership loss not reported")
		}
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	select {
	case <-done:
	case <-ctx.Done():
		t.Fatal("renewal continued after losing the claim")
	}
}

func TestQueueRenewalCancellationReleasesInFlightDatabaseCall(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	deadline, finish := context.WithTimeout(context.Background(), time.Second)
	defer finish()
	ticks := make(chan time.Time, 1)
	ticks <- time.Time{}
	entered := make(chan struct{})
	done := make(chan struct{})
	reported := make(chan error, 1)
	go func() {
		defer close(done)
		queueRenewals(ctx, ticks, func(ctx context.Context) (bool, error) { close(entered); <-ctx.Done(); return false, ctx.Err() }, func(err error) { reported <- err })
	}()
	select {
	case <-entered:
	case <-deadline.Done():
		t.Fatal(deadline.Err())
	}
	cancel()
	select {
	case <-done:
	case <-deadline.Done():
		t.Fatal("cancellation did not reach database operation")
	}
	select {
	case err := <-reported:
		t.Fatalf("normal shutdown reported failure: %v", err)
	default:
	}
}

func TestQueueRenewalDatabaseFailureIsReportedOnce(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	ticks := make(chan time.Time, 2)
	ticks <- time.Time{}
	ticks <- time.Time{}
	want := errors.New("connection lost")
	calls, reports := 0, 0
	queueRenewals(ctx, ticks, func(context.Context) (bool, error) { calls++; return false, want }, func(got error) {
		reports++
		if !errors.Is(got, want) {
			t.Errorf("lost error identity: %v", got)
		}
	})
	if calls != 1 || reports != 1 {
		t.Fatalf("calls=%d reports=%d", calls, reports)
	}
}

type leasedTestBackend struct {
	flakyBackend
	started, stopped  int
	beforePersistence func(string)
}

func (b *leasedTestBackend) keepClaim(id, token string) func() {
	b.started++
	var once sync.Once
	return func() { once.Do(func() { b.stopped++ }) }
}

func (b *leasedTestBackend) complete(id, token string) bool {
	if b.beforePersistence != nil {
		b.beforePersistence("complete")
	}
	return b.flakyBackend.complete(id, token)
}
func (b *leasedTestBackend) fail(id string, attempts int, token string) bool {
	if b.beforePersistence != nil {
		b.beforePersistence("fail")
	}
	return b.flakyBackend.fail(id, attempts, token)
}

// A handler and its final store mutation share one renewal lifetime. Store
// failures must still release it while unwinding, without leaking a goroutine.
func TestQueueRenewalCoversPersistence(t *testing.T) {
	for _, dead := range []bool{false, true} {
		for _, handlerFails := range []bool{false, true} {
			for _, storeFails := range []bool{false, true} {
				t.Run(fmt.Sprintf("dead=%v/handler_failure=%v/store_failure=%v", dead, handlerFails, storeFails), func(t *testing.T) {
					inner := NewQueue("lease-inner", 1)
					Enqueue(inner, "payload")
					if dead {
						ProcessNextJob(inner, func(any) JobOutcome { return JobOutcome{OK: false} })
					}
					calls := 0
					backend := &leasedTestBackend{flakyBackend: flakyBackend{inner: inner}}
					backend.beforePersistence = func(kind string) {
						calls++
						if backend.started != 1 || backend.stopped != 0 {
							t.Errorf("renewal stopped before %s: starts=%d stops=%d", kind, backend.started, backend.stopped)
						}
						want := "complete"
						if !dead && handlerFails {
							want = "fail"
						}
						if kind != want {
							t.Errorf("persisted %s, want %s", kind, want)
						}
						if storeFails {
							panic("injected persistence failure")
						}
					}
					queue := NewQueue("lease-outer", 1)
					queue.backend = backend
					outcome, ok := workerIteration(queue, func(any) JobOutcome {
						if handlerFails {
							panic("handler failure")
						}
						return JobOutcome{OK: true}
					}, dead)
					if ok == storeFails || (!storeFails && (!outcome.Ran || outcome.OK == handlerFails)) || calls != 1 || backend.stopped != 1 {
						t.Fatalf("outcome=%+v store_ok=%v calls=%d starts=%d stops=%d", outcome, ok, calls, backend.started, backend.stopped)
					}
				})
			}
		}
	}
}

// Both the success and panic paths eventually stop renewal. A missing stop on
// the panic path would leave a lease alive after the worker exits.
func TestQueueHandlerAlwaysReleasesItsRenewal(t *testing.T) {
	for _, trap := range []bool{false, true} {
		inner := NewQueue("lease-inner", 1)
		backend := &leasedTestBackend{flakyBackend: flakyBackend{inner: inner}}
		queue := NewQueue("lease-outer", 1)
		queue.backend = backend
		Enqueue(queue, "payload")
		out := ProcessNextJob(queue, func(any) JobOutcome {
			if backend.started != 1 || backend.stopped != 0 {
				t.Fatal("handler ran without a live renewal")
			}
			if trap {
				panic("handler trap")
			}
			return JobOutcome{OK: true}
		})
		if !out.Ran || out.OK == trap || backend.stopped != 1 {
			t.Fatalf("outcome=%+v starts=%d stops=%d", out, backend.started, backend.stopped)
		}
		if trap {
			out = ProcessNextDeadJob(queue, okJob)
			if !out.Ran || backend.started != 2 || backend.stopped != 2 {
				t.Fatalf("dead-letter renewal leaked: %+v", out)
			}
		}
	}
}

func TestQueueClaimSequenceRejectsMalformedAndUnboundedTokens(t *testing.T) {
	for _, token := range []string{"", ":1", "uuid", "uuid:", "uuid:0", "uuid:-1", "uuid:9223372036854775808", "uuid:not-an-int"} {
		if _, valid := queueClaimSequence(token); valid {
			t.Fatalf("accepted %q", token)
		}
	}
	for _, seq := range []string{"1", "9223372036854775807"} {
		if value, valid := queueClaimSequence("uuid:" + seq); !valid || value < 1 {
			t.Fatalf("refused legal sequence: %s", seq)
		}
	}
}
