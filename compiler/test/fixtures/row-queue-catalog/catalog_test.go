package teslmodtodoapp

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	teslrt "tesl.generated/teslmodtodoapp/internal/teslrt"
)

func TestRowQueueCatalogPostgres(t *testing.T) {
	host, user := os.Getenv("TESL_TEST_POSTGRES_SHARED_HOST"), os.Getenv("TESL_TEST_POSTGRES_SHARED_USER")
	if host == "" || user == "" {
		if os.Getenv("TESL_MIGRATION_TEST_REQUIRE_POSTGRES") == "1" {
			t.Fatal("required PostgreSQL configuration missing")
		}
		t.Skip("requires PostgreSQL catalog lane")
	}
	port, err := strconv.Atoi(os.Getenv("TESL_TEST_POSTGRES_SHARED_PORT"))
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	cfg, err := pgx.ParseConfig("")
	if err != nil {
		t.Fatal(err)
	}
	cfg.Host = host
	cfg.Port = uint16(port)
	cfg.User = user
	cfg.Database = os.Getenv("TESL_TEST_POSTGRES_SHARED_ADMIN_DATABASE")
	if cfg.Database == "" {
		cfg.Database = "postgres"
	}
	admin, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	name := "rq_" + strings.ReplaceAll(teslrt.UUIDv7(), "-", "")
	roles := teslrt.PgMigrationControlRoles{Owner: name + "_owner", Worker: name + "_worker", Request: name + "_request"}
	q := func(value string) string { return pgx.Identifier{value}.Sanitize() }
	var installer, worker, request *pgx.Conn
	t.Cleanup(func() {
		cleanup, stop := context.WithTimeout(context.Background(), 10*time.Second)
		defer stop()
		for _, conn := range []*pgx.Conn{request, worker, installer} {
			if conn != nil {
				_ = conn.Close(cleanup)
			}
		}
		_, _ = admin.Exec(cleanup, "drop database if exists "+q(name)+" with (force)")
		for _, role := range []string{roles.Request, roles.Worker, roles.Owner} {
			_, _ = admin.Exec(cleanup, "drop role if exists "+q(role))
		}
		_ = admin.Close(cleanup)
	})
	for _, sql := range []string{"create role " + q(roles.Owner) + " nologin", "create role " + q(roles.Worker) + " login", "create role " + q(roles.Request) + " login", "create database " + q(name), "grant create on database " + q(name) + " to " + q(roles.Owner)} {
		if _, err := admin.Exec(ctx, sql); err != nil {
			t.Fatal(err)
		}
	}
	cfg.Database = name
	installer, err = pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := installer.Exec(ctx, "grant create on schema public to "+q(roles.Owner)); err != nil {
		t.Fatal(err)
	}
	cfg.User = roles.Worker
	worker, err = pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	cfg.User = roles.Request
	request, err = pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	DDatabase.Config = teslrt.PostgresConfig{Host: host, Port: port, DBName: name, User: roles.Request, Schema: "todo", ControlOwner: roles.Owner, RequestRole: roles.Request, WorkerRole: roles.Worker, MigrationTopology: "Worker"}
	state, err := teslrt.TeslTestRowQueueCatalogInstall(ctx, installer, DDatabase, roles)
	if err != nil {
		t.Fatal(err)
	}
	if state.Format != 5 || state.Current != 0 || state.InitialVersion != 1 {
		t.Fatal("wrong fresh candidate origin", state)
	}
	inspect := func(t *testing.T) {
		t.Helper()
		if err := teslrt.TeslTestRowQueueCatalogInspect(ctx, request, DDatabase, roles); err != nil {
			t.Fatal(err)
		}
	}
	inspect(t)
	if expanded, err := teslrt.TeslTestRowQueueCatalogExpand(ctx, worker, DDatabase, roles); err != nil || expanded.Current != 1 {
		t.Fatal("original V1 entity/catalog expansion", expanded, err)
	}
	inspect(t)
	var count int
	if err := installer.QueryRow(ctx, "select count(*) from todo.tesl_queue_payloads where version=1 and queue='Notifications' and job_type='Notify'").Scan(&count); err != nil || count != 1 {
		t.Fatal("lost exact original payload", count, err)
	}
	if err := teslrt.PreflightApplicationDatabases(DDatabase); err != nil {
		t.Fatal("checked additive Worker queue preflight refused", err)
	}
	// Protected SQL is a separate prerequisite from public App dispatch.
	rowQueueRetirementRefuses(t, ctx, installer, worker, roles, 1)
	rowQueueSQLLifecycle(t, ctx, request, 1, "original-v1")
	rowQueueSQLReclaim(t, ctx, request)
	rowQueueSQLRefusals(t, ctx, installer, request, 1)
	if _, err := request.Exec(ctx, "select todo.tesl_queue_enqueue(1,'Notifications','Notify','retained-v1','{\"text\":\"original job\"}'::jsonb)"); err != nil {
		t.Fatal(err)
	}
	// Exact new layout validation rejects an altered private candidate. No upgrade
	// installs missing tables or loosens the catalog comparator.
	for _, tc := range []struct{ name, change, restore, want string }{
		{"physical hash is not storage source", "update todo.tesl_row_queue_sources set expansion_hash=(select storage_snapshot_hash from todo.tesl_queue_versions where version=1)", "update todo.tesl_row_queue_sources set expansion_hash=(select catalog_hash from todo.tesl_row_versions where version=1)", "baseline expansion"},
		{"unknown origin is not empty", "update todo.tesl_queue_baseline set inventory_authority='unknown',established_by='format-upgrade',inventory_hash=null", "update todo.tesl_queue_baseline set inventory_authority='complete',established_by='fresh-install',inventory_hash=(select inventory_hash from todo.tesl_queue_versions where version=1)", "complete fresh origin"},
		{"exact table shape", "alter table todo.tesl_queue_versions add column unrecorded text", "alter table todo.tesl_queue_versions drop column unrecorded", "queue table"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := installer.Exec(ctx, tc.change); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() {
				if _, err := installer.Exec(ctx, tc.restore); err != nil {
					t.Fatal(err)
				}
				inspect(t)
			})
			err := teslrt.TeslTestRowQueueCatalogInspect(ctx, request, DDatabase, roles)
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("wrong exact refusal: %v", err)
			}
		})
	}
	if executable := os.Getenv("TESL_ROW_QUEUE_V2_TEST"); executable != "" {
		command := exec.CommandContext(ctx, executable, "-test.run=^TestRowQueueCatalogRetainedOrigin$", "-test.v")
		command.Env = append(os.Environ(), "TESL_ROW_QUEUE_DB="+name, "TESL_ROW_QUEUE_OWNER="+roles.Owner, "TESL_ROW_QUEUE_WORKER="+roles.Worker, "TESL_ROW_QUEUE_REQUEST="+roles.Request)
		if output, err := command.CombinedOutput(); err != nil {
			t.Fatalf("original V2 could not inspect original V1 catalog: %v\n%s", err, output)
		}
	}
	inspect(t) // Original V1 also validates the complete protected V2 inventory.
	if _, err := installer.Exec(ctx, "drop table todo.tesl_queue_baseline"); err != nil {
		t.Fatal(err)
	}
	if _, err := teslrt.TeslTestRowQueueCatalogInstall(ctx, installer, DDatabase, roles); err == nil {
		t.Fatal("incompatible row5 acquired automatic catalog upgrade")
	}
	var absent bool
	if err := installer.QueryRow(ctx, "select to_regclass('todo.tesl_queue_baseline') is null").Scan(&absent); err != nil || !absent {
		t.Fatal("missing private catalog was silently installed", err)
	}
}

