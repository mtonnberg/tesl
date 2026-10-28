package teslmodtodoapp

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	rt "tesl.generated/teslmodtodoapp/internal/teslrt"
)

// This file is copied into ACTUAL compiler output for both source versions.
// The source project is deleted before these tests run. No snapshot is handbuilt.
type removalFixture struct {
	t                          *testing.T
	ctx                        context.Context
	cfg                        *pgx.ConnConfig
	db, request                *pgx.Conn
	owner, worker, requestRole string
	env                        []string
}

// ParseConfig's ConnString retains the input string, not subsequent field edits.
// This fixture controls all names/socket paths (no whitespace or quoting).
func removalDSN(cfg *pgx.ConnConfig) string {
	return fmt.Sprintf("host=%s port=%d user=%s dbname=%s sslmode=disable", cfg.Host, cfg.Port, cfg.User, cfg.Database)
}

func newRemovalFixture(t *testing.T, original bool) *removalFixture {
	t.Helper()
	host := os.Getenv("TESL_TEST_POSTGRES_SHARED_HOST")
	if host == "" {
		if os.Getenv("TESL_MIGRATION_TEST_REQUIRE_POSTGRES") == "1" {
			t.Fatal("required PostgreSQL missing")
		}
		t.Skip("requires PostgreSQL")
	}
	budget := 60 * time.Second
	if os.Getenv("QUEUE_REMOVAL_V4") != "" {
		budget = 150 * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), budget)
	t.Cleanup(cancel)
	cfg, err := pgx.ParseConfig("")
	if err != nil {
		t.Fatal(err)
	}
	cfg.Host = host
	port, err := strconv.Atoi(os.Getenv("TESL_TEST_POSTGRES_SHARED_PORT"))
	if err != nil {
		t.Fatal(err)
	}
	cfg.Port = uint16(port)
	cfg.User = os.Getenv("TESL_TEST_POSTGRES_SHARED_USER")
	cfg.Database = os.Getenv("TESL_TEST_POSTGRES_SHARED_ADMIN_DATABASE")
	admin, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	name := "qr_" + strings.ReplaceAll(rt.UUIDv7(), "-", "")
	f := &removalFixture{t: t, ctx: ctx, owner: name + "_owner", worker: name + "_worker", requestRole: name + "_request"}
	q := func(s string) string { return pgx.Identifier{s}.Sanitize() }
	t.Cleanup(func() {
		cleanup, stop := context.WithTimeout(context.Background(), 5*time.Second)
		defer stop()
		if f.request != nil {
			_ = f.request.Close(cleanup)
		}
		if f.db != nil {
			_ = f.db.Close(cleanup)
		}
		_, _ = admin.Exec(cleanup, "drop database if exists "+q(name)+" with (force)")
		for _, role := range []string{f.requestRole, f.worker, f.owner} {
			_, _ = admin.Exec(cleanup, "drop role if exists "+q(role))
		}
		_ = admin.Close(cleanup)
	})
	for _, sql := range []string{"create role " + q(f.owner) + " nologin", "create role " + q(f.worker) + " login", "create role " + q(f.requestRole) + " login", "create database " + q(name), "grant create on database " + q(name) + " to " + q(f.owner)} {
		if _, err := admin.Exec(ctx, sql); err != nil {
			t.Fatal(err)
		}
	}
	cfg.Database = name
	f.cfg = cfg
	f.db, err = pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	if _, err = f.db.Exec(ctx, "grant create on schema public to "+q(f.owner)); err != nil {
		t.Fatal(err)
	}
	f.env = append(os.Environ(), "Q_HOST="+host, "Q_PORT="+strconv.Itoa(port), "Q_DB="+name, "Q_OWNER="+f.owner, "Q_WORKER="+f.worker, "Q_REQUEST="+f.requestRole)
	request := cfg.Copy()
	request.User = f.requestRole
	f.request, err = pgx.ConnectConfig(ctx, request)
	if err != nil {
		t.Fatal(err)
	}
	if original {
		f.run(f.command(1, cfg.User, "app", "--schema", "install", "--worker", f.worker, "--request", f.requestRole))
		f.run(f.command(1, f.worker, "app", "--schema", "catch-up"))
		f.run(f.command(2, cfg.User, "app", "--schema", "install", "--worker", f.worker, "--request", f.requestRole))
		f.state(1)
		var published int
		if err := f.db.QueryRow(ctx, "select count(*) from todo.tesl_queue_versions where version=2").Scan(&published); err != nil || published != 0 {
			t.Fatal("staging published membership", published, err)
		}
	}
	return f
}
func (f *removalFixture) command(v int, login, binary string, args ...string) *exec.Cmd {
	path := os.Getenv("QUEUE_REMOVAL_V" + strconv.Itoa(v))
	cmd := exec.CommandContext(f.ctx, filepath.Join(path, binary), args...)
	cfg := f.cfg.Copy()
	cfg.User = login
	cmd.Env = append(append([]string{}, f.env...), "Q_USER="+login, "Q_DDL="+removalDSN(cfg))
	return cmd
}
func (f *removalFixture) run(cmd *exec.Cmd) string {
	f.t.Helper()
	out, err := cmd.CombinedOutput()
	if err != nil {
		f.t.Fatalf("%v: %v\n%s", cmd.Args, err, out)
	}
	return string(out)
}
func (f *removalFixture) catchup() *exec.Cmd {
	return f.command(2, f.worker, "app", "--schema", "catch-up")
}
func (f *removalFixture) state(want int) {
	f.t.Helper()
	var current, min, floor int
	if err := f.db.QueryRow(f.ctx, "select current,min_version,compat_floor from todo.tesl_schema_state where id=1").Scan(&current, &min, &floor); err != nil || current != want || min != want || floor != want {
		f.t.Fatalf("state %d/%d/%d want %d: %v", current, min, floor, want, err)
	}
}
func (f *removalFixture) snapshot() string {
	f.t.Helper()
	var value string
	if err := f.db.QueryRow(f.ctx, `select jsonb_build_array(
 (select to_jsonb(s) from todo.tesl_schema_state s),
 (select jsonb_agg(to_jsonb(v) order by version,step) from todo.tesl_schema_versions v),
 (select jsonb_agg(to_jsonb(q) order by version) from todo.tesl_queue_versions q),
 (select jsonb_agg(to_jsonb(q) order by version,queue) from todo.tesl_queue_contracts q),
 (select jsonb_agg(to_jsonb(p) order by version,queue,job_type) from todo.tesl_queue_payloads p),
 (select jsonb_agg(to_jsonb(r) order by version) from todo.tesl_row_queue_retirements r),
 (select jsonb_agg(to_jsonb(r) order by job_id,from_version) from todo.tesl_row_queue_restamps r),
 (select jsonb_agg(to_jsonb(r) order by job_id,from_version) from todo.tesl_row_queue_removal_restamps r),
 (select jsonb_agg(to_jsonb(j) order by seq) from todo.tesl_jobs j))::text`).Scan(&value); err != nil {
		f.t.Fatal(err)
	}
	return value
}

