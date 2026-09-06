package teslrt

import (
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// This wrapper pauses only the public dispatch-to-persistence boundary. Claim,
// renewal, completion and retry still execute the real protected SQL backend.
type workerLifetimePersistenceBackend struct {
	queueBackend
	lease   queueLeaseBackend
	stopped atomic.Bool
	before  func(string)
}

func (b *workerLifetimePersistenceBackend) keepClaim(id, token string) func() {
	stop := b.lease.keepClaim(id, token)
	return sync.OnceFunc(func() { stop(); b.stopped.Store(true) })
}
func (b *workerLifetimePersistenceBackend) complete(id, token string) bool {
	b.before("complete")
	return b.queueBackend.complete(id, token)
}
func (b *workerLifetimePersistenceBackend) fail(id string, attempts int, token string) bool {
	b.before("fail")
	return b.queueBackend.fail(id, attempts, token)
}

func TestQueueRuntimeWorkerLifetimeDrainsBeforeUnbind(t *testing.T) {
	for _, dead := range []bool{false, true} {
		for _, fail := range []bool{false, true} {
			t.Run(fmt.Sprintf("dead=%v/handler_failure=%v", dead, fail), func(t *testing.T) {
				f := pgNewQueueRuntimeTest(t, 3, 3)
				t.Setenv("TESL_QUEUE_VISIBILITY_TIMEOUT_MS", "120")
				entered, release := make(chan struct{}), make(chan struct{})
				persistenceEntered := make(chan string, 1)
				persistenceRelease := make(chan struct{})
				resumePersistence := sync.OnceFunc(func() { close(persistenceRelease) })
				probe := &workerLifetimePersistenceBackend{queueBackend: f.backend, lease: f.backend}
				probe.before = func(kind string) { persistenceEntered <- kind; <-persistenceRelease }
				var once sync.Once
				unblock := func() { once.Do(func() { close(release) }) }
				defer unblock()
				started := make(chan *runtimeWorkerScope, 1)
				finished := make(chan any, 1)
				joined := make(chan struct{})
				var successorJoined chan struct{}
				defer func() {
					unblock()
					resumePersistence()
					workerLifetimeReceive(t, joined)
					if successorJoined != nil {
						workerLifetimeReceive(t, successorJoined)
					}
				}()
				firstID := make(chan string, 1)
				go func() {
					defer close(joined)
					finished <- pgFacilityPanic(func() {
						withDatabaseBinding(f.database, f.db, func() {
							seed := func(message string) string {
								id := Enqueue(f.queue, queueRuntimeJob{message})
								if dead {
									for range 2 {
										ProcessNextJob(f.queue, func(any) JobOutcome { return JobOutcome{OK: false} })
									}
								}
								return id
							}
							firstID <- seed("active")
							seed("leave pending")
							f.queue.backend = probe
							group := boundDatabaseScope.Load().workers
							StartWorkers(f.queue, func(payload any) JobOutcome {
								if payload.(queueRuntimeJob).Message != "active" {
									panic("claimed pending work during shutdown")
								}
								close(entered)
								<-release
								if f.database.bound() != f.db || boundDatabase.Load() != f.database {
									panic("handler lost pinned database")
								}
								// Public WithDatabase must borrow the existing worker
								// lifetime rather than deadlocking on main's binding lock.
								WithDatabase(f.database, func() {
									other := NewDatabase("forbidden", PostgresConfig{Host: "invalid.invalid"}, nil)
									rejection := pgFacilityPanic(func() { WithDatabase(other, func() { panic("other body executed") }) })
									if fmt.Sprint(rejection) != "database: worker cannot enter another database scope" {
										panic(fmt.Sprint("wrong rejection: ", rejection))
									}
									if fail {
										panic("job deliberately failed")
									}
									WithTransaction(func() { PgExec(f.db, "insert into notes_app.notes(id,active) values ('worker-drained',true)", nil) })
								})
								return JobOutcome{OK: true}
							}, 1, dead)
							started <- group
							<-group.ctx.Done()
						})
					})
				}()
				id := workerLifetimeReceive(t, firstID)
				group := workerLifetimeReceive(t, started)
				workerLifetimeReceive(t, entered)
				// A committed claim is renewable after the worker's stopping context
				// cancels; draining must not apply that cancellation to the handler.
				var expiry time.Time
				if err := f.installer.QueryRow(f.ctx, "select lease_until from notes_app.tesl_jobs where id=$1", id).Scan(&expiry); err != nil {
					t.Fatal(err)
				}
				group.cancel()
				var renewed bool
				deadline := time.Now().Add(3 * time.Second)
				for time.Now().Before(deadline) {
					var next time.Time
					if err := f.installer.QueryRow(f.ctx, "select lease_until from notes_app.tesl_jobs where id=$1", id).Scan(&next); err != nil {
						t.Fatal(err)
					}
					if next.After(expiry) {
						renewed = true
						break
					}
					time.Sleep(10 * time.Millisecond)
				}
				if !renewed {
					t.Fatal("shutdown stopped renewal of active handler")
				}
				select {
				case err := <-finished:
					t.Fatal("scope returned before handler", err)
				default:
				}
				successorEntered := make(chan struct{})
				successorDone := make(chan any, 1)
				successor := NewDatabase("successor", PostgresConfig{}, nil)
				successorJoined = make(chan struct{})
				go func() {
					defer close(successorJoined)
					successorDone <- pgFacilityPanic(func() { withDatabaseBinding(successor, &PostgresDB{}, func() { close(successorEntered) }) })
				}()
				select {
				case <-successorEntered:
					t.Fatal("successor replaced active worker binding")
				case <-time.After(30 * time.Millisecond):
				}
				unblock()
				kind := workerLifetimeReceive(t, persistenceEntered)
				want := "complete"
				if !dead && fail {
					want = "fail"
				}
				if kind != want {
					t.Fatal("wrong persistence path", kind, want)
				}
				if f.database.bound() != f.db || boundDatabase.Load() != f.database {
					t.Fatal("scope lost binding before persistence")
				}
				var persistenceExpiry time.Time
				if err := f.installer.QueryRow(f.ctx, "select lease_until from notes_app.tesl_jobs where id=$1", id).Scan(&persistenceExpiry); err != nil {
					t.Fatal(err)
				}
				if probe.stopped.Load() {
					// Prove the old handoff error against PostgreSQL, not only wrapper order:
					// completion is paused until its now-unrenewed lease actually expires.
					if _, err := f.installer.Exec(f.ctx, "select pg_sleep(greatest(0,extract(epoch from ($1::timestamptz-clock_timestamp())))+0.02)", persistenceExpiry); err != nil {
						t.Fatal(err)
					}
					t.Error("claim renewal stopped before persistence began")
				} else {
					// Cross the deadline observed after the handler returned. Merely observing
					// one earlier renewal while the handler was blocked cannot prove this seam.
					renewedPastDeadline := false
					until := time.Now().Add(3 * time.Second)
					for time.Now().Before(until) {
						var next time.Time
						var passed bool
						if err := f.installer.QueryRow(f.ctx, "select lease_until,clock_timestamp()>$2::timestamptz from notes_app.tesl_jobs where id=$1", id, persistenceExpiry).Scan(&next, &passed); err != nil {
							t.Fatal(err)
						}
						if passed && next.After(persistenceExpiry) {
							renewedPastDeadline = true
							break
						}
						time.Sleep(10 * time.Millisecond)
					}
					if !renewedPastDeadline {
						t.Fatal("renewal did not protect pending persistence past its original deadline", f.row(t, id))
					}
				}
				resumePersistence()
				if err := workerLifetimeReceive(t, finished); err != nil {
					t.Fatal(err)
				}
				if err := workerLifetimeReceive(t, successorDone); err != nil {
					t.Fatal(err)
				}
				var rows int
				pendingStatus, pendingAttempts := "pending", 0
				if dead {
					pendingStatus, pendingAttempts = "dead", 2
				}
				if err := f.installer.QueryRow(f.ctx, "select count(*) from notes_app.tesl_jobs where id<>$1 and status=$2 and attempts=$3", id, pendingStatus, pendingAttempts).Scan(&rows); err != nil || rows != 1 {
					t.Fatal("pending job was claimed", rows, err)
				}
				var activeRows int
				if err := f.installer.QueryRow(f.ctx, "select count(*) from notes_app.tesl_jobs where id=$1", id).Scan(&activeRows); err != nil {
					t.Fatal(err)
				}
				if fail && !dead {
					if activeRows != 1 {
						t.Fatal("failed attempt disappeared")
					}
					row := f.row(t, id)
					if !strings.Contains(row, `"attempts":1`) || !strings.Contains(row, `"status":"pending"`) {
						t.Fatal(row)
					}
				} else if activeRows != 0 {
					t.Fatal("completion did not reach original protected store", f.row(t, id))
				}
				if !probe.stopped.Load() {
					t.Fatal("renewal was not joined after persistence")
				}
				if f.database.bound() != nil || boundDatabase.Load() != nil {
					t.Fatal("scope did not release after join")
				}
				f.queue.mutex.Lock()
				memoryJobs := len(f.queue.jobs)
				f.queue.mutex.Unlock()
				if memoryJobs != 0 {
					t.Fatal("worker fell back to Memory")
				}
			})
		}
	}
}

func TestQueueRuntimeWorkerLifetimePreservesUnversionedScope(t *testing.T) {
	database := storeDatabase(t, "unversioned-worker-lifetime")
	queue := NewQueueOn(database, uniqueName("lifetime"), 2, "fixed", 0)
	registerStoreJobCodec(queue)
	entered, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	unblock := func() { once.Do(func() { close(release) }) }
	started := make(chan *runtimeWorkerScope, 1)
	finished := make(chan any, 1)
	joined := make(chan struct{})
	defer func() { unblock(); workerLifetimeReceive(t, joined) }()
	go func() {
		defer close(joined)
		finished <- pgFacilityPanic(func() {
			WithDatabase(database, func() {
				Enqueue(queue, storeJob{Name: "active", Count: FromInt64(1)})
				Enqueue(queue, storeJob{Name: "pending", Count: FromInt64(2)})
				group := boundDatabaseScope.Load().workers
				StartWorkers(queue, func(value any) JobOutcome {
					if value.(storeJob).Name != "active" {
						panic("claimed after shutdown")
					}
					close(entered)
					<-release
					WithDatabase(database, func() {
						if database.bound() == nil {
							panic("unversioned binding lost")
						}
					})
					return JobOutcome{OK: true}
				}, 1, false)
				started <- group
				<-group.ctx.Done()
			})
		})
	}()
	group := workerLifetimeReceive(t, started)
	workerLifetimeReceive(t, entered)
	group.cancel()
	select {
	case err := <-finished:
		t.Fatal("unversioned scope lost handler", err)
	case <-time.After(20 * time.Millisecond):
	}
	unblock()
	if err := workerLifetimeReceive(t, finished); err != nil {
		t.Fatal(err)
	}
	WithDatabase(database, func() {
		if PendingJobCount(queue).String() != "1" {
			t.Fatal("unversioned pending work changed")
		}
		if len(queue.jobs) != 0 {
			t.Fatal("unversioned completion used Memory")
		}
		ResetQueue(queue)
	})
}
