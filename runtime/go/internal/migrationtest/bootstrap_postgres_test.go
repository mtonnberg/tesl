package migrationtest

import (
	"fmt"
	"reflect"
	"runtime"
	"testing"

	"github.com/jackc/pgx/v5"
)

var bootstrapObjectOrder = []string{"notes.id", "notes.title", "notes.label"}

func selectInstallTarget(t *testing.T, f *databaseFixture, conn *pgx.Conn, version int) int {
	t.Helper()
	var selected int
	err := conn.QueryRow(f.ctx, "update "+f.schema+".tesl_schema_state set installing_version=coalesce(installing_version,$1) where id=1 and current=0 returning installing_version", version).Scan(&selected)
	if err != nil {
		t.Fatal(err)
	}
	return selected
}

// These short fixture statements implement the design's install_schema hook.
// They are deliberately independent of the oracle's catalog representation.
func installBootstrapObject(t *testing.T, f *databaseFixture, conn *pgx.Conn, object string) {
	t.Helper()
	var statement string
	switch object {
	case "notes.id":
		statement = "create table if not exists " + f.schema + ".bootstrap_notes(id int primary key)"
	case "notes.title":
		statement = "alter table " + f.schema + ".bootstrap_notes add column if not exists title text"
	case "notes.label":
		statement = "alter table " + f.schema + ".bootstrap_notes add column if not exists label text"
	default:
		t.Fatalf("unknown bootstrap fixture object %q", object)
	}
	f.execOn(t, conn, "set role "+f.worker)
	f.execOn(t, conn, statement)
	f.execOn(t, conn, "reset role")
}

func recordBootstrap(t *testing.T, f *databaseFixture, conn *pgx.Conn, version int, hash string) {
	t.Helper()
	f.execOn(t, conn, "set role "+f.worker)
	f.execOn(t, conn, "select "+f.schema+".tesl_record_expanded($1,$2,$3,1,'tesl-1',true,'bootstrap')", version, hash, "migration-"+hash)
	f.execOn(t, conn, "reset role")
}

func assertBootstrapDatabase(t *testing.T, f *databaseFixture, m *BootstrapModel) {
	t.Helper()
	var current, floor, compat, installing int
	err := f.conn.QueryRow(f.ctx, "select current,min_version,compat_floor,coalesce(installing_version,0) from "+f.schema+".tesl_schema_state where id=1").Scan(&current, &floor, &compat, &installing)
	if err != nil {
		t.Fatal(err)
	}
	wantCurrent, wantFloor, wantCompat := 0, 0, 0
	if m.History != nil {
		wantCurrent, wantFloor, wantCompat = m.History.Expanded, m.History.Floor, m.History.Compat
	}
	if current != wantCurrent || floor != wantFloor || compat != wantCompat || installing != m.Installing {
		t.Fatalf("SQL bootstrap state (%d,%d,%d,%d), model (%d,%d,%d,%d)", current, floor, compat, installing, wantCurrent, wantFloor, wantCompat, m.Installing)
	}
	rows, err := f.conn.Query(f.ctx, "select version,step,coalesce(snapshot_hash,''),artefact_hash,epoch_preserving from "+f.schema+".tesl_schema_versions order by version,step")
	if err != nil {
		t.Fatal(err)
	}
	type event struct {
		Version                  int
		Step, Snapshot, Artefact string
		Epoch                    *bool
	}
	actual, err := pgx.CollectRows(rows, pgx.RowToStructByPos[event])
	if err != nil {
		t.Fatal(err)
	}
	var expected []event
	if m.History != nil {
		for v := m.History.Base; v <= m.History.Expanded; v++ {
			hash := m.History.Hashes[v]
			if v == m.History.Base {
				expected = append(expected, event{v, "contracted", "", "migration-" + hash, nil}, event{v, "contracting", "", "migration-" + hash, nil})
			}
			epoch := true
			expected = append(expected, event{v, "expanded", hash, "migration-" + hash, &epoch})
		}
	}
	if len(actual) != len(expected) || (len(actual) != 0 && !reflect.DeepEqual(actual, expected)) {
		t.Fatalf("SQL bootstrap history %+v, model %+v", actual, expected)
	}
	rows, err = f.conn.Query(f.ctx, `select a.attname, format_type(a.atttypid,a.atttypmod), a.attnotnull,
		exists(select 1 from pg_constraint p where p.conrelid=c.oid and p.contype='p' and p.conkey=array[a.attnum]),
		pg_get_userbyid(c.relowner), a.atthasdef
		from pg_class c join pg_namespace n on n.oid=c.relnamespace join pg_attribute a on a.attrelid=c.oid
		where n.nspname=$1 and c.relname='bootstrap_notes' and a.attnum>0 and not a.attisdropped order by a.attnum`, f.schema)
	if err != nil {
		t.Fatal(err)
	}
	defer rows.Close()
	catalog := map[string]string{}
	for rows.Next() {
		var name, typ, owner string
		var required, primary, defaulted bool
		if err := rows.Scan(&name, &typ, &required, &primary, &owner, &defaulted); err != nil {
			t.Fatal(err)
		}
		if owner != f.worker || defaulted {
			t.Fatalf("unexpected owner/default for %s: %s/%t", name, owner, defaulted)
		}
		definition := typ
		if typ == "integer" && primary && required {
			definition = "int primary key"
		} else if !required && !primary {
			definition += " nullable"
		}
		catalog["notes."+name] = definition
	}
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(catalog, m.Catalog) {
		t.Fatalf("SQL bootstrap catalog %v, model %v", catalog, m.Catalog)
	}
}

