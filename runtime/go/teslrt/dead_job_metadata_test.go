package teslrt

import (
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

func TestDeadJobMetadataReasonAndProvenance(t *testing.T) {
	for _, test := range []struct {
		reason string
		tag    DeadJobReasonTag
	}{
		{"attempts-exhausted", DeadJobReasonAttemptsExhausted},
		{"payload-invalid", DeadJobReasonPayloadInvalid},
		{"migration-rejected", DeadJobReasonMigrationRejected},
		{"legacy-unresolved", DeadJobReasonLegacyUnresolved},
	} {
		t.Run(test.reason, func(t *testing.T) {
			name := "Schema.Tasks.Send"
			version := int32(12)
			job, err := deadJobFromMetadata(nil, "opaque-id", &name, &version, 3, test.reason)
			if err != nil {
				t.Fatal(err)
			}
			name = "changed"
			version = 99
			if DeadJobID(job) != "opaque-id" || DeadJobReasonOf(job).Tag != test.tag || DeadJobAttempts(job).String() != "3" {
				t.Fatalf("wrong metadata: %+v", job)
			}
			gotName, ok := DeadJobTypeName(job).Value()
			if !ok || gotName != "Schema.Tasks.Send" {
				t.Fatal(gotName, ok)
			}
			gotVersion, ok := DeadJobSourceVersion(job).Value()
			if !ok || gotVersion.String() != "12" {
				t.Fatal(gotVersion, ok)
			}
		})
	}
	for _, reason := range []string{"", "unknown", "PayloadInvalid", " payload-invalid", "payload-invalid ", "payload_invalid", "attempts-exhausted\x00"} {
		if _, err := deadJobFromMetadata(nil, "id", nil, nil, 0, reason); err == nil {
			t.Errorf("accepted reason %q", reason)
		}
	}
	for _, version := range []int32{-1, 0, 2147483647} {
		if _, err := deadJobFromMetadata(nil, "id", nil, &version, 0, "attempts-exhausted"); err == nil {
			t.Errorf("accepted source version %d", version)
		}
	}
	if _, err := deadJobFromMetadata(nil, "", nil, nil, 0, "attempts-exhausted"); err == nil {
		t.Fatal("accepted empty ID")
	}
	if _, err := deadJobFromMetadata(nil, "id", nil, nil, -1, "attempts-exhausted"); err == nil {
		t.Fatal("accepted negative attempts")
	}
	job, err := deadJobFromMetadata(nil, "id", nil, nil, 0, "legacy-unresolved")
	if err != nil {
		t.Fatal(err)
	}
	if DeadJobSourceVersion(job).IsSomething() || DeadJobTypeName(job).IsSomething() {
		t.Fatal("invented source provenance")
	}
	if DeadJobReasonOf(DeadJob{}).Tag != DeadJobReasonLegacyUnresolved || Requeue(DeadJob{}) {
		t.Fatal("zero metadata became retryable")
	}
}

func TestDeadJobMemoryMetadataAndRequeue(t *testing.T) {
	queue := NewQueue("metadata", 2)
	id := Enqueue(queue, emailJob{Recipient: "private payload"})
	for range 2 {
		ProcessNextJob(queue, func(any) JobOutcome { return JobOutcome{Message: "failed"} })
	}
	entries := DeadJobs(queue)
	if len(entries) != 1 {
		t.Fatal(entries)
	}
	job := entries[0]
	if DeadJobID(job) != id || DeadJobReasonOf(job).Tag != DeadJobReasonAttemptsExhausted || DeadJobAttempts(job).String() != "2" {
		t.Fatal(job)
	}
	if DeadJobTypeName(job).IsSomething() || DeadJobSourceVersion(job).IsSomething() {
		t.Fatal("Memory invented a wire identity or version")
	}
	for _, reason := range []string{"payload-invalid", "migration-rejected", "legacy-unresolved"} {
		quarantine, err := deadJobFromMetadata(queue, id, nil, nil, 2, reason)
		if err != nil {
			t.Fatal(err)
		}
		if Requeue(quarantine) {
			t.Fatalf("requeued quarantine %s", reason)
		}
	}
	if len(DeadJobs(queue)) != 1 || PendingJobCount(queue).String() != "0" {
		t.Fatal("refusal mutated the queue")
	}
	if !Requeue(job) {
		t.Fatal("ordinary exhausted job could not be requeued")
	}
	if len(DeadJobs(queue)) != 0 || PendingJobCount(queue).String() != "1" {
		t.Fatal("retryable job did not move")
	}
	if DeadJobAttempts(job).String() != "2" {
		t.Fatal("returned metadata was mutated by requeue")
	}
}

func TestDurableDeadJobMetadataQuarantinesAndStaleRequeue(t *testing.T) {
	database := storeDatabase(t, "DeadMetadata")
	queue := NewQueueOn(database, uniqueName("dead_metadata"), 1, "", 0)
	registerStoreJobCodec(queue)
	WithDatabase(database, func() {
		ResetQueue(queue)
		db := database.bound()
		table := db.QualifiedTable(jobsTable)
		for _, test := range []struct{ name, kind, payload string }{
			{"missing codec", "UnknownHistoricalType", `{}`},
			{"malformed known payload", "storeJob", `{"name":42,"count":"not-an-int"}`},
		} {
			t.Run(test.name, func(t *testing.T) {
				id := UUIDv7()
				// The actual registered identity is authoritative; do not guess its case.
				kind := test.kind
				if test.name == "malformed known payload" {
					kind = queue.backend.(*pgQueueBackend).codecs[0].typeName
				}
				PgExec(db, "insert into "+table+" (id,queue,job_type,payload,status) values($1,$2,$3,$4::jsonb,'pending')", []any{id, queue.name, kind, test.payload})
				output := captureStderr(t, func() {
					if out := ProcessNextJob(queue, okJob); out.Ran {
						t.Fatal("quarantine was dispatched")
					}
				})
				if !strings.Contains(output, "quarantined") {
					t.Fatal(output)
				}
				var found *DeadJob
				for _, entry := range DeadJobs(queue) {
					if DeadJobID(entry) == id {
						found = &entry
						break
					}
				}
				if found == nil {
					t.Fatal("quarantined entry omitted")
				}
				if DeadJobReasonOf(*found).Tag != DeadJobReasonLegacyUnresolved || DeadJobSourceVersion(*found).IsSomething() {
					t.Fatal("legacy quarantine falsely classified", found)
				}
				name, ok := DeadJobTypeName(*found).Value()
				if !ok || name != kind {
					t.Fatal(name, ok, kind)
				}
				if Requeue(*found) {
					t.Fatal("quarantine requeued")
				}
				if out := ProcessNextDeadJob(queue, okJob); out.Ran {
					t.Fatal("quarantine reached dead worker")
				}
			})
		}
		id := Enqueue(queue, storeJob{Name: "retry", Count: FromInt64(1)})
		ProcessNextJob(queue, failJob)
		var stale DeadJob
		for _, entry := range DeadJobs(queue) {
			if entry.ID == id {
				stale = entry
			}
		}
		if stale.ID != id || DeadJobReasonOf(stale).Tag != DeadJobReasonAttemptsExhausted || DeadJobAttempts(stale).String() != "1" {
			t.Fatal(stale)
		}
		if !Requeue(stale) {
			t.Fatal("ordinary exhausted job could not retry")
		}
		ProcessNextJob(queue, failJob)
		PgExec(db, "update "+table+" set next_attempt_at='infinity'::timestamptz where id=$1", []any{id})
		snapshot := func() string {
			rows := PgQuery(db, "select row_to_json(j)::text from "+table+" j where id=$1", []any{id}, func(row pgx.CollectableRow) (string, error) {
				var value string
				err := row.Scan(&value)
				return value, err
			})
			if len(rows) != 1 {
				t.Fatal("quarantined row disappeared", rows)
			}
			return rows[0]
		}
		before := snapshot()
		if Requeue(stale) {
			t.Fatal("stale retryable DTO overrode current quarantine")
		}
		if after := snapshot(); after != before {
			t.Fatal("refused stale requeue changed retained row", before, after)
		}
		if PendingJobCount(queue).String() != "0" {
			t.Fatal("refused requeue made pending work")
		}
	})
}