type removalQuery interface {
	QueryRow(context.Context, string, ...any) pgx.Row
}

func (f *removalFixture) enqueue(conn removalQuery, queue, id string) {
	f.t.Helper()
	job := "Notify"
	if queue == "Survivors" {
		job = "Keep"
	}
	var actual string
	if err := conn.QueryRow(f.ctx, "select todo.tesl_queue_enqueue(1,$1,$2,$3,'{\"text\":\"retained 雪\"}'::jsonb)", queue, job, id).Scan(&actual); err != nil || actual != id {
		f.t.Fatal("enqueue", actual, err)
	}
}

type removalClaim struct {
	id, job, payload, token string
	version, attempts       int
	seq                     int64
}

func (f *removalFixture) claim(conn removalQuery, queue, kind string) removalClaim {
	f.t.Helper()
	var c removalClaim
	if err := conn.QueryRow(f.ctx, "select * from todo.tesl_queue_claim(1,$1,$2,'test',60000)", queue, kind).Scan(&c.id, &c.job, &c.payload, &c.version, &c.attempts, &c.token, &c.seq); err != nil {
		f.t.Fatal(err)
	}
	return c
}
func (f *removalFixture) dead(queue string, c removalClaim) {
	f.t.Helper()
	var ok bool
	if err := f.request.QueryRow(f.ctx, "select todo.tesl_queue_fail(1,$1,$2,$3,$4,1,0)", queue, c.id, c.token, c.seq).Scan(&ok); err != nil || !ok {
		f.t.Fatal(err, ok)
	}
}
func (f *removalFixture) blocked() {
	f.t.Helper()
	before := f.snapshot()
	out, err := f.catchup().CombinedOutput()
	if err == nil || !strings.Contains(string(out), "RemoveEmpty blocked") {
		f.t.Fatalf("nonempty removal: %v\n%s", err, out)
	}
	f.state(1)
	if before != f.snapshot() {
		f.t.Fatal("blocked removal changed jobs, source history, membership, receipts or floors")
	}
}

