package teslrt

import (
	"context"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func workerLifetimeReceive[T any](t *testing.T, ch <-chan T) T {
	t.Helper()
	select {
	case value := <-ch:
		return value
	case <-time.After(5 * time.Second):
		t.Fatal("worker lifecycle did not reach expected boundary")
		var zero T
		return zero
	}
}

func TestWorkerLifetimeIdleCancellationAndFreshScope(t *testing.T) {
	database := NewDatabase("scope", PostgresConfig{}, nil)
	connection := &PostgresDB{}
	queue := NewQueue("idle", 1)
	for range 2 {
		done := make(chan any, 1)
		started := make(chan *runtimeWorkerScope, 1)
		go func() {
			done <- pgFacilityPanic(func() {
				withDatabaseBinding(database, connection, func() {
					group := boundDatabaseScope.Load().workers
					StartWorkers(queue, func(any) JobOutcome { panic("idle worker unexpectedly claimed") }, 3, false)
					started <- group
					<-group.ctx.Done()
					// Cancellation during user startup must also reach Serve.
					Serve(Server{}, ServeOptions{Port: -1, ListenAddress: "127.0.0.1"})
				})
			})
		}()
		group := workerLifetimeReceive(t, started)
		if group.ctx.Err() != nil {
			t.Fatal("previous scope poisoned successor")
		}
		group.cancel()
		if err := workerLifetimeReceive(t, done); err != nil {
			t.Fatal(err)
		}
		if database.bound() != nil || currentRuntimeWorkers() != nil {
			t.Fatal("scope survived join")
		}
	}
	// Ordinary unbound Memory operations keep their established behavior.
	Enqueue(queue, "memory")
	if !ProcessNextJob(queue, func(any) JobOutcome { return JobOutcome{OK: true} }).OK {
		t.Fatal("Memory dispatch changed")
	}
}

func TestWorkerLifetimeRegistrationClosesAtomically(t *testing.T) {
	group := newRuntimeWorkerScope(context.Background(), goroutineID)
	var waiting sync.WaitGroup
	release := make(chan struct{})
	var count atomic.Int64
	for range 50 {
		waiting.Go(func() { group.start(func() { count.Add(1); <-release }) })
	}
	waiting.Wait()
	joined := make(chan struct{})
	go func() { group.join(); close(joined) }()
	<-group.ctx.Done()
	group.start(func() { t.Error("worker registered after closure") })
	close(release)
	workerLifetimeReceive(t, joined)
	if count.Load() != 50 {
		t.Fatal(count.Load())
	}
}

func TestWorkerLifetimeNestedRebindingCannotHideOuterWorkers(t *testing.T) {
	database := NewDatabase("outer", PostgresConfig{}, nil)
	connection := &PostgresDB{}
	other := NewDatabase("other", PostgresConfig{}, nil)
	queue := NewQueue("nested", 1)
	Enqueue(queue, "one")
	entered, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	unblock := func() { once.Do(func() { close(release) }) }
	defer unblock()
	withDatabaseBinding(database, connection, func() {
		StartWorkers(queue, func(any) JobOutcome { close(entered); <-release; return JobOutcome{OK: true} }, 1, false)
		workerLifetimeReceive(t, entered)
		withDatabaseBinding(database, connection, func() {
			failure := pgFacilityPanic(func() { withDatabaseBinding(other, &PostgresDB{}, func() { t.Error("other binding became active") }) })
			if failure == nil {
				t.Error("nested scope hid outer workers")
			}
			if boundDatabase.Load() != database || database.bound() != connection {
				t.Error("refused rebind changed current database")
			}
		})
		unblock()
	})
}

func TestWorkerLifetimeRegistrationSuspendedAcrossOtherBinding(t *testing.T) {
	database := NewDatabase("outer", PostgresConfig{}, nil)
	withDatabaseBinding(database, &PostgresDB{}, func() {
		outer := boundDatabaseScope.Load().workers
		withDatabaseBinding(NewDatabase("nested", PostgresConfig{}, nil), &PostgresDB{}, func() {
			if pgFacilityPanic(func() { outer.start(func() {}) }) == nil {
				t.Fatal("old scope registered across a changed binding")
			}
		})
		called := make(chan struct{})
		outer.start(func() { close(called) })
		workerLifetimeReceive(t, called)
	})
}

func TestWorkerLifetimeScopePanicJoinsActiveHandler(t *testing.T) {
	database := NewDatabase("panic", PostgresConfig{}, nil)
	connection := &PostgresDB{}
	queue := NewQueue("panic", 1)
	Enqueue(queue, "one")
	entered, release := make(chan struct{}), make(chan struct{})
	done := make(chan any, 1)
	var once sync.Once
	unblock := func() { once.Do(func() { close(release) }) }
	defer unblock()
	go func() {
		done <- pgFacilityPanic(func() {
			withDatabaseBinding(database, connection, func() {
				StartWorkers(queue, func(any) JobOutcome {
					close(entered)
					<-release
					if database.bound() != connection {
						panic("binding lost")
					}
					return JobOutcome{OK: true}
				}, 1, false)
				<-entered
				panic("application startup failed")
			})
		})
	}()
	workerLifetimeReceive(t, entered)
	select {
	case <-done:
		t.Fatal("panic released live worker binding")
	case <-time.After(20 * time.Millisecond):
	}
	unblock()
	if err := workerLifetimeReceive(t, done); fmt.Sprint(err) != "application startup failed" {
		t.Fatal(err)
	}
	if PendingJobCount(queue).String() != "0" {
		t.Fatal("worker completion did not finish")
	}
}

// A real production StartWorkers loop reaches the durable five-second idle
// branch. Cancellation must join it promptly without a job notification.
type workerLifetimeIdleBackend struct {
	queueBackend
	once    sync.Once
	claimed chan struct{}
}

func (backend *workerLifetimeIdleBackend) active() bool { return true }
func (backend *workerLifetimeIdleBackend) dequeue(string) (string, any, int, string, bool) {
	backend.once.Do(func() { close(backend.claimed) })
	return "", nil, 0, "", false
}
func TestWorkerLifetimeCancellationInterruptsDurableIdleWait(t *testing.T) {
	database := NewDatabase("idle", PostgresConfig{}, nil)
	queue := NewQueue("idle", 1)
	backend := &workerLifetimeIdleBackend{claimed: make(chan struct{})}
	queue.backend = backend
	done := make(chan any, 1)
	started := make(chan *runtimeWorkerScope, 1)
	go func() {
		done <- pgFacilityPanic(func() {
			withDatabaseBinding(database, &PostgresDB{}, func() {
				scope := boundDatabaseScope.Load().workers
				StartWorkers(queue, func(any) JobOutcome { panic("empty store") }, 1, false)
				started <- scope
				<-scope.ctx.Done()
			})
		})
	}()
	scope := workerLifetimeReceive(t, started)
	workerLifetimeReceive(t, backend.claimed)
	scope.cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("worker waited for its five-second idle interval")
	}
}
