package migrationtest

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

var fixtureCounter atomic.Uint64

type databaseFixture struct {
	conn                              *pgx.Conn
	dsn, schema, app, worker, control string
	ctx                               context.Context
	fence                             int
	activityDatabases                 []string
}

func newDatabaseFixture(t *testing.T) *databaseFixture {
	t.Helper()
	f := newUninstalledDatabaseFixture(t)
	f.exec(t, "update "+f.schema+".tesl_schema_state set installing_version=7 where id=1")
	f.expanded(t, 7)
	return f
}

func newUninstalledDatabaseFixture(t *testing.T) *databaseFixture {
	t.Helper()
	dsn := os.Getenv("TESL_MIGRATION_TEST_DSN")
	if dsn == "" {
		t.Skip("PostgreSQL migration matrix: run scripts/run-migration-tests.sh")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	t.Cleanup(cancel)
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	if err := requirePostgresMajor(ctx, conn, os.Getenv("TESL_MIGRATION_TEST_POSTGRES_MAJOR")); err != nil {
		_ = conn.Close(ctx)
		t.Fatal(err)
	}
	serial := fmt.Sprintf("mig_%d_%d", os.Getpid(), fixtureCounter.Add(1))
	f := &databaseFixture{conn: conn, dsn: dsn, schema: serial, app: serial + "_app", worker: serial + "_worker", control: serial + "_control", ctx: ctx}
	t.Cleanup(func() {
		cleanupCtx, done := context.WithTimeout(context.Background(), 5*time.Second)
		defer done()
		// The registry is shared by fixtures, so remove this fixture's entry before
		// dropping its namespace; all other objects are scoped to unique names.
		_, _ = conn.Exec(cleanupCtx, "rollback")
		_, _ = conn.Exec(cleanupCtx, "delete from public.tesl_fence_namespaces where database_uuid in (select database_uuid from "+f.schema+".tesl_schema_meta)")
		_, _ = conn.Exec(cleanupCtx, "drop schema if exists "+f.schema+" cascade")
		for _, role := range []string{f.app, f.worker, f.control} {
			_, _ = conn.Exec(cleanupCtx, "drop owned by "+role)
			_, _ = conn.Exec(cleanupCtx, "drop role if exists "+role)
		}
		_ = conn.Close(cleanupCtx)
	})
	for _, role := range []string{f.app, f.worker, f.control} {
		f.exec(t, "create role "+role+" nologin")
	}
	root := os.Getenv("TESL_REPO_ROOT")
	if root == "" {
		root = filepath.Join("..", "..", "..", "..")
	}
	text, err := os.ReadFile(filepath.Join(root, "runtime", "go", "internal", "migrationtest", "testdata", "control-bootstrap.sql"))
	if err != nil {
		t.Fatal(err)
	}
	sql := string(text)
	// Bind only known fixture constants. This is not a migration runtime: the
	// executable fixture is also copied into the design document by its sync gate.
	sql = strings.NewReplacer("notes_app", f.schema, "tesl_app", f.app, "tesl_schema;", f.worker+";", "tesl_schema,", f.worker+",", "to tesl_schema", "to "+f.worker, "tesl_control", f.control,
		":format_version", "1", ":max_observed_protocol", "1", ":retirement_protocol_floor", "1", ":fence_domain", "'tesl-1'").Replace(sql)
	// Fixture hooks implement the template's ownership steps. Existing catalog
	// drift/adoption assertions belong to the production installer, not this
	// fixture, which creates fresh namespaces and roles for every test.
	sql = strings.Replace(sql, "-- HARNESS STEP assign_and_assert_namespace_owner:",
		"alter schema "+f.schema+" owner to "+f.control+"; grant usage, create on schema "+f.schema+" to "+f.worker+"; grant usage on schema "+f.schema+" to "+f.app+";\n-- HARNESS STEP assign_and_assert_namespace_owner:", 1)
	f.exec(t, sql)
	rows, err := conn.Query(ctx, "select tablename from pg_tables where schemaname=$1", f.schema)
	if err != nil {
		t.Fatal(err)
	}
	names, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range names {
		f.exec(t, "alter table "+f.schema+"."+pgx.Identifier{name}.Sanitize()+" owner to "+f.control)
	}
	f.exec(t, "create table "+f.schema+".tesl_jobs (id text primary key, schema_version int not null, status text not null)")
	f.exec(t, "grant select on "+f.schema+".tesl_jobs to "+f.control)
	if err := conn.QueryRow(ctx, "select fence_ns from "+f.schema+".tesl_schema_meta").Scan(&f.fence); err != nil {
		t.Fatal(err)
	}
	return f
}

func requirePostgresMajor(ctx context.Context, conn *pgx.Conn, expected string) error {
	if expected == "" {
		return nil
	}
	want, err := strconv.Atoi(expected)
	if err != nil || want < 14 || want > 18 {
		return fmt.Errorf("TESL_MIGRATION_TEST_POSTGRES_MAJOR must name a supported major in [14,18], got %q", expected)
	}
	var actual int
	if err := conn.QueryRow(ctx, "select current_setting('server_version_num')::int / 10000").Scan(&actual); err != nil {
		return fmt.Errorf("read PostgreSQL matrix version: %w", err)
	}
	if actual != want {
		return fmt.Errorf("PostgreSQL matrix expected major %d, connected to major %d", want, actual)
	}
	return nil
}

// INV-MATRIX; TR-MATRIX-CONNECT.
func TestPostgresMajorGateChecksTheActualServer(t *testing.T) {
	f := newDatabaseFixture(t)
	var actual int
	if err := f.conn.QueryRow(f.ctx, "select current_setting('server_version_num')::int / 10000").Scan(&actual); err != nil {
		t.Fatal(err)
	}
	if err := requirePostgresMajor(f.ctx, f.conn, strconv.Itoa(actual)); err != nil {
		t.Fatal(err)
	}
	wrong := 14
	if actual == wrong {
		wrong = 18
	}
	if err := requirePostgresMajor(f.ctx, f.conn, strconv.Itoa(wrong)); err == nil || !strings.Contains(err.Error(), "connected to major") {
		t.Fatalf("wrong matrix service was accepted: %v", err)
	}
	for _, invalid := range []string{"13", "19", "seventeen", "17.10"} {
		if err := requirePostgresMajor(f.ctx, f.conn, invalid); err == nil {
			t.Fatalf("invalid matrix major %q was accepted", invalid)
		}
	}
}

func (f *databaseFixture) exec(t *testing.T, sql string, args ...any) {
	t.Helper()
	if _, err := f.conn.Exec(f.ctx, sql, args...); err != nil {
		t.Fatalf("SQL: %s\n%v", sql, err)
	}
}

func (f *databaseFixture) execOn(t *testing.T, conn *pgx.Conn, sql string, args ...any) {
	t.Helper()
	if _, err := conn.Exec(f.ctx, sql, args...); err != nil {
		t.Fatalf("%s: %v\n%s", sql, err, f.dump())
	}
}

func (f *databaseFixture) expanded(t *testing.T, v int) {
	t.Helper()
	f.exec(t, "select "+f.schema+".tesl_record_expanded($1,$2,$3,1,'tesl-1',true,'fixture')", v, fmt.Sprintf("snapshot-%d", v), fmt.Sprintf("migration-%d", v))
}

func (f *databaseFixture) other(t *testing.T) *pgx.Conn {
	t.Helper()
	conn, err := pgx.Connect(f.ctx, f.dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		_ = conn.Close(ctx)
	})
	return conn
}

