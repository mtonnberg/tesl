package teslrt

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// No SQL operation is supplied: a waiter must stop before it can obtain the
// cache and attempt observation. This isolates the overall budget from driver
// deadlines, and catches a caller context which has no deadline of its own.
func TestRowObservationWaitHasItsOwnBudget(t *testing.T) {
	t.Setenv("TESL_PG_POOL_LEASE_TIMEOUT_MS", "30")
	protocol := &pgMigrationAdmission{}
	cache := &pgRowObservationCache{owner: protocol}
	protocol.rowObservation = cache
	cache.mu.Lock()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() {
		_, err := pgRowObserveGeneration(ctx, nil, &PostgresDB{migration: protocol}, nil, nil)
		done <- err
	}()
	select {
	case err := <-done:
		cache.mu.Unlock()
		if !errors.Is(err, context.DeadlineExceeded) {
			t.Fatalf("unbounded caller wait returned %v", err)
		}
	case <-time.After(2 * time.Second):
		cancel()
		<-done
		cache.mu.Unlock()
		t.Fatal("observation did not enforce its own overall deadline")
	}
}

func TestRowObservationCanceledWaiterDoesNotTakeOwnerCache(t *testing.T) {
	protocol := &pgMigrationAdmission{}
	cache := &pgRowObservationCache{owner: protocol}
	protocol.rowObservation = cache
	cache.mu.Lock()
	defer cache.mu.Unlock()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err := pgRowObserveGeneration(ctx, nil, &PostgresDB{migration: protocol}, nil, nil)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled waiter returned %v", err)
	}
	if cache.observation != nil {
		t.Fatal("canceled waiter published an observation")
	}
}

func TestRowObservationCopiedAdmissionCannotShareAuthority(t *testing.T) {
	original := &pgMigrationAdmission{}
	original.rowObservation = &pgRowObservationCache{owner: original}
	copied := *original
	_, err := pgRowObserveGeneration(context.Background(), nil, &PostgresDB{migration: &copied}, nil, nil)
	if err == nil || !strings.Contains(err.Error(), "another admission") {
		t.Fatalf("copied identity reused observation authority: %v", err)
	}
}

// Hold the observation cache until the call returns. A current-version request
// must still make progress, while a future version must not use the cache without
// its lock. The real Request connection proves that admission and database
// identity checks remain required even when the cache is occupied.
func TestPgRowBaselineObservationContentionKeepsLiveAdmission(t *testing.T) {
	f, request := pgNewWorkerTest(t)
	database := pgRowBaselineFixture(t, f)
	if _, err := InstallPgCompiledRowBaseline(f.ctx, f.installer, database, f.roles); err != nil {
		t.Fatal(err)
	}
	state, err := ExecutePgCompiledRowBaseline(f.ctx, f.worker, database, f.roles)
	if err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct {
		name    string
		version int
		uuid    string
		future  bool
		want    string
	}{
		{name: "current version proceeds", version: 1, uuid: state.DatabaseUUID},
		{name: "wrong database refuses", version: 1, uuid: "another-database", want: "identity"},
		{name: "unadmitted binary refuses", version: 2, uuid: state.DatabaseUUID, want: "admission"},
		{name: "future version still waits", version: 1, uuid: state.DatabaseUUID, future: true, want: "deadline"},
	} {
		t.Run(test.name, func(t *testing.T) {
			if test.future {
				// An unverified future state must never take the negative fast path.
				if _, err := f.installer.Exec(f.ctx, `update notes_app.tesl_schema_state set current=2 where id=1`); err != nil {
					t.Fatal(err)
				}
			}
			protocol := &pgMigrationAdmission{version: test.version, databaseUUID: test.uuid}
			cache := &pgRowObservationCache{owner: protocol}
			protocol.rowObservation = cache
			cache.mu.Lock()
			defer cache.mu.Unlock()
			ctx, cancel := context.WithTimeout(f.ctx, 2*time.Second)
			defer cancel()
			tx, err := request.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = tx.Rollback(context.Background()) }()
			plan := &pgRowPhysicalPlan{namespace: f.namespace, version: 1}
			observation, err := pgRowObserveGeneration(ctx, tx, &PostgresDB{schema: f.namespace, migration: protocol}, plan, plan)
			switch test.want {
			case "":
				if err != nil || observation != nil {
					t.Fatalf("current request waited for irrelevant observation cache: %v %v", observation, err)
				}
			case "identity":
				if err == nil || !strings.Contains(err.Error(), "database identity changed") {
					t.Fatalf("database identity check was bypassed: %v", err)
				}
			case "admission":
				var admission *pgMigrationAdmissionError
				if !errors.As(err, &admission) {
					t.Fatalf("live admission was bypassed: %v", err)
				}
			case "deadline":
				if !errors.Is(err, context.DeadlineExceeded) || observation != nil {
					t.Fatalf("future state bypassed locked observation: %v %v", observation, err)
				}
			}
		})
	}
}
