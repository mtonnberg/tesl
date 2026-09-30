package teslmodtodoapp

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"github.com/jackc/pgx/v5"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	teslrt "tesl.generated/teslmodtodoapp/internal/teslrt"
	"testing"
	"time"
)

func TestQueueApplicationStage(t *testing.T) {
	stage := os.Getenv("QUEUE_APP_STAGE")
	if stage == "" {
		t.Skip("child only")
	}
	if err := teslrt.PreflightApplicationDatabases(DDatabase); err != nil {
		t.Fatal(err)
	}
	teslrt.WithDatabase(DDatabase, func() {
		success := func(any) teslrt.JobOutcome { return teslrt.JobOutcome{OK: true} }
		failure := func(any) teslrt.JobOutcome { return teslrt.JobOutcome{Message: "retry"} }
		switch stage {
		case "seed":
			teslrt.Enqueue(TasksQueue, payload("delayed"))
			if got := teslrt.ProcessNextJob(TasksQueue, failure); !got.Ran || got.OK {
				t.Fatal("retry did not run", got)
			}
			teslrt.Enqueue(TasksQueue, payload("pending"))
			teslrt.Enqueue(TasksQueue, payload("dead"))
			func() {
				defer func() {
					if recover() == nil {
						t.Fatal("rollback trap missing")
					}
				}()
				teslrt.WithTransaction(func() { addNote(); teslrt.Enqueue(TasksQueue, payload("rollback")); panic("rollback") })
			}()
		case "v2":
			count := 0
			for {
				out := teslrt.ProcessNextJob(TasksQueue, func(value any) teslrt.JobOutcome {
					count++
					if !strings.Contains(fmt.Sprint(value), "pending") && !strings.Contains(fmt.Sprint(value), "delayed") {
						t.Fatal("wrong typed old payload", value)
					}
					return success(value)
				})
				if !out.Ran {
					break
				}
			}
			if count != 2 {
				t.Fatalf("new worker consumed %d old pending/delayed jobs", count)
			}
			dead := teslrt.DeadJobs(TasksQueue)
			if len(dead) != 1 {
				t.Fatal("old dead job invisible", dead)
			}
			if !teslrt.Requeue(dead[0]) {
				t.Fatal("old dead job not requeued by new worker")
			}
			if out := teslrt.ProcessNextJob(TasksQueue, success); !out.Ran || !out.OK {
				t.Fatal("old dead job not consumed", out)
			}
			teslrt.Enqueue(TasksQueue, payload("future"))
		case "old":
			if out := teslrt.ProcessNextJob(TasksQueue, success); out.Ran {
				t.Fatal("old binary claimed future payload", out)
			}
		case "stale":
			teslrt.Enqueue(TasksQueue, payload("stale"))
		case "finish":
			if out := teslrt.ProcessNextJob(TasksQueue, success); !out.Ran || !out.OK {
				t.Fatal("new binary cannot consume own job", out)
			}
		default:
			t.Fatal(stage)
		}
	})
}

func TestQueueApplication(t *testing.T) {
	t.Run("retirement-and-crashes", func(t *testing.T) { queueApplication(t, false) })
	t.Run("quarantine-refuses-retirement", func(t *testing.T) { queueApplication(t, true) })
}