func (f *databaseFixture) dump() string {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	// Independent connection: the participant may itself be blocked on a lock.
	conn, err := pgx.Connect(ctx, f.dsn)
	if err != nil {
		return err.Error()
	}
	defer func() { _ = conn.Close(ctx) }()
	var output strings.Builder
	activity := "select coalesce(json_agg(t)::text,'[]') from (select datname,pid,wait_event_type,wait_event,state,query from pg_stat_activity where datname=current_database() or datname=any($1::text[])) t"
	var value string
	if err := conn.QueryRow(ctx, activity, f.activityDatabases).Scan(&value); err != nil {
		value = err.Error()
	}
	output.WriteString(value + "\n")
	for _, query := range []string{"select coalesce(json_agg(t)::text,'[]') from (select pid,locktype,mode,granted,classid,objid from pg_locks) t", "select coalesce(json_agg(t)::text,'[]') from " + f.schema + ".tesl_schema_versions t"} {
		var value string
		if err := conn.QueryRow(ctx, query).Scan(&value); err != nil {
			value = err.Error()
		}
		output.WriteString(value + "\n")
	}
	return output.String()
}

// INV-HISTORY; TR-EXPAND. A duplicate must not poison the enclosing transaction.
func TestPostgresTemplateLifecycleRetry(t *testing.T) {
	f := newDatabaseFixture(t)
	f.expanded(t, 8)
	f.exec(t, "begin")
	f.expanded(t, 8)
	f.exec(t, "select 42")
	f.exec(t, "commit")
	_, err := f.conn.Exec(f.ctx, "select "+f.schema+".tesl_record_expanded(8,'edited','migration-8',1,'tesl-1',true,'other')")
	if err == nil || !strings.Contains(err.Error(), "immutable history") {
		t.Fatalf("changed frozen identity accepted: %v", err)
	}
}

