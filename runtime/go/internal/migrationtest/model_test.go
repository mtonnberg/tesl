package migrationtest

import (
	"math"
	"math/rand"
	"os"
	"reflect"
	"strconv"
	"testing"
)

// INV-CLOCK, INV-ATTEMPT, INV-LEASE, INV-ABI; TR-EXPIRY, TR-CLAIM, TR-LEASE, TR-ABI-BATCH.
func TestModelRefusesCounterAndClockOverflowAtomically(t *testing.T) {
	m := NewModel(7, "seven")
	apply(t, m, Op{Kind: "enqueue", ID: "job", Version: 7}, Op{Kind: "tick", Ticks: math.MaxInt64 - 1})
	denied(t, m, Op{Kind: "tick", Ticks: 2})
	denied(t, m, Op{Kind: "claim", ID: "job", Version: 7, Ticks: 2})
	denied(t, m, Op{Kind: "lease-acquire", ID: "worker", Hash: "executor", Ticks: 2})
	apply(t, m, Op{Kind: "claim", ID: "job", Version: 7, Ticks: 1})
	denied(t, m, Op{Kind: "renew", ID: "job", Version: 7, Attempt: 1, Ticks: 2})
	apply(t, m, Op{Kind: "tick", Ticks: 1})
	denied(t, m, Op{Kind: "renew", ID: "job", Version: 7, Attempt: 1, Ticks: 1})

	m = NewModel(7, "seven")
	m.Jobs["job"] = Job{Version: 7, Status: "pending", Attempt: math.MaxInt64}
	m.Leases["worker"] = Lease{Holder: "last", Token: math.MaxInt64}
	denied(t, m, Op{Kind: "claim", ID: "job", Version: 7, Ticks: 1})
	denied(t, m, Op{Kind: "lease-acquire", ID: "worker", Hash: "next", Ticks: 1})
	m.ExecutorABI[7], m.ABILocked[7] = "compiler", true
	m.Processing["Note"] = ProcessingABI{Version: 7, Generation: 32767, ABI: "compiler", Rows: math.MaxUint64}
	denied(t, m, Op{Kind: "abi-batch", ID: "Note", Version: 7, Generation: 32767, Hash: "compiler"})
	denied(t, m, Op{Kind: "abi-select", ID: "Note", Version: 7, Generation: 32768, Hash: "compiler"})
}

// INV-ABI; TR-ABI-SELECT, TR-ABI-BATCH.
func TestModelDetectsCorruptedABIEvidence(t *testing.T) {
	for _, corrupt := range []func(*Model){
		func(m *Model) { m.ABILocked[7] = false },
		func(m *Model) { m.ExecutorABI[7] = "drift" },
		func(m *Model) { delete(m.Hashes, 7) },
		func(m *Model) { p := m.Processing["Note"]; p.Generation = 32768; m.Processing["Note"] = p },
	} {
		m := NewModel(7, "seven")
		apply(t, m, Op{Kind: "abi-batch", ID: "Note", Version: 7, Generation: 1, Hash: "compiler"})
		corrupt(m)
		if err := m.Check(); err == nil {
			t.Fatal("corrupted ABI evidence accepted")
		}
	}
}

// INV-HISTORY, INV-LIFECYCLE, INV-VERSION, INV-FLOOR; TR-EXPAND, TR-CONTRACT.
func TestModelChecksCompleteVersionEvidenceAndImmutableClassification(t *testing.T) {
	m := NewModel(7, "seven")
	apply(t, m, Op{Kind: "expand", Version: 8, Hash: "eight", Additive: true}, Op{Kind: "expand", Version: 9, Hash: "nine", Additive: true})
	denied(t, m, Op{Kind: "expand", Version: 9, Hash: "nine", Additive: false})
	denied(t, m, Op{Kind: "expand", Version: 8, Hash: "eight", Additive: true})
	for _, corrupt := range []func(*Model){
		func(m *Model) { delete(m.Versions, 8) },
		func(m *Model) { delete(m.Hashes, 8) },
		func(m *Model) { m.Hashes[8] = "" },
		func(m *Model) { delete(m.EpochPreserving, 8) },
		func(m *Model) { m.Hashes[10] = "future" },
		func(m *Model) { m.Versions[8] = "contracted" },
		func(m *Model) { m.Versions[8] = "unknown" },
		func(m *Model) { m.Compat = 8; m.Floor = 8 },
		func(m *Model) { m.RetiringThrough = 9 },
		func(m *Model) { m.Floor = 6 },
	} {
		clone := m.Clone()
		corrupt(clone)
		if err := clone.Check(); err == nil {
			t.Fatal("corrupted version or lifecycle evidence was accepted")
		}
	}
	last := NewModel(2147483646, "last")
	denied(t, last, Op{Kind: "expand", Version: 2147483647, Hash: "reserved", Additive: true})
	if err := NewModel(2147483647, "reserved").Check(); err == nil {
		t.Fatal("boot fence key accepted as a schema version")
	}
}

