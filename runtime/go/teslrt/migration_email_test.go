package teslrt

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

func pgEmailFixture(t *testing.T) (*pgControlTestFixture, *pgx.Conn, *Database, *pgOutboxBackend) {
	t.Helper()
	f, request := pgNewWorkerTest(t)
	var outbox *Outbox
	db := pgRowBaselineFixtureConfigured(t, f, nil, func(db *Database) { outbox = NewOutboxOn(db, SmtpSettings{}) })
	if _, err := InstallPgCompiledRowBaseline(f.ctx, f.installer, db, f.roles); err != nil {
		t.Fatal(err)
	}
	if _, err := ExecutePgCompiledRowBaseline(f.ctx, f.worker, db, f.roles); err != nil {
		t.Fatal(err)
	}
	return f, request, db, outbox.backend.(*pgOutboxBackend)
}

func TestPgEmailStorageClaimsRetryAndRestart(t *testing.T) {
	f, request, db, backend := pgEmailFixture(t)
	var abandoned EmailMessage
	WithDatabase(db, func() {
		for _, body := range []EmailBody{TextBody("hello"), HTMLBody(""), RichBody("plain", "<p>rich</p>")} {
			backend.send(EmailMessage{To: "recipient@example.test", Subject: "subject", Body: body})
		}
		messages := backend.messages()
		if len(messages) != 3 || messages[1].Body.Tag != EmailBodyHTML || messages[2].Body.Text != "plain" {
			t.Fatalf("envelope lost: %#v", messages)
		}
		claimed := backend.claimDue(1)
		if len(claimed) != 1 || claimed[0].claimToken == "" {
			t.Fatal("missing claim", claimed)
		}
		abandoned = claimed[0]
		if backend.messages()[0].claimToken != "" {
			t.Fatal("inspection leaked outcome capability")
		}
		if !backend.recordOutcome(claimed[0], errors.New("SMTP temporarily unavailable")) {
			t.Fatal("retry was not recorded")
		}
		if backend.recordOutcome(claimed[0], nil) {
			t.Fatal("old token completed after retry")
		}
		retry := backend.messages()[0]
		if retry.Attempts != 1 || retry.Status != EmailPending || time.Until(retry.NextAttemptAt) < emailRetryDelay(1)-time.Minute {
			t.Fatal("retry policy changed", retry)
		}
	})
	tx, err := request.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(f.ctx, `select notes_app.tesl_email_enqueue(1,'rollback','subject','text','','')`); err != nil {
		t.Fatal(err)
	}
	if err := tx.Rollback(f.ctx); err != nil {
		t.Fatal(err)
	}
	WithDatabase(db, func() { abandoned = backend.claimDue(1)[0] })
	rows, err := request.Query(f.ctx, `select * from notes_app.tesl_email_claim(1,10)`)
	if err != nil {
		t.Fatal(err)
	}
	others, err := pgx.CollectRows(rows, scanOutboxRow)
	if err != nil || len(others) != 1 || others[0].id == abandoned.id {
		t.Fatal("claim isolation", others, err)
	}
	// Simulate elapsed time after process death without waiting ten minutes.
	if _, err := f.installer.Exec(f.ctx, `update notes_app.tesl_email_messages set locked_at=clock_timestamp()-interval '11 minutes' where id=$1`, int64(abandoned.id)); err != nil {
		t.Fatal(err)
	}
	WithDatabase(db, func() {
		reclaimed := backend.claimDue(1)
		if len(reclaimed) != 1 || reclaimed[0].id != abandoned.id || reclaimed[0].claimToken == abandoned.claimToken {
			t.Fatal("restart did not replace claim", reclaimed)
		}
		if backend.recordOutcome(abandoned, nil) {
			t.Fatal("stale SMTP result overwrote restarted claim")
		}
		if !backend.recordOutcome(reclaimed[0], nil) {
			t.Fatal("new claim could not complete")
		}
		if len(backend.messages()) != 3 {
			t.Fatal("rollback or restart changed retained message count")
		}
	})
	if _, err := InstallPgCompiledRowBaseline(f.ctx, f.installer, db, f.roles); err != nil {
		t.Fatal(err)
	}
	if _, err := ExecutePgCompiledRowBaseline(f.ctx, f.worker, db, f.roles); err != nil {
		t.Fatal(err)
	}
}

