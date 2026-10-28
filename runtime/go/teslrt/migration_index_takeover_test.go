package teslrt

import (
	"context"
	"errors"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

const pgExpiredIndexGuardSQL = "select notes_app.tesl_lock_expired_index_holder($1,$2,$3,$4,$5)"
const pgExpiredIndexOldTag = "tesl-exec:expired-holder"

func pgExpiredIndexConnection(t *testing.T, f *pgControlTestFixture, tag string, administrative bool) *pgx.Conn {
	t.Helper()
	config := f.worker.Config().Copy()
	if administrative {
		config = f.installer.Config().Copy()
	}
	config.RuntimeParams["application_name"] = tag
	conn, err := pgx.ConnectConfig(f.ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close(context.Background()) })
	return conn
}

func pgExpiredIndexFixture(t *testing.T) (*pgControlTestFixture, *pgx.Conn, *pgx.Conn, string, int64) {
	t.Helper()
	f, request := pgNewWorkerTest(t)
	f.install(t, 1)
	f.expand(t, 1)
	id := pgIndexControlTestIntent(t, f)
	pgIndexControlTestRegister(t, f, id, "notes", "active_idx__v2", []string{"active"})
	f.call(t, "select notes_app.tesl_record_expanded(2)")
	f.call(t, "set application_name='tesl-exec:successor'")
	old := pgExpiredIndexConnection(t, f, pgExpiredIndexOldTag, false)
	var token int64
	if err := old.QueryRow(f.ctx, "select notes_app.tesl_claim_index($1,2,$2,600000)", id, pgTestSourceABI).Scan(&token); err != nil || token != 1 {
		t.Fatalf("original lease: %d %v", token, err)
	}
	return f, request, old, id, token
}

func pgExpiredIndexSnapshot(t *testing.T, f *pgControlTestFixture) string {
	t.Helper()
	return pgExpiredIndexSnapshotFrom(t, f, f.installer)
}

func pgExpiredIndexSnapshotFrom(t *testing.T, f *pgControlTestFixture, query interface {
	QueryRow(context.Context, string, ...any) pgx.Row
}) string {
	t.Helper()
	var value string
	if err := query.QueryRow(f.ctx, `select jsonb_build_array(
 (select jsonb_agg(to_jsonb(m) order by id) from notes_app.tesl_schema_meta m),
 (select jsonb_agg(to_jsonb(s) order by id) from notes_app.tesl_schema_state s),
 (select jsonb_agg(to_jsonb(v) order by version,step,seq) from notes_app.tesl_schema_versions v),
 (select jsonb_agg(to_jsonb(e) order by version) from notes_app.tesl_schema_expansions e),
 (select jsonb_agg(to_jsonb(o) order by version,ordinal) from notes_app.tesl_schema_expansion_objects o),
 (select jsonb_agg(to_jsonb(j) order by id) from notes_app.tesl_schema_index j),
 (select jsonb_agg(to_jsonb(l) order by name) from notes_app.tesl_schema_leases l))::text`).Scan(&value); err != nil {
		t.Fatal(err)
	}
	return value
}

func pgExpiredIndexExpire(t *testing.T, f *pgControlTestFixture) {
	t.Helper()
	if _, err := f.installer.Exec(f.ctx, "update notes_app.tesl_schema_leases set expires_at=clock_timestamp()-interval '1 second'"); err != nil {
		t.Fatal(err)
	}
}

