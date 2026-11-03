// Package migrationtest provides deterministic schedules for migration tests.
// It is outside teslrt and is never copied into generated application binaries.
package migrationtest

import (
	"context"
	"fmt"
	"sync"
)

// Event identifies a boundary, its executor and the occurrence within a trace.
// Matching on the actor avoids accidentally pausing a competing connection.
type Event struct {
	Name       string
	Actor      string
	Occurrence int
}

type gate struct {
	arrived  chan struct{}
	released chan struct{}
	once     sync.Once
}

// Schedule has no wall-clock sleeps: the test explicitly releases each boundary.
// The caller supplies a deadline and a dump of database locks/activity/state.
type Schedule struct {
	mu    sync.Mutex
	gates map[Event]*gate
	seen  map[Event]bool
	trace []Event
	dump  func() string
}

func NewSchedule(dump func() string) *Schedule {
	return &Schedule{gates: make(map[Event]*gate), seen: make(map[Event]bool), dump: dump}
}

// Pause must precede execution. Duplicate or already observed registrations are
// errors, so a test cannot silently miss the race it intended to exercise.
func (s *Schedule) Pause(e Event) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, exists := s.gates[e]; exists || s.seen[e] {
		return fmt.Errorf("migration schedule: boundary already registered or observed: %+v", e)
	}
	s.gates[e] = &gate{arrived: make(chan struct{}), released: make(chan struct{})}
	return nil
}

func (s *Schedule) Hit(ctx context.Context, e Event) error {
	s.mu.Lock()
	if s.seen[e] {
		s.mu.Unlock()
		return fmt.Errorf("migration schedule: duplicate occurrence: %+v", e)
	}
	s.seen[e] = true
	s.trace = append(s.trace, e)
	g := s.gates[e]
	if g != nil {
		close(g.arrived)
	}
	s.mu.Unlock()
	if g == nil {
		return nil
	}
	select {
	case <-g.released:
		return nil
	case <-ctx.Done():
		return s.timeout(ctx, e)
	}
}

func (s *Schedule) Await(ctx context.Context, e Event) error {
	s.mu.Lock()
	g := s.gates[e]
	s.mu.Unlock()
	if g == nil {
		return fmt.Errorf("migration schedule: unregistered boundary: %+v", e)
	}
	select {
	case <-g.arrived:
		return nil
	case <-ctx.Done():
		return s.timeout(ctx, e)
	}
}

func (s *Schedule) Release(e Event) error {
	s.mu.Lock()
	g := s.gates[e]
	seen := s.seen[e]
	s.mu.Unlock()
	if g == nil || !seen {
		return fmt.Errorf("migration schedule: release before arrival: %+v", e)
	}
	g.once.Do(func() { close(g.released) })
	return nil
}

func (s *Schedule) Trace() []Event {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]Event(nil), s.trace...)
}

func (s *Schedule) timeout(ctx context.Context, e Event) error {
	dump := ""
	if s.dump != nil {
		dump = s.dump()
	}
	return fmt.Errorf("migration schedule: %w at %+v; trace=%+v\n%s", ctx.Err(), e, s.Trace(), dump)
}
