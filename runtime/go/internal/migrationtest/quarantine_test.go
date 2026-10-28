package migrationtest

import (
	"math"
	"testing"
)

func rejectedRows(t *testing.T) *Model {
	t.Helper()
	m := NewModel(7, "seven")
	apply(t, m, Op{Kind: "expand", Version: 8, Hash: "eight"},
		Op{Kind: "row-add", ID: "accepted", Generation: 3}, Op{Kind: "backfill", ID: "accepted"},
		Op{Kind: "row-add", ID: "rejected", Generation: 3}, Op{Kind: "reject", ID: "rejected", Reason: "negative total"})
	return m
}

// INV-REPAIR-SCOPE, INV-REPAIR-ORDER, INV-REPAIR-EXECUTOR, INV-FINAL; TR-REPAIR-ROW, TR-BACKFILL, TR-RETIRE.
// Accept/Reason are symbolic results of independently pure row functions. This
// model checks protocol order and ownership; compiler/black-box tests must check
// that actual Tesl functions compute those results.
func TestRepairChainRunsOnlyOnRejectedRowsAndStopsAtFirstAcceptance(t *testing.T) {
	m := rejectedRows(t)
	chain := []string{"first", "second", "third"}
	for seq, hash := range chain {
		apply(t, m, Op{Kind: "repair-record", Version: 8, Sequence: seq + 1, Hash: hash})
	}
	first := Op{Kind: "repair-row", ID: "rejected", Version: 8, Revision: 1, Sequence: 1, Hash: "first", RepairHashes: chain, Reason: "still negative"}
	denied(t, m, first) // no final-pass fence
	apply(t, m, Op{Kind: "retire-begin", Version: 8})
	accepted := first
	accepted.ID, accepted.Revision = "accepted", m.Rows["accepted"].Revision
	denied(t, m, accepted)
	denied(t, m, Op{Kind: "reject", ID: "accepted"})
	incomplete := first
	incomplete.RepairHashes = chain[:1]
	denied(t, m, incomplete)
	outOfOrder := first
	outOfOrder.Sequence, outOfOrder.Hash = 2, "second"
	denied(t, m, outOfOrder)
	apply(t, m, first)
	denied(t, m, Op{Kind: "retire-commit", Version: 8})
	denied(t, m, first) // no repeated/out-of-order repair
	second := first
	second.Sequence, second.Hash, second.Accept = 2, "second", true
	apply(t, m, second)
	third := second
	third.Sequence, third.Hash, third.Revision = 3, "third", m.Rows["rejected"].Revision
	denied(t, m, third)
	if r := m.Rows["rejected"]; r.Rejected || r.Generation != 4 || r.Repair != 2 || r.Revision != 2 {
		t.Fatalf("wrong accepted row evidence: %+v", r)
	}
	if r := m.Rows["accepted"]; r.Generation != 4 || r.Repair != 0 || r.Revision != 2 {
		t.Fatalf("repair reinterpreted previously accepted row: %+v", r)
	}
	apply(t, m, Op{Kind: "retire-commit", Version: 8})
}