func terminateBootstrapBackend(t *testing.T, f *databaseFixture, conn *pgx.Conn) {
	t.Helper()
	var terminated bool
	if err := f.conn.QueryRow(f.ctx, "select pg_terminate_backend($1)", conn.PgConn().PID()).Scan(&terminated); err != nil || !terminated {
		t.Fatalf("terminate boot backend: %t %v", terminated, err)
	}
	waitIndexBackendGone(t, f, conn.PgConn().PID())
}

// INV-BOOT-LOCK, INV-INSTALL-TARGET, INV-INSTALL-CATALOG, INV-INSTALL-ATOMIC;
// TR-BOOT-LOCK, TR-BOOT-CRASH, TR-INSTALL-SELECT, TR-INSTALL-OBJECT, TR-INSTALL-RECORD, TR-BOOT-EXPAND, TR-BOOT-RELEASE.
func TestPostgresBootstrapWinnerSurvivesEveryPartialInstallCrash(t *testing.T) {
	for _, winner := range []int{8, 9} {
		for progress := 0; progress <= len(bootstrapSnapshots()[winner].Objects); progress++ {
			t.Run(fmt.Sprintf("winner-%d/objects-%d", winner, progress), func(t *testing.T) {
				f := newUninstalledDatabaseFixture(t)
				m := NewBootstrapModel(bootstrapSnapshots())
				assertBootstrapDatabase(t, f, m)
				first, successor := f.other(t), f.other(t)
				f.execOn(t, first, "select pg_advisory_lock($1,2147483647)", f.fence)
				bootApply(t, m, Op{Kind: "boot-lock", Holder: "first"})
				if selected := selectInstallTarget(t, f, first, winner); selected != winner {
					t.Fatalf("selected V%d, want V%d", selected, winner)
				}
				bootApply(t, m, Op{Kind: "install-select", Holder: "first", Version: winner})
				assertBootstrapDatabase(t, f, m)
				for _, object := range bootstrapObjectOrder[:progress] {
					installBootstrapObject(t, f, first, object)
					bootApply(t, m, Op{Kind: "install-object", Holder: "first", Version: winner, ID: object, Hash: m.Snapshots[winner].Objects[object]})
					assertBootstrapDatabase(t, f, m)
				}
				// Expiry of the observability row cannot release a live backend's lock.
				f.exec(t, "update "+f.schema+".tesl_schema_leases set holder='first',token=1,expires_at=clock_timestamp()-interval '1 second' where name='boot'")
				locked := make(chan error, 1)
				go func() {
					_, err := successor.Exec(f.ctx, "select pg_advisory_lock($1,2147483647)", f.fence)
					locked <- err
				}()
				for {
					var waiting bool
					if err := f.conn.QueryRow(f.ctx, "select exists(select 1 from pg_locks where pid=$1 and locktype='advisory' and classid=$2::oid and objid=2147483647::oid and not granted)", successor.PgConn().PID(), f.fence).Scan(&waiting); err != nil {
						t.Fatal(err)
					}
					if waiting {
						break
					}
					select {
					case err := <-locked:
						t.Fatalf("expired lease bypassed the live boot lock: %v", err)
					default:
					}
					runtime.Gosched()
				}
				bootDenied(t, m, Op{Kind: "boot-lock", Holder: "successor"})
				terminateBootstrapBackend(t, f, first)
				select {
				case err := <-locked:
					if err != nil {
						t.Fatal(err)
					}
				case <-f.ctx.Done():
					t.Fatalf("successor did not acquire released boot lock: %s", f.dump())
				}
				bootApply(t, m, Op{Kind: "boot-crash", Holder: "first"}, Op{Kind: "boot-lock", Holder: "successor"}, Op{Kind: "install-select", Holder: "successor", Version: 9})
				if selected := selectInstallTarget(t, f, successor, 9); selected != winner {
					t.Fatalf("newer executor replaced V%d with V%d", winner, selected)
				}
				assertBootstrapDatabase(t, f, m)
				for v := winner; v <= 9; v++ {
					for _, object := range bootstrapObjectOrder[:len(m.Snapshots[v].Objects)] {
						installBootstrapObject(t, f, successor, object)
						bootApply(t, m, Op{Kind: "install-object", Holder: "successor", Version: v, ID: object, Hash: m.Snapshots[v].Objects[object]})
						assertBootstrapDatabase(t, f, m)
					}
					kind := "boot-expand"
					if v == winner {
						kind = "install-record"
					}
					for retry := 0; retry < 2; retry++ {
						recordBootstrap(t, f, successor, v, m.Snapshots[v].Hash)
						bootApply(t, m, Op{Kind: kind, Holder: "successor", Version: v, Hash: m.Snapshots[v].Hash})
						assertBootstrapDatabase(t, f, m)
					}
				}
				for _, version := range []int{8, 9} {
					var floor int
					err := f.conn.QueryRow(f.ctx, "select "+f.schema+".tesl_admit($1)", version).Scan(&floor)
					if (err == nil) != m.History.Admitted(version) {
						t.Fatalf("initial winner V%d: admission V%d disagrees with model: %v", winner, version, err)
					}
				}
				f.execOn(t, successor, "select pg_advisory_unlock($1,2147483647)", f.fence)
				bootApply(t, m, Op{Kind: "boot-release", Holder: "successor"})
			})
		}
	}
}

