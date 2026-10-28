//go:build tesl_migration_test

package teslrt

import (
	"context"
	"fmt"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

func TestQueueRegistrationCrashBeforeAndAfterCommit(t *testing.T) {
	for _, boundary := range []string{"expansion-before-commit", "expansion-after-commit"} {
		t.Run(boundary, func(t *testing.T) {
			f, request, _, _ := pgQueueRegistrationSetup(t)
			h, root := pgQueueRegistrationSource(t, 3)
			pgQueueRegistrationRelink(t, h, root)
			pgQueueRegistrationBegin(t, f, h, 2)
			before := pgQueueRegistrationRows(t, f)
			pgQueueCandidateCrash(t, f, boundary, func(conn *pgx.Conn) error {
				err := pgExpansionTransaction(f.ctx, conn, func(tx pgx.Tx) error { return pgRegisterQueueCandidateInventory(f.ctx, tx, h, 1, 2) })
				if err != nil {
					return err
				}
				return conn.Ping(f.ctx)
			})
			var count int
			if err := f.installer.QueryRow(f.ctx, "select count(*) from notes_app.tesl_queue_versions").Scan(&count); err != nil {
				t.Fatal(err)
			}
			want := 1
			if boundary == "expansion-after-commit" {
				want = 2
			}
			if count != want {
				t.Fatalf("partial/absent committed inventory %d/%d", count, want)
			}
			if want == 1 && before != pgQueueRegistrationRows(t, f) {
				t.Fatal("precommit crash left metadata")
			}
			if err := pgExpansionTransaction(f.ctx, f.worker, func(tx pgx.Tx) error { return pgRegisterQueueCandidateInventory(f.ctx, tx, h, 1, 2) }); err != nil {
				t.Fatal(err)
			}
			stable := pgQueueRegistrationRows(t, f)
			if err := pgExpansionTransaction(f.ctx, f.worker, func(tx pgx.Tx) error { return pgRegisterQueueCandidateInventory(f.ctx, tx, h, 1, 2) }); err != nil {
				t.Fatal(err)
			}
			if stable != pgQueueRegistrationRows(t, f) {
				t.Fatal("uncertain-commit replay duplicated metadata")
			}
			if _, err := pgCandidateReadOnly(t, f, request, &h); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestQueueRegistrationBackendDeathDuringPayloadInsertion(t *testing.T) {
	f, request, _, _ := pgQueueRegistrationSetup(t)
	h, root := pgQueueRegistrationSource(t, 3)
	pgQueueRegistrationRelink(t, h, root)
	pgQueueRegistrationBegin(t, f, h, 2)
	before := pgQueueRegistrationRows(t, f)
	// A test-only owner trigger pauses inside the real closed registration
	// statement, after its version and contract rows exist but before all payloads.
	if _, err := f.installer.Exec(f.ctx, `create function notes_app.test_pause_queue_registration() returns trigger language plpgsql as $$
 begin if new.version=2 and new.job_type='Rebuild' then perform pg_advisory_xact_lock(813,421);end if;return new;end $$;
 create trigger test_pause before insert on notes_app.tesl_queue_payloads for each row execute function notes_app.test_pause_queue_registration()`); err != nil {
		t.Fatal(err)
	}
	blocker, err := pgx.ConnectConfig(f.ctx, f.installer.Config().Copy())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = blocker.Close(context.Background()) }()
	if _, err := blocker.Exec(f.ctx, "begin;select pg_advisory_xact_lock(813,421)"); err != nil {
		t.Fatal(err)
	}
	conn, err := pgx.ConnectConfig(f.ctx, f.worker.Config().Copy())
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = conn.Close(context.Background()) }()
	pid := conn.PgConn().PID()
	done := make(chan error, 1)
	go func() {
		done <- pgExpansionTransaction(f.ctx, conn, func(tx pgx.Tx) error { return pgRegisterQueueCandidateInventory(f.ctx, tx, h, 1, 2) })
	}()
	deadline := time.NewTimer(5 * time.Second)
	defer deadline.Stop()
	ticker := time.NewTicker(5 * time.Millisecond)
	defer ticker.Stop()
	waiting := false
	for !waiting {
		select {
		case err := <-done:
			t.Fatalf("registration ended before partial insert pause: %v", err)
		case <-deadline.C:
			t.Fatal("registration did not block in payload insertion")
		case <-ticker.C:
			if err := f.installer.QueryRow(f.ctx, "select exists(select 1 from pg_catalog.pg_locks where pid=$1 and locktype='advisory' and not granted)", pid).Scan(&waiting); err != nil {
				t.Fatal(err)
			}
		}
	}
	// An ordinary request still sees the previous complete metadata snapshot.
	if got := pgQueueRegistrationRows(t, f); got != before {
		t.Fatal("uncommitted source inventory leaked")
	}
	var killed bool
	if err := f.installer.QueryRow(f.ctx, "select pg_catalog.pg_terminate_backend($1::integer)", pid).Scan(&killed); err != nil || !killed {
		t.Fatalf("terminate %v %v", killed, err)
	}
	if err := <-done; err == nil {
		t.Fatal("killed registration returned success")
	}
	if _, err := blocker.Exec(f.ctx, "rollback"); err != nil {
		t.Fatal(err)
	}
	if _, err := f.installer.Exec(f.ctx, "drop trigger test_pause on notes_app.tesl_queue_payloads;drop function notes_app.test_pause_queue_registration()"); err != nil {
		t.Fatal(err)
	}
	if before != pgQueueRegistrationRows(t, f) {
		t.Fatal("backend death left a partial inventory")
	}
	if err := pgExpansionTransaction(f.ctx, f.worker, func(tx pgx.Tx) error { return pgRegisterQueueCandidateInventory(f.ctx, tx, h, 1, 2) }); err != nil {
		t.Fatal(err)
	}
	if _, err := pgCandidateReadOnly(t, f, request, &h); err != nil {
		t.Fatal(err)
	}
}

func TestQueueRegistrationConcurrentReplayHasOneImmutableWinner(t *testing.T) {
	for _, conflicting := range []bool{false, true} {
		t.Run(fmt.Sprint(conflicting), func(t *testing.T) {
			f, request, _, _ := pgQueueRegistrationSetup(t)
			h, root := pgQueueRegistrationSource(t, 3)
			pgQueueRegistrationRelink(t, h, root)
			pgQueueRegistrationBegin(t, f, h, 2)
			v := pgQueueRegistrationVersion(t, h, 1, 2)
			wire := pgQueueRegistrationWire(t, v)
			hash, err := pgQueueCandidateInventoryHash(h, v)
			if err != nil {
				t.Fatal(err)
			}
			other := pgQueueRegistrationWire(t, v)
			otherHash := hash
			if conflicting {
				q := other[0].(map[string]any)
				ps := q["payloads"].([]any)
				p := map[string]any{}
				for k, v := range ps[1].(map[string]any) {
					p[k] = v
				}
				p["job"] = "Reindex"
				q["payloads"] = append(ps, p)
				if err := f.worker.QueryRow(f.ctx, "select notes_app.tesl_queue_inventory_hash($1,$2,$3,$4,$5,$6::jsonb)", h.Family, v.Version, v.StorageSnapshotHash, v.SchemaSnapshotHash, h.StoredValueCompatibility, queueProjectionJSON(t, other)).Scan(&otherHash); err != nil {
					t.Fatal(err)
				}
			}
			first, err := pgx.ConnectConfig(f.ctx, f.worker.Config().Copy())
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = first.Close(context.Background()) }()
			second, err := pgx.ConnectConfig(f.ctx, f.worker.Config().Copy())
			if err != nil {
				t.Fatal(err)
			}
			defer func() { _ = second.Close(context.Background()) }()
			tx, err := first.Begin(f.ctx)
			if err != nil {
				t.Fatal(err)
			}
			if err := pgRegisterQueueCandidateInventory(f.ctx, tx, h, 1, 2); err != nil {
				t.Fatal(err)
			}
			done := make(chan error, 1)
			go func() { done <- pgQueueRegistrationCall(f, second, h, v, otherHash, other) }()
			// Wait for the second worker to block on the serialized control state.
			waiting := false
			deadline := time.NewTimer(5 * time.Second)
			defer deadline.Stop()
			ticker := time.NewTicker(5 * time.Millisecond)
			defer ticker.Stop()
			for !waiting {
				select {
				case err := <-done:
					t.Fatalf("replay bypassed registration lock: %v", err)
				case <-deadline.C:
					t.Fatal("replay failed to reach state lock")
				case <-ticker.C:
					if err := f.installer.QueryRow(f.ctx, "select exists(select 1 from pg_catalog.pg_stat_activity where pid=$1 and wait_event_type='Lock')", second.PgConn().PID()).Scan(&waiting); err != nil {
						t.Fatal(err)
					}
				}
			}
			if err := tx.Commit(f.ctx); err != nil {
				t.Fatal(err)
			}
			if err := <-done; (err != nil) != conflicting {
				t.Fatalf("conflicting=%v replay=%v", conflicting, err)
			}
			before := pgQueueRegistrationRows(t, f)
			if err := pgQueueRegistrationCall(f, f.worker, h, v, hash, wire); err != nil {
				t.Fatal(err)
			}
			if before != pgQueueRegistrationRows(t, f) {
				t.Fatal("winner replay modified inventory")
			}
			if _, err := pgCandidateReadOnly(t, f, request, &h); err != nil {
				t.Fatal(err)
			}
		})
	}
}