func apply(t *testing.T, m *Model, ops ...Op) {
	t.Helper()
	for _, op := range ops {
		if err := m.Apply(op); err != nil {
			t.Fatalf("%+v: %v", op, err)
		}
	}
}

func denied(t *testing.T, m *Model, op Op) {
	t.Helper()
	before := m.Clone()
	if err := m.Apply(op); err == nil {
		t.Fatalf("accepted forbidden operation: %+v", op)
	}
	if !reflect.DeepEqual(before, m) {
		t.Fatalf("refused operation changed durable state: %+v", op)
	}
}

// INV-FENCE, INV-READ, INV-FLOOR, INV-EXPAND; TR-WRITE, TR-RETIRE, TR-CRASH, TR-EXPAND.
func TestRetirementExcludesEveryOldWriter(t *testing.T) {
	m := NewModel(7, "seven")
	apply(t, m, Op{Kind: "expand", Version: 8, Hash: "eight", Additive: true},
		Op{Kind: "write-begin", Version: 7, ID: "paused"})
	denied(t, m, Op{Kind: "retire-begin", Version: 8})
	apply(t, m, Op{Kind: "write-end", ID: "paused"}, Op{Kind: "retire-begin", Version: 8})
	denied(t, m, Op{Kind: "expand", Version: 9, Hash: "nine", Additive: true})
	denied(t, m, Op{Kind: "write-begin", Version: 7, ID: "queued"})
	apply(t, m, Op{Kind: "write-begin", Version: 8, ID: "survivor"}, Op{Kind: "retire-commit", Version: 8})
	denied(t, m, Op{Kind: "read-deliver", Version: 7})
	denied(t, m, Op{Kind: "write-begin", Version: 7, ID: "reconnected"})
	apply(t, m, Op{Kind: "crash"})
	denied(t, m, Op{Kind: "write-begin", Version: 7, ID: "restarted"})
}

// INV-HISTORY, INV-WINDOW, INV-CONTRACT; TR-EXPAND, TR-CONTRACT.
func TestEpochClosesBeforeTransformAndContractPrecedesNextExpand(t *testing.T) {
	m := NewModel(1, "one")
	for v := 2; v <= 10; v++ {
		apply(t, m, Op{Kind: "expand", Version: v, Hash: strconv.Itoa(v), Additive: true})
	}
	apply(t, m, Op{Kind: "write-begin", ID: "v1", Version: 1}, Op{Kind: "write-end", ID: "v1"})
	denied(t, m, Op{Kind: "expand", Version: 11, Hash: "eleven"})
	denied(t, m, Op{Kind: "expand", Version: 10, Hash: "edited"})
	apply(t, m, Op{Kind: "expand", Version: 10, Hash: "10", Additive: true}, Op{Kind: "retire-begin", Version: 10}, Op{Kind: "retire-commit", Version: 10}, Op{Kind: "expand", Version: 11, Hash: "eleven"})
	denied(t, m, Op{Kind: "contract-end", Version: 11})
	denied(t, m, Op{Kind: "contract-begin", Version: 11})
	denied(t, m, Op{Kind: "expand", Version: 12, Hash: "twelve", Additive: true})
	apply(t, m, Op{Kind: "retire-begin", Version: 11}, Op{Kind: "retire-commit", Version: 11})
	denied(t, m, Op{Kind: "expand", Version: 12, Hash: "twelve", Additive: true})
	apply(t, m, Op{Kind: "contract-begin", Version: 11}, Op{Kind: "crash"})
	if m.Compat != 11 || m.Versions[11] != "contracting" {
		t.Fatal("crash lost compatibility switch")
	}
	apply(t, m, Op{Kind: "contract-end", Version: 11}, Op{Kind: "expand", Version: 12, Hash: "twelve", Additive: true})
}