func TestRowQueueCatalogRetainedOrigin(t *testing.T) {
	name := os.Getenv("TESL_ROW_QUEUE_DB")
	if name == "" {
		t.Skip("requires original V1 parent")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cfg, err := pgx.ParseConfig("")
	if err != nil {
		t.Fatal(err)
	}
	cfg.Host = os.Getenv("TESL_TEST_POSTGRES_SHARED_HOST")
	port, err := strconv.Atoi(os.Getenv("TESL_TEST_POSTGRES_SHARED_PORT"))
	if err != nil {
		t.Fatal(err)
	}
	cfg.Port = uint16(port)
	cfg.Database = name
	cfg.User = os.Getenv("TESL_TEST_POSTGRES_SHARED_USER")
	conn, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close(context.Background()) }()
	roles := teslrt.PgMigrationControlRoles{Owner: os.Getenv("TESL_ROW_QUEUE_OWNER"), Worker: os.Getenv("TESL_ROW_QUEUE_WORKER"), Request: os.Getenv("TESL_ROW_QUEUE_REQUEST")}
	DDatabase.Config = teslrt.PostgresConfig{Host: cfg.Host, Port: port, DBName: name, User: roles.Request, Schema: "todo", ControlOwner: roles.Owner, RequestRole: roles.Request, WorkerRole: roles.Worker, MigrationTopology: "Worker"}
	if _, err := teslrt.TeslTestRowQueueCatalogInstall(ctx, conn, DDatabase, roles); err != nil {
		t.Fatal(err)
	}
	cfg.User = roles.Worker
	worker, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = worker.Close(context.Background()) }()
	if err := teslrt.TeslTestRowQueueHeaderCases(ctx, worker, DDatabase); err != nil {
		t.Fatal(err)
	}
	for _, persist := range []bool{false, true} {
		for _, field := range []string{"schema", "storage"} {
			err := teslrt.TeslTestRowQueueBadSource(ctx, worker, DDatabase, field, persist)
			if err == nil || !strings.Contains(err.Error(), "source hashes differ from the stored physical header") {
				t.Fatalf("direct Worker %s substitution (persistPhysical=%v): %v", field, persist, err)
			}
			var physical, queues, sources int
			if err := conn.QueryRow(ctx, "select (select count(*) from todo.tesl_row_physical where version=2),(select count(*) from todo.tesl_queue_versions where version=2),(select count(*) from todo.tesl_row_queue_sources where version=2)").Scan(&physical, &queues, &sources); err != nil {
				t.Fatal(err)
			}
			expected := 0
			if persist {
				expected = 1
			}
			if physical != expected || queues != 0 || sources != 0 {
				t.Fatal("bad Worker registration left durable partial publication", physical, queues, sources)
			}
			if persist {
				if _, err := conn.Exec(ctx, "delete from todo.tesl_row_physical where version=2"); err != nil {
					t.Fatal(err)
				}
			}
		}
	}
	if expanded, err := teslrt.TeslTestRowQueueCatalogExpand(ctx, worker, DDatabase, roles); err != nil || expanded.Current != 2 {
		t.Fatal("original V2 source/physical queue publication", expanded, err)
	}
	cfg.User = roles.Request
	request, err := pgx.ConnectConfig(ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = request.Close(context.Background()) }()
	var retained string
	if err := request.QueryRow(ctx, "select job_id from todo.tesl_queue_claim(2,'Notifications','pending','new-worker',30000)").Scan(&retained); err != nil || retained != "retained-v1" {
		t.Fatalf("new SQL worker lost original payload: %s %v", retained, err)
	}
	rowQueueSQLLifecycle(t, ctx, request, 2, "current-v2")
	rowQueueSQLRefusals(t, ctx, conn, request, 2)
	rowQueueRetirementRefuses(t, ctx, conn, worker, roles, 2)
	rowQueueAdmissionAfterFence(t, ctx, conn, request)
	var count int
	if err := conn.QueryRow(ctx, "select count(*) from todo.tesl_row_queue_sources r join todo.tesl_queue_versions q on q.version=r.version and q.inventory_hash=r.inventory_hash join todo.tesl_row_physical p on p.version=r.version and p.contract_hash=r.expansion_hash where r.version=2 and q.storage_snapshot_hash<>r.expansion_hash").Scan(&count); err != nil || count != 1 {
		t.Fatal("V2 source storage was not independently bound", count, err)
	}
	var seal string
	if err := conn.QueryRow(ctx, "select source_seal_inventory from todo.tesl_queue_versions where version=1").Scan(&seal); err != nil || seal != "unrecorded" {
		t.Fatal("original V1 provenance was overwritten", seal, err)
	}
	fmt.Println("original V2 validated V1 source binding and preserved unrecorded creator provenance")
}