func TestPgEmailProtectedPermissionsAndCatalog(t *testing.T) {
	f, request, _, _ := pgEmailFixture(t)
	for _, sql := range []string{
		`insert into notes_app.tesl_email_messages(id,status) values(90,'sent')`,
		`update notes_app.tesl_email_messages set claim_token='forged'`,
		`delete from notes_app.tesl_email_messages`,
		`select claim_token from notes_app.tesl_email_messages`,
		`update notes_app.tesl_email_runtime set envelope='forged'`,
		`create table notes_app.tesl_email_outbox(id bigint)`,
	} {
		if _, err := request.Exec(f.ctx, sql); err == nil {
			t.Fatal("request obtained direct storage authority", sql)
		}
	}
	if _, err := f.worker.Exec(f.ctx, `select notes_app.tesl_email_claim(1,1)`); err == nil {
		t.Fatal("schema Worker became email dispatcher")
	}
	var changed bool
	if err := request.QueryRow(f.ctx, `select notes_app.tesl_email_outcome(1,1,'forged',true)`).Scan(&changed); err != nil || changed {
		t.Fatal("forged outcome", changed, err)
	}
	for _, mutation := range []string{
		`grant update on notes_app.tesl_email_messages to ` + quoteIdentifier(f.roles.Request),
		`alter table notes_app.tesl_email_messages add column unexpected text`,
		`update notes_app.tesl_email_runtime set envelope='tesl-email-envelope-v2'`,
		`grant execute on function notes_app.tesl_email_claim(integer,integer) to ` + quoteIdentifier(f.roles.Worker),
		`create function notes_app.tesl_email_claim() returns integer language sql as 'select 0'`,
		`drop table notes_app.tesl_email_runtime`,
		`grant pg_read_all_data to ` + quoteIdentifier(f.roles.Request),
		`grant ` + quoteIdentifier(f.roles.Request) + ` to ` + quoteIdentifier(f.roles.Worker),
	} {
		tx, err := f.installer.Begin(f.ctx)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := tx.Exec(f.ctx, mutation); err != nil {
			t.Fatal(err)
		}
		if _, err := pgVerifyEmail(f.ctx, tx, f.namespace, f.roles, false); err == nil {
			t.Fatal("catalog drift accepted", mutation)
		}
		if err := tx.Rollback(f.ctx); err != nil {
			t.Fatal(err)
		}
	}
}

func TestPgEmailOptionalRolloutAndRetainedEnvelope(t *testing.T) {
	f, _ := pgNewWorkerTest(t)
	db := pgRowBaselineFixture(t, f)
	if _, err := InstallPgCompiledRowBaseline(f.ctx, f.installer, db, f.roles); err != nil {
		t.Fatal(err)
	}
	if _, err := ExecutePgCompiledRowBaseline(f.ctx, f.worker, db, f.roles); err != nil {
		t.Fatal(err)
	}
	tx, err := f.installer.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	if err := pgInstallEmail(f.ctx, tx, f.namespace, f.roles); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(f.ctx); err != nil {
		t.Fatal(err)
	}
	// Removing the declaration does not remove retained storage.
	if _, err := InstallPgCompiledRowBaseline(f.ctx, f.installer, db, f.roles); err != nil {
		t.Fatal(err)
	}
	rows, err := f.installer.Query(f.ctx, `select 7::bigint,'old@example.test'::text,'old'::text,'html'::text,null::text,''::text,'pending'::text,2::integer,now(),null::timestamptz,'old-token'::text
 union all select 8,'plain@example.test','plain',null,'old body',null,'sent',0,now(),now(),null`)
	if err != nil {
		t.Fatal(err)
	}
	messages, err := pgx.CollectRows(rows, scanOutboxRow)
	if err != nil || len(messages) != 2 {
		t.Fatal(messages, err)
	}
	if messages[0].Body.Tag != EmailBodyHTML || messages[0].Body.HTML != "" || messages[0].Attempts != 2 || messages[0].claimToken != "old-token" || messages[1].Body.Text != "old body" || messages[1].Status != EmailSent {
		t.Fatal("old runtime envelope changed", messages)
	}
}

