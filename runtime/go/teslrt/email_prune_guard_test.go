package teslrt

import (
	"testing"
	"time"
)

// An outbox backend whose prune traps, standing in for a database that is unreachable when
// the hourly pruner fires.
type trappingOutboxBackend struct{ pruned int }

func (b *trappingOutboxBackend) active() bool                           { return true }
func (b *trappingOutboxBackend) send(EmailMessage)                      {}
func (b *trappingOutboxBackend) claimDue(int) []EmailMessage            { return nil }
func (b *trappingOutboxBackend) recordOutcome(EmailMessage, error) bool { return true }
func (b *trappingOutboxBackend) messages() []EmailMessage               { return []EmailMessage{} }
func (b *trappingOutboxBackend) reset()                                 {}
func (b *trappingOutboxBackend) prune(time.Duration) {
	b.pruned++
	panic(RequestRejection{Status: 503, Message: "database busy, try again"})
}

// The background pruner must survive a store failure: as an unrecovered panic it took the
// whole process down (the queue worker had the same bug).
func TestEmailPrunerSurvivesAStoreFailure(t *testing.T) {
	backend := &trappingOutboxBackend{}
	outbox := NewOutbox(SmtpSettings{})
	outbox.backend = backend
	pruneSentEmailGuarded(outbox, time.Hour) // must not panic
	if backend.pruned != 1 {
		t.Fatalf("prune ran %d times", backend.pruned)
	}
}