// INV-QUARANTINE, INV-FINAL, INV-ROW-REVISION; TR-QUARANTINE-REFRESH, TR-INVALIDATE, TR-ROW-DELETE, TR-CRASH.
func TestQuarantineAfterAbortRechecksChangedOrDeletedRows(t *testing.T) {
	for _, intervening := range []string{"unchanged", "updated", "accepted", "deleted"} {
		t.Run(intervening, func(t *testing.T) {
			m := rejectedRows(t)
			apply(t, m, Op{Kind: "retire-begin", Version: 8})
			denied(t, m, Op{Kind: "retire-commit", Version: 8})
			denied(t, m, Op{Kind: "quarantine-refresh", ID: "rejected", Revision: 1})
			apply(t, m, Op{Kind: "crash"})
			switch intervening {
			case "updated":
				apply(t, m, Op{Kind: "old-write", ID: "rejected", Version: 7})
			case "accepted":
				apply(t, m, Op{Kind: "backfill", ID: "rejected"})
			case "deleted":
				apply(t, m, Op{Kind: "row-delete", ID: "rejected", Version: 7})
			}
			if intervening == "updated" || intervening == "accepted" {
				denied(t, m, Op{Kind: "quarantine-refresh", ID: "rejected", Revision: 1})
			}
			apply(t, m, Op{Kind: "quarantine-refresh", ID: "rejected", Revision: m.Rows["rejected"].Revision})
			if got := len(m.Quarantine); (got == 1) != (intervening == "unchanged") {
				t.Fatalf("stale quarantine after %s: %+v", intervening, m.Quarantine)
			}
			if m.Floor != 7 || m.Rows["accepted"].Generation != 4 || m.Versions[8] != "expanded" {
				t.Fatal("aborted retirement lost committed accepted rows or advanced lifecycle")
			}
		})
	}
}

// INV-QUARANTINE, INV-REPAIR-ORDER; TR-REPAIR-ROW, TR-QUARANTINE-REFRESH, TR-INVALIDATE.
func TestQuarantineUsesLastRepairReasonAndClearsOnApplicationChange(t *testing.T) {
	for _, change := range []string{"old-write", "row-delete", "backfill"} {
		t.Run(change, func(t *testing.T) {
			m := rejectedRows(t)
			apply(t, m, Op{Kind: "repair-record", Version: 8, Sequence: 1, Hash: "repair"},
				Op{Kind: "retire-begin", Version: 8},
				Op{Kind: "repair-row", ID: "rejected", Version: 8, Revision: 1, Sequence: 1, Hash: "repair", RepairHashes: []string{"repair"}, Reason: "repair also rejected"},
				Op{Kind: "crash"}, Op{Kind: "quarantine-refresh", ID: "rejected", Revision: 1})
			if q := m.Quarantine["rejected"]; q.Reason != "repair also rejected" || q.Repair != 1 || q.Generation != 4 || q.Version != 8 {
				t.Fatalf("quarantine lost latest repair evidence: %+v", q)
			}
			apply(t, m, Op{Kind: change, ID: "rejected", Version: 7})
			if len(m.Quarantine) != 0 {
				t.Fatalf("application %s left stale quarantine: %+v", change, m.Quarantine)
			}
		})
	}
}

// INV-QUARANTINE, INV-ROW-REVISION; TR-QUARANTINE-REFRESH, TR-BACKFILL, TR-INVALIDATE.
func TestQuarantineEvidenceCorruptionAndRowRevisionOverflowAreRefused(t *testing.T) {
	m := rejectedRows(t)
	apply(t, m, Op{Kind: "quarantine-refresh", ID: "rejected", Revision: 1})
	for _, corrupt := range []func(*Model){
		func(m *Model) { delete(m.Rows, "rejected") },
		func(m *Model) { q := m.Quarantine["rejected"]; q.Revision++; m.Quarantine["rejected"] = q },
		func(m *Model) { q := m.Quarantine["rejected"]; q.Generation++; m.Quarantine["rejected"] = q },
		func(m *Model) { q := m.Quarantine["rejected"]; q.Reason = "wrong reason"; m.Quarantine["rejected"] = q },
		func(m *Model) { r := m.Rows["rejected"]; r.Rejected = false; m.Rows["rejected"] = r },
	} {
		clone := m.Clone()
		corrupt(clone)
		if err := clone.Check(); err == nil {
			t.Fatal("corrupted quarantine evidence was accepted")
		}
	}
	r := m.Rows["rejected"]
	r.Revision = math.MaxUint64
	m.Rows["rejected"] = r
	delete(m.Quarantine, "rejected")
	denied(t, m, Op{Kind: "old-write", ID: "rejected", Version: 7})
	denied(t, m, Op{Kind: "backfill", ID: "rejected"})
}