// INV-LEASE, INV-PRIVILEGE; TR-DDL-CLAIM.
func TestPgMigrationControlIndexExpiredHolderValidatesWithoutMutation(t *testing.T) {
	for _, name := range []string{"live", "expired", "released", "wrong-holder", "wrong-token", "self", "bad-caller", "bad-holder",
		"null-holder", "null-token", "null-abi", "wrong-abi", "uninstalled-version", "predating-version", "retired-version", "valid", "terminal"} {
		t.Run(name, func(t *testing.T) {
			f, request, old, id, token := pgExpiredIndexFixture(t)
			args := []any{id, pgExpiredIndexOldTag, token, 2, pgTestSourceABI}
			want, reason := false, ""
			if name != "live" {
				pgExpiredIndexExpire(t, f)
			}
			switch name {
			case "live":
			case "expired":
				want = true
			case "released":
				if _, err := f.installer.Exec(f.ctx, "update notes_app.tesl_schema_leases set holder=null,expires_at=null"); err != nil {
					t.Fatal(err)
				}
			case "wrong-holder":
				args[1] = "tesl-exec:another-holder"
			case "wrong-token":
				args[2] = token + 1
			case "self":
				f.call(t, "set application_name='"+pgExpiredIndexOldTag+"'")
			case "bad-caller":
				f.call(t, "set application_name='tesl-app:request'")
				reason = "invalid expired index holder"
			case "bad-holder":
				args[1], reason = "tesl-exec:", "invalid expired index holder"
			case "null-holder":
				args[1], reason = nil, "invalid expired index holder"
			case "null-token":
				args[2], reason = nil, "invalid expired index holder"
			case "null-abi":
				args[4], reason = nil, "invalid expired index holder"
			case "wrong-abi":
				args[4], reason = "other", "unfinished index compiler ABI"
			case "uninstalled-version":
				args[3], reason = 3, "not installed"
			case "predating-version":
				args[3], reason = 1, "predates its job"
			case "retired-version":
				if _, err := f.installer.Exec(f.ctx, "update notes_app.tesl_schema_state set min_version=2,compat_floor=2"); err != nil {
					t.Fatal(err)
				}
				args[3], reason = 1, "retired"
			case "valid":
				if _, err := f.installer.Exec(f.ctx, "update notes_app.tesl_schema_index set state='valid'"); err != nil {
					t.Fatal(err)
				}
			case "terminal":
				if _, err := f.installer.Exec(f.ctx, "update notes_app.tesl_schema_index set state='terminal',terminal_version=2"); err != nil {
					t.Fatal(err)
				}
			default:
				t.Fatal(name)
			}
			before := pgExpiredIndexSnapshot(t, f)
			var got bool
			err := f.worker.QueryRow(f.ctx, pgExpiredIndexGuardSQL, args...).Scan(&got)
			if reason != "" {
				if err == nil || !strings.Contains(err.Error(), reason) {
					t.Fatalf("guard did not refuse %s: %v", reason, err)
				}
			} else if err != nil || got != want {
				t.Fatalf("guard: got=%v want=%v err=%v", got, want, err)
			}
			if before != pgExpiredIndexSnapshot(t, f) {
				t.Fatal("guard rewrote persisted ownership, lifecycle or provenance")
			}
			if _, err := old.Exec(f.ctx, "select 1"); err != nil {
				t.Fatalf("SECURITY DEFINER guard signalled its old holder: %v", err)
			}
			if name == "expired" {
				var claimed int64
				if err := f.worker.QueryRow(f.ctx, "select notes_app.tesl_claim_index($1,2,$2,600000)", id, pgTestSourceABI).Scan(&claimed); err != nil || claimed != 0 {
					t.Fatalf("expiry guard bypassed the live-backend claim rule: %d %v", claimed, err)
				}
				if _, err := request.Exec(f.ctx, "set application_name='tesl-exec:spoof'"); err != nil {
					t.Fatal(err)
				}
				_, err := request.Exec(f.ctx, pgExpiredIndexGuardSQL, id, pgExpiredIndexOldTag, token, 2, pgTestSourceABI)
				var denied *pgconn.PgError
				if !errors.As(err, &denied) || denied.Code != "42501" {
					t.Fatalf("spoofed request acquired holder-lock authority: %v", err)
				}
				if before != pgExpiredIndexSnapshot(t, f) {
					t.Fatal("refused request or live-holder claim changed persisted state")
				}
			}
		})
	}
}

type pgExpiredIndexResult struct {
	value bool
	err   error
}

type pgExpiredIndexCall struct {
	done   chan struct{}
	result pgExpiredIndexResult
}

func pgStartExpiredIndexCall(t *testing.T, f *pgControlTestFixture, run func(context.Context) pgExpiredIndexResult) *pgExpiredIndexCall {
	t.Helper()
	ctx, cancel := context.WithTimeout(f.ctx, 10*time.Second)
	call := &pgExpiredIndexCall{done: make(chan struct{})}
	go func() {
		call.result = run(ctx)
		close(call.done)
	}()
	t.Cleanup(func() {
		cancel()
		select {
		case <-call.done:
		case <-time.After(5 * time.Second):
			t.Error("controlled index query did not join after cancellation")
		}
	})
	return call
}

