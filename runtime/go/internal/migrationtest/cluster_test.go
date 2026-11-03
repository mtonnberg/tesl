package migrationtest

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// This fixture owns the entire cluster. Never stop/restart the matrix service or
// a database selected by TESL_MIGRATION_TEST_DSN: other tests may be using it.
type ownedCluster struct {
	dir, socket, pgctl string
}

func ownedClusterDirectory(t *testing.T) *ownedCluster {
	t.Helper()
	if os.Getenv("TESL_MIGRATION_TEST_CLUSTER_CRASH") != "1" {
		t.Skip("set TESL_MIGRATION_TEST_CLUSTER_CRASH=1 for disposable crash and replica tests")
	}
	pgctl, err := exec.LookPath("pg_ctl")
	if err != nil {
		t.Fatal(err)
	}
	dir, err := os.MkdirTemp("", "tesl-migration-primary-")
	if err != nil {
		t.Fatal(err)
	}
	c := &ownedCluster{dir: dir, socket: filepath.Join(dir, "socket"), pgctl: pgctl}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		data := filepath.Join(c.dir, "data")
		_, stopErr := exec.CommandContext(ctx, c.pgctl, "-D", data, "-m", "immediate", "-w", "-t", "5", "stop").CombinedOutput()
		if stopErr != nil && exec.CommandContext(ctx, c.pgctl, "-D", data, "status").Run() == nil {
			t.Errorf("owned primary did not stop; retaining its data at %s", c.dir)
			return
		}
		if err := os.RemoveAll(c.dir); err != nil {
			t.Error(err)
		}
	})
	if err := os.Mkdir(c.socket, 0700); err != nil {
		t.Fatal(err)
	}
	return c
}

func newOwnedCluster(t *testing.T) *ownedCluster {
	t.Helper()
	c := ownedClusterDirectory(t)
	initdb, err := exec.LookPath("initdb")
	if err != nil {
		t.Fatal(err)
	}
	c.command(t, initdb, "-D", filepath.Join(c.dir, "data"), "-U", "migration_installer", "--auth=trust", "--no-locale", "--encoding=UTF8")
	c.start(t)
	return c
}

func (c *ownedCluster) replica(t *testing.T) *ownedCluster {
	t.Helper()
	r := ownedClusterDirectory(t)
	backup, err := exec.LookPath("pg_basebackup")
	if err != nil {
		t.Fatal(err)
	}
	r.command(t, backup, "-D", filepath.Join(r.dir, "data"), "-h", c.socket, "-U", "migration_installer", "-X", "stream", "-R", "-c", "fast", "--no-password")
	r.start(t)
	return r
}

func (c *ownedCluster) command(t *testing.T, binary string, args ...string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, binary, args...).CombinedOutput()
	if err != nil {
		log, _ := os.ReadFile(filepath.Join(c.dir, "postgres.log"))
		t.Fatalf("owned cluster command %s: %v\n%s\n%s", filepath.Base(binary), err, output, log)
	}
}

func (c *ownedCluster) start(t *testing.T) {
	t.Helper()
	c.command(t, c.pgctl, "-D", filepath.Join(c.dir, "data"), "-l", filepath.Join(c.dir, "postgres.log"),
		"-o", fmt.Sprintf("-k %s -h '' -c max_connections=20", c.socket), "-w", "-t", "15", "start")
}

func (c *ownedCluster) crashAndRestart(t *testing.T) {
	t.Helper()
	// Immediate shutdown forces WAL recovery on restart; it does not checkpoint
	// cleanly or wait for transaction commits. Durability settings stay enabled.
	c.command(t, c.pgctl, "-D", filepath.Join(c.dir, "data"), "-m", "immediate", "-w", "-t", "10", "stop")
	c.start(t)
}

// INV-FENCE, INV-FLOOR, INV-HISTORY; TR-RETIRE, TR-CONTRACT, TR-CRASH.
func TestOwnedPrimaryCrashPreservesOnlyCommittedRetirement(t *testing.T) {
	for _, committed := range []bool{false, true} {
		t.Run(fmt.Sprintf("committed=%v", committed), func(t *testing.T) {
			cluster := newOwnedCluster(t)
			t.Setenv("TESL_MIGRATION_TEST_DSN", "host="+cluster.socket+" user=migration_installer dbname=postgres")
			f := newDatabaseFixture(t)
			f.expanded(t, 8)
			coordinator := f.other(t)
			if _, err := coordinator.Exec(f.ctx, "select pg_advisory_lock($1,7)", f.fence); err != nil {
				t.Fatal(err)
			}
			if _, err := coordinator.Exec(f.ctx, "begin; select "+f.schema+".tesl_advance_floor(7,8,'retire',1,'tesl-1','crashing'); select "+f.schema+".tesl_begin_contract(8,'contract',1,'tesl-1','crashing')"); err != nil {
				t.Fatal(err)
			}
			if committed {
				if _, err := coordinator.Exec(f.ctx, "commit"); err != nil {
					t.Fatal(err)
				}
			}
			cluster.crashAndRestart(t)
			f.conn = f.other(t)
			f.exec(t, "begin")
			f.exec(t, "select pg_advisory_xact_lock($1,7)", f.fence)
			var floor, compat, retired, contracting int
			if err := f.conn.QueryRow(f.ctx, "select min_version,compat_floor,(select count(*) from "+f.schema+".tesl_schema_versions where version=7 and step='retired'),(select count(*) from "+f.schema+".tesl_schema_versions where version=8 and step='contracting') from "+f.schema+".tesl_schema_state").Scan(&floor, &compat, &retired, &contracting); err != nil {
				t.Fatal(err)
			}
			expectedFloor, expectedEvents := 7, 0
			if committed {
				expectedFloor, expectedEvents = 8, 1
			}
			if floor != expectedFloor || compat != expectedFloor || retired != expectedEvents || contracting != expectedEvents {
				t.Fatalf("WAL recovery split retirement evidence: floor=%d compat=%d retired=%d contracting=%d, committed=%v", floor, compat, retired, contracting, committed)
			}
			if !committed {
				f.exec(t, "select "+f.schema+".tesl_advance_floor(7,8,'retire',1,'tesl-1','recovered')")
			}
			f.exec(t, "select "+f.schema+".tesl_begin_contract(8,'contract',1,'tesl-1','recovered')")
			f.exec(t, "select "+f.schema+".tesl_record_contracted(8,'contract',1,'tesl-1','recovered'); commit")
			var events int
			if err := f.conn.QueryRow(f.ctx, "select count(*) from "+f.schema+".tesl_schema_versions where (version=7 and step='retired') or (version=8 and step in ('contracting','contracted'))").Scan(&events); err != nil || events != 3 {
				t.Fatalf("recovered coordinator did not finish exactly once: %d, %v", events, err)
			}
		})
	}
}