func TestQueueRemovalNonempty(t *testing.T) {
	for _, kind := range []string{"pending", "delayed", "dead", "quarantined", "claimed", "dead-claimed", "expired-claimed"} {
		t.Run(kind, func(t *testing.T) {
			f := newRemovalFixture(t, true)
			f.enqueue(f.request, "Notifications", "kept")
			switch kind {
			case "delayed":
				if _, err := f.db.Exec(f.ctx, "update todo.tesl_jobs set next_attempt_at=clock_timestamp()+interval '1 day'"); err != nil {
					t.Fatal(err)
				}
			case "dead", "dead-claimed":
				f.dead("Notifications", f.claim(f.request, "Notifications", "pending"))
				if kind == "dead-claimed" {
					f.claim(f.request, "Notifications", "dead")
				}
			case "quarantined":
				c := f.claim(f.request, "Notifications", "pending")
				var ok bool
				if err := f.request.QueryRow(f.ctx, "select todo.tesl_queue_quarantine(1,'Notifications',$1,$2,$3)", c.id, c.token, c.seq).Scan(&ok); err != nil || !ok {
					t.Fatal(err, ok)
				}
			case "claimed", "expired-claimed":
				f.claim(f.request, "Notifications", "pending")
				if kind == "expired-claimed" {
					if _, err := f.db.Exec(f.ctx, "update todo.tesl_jobs set lease_until=clock_timestamp()-interval '1 second'"); err != nil {
						t.Fatal(err)
					}
				}
			}
			f.blocked()
		})
	}
}

