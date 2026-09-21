package teslmodtodoapp

import (
	"context"
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
		if err := observer.QueryRow(ctx, `select jsonb_build_object('state',(select to_jsonb(s) from todo.tesl_schema_state s),'history',(select jsonb_agg(to_jsonb(v) order by version,step,seq) from todo.tesl_schema_versions v),'epochs',(select jsonb_agg(to_jsonb(e)) from todo.tesl_row_epochs e))::text`).Scan(&s); err != nil {
			t.Fatal(err)
		}
		return s
	}
	before = snapshot()
	for _, flags := range [][]string{{}, {"--force"}, {"--dry-run"}, {"--force", "--dry-run"}} {
		args := append([]string{"--schema", "close-epoch", "--through", "V2", "--json"}, flags...)
		out, err := command(2, worker, "app", args...).CombinedOutput()
		if err == nil || !strings.Contains(string(out), "queue-bearing history retirement is not supported") {
			t.Fatalf("queue epoch not refused %v: %v %s", flags, err, out)
		}
	}
	after = snapshot()
	if before != after {
		t.Fatal("refused epoch changed durable state", before, after)
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
