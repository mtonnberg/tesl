package teslrt

// Test-only access to the unpublished executor. The source registry, payload
// contracts, SQL functions and mutation path are the actual runtime ones.
import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

type QueueConversionDBResultForTest = pgQueueConversionStored
type QueueConversionBatchForTest = pgQueueConversionBatch
type QueueClaimForTest struct {
	ID, Payload, Token string
	Version, Attempts  int32
	Sequence           int64
}
type QueueConversionDBFixture struct {
	Context                           context.Context
	Installer, Worker, Other, Request *pgx.Conn
	Scope                             pgQueueConversionDB
	Config                            *pgx.ConnConfig
	roles                             PgMigrationControlRoles
	applicationEnv                    []string
}

func OpenQueueConversionDBForTest(t *testing.T, digest string) *QueueConversionDBFixture {
	return openQueueConversionDBForTest(t, digest, false)
}

func OpenApplicationQueueForTest(t *testing.T) *QueueConversionDBFixture {
	return openQueueConversionDBForTest(t, "", true)
}

func openQueueConversionDBForTest(t *testing.T, digest string, application bool) *QueueConversionDBFixture {
	t.Helper()
	dsn := os.Getenv("TESL_MIGRATION_TEST_DSN")
	if dsn == "" {
		if os.Getenv("TESL_MIGRATION_TEST_REQUIRE_POSTGRES") == "1" {
			t.Fatal("mandatory queue repair PostgreSQL witness has no DSN")
		}
		t.Skip("set TESL_MIGRATION_TEST_DSN for the PostgreSQL repair witness")
	}
	config, err := pgx.ParseConfig(dsn)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	t.Cleanup(cancel)
	admin, err := pgx.ConnectConfig(ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	name := "repair_" + strings.ReplaceAll(UUIDv7(), "-", "")
	roles := PgMigrationControlRoles{Owner: name + "_owner", Worker: name + "_worker", Request: name + "_request"}
	f := &QueueConversionDBFixture{Context: ctx, roles: roles}
	t.Cleanup(func() {
		clean, stop := context.WithTimeout(context.Background(), 10*time.Second)
		defer stop()
		for _, conn := range []*pgx.Conn{f.Request, f.Other, f.Worker, f.Installer} {
			if conn != nil {
				_ = conn.Close(clean)
			}
		}
		for _, stmt := range []string{"drop database if exists " + quoteIdentifier(name) + " with (force)",
			"drop role if exists " + quoteIdentifier(roles.Request), "drop role if exists " + quoteIdentifier(roles.Worker), "drop role if exists " + quoteIdentifier(roles.Owner)} {
			if _, err := admin.Exec(clean, stmt); err != nil {
				t.Error(err)
			}
		}
		_ = admin.Close(clean)
	})
	for _, stmt := range []string{
		"create role " + quoteIdentifier(roles.Owner) + " nologin",
		"create role " + quoteIdentifier(roles.Worker) + " login",
		"create role " + quoteIdentifier(roles.Request) + " login",
		"create database " + quoteIdentifier(name),
		"grant create on database " + quoteIdentifier(name) + " to " + quoteIdentifier(roles.Owner),
		"revoke temporary on database " + quoteIdentifier(name) + " from public",
		"grant temporary on database " + quoteIdentifier(name) + " to " + quoteIdentifier(roles.Owner) + "," + quoteIdentifier(roles.Worker),
	} {
		if _, err := admin.Exec(ctx, stmt); err != nil {
			t.Fatal(err)
		}
	}
	config.Database = name
	f.Installer, err = pgx.ConnectConfig(ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	// Operator defaults must not silently widen the candidate's role boundary.
	var defaultGrantObjects []string
	if !application {
		defaultGrantObjects = []string{"tables", "sequences", "functions"}
	}
	for _, objects := range defaultGrantObjects {
		if _, err := f.Installer.Exec(ctx, "alter default privileges for role "+quoteIdentifier(roles.Owner)+" grant all on "+objects+" to "+quoteIdentifier(roles.Worker)+","+quoteIdentifier(roles.Request)); err != nil {
			t.Fatal(err)
		}
	}
	if !application {
		f.Scope, err = pgInstallQueueConversionCandidate(ctx, f.Installer, "mail", roles, digest)
		if err != nil {
			t.Fatal(err)
		}
	}
	worker := config.Copy()
	worker.User = roles.Worker
	f.Config = worker
	f.Worker, err = pgx.ConnectConfig(ctx, worker)
	if err != nil {
		t.Fatal(err)
	}
	f.Other, err = pgx.ConnectConfig(ctx, worker)
	if err != nil {
		t.Fatal(err)
	}
	request := config.Copy()
	request.User = roles.Request
	f.Request, err = pgx.ConnectConfig(ctx, request)
	if err != nil {
		t.Fatal(err)
	}
	// All execution witnesses start from a Worker-verified handle, not the
	// privileged installer's return value.
	if application {
		if _, err := f.Installer.Exec(ctx, "grant create on schema public to "+quoteIdentifier(roles.Owner)); err != nil {
			t.Fatal(err)
		}
		dsn := url.URL{Scheme: "postgresql", User: url.User(config.User), Path: "/" + config.Database,
			RawQuery: url.Values{"host": {config.Host}, "port": {fmt.Sprint(config.Port)}, "sslmode": {"disable"}}.Encode()}
		base := append(os.Environ(), "Q_DB="+name, "Q_HOST="+config.Host, "Q_PORT="+fmt.Sprint(config.Port),
			"Q_OWNER="+roles.Owner, "Q_WORKER="+roles.Worker, "Q_REQUEST="+roles.Request, "Q_DDL="+dsn.String())
		f.applicationEnv = base
		binary := os.Getenv("QUEUE_REPAIR_V1_APP")
		if binary == "" {
			t.Fatal("compiled V1 application is missing")
		}
		install := exec.CommandContext(ctx, binary, "--schema", "install", "--worker", roles.Worker, "--request", roles.Request, "--json")
		install.Env = append(append([]string{}, base...), "Q_USER="+config.User)
		if output, err := install.CombinedOutput(); err != nil {
			t.Fatalf("ordinary V1 install: %v\n%s", err, output)
		}
		log, err := os.CreateTemp(t.TempDir(), "application-worker-")
		if err != nil {
			t.Fatal(err)
		}
		process := exec.CommandContext(ctx, binary, "--schema", "worker", "--json")
		dsn.User = url.User(roles.Worker)
		process.Env = append(append([]string{}, base...), "Q_USER="+roles.Worker, "Q_DDL="+dsn.String())
		process.Stdout = log
		process.Stderr = log
		if err := process.Start(); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = process.Process.Kill(); _ = process.Wait(); _ = log.Close() })
		deadline := time.Now().Add(30 * time.Second)
		for {
			output, err := os.ReadFile(log.Name())
			if err != nil {
				t.Fatal(err)
			}
			if strings.Contains(string(output), "schema-worker-ready") {
				break
			}
			if time.Now().After(deadline) {
				t.Fatalf("V1 worker did not expand baseline: %s", output)
			}
			time.Sleep(20 * time.Millisecond)
		}
	} else if err := f.Reopen(f.Worker, digest); err != nil {
		t.Fatal(err)
	}
	return f
}

