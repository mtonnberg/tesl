package teslrt

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// INV-ATTEMPT; TR-CLAIM, TR-EXPIRY, TR-QUARANTINE.
// Decoding is user code and may finish after its claim expires or is replaced.
// A decoder rejection has the same ownership checks as completion and failure.
func TestDurableQueueDecoderFailureCannotChangeANewerAttempt(t *testing.T) {
	for _, interpose := range []string{"live", "expired", "replaced", "sequence changed", "transaction expired"} {
		t.Run(interpose, func(t *testing.T) {
			database := storeDatabase(t, "DecoderClaimOwnership")
			queue := NewQueueOn(database, uniqueName("decode_claim"), 3, "", 0)
			RegisterJobCodec(queue, "StoreJob", func(value any) any { return value }, func(any) (any, error) {
				db := database.bound()
				set := ""
				switch interpose {
				case "live":
				case "expired", "transaction expired":
					set = "lease_until=clock_timestamp()-interval '1 day'"
				case "replaced":
					set = "claim_token='successor:123',claim_seq=123"
				case "sequence changed":
					set = "claim_seq=claim_seq+1"
				}
				if set != "" {
					PgExec(db, "update "+db.QualifiedTable(jobsTable)+" set "+set+" where queue=$1", []any{queue.name})
				}
				return nil, errors.New("fixture decoder rejection")
			})
			WithDatabase(database, func() {
				EnqueueJob(queue, storeJob{Name: "reject", Count: FromInt64(1)})
				run := func() {
					if _, _, _, _, found := queue.dequeue(jobPending); found {
						t.Fatal("failed decode delivered a payload")
					}
				}
				if interpose == "transaction expired" {
					WithTransaction(run)
				} else {
					run()
				}
				db := database.bound()
				type state struct{ status, token, sequence string }
				rows := PgQuery(db, "select status,coalesce(claim_token,''),claim_seq::text from "+db.QualifiedTable(jobsTable)+" where queue=$1", []any{queue.name}, func(row pgx.CollectableRow) (state, error) {
					var s state
					err := row.Scan(&s.status, &s.token, &s.sequence)
					return s, err
				})
				if len(rows) != 1 {
					t.Fatalf("decoder rejection lost the job: %+v", rows)
				}
				s := rows[0]
				if interpose == "live" || interpose == "transaction expired" {
					if s.status != jobDead || s.token != "" || s.sequence != "1" {
						t.Fatalf("owned decoder rejection was not dead-lettered: %+v", s)
					}
				} else if s.status != jobProcessing || s.token == "" {
					t.Fatalf("stale decoder changed its successor or expired claim: %+v", s)
				}
				if interpose == "replaced" && (s.token != "successor:123" || s.sequence != "123") {
					t.Fatalf("replacement identity changed: %+v", s)
				}
				if interpose == "sequence changed" && s.sequence != "2" {
					t.Fatalf("monotone attempt changed: %+v", s)
				}
			})
		})
	}
}

