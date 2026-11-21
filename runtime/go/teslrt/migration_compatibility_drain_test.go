package teslrt

import (
	"context"
	"math/rand"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Every admitted request transaction holds its version's compatibility key in
// shared mode. Under steady overlapping load there is rarely an instant with
// no holder, so a drain that only ever tries the lock never gets it. The drain
// must still get through, without making any request wait for long.
func TestPgMigrationCompatibilityDrainProgressesUnderSteadyLoad(t *testing.T) {
	f := pgNewControlTest(t)
	config := f.installer.Config().Copy()
	const fence, version = 4242, 3
	for _, load := range []struct {
		name    string
		holders int
		gap     func(*rand.Rand) time.Duration
	}{
		{"busy clients", 8, func(*rand.Rand) time.Duration { return time.Millisecond }},
		{"many half-busy clients", 24, func(r *rand.Rand) time.Duration { return time.Duration(5+r.Intn(15)) * time.Millisecond }},
	} {
		t.Run(load.name, func(t *testing.T) {
			ctx, stop := context.WithCancel(f.ctx)
			var group sync.WaitGroup
			var longestWait atomic.Int64
			var completed atomic.Int64
			for i := 0; i < load.holders; i++ {
				conn, err := pgx.ConnectConfig(ctx, config)
				if err != nil {
					t.Fatal(err)
				}
				group.Add(1)
				go func(seed int64) {
					defer group.Done()
					defer conn.Close(context.Background())
					random := rand.New(rand.NewSource(seed))
					for ctx.Err() == nil {
						started := time.Now()
						tx, err := conn.Begin(ctx)
						if err != nil {
							return
						}
						if _, err := tx.Exec(ctx, "select pg_catalog.pg_advisory_xact_lock_shared($1::integer,$2::integer)", -fence, version); err != nil {
							_ = tx.Rollback(context.Background())
							return
						}
						if wait := time.Since(started).Nanoseconds(); wait > longestWait.Load() {
							longestWait.Store(wait)
						}
						time.Sleep(time.Duration(2+random.Intn(18)) * time.Millisecond)
						if tx.Commit(ctx) == nil {
							completed.Add(1)
						}
						time.Sleep(load.gap(random))
					}
				}(int64(i))
			}
			defer func() { stop(); group.Wait() }()
			time.Sleep(300 * time.Millisecond)
			drain, err := pgx.ConnectConfig(f.ctx, config)
			if err != nil {
				t.Fatal(err)
			}
			defer drain.Close(context.Background())
			budget, cancel := context.WithTimeout(f.ctx, 15*time.Second)
			defer cancel()
			ran := false
			started := time.Now()
			if err := pgRowCompatibilityDrain(budget, drain, fence, version, version, "test", func() error {
				ran = true
				return nil
			}); err != nil || !ran {
				t.Fatalf("drain did not get through under steady load after %s: ran=%v err=%v", time.Since(started), ran, err)
			}
			before := completed.Load()
			time.Sleep(200 * time.Millisecond)
			if completed.Load() == before {
				t.Fatal("requests stopped completing after the drain released its keys")
			}
			// A queued wait may hold new requests back for one bounded interval.
			if wait := time.Duration(longestWait.Load()); wait > 2*time.Second {
				t.Fatalf("a request waited %s for the compatibility key", wait)
			}
			var timeout string
			if err := drain.QueryRow(f.ctx, "select pg_catalog.current_setting('lock_timeout')").Scan(&timeout); err != nil || timeout != "0" {
				t.Fatalf("drain left lock_timeout=%q err=%v", timeout, err)
			}
		})
	}
}

// One long transaction keeps its shared key, so the drain must keep waiting:
// a timed-out queued wait is "busy", never an error or a false success.
func TestPgMigrationCompatibilityDrainWaitsForLongTransaction(t *testing.T) {
	f := pgNewControlTest(t)
	config := f.installer.Config().Copy()
	const fence, version = 4243, 2
	holder, err := pgx.ConnectConfig(f.ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	defer holder.Close(context.Background())
	tx, err := holder.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(f.ctx, "select pg_catalog.pg_advisory_xact_lock_shared($1::integer,$2::integer)", -fence, version); err != nil {
		t.Fatal(err)
	}
	drain, err := pgx.ConnectConfig(f.ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	defer drain.Close(context.Background())
	done := make(chan error, 1)
	ran := atomic.Bool{}
	go func() {
		done <- pgRowCompatibilityDrain(f.ctx, drain, fence, version, version, "test", func() error { ran.Store(true); return nil })
	}()
	// Long enough for the drain to pass its try phase and time out queued waits.
	select {
	case err := <-done:
		t.Fatalf("drain finished while a transaction still held the key: ran=%v err=%v", ran.Load(), err)
	case <-time.After(2 * time.Second):
	}
	if err := tx.Commit(f.ctx); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err != nil || !ran.Load() {
			t.Fatalf("drain after the transaction ended: ran=%v err=%v", ran.Load(), err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("drain did not get through after the long transaction ended")
	}
}