func (f *QueueConversionDBFixture) StageApplication(conn *pgx.Conn, digest string) error {
	return pgStageRowQueueConversions(f.Context, conn, "mail", f.roles, digest)
}

func (f *QueueConversionDBFixture) StageApplicationRoot(conn *pgx.Conn, c pgQueueConversionExecutable) error {
	return f.StageApplication(conn, c.queueConversionSource().spec.digest)
}

func (f *QueueConversionDBFixture) StageApplicationTarget(conn *pgx.Conn) error {
	plan, err := pgParseRowPhysicalPlan(testQueueTargetDocument, testQueueTargetHash)
	if err != nil {
		return err
	}
	if pgRowEpochPreserving(plan) {
		return fmt.Errorf("queue transformation incorrectly preserved the additive epoch")
	}
	return pgStageRowQueueTarget(f.Context, conn, "mail", f.roles, testQueueTargetDocument, testQueueTargetHash)
}

func (f *QueueConversionDBFixture) PrepareApplicationTarget(conn *pgx.Conn, mutation string) error {
	var target PgQueueSourceVersion
	if err := json.Unmarshal([]byte(testQueueTargetInventory), &target); err != nil {
		return err
	}
	switch mutation {
	case "":
	case "schema":
		target.SchemaSnapshotHash = strings.Repeat("0", 64)
	case "missing":
		target.Contracts = []PgQueueSourceContract{}
	case "unchanged":
		compiledQueueConversionSources.RLock()
		for _, s := range compiledQueueConversionSources.byDigest {
			if s.repairRevision == 0 {
				c := pgQueueConversionPayloadContract(s, false)
				target.Contracts[0].Payloads[0].Contract = hex.EncodeToString(c)
				target.Contracts[0].Payloads[0].ContractHash = fmt.Sprintf("%x", sha256.Sum256(c))
			}
		}
		compiledQueueConversionSources.RUnlock()
	case "additional":
		target.Contracts[0].Payloads = append(target.Contracts[0].Payloads, PgQueueSourcePayload{Job: "Other", Contract: target.Contracts[0].Payloads[0].Contract, ContractHash: target.Contracts[0].Payloads[0].ContractHash})
	default:
		return fmt.Errorf("unknown successor mutation")
	}
	return pgPrepareRowQueueTarget(f.Context, conn, "mail", f.roles, target, testQueueTargetDocument, testQueueTargetHash)
}