func TestQueueRemovalSurvivorsAndReplay(t *testing.T) {
	f := newRemovalFixture(t, true)
	f.enqueue(f.request, "Survivors", "dead")
	f.dead("Survivors", f.claim(f.request, "Survivors", "pending"))
	f.enqueue(f.request, "Survivors", "delayed")
	if _, err := f.db.Exec(f.ctx, "update todo.tesl_jobs set next_attempt_at=clock_timestamp()+interval '1 day' where id='delayed'"); err != nil {
		t.Fatal(err)
	}
	f.enqueue(f.request, "Survivors", "claimed")
	f.claim(f.request, "Survivors", "pending")
	f.blocked()
	if _, err := f.db.Exec(f.ctx, "update todo.tesl_jobs set lease_until=clock_timestamp()-interval '1 second' where id='claimed'"); err != nil {
		t.Fatal(err)
	}
	f.enqueue(f.request, "Survivors", "pending")
	var payloads string
	query := `select jsonb_agg(jsonb_build_array(id,payload,attempts,next_attempt_at,claim_seq) order by id)::text from todo.tesl_jobs`
	if err := f.db.QueryRow(f.ctx, query).Scan(&payloads); err != nil {
		t.Fatal(err)
	}
	f.run(f.catchup())
	f.state(2)
	var after string
	if err := f.db.QueryRow(f.ctx, query).Scan(&after); err != nil || after != payloads {
		t.Fatal("survivor values changed", err)
	}
	var count int
	if err := f.db.QueryRow(f.ctx, "select count(*) from todo.tesl_row_queue_removal_restamps").Scan(&count); err != nil || count != 4 {
		t.Fatal("missing restamp audit", count, err)
	}
	if err := f.db.QueryRow(f.ctx, "select count(*) from todo.tesl_jobs where schema_version<>2 or status in ('processing','dead_processing')").Scan(&count); err != nil || count != 0 {
		t.Fatal("expired claim not safely normalized", count, err)
	}
	// Replay must not clear a legitimate NEW-version survivor claim.
	var currentClaim removalClaim
	if err := f.request.QueryRow(f.ctx, "select * from todo.tesl_queue_claim(2,'Survivors','pending','new-worker',60000)").Scan(&currentClaim.id, &currentClaim.job, &currentClaim.payload, &currentClaim.version, &currentClaim.attempts, &currentClaim.token, &currentClaim.seq); err != nil {
		t.Fatal(err)
	}
	before := f.snapshot()
	f.run(f.catchup())
	f.run(f.command(2, f.worker, "app", "--schema", "contract", "V2"))
	if before != f.snapshot() {
		t.Fatal("replay changed immutable receipt or restamped twice")
	}
	old := f.command(1, f.requestRole, "application.test", "-test.run", "^TestOldRemovalProducer$", "-test.v")
	old.Env = append(old.Env, "REMOVAL_OLD_PRODUCER=1")
	if out, err := old.CombinedOutput(); err == nil {
		t.Fatalf("old compiled producer survived removal: %s", out)
	}
	if before != f.snapshot() {
		t.Fatal("rejected old binary changed retained jobs")
	}
	child := f.command(2, f.requestRole, "application.test", "-test.run", "^TestQueueRemovalCurrentApplication$", "-test.v")
	child.Env = append(child.Env, "REMOVAL_CURRENT=1")
	f.run(child)
	f.run(f.catchup())
}

func TestQueueRemovalCurrentApplication(t *testing.T) {
	if os.Getenv("REMOVAL_CURRENT") != "1" {
		t.Skip("child only")
	}
	if err := rt.PreflightApplicationDatabases(DDatabase); err != nil {
		t.Fatal(err)
	}
	h, ok := DDatabase.CompiledMigrationHistory()
	if !ok {
		t.Fatal("missing compiled source")
	}
	q, err := h.QueueSourceInventory(1)
	if err != nil || len(q.Versions) != 2 || len(q.Versions[0].Contracts) != 2 || len(q.Versions[1].Contracts) != 1 {
		t.Fatal("historical descriptors lost", err)
	}
	rt.WithDatabase(DDatabase, func() {
		out := rt.ProcessNextJob(RetainedQueue, func(any) rt.JobOutcome { return rt.JobOutcome{OK: true} })
		if !out.Ran || !out.OK {
			t.Fatal("current binding cannot consume preserved survivor", out)
		}
	})
}

