package migrationtest

import (
	"math"
	"testing"
)

func indexOp(kind, holder string, token uint64) Op {
	return Op{Kind: kind, ID: "notes_title_v8", Holder: holder, Attempt: token, Version: 8}
}

func plannedIndex(t *testing.T) *Model {
	t.Helper()
	m := NewModel(7, "seven")
	apply(t, m, Op{Kind: "expand", Version: 8, Hash: "eight", Additive: true},
		Op{Kind: "index-plan", ID: "notes_title_v8", Version: 8, Hash: "typed-title-key"},
		Op{Kind: "lease-acquire", ID: "index:notes_title_v8", Hash: "first", Ticks: 10},
		indexOp("index-enter", "first", 1))
	return m
}

// INV-INDEX-RECOVERY, INV-INDEX-READY, INV-DDL-JOB, INV-LEASE; TR-INDEX-PLAN, TR-INDEX-START, TR-INDEX-SUCCESS, TR-INDEX-CLEANUP, TR-INDEX-VERIFY.
func TestExpiredIndexLeaseCannotDestroyAnActiveOrValidBuild(t *testing.T) {
	m := plannedIndex(t)
	apply(t, m, indexOp("index-start", "first", 1), Op{Kind: "tick", Ticks: 10},
		Op{Kind: "lease-acquire", ID: "index:notes_title_v8", Hash: "second", Ticks: 10},
		indexOp("index-enter", "second", 2))
	denied(t, m, indexOp("index-cleanup", "second", 2))
	denied(t, m, indexOp("index-start", "second", 2))
	denied(t, m, indexOp("index-exit", "first", 1))
	denied(t, m, indexOp("index-verify", "second", 2))
	// Server success is independent of the expired scheduling lease. The old
	// worker cannot publish; the successor adopts only the verified valid shape.
	apply(t, m, indexOp("index-success", "first", 1))
	denied(t, m, indexOp("index-verify", "first", 1))
	denied(t, m, indexOp("index-cleanup", "second", 2))
	apply(t, m, indexOp("index-verify", "second", 2), indexOp("index-exit", "first", 1), indexOp("index-exit", "second", 2))
	job := m.Indexes["notes_title_v8"]
	if !job.Ready || job.Attempts != 1 || job.Catalog != "valid" {
		t.Fatalf("successor destroyed or rebuilt a successful index: %+v", job)
	}
}

// INV-DDL-TERMINAL, INV-DDL-JOB, INV-INDEX-READY; TR-INDEX-TERMINAL, TR-INDEX-DROP, TR-CONTRACT, TR-CRASH.
func TestContractWaitsForSurvivingIndexWorkerAndCannotResurrectJob(t *testing.T) {
	m := plannedIndex(t)
	apply(t, m, indexOp("index-start", "first", 1), Op{Kind: "retire-begin", Version: 8},
		Op{Kind: "retire-commit", Version: 8}, Op{Kind: "contract-begin", Version: 8})
	terminal := Op{Kind: "index-terminal", ID: "notes_title_v8", Version: 8}
	denied(t, m, terminal)
	denied(t, m, indexOp("index-drop", "", 0))
	apply(t, m, indexOp("index-success", "first", 1), indexOp("index-verify", "first", 1))
	denied(t, m, terminal)
	apply(t, m, indexOp("index-exit", "first", 1), terminal, Op{Kind: "crash"})
	denied(t, m, indexOp("index-enter", "first", 1))
	apply(t, m, indexOp("index-drop", "", 0), Op{Kind: "crash"}, terminal,
		indexOp("index-drop", "", 0), Op{Kind: "index-plan", ID: "notes_title_v8", Version: 8, Hash: "typed-title-key"})
	denied(t, m, indexOp("index-enter", "first", 1))
	job := m.Indexes["notes_title_v8"]
	if !job.Terminal || job.Catalog != "absent" || job.Ready {
		t.Fatalf("interrupted contract resurrected index work: %+v", job)
	}
}

// INV-DDL-TERMINAL, INV-CONTRACT; TR-INDEX-TERMINAL, TR-INDEX-DROP, TR-CONTRACT, TR-CRASH.
func TestTerminalBeforePlanSwitchDoesNotAuthorizeEarlyDrop(t *testing.T) {
	m := plannedIndex(t)
	apply(t, m, indexOp("index-start", "first", 1), indexOp("index-success", "first", 1),
		indexOp("index-exit", "first", 1))
	terminal := Op{Kind: "index-terminal", ID: "notes_title_v8", Version: 8}
	denied(t, m, terminal)
	apply(t, m, Op{Kind: "retire-begin", Version: 8}, Op{Kind: "retire-commit", Version: 8}, terminal)
	// The documented recipe records terminal under exclusive job locks before
	// announcing the plan switch. A crash in between must not authorize DROP.
	apply(t, m, Op{Kind: "crash"})
	denied(t, m, indexOp("index-drop", "", 0))
	denied(t, m, Op{Kind: "index-terminal", ID: "notes_title_v8", Version: 7})
	apply(t, m, terminal, Op{Kind: "contract-begin", Version: 8}, indexOp("index-drop", "", 0))
}