func (f *QueueConversionDBFixture) ApplicationStatus(t *testing.T) {
	t.Helper()
	command := exec.CommandContext(f.Context, os.Getenv("QUEUE_REPAIR_V1_APP"), "--schema", "status", "--json")
	command.Env = append(append([]string{}, f.applicationEnv...), "Q_USER="+f.roles.Request)
	if output, err := command.CombinedOutput(); err != nil {
		t.Fatalf("ordinary V1 status refused prepared successor: %v\n%s", err, output)
	}
}

func (f *QueueConversionDBFixture) PublishApplicationTarget() error {
	var target PgQueueSourceVersion
	if err := json.Unmarshal([]byte(testQueueTargetInventory), &target); err != nil {
		return err
	}
	return pgPublishRowQueueTarget(f.Context, f.Worker, "mail", f.roles, target, testQueueTargetDocument, testQueueTargetHash)
}

func (f *QueueConversionDBFixture) OpenApplicationDispatch(conn *pgx.Conn, digest string) error {
	scope, err := pgOpenRowQueueConversion(f.Context, conn, "mail", f.roles, digest)
	if err == nil {
		f.Scope = scope
	}
	return err
}

func (f *QueueConversionDBFixture) OpenApplicationRoot(conn *pgx.Conn, c pgQueueConversionExecutable) error {
	return f.OpenApplicationDispatch(conn, c.queueConversionSource().spec.digest)
}

func (f *QueueConversionDBFixture) ApplicationTurn(conn *pgx.Conn, limit int) (pgQueueConversionBatch, error) {
	return pgRunRowQueueConversionTurn(f.Context, conn, "mail", f.roles, limit)
}

func (f *QueueConversionDBFixture) RetireApplication(conn *pgx.Conn) (bool, error) {
	return pgRetireRowQueue(f.Context, conn, "mail", f.roles)
}

