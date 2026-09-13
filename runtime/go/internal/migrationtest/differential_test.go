package migrationtest

import (
	"fmt"
	"math/rand"
	"testing"

	"github.com/jackc/pgx/v5"
)

// INV-FLOOR, INV-HISTORY, INV-LIFECYCLE, INV-READ; TR-EXPAND, TR-RETIRE, TR-CONTRACT, TR-ADMIT.
// Compare the SQL template to the separately written model, including refusal
// outcomes. A model that merely checks its own postconditions is not this test.
func TestPostgresTemplateAgainstReferenceTraces(t *testing.T) {
	for seed := int64(0); seed < 16; seed++ {
		t.Run(fmt.Sprint(seed), func(t *testing.T) {
			f := newDatabaseFixture(t)
			m := NewModel(7, "migration-7")
			rng := rand.New(rand.NewSource(seed))
			trace := []Op{}
			for step := 0; step < 48; step++ {
				var op Op
				var sql string
				var args []any
				switch rng.Intn(7) {
				case 0, 1:
					v := m.Expanded + 1
					op = Op{Kind: "expand", Version: v, Hash: fmt.Sprintf("migration-%d", v), Additive: true}
					sql = "select " + f.schema + ".tesl_record_expanded($1,$2,$3,1,'tesl-1',true,'trace')"
					args = []any{v, fmt.Sprintf("snapshot-%d", v), op.Hash}
				case 2:
					v := m.Expanded
					op = Op{Kind: "expand", Version: v, Hash: "edited", Additive: true}
					sql = "select " + f.schema + ".tesl_record_expanded($1,'edited','edited',1,'tesl-1',true,'trace')"
					args = []any{v}
				case 3:
					v := 7 + rng.Intn(m.Expanded-6)
					op = Op{Kind: "read-deliver", Version: v}
					sql = "select " + f.schema + ".tesl_admit($1)"
					args = []any{v}
				case 4:
					target := m.Expanded
					op = Op{Kind: "retire-begin", Version: target}
					f.exec(t, "begin")
					for v := m.Floor; v < target; v++ {
						f.exec(t, "select pg_advisory_xact_lock($1,$2)", f.fence, v)
					}
					sql = "select " + f.schema + ".tesl_advance_floor($1,$2,'retirement',1,'tesl-1','trace')"
					args = []any{m.Floor, target}
				case 5:
					v := m.Expanded
					if v == 7 || m.Versions[v] != "expanded" {
						continue
					}
					op = Op{Kind: "contract-begin", Version: v}
					sql = "select " + f.schema + ".tesl_begin_contract($1,'contract',1,'tesl-1','trace')"
					args = []any{v}
				case 6:
					v := m.Expanded
					if v == 7 {
						continue
					}
					op = Op{Kind: "contract-end", Version: v}
					sql = "select " + f.schema + ".tesl_record_contracted($1,'contract',1,'tesl-1','trace')"
					args = []any{v}
					if m.Versions[v] == "contracted" {
						continue
					} // equal retries have their own identity test
				}
				trace = append(trace, op)
				wantErr := m.Apply(op)
				_, gotErr := f.conn.Exec(f.ctx, sql, args...)
				if (wantErr == nil) != (gotErr == nil) {
					t.Fatalf("seed=%d step=%d model=%v PostgreSQL=%v trace=%+v", seed, step, wantErr, gotErr, trace)
				}
				if op.Kind == "retire-begin" {
					if gotErr == nil {
						f.exec(t, "commit")
						apply(t, m, Op{Kind: "retire-commit", Version: op.Version})
					} else {
						f.exec(t, "rollback")
					}
				}
				var floor, compat, current int
				if err := f.conn.QueryRow(f.ctx, "select min_version,compat_floor,current from "+f.schema+".tesl_schema_state where id=1").Scan(&floor, &compat, &current); err != nil {
					t.Fatal(err)
				}
				if floor != m.Floor || compat != m.Compat || current != m.Expanded {
					t.Fatalf("seed=%d step=%d database=(%d,%d,%d) model=(%d,%d,%d) trace=%+v", seed, step, floor, compat, current, m.Floor, m.Compat, m.Expanded, trace)
				}
				rows, err := f.conn.Query(f.ctx, "select version, max(artefact_hash) filter (where step='expanded'), bool_or(step='contracting'), bool_or(step='contracted'), bool_or(step='retired') from "+f.schema+".tesl_schema_versions group by version order by version")
				if err != nil {
					t.Fatal(err)
				}
				type lifecycle struct {
					version                          int
					hash                             string
					contracting, contracted, retired bool
				}
				states, err := pgx.CollectRows(rows, func(row pgx.CollectableRow) (lifecycle, error) {
					var value lifecycle
					err := row.Scan(&value.version, &value.hash, &value.contracting, &value.contracted, &value.retired)
					return value, err
				})
				if err != nil {
					t.Fatal(err)
				}
				if len(states) != len(m.Versions) {
					t.Fatalf("seed=%d step=%d lifecycle inventory differs: %+v trace=%+v", seed, step, states, trace)
				}
				for _, value := range states {
					state := "expanded"
					if value.contracted {
						state = "contracted"
					} else if value.contracting {
						state = "contracting"
					}
					if state != m.Versions[value.version] || value.hash != m.Hashes[value.version] || value.retired != (value.version < m.Floor) {
						t.Fatalf("seed=%d step=%d lifecycle differs: %+v model=%+v trace=%+v", seed, step, value, m.Versions, trace)
					}
				}
			}
		})
	}
}
