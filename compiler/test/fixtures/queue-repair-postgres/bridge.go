package teslrt

// Test-only access to the unpublished executor. The source registry, payload
// contracts, SQL functions and mutation path are the actual runtime ones.
import (
	"context"
	"fmt"
	"os"
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
}

func OpenQueueConversionDBForTest(t *testing.T, digest string) *QueueConversionDBFixture {
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
	for _, objects := range []string{"tables", "sequences", "functions"} {
		if _, err := f.Installer.Exec(ctx, "alter default privileges for role "+quoteIdentifier(roles.Owner)+" grant all on "+objects+" to "+quoteIdentifier(roles.Worker)+","+quoteIdentifier(roles.Request)); err != nil {
			t.Fatal(err)
		}
	}
	f.Scope, err = pgInstallQueueConversionCandidate(ctx, f.Installer, "mail", roles, digest)
	if err != nil {
		t.Fatal(err)
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
	return f
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
	_, err := f.Request.Exec(f.Context, "select mail.tesl_queue_conversion_enqueue($1,1,$2,$3::jsonb,$4,$5)", f.Scope.identity, id, body, status, due.Format(time.RFC3339Nano))
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
func (f *QueueConversionDBFixture) Snapshot(t *testing.T, id string) string {
	t.Helper()
	var snapshot string
	err := f.Installer.QueryRow(f.Context, `select pg_catalog.jsonb_build_object('job',pg_catalog.to_jsonb(j),'receipts',coalesce((select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(r) order by r.attempt_seq) from mail.tesl_queue_conversion_receipts r where r.job_id=j.id),'[]'::jsonb),'attempt',(select pg_catalog.to_jsonb(a) from mail.tesl_queue_conversion_attempts a where a.job_id=j.id))::text from mail.tesl_jobs j where j.id=$1`, id).Scan(&snapshot)
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
	if _, err := tx.Exec(f.Context, "select * from mail.tesl_queue_conversion_begin($1,$2,$3,$4::jsonb)", f.Scope.identity, source.spec.digest, id, string(binding)); err != nil {
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