func (f *QueueConversionDBFixture) ApplicationTurnWithoutCode(c pgQueueConversionExecutable) (pgQueueConversionBatch, error) {
	digest := c.queueConversionSource().spec.digest
	compiledQueueConversionExecutables.Lock()
	saved := compiledQueueConversionExecutables.byDigest[digest]
	delete(compiledQueueConversionExecutables.byDigest, digest)
	compiledQueueConversionExecutables.Unlock()
	defer func() {
		compiledQueueConversionExecutables.Lock()
		compiledQueueConversionExecutables.byDigest[digest] = saved
		compiledQueueConversionExecutables.Unlock()
	}()
	return f.ApplicationTurn(f.Worker, 1)
}

func (f *QueueConversionDBFixture) MutateApplicationTarget(t *testing.T, kind string) error {
	t.Helper()
	doc, _, err := pgReadRowCanonical(testQueueTargetDocument)
	if err != nil {
		t.Fatal(err)
	}
	n := &doc.children[3]
	switch kind {
	case "schema":
		n.children[4] = pgRowAtom(strings.Repeat("0", 64))
	case "storage":
		n.children[5] = pgRowAtom(strings.Repeat("0", 64))
	case "namespace":
		n.children[2] = pgRowAtom("foreign")
	case "callback":
		n.children[8].children[0].children[2] = pgRowAtom(strings.Repeat("0", 64))
	case "missing":
		n.children[8] = pgRowList()
	case "duplicate":
		n.children[8].children = append(n.children[8].children, n.children[8].children[0])
	case "reverse":
		n.children[8].children[0].children[3], n.children[8].children[0].children[4] = n.children[8].children[0].children[4], n.children[8].children[0].children[3]
	default:
		t.Fatal("unknown target mutation")
	}
	raw, hash := pgRowBaselineDocument(*n)
	return pgStageRowQueueTarget(f.Context, f.Installer, "mail", f.roles, hex.EncodeToString([]byte(raw)), hash)
}

func (f *QueueConversionDBFixture) Apply(conn *pgx.Conn, c pgQueueConversionExecutable, id string) (pgQueueConversionStored, error) {
	return pgApplyQueueConversionCandidate(f.Context, conn, f.Scope, c, id)
}

func (f *QueueConversionDBFixture) Batch(ctx context.Context, conn *pgx.Conn, c pgQueueConversionExecutable, limit int) (pgQueueConversionBatch, error) {
	return pgRunQueueConversionCandidateBatch(ctx, conn, f.Scope, c, limit)
}

func (f *QueueConversionDBFixture) SelectWork(tx pgx.Tx, c pgQueueConversionExecutable, after int64) (string, int64, error) {
	return pgSelectQueueConversionCandidateTx(f.Context, tx, f.Scope, c.queueConversionSource(), after)
}

func OpenQueueConversionRootForTest(t *testing.T, c pgQueueConversionExecutable) *QueueConversionDBFixture {
	t.Helper()
	return OpenQueueConversionDBForTest(t, c.queueConversionSource().spec.digest)
}

func (f *QueueConversionDBFixture) Register(conn *pgx.Conn, c pgQueueConversionExecutable) error {
	return pgRegisterQueueRepairCandidate(f.Context, conn, f.Scope, f.roles, c.queueConversionSource().spec.digest)
}
func (f *QueueConversionDBFixture) ApplyTx(tx pgx.Tx, c pgQueueConversionExecutable, id string) (pgQueueConversionStored, error) {
	return pgApplyQueueConversionCandidateTx(f.Context, tx, f.Scope, c, id)
}
func (f *QueueConversionDBFixture) Enqueue(id, body, status string, due time.Time) error {
	return f.EnqueueAt(1, id, body, status, due)
}

func (f *QueueConversionDBFixture) EnqueueAt(version int, id, body, status string, due time.Time) error {
	_, err := f.Request.Exec(f.Context, "select mail.tesl_queue_conversion_enqueue($1,$2,$3,$4::jsonb,$5,$6)", f.Scope.identity, version, id, body, status, due.Format(time.RFC3339Nano))
	return err
}