func TestPgEmailRetryExhaustion(t *testing.T) {
	f, _, db, backend := pgEmailFixture(t)
	WithDatabase(db, func() {
		backend.send(EmailMessage{To: "retry@example.test", Subject: "retry", Body: TextBody("body")})
		for attempt := 1; attempt <= emailMaxAttempts; attempt++ {
			claims := backend.claimDue(1)
			if len(claims) != 1 {
				t.Fatal("due retry was not claimable", attempt, claims)
			}
			claims[0].Attempts = 1000
			if !backend.recordOutcome(claims[0], errors.New("SMTP rejected")) {
				t.Fatal("retry failed", attempt)
			}
			message := backend.messages()[0]
			if message.Attempts != attempt {
				t.Fatal("client forged attempts", message)
			}
			if attempt < emailMaxAttempts {
				if message.Status != EmailPending || time.Until(message.NextAttemptAt) < emailRetryDelay(attempt)-time.Minute || time.Until(message.NextAttemptAt) > emailRetryDelay(attempt)+time.Minute {
					t.Fatal("durable retry differs from SMTP policy", message)
				}
				if len(backend.claimDue(1)) != 0 {
					t.Fatal("backoff was bypassed")
				}
				if _, err := f.installer.Exec(f.ctx, `update notes_app.tesl_email_messages set next_attempt_at=clock_timestamp()-interval '1 second'`); err != nil {
					t.Fatal(err)
				}
			} else if message.Status != EmailDead || len(backend.claimDue(1)) != 0 {
				t.Fatal("exhausted mail was not retained dead", message)
			}
		}
		backend.prune(0)
		if len(backend.messages()) != 1 {
			t.Fatal("pruning deleted dead mail")
		}
	})
}

func TestPgEmailAdmissionReadsStateAfterFenceWait(t *testing.T) {
	f, request, _, _ := pgEmailFixture(t)
	ctx, cancel := context.WithTimeout(f.ctx, 10*time.Second)
	defer cancel()
	tx, err := f.installer.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = tx.Rollback(f.ctx) }()
	if _, err := tx.Exec(ctx, `select pg_advisory_xact_lock(fence_ns,1) from notes_app.tesl_schema_meta where id=1`); err != nil {
		t.Fatal(err)
	}
	finished := make(chan error, 1)
	go func() {
		_, err := request.Exec(ctx, `select notes_app.tesl_email_enqueue(1,'old@example.test','old','text','','')`)
		finished <- err
	}()
	for {
		var waiting bool
		if err := tx.QueryRow(ctx, `select exists(select 1 from pg_catalog.pg_locks where pid=$1 and locktype='advisory' and not granted)`, request.PgConn().PID()).Scan(&waiting); err != nil {
			t.Fatal(err)
		}
		if waiting {
			break
		}
		select {
		case err := <-finished:
			t.Fatal("email did not wait for retirement fence", err)
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		case <-time.After(10 * time.Millisecond):
		}
	}
	if _, err := tx.Exec(ctx, `update notes_app.tesl_schema_state set current=2,min_version=2,compat_floor=2 where id=1`); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(ctx); err != nil {
		t.Fatal(err)
	}
	if err := <-finished; err == nil {
		t.Fatal("retired request enqueued after fence wait")
	}
	var count int
	if err := f.installer.QueryRow(ctx, `select count(*) from notes_app.tesl_email_messages`).Scan(&count); err != nil || count != 0 {
		t.Fatal("retired request left mail", count, err)
	}
}