// INV-GENERATION, INV-FINAL; TR-ROW-ADD, TR-BACKFILL, TR-INVALIDATE, TR-REPAIR, TR-REJECT.
func TestProvisionalBackfillCannotAuthorizeRetirement(t *testing.T) {
	m := NewModel(7, "seven")
	apply(t, m, Op{Kind: "expand", Version: 8, Hash: "eight"}, Op{Kind: "row-add", ID: "row", Generation: 3}, Op{Kind: "backfill", ID: "row"}, Op{Kind: "old-write", ID: "row", Version: 7}, Op{Kind: "retire-begin", Version: 8})
	denied(t, m, Op{Kind: "retire-commit", Version: 8})
	apply(t, m, Op{Kind: "reject", ID: "row"})
	denied(t, m, Op{Kind: "retire-commit", Version: 8})
	apply(t, m, Op{Kind: "backfill", ID: "row"}, Op{Kind: "retire-commit", Version: 8})
	denied(t, m, Op{Kind: "old-write", ID: "row", Version: 7})
	denied(t, m, Op{Kind: "row-add", ID: "overflow", Generation: 32767})
}

// INV-QUEUE-FLOOR, INV-CLAIMANT, INV-ATTEMPT; TR-ENQUEUE, TR-RESTAMP, TR-RENEW, TR-RETRY.
func TestSurvivingClaimantRestampPreservesAttemptAndLease(t *testing.T) {
	m := NewModel(7, "seven")
	apply(t, m, Op{Kind: "expand", Version: 8, Hash: "eight", Additive: true}, Op{Kind: "enqueue", ID: "job", Version: 7}, Op{Kind: "claim", ID: "job", Version: 8, Ticks: 60}, Op{Kind: "retire-begin", Version: 8})
	denied(t, m, Op{Kind: "retire-commit", Version: 8})
	claim := m.Jobs["job"]
	apply(t, m, Op{Kind: "restamp", ID: "job", Version: 8}, Op{Kind: "retire-commit", Version: 8})
	restamped := m.Jobs["job"]
	restamped.Version = claim.Version
	if restamped != claim {
		t.Fatal("restamp changed processing identity")
	}
	apply(t, m, Op{Kind: "renew", ID: "job", Version: 8, Attempt: 1, Ticks: 60}, Op{Kind: "retry", ID: "job", Version: 8, Attempt: 1})
	if m.Jobs["job"].Version != 8 {
		t.Fatal("requeue restored retired payload stamp")
	}
}

// INV-ATTEMPT, INV-CLAIMANT, INV-DECODER; TR-CLAIM, TR-EXPIRY, TR-COMPLETE.
func TestRetiringClaimantExpiresAndLateOutcomesAreRejected(t *testing.T) {
	m := NewModel(7, "seven")
	apply(t, m, Op{Kind: "expand", Version: 8, Hash: "eight", Additive: true}, Op{Kind: "enqueue", ID: "job", Version: 7}, Op{Kind: "claim", ID: "job", Version: 7, Ticks: 60}, Op{Kind: "retire-begin", Version: 8})
	denied(t, m, Op{Kind: "restamp", ID: "job", Version: 8})
	denied(t, m, Op{Kind: "renew", ID: "job", Version: 7, Attempt: 1, Ticks: 60})
	apply(t, m, Op{Kind: "tick", Ticks: 60}, Op{Kind: "restamp", ID: "job", Version: 8}, Op{Kind: "retire-commit", Version: 8}, Op{Kind: "claim", ID: "job", Version: 8, Ticks: 60})
	for _, kind := range []string{"complete", "retry", "dead", "renew"} {
		denied(t, m, Op{Kind: kind, ID: "job", Version: 7, Attempt: 1, Ticks: 60})
	}
	apply(t, m, Op{Kind: "complete", ID: "job", Version: 8, Attempt: 2})
}

// INV-QUEUE-FLOOR; TR-RESTAMP, TR-CRASH.
func TestCrashAfterRestampBeforeFloorCommitIsResumable(t *testing.T) {
	m := NewModel(1, "one")
	apply(t, m, Op{Kind: "expand", Version: 2, Hash: "two", Additive: true}, Op{Kind: "enqueue", ID: "job", Version: 1}, Op{Kind: "retire-begin", Version: 2}, Op{Kind: "restamp", ID: "job", Version: 2}, Op{Kind: "crash"})
	if m.Floor != 1 || m.Jobs["job"].Version != 2 {
		t.Fatal("crash lost durable restamp or advanced floor")
	}
	denied(t, m, Op{Kind: "retire-commit", Version: 2})
	apply(t, m, Op{Kind: "retire-begin", Version: 2}, Op{Kind: "retire-commit", Version: 2})
}

