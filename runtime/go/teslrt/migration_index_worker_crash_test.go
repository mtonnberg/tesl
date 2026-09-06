//go:build tesl_migration_test

package teslrt

import (
	"testing"
	"time"
)

func TestPgMigrationIndexWorkerValidCommitBeforeActorReturnDoesNotLoseLease(t *testing.T) {
	f, _ := pgNewWorkerTest(t)
	f.install(t, 1)
	pgExpandIndexTest(t, f, 1, true)
	state := pgExpandIndexTest(t, f, 2, true)
	arrived, resume := pgPauseExpansionBoundary(t, "index-after-valid", 1)
	service := pgStartIndexTestService(t, f, 2, true, state, pgIndexTestSettings())
	defer resume() // A failed assertion must not leave the actor at its test seam.
	select {
	case <-arrived:
	case <-service.done:
		t.Fatalf("worker exited: %v", service.err)
	case <-f.ctx.Done():
		t.Fatal(f.ctx.Err())
	}
	job := pgIndexControlTestJobs(t, f)[0]
	if job.State != "valid" || job.Holder == "" || job.ExpiresAt == nil {
		t.Fatalf("not paused after durable success: %+v", job)
	}
	pgIndexTestReady(t, f, service)
	// Wait on database time until even the final lease has expired. Several
	// renewal and snapshot ticks must tolerate the completed actor still owning
	// its transport and shared job lock; success is immutable, not lease loss.
	pgIndexTestAwait(t, f, service, "completed actor survives renewal ticks", func() bool {
		var expired bool
		if err := f.installer.QueryRow(f.ctx, "select clock_timestamp()>$1::timestamptz", job.ExpiresAt).Scan(&expired); err != nil {
			t.Fatal(err)
		}
		return expired
	})
	var alive int
	if err := f.installer.QueryRow(f.ctx, "select count(*) from pg_stat_activity where datname=current_database() and application_name=$1", job.Holder).Scan(&alive); err != nil || alive != 2 {
		t.Fatalf("successful generation was torn down by a renewal race: %d %v", alive, err)
	}
	if current := pgIndexControlTestJobs(t, f)[0]; current.Token != job.Token || current.Attempts != job.Attempts || current.Holder != job.Holder {
		t.Fatalf("successful job was reclaimed: %+v", current)
	}
	resume()
	pgIndexTestValid(t, f, service)
	pgIndexTestStop(t, service)
}

func TestPgMigrationIndexWorkerReobservesCommittedCreateAfterConnectionLoss(t *testing.T) {
	f, _ := pgNewWorkerTest(t)
	f.install(t, 1)
	pgExpandIndexTest(t, f, 1, true)
	state := pgExpandIndexTest(t, f, 2, true)
	arrived, resume := pgPauseExpansionBoundary(t, "index-after-create", 1)
	service := pgStartIndexTestService(t, f, 2, true, state, pgIndexTestSettings())
	defer resume()
	select {
	case <-arrived:
	case <-service.done:
		t.Fatalf("worker exited: %v", service.err)
	case <-f.ctx.Done():
		t.Fatal(f.ctx.Err())
	}
	var oid uint32
	if err := f.installer.QueryRow(f.ctx, "select 'notes_app.token__v2'::regclass::oid").Scan(&oid); err != nil {
		t.Fatal(err)
	}
	initial := pgIndexControlTestJobs(t, f)[0]
	if initial.State != "building" || initial.Attempts != 1 {
		t.Fatalf("create prematurely recorded completion: %+v", initial)
	}
	if _, err := f.installer.Exec(f.ctx, "select pg_terminate_backend($1)", service.pid); err != nil {
		t.Fatal(err)
	}
	resume()
	job := pgIndexTestValid(t, f, service)
	pgIndexTestReady(t, f, service)
	var after uint32
	if err := f.installer.QueryRow(f.ctx, "select 'notes_app.token__v2'::regclass::oid").Scan(&after); err != nil || oid != after {
		t.Fatalf("valid unknown result was dropped/rebuilt: %d %d %v", oid, after, err)
	}
	if job.Attempts != 1 || job.Token <= initial.Token {
		t.Fatalf("recovery did not independently fence and adopt the same valid result: %+v", job)
	}
	pgIndexTestStop(t, service)
}