func (f *QueueConversionDBFixture) UpgradeProcessEnvironment() []string {
	config := f.Installer.Config()
	dsn := url.URL{Scheme: "postgresql", User: url.User(config.User), Path: "/" + config.Database,
		RawQuery: url.Values{"host": {config.Host}, "port": {fmt.Sprint(config.Port)}, "sslmode": {"disable"}}.Encode()}
	return append(f.WorkerProcessEnvironment(), "TESL_QUEUE_UPGRADE_INSTALLER_DSN="+dsn.String(), "TESL_QUEUE_UPGRADE_IDENTITY="+f.Scope.identity)
}

func UpgradeQueueProcessForTest(t *testing.T, c pgQueueConversionExecutable) (*QueueConversionDBFixture, error) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	t.Cleanup(cancel)
	roles := PgMigrationControlRoles{Owner: os.Getenv("TESL_QUEUE_REPAIR_OWNER"), Worker: os.Getenv("TESL_QUEUE_REPAIR_WORKER"), Request: os.Getenv("TESL_QUEUE_REPAIR_REQUEST")}
	config, err := pgx.ParseConfig(os.Getenv("TESL_QUEUE_REPAIR_WORKER_DSN"))
	if err != nil {
		return nil, err
	}
	f := &QueueConversionDBFixture{Context: ctx, roles: roles, Config: config}
	t.Cleanup(func() {
		for _, conn := range []*pgx.Conn{f.Installer, f.Worker, f.Request} {
			if conn != nil {
				_ = conn.Close(context.Background())
			}
		}
	})
	f.Installer, err = pgx.Connect(ctx, os.Getenv("TESL_QUEUE_UPGRADE_INSTALLER_DSN"))
	if err != nil {
		return nil, err
	}
	f.Worker, err = pgx.ConnectConfig(ctx, config)
	if err != nil {
		return nil, err
	}
	request := config.Copy()
	request.User = roles.Request
	f.Request, err = pgx.ConnectConfig(ctx, request)
	if err != nil {
		return nil, err
	}
	f.Scope, err = pgUpgradeQueueConversionCandidate(ctx, f.Installer, "mail", roles, os.Getenv("TESL_QUEUE_UPGRADE_IDENTITY"), c.queueConversionSource().spec.digest)
	return f, err
}

func (f *QueueConversionDBFixture) ReplayUpgrade(c pgQueueConversionExecutable) error {
	scope, err := pgUpgradeQueueConversionCandidate(f.Context, f.Installer, "mail", f.roles, f.Scope.identity, c.queueConversionSource().spec.digest)
	if err == nil {
		f.Scope = scope
	}
	return err
}
func (f *QueueConversionDBFixture) Retire(conn *pgx.Conn) (bool, error) {
	var done bool
	err := conn.QueryRow(f.Context, "select mail.tesl_queue_conversion_retire($1)", f.Scope.identity).Scan(&done)
	return done, err
}
func (f *QueueConversionDBFixture) RetireTx(tx pgx.Tx) (bool, error) {
	var done bool
	err := tx.QueryRow(f.Context, "select mail.tesl_queue_conversion_retire($1)", f.Scope.identity).Scan(&done)
	return done, err
}
func (f *QueueConversionDBFixture) WrongDatabase(c pgQueueConversionExecutable, id string) error {
	bad := f.Scope
	bad.identity = UUIDv7()
	_, err := pgApplyQueueConversionCandidate(f.Context, f.Worker, bad, c, id)
	return err
}
func (f *QueueConversionDBFixture) StaleAttempt(t *testing.T, c pgQueueConversionExecutable, id string) {
	t.Helper()
	source := c.queueConversionSource()
	binding, err := pgQueueConversionCandidateBinding(source)
	if err != nil {
		t.Fatal(err)
	}
	tx, err := f.Worker.Begin(f.Context)
	if err != nil {
		t.Fatal(err)
	}
	var original, reason, xid, outcome string
	var seq int64
	err = tx.QueryRow(f.Context, "select * from mail.tesl_queue_conversion_begin($1,$2,$3,$4::jsonb)", f.Scope.identity, source.spec.digest, id, string(binding)).Scan(&original, &reason, &seq, &xid, &outcome)
	if err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(f.Context); err != nil {
		t.Fatal(err)
	} // Simulate a committed abandoned attempt.
	result, err := f.Apply(f.Other, c, id)
	if err != nil || result.Kind != "converted" {
		t.Fatal(result, err)
	}
	var applied bool
	err = f.Worker.QueryRow(f.Context, "select mail.tesl_queue_conversion_finish($1,$2,$3,$4,$5,$6,'converted',$7::jsonb,'')", f.Scope.identity, source.spec.digest, id, seq, xid, original, `{"message":"stale","priority":99}`).Scan(&applied)
	if err != nil || applied {
		t.Fatal("stale transaction published", applied, err)
	}
}
func (f *QueueConversionDBFixture) RestartWorker(t *testing.T) {
	t.Helper()
	_ = f.Worker.Close(f.Context)
	var err error
	f.Worker, err = pgx.ConnectConfig(f.Context, f.Config)
	if err != nil {
		t.Fatal(err)
	}
}

