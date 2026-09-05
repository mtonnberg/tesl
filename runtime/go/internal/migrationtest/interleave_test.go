package migrationtest

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

// INV-HARNESS; TR-SCHEDULE.
func TestScheduleSelectsActorAndOccurrence(t *testing.T) {
	s := NewSchedule(nil)
	e := Event{"fence-acquired", "v7", 2}
	if err := s.Pause(e); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	for _, other := range []Event{{"fence-acquired", "v8", 2}, {"fence-acquired", "v7", 1}} {
		if err := s.Hit(ctx, other); err != nil {
			t.Fatal(err)
		}
	}
	done := make(chan error, 1)
	go func() { done <- s.Hit(ctx, e) }()
	if err := s.Await(ctx, e); err != nil {
		t.Fatal(err)
	}
	select {
	case <-done:
		t.Fatal("paused boundary returned before release")
	default:
	}
	if err := s.Release(e); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-ctx.Done():
		t.Fatal(ctx.Err())
	}
	trace := s.Trace()
	trace[0].Name = "changed"
	if s.Trace()[0].Name == "changed" {
		t.Fatal("trace aliases scheduler memory")
	}
}

// INV-HARNESS; TR-SCHEDULE.
func TestScheduleMisuseFailsLoudly(t *testing.T) {
	s := NewSchedule(nil)
	e := Event{"claim", "worker", 1}
	if err := s.Release(e); err == nil {
		t.Fatal("released unknown event")
	}
	if err := s.Await(context.Background(), e); err == nil {
		t.Fatal("awaited unknown event")
	}
	if err := s.Pause(e); err != nil {
		t.Fatal(err)
	}
	if err := s.Pause(e); err == nil {
		t.Fatal("duplicate pause")
	}
	if err := s.Release(e); err == nil {
		t.Fatal("released before arrival")
	}
	other := Event{"claim", "worker", 2}
	if err := s.Hit(context.Background(), other); err != nil {
		t.Fatal(err)
	}
	if err := s.Hit(context.Background(), other); err == nil {
		t.Fatal("duplicate occurrence")
	}
	if err := s.Pause(other); err == nil {
		t.Fatal("registered after arrival")
	}
}

// INV-HARNESS; TR-SCHEDULE.
func TestScheduleTimeoutIncludesTraceAndDatabaseDump(t *testing.T) {
	s := NewSchedule(func() string { return "pg_stat_activity; pg_locks; lifecycle rows" })
	e := Event{"contract-commit", "worker", 1}
	if err := s.Pause(e); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	err := s.Hit(ctx, e)
	if !errors.Is(err, context.Canceled) || !strings.Contains(err.Error(), "pg_locks") || !strings.Contains(err.Error(), "contract-commit") {
		t.Fatalf("missing timeout evidence: %v", err)
	}
}