// INV-LEASE; TR-LEASE, TR-EXPIRY.
func TestStaleExecutorCannotCommitAfterTakeover(t *testing.T) {
	m := NewModel(7, "seven")
	apply(t, m, Op{Kind: "lease-acquire", ID: "backfill", Hash: "a", Ticks: 30})
	denied(t, m, Op{Kind: "lease-acquire", ID: "backfill", Hash: "b", Ticks: 30})
	apply(t, m, Op{Kind: "tick", Ticks: 30}, Op{Kind: "lease-acquire", ID: "backfill", Hash: "b", Ticks: 30})
	denied(t, m, Op{Kind: "lease-commit", ID: "backfill", Hash: "a", Attempt: 1})
	apply(t, m, Op{Kind: "lease-commit", ID: "backfill", Hash: "b", Attempt: 2})
}

// INV-ABI; TR-ABI-SELECT, TR-ABI-BATCH, TR-CRASH.
func TestABIChangeRefusedAfterFirstBatchOrProvisionalPass(t *testing.T) {
	for _, start := range []string{"abi-batch", "abi-provisional"} {
		m := NewModel(7, "seven")
		apply(t, m, Op{Kind: "expand", Version: 8, Hash: "eight"})
		apply(t, m, Op{Kind: "abi-select", ID: "Note", Version: 8, Generation: 4, Hash: "compiler-a"}, Op{Kind: "abi-select", ID: "Note", Version: 8, Generation: 4, Hash: "compiler-b"}, Op{Kind: start, ID: "Note", Version: 8, Generation: 4, Hash: "compiler-b"}, Op{Kind: "crash"})
		denied(t, m, Op{Kind: "abi-select", ID: "Note", Version: 8, Generation: 4, Hash: "compiler-c"})
		denied(t, m, Op{Kind: "abi-batch", ID: "Note", Version: 8, Generation: 4, Hash: "compiler-c"})
		apply(t, m, Op{Kind: "abi-batch", ID: "Note", Version: 8, Generation: 4, Hash: "compiler-b"})
		// The lock belongs to the whole migration, even for an entity with
		// no rows yet. Changing a different entity cannot bypass it.
		denied(t, m, Op{Kind: "abi-batch", ID: "Other", Version: 8, Generation: 1, Hash: "compiler-c"})
		denied(t, m, Op{Kind: "abi-batch", ID: "Note", Version: 8, Generation: 5, Hash: "compiler-c"})
		apply(t, m, Op{Kind: "abi-batch", ID: "Other", Version: 8, Generation: 1, Hash: "compiler-b"})
		// Reprocessing has a fresh generation in the next version, never an
		// override on old work. Historic ABI evidence survives that reprocess.
		apply(t, m, Op{Kind: "retire-begin", Version: 8}, Op{Kind: "retire-commit", Version: 8}, Op{Kind: "contract-begin", Version: 8}, Op{Kind: "contract-end", Version: 8}, Op{Kind: "expand", Version: 9, Hash: "nine"})
		apply(t, m, Op{Kind: "abi-batch", ID: "Note", Version: 9, Generation: 5, Hash: "compiler-c"})
		denied(t, m, Op{Kind: "abi-batch", ID: "Note", Version: 8, Generation: 4, Hash: "compiler-b"})
	}
}