// INV-TOPOLOGY, INV-READ, INV-FLOOR; TR-REPLAY, TR-RETIRE, TR-CONTRACT.
// This tests why admission must use the primary. It does not implement or claim
// production replica routing: a paused replica really has both an old floor and
// old physical columns, despite the primary having committed retirement and DDL.
func TestOwnedLaggedReplicaHasStaleAdmissionAndSchema(t *testing.T) {
	primary := newOwnedCluster(t)
	t.Setenv("TESL_MIGRATION_TEST_DSN", "host="+primary.socket+" user=migration_installer dbname=postgres")
	f := newDatabaseFixture(t)
	f.exec(t, "create table "+f.schema+".replay_probe (id int primary key, legacy text)")
	f.exec(t, "insert into "+f.schema+".replay_probe values (1,'old column')")
	replica := primary.replica(t)
	standby, err := pgx.Connect(f.ctx, "host="+replica.socket+" user=migration_installer dbname=postgres")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = standby.Close(ctx)
	})
	var recovery bool
	if err := standby.QueryRow(f.ctx, "select pg_is_in_recovery()").Scan(&recovery); err != nil || !recovery {
		t.Fatalf("fixture is not a streaming standby: %v, %v", recovery, err)
	}
	waitFor := func(query string, args ...any) {
		t.Helper()
		for {
			var ready bool
			if err := standby.QueryRow(f.ctx, query, args...).Scan(&ready); err != nil {
				t.Fatalf("replica rendezvous: %v\n%s", err, f.dump())
			}
			if ready {
				return
			}
			runtime.Gosched()
		}
	}
	var initialLSN string
	if err := f.conn.QueryRow(f.ctx, "select pg_current_wal_lsn()::text").Scan(&initialLSN); err != nil {
		t.Fatal(err)
	}
	waitFor("select pg_last_wal_replay_lsn() >= $1::pg_lsn", initialLSN)
	if _, err := standby.Exec(f.ctx, "select pg_wal_replay_pause()"); err != nil {
		t.Fatal(err)
	}
	waitFor("select pg_get_wal_replay_pause_state() = 'paused'")
	f.expanded(t, 8)
	f.exec(t, "begin")
	f.exec(t, "select pg_advisory_xact_lock($1,7)", f.fence)
	f.exec(t, "select "+f.schema+".tesl_advance_floor(7,8,'retire',1,'tesl-1','primary')")
	f.exec(t, "select "+f.schema+".tesl_begin_contract(8,'contract',1,'tesl-1','primary')")
	f.exec(t, "alter table "+f.schema+".replay_probe drop column legacy")
	f.exec(t, "select "+f.schema+".tesl_record_contracted(8,'contract',1,'tesl-1','primary'); commit")
	var committedLSN string
	if err := f.conn.QueryRow(f.ctx, "select pg_current_wal_lsn()::text").Scan(&committedLSN); err != nil {
		t.Fatal(err)
	}
	var oldFloor int
	if err := standby.QueryRow(f.ctx, "select "+f.schema+".tesl_admit(7)").Scan(&oldFloor); err != nil || oldFloor != 7 {
		t.Fatalf("paused replica did not expose stale admission: %d, %v", oldFloor, err)
	}
	var legacy string
	if err := standby.QueryRow(f.ctx, "select legacy from "+f.schema+".replay_probe where id=1").Scan(&legacy); err != nil || legacy != "old column" {
		t.Fatalf("paused replica lost pre-contract schema: %q, %v", legacy, err)
	}
	if _, err := f.conn.Exec(f.ctx, "select "+f.schema+".tesl_admit(7)"); err == nil || !strings.Contains(err.Error(), "is retired") {
		t.Fatalf("primary did not refuse the retired reader: %v", err)
	}
	if _, err := standby.Exec(f.ctx, "select pg_wal_replay_resume()"); err != nil {
		t.Fatal(err)
	}
	waitFor("select pg_last_wal_replay_lsn() >= $1::pg_lsn", committedLSN)
	if _, err := standby.Exec(f.ctx, "select "+f.schema+".tesl_admit(7)"); err == nil || !strings.Contains(err.Error(), "is retired") {
		t.Fatalf("caught-up replica did not refuse the retired reader: %v", err)
	}
	var hasLegacy bool
	if err := standby.QueryRow(f.ctx, "select exists(select from pg_attribute where attrelid=$1::regclass and attname='legacy' and not attisdropped)", f.schema+".replay_probe").Scan(&hasLegacy); err != nil || hasLegacy {
		t.Fatalf("caught-up replica retained dropped storage: %v, %v", hasLegacy, err)
	}
}