func TestPgMigrationIndexWorkerReobservesValidResultBeforeInvalidCleanup(t *testing.T) {
	f, _ := pgNewWorkerTest(t)
	f.install(t, 1)
	pgExpandIndexTest(t, f, 1, true)
	state := pgExpandIndexTest(t, f, 2, true)
	f.call(t, "insert into notes_app.notes(id,active,token) values('a',true,'duplicate'),('b',false,'duplicate')")
	arrived, resume := pgPauseExpansionBoundary(t, "index-before-cleanup", 1)
	service := pgStartIndexTestService(t, f, 2, true, state, pgIndexTestSettings())
	defer resume()
	select {
	case <-arrived:
	case <-service.done:
		t.Fatalf("worker exited: %v", service.err)
	case <-f.ctx.Done():
		t.Fatal(f.ctx.Err())
	}
	failed := pgIndexControlTestJobs(t, f)[0]
	if failed.State != "failed" {
		t.Fatalf("not paused before failed-remnant cleanup: %+v", failed)
	}
	// An independently completed repair during a paused worker invalidates its
	// earlier INVALID observation. The second token/catalog barrier must see it.
	f.call(t, "update notes_app.notes set token='repaired' where id='b'")
	f.call(t, "drop index concurrently notes_app.token__v2")
	f.call(t, "create unique index concurrently token__v2 on notes_app.notes(token)")
	var oid uint32
	if err := f.installer.QueryRow(f.ctx, "select 'notes_app.token__v2'::regclass::oid").Scan(&oid); err != nil {
		t.Fatal(err)
	}
	resume()
	job := pgIndexTestValid(t, f, service)
	pgIndexTestReady(t, f, service)
	var after uint32
	if err := f.installer.QueryRow(f.ctx, "select 'notes_app.token__v2'::regclass::oid").Scan(&after); err != nil || oid != after {
		t.Fatalf("cleanup dropped a completed valid result: %d %d %v", oid, after, err)
	}
	if job.Attempts != 1 {
		t.Fatalf("paused cleanup rebuilt a successful index: %+v", job)
	}
	pgIndexTestStop(t, service)
}

func TestPgMigrationIndexWorkerLeaseRevocationStopsBeforeDDL(t *testing.T) {
	for _, boundary := range []string{"index-job-lock", "index-before-create"} {
		t.Run(boundary, func(t *testing.T) {
			pgTestIndexRevocationBeforeDDL(t, boundary)
		})
	}
}

func pgTestIndexRevocationBeforeDDL(t *testing.T, boundary string) {
	t.Helper()
	f, _ := pgNewWorkerTest(t)
	f.install(t, 1)
	pgExpandIndexTest(t, f, 1, false)
	state := pgExpandIndexTest(t, f, 2, false)
	pauses := pgPauseExpansionBoundaries(t, []pgExpansionBoundary{{boundary, 1}, {"index-job-lock", 2}})
	settings := pgIndexTestSettings()
	settings.renew = time.Second
	settings.poll = time.Second
	service := pgStartIndexTestService(t, f, 2, false, state, settings)
	defer pauses[0].resume()
	defer pauses[1].resume()
	select {
	case <-pauses[0].arrived:
	case <-service.done:
		t.Fatalf("worker exited: %v", service.err)
	case <-f.ctx.Done():
		t.Fatal(f.ctx.Err())
	}
	// Administrative fault injection models revocation while a holder is
	// paused. Each locked pre-DDL ownership barrier must refuse its old token,
	// including the last check after the durable building transition.
	job := pgIndexControlTestJobs(t, f)[0]
	if _, err := f.installer.Exec(f.ctx, "update notes_app.tesl_schema_leases set token=token+1 where name='index:active__v2'"); err != nil {
		t.Fatal(err)
	}
	pauses[0].resume()
	select {
	case <-pauses[1].arrived:
	case <-service.done:
		t.Fatalf("worker exited before replacement job lock: %v", service.err)
	case <-f.ctx.Done():
		t.Fatal(f.ctx.Err())
	}
	current := pgIndexControlTestJobs(t, f)[0]
	if current.Token <= job.Token+1 || current.Holder == job.Holder {
		t.Fatalf("paused successor did not acquire new ownership: initial=%+v current=%+v", job, current)
	}
	var survivors int
	var absent bool
	if err := f.installer.QueryRow(f.ctx, `select
 (select count(*) from pg_catalog.pg_stat_activity where datname=current_database() and application_name=$1),
 pg_catalog.to_regclass('notes_app.active__v2') is null`, job.Holder).Scan(&survivors, &absent); err != nil {
		t.Fatal(err)
	}
	if survivors != 0 || !absent {
		t.Fatalf("revoked actor left a live backend or physical index before successor inspection: survivors=%d indexAbsent=%v", survivors, absent)
	}
	// The successor is still before its first observation or cleanup. Requiring
	// absence here catches even a revoked CREATE canceled into an invalid remnant,
	// which a later successful rebuild would otherwise hide from the counter.
	pauses[1].resume()
	completed := pgIndexTestValid(t, f, service)
	// At index-before-create the first attempt is already durably recorded. A
	// replacement must start another attempt: merely adopting an index created
	// by the revoked actor would leave this counter unchanged and fail here.
	if completed.Attempts != job.Attempts+1 {
		t.Fatalf("revoked pre-DDL actor executed a build: %+v", completed)
	}
	pgIndexTestStop(t, service)
}
