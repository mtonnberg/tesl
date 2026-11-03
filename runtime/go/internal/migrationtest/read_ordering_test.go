package migrationtest

import (
	"context"
	"fmt"
	"slices"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

// INV-READ, INV-CONTRACT, INV-FLOOR; TR-READ, TR-ADMIT, TR-RETIRE, TR-CONTRACT.
// These are protocol-oracle transactions, not generated runtime admission yet.
// Even an empty query holds ACCESS SHARE through admission and commit. Retirement
// can pass that query, but contract cannot drop its columns until the reader ends.
func TestPostgresTemplateQueryFirstAdmissionAcrossRetirement(t *testing.T) {
	for _, version := range []int{7, 8} {
		for _, shape := range []struct {
			name, query string
			want        []string
		}{
			{"rows", "select legacy from %s.notes", []string{"buffered-old-shape"}},
			{"missing-key", "select legacy from %s.notes where id=2", nil},
			{"constant-false", "select legacy from %s.notes where false", nil},
			{"zero-limit", "select legacy from %s.notes limit 0", nil},
			{"empty-aggregate", "select count(legacy)::text from %s.notes where false", []string{"0"}},
			{"empty-exists", "select exists(select legacy from %s.notes where false)::text", []string{"false"}},
		} {
			t.Run(fmt.Sprintf("V%d/%s", version, shape.name), func(t *testing.T) {
				f := newDatabaseFixture(t)
				f.expanded(t, 8)
				f.exec(t, "create table "+f.schema+".notes (id int primary key, legacy text)")
				f.exec(t, "insert into "+f.schema+".notes values (1,'buffered-old-shape')")
				ctx, cancel := context.WithCancel(f.ctx)
				defer cancel()
				reader, dropper := f.other(t), f.other(t)
				schedule := NewSchedule(f.dump)
				queried := Event{"query-complete", "reader", 1}
				admitted := Event{"admission-complete", "reader", 1}
				for _, event := range []Event{queried, admitted} {
					if err := schedule.Pause(event); err != nil {
						t.Fatal(err)
					}
				}
				type result struct {
					values []string
					floor  int
					err    error
				}
				done := make(chan result, 1)
				go func() {
					read := func() result {
						tx, err := reader.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
						if err != nil {
							return result{err: err}
						}
						defer func() { _ = tx.Rollback(ctx) }()
						rows, err := tx.Query(ctx, fmt.Sprintf(shape.query, f.schema))
						if err != nil {
							return result{err: err}
						}
						buffered, err := pgx.CollectRows(rows, pgx.RowTo[string])
						if err != nil {
							return result{err: err}
						}
						if err = schedule.Hit(ctx, queried); err != nil {
							return result{err: err}
						}
						var floor int
						if err = tx.QueryRow(ctx, "select "+f.schema+".tesl_admit($1)", version).Scan(&floor); err != nil {
							return result{err: err} // Refusal must discard buffered data.
						}
						if err = schedule.Hit(ctx, admitted); err != nil {
							return result{err: err}
						}
						if err = tx.Commit(ctx); err != nil {
							return result{err: err}
						}
						return result{values: buffered, floor: floor}
					}
					done <- read()
				}()
				if err := schedule.Await(ctx, queried); err != nil {
					t.Fatal(err)
				}
				f.exec(t, "begin")
				f.exec(t, "select pg_advisory_xact_lock($1,7)", f.fence)
				f.exec(t, "select "+f.schema+".tesl_advance_floor(7,8,'retire',1,'tesl-1','fixture')")
				f.exec(t, "select "+f.schema+".tesl_begin_contract(8,'contract',1,'tesl-1','fixture'); commit")
				dropped := make(chan error, 1)
				go func() {
					_, err := dropper.Exec(ctx, "alter table "+f.schema+".notes drop column legacy")
					dropped <- err
				}()
				for {
					var waiting bool
					if err := f.conn.QueryRow(ctx, "select exists(select 1 from pg_locks where pid=$1 and locktype='relation' and mode='AccessExclusiveLock' and not granted)", dropper.PgConn().PID()).Scan(&waiting); err != nil {
						t.Fatalf("%v\n%s", err, f.dump())
					}
					if waiting {
						break
					}
					select {
					case err := <-dropped:
						t.Fatalf("contract passed paused reader: %v\n%s", err, f.dump())
					default:
					}
				}
				if err := schedule.Release(queried); err != nil {
					t.Fatal(err)
				}
				if version == 8 {
					if err := schedule.Await(ctx, admitted); err != nil {
						t.Fatal(err)
					}
					var waiting bool
					if err := f.conn.QueryRow(ctx, "select exists(select 1 from pg_locks where pid=$1 and mode='AccessExclusiveLock' and not granted)", dropper.PgConn().PID()).Scan(&waiting); err != nil || !waiting {
						t.Fatalf("reader released its table lock before commit: waiting=%v, %v\n%s", waiting, err, f.dump())
					}
					if err := schedule.Release(admitted); err != nil {
						t.Fatal(err)
					}
				}
				select {
				case r := <-done:
					if version == 7 {
						if r.err == nil || !strings.Contains(r.err.Error(), "is retired") || len(r.values) != 0 {
							t.Fatalf("retired read delivered data or failed for wrong reason: %+v", r)
						}
					} else if r.err != nil || r.floor != 8 || !slices.Equal(r.values, shape.want) {
						t.Fatalf("surviving read did not learn settled floor and deliver its buffered result: %+v", r)
					}
				case <-ctx.Done():
					t.Fatalf("reader: %v\n%s", ctx.Err(), f.dump())
				}
				select {
				case err := <-dropped:
					if err != nil {
						t.Fatal(err)
					}
				case <-ctx.Done():
					t.Fatalf("contract: %v\n%s", ctx.Err(), f.dump())
				}
				var exists bool
				if err := f.conn.QueryRow(ctx, "select exists(select 1 from information_schema.columns where table_schema=$1 and table_name='notes' and column_name='legacy')", f.schema).Scan(&exists); err != nil || exists {
					t.Fatalf("contract did not drop the column after the reader ended: exists=%v, %v", exists, err)
				}
			})
		}
	}
}

// INV-FLOOR, INV-HISTORY, INV-CONTRACT, INV-FENCE; TR-RETIRE, TR-CONTRACT, TR-CRASH.
// A killed coordinator either loses both floor/lifecycle writes, or preserves
// both. A successor acquires the released session fence and resumes accordingly.
func TestPostgresTemplateCoordinatorDeathAtRetirementCommit(t *testing.T) {
	for _, committed := range []bool{false, true} {
		t.Run(fmt.Sprintf("committed=%v", committed), func(t *testing.T) {
			f := newDatabaseFixture(t)
			f.expanded(t, 8)
			coordinator := f.other(t)
			if _, err := coordinator.Exec(f.ctx, "select pg_advisory_lock($1,7)", f.fence); err != nil {
				t.Fatal(err)
			}
			if _, err := coordinator.Exec(f.ctx, "begin; select "+f.schema+".tesl_advance_floor(7,8,'retire',1,'tesl-1','dying'); select "+f.schema+".tesl_begin_contract(8,'contract',1,'tesl-1','dying')"); err != nil {
				t.Fatal(err)
			}
			if committed {
				if _, err := coordinator.Exec(f.ctx, "commit"); err != nil {
					t.Fatal(err)
				}
			}
			var killed bool
			if err := f.conn.QueryRow(f.ctx, "select pg_terminate_backend($1)", coordinator.PgConn().PID()).Scan(&killed); err != nil || !killed {
				t.Fatalf("terminate coordinator: %v, %v", killed, err)
			}
			// Acquiring the same lock is the acknowledgement of backend cleanup;
			// pg_terminate_backend returning alone does not guarantee it finished.
			f.exec(t, "begin")
			f.exec(t, "select pg_advisory_xact_lock($1,7)", f.fence)
			var floor, compat, retired, contracting int
			if err := f.conn.QueryRow(f.ctx, "select min_version,compat_floor,(select count(*) from "+f.schema+".tesl_schema_versions where version=7 and step='retired'),(select count(*) from "+f.schema+".tesl_schema_versions where version=8 and step='contracting') from "+f.schema+".tesl_schema_state").Scan(&floor, &compat, &retired, &contracting); err != nil {
				t.Fatal(err)
			}
			if committed {
				if floor != 8 || compat != 8 || retired != 1 || contracting != 1 {
					t.Fatalf("committed state was not durable: %d/%d/%d/%d", floor, compat, retired, contracting)
				}
			} else {
				if floor != 7 || compat != 7 || retired != 0 || contracting != 0 {
					t.Fatalf("partial retirement survived death: %d/%d/%d/%d", floor, compat, retired, contracting)
				}
				f.exec(t, "select "+f.schema+".tesl_advance_floor(7,8,'retire',1,'tesl-1','successor')")
			}
			f.exec(t, "select "+f.schema+".tesl_begin_contract(8,'contract',1,'tesl-1','successor')")
			f.exec(t, "select "+f.schema+".tesl_record_contracted(8,'contract',1,'tesl-1','successor'); commit")
			var rows int
			if err := f.conn.QueryRow(f.ctx, "select count(*) from "+f.schema+".tesl_schema_versions where version=8 and step in ('contracting','contracted')").Scan(&rows); err != nil || rows != 2 {
				t.Fatalf("successor did not finish exactly once: %d, %v", rows, err)
			}
		})
	}
}