// A real process boundary, not a sleep or a goroutine scheduling assumption.
func removalGate(t *testing.T, cmd *exec.Cmd, boundary string) (<-chan struct{}, func()) {
	t.Helper()
	dir, err := os.MkdirTemp(os.Getenv("TESL_MIGRATION_TEST_SOCKET_ROOT"), "qr-gate-")
	if err != nil {
		t.Fatal(err)
	}
	socket := filepath.Join(dir, "gate.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	arrived, release, stopped := make(chan struct{}), make(chan struct{}), make(chan struct{})
	resume := sync.OnceFunc(func() { close(release) })
	t.Cleanup(func() { resume(); _ = listener.Close(); <-stopped; _ = os.RemoveAll(dir) })
	go func() {
		defer close(stopped)
		paused := false
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			_ = conn.SetDeadline(time.Now().Add(30 * time.Second))
			var event struct{ Name string }
			if json.NewDecoder(io.LimitReader(conn, 4096)).Decode(&event) == nil {
				if event.Name == boundary && !paused {
					paused = true
					close(arrived)
					<-release
				}
				_, _ = io.WriteString(conn, "continue\n")
			}
			_ = conn.Close()
		}
	}()
	cmd.Env = append(cmd.Env, "TESL_MIGRATION_TEST_SOCKET="+socket, "TESL_MIGRATION_TEST_ACTOR=queue-removal")
	return arrived, resume
}
func startRemoval(t *testing.T, cmd *exec.Cmd) (<-chan error, *bytes.Buffer) {
	t.Helper()
	var output bytes.Buffer
	cmd.Stdout = &output
	cmd.Stderr = &output
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	t.Cleanup(func() { _ = cmd.Process.Kill() })
	return done, &output
}
func waitRemovalGate(t *testing.T, arrived <-chan struct{}, done <-chan error, output *bytes.Buffer) {
	t.Helper()
	select {
	case <-arrived:
	case err := <-done:
		t.Fatalf("process ended before boundary: %v\n%s", err, output.String())
	case <-time.After(20 * time.Second):
		t.Fatal("boundary not reached")
	}
}