// SQL-only prerequisite: the generated app still refuses ordinary startup.
func rowQueueSQLLifecycle(t *testing.T, ctx context.Context, request *pgx.Conn, version int, id string) {
	t.Helper()
	var inserted, claimed, token string
	var source int
	var sequence int64
	if err := request.QueryRow(ctx, "select todo.tesl_queue_enqueue($1,'Notifications','Notify',$2,'{\"text\":\"queue 雪\"}'::jsonb)", version, id).Scan(&inserted); err != nil || inserted != id {
		t.Fatalf("enqueue: %s %v", inserted, err)
	}
	if err := request.QueryRow(ctx, "select job_id,source_version,token,attempt_seq from todo.tesl_queue_claim($1,'Notifications','pending','sql-worker',30000)", version).Scan(&claimed, &source, &token, &sequence); err != nil || claimed != id || source != version {
		t.Fatalf("claim: %s V%d %v", claimed, source, err)
	}
	var done bool
	if err := request.QueryRow(ctx, "select todo.tesl_queue_complete($1,'Notifications',$2,$3,$4)", version, id, token, sequence).Scan(&done); err != nil || !done {
		t.Fatalf("complete: %t %v", done, err)
	}
	if err := request.QueryRow(ctx, "select todo.tesl_queue_complete($1,'Notifications',$2,$3,$4)", version, id, token, sequence).Scan(&done); err != nil || done {
		t.Fatalf("duplicate complete: %t %v", done, err)
	}
}

