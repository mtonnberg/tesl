package teslrt

import (
	"strings"
	"testing"
)

type emailJob struct {
	Recipient string
}

// Dequeue order is ENQUEUE order, not map order: the Racket store keyed by job id once
// dequeued in hash order while the PostgreSQL path is `order by created_at asc`, and that
// disagreement was a real bug.
func TestQueueIsFIFO(t *testing.T) {
	queue := NewQueue("Email", 3)
	for _, name := range []string{"a", "b", "c"} {
		Enqueue(queue, emailJob{Recipient: name})
	}
	if n := PendingJobCount(queue); n.String() != "3" {
		t.Fatalf("pending = %s", n.String())
	}
	var seen []string
	handler := func(payload any) JobOutcome {
		seen = append(seen, payload.(emailJob).Recipient)
		return JobOutcome{OK: true}
	}
	for i := 0; i < 3; i++ {
		if outcome := ProcessNextJob(queue, handler); !outcome.Ran || !outcome.OK {
			t.Fatalf("job %d did not run cleanly: %+v", i, outcome)
		}
	}
	if strings.Join(seen, "") != "abc" {
		t.Errorf("dequeue order = %v", seen)
	}
	// A completed job leaves the queue, and an empty queue reports "nothing ran".
	if n := PendingJobCount(queue); n.String() != "0" {
		t.Errorf("pending after draining = %s", n.String())
	}
	if outcome := ProcessNextJob(queue, handler); outcome.Ran {
		t.Errorf("an empty queue must not run a job: %+v", outcome)
	}
}

// A failing job is retried until maxAttempts, then dead-lettered.
func TestQueueRetriesThenDeadLetters(t *testing.T) {
	queue := NewQueue("Email", 3)
	Enqueue(queue, emailJob{Recipient: "x"})
	failing := func(any) JobOutcome { return JobOutcome{OK: false, Message: "nope"} }

	for attempt := 1; attempt <= 2; attempt++ {
		outcome := ProcessNextJob(queue, failing)
		if !outcome.Ran || outcome.OK {
			t.Fatalf("attempt %d: %+v", attempt, outcome)
		}
		if n := PendingJobCount(queue); n.String() != "1" {
			t.Fatalf("attempt %d left pending = %s", attempt, n.String())
		}
	}
	// The third failure exhausts maxAttempts.
	if outcome := ProcessNextJob(queue, failing); outcome.OK {
		t.Fatalf("third attempt should fail: %+v", outcome)
	}
	if n := PendingJobCount(queue); n.String() != "0" {
		t.Errorf("a dead job must not stay pending: %s", n.String())
	}
	if n := DeadJobCount(queue); n.String() != "1" {
		t.Errorf("dead = %s", n.String())
	}
	// The dead-letter worker gets it, and the job is gone whatever it answers.
	dead := ProcessNextDeadJob(queue, func(any) JobOutcome { return JobOutcome{OK: true} })
	if !dead.Ran {
		t.Fatal("the dead-letter worker got nothing")
	}
	if n := DeadJobCount(queue); n.String() != "0" {
		t.Errorf("dead after handling = %s", n.String())
	}
}

// A worker that TRAPS is a failed attempt, not a crashed process.
func TestQueueTrapIsAFailedAttempt(t *testing.T) {
	queue := NewQueue("Email", 2)
	Enqueue(queue, emailJob{Recipient: "x"})
	trapping := func(any) JobOutcome { panic("worker exploded") }
	outcome := ProcessNextJob(queue, trapping)
	if !outcome.Ran || outcome.OK || !strings.Contains(outcome.Message, "exploded") {
		t.Fatalf("trap outcome = %+v", outcome)
	}
	if n := PendingJobCount(queue); n.String() != "1" {
		t.Errorf("pending after a trap = %s", n.String())
	}
}

func TestDrainQueueStopsAtItsLimit(t *testing.T) {
	queue := NewQueue("Email", 100)
	Enqueue(queue, emailJob{Recipient: "x"})
	// This job always fails back into the queue, so only the limit stops the drain.
	failing := func(any) JobOutcome { return JobOutcome{OK: false, Message: "again"} }
	if ran := DrainQueue(queue, failing, 5); ran.String() != "5" {
		t.Errorf("drain ran = %s", ran.String())
	}
	queue2 := NewQueue("Email", 3)
	Enqueue(queue2, emailJob{Recipient: "y"})
	Enqueue(queue2, emailJob{Recipient: "z"})
	if ran := DrainQueue(queue2, func(any) JobOutcome { return JobOutcome{OK: true} }, 10); ran.String() != "2" {
		t.Errorf("drain of two jobs ran = %s", ran.String())
	}
}

// Job ids are time-ordered UUID v7s: shaped right, unique, and monotonic enough that
// "oldest first" is recoverable from the id.
func TestJobIdsAreUUIDv7(t *testing.T) {
	queue := NewQueue("Email", 3)
	seen := map[string]bool{}
	previous := ""
	for i := 0; i < 200; i++ {
		id := Enqueue(queue, emailJob{Recipient: "x"})
		if len(id) != 36 || id[14] != '7' {
			t.Fatalf("id is not a v7 UUID: %q", id)
		}
		if seen[id] {
			t.Fatalf("id repeated: %q", id)
		}
		seen[id] = true
		if previous != "" && id[:13] < previous[:13] {
			t.Fatalf("v7 ids must not go backwards: %q then %q", previous, id)
		}
		previous = id
	}
}