func TestQueueRemovalInFlightTransactions(t *testing.T) {
	for _, kind := range []string{"producer", "claim"} {
		t.Run(kind, func(t *testing.T) {
			f := newRemovalFixture(t, true)
			if kind == "claim" {
				f.enqueue(f.request, "Survivors", "in-flight")
			}
			tx, err := f.request.Begin(f.ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer tx.Rollback(f.ctx)
			if kind == "producer" {
				f.enqueue(tx, "Notifications", "in-flight")
			} else {
				f.claim(tx, "Survivors", "pending")
			}
			cmd := f.catchup()
			arrived, resume := removalGate(t, cmd, "row-epoch-compatibility-busy")
			done, out := startRemoval(t, cmd)
			waitRemovalGate(t, arrived, done, out)
			if err := tx.Commit(f.ctx); err != nil {
				t.Fatal(err)
			}
			before := f.snapshot()
			resume()
			if err := <-done; err == nil || !strings.Contains(out.String(), "RemoveEmpty blocked") {
				t.Fatalf("missed committed %s: %v %s", kind, err, out.String())
			}
			f.state(1)
			if before != f.snapshot() {
				t.Fatal("in-flight job or claim lost")
			}
		})
	}
}

func TestQueueRemovalPostWaitAdmission(t *testing.T) {
	for _, kind := range []string{"producer", "claim"} {
		t.Run(kind, func(t *testing.T) {
			f := newRemovalFixture(t, true)
			cmd := f.catchup()
			arrived, resume := removalGate(t, cmd, "queue-removal-before-commit")
			done, out := startRemoval(t, cmd)
			waitRemovalGate(t, arrived, done, out)
			waiting := make(chan error, 1)
			go func() {
				if kind == "producer" {
					_, err := f.request.Exec(f.ctx, `select todo.tesl_queue_enqueue(1,'Notifications','Notify','late','{"text":"late"}'::jsonb)`)
					waiting <- err
				} else {
					var id string
					err := f.request.QueryRow(f.ctx, "select job_id from todo.tesl_queue_claim(1,'Survivors','pending','old',60000)").Scan(&id)
					waiting <- err
				}
			}()
			blocked := false
			deadline := time.Now().Add(5 * time.Second)
			for time.Now().Before(deadline) {
				if err := f.db.QueryRow(f.ctx, "select exists(select 1 from pg_locks where pid=$1 and locktype='advisory' and not granted)", f.request.PgConn().PID()).Scan(&blocked); err != nil {
					t.Fatal(err)
				}
				if blocked {
					break
				}
				time.Sleep(time.Millisecond)
			}
			if !blocked {
				t.Fatal("old operation did not wait on fence")
			}
			resume()
			if err := <-done; err != nil {
				t.Fatal(err, out.String())
			}
			if err := <-waiting; err == nil || errors.Is(err, pgx.ErrNoRows) {
				t.Fatalf("post-wait admission did not reject old %s: %v", kind, err)
			}
			f.state(2)
			var count int
			if err := f.db.QueryRow(f.ctx, "select count(*) from todo.tesl_jobs").Scan(&count); err != nil || count != 0 {
				t.Fatal("late old producer wrote", count, err)
			}
		})
	}
}

func TestQueueRemovalCrashReplay(t *testing.T) {
	for _, boundary := range []string{"queue-removal-before-commit", "queue-removal-after-commit"} {
		t.Run(boundary, func(t *testing.T) {
			f := newRemovalFixture(t, true)
			f.enqueue(f.request, "Survivors", "survives-crash")
			before := f.snapshot()
			cmd := f.catchup()
			arrived, resume := removalGate(t, cmd, boundary)
			done, out := startRemoval(t, cmd)
			waitRemovalGate(t, arrived, done, out)
			if err := cmd.Process.Kill(); err != nil {
				t.Fatal(err)
			}
			resume()
			if err := <-done; err == nil {
				t.Fatal("killed process succeeded")
			}
			if boundary == "queue-removal-before-commit" {
				f.state(1)
				if before != f.snapshot() {
					t.Fatal("crash exposed partial removal")
				}
			} else {
				f.state(2)
			}
			f.run(f.catchup())
			f.state(2)
			published := f.snapshot()
			f.run(f.catchup())
			if published != f.snapshot() {
				t.Fatal("replay changed receipt or duplicated restamps")
			}
		})
	}
}

func TestQueueRemovalForgedStagingAndACL(t *testing.T) {
	f := newRemovalFixture(t, true)
	workerCfg := f.cfg.Copy()
	workerCfg.User = f.worker
	worker, err := pgx.ConnectConfig(f.ctx, workerCfg)
	if err != nil {
		t.Fatal(err)
	}
	defer worker.Close(f.ctx)
	if _, err := worker.Exec(f.ctx, "update todo.tesl_row_queue_removal_staging set queue='Survivors'"); err == nil {
		t.Fatal("Worker can forge reviewed decision")
	}
	if _, err := worker.Exec(f.ctx, `select todo.tesl_register_row_physical(version,predecessor_hash,contract,contract_hash,compiler_abi,stored_value_compatibility,0,false) from todo.tesl_row_queue_target_staging`); err == nil {
		t.Fatal("standalone registration bypassed atomic removal")
	}
	if _, err := f.request.Exec(f.ctx, "select todo.tesl_remove_empty_queue('forged',1,repeat('a',64),'tesl-source-abi-v1:'||repeat('a',64),2)"); err == nil {
		t.Fatal("Request can publish removal")
	}
	var source string
	if err := f.db.QueryRow(f.ctx, "select source::text from todo.tesl_row_queue_removal_staging").Scan(&source); err != nil {
		t.Fatal(err)
	}
	// Deliberate owner corruption must fail AT the protected mutation, even when
	// no Go observer checks the source afterward and all caller fences are held.
	if _, err := f.db.Exec(f.ctx, "update todo.tesl_row_queue_removal_staging set source=jsonb_set(source,'{newSchema}',to_jsonb(repeat('a',64)))"); err != nil {
		t.Fatal(err)
	}
	var uuid, digest, abi string
	var fence int
	if err := f.db.QueryRow(f.ctx, "select m.database_uuid::text,m.fence_ns,t.contract_hash,t.compiler_abi from todo.tesl_schema_meta m cross join todo.tesl_row_queue_target_staging t").Scan(&uuid, &fence, &digest, &abi); err != nil {
		t.Fatal(err)
	}
	tx, err := worker.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	for _, domain := range []int{fence, -fence} {
		if _, err := tx.Exec(f.ctx, "select pg_advisory_xact_lock($1::integer,1)", domain); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := tx.Exec(f.ctx, "select todo.tesl_remove_empty_queue($1,$2,$3,$4,2)", uuid, fence, digest, abi); err == nil {
		t.Fatal("forged source accepted by protected mutation")
	}
	_ = tx.Rollback(f.ctx)
	f.state(1)
	if _, err := f.db.Exec(f.ctx, "update todo.tesl_row_queue_removal_staging set source=$1::jsonb", source); err != nil {
		t.Fatal(err)
	}
	tx, err = worker.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	for _, domain := range []int{fence, -fence} {
		if _, err := tx.Exec(f.ctx, "select pg_advisory_xact_lock($1::integer,1)", domain); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := tx.Exec(f.ctx, "select todo.tesl_remove_empty_queue($1,$2,$3,$4,2)", uuid, fence, digest, "tesl-source-abi-v1:"+strings.Repeat("0", 64)); err == nil {
		t.Fatal("unfinished removal accepted another compiler ABI")
	}
	_ = tx.Rollback(f.ctx)
	f.state(1)
	f.run(f.catchup())
	f.state(2)
}

func TestQueueRemovalFreshLatestDeployment(t *testing.T) {
	f := newRemovalFixture(t, false)
	cmd := f.command(2, f.requestRole, "app", "--schema", "deploy", "--json")
	worker := f.cfg.Copy()
	worker.User = f.worker
	cmd.Env = append(cmd.Env, "Q_DDL="+removalDSN(worker), "TESL_SCHEMA_INSTALLER_DSN="+removalDSN(f.cfg))
	f.run(cmd)
	f.state(2)
	before := f.snapshot()
	f.run(f.command(2, f.cfg.User, "app", "--schema", "install", "--worker", f.worker, "--request", f.requestRole))
	f.run(f.catchup())
	if before != f.snapshot() {
		t.Fatal("fresh latest replay changed original descriptors or receipt")
	}
}

func TestQueueRemovalActiveAttemptRefuses(t *testing.T) {
	f := newRemovalFixture(t, true)
	// V1 has no legitimate conversion edge. Even an orphaned retained attempt
	// must block rather than being treated as evidence that the queue is empty.
	if _, err := f.db.Exec(f.ctx, `insert into todo.tesl_row_queue_conversion_attempts
 values('orphan',repeat('a',64),1,pg_current_xact_id(),'{}','','pending')`); err != nil {
		t.Fatal(err)
	}
	before := f.snapshot()
	cfg := f.cfg.Copy()
	cfg.User = f.worker
	worker, err := pgx.ConnectConfig(f.ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer worker.Close(f.ctx)
	var uuid, digest, abi string
	var fence int
	if err := f.db.QueryRow(f.ctx, "select m.database_uuid::text,m.fence_ns,t.contract_hash,t.compiler_abi from todo.tesl_schema_meta m cross join todo.tesl_row_queue_target_staging t").Scan(&uuid, &fence, &digest, &abi); err != nil {
		t.Fatal(err)
	}
	tx, err := worker.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(f.ctx)
	for _, domain := range []int{fence, -fence} {
		if _, err := tx.Exec(f.ctx, "select pg_advisory_xact_lock($1::integer,1)", domain); err != nil {
			t.Fatal(err)
		}
	}
	var done bool
	if err := tx.QueryRow(f.ctx, "select todo.tesl_remove_empty_queue($1,$2,$3,$4,2)", uuid, fence, digest, abi).Scan(&done); err != nil || done {
		t.Fatal("active attempt was ignored", done, err)
	}
	if err := tx.Commit(f.ctx); err != nil {
		t.Fatal(err)
	}
	f.state(1)
	if before != f.snapshot() {
		t.Fatal("committing a false preflight published partial removal")
	}
	var count int
	if err := f.db.QueryRow(f.ctx, "select count(*) from todo.tesl_row_queue_conversion_attempts").Scan(&count); err != nil || count != 1 {
		t.Fatal("attempt discarded", count, err)
	}
}

func TestQueueRemovalWorkerAutomation(t *testing.T) {
	f := newRemovalFixture(t, true)
	cmd := f.command(2, f.worker, "app", "--schema", "worker", "--json")
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = cmd.Process.Kill(); _ = cmd.Wait() })
	ready := make(chan error, 1)
	go func() {
		var value struct {
			Kind string `json:"kind"`
		}
		err := json.NewDecoder(stdout).Decode(&value)
		if err == nil && value.Kind != "schema-worker-ready" {
			err = errors.New("unexpected worker lifecycle response")
		}
		ready <- err
	}()
	select {
	case err := <-ready:
		if err != nil {
			t.Fatal(err)
		}
	case <-f.ctx.Done():
		t.Fatal("Worker did not publish the removal before becoming ready")
	}
	f.state(2)
}

func TestQueueRemovalMissingClaimAuthorityCannotManufactureEmptiness(t *testing.T) {
	f := newRemovalFixture(t, true)
	f.enqueue(f.request, "Notifications", "claimed-must-remain")
	c := f.claim(f.request, "Notifications", "pending")
	before := f.snapshot()
	cfg := f.cfg.Copy()
	cfg.User = f.worker
	worker, err := pgx.ConnectConfig(f.ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer worker.Close(f.ctx)
	_, err = worker.Exec(f.ctx, "delete from todo.tesl_jobs where id=$1", c.id)
	var denied *pgconn.PgError
	if !errors.As(err, &denied) || denied.Code != "42501" {
		t.Fatalf("schema Worker could erase a claim: %v", err)
	}
	var completed bool
	if err := worker.QueryRow(f.ctx, "select todo.tesl_queue_complete(1,'Notifications',$1,'missing-claim-token',$2)", c.id, c.seq).Scan(&completed); err != nil || completed {
		t.Fatal("missing claim proof authorized completion", completed, err)
	}
	if before != f.snapshot() {
		t.Fatal("failed claim proof changed the retained job")
	}
	f.blocked()
}

func TestQueueRemovalRequiresOriginalProtocolMarker(t *testing.T) {
	f := newRemovalFixture(t, true)
	before := f.snapshot()
	if _, err := f.db.Exec(f.ctx, "delete from todo.tesl_schema_queue_removal_protocol"); err != nil {
		t.Fatal(err)
	}
	out, err := f.catchup().CombinedOutput()
	if err == nil || !strings.Contains(string(out), "protocol marker") {
		t.Fatalf("missing original protocol was adopted: %v\n%s", err, out)
	}
	out, err = f.command(2, f.cfg.User, "app", "--schema", "install", "--worker", f.worker, "--request", f.requestRole).CombinedOutput()
	if err == nil || !strings.Contains(string(out), "protocol marker") {
		t.Fatalf("Installer silently adopted missing original protocol: %v\n%s", err, out)
	}
	if before != f.snapshot() {
		t.Fatal("missing marker changed data or publication")
	}
	if _, err := f.db.Exec(f.ctx, "insert into todo.tesl_schema_queue_removal_protocol values(1,1)"); err != nil {
		t.Fatal(err)
	}
	f.run(f.catchup())
	f.state(2)
}
