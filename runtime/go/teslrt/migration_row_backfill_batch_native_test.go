//go:build tesl_migration_test

package teslrt

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"
)

func TestPgRowParallelShardRequiresProtocolUpgrade(t *testing.T) {
	root := os.Getenv("TESL_ROW_SETTLED_PROGRAMS")
	if root == "" {
		t.Skip("actual compiler-generated applications required")
	}
	f, _ := pgNewWorkerTest(t)
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	t.Cleanup(cancel)
	f.ctx = ctx
	f.namespace = "notes"
	pgForwardNativeRun(t, f, root, "v1", "install", true)
	pgForwardNativeRun(t, f, root, "v1", "worker", true)
	pgForwardNativeRun(t, f, root, "v2", "worker", true)
	pgForwardNativeRun(t, f, root, "v2", "status", true)
	if _, err := f.installer.Exec(ctx, `insert into notes.tesl_schema_backfill_shards(version,entity,target_generation,shard,lo_pk,hi_pk,lease_name)
values(2,'Note',2,1,null,null,'row:Note:2:1'); insert into notes.tesl_schema_leases(name) values('row:Note:2:1')`); err != nil {
		t.Fatal(err)
	}
	out := pgForwardNativeRun(t, f, root, "v2", "status", false)
	if !strings.Contains(string(out), "row shard/lease differs") {
		t.Fatal("unexpected parallel shard refusal", string(out))
	}
}

// Processing success belongs to one SQL transaction. A 40001 retry in the same
// process must not reuse a latch which the preceding batch rolled back.
func TestPgRowBackfillBatchLatchRollback(t *testing.T) {
	root := os.Getenv("TESL_ROW_SETTLED_PROGRAMS")
	if root == "" {
		t.Skip("actual compiler-generated V1/V2 applications required")
	}
	f, request := pgNewWorkerTest(t)
	ctx, cancel := context.WithTimeout(context.Background(), 75*time.Second)
	t.Cleanup(cancel)
	f.ctx = ctx
	f.namespace = "notes"
	pgForwardNativeRun(t, f, root, "v1", "install", true)
	pgForwardNativeRun(t, f, root, "v1", "worker", true)
	pgForwardNativeRun(t, f, root, "v2", "worker", true)
	v1 := pgStartRowAccessApp(t, f, root, "v1")
	for _, key := range []string{"four", "one"} {
		pgCallRowAccessApp(t, f.ctx, v1, "POST", "/"+key, 200)
	}
	// Four sorts before one. Its CAS is followed by the first processing latch;
	// changing one after this RR snapshot forces the second CAS to abort both.
	pauses := pgPauseConcurrentRowBoundaries(t, []pgExpansionBoundary{
		{name: "row-backfill-after-dml", hit: 1},
		{name: "row-backfill-after-read", hit: 2},
	})
	socket := "TESL_MIGRATION_TEST_SOCKET=" + os.Getenv("TESL_MIGRATION_TEST_SOCKET")
	stop, done := pgStartSettledWorker(t, f, root, "v2", socket, "TESL_BACKFILL_BATCH=2")
	t.Cleanup(func() {
		for _, pause := range pauses {
			pause.resume()
		}
	})
	pgAwaitRowSnapshotBoundary(t, pauses[0], done)
	pgCallRowAccessApp(t, f.ctx, v1, "PUT", "/one", 200)
	var oldRows, pins int
	var title, memo string
	if err := request.QueryRow(f.ctx, `select title,memo,(select count(*) from notes.notes where _tesl_v=1),
 (select count(*) from notes.tesl_row_processing) from notes.notes where id='one'`).Scan(&title, &memo, &oldRows, &pins); err != nil || title != "edited" || memo != "one-edited" || oldRows != 2 || pins != 0 {
		t.Fatal("old application write not committed before second CAS", title, memo, oldRows, pins, err)
	}
	pauses[0].resume()
	pgAwaitRowSnapshotBoundary(t, pauses[1], done)
	var unchanged, accepted, rowsDone, floor int
	var cursorAbsent bool
	if err := request.QueryRow(f.ctx, `select
 (select count(*) from notes.notes where _tesl_v=1 and count is null),
 (select count(*) from notes.notes where id='four' and title='four' and memo='base'),
 (select count(*) from notes.notes where id='one' and title='edited' and memo='one-edited'),
 (select count(*) from notes.tesl_row_processing),b.rows_done,b.last_pk is null,s.compat_floor
 from notes.tesl_schema_backfill_shards b cross join notes.tesl_schema_state s
 where b.lease_name='row:Note:2:0' and s.id=1`).Scan(&oldRows, &unchanged, &accepted, &pins, &rowsDone, &cursorAbsent, &floor); err != nil || oldRows != 2 || unchanged != 1 || accepted != 1 || pins != 0 || rowsDone != 0 || !cursorAbsent || floor != 1 {
		t.Fatal("failed two-row attempt published rows, latch or progress", oldRows, unchanged, accepted, pins, rowsDone, cursorAbsent, floor, err)
	}
	pauses[1].resume()
	deadline := time.Now().Add(15 * time.Second)
	for {
		var converted int
		var exactABI bool
		if err := request.QueryRow(f.ctx, `select
 (select count(*) from notes.notes where _tesl_v=2 and count=7 and owner='writer' and
  ((id='four' and title='four' and memo='base') or (id='one' and title='edited' and memo='one-edited'))),
 (select count(*) from notes.tesl_row_processing),
 coalesce((select p.compiler_abi=r.compiler_abi from notes.tesl_row_processing p join notes.tesl_row_physical r on r.version=p.version where p.version=2),false),
 b.rows_done,s.compat_floor from notes.tesl_schema_backfill_shards b cross join notes.tesl_schema_state s
 where b.lease_name='row:Note:2:0' and s.id=1`).Scan(&converted, &pins, &exactABI, &rowsDone, &floor); err != nil {
			t.Fatal(err)
		}
		if converted == 2 {
			if pins != 1 || !exactABI || rowsDone != 2 || floor != 1 {
				t.Fatal("same-process retry omitted its own committed ABI receipt or progress", converted, pins, exactABI, rowsDone, floor)
			}
			break
		}
		select {
		case err := <-done:
			t.Fatalf("Worker exited rather than retrying two-row serialization: %v", err)
		default:
		}
		if time.Now().After(deadline) {
			t.Fatal("Worker failed to retry the two-row batch")
		}
		time.Sleep(10 * time.Millisecond)
	}
	stop()
	t.Log("same Worker process rolled back its first successful latch and both-row attempt, then re-latched a fresh transaction while preserving the old writer's edit")
}

