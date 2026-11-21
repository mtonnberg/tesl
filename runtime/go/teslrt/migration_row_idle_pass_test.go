package teslrt

import (
	"testing"
	"time"
)

// A pass that converts nothing delays the next one, doubling up to the cap; a
// pass that converted anything (even in an earlier batch) resets the delay.
func TestRowIdlePassesBackOffOnlyAfterSettledPasses(t *testing.T) {
	now := time.Unix(1_000_000, 0)
	var pace pgRowIdlePasses
	pace.record(5, false, now)
	pace.record(0, true, now)
	if !pace.notBefore.IsZero() || pace.idle != 0 {
		t.Fatalf("a pass that converted rows in an earlier batch backed off: %+v", pace)
	}
	waits := []time.Duration{}
	for i := 0; i < 8; i++ {
		pace.record(0, false, now)
		pace.record(0, true, now)
		waits = append(waits, pace.notBefore.Sub(now))
	}
	want := []time.Duration{time.Second, 2 * time.Second, 4 * time.Second, 8 * time.Second, 16 * time.Second, 30 * time.Second, 30 * time.Second, 30 * time.Second}
	for i := range want {
		if waits[i] != want[i] {
			t.Fatalf("idle wait %d = %s, want %s (all %v)", i, waits[i], want[i], waits)
		}
	}
	pace.record(1, true, now)
	if !pace.notBefore.IsZero() || pace.idle != 0 || pace.changed != 0 {
		t.Fatalf("a pass that converted a demoted row kept backing off: %+v", pace)
	}
}