func (call *pgExpiredIndexCall) wait(t *testing.T, f *pgControlTestFixture) pgExpiredIndexResult {
	t.Helper()
	select {
	case <-call.done:
		return call.result
	case <-f.ctx.Done():
		t.Fatal(f.ctx.Err())
		return pgExpiredIndexResult{}
	}
}

func pgWaitExpiredIndexObservation(t *testing.T, f *pgControlTestFixture, condition func() bool) {
	t.Helper()
	ctx, cancel := context.WithTimeout(f.ctx, 5*time.Second)
	defer cancel()
	ticker := time.NewTicker(time.Millisecond)
	defer ticker.Stop()
	for !condition() {
		select {
		case <-ctx.Done():
			t.Fatalf("controlled index state was not observed: %v", ctx.Err())
		case <-ticker.C:
		}
	}
}

func pgAssertExpiredIndexBlocked(t *testing.T, f *pgControlTestFixture, waiter, holder uint32, call *pgExpiredIndexCall) {
	t.Helper()
	pgWaitExpiredIndexObservation(t, f, func() bool {
		select {
		case <-call.done:
			t.Fatalf("index operation bypassed the guard's row locks: %+v", call.result)
		default:
		}
		var blockers []int32
		if err := f.installer.QueryRow(f.ctx, "select pg_catalog.pg_blocking_pids($1::integer)", waiter).Scan(&blockers); err != nil {
			t.Fatal(err)
		}
		return slices.Contains(blockers, int32(holder))
	})
}

func pgWaitExpiredIndexGone(t *testing.T, f *pgControlTestFixture, pid uint32) {
	t.Helper()
	pgWaitExpiredIndexObservation(t, f, func() bool {
		var gone bool
		if err := f.installer.QueryRow(f.ctx, `select not exists(select 1 from pg_catalog.pg_stat_activity where pid=$1)
 and not exists(select 1 from pg_catalog.pg_locks where pid=$1)`, pid).Scan(&gone); err != nil {
			t.Fatal(err)
		}
		return gone
	})
}

// INV-LEASE; TR-DDL-CLAIM.
func TestPgMigrationControlIndexExpiredHolderLocksRenewClaimAndPublication(t *testing.T) {
	for _, operation := range []string{"renew", "claim", "valid", "terminal"} {
		for _, finish := range []string{"commit", "rollback"} {
			t.Run(operation+"/"+finish, func(t *testing.T) {
				f, _, _, id, token := pgExpiredIndexFixture(t)
				pgExpiredIndexExpire(t, f)
				before := pgExpiredIndexSnapshot(t, f)
				tx, err := f.worker.Begin(f.ctx)
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() { _ = tx.Rollback(context.Background()) })
				var guarded bool
				if err := tx.QueryRow(f.ctx, pgExpiredIndexGuardSQL, id, pgExpiredIndexOldTag, token, 2, pgTestSourceABI).Scan(&guarded); err != nil || !guarded {
					t.Fatalf("lock expired holder: %v %v", guarded, err)
				}
				contender := pgExpiredIndexConnection(t, f, pgExpiredIndexOldTag, operation == "terminal")
				if operation == "claim" {
					if _, err := contender.Exec(f.ctx, "set application_name='tesl-exec:competitor'"); err != nil {
						t.Fatal(err)
					}
				}
				call := pgStartExpiredIndexCall(t, f, func(ctx context.Context) pgExpiredIndexResult {
					var got bool
					var err error
					switch operation {
					case "renew":
						err = contender.QueryRow(ctx, "select notes_app.tesl_renew_index($1,$2,600000)", id, token).Scan(&got)
					case "claim":
						var claimed int64
						err = contender.QueryRow(ctx, "select notes_app.tesl_claim_index($1,2,$2,600000)", id, pgTestSourceABI).Scan(&claimed)
						got = claimed != 0
					case "valid":
						err = contender.QueryRow(ctx, "select notes_app.tesl_record_index_state($1,$2,'valid',null)", id, token).Scan(&got)
					case "terminal":
						_, err = contender.Exec(ctx, "update notes_app.tesl_schema_index set state='terminal',terminal_version=2 where id=$1", id)
						got = err == nil
					}
					return pgExpiredIndexResult{got, err}
				})
				pgAssertExpiredIndexBlocked(t, f, contender.PgConn().PID(), f.worker.PgConn().PID(), call)
				if before != pgExpiredIndexSnapshot(t, f) {
					t.Fatal("locking expired holder changed persisted rows")
				}
				if finish == "commit" {
					err = tx.Commit(f.ctx)
				} else {
					err = tx.Rollback(f.ctx)
				}
				if err != nil {
					t.Fatal(err)
				}
				result := call.wait(t, f)
				if result.err != nil || result.value != (operation == "terminal") {
					t.Fatalf("blocked contender after guard %s: %+v", finish, result)
				}
				if operation != "terminal" && before != pgExpiredIndexSnapshot(t, f) {
					t.Fatal("expired holder or competing claim changed persisted state")
				}
			})
		}
	}
}

