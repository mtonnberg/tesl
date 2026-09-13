package migrationtest

import (
	"fmt"
	"math/rand"
	"reflect"
	"slices"
	"strconv"
	"testing"

	"github.com/jackc/pgx/v5"
)

// INV-REPAIR-HISTORY, INV-REPAIR-EXECUTOR, INV-HISTORY; TR-REPAIR-RECORD, TR-REPAIR-ADMIT, TR-REPAIR-FINAL.
func TestRepairPrefixesPreserveRollbackButRequireCompleteExecutor(t *testing.T) {
	for recorded := 0; recorded <= 4; recorded++ {
		for embedded := 0; embedded <= 4; embedded++ {
			t.Run(fmt.Sprintf("recorded-%d/embedded-%d", recorded, embedded), func(t *testing.T) {
				m := NewModel(7, "seven")
				apply(t, m, Op{Kind: "expand", Version: 8, Hash: "eight"})
				chain := []string{"first", "second", "third", "fourth"}
				for i, hash := range chain[:recorded] {
					apply(t, m, Op{Kind: "repair-record", Version: 8, Sequence: i + 1, Hash: hash})
				}
				apply(t, m, Op{Kind: "repair-admit", Version: 8, RepairHashes: chain[:embedded]})
				final := Op{Kind: "repair-final", Version: 8, RepairHashes: chain[:embedded]}
				if embedded < recorded {
					denied(t, m, final)
				} else {
					apply(t, m, final)
				}
				for changed := 0; changed < min(recorded, embedded); changed++ {
					edited := slices.Clone(chain[:embedded])
					edited[changed] = "edited"
					for _, kind := range []string{"repair-admit", "repair-final"} {
						denied(t, m, Op{Kind: kind, Version: 8, RepairHashes: edited})
					}
				}
				if m.Hashes[8] != "eight" || !m.Admitted(7) {
					t.Fatal("repair changed migration identity or rollback admission")
				}
			})
		}
	}
}

// INV-REPAIR-HISTORY, INV-REPAIR-EXECUTOR; TR-REPAIR-RECORD, TR-REPAIR-FINAL, TR-CRASH.
func TestHistoricalRepairIsAppendOnlyAndSurvivesCrash(t *testing.T) {
	m := NewModel(7, "seven")
	apply(t, m, Op{Kind: "expand", Version: 8, Hash: "eight", Additive: true},
		Op{Kind: "retire-begin", Version: 8}, Op{Kind: "retire-commit", Version: 8},
		Op{Kind: "contract-begin", Version: 8}, Op{Kind: "contract-end", Version: 8},
		Op{Kind: "expand", Version: 9, Hash: "nine", Additive: true},
		Op{Kind: "retire-begin", Version: 9}, Op{Kind: "retire-commit", Version: 9})
	for _, seq := range []int{-1, 0, 2, 32768} {
		denied(t, m, Op{Kind: "repair-record", Version: 8, Sequence: seq, Hash: "first"})
	}
	denied(t, m, Op{Kind: "repair-record", Version: 10, Sequence: 1, Hash: "first"})
	denied(t, m, Op{Kind: "repair-record", Version: 8, Sequence: 1})
	apply(t, m, Op{Kind: "repair-record", Version: 8, Sequence: 1, Hash: "first"},
		Op{Kind: "repair-record", Version: 8, Sequence: 2, Hash: "second"}, Op{Kind: "crash"})
	before := m.Clone()
	apply(t, m, Op{Kind: "repair-record", Version: 8, Sequence: 1, Hash: "first"})
	if !reflect.DeepEqual(m, before) {
		t.Fatal("retry rewrote a recorded repair")
	}
	denied(t, m, Op{Kind: "repair-record", Version: 8, Sequence: 1, Hash: "edited"})
	denied(t, m, Op{Kind: "repair-final", Version: 8, RepairHashes: []string{"first"}})
	apply(t, m, Op{Kind: "repair-final", Version: 8, RepairHashes: []string{"first", "second"}})
	if m.Admitted(8) || m.Floor != 9 || m.Hashes[8] != "eight" {
		t.Fatal("catch-up repair altered live admission or frozen migration identity")
	}
	// Model snapshots own their chain storage. A rejected speculative operation
	// must not corrupt the original through a shared slice backing array.
	clone := m.Clone()
	cloned, original := clone.Repairs[8], m.Repairs[8]
	if len(cloned) == 0 || len(original) == 0 {
		t.Fatal("recorded repair is missing from model snapshot")
	}
	cloned[0] = "edited"
	if original[0] != "first" {
		t.Fatal("model clones share repair storage")
	}
}