// INV-DDL-TERMINAL, INV-CONTRACT, INV-INDEX-IDENTITY; TR-INDEX-TERMINAL, TR-INDEX-DROP, TR-CONTRACT, TR-CRASH.
func TestIndexRemovalUsesContractVersionInsteadOfCreatingVersion(t *testing.T) {
	m := plannedIndex(t)
	apply(t, m, indexOp("index-start", "first", 1), indexOp("index-success", "first", 1),
		indexOp("index-verify", "first", 1), indexOp("index-exit", "first", 1),
		Op{Kind: "retire-begin", Version: 8}, Op{Kind: "retire-commit", Version: 8},
		Op{Kind: "contract-begin", Version: 8}, Op{Kind: "contract-end", Version: 8},
		Op{Kind: "expand", Version: 9, Hash: "nine", Additive: true})
	terminal := Op{Kind: "index-terminal", ID: "notes_title_v8", Version: 9}
	denied(t, m, terminal)
	apply(t, m, Op{Kind: "retire-begin", Version: 9}, Op{Kind: "retire-commit", Version: 9}, terminal,
		Op{Kind: "crash"})
	// Compat already equals 8, but V9 has not announced its drops. The V8
	// creation stamp cannot stand in for V9's persisted contract identity.
	denied(t, m, indexOp("index-drop", "", 0))
	denied(t, m, Op{Kind: "index-terminal", ID: "notes_title_v8", Version: 8})
	for _, version := range []int{0, 7, 10, 2147483647} {
		clone := m.Clone()
		job := clone.Indexes["notes_title_v8"]
		job.ContractVersion = version
		clone.Indexes["notes_title_v8"] = job
		if err := clone.Check(); err == nil {
			t.Fatalf("accepted invalid persisted contract target %d", version)
		}
	}
	apply(t, m, terminal, Op{Kind: "contract-begin", Version: 9}, indexOp("index-drop", "", 0),
		Op{Kind: "crash"}, terminal, indexOp("index-drop", "", 0))
	if job := m.Indexes["notes_title_v8"]; !job.Terminal || job.Catalog != "absent" || job.Version != 8 || job.ContractVersion != 9 {
		t.Fatalf("V9 removal lost the V8 index identity: %+v", job)
	}
}

// INV-DDL-JOB, INV-FENCE, INV-DDL-TERMINAL; TR-INDEX-ENTER, TR-INDEX-EXIT, TR-INDEX-VERIFY, TR-RETIRE, TR-INDEX-TERMINAL.
func TestSuccessorIndexWorkerUsesItsOwnAdmissionVersion(t *testing.T) {
	m := plannedIndex(t)
	apply(t, m, indexOp("index-exit", "first", 1),
		Op{Kind: "expand", Version: 9, Hash: "nine", Additive: true},
		Op{Kind: "tick", Ticks: 10}, Op{Kind: "lease-acquire", ID: "index:notes_title_v8", Hash: "successor", Ticks: 10})
	for _, version := range []int{0, 7, 10, 2147483647} {
		denied(t, m, Op{Kind: "index-enter", ID: "notes_title_v8", Version: version, Holder: "successor", Attempt: 2})
	}
	successor := func(kind string) Op {
		return Op{Kind: kind, ID: "notes_title_v8", Version: 9, Holder: "successor", Attempt: 2}
	}
	apply(t, m, successor("index-enter"), successor("index-start"),
		Op{Kind: "retire-begin", Version: 9}, Op{Kind: "retire-commit", Version: 9})
	// V8 has retired. Its unfinished index can still be completed by the V9
	// executor that holds V9's fence and the same immutable DDL-job lock.
	denied(t, m, indexOp("index-enter", "first", 1))
	denied(t, m, indexOp("index-success", "successor", 2))
	denied(t, m, Op{Kind: "index-terminal", ID: "notes_title_v8", Version: 9})
	apply(t, m, successor("index-success"), successor("index-verify"))
	for _, version := range []int{0, 7, 8, 10} {
		clone := m.Clone()
		clone.Indexes["notes_title_v8"].Holders["successor"] = IndexHolder{Attempt: 2, Version: version}
		if err := clone.Check(); err == nil {
			t.Fatalf("accepted a DDL holder with invalid admission version %d", version)
		}
	}
	apply(t, m, successor("index-exit"), Op{Kind: "index-terminal", ID: "notes_title_v8", Version: 9})
}