func rowQueueSQLRefusals(t *testing.T, ctx context.Context, admin, request *pgx.Conn, version int) {
	t.Helper()
	for _, tc := range []struct{ name, change, want string }{
		{"inventory", "update todo.tesl_queue_versions set inventory_hash=repeat('a',64) where version=$1", "row expansion requires its exact complete queue source inventory"},
		{"source binding", "update todo.tesl_row_queue_sources set source_binding=convert_to('wrong','UTF8'),source_binding_hash=encode(sha256(convert_to('wrong','UTF8')),'hex') where version=$1", "row queue canonical source binding differs"},
		{"expansion receipt", "update todo.tesl_schema_versions set snapshot_hash=repeat('b',64) where version=$1 and step='expanded'", "row queue has no exact completed expansion receipt"},
	} {
		t.Run(fmt.Sprintf("V%d SQL %s", version, tc.name), func(t *testing.T) {
			// Preserve the exact authentic row, then restore it in one SQL statement.
			table := "tesl_queue_versions"
			if tc.name == "source binding" {
				table = "tesl_row_queue_sources"
			}
			if tc.name == "expansion receipt" {
				table = "tesl_schema_versions"
			}
			where := "version=$1"
			if table == "tesl_schema_versions" {
				where += " and step='expanded'"
			}
			var original string
			if err := admin.QueryRow(ctx, "select to_jsonb(r)::text from todo."+table+" r where "+where, version).Scan(&original); err != nil {
				t.Fatal(err)
			}
			if _, err := admin.Exec(ctx, tc.change, version); err != nil {
				t.Fatal(err)
			}
			defer func() {
				var restore string
				switch tc.name {
				case "inventory":
					restore = "inventory_hash=r.inventory_hash"
				case "source binding":
					restore = "source_binding=r.source_binding,source_binding_hash=r.source_binding_hash"
				case "expansion receipt":
					restore = "snapshot_hash=r.snapshot_hash"
				}
				if _, err := admin.Exec(ctx, "update todo."+table+" target set "+restore+" from jsonb_populate_record(null::todo."+table+",$2::jsonb) r where target.version=$1"+func() string {
					if table == "tesl_schema_versions" {
						return " and target.step='expanded'"
					}
					return ""
				}(), version, original); err != nil {
					t.Fatal(err)
				}
			}()
			var before, after string
			snapshot := func(out *string) {
				if err := admin.QueryRow(ctx, "select coalesce(jsonb_agg(to_jsonb(j) order by id),'[]'::jsonb)::text from todo.tesl_jobs j").Scan(out); err != nil {
					t.Fatal(err)
				}
			}
			snapshot(&before)
			for _, sql := range []string{"select todo.tesl_queue_enqueue($1,'Notifications','Notify','must-refuse','{}'::jsonb)", "select * from todo.tesl_queue_claim($1,'Notifications','pending','must-refuse',30000)"} {
				if _, err := request.Exec(ctx, sql, version); err == nil || !strings.Contains(err.Error(), tc.want) {
					t.Fatalf("wrong admission refusal: %v", err)
				}
			}
			snapshot(&after)
			if before != after {
				t.Fatal("refused admission changed jobs")
			}
		})
	}
}

