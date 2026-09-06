package teslrt

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// A protected descriptor can outlive its original process. A still-running
// server build is not an abandoned INVALID remnant, even if it is no longer
// associated with the claimant this worker sees. Observe actual server progress
// across multiple claims, then preserve the exact committed index OID.
func TestPgMigrationIndexWorkerPreservesIndependentActiveBuild(t *testing.T) {
	f, request := pgNewWorkerTest(t)
	f.install(t, 1)
	pgExpandIndexTest(t, f, 1, false)
	f.call(t, "insert into notes_app.notes(id,active) values('retained',true)")
	state := pgExpandIndexTest(t, f, 2, false)
	writer := pgIndexTestWriter(t, f, request)
	config := f.worker.Config().Copy()
	config.RuntimeParams["application_name"] = "independent-index-builder"
	builder, err := pgx.ConnectConfig(f.ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	buildCtx, cancelBuild := context.WithCancel(f.ctx)
	buildResult, buildDone := make(chan error, 1), make(chan struct{})
	go func() {
		_, err := builder.Exec(buildCtx, "create index concurrently active__v2 on notes_app.notes(active)")
		buildResult <- err
		close(buildDone)
	}()
	t.Cleanup(func() {
		cancelBuild()
		_ = builder.PgConn().Conn().Close()
		select {
		case <-buildDone:
			cleanup, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			_ = builder.Close(cleanup)
		case <-time.After(5 * time.Second):
			t.Error("independent builder did not join after transport close")
		}
	})
	var originalOID uint32
	for {
		err := f.installer.QueryRow(f.ctx, `select index_relid from pg_stat_progress_create_index
 where pid=$1 and phase='waiting for writers before build'`, builder.PgConn().PID()).Scan(&originalOID)
		if err == nil {
			break
		}
		if !errors.Is(err, pgx.ErrNoRows) {
			t.Fatal(err)
		}
		select {
		case err := <-buildResult:
			t.Fatalf("independent CIC completed before its real writer barrier: %v", err)
		case <-f.ctx.Done():
			t.Fatal(f.ctx.Err())
		case <-time.After(10 * time.Millisecond):
		}
	}
	service := pgStartIndexTestService(t, f, 2, false, state, pgIndexTestSettings())
	pgIndexTestReady(t, f, service)
	pgIndexTestAwait(t, f, service, "repeated claims preserve actual independent progress", func() bool {
		job := pgIndexControlTestJobs(t, f)[0]
		if job.State != "pending" || job.Attempts != 0 {
			t.Fatalf("active external build was classified as failed or rebuilt: %+v", job)
		}
		var active bool
		if err := f.installer.QueryRow(f.ctx, `select exists(select 1 from pg_stat_progress_create_index
 where pid=$1 and index_relid=$2 and phase='waiting for writers before build')`, builder.PgConn().PID(), originalOID).Scan(&active); err != nil || !active {
			t.Fatalf("worker dropped or signalled a live independent build: %v %v", active, err)
		}
		return job.Token >= 2 && job.Holder == ""
	})
	reader, err := pgx.ConnectConfig(f.ctx, request.Config().Copy())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = reader.Close(context.Background()) }()
	for _, version := range []int{1, 2} {
		if _, err := pgWaitForMigrationReadiness(f.ctx, reader, pgIndexExpansionTestHistory(f.namespace, version, false), f.roles); err != nil {
			t.Fatalf("V%d request could not restart during live CIC: %v", version, err)
		}
	}
	if _, err := reader.Exec(f.ctx, "insert into notes_app.notes(id,active) values('during-build',false)"); err != nil {
		t.Fatal(err)
	}
	pgIndexTestStop(t, service)
	var externalAlive bool
	if err := f.installer.QueryRow(f.ctx, "select exists(select 1 from pg_stat_progress_create_index where pid=$1)", builder.PgConn().PID()).Scan(&externalAlive); err != nil || !externalAlive {
		t.Fatalf("worker shutdown signalled a different actor: %v %v", externalAlive, err)
	}
	if err := writer.Commit(f.ctx); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-buildResult:
		if err != nil {
			t.Fatal(err)
		}
	case <-f.ctx.Done():
		t.Fatal(f.ctx.Err())
	}
	successor := pgStartIndexTestService(t, f, 2, false, state, pgIndexTestSettings())
	pgIndexTestReady(t, f, successor)
	job := pgIndexTestValid(t, f, successor)
	var currentOID uint32
	if err := f.installer.QueryRow(f.ctx, "select 'notes_app.active__v2'::regclass::oid").Scan(&currentOID); err != nil || currentOID != originalOID || job.Attempts != 0 {
		t.Fatalf("valid independent result was rebuilt: old=%d new=%d attempts=%d err=%v", originalOID, currentOID, job.Attempts, err)
	}
	var retained int
	if err := reader.QueryRow(f.ctx, "select count(*) from notes_app.notes where token is null").Scan(&retained); err != nil || retained != 3 {
		t.Fatalf("active-build recovery changed application writes: %d %v", retained, err)
	}
	pgIndexTestStop(t, successor)
}