func (f *QueueConversionDBFixture) ForgetScope() { f.Scope = pgQueueConversionDB{} }

func (f *QueueConversionDBFixture) Reopen(conn *pgx.Conn, digest string) error {
	scope, err := pgOpenQueueConversionCandidate(f.Context, conn, "mail", f.roles, digest)
	if err == nil {
		f.Scope = scope
	}
	return err
}

func (f *QueueConversionDBFixture) RevokeTemporary(t *testing.T) {
	t.Helper()
	if _, err := f.Installer.Exec(f.Context, "revoke temporary on database "+quoteIdentifier(f.Config.Database)+" from "+quoteIdentifier(f.roles.Worker)); err != nil {
		t.Fatal(err)
	}
}

func (f *QueueConversionDBFixture) WorkerProcessEnvironment() []string {
	// ConnString retains pgx's original parsed input, even after Config.User and
	// Config.Database change. Serialize the actual Worker endpoint explicitly.
	dsn := url.URL{Scheme: "postgresql", User: url.User(f.Config.User), Path: "/" + f.Config.Database,
		RawQuery: url.Values{"host": {f.Config.Host}, "port": {fmt.Sprint(f.Config.Port)}, "sslmode": {"disable"}}.Encode()}
	return []string{"TESL_QUEUE_REPAIR_CHILD=1", "TESL_QUEUE_REPAIR_WORKER_DSN=" + dsn.String(),
		"TESL_QUEUE_REPAIR_OWNER=" + f.roles.Owner, "TESL_QUEUE_REPAIR_WORKER=" + f.roles.Worker, "TESL_QUEUE_REPAIR_REQUEST=" + f.roles.Request}
}

func ReopenQueueWorkerProcessForTest(t *testing.T, digest string) *QueueConversionDBFixture {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	t.Cleanup(cancel)
	conn, err := pgx.Connect(ctx, os.Getenv("TESL_QUEUE_REPAIR_WORKER_DSN"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close(context.Background()) })
	roles := PgMigrationControlRoles{Owner: os.Getenv("TESL_QUEUE_REPAIR_OWNER"), Worker: os.Getenv("TESL_QUEUE_REPAIR_WORKER"), Request: os.Getenv("TESL_QUEUE_REPAIR_REQUEST")}
	scope, err := pgOpenQueueConversionCandidate(ctx, conn, "mail", roles, digest)
	if err != nil {
		t.Fatal(err)
	}
	return &QueueConversionDBFixture{Context: ctx, Worker: conn, Scope: scope, roles: roles}
}