// INV-ATTEMPT; TR-CLAIM, TR-RENEW, TR-EXPIRY, TR-RETRY, TR-COMPLETE.
func TestDurableQueueLeaseRenewalAndMonotoneAttempts(t *testing.T) {
	database := storeDatabase(t, "QueueRenewal")
	queue := NewQueueOn(database, uniqueName("renewal"), 3, "", 0)
	registerStoreJobCodec(queue)
	WithDatabase(database, func() {
		EnqueueJob(queue, storeJob{Name: "long handler", Count: FromInt64(1)})
		id, _, attempts, token, found := queue.dequeue(jobPending)
		if !found {
			t.Fatal("claim missing")
		}
		seq, valid := queueClaimSequence(token)
		if !valid || seq != 1 {
			t.Fatalf("first claim sequence: %q", token)
		}
		backend := queue.backend.(*pgQueueBackend)
		db, table := backend.table()
		// Advance the database's lease state directly. No production timeout is
		// shortened, and no wall-clock sleep controls this interleaving.
		PgExec(db, "update "+table+" set locked_at=clock_timestamp()-interval '20 seconds' where id=$1", []any{id})
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		if owned, err := backend.renewClaim(ctx, db, table, id, token, time.Minute); err != nil || !owned {
			t.Fatalf("live renewal: owned=%v err=%v", owned, err)
		}
		fresh := PgQuery(db, "select locked_at > clock_timestamp()-interval '5 seconds' from "+table+" where id=$1", []any{id}, pgx.RowTo[bool])
		if len(fresh) != 1 || !fresh[0] {
			t.Fatal("renewal did not advance lease")
		}
		PgExec(db, "update "+table+" set lease_until=clock_timestamp()-interval '1 day' where id=$1", []any{id})
		if owned, err := backend.renewClaim(ctx, db, table, id, token, time.Minute); err != nil || owned {
			t.Fatalf("expired claim resurrected: owned=%v err=%v", owned, err)
		}
		if queue.complete(id, token) || queue.fail(id, attempts, token) {
			t.Fatal("expired claim changed the row before reclaim")
		}
		backend.lastReclaim.Store(0)
		backend.reclaimStuck(db, table)
		again, _, _, replacement, found := queue.dequeue(jobPending)
		seq, valid = queueClaimSequence(replacement)
		if !found || again != id || !valid || seq != 2 {
			t.Fatalf("replacement attempt: id=%s token=%s", again, replacement)
		}
		if owned, err := backend.renewClaim(ctx, db, table, id, token, time.Minute); err != nil || owned {
			t.Fatalf("stale renewal changed replacement: owned=%v err=%v", owned, err)
		}
		if queue.complete(id, token) || queue.fail(id, attempts, token) {
			t.Fatal("stale outcome changed replacement")
		}
		if !queue.fail(id, 0, replacement) {
			t.Fatal("current claim could not retry")
		}
		_, _, _, third, found := queue.dequeue(jobPending)
		seq, valid = queueClaimSequence(third)
		if !found || !valid || seq != 3 {
			t.Fatalf("retry reset sequence: %q", third)
		}
		if !queue.complete(id, third) {
			t.Fatal("current claim could not complete")
		}
	})
}

func TestDurableQueueRenewalDoesNotDeadlockAnExplicitTransaction(t *testing.T) {
	database := storeDatabase(t, "QueueRenewalTransaction")
	queue := NewQueueOn(database, uniqueName("renewal_tx"), 3, "", 0)
	registerStoreJobCodec(queue)
	WithDatabase(database, func() {
		WithTransaction(func() {
			EnqueueJob(queue, storeJob{Name: "transaction", Count: FromInt64(1)})
			if out := ProcessNextJob(queue, func(any) JobOutcome {
				db := database.bound()
				PgExec(db, "update "+db.QualifiedTable(jobsTable)+" set lease_until=clock_timestamp()-interval '1 day' where queue=$1", []any{queue.name})
				return JobOutcome{OK: true}
			}); !out.Ran || !out.OK {
				t.Fatalf("transactional claim: %+v", out)
			}
		})
		expectInt(t, "no remaining job", PendingJobCount(queue), 0)
		db := database.bound()
		expectInt(t, "no processing job", PgCount(db, "select count(*) from "+db.QualifiedTable(jobsTable)+" where queue=$1", []any{queue.name}), 0)
		EnqueueJob(queue, storeJob{Name: "expired", Count: FromInt64(1)})
		var id, token string
		WithTransaction(func() { id, _, _, token, _ = queue.dequeue(jobPending) })
		PgExec(db, "update "+db.QualifiedTable(jobsTable)+" set lease_until=clock_timestamp()-interval '1 day' where id=$1", []any{id})
		WithTransaction(func() {
			if queue.complete(id, token) {
				t.Fatal("a new transaction revived an expired claim")
			}
		})
	})
}