// INV-INSTALL-ATOMIC, INV-INSTALL-TARGET, INV-HISTORY; TR-INSTALL-RECORD, TR-BOOT-CRASH.
func TestPostgresBootstrapRecordCommitIsAtomicAcrossBackendDeath(t *testing.T) {
	for _, committed := range []bool{false, true} {
		t.Run(fmt.Sprintf("committed=%t", committed), func(t *testing.T) {
			f := newUninstalledDatabaseFixture(t)
			m := NewBootstrapModel(bootstrapSnapshots())
			first := f.other(t)
			f.execOn(t, first, "select pg_advisory_lock($1,2147483647)", f.fence)
			bootApply(t, m, Op{Kind: "boot-lock", Holder: "first"}, Op{Kind: "install-select", Holder: "first", Version: 8})
			selectInstallTarget(t, f, first, 8)
			for _, object := range bootstrapObjectOrder[:2] {
				installBootstrapObject(t, f, first, object)
				bootApply(t, m, Op{Kind: "install-object", Holder: "first", Version: 8, ID: object, Hash: m.Snapshots[8].Objects[object]})
			}
			if _, err := first.Exec(f.ctx, "select "+f.schema+".tesl_record_expanded(9,'nine','migration-nine',1,'tesl-1',true,'wrong')"); err == nil {
				t.Fatal("wrong initial target was recorded")
			}
			assertBootstrapDatabase(t, f, m)
			f.execOn(t, first, "begin")
			recordBootstrap(t, f, first, 8, "eight")
			// Independent readers must see neither half before commit.
			assertBootstrapDatabase(t, f, m)
			if committed {
				f.execOn(t, first, "commit")
				bootApply(t, m, Op{Kind: "install-record", Holder: "first", Version: 8, Hash: "eight"})
			}
			terminateBootstrapBackend(t, f, first)
			bootApply(t, m, Op{Kind: "boot-crash", Holder: "first"})
			assertBootstrapDatabase(t, f, m)
			recovery := f.other(t)
			f.execOn(t, recovery, "select pg_advisory_lock($1,2147483647)", f.fence)
			bootApply(t, m, Op{Kind: "boot-lock", Holder: "recovery"})
			recordBootstrap(t, f, recovery, 8, "eight")
			bootApply(t, m, Op{Kind: "install-record", Holder: "recovery", Version: 8, Hash: "eight"})
			assertBootstrapDatabase(t, f, m)
		})
	}
}