func queueApplication(t *testing.T, quarantineOnly bool) {
	host := os.Getenv("TESL_TEST_POSTGRES_SHARED_HOST")
	if host == "" {
		if os.Getenv("TESL_MIGRATION_TEST_REQUIRE_POSTGRES") == "1" {
			t.Fatal("required PostgreSQL missing")
		}
		t.Skip("PostgreSQL required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 150*time.Second)
	defer cancel()
	cfg, err := pgx.ParseConfig("")
	if err != nil {
		t.Fatal(err)
	}
	cfg.Host = host
	port, _ := strconv.Atoi(os.Getenv("TESL_TEST_POSTGRES_SHARED_PORT"))
	cfg.Port = uint16(port)
	cfg.User = os.Getenv("TESL_TEST_POSTGRES_SHARED_USER")
	cfg.Database = os.Getenv("TESL_TEST_POSTGRES_SHARED_ADMIN_DATABASE")
	admin, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	name := "qa_" + strings.ReplaceAll(teslrt.UUIDv7(), "-", "")
	owner, worker, request := name+"_owner", name+"_worker", name+"_request"
	q := func(s string) string { return pgx.Identifier{s}.Sanitize() }
	t.Cleanup(func() {
		cleanup, stop := context.WithTimeout(context.Background(), 10*time.Second)
		defer stop()
		_, _ = admin.Exec(cleanup, "drop database if exists "+q(name)+" with (force)")
		for _, r := range []string{request, worker, owner} {
			_, _ = admin.Exec(cleanup, "drop role if exists "+q(r))
		}
		_ = admin.Close(cleanup)
	})
	for _, sql := range []string{"create role " + q(owner) + " nologin", "create role " + q(worker) + " login", "create role " + q(request) + " login", "create database " + q(name), "grant create on database " + q(name) + " to " + q(owner)} {
		if _, err := admin.Exec(ctx, sql); err != nil {
			t.Fatal(err)
		}
	}
	cfg.Database = name
	observer, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer observer.Close(context.Background())
	if _, err := observer.Exec(ctx, "grant create on schema public to "+q(owner)); err != nil {
		t.Fatal(err)
	}
	base := append(os.Environ(), "Q_HOST="+host, "Q_PORT="+strconv.Itoa(port), "Q_DB="+name, "Q_OWNER="+owner, "Q_WORKER="+worker, "Q_REQUEST="+request, "Q_DDL="+cfg.ConnString())
	versions := map[int]string{1: os.Getenv("QUEUE_APP_V1"), 2: os.Getenv("QUEUE_APP_V2")}
	command := func(version int, login, executable string, args ...string) *exec.Cmd {
		cmd := exec.CommandContext(ctx, filepath.Join(versions[version], executable), args...)
		cmd.Env = append(append([]string{}, base...), "Q_USER="+login)
		return cmd
	}
	run := func(cmd *exec.Cmd) string {
		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("%v: %v\n%s", cmd.Args, err, out)
		}
		return string(out)
	}
	run(command(1, cfg.User, "app", "--schema", "install", "--worker", worker, "--request", request, "--json"))
	startWorker := func(version int) {
		cmd := command(version, worker, "app", "--schema", "worker", "--json")
		log, err := os.CreateTemp(t.TempDir(), "worker-")
		if err != nil {
			t.Fatal(err)
		}
		cmd.Stdout = log
		cmd.Stderr = log
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = cmd.Process.Kill(); _ = cmd.Wait(); _ = log.Close() })
		deadline := time.Now().Add(20 * time.Second)
		for time.Now().Before(deadline) {
			b, _ := os.ReadFile(log.Name())
			if strings.Contains(string(b), "schema-worker-ready") {
				return
			}
			time.Sleep(25 * time.Millisecond)
		}
		b, _ := os.ReadFile(log.Name())
		t.Fatalf("worker did not become ready: %s", b)
	}
	stage := func(v int, s string) {
		cmd := command(v, request, "application.test", "-test.run", "^TestQueueApplicationStage$", "-test.v")
		cmd.Env = append(cmd.Env, "QUEUE_APP_STAGE="+s)
		run(cmd)
	}
	startWorker(1)
	stage(1, "seed")
	var count int
	if err := observer.QueryRow(ctx, "select count(*) from todo.notes").Scan(&count); err != nil || count != 0 {
		t.Fatal("entity rollback failed", count, err)
	}
	if err := observer.QueryRow(ctx, "select count(*) from todo.tesl_jobs").Scan(&count); err != nil || count != 3 {
		t.Fatal("queue rollback failed", count, err)
	}
	// Calibrate retained delayed/dead states without changing their typed payload,
	// source-version identity or any compiler-owned control metadata.
	if _, err := observer.Exec(ctx, `update todo.tesl_jobs set status='dead',dead_reason='attempts-exhausted' where payload->>'text'='dead';update todo.tesl_jobs set next_attempt_at=clock_timestamp()-interval '1 second' where payload->>'text'='delayed'`); err != nil {
		t.Fatal(err)
	}
	startWorker(2)
	stage(2, "v2")
	stage(1, "old")
	stage(2, "finish")
	if err := observer.QueryRow(ctx, "select count(*) from todo.tesl_jobs").Scan(&count); err != nil || count != 0 {
		t.Fatal("jobs stranded", count, err)
	}
	stage(2, "stale")
	requestConfig := cfg.Copy()
	requestConfig.User = request
	requestSQL, err := pgx.ConnectConfig(ctx, requestConfig)
	if err != nil {
		t.Fatal(err)
	}
	defer requestSQL.Close(context.Background())
	var claimID, firstToken, secondToken string
	var firstSeq, secondSeq int64
	if err := requestSQL.QueryRow(ctx, "select job_id,token,attempt_seq from todo.tesl_queue_claim(2,'Notifications','pending','first',1)").Scan(&claimID, &firstToken, &firstSeq); err != nil {
		t.Fatal(err)
	}
	time.Sleep(10 * time.Millisecond)
	stage(1, "old") // A stale V2 lease is still not reclaimable by V1.
	if err := requestSQL.QueryRow(ctx, "select token,attempt_seq from todo.tesl_queue_claim(2,'Notifications','pending','replacement',30000)").Scan(&secondToken, &secondSeq); err != nil || firstToken == secondToken || secondSeq <= firstSeq {
		t.Fatal("attempt not replaced", err)
	}
	var owned bool
	if err := requestSQL.QueryRow(ctx, "select todo.tesl_queue_complete(2,'Notifications',$1,$2,$3)", claimID, firstToken, firstSeq).Scan(&owned); err != nil || owned {
		t.Fatal("stale attempt completed", owned, err)
	}
	if err := requestSQL.QueryRow(ctx, "select todo.tesl_queue_complete(2,'Notifications',$1,$2,$3)", claimID, secondToken, secondSeq).Scan(&owned); err != nil || !owned {
		t.Fatal("replacement lost ownership", owned, err)
	}
	var before, after string
	snapshot := func() string {
		var s string
		if err := observer.QueryRow(ctx, `select jsonb_build_object('state',(select to_jsonb(s) from todo.tesl_schema_state s),'history',(select jsonb_agg(to_jsonb(v) order by version,step,seq) from todo.tesl_schema_versions v),'epochs',(select jsonb_agg(to_jsonb(e)) from todo.tesl_row_epochs e),'jobs',(select jsonb_agg(to_jsonb(j) order by id) from todo.tesl_jobs j))::text`).Scan(&s); err != nil {
			t.Fatal(err)
		}
		return s
	}
	before = snapshot()
	for _, flags := range [][]string{{"--dry-run"}, {"--force", "--dry-run"}} {
		args := append([]string{"--schema", "close-epoch", "--through", "V2", "--json"}, flags...)
		out, err := command(2, worker, "app", args...).CombinedOutput()
		if err != nil || !strings.Contains(string(out), "schema-epoch-preview") {
			t.Fatalf("queue epoch preview %v: %v %s", flags, err, out)
		}
	}
	after = snapshot()
	if before != after {
		t.Fatal("epoch preview changed durable state", before, after)
	}
	// Even a payload byte edit with a freshly recomputed table digest cannot
	// borrow the immutable source inventory's authority to move admission.
	var sourceBytes []byte
	var sourceDigest string
	if err := observer.QueryRow(ctx, `select contract,contract_hash from todo.tesl_queue_payloads where version=1 and queue='Notifications' and job_type='Notify'`).Scan(&sourceBytes, &sourceDigest); err != nil {
		t.Fatal(err)
	}
	forgedBytes := bytes.Replace(sourceBytes, []byte("text"), []byte("next"), 1)
	if bytes.Equal(forgedBytes, sourceBytes) {
		t.Fatal("source contract has no expected field name to mutate canonically")
	}
	if tag, err := observer.Exec(ctx, `update todo.tesl_queue_payloads set contract=$1,contract_hash=encode(sha256($1::bytea),'hex') where version=1 and queue='Notifications' and job_type='Notify'`, forgedBytes); err != nil || tag.RowsAffected() != 1 {
		t.Fatal("failed to construct freshly hashed catalog substitution", tag, err)
	}
	out, err := command(2, worker, "app", "--schema", "close-epoch", "--through", "V2", "--force", "--json").CombinedOutput()
	if err == nil || (!strings.Contains(string(out), "inventory") && !strings.Contains(string(out), "source binding")) {
		t.Fatalf("resigned foreign payload authorized retirement: %v %s", err, out)
	}
	if after = snapshot(); before != after {
		t.Fatal("refused forged inventory changed floor, jobs or receipts")
	}
	if tag, err := observer.Exec(ctx, `update todo.tesl_queue_payloads set contract=$1,contract_hash=$2 where version=1 and queue='Notifications' and job_type='Notify'`, sourceBytes, sourceDigest); err != nil || tag.RowsAffected() != 1 {
		t.Fatal("could not restore original immutable queue catalog", tag, err)
	}
	// Two attempts on old payloads: retirement must preserve a surviving
	// claimant, but cannot invalidate an old claimant before its lease expires.
	enqueue := func(id string) {
		if _, err := requestSQL.Exec(ctx, `select todo.tesl_queue_enqueue(1,'Notifications','Notify',$1,jsonb_build_object('text',$1::text))`, id); err != nil {
			t.Fatal(err)
		}
	}
	claim := func(version int, id string) (string, int64) {
		var actual, token string
		var seq int64
		if err := requestSQL.QueryRow(ctx, `select job_id,token,attempt_seq from todo.tesl_queue_claim($1,'Notifications','pending',$2,300000)`, version, id).Scan(&actual, &token, &seq); err != nil || actual != id {
			t.Fatal("claim wrong old payload", actual, id, err)
		}
		return token, seq
	}
	enqueue("surviving")
	survivingToken, survivingSeq := claim(2, "surviving")
	enqueue("retiring")
	retiringToken, retiringSeq := claim(1, "retiring")
	deadClaim := func(version int, id string) (string, int64) {
		enqueue(id)
		if _, err := observer.Exec(ctx, `update todo.tesl_jobs set status='dead',dead_reason='attempts-exhausted' where id=$1`, id); err != nil {
			t.Fatal(err)
		}
		var actual, token string
		var seq int64
		if err := requestSQL.QueryRow(ctx, `select job_id,token,attempt_seq from todo.tesl_queue_claim($1,'Notifications','dead',$2,300000)`, version, id).Scan(&actual, &token, &seq); err != nil || actual != id {
			t.Fatal("claim wrong old dead payload", actual, id, err)
		}
		return token, seq
	}
	survivingDeadToken, survivingDeadSeq := deadClaim(2, "surviving-dead")
	retiringDeadToken, retiringDeadSeq := deadClaim(1, "retiring-dead")
	if quarantineOnly {
		enqueue("quarantined")
		token, sequence := claim(1, "quarantined")
		if err := requestSQL.QueryRow(ctx, `select todo.tesl_queue_quarantine(1,'Notifications','quarantined',$1,$2)`, token, sequence).Scan(&owned); err != nil || !owned {
			t.Fatal("could not quarantine original payload", owned, err)
		}
		before = snapshot()
		out, err := command(2, worker, "app", "--schema", "close-epoch", "--through", "V2", "--force", "--json").CombinedOutput()
		if err == nil || !strings.Contains(string(out), "quarantined queue payload requires typed repair") {
			t.Fatalf("quarantine did not block forced retirement: %v %s", err, out)
		}
		if err := requestSQL.QueryRow(ctx, `select todo.tesl_queue_requeue(2,'Notifications','quarantined')`).Scan(&owned); err != nil || owned {
			t.Fatal("ordinary requeue bypassed typed repair", owned, err)
		}
		if after = snapshot(); before != after {
			t.Fatal("refused retirement/requeue changed quarantined bytes, source stamp or admission")
		}
		return
	}
	stage(1, "seed")
	if _, err := observer.Exec(ctx, `update todo.tesl_jobs set status='dead',dead_reason='attempts-exhausted' where payload->>'text'='dead'`); err != nil {
		t.Fatal(err)
	}
	before = snapshot()
	out, err = command(2, worker, "app", "--schema", "close-epoch", "--through", "V2", "--force", "--json").CombinedOutput()
	if err == nil || !strings.Contains(string(out), "retiring queue attempts are still leased") {
		t.Fatalf("live old attempt did not block retirement: %v %s", err, out)
	}
	if after = snapshot(); before != after {
		t.Fatal("leased-attempt refusal changed durable state")
	}
	// Calibrate lease expiry without changing token, sequence or payload.
	if _, err := observer.Exec(ctx, `update todo.tesl_jobs set lease_until=clock_timestamp()-interval '1 second' where id in ('retiring','retiring-dead')`); err != nil {
		t.Fatal(err)
	}
	var survivingBefore, jobsBefore string
	if err := observer.QueryRow(ctx, `select jsonb_agg(to_jsonb(j)-'schema_version' order by id)::text from todo.tesl_jobs j where id in ('surviving','surviving-dead')`).Scan(&survivingBefore); err != nil {
		t.Fatal(err)
	}
	if err := observer.QueryRow(ctx, `select jsonb_agg(to_jsonb(j)-'schema_version' order by id)::text from todo.tesl_jobs j where status in ('pending','dead')`).Scan(&jobsBefore); err != nil {
		t.Fatal(err)
	}
	crashEpoch := func(boundary string, oldFence pgx.Tx, inspect func()) {
		t.Helper()
		dir, err := os.MkdirTemp(os.Getenv("TESL_MIGRATION_TEST_SOCKET_TMPDIR"), "qe-")
		if err != nil {
			t.Fatal(err)
		}
		defer os.RemoveAll(dir)
		socket := filepath.Join(dir, "s")
		listener, err := net.Listen("unix", socket)
		if err != nil {
			t.Fatal(err)
		}
		defer listener.Close()
		arrived := make(chan net.Conn, 1)
		busy := make(chan struct{}, 1)
		listenerDone := make(chan struct{})
		go func() {
			defer close(listenerDone)
			for {
				connection, err := listener.Accept()
				if err != nil {
					return
				}
				_ = connection.SetDeadline(time.Now().Add(10 * time.Second))
				var event struct{ Name string }
				if err := json.NewDecoder(connection).Decode(&event); err == nil {
					if event.Name == boundary {
						arrived <- connection
						return
					}
					if event.Name == "row-epoch-compatibility-busy" {
						select {
						case busy <- struct{}{}:
						default:
						}
					}
				}
				_, _ = io.WriteString(connection, "continue\n")
				_ = connection.Close()
			}
		}()
		defer func() { _ = listener.Close(); <-listenerDone }()
		cmd := command(2, worker, "app", "--schema", "close-epoch", "--through", "V2", "--force", "--json")
		cmd.Env = append(cmd.Env, "TESL_MIGRATION_TEST_SOCKET="+socket)
		log, err := os.CreateTemp(t.TempDir(), "epoch-")
		if err != nil {
			t.Fatal(err)
		}
		defer log.Close()
		cmd.Stdout, cmd.Stderr = log, log
		if err := cmd.Start(); err != nil {
			t.Fatal(err)
		}
		done := make(chan error, 1)
		go func() { done <- cmd.Wait(); close(done) }()
		defer func() { _ = cmd.Process.Kill(); <-done }()
		if oldFence != nil {
			select {
			case <-busy:
				if after = snapshot(); before != after {
					t.Fatal("epoch advanced while an old queue transaction held the writer fence")
				}
				if err := oldFence.Commit(ctx); err != nil {
					t.Fatal("old queue transaction failed to finish", err)
				}
			case err := <-done:
				t.Fatalf("epoch bypassed old queue transaction: %v", err)
			case <-time.After(15 * time.Second):
				t.Fatal("epoch did not observe old queue transaction")
			}
		}
		select {
		case connection := <-arrived:
			defer connection.Close()
			inspect()
			if err := cmd.Process.Kill(); err != nil {
				t.Fatal(err)
			}
			<-done
		case err := <-done:
			b, _ := os.ReadFile(log.Name())
			t.Fatalf("epoch ended before %s: %v %s", boundary, err, b)
		case <-time.After(15 * time.Second):
			t.Fatalf("epoch did not reach %s", boundary)
		}
	}
	before = snapshot()
	oldFence, err := requestSQL.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer oldFence.Rollback(context.Background())
	if err := oldFence.QueryRow(ctx, `select todo.tesl_queue_count(1,'Notifications','pending')`).Scan(&count); err != nil {
		t.Fatal("old queue operation failed to hold its retirement fence", err)
	}
	crashEpoch("row-epoch-after-publication", oldFence, func() {
		if after = snapshot(); before != after {
			t.Fatal("uncommitted restamping/floor escaped transaction")
		}
	})
	if after = snapshot(); before != after {
		t.Fatal("crash before commit retained partial restamping or admission")
	}
	crashEpoch("row-epoch-after-commit", nil, func() {})
	var minimum, floor, oldJobs int
	if err := observer.QueryRow(ctx, `select min_version,compat_floor,(select count(*) from todo.tesl_jobs where schema_version<2) from todo.tesl_schema_state`).Scan(&minimum, &floor, &oldJobs); err != nil || minimum != 2 || floor != 2 || oldJobs != 0 {
		t.Fatal("floor published without queue finality", minimum, floor, oldJobs, err)
	}
	// An administrator-created stranded stamp cannot be ignored merely because
	// ordinary claim predicates would skip it. Both read and write admission
	// must expose the inconsistent durable state until it is repaired.
	if tag, err := observer.Exec(ctx, `update todo.tesl_jobs set schema_version=1 where id='surviving'`); err != nil || tag.RowsAffected() != 1 {
		t.Fatal("fixture failed to forge existing job", tag, err)
	}
	for _, sql := range []string{
		`select todo.tesl_queue_count(2,'Notifications','dead')`,
		`select todo.tesl_queue_enqueue(2,'Notifications','Notify','must-not-enqueue','{}'::jsonb)`,
	} {
		if _, err := requestSQL.Exec(ctx, sql); err == nil || !strings.Contains(err.Error(), "non-quarantined queue job is below the admission floor") {
			t.Fatalf("stranded payload escaped admission: %s: %v", sql, err)
		}
	}
	if tag, err := observer.Exec(ctx, `update todo.tesl_jobs set schema_version=2 where id='surviving'`); err != nil || tag.RowsAffected() != 1 {
		t.Fatal("fixture failed to restore job version", tag, err)
	}
	// A quarantined historical payload is deliberately inspectable below the
	// admission floor. It is not claimable or requeueable as a current typed job.
	if tag, err := observer.Exec(ctx, `insert into todo.tesl_jobs(id,queue,job_type,payload,schema_version,status,dead_reason)
		values('visible-quarantine','Notifications','Notify','{}'::jsonb,1,'quarantined','payload-invalid')`); err != nil || tag.RowsAffected() != 1 {
		t.Fatal("could not model an administrator-retained quarantine", tag, err)
	}
	var seenVersion int
	var seenReason string
	if err := requestSQL.QueryRow(ctx, `select source_version,reason from todo.tesl_queue_dead_jobs(2,'Notifications') where job_id='visible-quarantine'`).Scan(&seenVersion, &seenReason); err != nil || seenVersion != 1 || seenReason != "payload-invalid" {
		t.Fatal("retained quarantine was silently hidden", seenVersion, seenReason, err)
	}
	if err := requestSQL.QueryRow(ctx, `select todo.tesl_queue_requeue(2,'Notifications','visible-quarantine')`).Scan(&owned); err != nil || owned {
		t.Fatal("retained quarantine became a current typed job", owned, err)
	}
	if tag, err := observer.Exec(ctx, `delete from todo.tesl_jobs where id='visible-quarantine'`); err != nil || tag.RowsAffected() != 1 {
		t.Fatal("could not clear adversarial quarantine fixture", tag, err)
	}
	var survivingAfter, jobsAfter string
	if err := observer.QueryRow(ctx, `select jsonb_agg(to_jsonb(j)-'schema_version' order by id)::text from todo.tesl_jobs j where id in ('surviving','surviving-dead')`).Scan(&survivingAfter); err != nil || survivingAfter != survivingBefore {
		t.Fatal("surviving claim identity/lease changed", survivingBefore, survivingAfter, err)
	}
	if err := observer.QueryRow(ctx, `select jsonb_agg(to_jsonb(j)-'schema_version' order by id)::text from todo.tesl_jobs j where status in ('pending','dead') and id not in ('retiring','retiring-dead')`).Scan(&jobsAfter); err != nil || jobsBefore != jobsAfter {
		t.Fatal("restamping changed pending/delayed/dead payload or scheduling", jobsBefore, jobsAfter, err)
	}
	if err := requestSQL.QueryRow(ctx, `select todo.tesl_queue_complete(2,'Notifications','surviving',$1,$2)`, survivingToken, survivingSeq).Scan(&owned); err != nil || !owned {
		t.Fatal("surviving claimant could not finish after restamping", owned, err)
	}
	if err := requestSQL.QueryRow(ctx, `select todo.tesl_queue_complete(2,'Notifications','surviving-dead',$1,$2)`, survivingDeadToken, survivingDeadSeq).Scan(&owned); err != nil || !owned {
		t.Fatal("surviving dead-letter claimant could not finish", owned, err)
	}
	if _, err := requestSQL.Exec(ctx, `select todo.tesl_queue_complete(1,'Notifications','retiring',$1,$2)`, retiringToken, retiringSeq); err == nil {
		t.Fatal("retired claimant completed")
	}
	if _, err := requestSQL.Exec(ctx, `select todo.tesl_queue_enqueue(1,'Notifications','Notify','late','{}'::jsonb)`); err == nil {
		t.Fatal("retired producer enqueued")
	}
	// Expired old attempts are claimable under a new attempt, never the old one.
	var reclaimedToken string
	var reclaimedSeq int64
	if err := requestSQL.QueryRow(ctx, `select token,attempt_seq from todo.tesl_queue_claim(2,'Notifications','pending','reclaimed',30000)`).Scan(&reclaimedToken, &reclaimedSeq); err != nil || reclaimedSeq <= retiringSeq || reclaimedToken == retiringToken {
		t.Fatal("expired old attempt was not replaced", reclaimedSeq, err)
	}
	if err := requestSQL.QueryRow(ctx, `select todo.tesl_queue_complete(2,'Notifications','retiring',$1,$2)`, reclaimedToken, reclaimedSeq).Scan(&owned); err != nil || !owned {
		t.Fatal("replacement did not own retired attempt's job", owned, err)
	}
	if err := requestSQL.QueryRow(ctx, `select token,attempt_seq from todo.tesl_queue_claim(2,'Notifications','dead','reclaimed-dead',30000)`).Scan(&reclaimedToken, &reclaimedSeq); err != nil || reclaimedSeq <= retiringDeadSeq || reclaimedToken == retiringDeadToken {
		t.Fatal("expired dead-letter attempt was not replaced", reclaimedSeq, err)
	}
	if err := requestSQL.QueryRow(ctx, `select todo.tesl_queue_complete(2,'Notifications','retiring-dead',$1,$2)`, reclaimedToken, reclaimedSeq).Scan(&owned); err != nil || !owned {
		t.Fatal("replacement did not own old dead-letter job", owned, err)
	}
	if _, err := observer.Exec(ctx, `update todo.tesl_jobs set next_attempt_at=clock_timestamp()-interval '1 second' where payload->>'text'='delayed'`); err != nil {
		t.Fatal(err)
	}
	stage(2, "v2")
	stage(2, "finish")
	before = snapshot()
	run(command(2, worker, "app", "--schema", "close-epoch", "--through", "V2", "--force", "--json"))
	if after = snapshot(); before != after {
		t.Fatal("completed epoch retry changed durable state")
	}
	// Run the ordinary generated App, including its emitted worker and LISTEN
	// lifecycle. This is separate from deterministic public-API test stages.
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := listener.Addr().String()
	_, httpPort, _ := net.SplitHostPort(address)
	_ = listener.Close()
	appCmd := command(2, request, "app")
	appCmd.Env = append(appCmd.Env, "Q_HTTP_PORT="+httpPort)
	appLog, err := os.CreateTemp(t.TempDir(), "ordinary-app-")
	if err != nil {
		t.Fatal(err)
	}
	appCmd.Stdout = appLog
	appCmd.Stderr = appLog
	if err := appCmd.Start(); err != nil {
		t.Fatal(err)
	}
	appDone := make(chan error, 1)
	go func() { appDone <- appCmd.Wait() }()
	stopped := false
	t.Cleanup(func() {
		if !stopped {
			_ = appCmd.Process.Kill()
			<-appDone
		}
		_ = appLog.Close()
	})
	client := &http.Client{Timeout: time.Second}
	wait := func(label string, check func() bool) {
		deadline := time.Now().Add(20 * time.Second)
		for time.Now().Before(deadline) {
			select {
			case err := <-appDone:
				b, _ := os.ReadFile(appLog.Name())
				stopped = true
				t.Fatalf("ordinary App exited: %v %s", err, b)
			default:
			}
			if check() {
				return
			}
			time.Sleep(25 * time.Millisecond)
		}
		b, _ := os.ReadFile(appLog.Name())
		t.Fatalf("%s timed out: %s", label, b)
	}
	wait("HTTP health", func() bool {
		r, e := client.Get("http://" + address + "/")
		if e != nil {
			return false
		}
		defer r.Body.Close()
		return r.StatusCode == 200
	})
	var listenerPID int
	wait("protected queue LISTEN admission", func() bool {
		return observer.QueryRow(ctx, `select pid from pg_stat_activity where datname=$1 and usename=$2 and query='listen "tesl_queue"' order by backend_start desc limit 1`, name, request).Scan(&listenerPID) == nil
	})
	if _, err := observer.Exec(ctx, "select pg_terminate_backend($1)", listenerPID); err != nil {
		t.Fatal(err)
	}
	previousListener := listenerPID
	wait("protected queue LISTEN reconnect admission", func() bool {
		return observer.QueryRow(ctx, `select pid from pg_stat_activity where datname=$1 and usename=$2 and query='listen "tesl_queue"' and pid<>$3 order by backend_start desc limit 1`, name, request, previousListener).Scan(&listenerPID) == nil
	})
	r, err := client.Post("http://"+address+"/send", "application/json", strings.NewReader("{}"))
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(r.Body)
	_ = r.Body.Close()
	if r.StatusCode != 200 {
		t.Fatal("enqueue handler", r.StatusCode, string(body))
	}
	wait("generated worker consumes endpoint payload", func() bool {
		var n, j int
		err := observer.QueryRow(ctx, "select (select count(*) from todo.notes where id='rollback'),(select count(*) from todo.tesl_jobs)").Scan(&n, &j)
		return err == nil && n == 1 && j == 0
	})
	if err := appCmd.Process.Signal(os.Interrupt); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-appDone:
		stopped = true
		if err != nil {
			t.Fatal("ordinary app graceful shutdown", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("ordinary app queue shutdown hung")
	}

	var forbidden int
	if err := observer.QueryRow(ctx, `select count(*) from information_schema.tables where table_schema='todo' and table_name in ('tesl_pubsub_outbox','tesl_cache','tesl_email_outbox')`).Scan(&forbidden); err != nil || forbidden != 0 {
		t.Fatal("unexpected facility bootstrap", forbidden, err)
	}

}