// INV-LEASE, INV-INDEX-READY; TR-DDL-CLAIM.
func TestPgMigrationControlIndexExpiredHolderRechecksAfterCompetingCommit(t *testing.T) {
	for _, winner := range []string{"renewal", "claim", "valid", "terminal", "expiry"} {
		t.Run(winner, func(t *testing.T) {
			f, _, old, id, token := pgExpiredIndexFixture(t)
			winning := old
			if winner == "terminal" || winner == "expiry" {
				winning = pgExpiredIndexConnection(t, f, "index-state-writer", true)
			}
			if winner == "claim" {
				pid := old.PgConn().PID()
				if err := old.Close(f.ctx); err != nil {
					t.Fatal(err)
				}
				pgWaitExpiredIndexGone(t, f, pid)
				winning = pgExpiredIndexConnection(t, f, "tesl-exec:winning-claim", false)
			}
			tx, err := winning.Begin(f.ctx)
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = tx.Rollback(context.Background()) })
			switch winner {
			case "renewal":
				var renewed bool
				if err := tx.QueryRow(f.ctx, "select notes_app.tesl_renew_index($1,$2,600000)", id, token).Scan(&renewed); err != nil || !renewed {
					t.Fatalf("winning renewal: %v %v", renewed, err)
				}
			case "claim":
				var next int64
				if err := tx.QueryRow(f.ctx, "select notes_app.tesl_claim_index($1,2,$2,600000)", id, pgTestSourceABI).Scan(&next); err != nil || next != token+1 {
					t.Fatalf("winning claim: %d %v", next, err)
				}
			case "valid":
				var published bool
				if err := tx.QueryRow(f.ctx, "select notes_app.tesl_record_index_state($1,$2,'valid',null)", id, token).Scan(&published); err != nil || !published {
					t.Fatalf("winning publication: %v %v", published, err)
				}
			case "terminal":
				if _, err := tx.Exec(f.ctx, "update notes_app.tesl_schema_index set state='terminal',terminal_version=2 where id=$1", id); err != nil {
					t.Fatal(err)
				}
			case "expiry":
				// The guard's initial snapshot still sees a live lease, but after
				// acquiring this lease row it must evaluate the newly expired one.
				if _, err := tx.Exec(f.ctx, "update notes_app.tesl_schema_leases set expires_at=clock_timestamp()-interval '1 second'"); err != nil {
					t.Fatal(err)
				}
			}
			expected := pgExpiredIndexSnapshotFrom(t, f, tx)
			call := pgStartExpiredIndexCall(t, f, func(ctx context.Context) pgExpiredIndexResult {
				var guarded bool
				err := f.worker.QueryRow(ctx, pgExpiredIndexGuardSQL, id, pgExpiredIndexOldTag, token, 2, pgTestSourceABI).Scan(&guarded)
				return pgExpiredIndexResult{guarded, err}
			})
			pgAssertExpiredIndexBlocked(t, f, f.worker.PgConn().PID(), winning.PgConn().PID(), call)
			if err := tx.Commit(f.ctx); err != nil {
				t.Fatal(err)
			}
			result := call.wait(t, f)
			if result.err != nil || result.value != (winner == "expiry") {
				t.Fatalf("guard used stale state after %s: %+v", winner, result)
			}
			if after := pgExpiredIndexSnapshot(t, f); after != expected {
				t.Fatalf("guard changed the winning transaction:\nexpected %s\nafter %s", expected, after)
			}
		})
	}
}