// INV-INDEX-RECOVERY, INV-INDEX-READY, INV-INDEX-BUILD, INV-DDL-JOB; TR-INDEX-FAILURE, TR-INDEX-BACKEND-DEATH, TR-INDEX-CLEANUP, TR-INDEX-EXIT, TR-CRASH.
func TestIndexRecoveryAtEveryBuildBoundary(t *testing.T) {
	for _, boundary := range []string{"before-create", "during-create", "failed-create", "valid-before-verify", "verified-before-exit", "after-exit"} {
		t.Run(boundary, func(t *testing.T) {
			m := plannedIndex(t)
			if boundary != "before-create" {
				apply(t, m, indexOp("index-start", "first", 1))
			}
			switch boundary {
			case "failed-create":
				apply(t, m, indexOp("index-failure", "first", 1))
			case "valid-before-verify", "verified-before-exit", "after-exit":
				apply(t, m, indexOp("index-success", "first", 1))
			}
			if boundary == "verified-before-exit" || boundary == "after-exit" {
				apply(t, m, indexOp("index-verify", "first", 1))
			}
			if boundary == "after-exit" {
				apply(t, m, indexOp("index-exit", "first", 1))
			} else {
				apply(t, m, indexOp("index-backend-death", "first", 1))
			}
			apply(t, m, Op{Kind: "crash"}, Op{Kind: "tick", Ticks: 10},
				Op{Kind: "lease-acquire", ID: "index:notes_title_v8", Hash: "second", Ticks: 10}, indexOp("index-enter", "second", 2))
			if m.Indexes["notes_title_v8"].Catalog == "invalid" {
				apply(t, m, indexOp("index-cleanup", "second", 2))
			}
			if m.Indexes["notes_title_v8"].Catalog == "absent" {
				apply(t, m, indexOp("index-start", "second", 2), indexOp("index-success", "second", 2))
			}
			apply(t, m, indexOp("index-verify", "second", 2), indexOp("index-exit", "second", 2))
			job := m.Indexes["notes_title_v8"]
			attempts := uint64(1)
			if boundary == "during-create" || boundary == "failed-create" {
				attempts = 2
			}
			if !job.Ready || job.Attempts != attempts || job.Catalog != "valid" || len(job.Holders) != 0 {
				t.Fatalf("unexpected recovered catalog: %+v", job)
			}
		})
	}
}

// INV-INDEX-IDENTITY, INV-INDEX-READY, INV-DDL-JOB, INV-FENCE; TR-INDEX-VERIFY, TR-INDEX-ENTER, TR-RETIRE.
func TestIndexCatalogIdentityAndWorkerFencesAreIndependentChecks(t *testing.T) {
	m := plannedIndex(t)
	denied(t, m, Op{Kind: "index-plan", ID: "notes_title_v8", Version: 8, Hash: "different-collation"})
	denied(t, m, indexOp("index-enter", "first", 1))
	denied(t, m, indexOp("index-verify", "first", 1))
	apply(t, m, indexOp("index-start", "first", 1), indexOp("index-success", "first", 1))
	job := m.Indexes["notes_title_v8"]
	job.Observed = "different-collation"
	m.Indexes["notes_title_v8"] = job
	denied(t, m, indexOp("index-verify", "first", 1))
	denied(t, m, indexOp("index-cleanup", "first", 1))
	job.Observed = job.Expected
	m.Indexes["notes_title_v8"] = job
	apply(t, m, indexOp("index-verify", "first", 1))
	for _, corrupt := range []func(*Model){
		func(m *Model) {
			j := m.Indexes["notes_title_v8"]
			j.Observed = "different-key"
			m.Indexes["notes_title_v8"] = j
		},
		func(m *Model) { j := m.Indexes["notes_title_v8"]; j.Terminal = true; m.Indexes["notes_title_v8"] = j },
		func(m *Model) {
			j := m.Indexes["notes_title_v8"]
			j.Attempts = math.MaxInt32 + 1
			m.Indexes["notes_title_v8"] = j
		},
		func(m *Model) {
			j := m.Indexes["notes_title_v8"]
			j.Catalog = "invalid"
			m.Indexes["notes_title_v8"] = j
		},
		func(m *Model) { m.Indexes["notes_title_v8"].Holders["first"] = IndexHolder{Attempt: 2, Version: 8} },
	} {
		clone := m.Clone()
		corrupt(clone)
		if err := clone.Check(); err == nil {
			t.Fatal("corrupted index evidence was accepted")
		}
	}
	if m.Indexes["notes_title_v8"].Holders["first"].Attempt != 1 {
		t.Fatal("model snapshots share index holder storage")
	}
	apply(t, m, Op{Kind: "expand", Version: 9, Hash: "nine", Additive: true})
	denied(t, m, Op{Kind: "retire-begin", Version: 9})
	apply(t, m, indexOp("index-exit", "first", 1), Op{Kind: "retire-begin", Version: 9}, Op{Kind: "retire-commit", Version: 9})
	denied(t, m, indexOp("index-enter", "first", 1))
}