// INV-REPAIR-HISTORY; TR-REPAIR-RECORD.
func TestRepairSequenceBoundsAndCorruptedEvidence(t *testing.T) {
	m := NewModel(7, "seven")
	chain := make([]string, 32767)
	for i := range chain {
		chain[i] = strconv.Itoa(i + 1)
	}
	m.Repairs[7] = slices.Clone(chain[:32766])
	apply(t, m, Op{Kind: "repair-record", Version: 7, Sequence: 32767, Hash: "32767"})
	denied(t, m, Op{Kind: "repair-record", Version: 7, Sequence: 32768, Hash: "overflow"})
	for _, corrupt := range []func(*Model){
		func(m *Model) { delete(m.Hashes, 7) },
		func(m *Model) { m.Repairs[7][100] = "" },
		func(m *Model) { m.Repairs[7] = append(m.Repairs[7], "overflow") },
	} {
		clone := m.Clone()
		corrupt(clone)
		if err := clone.Check(); err == nil {
			t.Fatal("corrupted repair evidence was accepted")
		}
	}
	for _, hashes := range [][]string{{""}, {"1", ""}, append(slices.Clone(chain), "overflow")} {
		denied(t, m, Op{Kind: "repair-admit", Version: 7, RepairHashes: hashes})
	}
}

// INV-REPAIR-HISTORY, INV-LIFECYCLE, INV-HISTORY; TR-REPAIR-RECORD, TR-CRASH.
// The model supplies the expected result; the independently authored normative
// SQL supplies the actual result, including every refusal's durable state.
func TestPostgresRepairHistoryAgainstReferenceTraces(t *testing.T) {
	for seed := int64(0); seed < 16; seed++ {
		t.Run(fmt.Sprint(seed), func(t *testing.T) {
			f := newDatabaseFixture(t)
			f.expanded(t, 8)
			m := NewModel(7, "migration-7")
			apply(t, m, Op{Kind: "expand", Version: 8, Hash: "migration-8", Additive: true})
			rng := rand.New(rand.NewSource(seed))
			trace := []Op{}
			for step := 0; step < 48; step++ {
				v := 7 + rng.Intn(3)
				q := len(m.Repairs[v]) + 1
				if rng.Intn(2) == 0 {
					q = rng.Intn(q+3) - 1
				}
				op := Op{Kind: "repair-record", Version: v, Sequence: q, Hash: fmt.Sprintf("repair-%d", rng.Intn(4))}
				if rng.Intn(8) == 0 {
					op.Hash = ""
				}
				trace = append(trace, op)
				before := m.Clone()
				wantErr := m.Apply(op)
				f.exec(t, "begin")
				_, gotErr := f.conn.Exec(f.ctx, "select "+f.schema+".tesl_record_repair($1,$2,$3,1,'tesl-1','trace')", v, q, op.Hash)
				if (wantErr == nil) != (gotErr == nil) {
					t.Fatalf("seed=%d step=%d model=%v PostgreSQL=%v trace=%+v", seed, step, wantErr, gotErr, trace)
				}
				if gotErr != nil || step%7 == 0 {
					f.exec(t, "rollback")
					m = before
				} else {
					// An equal retry must leave this transaction usable.
					f.exec(t, "select 42")
					f.exec(t, "commit")
				}
				rows, err := f.conn.Query(f.ctx, "select version,seq,artefact_hash from "+f.schema+".tesl_schema_versions where step='repair' order by version,seq")
				if err != nil {
					t.Fatal(err)
				}
				type record struct {
					Version, Sequence int
					Hash              string
				}
				records, err := pgx.CollectRows(rows, pgx.RowToStructByPos[record])
				if err != nil {
					t.Fatal(err)
				}
				actual := map[int][]string{}
				for _, r := range records {
					if r.Sequence != len(actual[r.Version])+1 {
						t.Fatalf("database repair gap: %+v; trace=%+v", records, trace)
					}
					actual[r.Version] = append(actual[r.Version], r.Hash)
				}
				if !reflect.DeepEqual(actual, m.Repairs) {
					t.Fatalf("seed=%d step=%d database=%+v model=%+v trace=%+v", seed, step, actual, m.Repairs, trace)
				}
			}
		})
	}
}

// INV-ATTEMPT, INV-QUEUE-FLOOR; TR-CLAIM, TR-DEAD, TR-RESTAMP.
func TestDeadJobCannotBeClaimedWithoutExplicitReplay(t *testing.T) {
	m := NewModel(7, "seven")
	apply(t, m, Op{Kind: "enqueue", ID: "job", Version: 7}, Op{Kind: "claim", ID: "job", Version: 7, Ticks: 5},
		Op{Kind: "dead", ID: "job", Version: 7, Attempt: 1}, Op{Kind: "tick", Ticks: 5})
	denied(t, m, Op{Kind: "claim", ID: "job", Version: 7, Ticks: 5})
	apply(t, m, Op{Kind: "expand", Version: 8, Hash: "eight", Additive: true},
		Op{Kind: "retire-begin", Version: 8}, Op{Kind: "restamp", ID: "job", Version: 8},
		Op{Kind: "retire-commit", Version: 8})
	denied(t, m, Op{Kind: "claim", ID: "job", Version: 8, Ticks: 5})
	if m.Jobs["job"].Status != "dead" || m.Jobs["job"].Version != 8 {
		t.Fatal("retirement resurrected a dead job")
	}
}