// INV-LEASE, INV-PRIVILEGE; TR-DDL-CLAIM.
func TestPgMigrationControlIndexExpiredHolderWorkerSignalsOnlyExactOldSessions(t *testing.T) {
	f, request, old, id, token := pgExpiredIndexFixture(t)
	twin := pgExpiredIndexConnection(t, f, pgExpiredIndexOldTag, false)
	unrelated := pgExpiredIndexConnection(t, f, "tesl-exec:unrelated", false)
	if _, err := request.Exec(f.ctx, "set application_name='"+pgExpiredIndexOldTag+"'"); err != nil {
		t.Fatal(err)
	}
	for _, role := range []string{f.roles.Owner, f.roles.Worker, f.roles.Request} {
		var broadSignal bool
		if err := f.installer.QueryRow(f.ctx, "select pg_catalog.pg_has_role($1,'pg_signal_backend','MEMBER')", role).Scan(&broadSignal); err != nil || broadSignal {
			t.Fatalf("takeover fixture broadened %s signal authority: %v %v", role, broadSignal, err)
		}
	}
	pgExpiredIndexExpire(t, f)
	before := pgExpiredIndexSnapshot(t, f)
	tx, err := f.worker.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = tx.Rollback(context.Background()) })
	var guarded bool
	if err := tx.QueryRow(f.ctx, pgExpiredIndexGuardSQL, id, pgExpiredIndexOldTag, token, 2, pgTestSourceABI).Scan(&guarded); err != nil || !guarded {
		t.Fatalf("lock expired holder: %v %v", guarded, err)
	}
	// Signals execute as the ordinary Worker, outside SECURITY DEFINER. Exact
	// database/login/full-tag matching must preserve both a different worker
	// instance and a request login that copied the old holder's visible tag.
	rows, err := tx.Query(f.ctx, `select pid,pg_catalog.pg_terminate_backend(pid) from pg_catalog.pg_stat_activity
 where datname=pg_catalog.current_database() and usename=$1 and application_name=$2 and pid<>pg_backend_pid()`, f.roles.Worker, pgExpiredIndexOldTag)
	if err != nil {
		t.Fatal(err)
	}
	victims := map[uint32]bool{}
	for rows.Next() {
		var pid uint32
		var signalled bool
		if err := rows.Scan(&pid, &signalled); err != nil || !signalled {
			rows.Close()
			t.Fatalf("old Worker signalling: pid=%d accepted=%v err=%v", pid, signalled, err)
		}
		victims[pid] = true
	}
	if err := rows.Err(); err != nil {
		rows.Close()
		t.Fatal(err)
	}
	rows.Close()
	if len(victims) != 2 || !victims[old.PgConn().PID()] || !victims[twin.PgConn().PID()] {
		t.Fatalf("wrong backend set signalled: %+v", victims)
	}
	if err := tx.Commit(f.ctx); err != nil {
		t.Fatal(err)
	}
	for pid := range victims {
		pgWaitExpiredIndexGone(t, f, pid)
	}
	if before != pgExpiredIndexSnapshot(t, f) {
		t.Fatal("guard/signalling rewrote the original lease before a successor claim")
	}
	for label, connection := range map[string]*pgx.Conn{"other worker": unrelated, "spoofed request": request} {
		if _, err := connection.Exec(f.ctx, "select 1"); err != nil {
			t.Fatalf("takeover signalled %s: %v", label, err)
		}
	}
	var next int64
	if err := f.worker.QueryRow(f.ctx, "select notes_app.tesl_claim_index($1,2,$2,600000)", id, pgTestSourceABI).Scan(&next); err != nil || next != 0 {
		t.Fatalf("claim ignored a remaining backend with the old full tag: %d %v", next, err)
	}
	spoofPID := request.PgConn().PID()
	if err := request.Close(f.ctx); err != nil {
		t.Fatal(err)
	}
	pgWaitExpiredIndexGone(t, f, spoofPID)
	if err := f.worker.QueryRow(f.ctx, "select notes_app.tesl_claim_index($1,2,$2,600000)", id, pgTestSourceABI).Scan(&next); err != nil || next != token+1 {
		t.Fatalf("dead holder replacement did not advance its fencing token: %d %v", next, err)
	}
	var stale bool
	if err := f.worker.QueryRow(f.ctx, pgExpiredIndexGuardSQL, id, pgExpiredIndexOldTag, token, 2, pgTestSourceABI).Scan(&stale); err != nil || stale {
		t.Fatalf("old observed identity retained termination authority after takeover: %v %v", stale, err)
	}
}