func rowQueueRetirementRefuses(t *testing.T, ctx context.Context, observer, worker *pgx.Conn, roles teslrt.PgMigrationControlRoles, version int) {
	t.Helper()
	snapshot := func() string {
		var s string
		if err := observer.QueryRow(ctx, `select jsonb_build_object(
 'state',(select jsonb_agg(to_jsonb(r)) from todo.tesl_schema_state r),
 'history',(select jsonb_agg(to_jsonb(r) order by version,step,seq) from todo.tesl_schema_versions r),
 'epochs',(select jsonb_agg(to_jsonb(r)) from todo.tesl_row_epochs r),
 'contracts',(select jsonb_agg(to_jsonb(r)) from todo.tesl_row_contracts r),
 'jobs',(select jsonb_agg(to_jsonb(r) order by id) from todo.tesl_jobs r))::text`).Scan(&s); err != nil {
			t.Fatal(err)
		}
		return s
	}
	before := snapshot()
	for _, forced := range []string{"false", "true"} {
		if _, err := worker.Exec(ctx, "select todo.tesl_close_row_epoch(null,null,null,null,null,null,null,null,"+forced+")"); err == nil || !strings.Contains(err.Error(), "invalid additive epoch retirement") {
			t.Fatalf("malformed queue epoch accepted: %v", err)
		}
	}
	for _, sql := range []string{
		"select todo.tesl_retire_row_window(null,null,null,null,null,null)",
		"select todo.tesl_begin_row_contract(null,null)",
		"select todo.tesl_register_row_contract(null,null,null,null,null,null,null,null,null,null)",
	} {
		if _, err := worker.Exec(ctx, sql); err == nil || !strings.Contains(err.Error(), "invalid queue-bearing row Contract target") {
			t.Fatalf("V%d queue retirement guard: %v", version, err)
		}
	}
	err := teslrt.TeslTestRowQueueRetirementGuard(ctx, worker)
	if version == 1 {
		if err == nil || !strings.Contains(err.Error(), "row Contract requires identical queue membership and payload contracts") {
			t.Fatalf("V1 has no adjacent row retirement target: %v", err)
		}
	} else if err != nil {
		t.Fatalf("unchanged queue contracts must permit checked row retirement: %v", err)
	}
	if version == 2 {
		for _, force := range []bool{false, true} {
			if err := teslrt.TeslTestRowQueueEpochGuard(ctx, worker, DDatabase, roles, force, true); err != nil {
				t.Fatalf("additive queue epoch preview force=%t: %v", force, err)
			}
		}
	}
	if after := snapshot(); before != after {
		t.Fatal("queue retirement refusal changed durable state")
	}
}

// The owner injection calibrates admission's post-wait snapshot independently
// of the additive queue-epoch application lifecycle.
func rowQueueAdmissionAfterFence(t *testing.T, ctx context.Context, admin, request *pgx.Conn) {
	t.Helper()
	tx, err := admin.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(context.Background()) }()
	var fence int
	if err := tx.QueryRow(ctx, "select fence_ns from todo.tesl_schema_meta where id=1").Scan(&fence); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(ctx, "select pg_advisory_xact_lock($1,1)", fence); err != nil {
		t.Fatal(err)
	}
	waiting, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	result := make(chan error, 1)
	go func() {
		_, err := request.Exec(waiting, "select todo.tesl_queue_admit(1,'Notifications')")
		result <- err
	}()
	observed := false
	for waiting.Err() == nil {
		var blocked bool
		if err := tx.QueryRow(ctx, "select exists(select 1 from pg_locks where pid=$1 and locktype='advisory' and not granted)", request.PgConn().PID()).Scan(&blocked); err != nil {
			t.Fatal(err)
		}
		if blocked {
			observed = true
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if !observed {
		t.Fatal("queue admission did not wait on version fence")
	}
	if _, err := tx.Exec(ctx, "update todo.tesl_schema_state set min_version=2 where id=1"); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if _, err := admin.Exec(ctx, "update todo.tesl_schema_state set min_version=1 where id=1"); err != nil {
			t.Fatal(err)
		}
	}()
	if err := <-result; err == nil || !strings.Contains(err.Error(), "schema version 1 is retired") {
		t.Fatalf("admission reused pre-wait snapshot: %v", err)
	}
}

func rowQueueSQLReclaim(t *testing.T, ctx context.Context, request *pgx.Conn) {
	t.Helper()
	if _, err := request.Exec(ctx, "select todo.tesl_queue_enqueue(1,'Notifications','Notify','reclaim','{}'::jsonb)"); err != nil {
		t.Fatal(err)
	}
	var first, second string
	var firstSeq, secondSeq int64
	if err := request.QueryRow(ctx, "select token,attempt_seq from todo.tesl_queue_claim(1,'Notifications','pending','old',1)").Scan(&first, &firstSeq); err != nil {
		t.Fatal(err)
	}
	time.Sleep(10 * time.Millisecond)
	if err := request.QueryRow(ctx, "select token,attempt_seq from todo.tesl_queue_claim(1,'Notifications','pending','new',30000)").Scan(&second, &secondSeq); err != nil || second == first || secondSeq <= firstSeq {
		t.Fatalf("reclaim did not rotate attempt: %v", err)
	}
	var owned bool
	if err := request.QueryRow(ctx, "select todo.tesl_queue_complete(1,'Notifications','reclaim',$1,$2)", first, firstSeq).Scan(&owned); err != nil || owned {
		t.Fatalf("stale attempt completed: %v", err)
	}
	if err := request.QueryRow(ctx, "select todo.tesl_queue_complete(1,'Notifications','reclaim',$1,$2)", second, secondSeq).Scan(&owned); err != nil || !owned {
		t.Fatalf("current attempt could not complete: %v", err)
	}
}