func (f *QueueConversionDBFixture) MutateCatalog(t *testing.T, kind string) {
	t.Helper()
	statements := map[string]string{
		"column":        "alter table mail.tesl_queue_conversion_scope add column extra integer",
		"relation":      "create table mail.unrecorded(id integer)",
		"function":      "create function mail.unrecorded() returns integer language sql as 'select 1'",
		"function-body": "create or replace function mail.tesl_queue_conversion_snapshot() returns jsonb language plpgsql stable security definer set search_path='' as 'begin raise exception ''snapshot must not execute''; end'",
		"cascade":       "alter table mail.tesl_queue_conversion_attempts drop constraint tesl_queue_conversion_attempts_job_id_fkey; alter table mail.tesl_queue_conversion_attempts add foreign key(job_id) references mail.tesl_jobs(id)",
		"trigger":       "alter table mail.tesl_jobs disable trigger all",
		"sequence":      "alter sequence mail.tesl_jobs_seq_seq cache 2",
		"check":         "alter table mail.tesl_queue_conversion_receipts drop constraint tesl_queue_conversion_receipts_kind_check",
		"column-grant":  "grant update(payload) on mail.tesl_jobs to " + quoteIdentifier(f.roles.Worker),
		"schema-grant":  "grant create on schema mail to " + quoteIdentifier(f.roles.Worker),
		"payload":       "update mail.tesl_queue_payloads set contract=pg_catalog.convert_to('other','UTF8'),contract_hash=pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to('other','UTF8')),'hex') where version=1",
		"source":        "update mail.tesl_queue_conversion_sources set document=pg_catalog.convert_to('other','UTF8'),digest=pg_catalog.encode(pg_catalog.sha256(pg_catalog.convert_to('other','UTF8')),'hex') where revision=2",
		"parent":        "update mail.tesl_queue_conversion_sources set parent_digest=(select digest from mail.tesl_queue_conversion_sources where revision=0) where revision=2",
		"database":      "update mail.tesl_queue_conversion_scope set database_oid=0",
		"floor":         "update mail.tesl_queue_conversion_scope set floor=to_version",
	}
	statement, ok := statements[kind]
	if !ok {
		t.Fatal("unknown catalog mutation")
	}
	if _, err := f.Installer.Exec(f.Context, statement); err != nil {
		t.Fatal(err)
	}
}
func (f *QueueConversionDBFixture) Snapshot(t *testing.T, id string) string {
	t.Helper()
	var snapshot string
	query := `select pg_catalog.jsonb_build_object('job',pg_catalog.to_jsonb(j),'receipts',coalesce((select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(r) order by r.attempt_seq) from mail.tesl_queue_conversion_receipts r where r.job_id=j.id),'[]'::jsonb),'attempt',(select pg_catalog.to_jsonb(a) from mail.tesl_queue_conversion_attempts a where a.job_id=j.id))::text from mail.tesl_jobs j where j.id=$1`
	if f.Scope.application {
		query = strings.ReplaceAll(query, "tesl_queue_conversion_", "tesl_row_queue_conversion_")
	}
	err := f.Installer.QueryRow(f.Context, query, id).Scan(&snapshot)
	if err != nil {
		t.Fatal(fmt.Errorf("snapshot %s: %w", id, err))
	}
	return snapshot
}

func (f *QueueConversionDBFixture) QueueClaim(conn *pgx.Conn, version int, wanted string, lease int64) (QueueClaimForTest, bool, error) {
	tx, err := conn.BeginTx(f.Context, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return QueueClaimForTest{}, false, err
	}
	defer pgQueueConversionCandidateRollback(tx)
	queue, err := pgQueueConversionCandidateQueueContext(f.Context, tx, f.Scope)
	if err != nil {
		return QueueClaimForTest{}, false, err
	}
	rows, err := tx.Query(f.Context, "select job_id,job_type,payload::text,source_version,attempts,token,attempt_seq from mail.tesl_queue_claim($1,$2,$3,$4,$5)", version, queue, wanted, "candidate-handler", lease)
	if err != nil {
		return QueueClaimForTest{}, false, err
	}
	claims, err := pgx.CollectRows(rows, pgScanQueueRuntimeClaim)
	if err != nil {
		return QueueClaimForTest{}, false, err
	}
	if err := tx.Commit(f.Context); err != nil {
		return QueueClaimForTest{}, false, err
	}
	if len(claims) == 0 {
		return QueueClaimForTest{}, false, nil
	}
	if len(claims) != 1 {
		return QueueClaimForTest{}, false, fmt.Errorf("multiple claims")
	}
	c := claims[0]
	return QueueClaimForTest{c.id, c.payload, c.token, c.version, c.attempts, c.sequence}, true, nil
}