// A later pipeline group can fail after earlier groups have succeeded. Every
// group, the first-write ABI latch and the cursor still share one transaction.
func TestPgRowBackfillPipelineRollback(t *testing.T) {
	root := os.Getenv("TESL_ROW_SETTLED_PROGRAMS")
	if root == "" {
		t.Skip("actual compiler-generated V1/V2 applications required")
	}
	f, request := pgNewWorkerTest(t)
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	t.Cleanup(cancel)
	f.ctx = ctx
	f.namespace = "notes"
	pgForwardNativeRun(t, f, root, "v1", "install", true)
	pgForwardNativeRun(t, f, root, "v1", "worker", true)
	pgForwardNativeRun(t, f, root, "v2", "worker", true)
	if _, err := request.Exec(ctx, `begin; select notes.tesl_admit_writer(1);
insert into notes.notes(id,author,title,memo)
select 'r'||lpad(i::text,4,'0'),'writer','r'||lpad(i::text,4,'0'),'base' from generate_series(0,259) i;
commit`); err != nil {
		t.Fatal(err)
	}
	publication := pgExpansionBoundary{name: "row-backfill-after-dml", hit: 2}
	if os.Getenv("TESL_REQUIRE_BULK") == "1" {
		publication = pgExpansionBoundary{name: "row-backfill-after-bulk", hit: 1}
	}
	pauses := pgPauseConcurrentRowBoundaries(t, []pgExpansionBoundary{
		publication,
		{name: "row-backfill-after-read", hit: 2},
	})
	socket := "TESL_MIGRATION_TEST_SOCKET=" + os.Getenv("TESL_MIGRATION_TEST_SOCKET")
	stop, done := pgStartSettledWorker(t, f, root, "v2", socket, "TESL_BACKFILL_BATCH=260")
	t.Cleanup(func() {
		for _, pause := range pauses {
			pause.resume()
		}
	})
	pgAwaitRowSnapshotBoundary(t, pauses[0], done)
	if _, err := request.Exec(ctx, `begin; select notes.tesl_admit_writer(1);
update notes.notes set memo='accepted-old-edit' where id='r0259'; commit`); err != nil {
		t.Fatal(err)
	}
	pauses[0].resume()
	pgAwaitRowSnapshotBoundary(t, pauses[1], done)
	var oldRows, pins, progress, edits int
	if err := request.QueryRow(ctx, `select
(select count(*) from notes.notes where _tesl_v=1 and count is null),
(select count(*) from notes.tesl_row_processing),
(select rows_done from notes.tesl_schema_backfill_shards where lease_name='row:Note:2:0'),
(select count(*) from notes.notes where id='r0259' and memo='accepted-old-edit')`).Scan(&oldRows, &pins, &progress, &edits); err != nil || oldRows != 260 || pins != 0 || progress != 0 || edits != 1 {
		t.Fatal("pipeline failure published a prefix or lost the accepted edit", oldRows, pins, progress, edits, err)
	}
	pauses[1].resume()
	for {
		var converted int
		if err := request.QueryRow(ctx, `select count(*) from notes.notes where _tesl_v=2 and count=7 and owner='writer'
and memo=case when id='r0259' then 'accepted-old-edit' else 'base' end`).Scan(&converted); err != nil {
			t.Fatal(err)
		}
		if converted == 260 {
			break
		}
		select {
		case err := <-done:
			t.Fatalf("Worker did not retry the rolled-back pipeline: %v", err)
		default:
		}
		if err := pgIndexWait(ctx, 10*time.Millisecond); err != nil {
			t.Fatal(err)
		}
	}
	stop()
}
