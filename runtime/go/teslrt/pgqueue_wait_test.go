package teslrt

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// A row lock that changes no tuple must not preserve an already evaluated lease
// predicate. Exercise the public runtime backend, not a copied SQL statement.
func TestDurableQueueLeaseExpiryWhileWaitingForUnchangedRowLock(t *testing.T) {
	for _, kind := range []string{"complete", "renew", "fail", "quarantine"} {
		t.Run(kind, func(t *testing.T) {
			database := storeDatabase(t, "QueueWaitLease")
			queue := NewQueueOn(database, uniqueName("lockwait"), 3, "", 0)
			registerStoreJobCodec(queue)
			enteredDecode, releaseDecode := make(chan struct{}), make(chan struct{})
			if kind == "quarantine" {
				RegisterJobCodec(queue, "StoreJob", func(value any) any { return value }, func(any) (any, error) {
					close(enteredDecode)
					<-releaseDecode
					return nil, errors.New("fixture decoder rejection")
				})
			}
			WithDatabase(database, func() {
				EnqueueJob(queue, storeJob{Name: "retained", Count: FromInt64(1)})
				type result struct {
					changed bool
					err     error
				}
				done := make(chan result, 1)
				backend := queue.backend.(*pgQueueBackend)
				db, table := backend.table()
				var id, token string
				var attempts int
				if kind == "quarantine" {
					go func() { _, _, _, _, found := queue.dequeue(jobPending); done <- result{changed: found} }()
					<-enteredDecode
					rows := PgQuery(db, "select id,claim_token,attempts from "+table+" where queue=$1", []any{queue.name}, func(row pgx.CollectableRow) (struct{}, error) { return struct{}{}, row.Scan(&id, &token, &attempts) })
					if len(rows) != 1 {
						t.Fatal("missing decoder claim")
					}
				} else {
					var found bool
					id, _, attempts, token, found = queue.dequeue(jobPending)
					if !found {
						t.Fatal("missing claim")
					}
				}
				observer, err := pgx.Connect(context.Background(), postgresDSN(database.Config))
				if err != nil {
					t.Fatal(err)
				}
				defer func() { _ = observer.Close(context.Background()) }()
				ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
				defer cancel()
				if _, err = observer.Exec(ctx, "update "+table+" set lease_until=clock_timestamp()+interval '1 second' where id=$1", id); err != nil {
					t.Fatal(err)
				}
				held, err := observer.Begin(ctx)
				if err != nil {
					t.Fatal(err)
				}
				defer func() { _ = held.Rollback(ctx) }()
				if _, err = held.Exec(ctx, "select id from "+table+" where id=$1 for update", id); err != nil {
					t.Fatal(err)
				}
				if kind == "quarantine" {
					close(releaseDecode)
				} else {
					go func() {
						result := result{}
						switch kind {
						case "complete":
							result.changed = queue.complete(id, token)
						case "fail":
							result.changed = queue.fail(id, attempts, token)
						case "renew":
							result.changed, result.err = backend.renewClaim(ctx, db, table, id, token, time.Minute)
						}
						done <- result
					}()
				}
				for {
					var waiting, live bool
					if err = held.QueryRow(ctx, "select exists(select 1 from pg_stat_activity a where pg_backend_pid()=any(pg_blocking_pids(a.pid))),(select lease_until>clock_timestamp() from "+table+" where id=$1)", id).Scan(&waiting, &live); err != nil {
						t.Fatal(err)
					}
					if !live {
						t.Fatal("operation did not wait before expiry")
					}
					if waiting {
						break
					}
					if _, err = held.Exec(ctx, "select pg_stat_clear_snapshot(),pg_sleep(0.005)"); err != nil {
						t.Fatal(err)
					}
				}
				if _, err = held.Exec(ctx, "select pg_sleep(greatest(0,extract(epoch from lease_until-clock_timestamp()))+0.03) from "+table+" where id=$1", id); err != nil {
					t.Fatal(err)
				}
				if err = held.Commit(ctx); err != nil {
					t.Fatal(err)
				}
				got := <-done
				if got.err != nil {
					t.Fatal(got.err)
				}
				if got.changed {
					t.Fatal("expired attempt changed job after row lock wait")
				}
				var retained bool
				if err = observer.QueryRow(ctx, "select status='processing' and claim_token=$2 and attempts=$3 and lease_until<clock_timestamp() from "+table+" where id=$1", id, token, attempts).Scan(&retained); err != nil || !retained {
					t.Fatalf("retained row changed: %v %v", retained, err)
				}
			})
		})
	}
}