// INV-FENCE, INV-FLOOR, INV-READ; TR-WRITE, TR-RETIRE.
// Polling is bounded by context and observes pg_locks, not an assumed delay.
func TestPostgresTemplateFenceOrdersPausedWriterAndRetirement(t *testing.T) {
	f := newDatabaseFixture(t)
	f.expanded(t, 8)
	writer := f.other(t)
	retirer := f.other(t)
	if _, err := writer.Exec(f.ctx, "begin"); err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Exec(f.ctx, "select pg_advisory_xact_lock_shared($1,7)", f.fence); err != nil {
		t.Fatal(err)
	}
	s := NewSchedule(f.dump)
	e := Event{"fence-acquired", "v7", 1}
	if err := s.Pause(e); err != nil {
		t.Fatal(err)
	}
	written := make(chan error, 1)
	go func() {
		if err := s.Hit(f.ctx, e); err != nil {
			written <- err
			return
		}
		_, err := writer.Exec(f.ctx, "commit")
		written <- err
	}()
	if err := s.Await(f.ctx, e); err != nil {
		t.Fatal(err)
	}
	retired := make(chan error, 1)
	go func() {
		_, err := retirer.Exec(f.ctx, "begin; select pg_advisory_xact_lock("+fmt.Sprint(f.fence)+",7)")
		if err == nil {
			_, err = retirer.Exec(f.ctx, "select "+f.schema+".tesl_advance_floor(7,8,'retirement',1,'tesl-1','fixture'); commit")
		}
		retired <- err
	}()
	for {
		var waiting bool
		if err := f.conn.QueryRow(f.ctx, "select exists (select 1 from pg_locks where pid=$1 and locktype='advisory' and not granted)", retirer.PgConn().PID()).Scan(&waiting); err != nil {
			t.Fatalf("%v\n%s", err, f.dump())
		}
		if waiting {
			break
		}
		select {
		case err := <-retired:
			t.Fatalf("retirement passed paused writer: %v\n%s", err, f.dump())
		default:
		}
	}
	if err := s.Release(e); err != nil {
		t.Fatal(err)
	}
	for _, ch := range []chan error{written, retired} {
		select {
		case err := <-ch:
			if err != nil {
				t.Fatalf("%v\n%s", err, f.dump())
			}
		case <-f.ctx.Done():
			t.Fatalf("%v\n%s", f.ctx.Err(), f.dump())
		}
	}
	if _, err := writer.Exec(f.ctx, "select "+f.schema+".tesl_admit(7)"); err == nil {
		t.Fatal("retired reader admitted")
	}
	var floor int
	if err := f.conn.QueryRow(f.ctx, "select min_version from "+f.schema+".tesl_schema_state").Scan(&floor); err != nil || floor != 8 {
		t.Fatalf("floor=%d: %v", floor, err)
	}
}

// INV-FENCE, INV-QUEUE-FLOOR, INV-FINAL; TR-RETIRE.
func TestPostgresTemplateRefusesMissingFloorPrerequisites(t *testing.T) {
	for _, missing := range []string{"exclusive fence", "entity finality", "queue restamp", "protocol", "domain", "range", "history"} {
		t.Run(missing, func(t *testing.T) {
			f := newDatabaseFixture(t)
			f.expanded(t, 8)
			switch missing {
			case "entity finality":
				f.exec(t, "insert into "+f.schema+".tesl_schema_entities(entity,generation,target_generation) values ('Note',3,4)")
			case "queue restamp":
				f.exec(t, "insert into "+f.schema+".tesl_jobs values ('old',7,'pending')")
			case "protocol":
				f.exec(t, "update "+f.schema+".tesl_schema_meta set retirement_protocol_floor=0")
			case "domain":
				f.exec(t, "update "+f.schema+".tesl_schema_versions set fence_domain='other' where version=7")
			case "history":
				f.exec(t, "delete from "+f.schema+".tesl_schema_versions where version=7 and step='expanded'")
			}
			f.exec(t, "begin")
			if missing != "exclusive fence" {
				f.exec(t, "select pg_advisory_xact_lock($1,7)", f.fence)
			}
			target := 8
			if missing == "range" {
				target = 7
			}
			_, err := f.conn.Exec(f.ctx, "select "+f.schema+".tesl_advance_floor(7,$1,'retirement',1,'tesl-1','fixture')", target)
			if err == nil {
				t.Fatalf("retired without %s", missing)
			}
			f.exec(t, "rollback")
			var floor int
			if err := f.conn.QueryRow(f.ctx, "select min_version from "+f.schema+".tesl_schema_state").Scan(&floor); err != nil || floor != 7 {
				t.Fatalf("refusal changed floor: %d %v", floor, err)
			}
		})
	}
}