func (f *QueueConversionDBFixture) QueueBoolean(conn *pgx.Conn, version int, operation string, rest ...any) (bool, error) {
	tx, err := conn.BeginTx(f.Context, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		return false, err
	}
	defer pgQueueConversionCandidateRollback(tx)
	queue, err := pgQueueConversionCandidateQueueContext(f.Context, tx, f.Scope)
	if err != nil {
		return false, err
	}
	args := append([]any{version, queue}, rest...)
	parameters := make([]string, len(args))
	for i := range args {
		parameters[i] = fmt.Sprintf("$%d", i+1)
	}
	var result bool
	err = tx.QueryRow(f.Context, "select mail."+quoteIdentifier("tesl_queue_"+operation)+"("+strings.Join(parameters, ",")+")", args...).Scan(&result)
	if err != nil {
		return false, err
	}
	if err := tx.Commit(f.Context); err != nil {
		return false, err
	}
	return result, nil
}

func (f *QueueConversionDBFixture) AbandonConversion(t *testing.T, c pgQueueConversionExecutable, id string) {
	t.Helper()
	source := c.queueConversionSource()
	binding, err := pgQueueConversionCandidateBinding(source)
	if err != nil {
		t.Fatal(err)
	}
	tx, err := f.Worker.Begin(f.Context)
	if err != nil {
		t.Fatal(err)
	}
	defer pgQueueConversionCandidateRollback(tx)
	if _, err := tx.Exec(f.Context, "select * from "+f.Scope.function("begin")+"($1,$2,$3,$4::jsonb)", f.Scope.identity, source.spec.digest, id, string(binding)); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(f.Context); err != nil {
		t.Fatal(err)
	}
}

func (f *QueueConversionDBFixture) ClaimTransactionOutlivesLease(t *testing.T, c pgQueueConversionExecutable, id string) {
	t.Helper()
	tx, err := f.Worker.BeginTx(f.Context, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		t.Fatal(err)
	}
	defer pgQueueConversionCandidateRollback(tx)
	queue, err := pgQueueConversionCandidateQueueContext(f.Context, tx, f.Scope)
	if err != nil {
		t.Fatal(err)
	}
	var claimed, token string
	var sequence int64
	err = tx.QueryRow(f.Context, "select job_id,token,attempt_seq from mail.tesl_queue_claim(1,$1,'pending','transaction-owner',1)", queue).Scan(&claimed, &token, &sequence)
	if err != nil || claimed != id {
		t.Fatal(claimed, err)
	}
	if _, err := tx.Exec(f.Context, "select pg_catalog.pg_sleep(0.02)"); err != nil {
		t.Fatal(err)
	}
	if result, err := f.Apply(f.Other, c, id); err != nil || result.Kind != "unavailable" {
		t.Fatal("another transaction stole an active claim", result, err)
	}
	savepoint, err := tx.Begin(f.Context)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := f.ApplyTx(savepoint, c, id); err == nil {
		t.Fatal("conversion revoked its own transaction's claim")
	}
	if err := savepoint.Rollback(f.Context); err != nil {
		t.Fatal(err)
	}
	var completed bool
	err = tx.QueryRow(f.Context, "select mail.tesl_queue_complete(1,$1,$2,$3,$4)", queue, id, token, sequence).Scan(&completed)
	if err != nil || !completed {
		t.Fatal("transaction-local completion right was lost", completed, err)
	}
	if err := tx.Commit(f.Context); err != nil {
		t.Fatal(err)
	}
}
