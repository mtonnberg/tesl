package teslmodapp

import (
	"fmt"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	schema "tesl.generated/teslmodapp/internal/teslmodschematasksvcurrent"
	"tesl.generated/teslmodapp/internal/teslrt"
)

// Drive the actual emitted HTTP dispatch and body decoder, including the check
// that establishes the nested proof before the emitted handler enqueues a job.
func candidatePost(t *testing.T, endpoint, id, message string, want int) {
	t.Helper()
	body := fmt.Sprintf(`{"id":%q,"message":%q}`, id, message)
	request := httptest.NewRequest("POST", endpoint, strings.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	Web.ServeHTTP(response, request)
	if response.Code != want {
		t.Fatal(endpoint, response.Code, response.Body.String())
	}
}

// The test controls scheduling; both payload branches execute their actual
// compiler-emitted worker bodies, and all codec/claim selection stays runtime-owned.
func candidateWorker(value any) teslrt.JobOutcome {
	switch job := value.(type) {
	case schema.Notify:
		HandleNotify(job)
	case schema.Audit:
		HandleAudit(job)
	default:
		panic(fmt.Sprintf("unexpected emitted payload %T", value))
	}
	return teslrt.JobOutcome{OK: true}
}
func candidateDeadWorker(value any) teslrt.JobOutcome {
	job, ok := value.(schema.Audit)
	if !ok {
		panic(fmt.Sprintf("unexpected dead payload %T", value))
	}
	DeadAudit(job)
	return teslrt.JobOutcome{OK: true}
}
func TestCompiledCandidateApplication(t *testing.T) {
	for _, path := range []string{"../../queue-history.json", "../../migration-history.json"} {
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Fatal("loose metadata must be absent", path, err)
		}
	}
	// This must fail before serving, connecting, starting workers or sealing the
	// declarations. The test bridge below is deliberately not production Main.
	if refusal := teslrt.CandidatePanicForTest(func() { Main() }); !strings.Contains(refusal, "Worker migration topology does not yet support") {
		t.Fatal("public Main unexpectedly enabled candidate queues", refusal)
	}
	codecs, err := teslrt.QueueSourceCodecs(TasksQueue)
	if err != nil || len(codecs) != 2 || codecs[0].Job != "Audit" || codecs[1].Job != "Notify" {
		t.Fatal("emitted identities", codecs, err)
	}
	f := teslrt.OpenCompiledCandidateForTest(t, StoreDatabase)
	f.Bind(func() {
		if refusal := teslrt.CandidatePanicForTest(func() { Main() }); !strings.Contains(refusal, "Worker migration topology does not yet support") {
			t.Fatal("installed candidate enabled public Main", refusal)
		}
		t.Run("HTTP handlers and both emitted codecs", func(t *testing.T) {
			candidatePost(t, "/notify", "invalid-http", "", 400)
			if teslrt.PendingJobCount(TasksQueue).String() != "0" {
				t.Fatal("rejected check enqueued bytes")
			}
			candidatePost(t, "/notify", "notice", "nested 雪", 200)
			candidatePost(t, "/audit", "audit", "ordinary", 200)
			if n := f.Number(t, "select count(*) from queued_app.tesl_jobs where queue='Notifications' and schema_version=1"); n != 2 {
				t.Fatal("wire identity or stamp", n)
			}
			payload := f.Text(t, "select payload::text from queued_app.tesl_jobs where job_type='Notify'")
			if !strings.Contains(payload, `"detail": {"text": "nested 雪"}`) {
				t.Fatal("actual nested encoder", payload)
			}
			for range 2 {
				if result := teslrt.ProcessNextJob(TasksQueue, candidateWorker); !result.Ran || !result.OK {
					t.Fatal(result)
				}
			}
			if n := f.Number(t, "select count(*) from queued_app.receipts where (id='notice' and label='nested 雪') or (id='audit' and label='ordinary')"); n != 2 {
				t.Fatal("actual worker database effects", n)
			}
			if teslrt.PendingJobCount(TasksQueue).String() != "0" {
				t.Fatal("completed jobs remain")
			}
		})
		t.Run("nested shape and proof rejection preserve bytes", func(t *testing.T) {
			for _, bad := range []struct{ id, json string }{
				{"wrong-shape", `{"id":"wrong-shape","detail":{"text":42}}`},
				{"unproven", `{"id":"unproven","detail":{"text":""}}`},
			} {
				candidatePost(t, "/notify", bad.id, "accepted before corruption", 200)
				jobID := f.Text(t, "select id from queued_app.tesl_jobs where job_type='Notify' and status='pending'")
				before := f.CorruptPayloadForTest(t, jobID, bad.json)
				candidatePost(t, "/audit", "after-"+bad.id, "valid second codec", 200)
				result := teslrt.ProcessNextJob(TasksQueue, candidateWorker)
				if !result.Ran || !result.OK {
					t.Fatal("quarantine did not continue to next valid codec", result)
				}
				if n := f.Number(t, "select count(*) from queued_app.receipts where id=$1", bad.id); n != 0 {
					t.Fatal("invalid payload reached actual worker", n)
				}
				if got := f.Text(t, "select payload::text from queued_app.tesl_jobs where id=$1", jobID); got != before {
					t.Fatal("quarantine rewrote original JSON", before, got)
				}
				var found bool
				for _, job := range teslrt.DeadJobs(TasksQueue) {
					if teslrt.DeadJobID(job) != jobID {
						continue
					}
					found = true
					source, known := teslrt.DeadJobSourceVersion(job).Value()
					kind, typed := teslrt.DeadJobTypeName(job).Value()
					if !known || source.String() != "1" || !typed || kind != "Notify" || teslrt.DeadJobReasonOf(job).Tag != teslrt.DeadJobReasonPayloadInvalid || teslrt.Requeue(job) {
						t.Fatal("untyped or retryable quarantine", job)
					}
				}
				if !found {
					t.Fatal("missing quarantine metadata")
				}
			}
			if result := teslrt.ProcessNextDeadJob(TasksQueue, candidateDeadWorker); result.Ran {
				t.Fatal("quarantine reached dead worker", result)
			}
		})
		t.Run("actual failing worker retries then dead letter", func(t *testing.T) {
			candidatePost(t, "/audit", "retry", "fail", 200)
			for attempt := 1; attempt <= 2; attempt++ {
				result := teslrt.ProcessNextJob(TasksQueue, candidateWorker)
				if !result.Ran || result.OK || !strings.Contains(result.Message, "retry this audit") {
					t.Fatal("actual worker failure", result)
				}
				if n := f.Number(t, "select attempts from queued_app.tesl_jobs where job_type='Audit' and payload->>'id'='retry'"); n != attempt {
					t.Fatal("stored attempts", n, attempt)
				}
			}
			var retry teslrt.DeadJob
			for _, job := range teslrt.DeadJobs(TasksQueue) {
				if kind, known := teslrt.DeadJobTypeName(job).Value(); known && kind == "Audit" {
					retry = job
				}
			}
			if teslrt.DeadJobReasonOf(retry).Tag != teslrt.DeadJobReasonAttemptsExhausted || teslrt.DeadJobAttempts(retry).String() != "2" || !teslrt.Requeue(retry) || teslrt.Requeue(retry) {
				t.Fatal("live retry metadata", retry)
			}
			for range 2 {
				teslrt.ProcessNextJob(TasksQueue, candidateWorker)
			}
			if out := teslrt.ProcessNextDeadJob(TasksQueue, candidateDeadWorker); !out.Ran || !out.OK {
				t.Fatal("actual dead worker", out)
			}
			if n := f.Number(t, "select count(*) from queued_app.receipts where id='dead-retry' and label='fail'"); n != 1 {
				t.Fatal("dead worker effect", n)
			}
		})
		t.Run("handler enqueue and worker effects share transactions", func(t *testing.T) {
			candidatePost(t, "/notify", "rollback-enqueue", "valid", 409)
			if teslrt.PendingJobCount(TasksQueue).String() != "0" {
				t.Fatal("handler enqueue escaped its compiled transaction rollback")
			}
			candidatePost(t, "/notify", "transaction", "atomic", 200)
			before := f.Text(t, "select row_to_json(j)::text from queued_app.tesl_jobs j where status='pending'")
			failure := teslrt.CandidatePanicForTest(func() {
				teslrt.WithTransaction(func() {
					out := teslrt.ProcessNextJob(TasksQueue, candidateWorker)
					if !out.OK {
						panic("worker did not succeed")
					}
					panic("rollback worker")
				})
			})
			if failure != "rollback worker" {
				t.Fatal(failure)
			}
			if n := f.Number(t, "select count(*) from queued_app.receipts where id='transaction'"); n != 0 {
				t.Fatal("worker business effect escaped rollback", n)
			}
			if after := f.Text(t, "select row_to_json(j)::text from queued_app.tesl_jobs j where status='pending'"); after != before {
				t.Fatal("claim or completion escaped rollback", before, after)
			}
			teslrt.WithTransaction(func() {
				if out := teslrt.ProcessNextJob(TasksQueue, candidateWorker); !out.Ran || !out.OK {
					t.Fatal(out)
				}
			})
			if n := f.Number(t, "select count(*) from queued_app.receipts where id='transaction' and label='atomic'"); n != 1 {
				t.Fatal("committed business effect", n)
			}
			if teslrt.PendingJobCount(TasksQueue).String() != "0" {
				t.Fatal("committed completion missing")
			}
		})
		if n := f.Number(t, "select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='queued_app' and c.relname like 'tesl_pubsub%'"); n != 0 {
			t.Fatal("queue app bootstrapped SSE storage", n)
		}
	})
}
