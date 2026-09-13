package teslrt

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
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