// INV-ABI, INV-FENCE; TR-ABI-WRITE, TR-ABI-SELECT, TR-ABI-BATCH, TR-WRITE, TR-CRASH.
func TestApplicationTargetWriteLocksABIBeforeBackfillStarts(t *testing.T) {
	m := NewModel(7, "seven")
	apply(t, m, Op{Kind: "expand", Version: 8, Hash: "eight"})
	write := Op{Kind: "abi-write", ID: "Note", Version: 8, Generation: 4, Hash: "compiler-a", Holder: "app"}
	denied(t, m, write)
	apply(t, m, Op{Kind: "write-begin", ID: "app", Version: 7})
	denied(t, m, write)
	apply(t, m, Op{Kind: "write-end", ID: "app"}, Op{Kind: "write-begin", ID: "app", Version: 8})
	apply(t, m, write, Op{Kind: "write-end", ID: "app"}, Op{Kind: "crash"})
	processing := m.Processing["Note"]
	if processing.Rows != 0 || processing.Provisional || !processing.Written || !m.ABILocked[8] {
		t.Fatalf("application write must lock ABI independently of backfill counters: %+v", processing)
	}
	for _, operation := range []string{"abi-select", "abi-batch", "abi-provisional"} {
		denied(t, m, Op{Kind: operation, ID: "Note", Version: 8, Generation: 4, Hash: "compiler-b"})
		denied(t, m, Op{Kind: operation, ID: "AnotherEntity", Version: 8, Generation: 1, Hash: "compiler-b"})
		denied(t, m, Op{Kind: operation, Version: 8, Generation: 1, Hash: "compiler-a"})
	}
	apply(t, m, Op{Kind: "write-begin", ID: "different-build", Version: 8})
	denied(t, m, Op{Kind: "abi-write", ID: "Note", Version: 8, Generation: 4, Hash: "compiler-b", Holder: "different-build"})
	apply(t, m, Op{Kind: "write-end", ID: "different-build"}, Op{Kind: "abi-batch", ID: "Note", Version: 8, Generation: 4, Hash: "compiler-a"})
	// Lost or mismatched durable write evidence must be detected even with no
	// backfill/provisional counters. This is a consistency oracle; proof transfer
	// across compiler ABIs remains a separate typing requirement.
	for _, corrupt := range []func(*Model){
		func(n *Model) { n.ABILocked[8] = false },
		func(n *Model) { n.ExecutorABI[8] = "different" },
	} {
		n := m.Clone()
		p := n.Processing["Note"]
		p.Rows = 0
		n.Processing["Note"] = p
		corrupt(n)
		if n.Check() == nil {
			t.Fatal("application-write ABI evidence was not checked")
		}
	}
}

// INV-FENCE, INV-FLOOR, INV-ATTEMPT, INV-GENERATION; all model transitions.
// Invalid sequences matter as much as legal ones. The seed and entire prefix are
// reported on failure; refusals must be transactional and are checked each time.
func TestAdversarialTraces(t *testing.T) {
	kinds := []string{"expand", "write-begin", "write-end", "read-deliver", "retire-begin", "retire-commit", "contract-begin", "contract-end", "crash", "row-add", "backfill", "reject", "old-write", "row-delete", "quarantine-refresh", "repair-record", "repair-admit", "repair-final", "repair-row", "abi-select", "abi-batch", "abi-provisional", "abi-write", "enqueue", "claim", "renew", "complete", "retry", "dead", "restamp", "tick", "lease-acquire", "lease-commit"}
	steps := 500 * traceScale(t)
	for seed := int64(0); seed < 128; seed++ {
		t.Run(strconv.FormatInt(seed, 10), func(t *testing.T) {
			rng := rand.New(rand.NewSource(seed))
			m := NewModel(7, "seven")
			trace := make([]Op, 0, steps)
			for step := 0; step < steps; step++ {
				op := Op{Kind: kinds[rng.Intn(len(kinds))], ID: strconv.Itoa(rng.Intn(4)), Hash: strconv.Itoa(rng.Intn(4)), Version: 7 + rng.Intn(5), Generation: 1 + rng.Intn(4), Attempt: uint64(rng.Intn(4)), Ticks: int64(rng.Intn(20)), Additive: rng.Intn(2) == 0,
					Sequence: rng.Intn(5), Revision: uint64(rng.Intn(8)), Accept: rng.Intn(2) == 0, Reason: "trace rejection", Holder: strconv.Itoa(rng.Intn(4))}
				trace = append(trace, op)
				before := m.Clone()
				err := m.Apply(op)
				if err != nil && !reflect.DeepEqual(before, m) {
					t.Fatalf("seed=%d step=%d rejected mutation; trace=%+v", seed, step, trace)
				}
				if err := m.Check(); err != nil {
					t.Fatalf("seed=%d step=%d: %v; trace=%+v", seed, step, err, trace)
				}
			}
		})
	}
}

func traceScale(t *testing.T) int {
	t.Helper()
	value := os.Getenv("TESL_MIGRATION_TEST_TRACE_SCALE")
	if value == "" {
		return 1
	}
	scale, err := strconv.Atoi(value)
	if err != nil || scale < 1 || scale > 16 {
		t.Fatal("TESL_MIGRATION_TEST_TRACE_SCALE must be an integer in [1,16]")
	}
	return scale
}
