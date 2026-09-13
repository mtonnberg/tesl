package teslrt

// This file is copied only into an emitted test project. It installs the private
// candidate using the compiler's registered history, and never creates a
// history literal, payload contract, codec, public opener, or Main bypass.
import (
	"context"
	"fmt"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type CompiledCandidateFixture struct {
	Context   context.Context
	Installer *pgx.Conn
	Request   *PostgresDB
	Database  *Database
}

func OpenCompiledCandidateForTest(t *testing.T, database *Database) *CompiledCandidateFixture {
	t.Helper()
	host := os.Getenv("TESL_TEST_POSTGRES_SHARED_HOST")
	if host == "" {
		if os.Getenv("TESL_MIGRATION_TEST_REQUIRE_POSTGRES") == "1" {
			t.Fatal("required PostgreSQL witness has no TESL_TEST_POSTGRES_SHARED_HOST")
		}
		t.Skip("set TESL_TEST_POSTGRES_SHARED_HOST for actual PostgreSQL candidate regression")
	}
	history, ok := database.CompiledMigrationHistory()
	if !ok {
		t.Fatal("the emitted database did not register its history")
	}
	inventory, err := history.QueueSourceInventory(1)
	if err != nil || len(inventory.Versions) != 1 || inventory.Versions[0].SourceSealInventory != "unrecorded" {
		t.Fatal("source registration was replaced or falsely claimed baseline authority", inventory, err)
	}
	config, err := pgx.ParseConfig("")
	if err != nil {
		t.Fatal(err)
	}
	config.Host = host
	if value := os.Getenv("TESL_TEST_POSTGRES_SHARED_PORT"); value != "" {
		port, err := strconv.ParseUint(value, 10, 16)
		if err != nil {
			t.Fatal(err)
		}
		config.Port = uint16(port)
	}
	if user := os.Getenv("TESL_TEST_POSTGRES_SHARED_USER"); user != "" {
		config.User = user
	}
	config.Database = os.Getenv("TESL_TEST_POSTGRES_SHARED_ADMIN_DATABASE")
	if config.Database == "" {
		config.Database = "postgres"
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	t.Cleanup(cancel)
	admin, err := pgx.ConnectConfig(ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	name := "emitted_" + strings.ReplaceAll(UUIDv7(), "-", "")
	roles := PgMigrationControlRoles{Owner: name + "_owner", Worker: name + "_worker", Request: name + "_request"}
	f := &CompiledCandidateFixture{Context: ctx, Database: database}
	var worker *pgx.Conn
	t.Cleanup(func() {
		clean, stop := context.WithTimeout(context.Background(), 10*time.Second)
		defer stop()
		pubsubFor(database).Close()
		if f.Request != nil {
			f.Request.pool.Close()
		}
		if worker != nil {
			_ = worker.Close(clean)
		}
		if f.Installer != nil {
			_ = f.Installer.Close(clean)
		}
		for _, statement := range []string{
			"drop database if exists " + quoteIdentifier(name) + " with (force)",
			"drop role if exists " + quoteIdentifier(roles.Request),
			"drop role if exists " + quoteIdentifier(roles.Worker),
			"drop role if exists " + quoteIdentifier(roles.Owner),
		} {
			if _, err := admin.Exec(clean, statement); err != nil {
				t.Error("candidate cleanup", err)
			}
		}
		_ = admin.Close(clean)
	})
	for _, statement := range []string{
		"create role " + quoteIdentifier(roles.Owner) + " nologin",
		"create role " + quoteIdentifier(roles.Worker) + " login",
		"create role " + quoteIdentifier(roles.Request) + " login",
		"create database " + quoteIdentifier(name),
		"grant create on database " + quoteIdentifier(name) + " to " + quoteIdentifier(roles.Owner),
		"revoke temporary on database " + quoteIdentifier(name) + " from public",
		"grant temporary on database " + quoteIdentifier(name) + " to " + quoteIdentifier(roles.Owner) + "," + quoteIdentifier(roles.Worker),
	} {
		if _, err := admin.Exec(ctx, statement); err != nil {
			t.Fatal(err)
		}
	}
	config.Database = name
	f.Installer, err = pgx.ConnectConfig(ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.Installer.Exec(ctx, "grant create on schema public to "+quoteIdentifier(roles.Owner)); err != nil {
		t.Fatal(err)
	}
	state, err := pgInstallQueueCandidate(ctx, f.Installer, history, roles)
	if err != nil {
		t.Fatal(err)
	}
	workerConfig := config.Copy()
	workerConfig.User = roles.Worker
	worker, err = pgx.ConnectConfig(ctx, workerConfig)
	if err != nil {
		t.Fatal(err)
	}
	plan, err := history.ExpansionPlan(1)
	if err != nil {
		t.Fatal(err)
	}
	if err := pgApplyExpansion(ctx, worker, plan, roles, 0, map[int]*pgExpansionIntent{}); err != nil {
		t.Fatal(err)
	}
	database.Config = PostgresConfig{Schema: history.Namespace, DBName: name, User: roles.Request, Host: config.Host, Port: int(config.Port),
		MigrationTopology: "Worker", ControlOwner: roles.Owner, WorkerRole: roles.Worker, RequestRole: roles.Request}
	// The source-only transaction is already exercised by App preflight tests.
	// It closes the actual emitted Queue pointers and codecs; production preflight
	// still refuses the candidate, as the separate generated Main assertion proves.
	pgMigrationRegistrations.Lock()
	pending, prepareErr := pgPrepareApplicationDatabases([]*Database{database})
	if prepareErr == nil {
		pending.closeRegistrations()
	}
	pgMigrationRegistrations.Unlock()
	if prepareErr != nil {
		t.Fatal(prepareErr)
	}
	poolConfig, err := pgxpool.ParseConfig("")
	if err != nil {
		t.Fatal(err)
	}
	poolConfig.ConnConfig = config.Copy()
	poolConfig.ConnConfig.User = roles.Request
	poolConfig.MaxConns = 4
	f.Request, err = pgOpenQueueCandidateRuntime(ctx, database, poolConfig, &pgMigrationAdmission{
		version: history.CurrentVersion, databaseUUID: state.DatabaseUUID, fenceNamespace: state.FenceNamespace, worker: roles.Request, roles: roles})
	if err != nil {
		t.Fatal(err)
	}
	var authority string
	if err := f.Installer.QueryRow(ctx, "select inventory_authority from "+pgx.Identifier{history.Namespace, "tesl_queue_baseline"}.Sanitize()).Scan(&authority); err != nil || authority != "complete" {
		t.Fatal("fresh installation failed to establish persisted baseline", authority, err)
	}
	return f
}

func (f *CompiledCandidateFixture) Bind(body func()) {
	f.Database.mutex.Lock()
	old := f.Database.open
	f.Database.open = f.Request
	f.Database.mutex.Unlock()
	prior := boundDatabase.Swap(f.Database)
	defer func() {
		boundDatabase.Store(prior)
		f.Database.mutex.Lock()
		f.Database.open = old
		f.Database.mutex.Unlock()
	}()
	body()
}
func (f *CompiledCandidateFixture) SQL(t *testing.T, query string, args ...any) {
	t.Helper()
	if _, err := f.Installer.Exec(f.Context, query, args...); err != nil {
		t.Fatal(err)
	}
}
func (f *CompiledCandidateFixture) Text(t *testing.T, query string, args ...any) string {
	t.Helper()
	var value string
	if err := f.Installer.QueryRow(f.Context, query, args...).Scan(&value); err != nil {
		t.Fatal(err)
	}
	return value
}
func (f *CompiledCandidateFixture) Number(t *testing.T, query string, args ...any) int {
	t.Helper()
	var value int
	if err := f.Installer.QueryRow(f.Context, query, args...).Scan(&value); err != nil {
		t.Fatal(err)
	}
	return value
}
func (f *CompiledCandidateFixture) CorruptPayloadForTest(t *testing.T, jobID string, json string) string {
	t.Helper()
	table := pgx.Identifier{f.Request.schema, "tesl_jobs"}.Sanitize()
	f.SQL(t, "update "+table+" set payload=$2::jsonb where id=$1", jobID, json)
	return f.Text(t, "select payload::text from "+table+" where id=$1", jobID)
}
func CandidatePanicForTest(body func()) (result string) {
	defer func() {
		if value := recover(); value != nil {
			result = fmt.Sprint(value)
		}
	}()
	body()
	return ""
}
