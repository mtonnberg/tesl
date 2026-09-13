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
	if err := teslrt.PreflightApplicationDatabases(DDatabase); err == nil || !strings.Contains(err.Error(), "does not yet support") {
		t.Fatal("installer closure activated queue App", err)
	}
	if _, err := request.Exec(ctx, "select todo.tesl_queue_admit(1,'Notifications')"); err == nil {
		t.Fatal("format4 queue dispatch admitted row5")
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
