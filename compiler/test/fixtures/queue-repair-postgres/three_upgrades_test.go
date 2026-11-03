package teslqueueconversions

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	rt "tesl.generated/teslmodschemamailmigratehelpers/internal/teslrt"
)

const upgradeStage = 0 // Replaced with the source project's stage by the compiler test.
const upgradeRepairDigest = "@@DIGEST@@"

func runUpgrade(t *testing.T, f *rt.QueueConversionDBFixture, stage int) {
	t.Helper()
	version := stage + 1
	if stage > 1 {
		body := `{"message":"","priority":3}`
		if stage == 3 {
			body = `{"content":"","importance":5,"tag":"v3"}`
		}
		if err := f.EnqueueAt(stage, fmt.Sprintf("rejected-v%d", version), body, "pending", time.Now().UTC()); err != nil {
			t.Fatal(err)
		}
	}
	rejectedID := fmt.Sprintf("rejected-v%d", version)
	var original string
	if err := f.Installer.QueryRow(f.Context, "select payload::text from mail.tesl_jobs where id=$1", rejectedID).Scan(&original); err != nil {
		t.Fatal(err)
	}
	checkRejection := func() {
		var body string
		var stamp int
		if err := f.Installer.QueryRow(f.Context, "select payload::text,schema_version from mail.tesl_jobs where id=$1", rejectedID).Scan(&body, &stamp); err != nil || body != original || stamp != stage {
			t.Fatal("rejection lost historical bytes/version", stage, body, stamp, err)
		}
	}
	progress, err := f.Batch(f.Context, f.Worker, Conversion0, 256)
	wantedRejected := 1
	if stage == 1 {
		wantedRejected = 2
	}
	if err != nil || progress.Selected != stage+2 || progress.Rejected != wantedRejected || !progress.NoEligible {
		t.Fatal("migration did not convert retained jobs", stage, progress, err)
	}
	checkRejection()
	if done, err := f.Retire(f.Worker); err != nil || done {
		t.Fatal("rejection failed to block this edge's retirement", stage, done, err)
	}
	if err := f.Register(f.Installer, Conversion1); err != nil {
		t.Fatal(err)
	}
	progress, err = f.Batch(f.Context, f.Worker, Conversion1, 256)
	if err != nil || progress.Rejected != wantedRejected || progress.Selected != wantedRejected {
		t.Fatal("first repair lost its source rejection", stage, progress, err)
	}
	checkRejection()
	if done, err := f.Retire(f.Worker); err != nil || done {
		t.Fatal("repair rejection failed to block retirement", stage, done, err)
	}
	if err := f.Register(f.Installer, Conversion2); err != nil {
		t.Fatal(err)
	}
	f.RestartWorker(t)
	f.ForgetScope()
	if err := f.Reopen(f.Worker, upgradeRepairDigest); err != nil {
		t.Fatal("new edge's repair history could not reopen", stage, err)
	}
	progress, err = f.Batch(f.Context, f.Worker, Conversion2, 256)
	if err != nil || progress.Converted != wantedRejected || progress.Selected != wantedRejected {
		t.Fatal("second repair failed", stage, progress, err)
	}
	if err := f.Register(f.Installer, Conversion2); err != nil {
		t.Fatal("repair history replay failed", stage, err)
	}
	before := f.Snapshot(t, rejectedID)
	f.RestartWorker(t)
	if result, err := f.Apply(f.Worker, Conversion2, rejectedID); err != nil || !result.Replayed || result.Kind != "converted" {
		t.Fatal("edge repair replay failed after restart", stage, result, err)
	}
	if before != f.Snapshot(t, rejectedID) {
		t.Fatal("replayed repair changed durable outcome", stage)
	}
	if done, err := f.Retire(f.Worker); err != nil || !done {
		t.Fatal("finished edge could not retire", stage, done, err)
	}
	if err := f.EnqueueAt(stage, "old-writer", `{}`, "pending", time.Now().UTC()); err == nil {
		t.Fatal("retired writer enqueued into upgraded queue", stage)
	}
	var stamp int
	var body string
	var due time.Time
	if err := f.Installer.QueryRow(f.Context, "select schema_version,payload::text,next_attempt_at from mail.tesl_jobs where id='carry'").Scan(&stamp, &body, &due); err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := json.Unmarshal([]byte(body), &decoded); err != nil {
		t.Fatal(err)
	}
	wanted := map[string]any{"message": "kept", "priority": float64(7)}
	if stage == 2 {
		wanted = map[string]any{"content": "kept", "importance": float64(17), "tag": "v3"}
	}
	if stage == 3 {
		wanted = map[string]any{"message": "kept", "rank": float64(27), "audit": "v3"}
	}
	for key, value := range wanted {
		if decoded[key] != value {
			t.Fatal("retained job lost migration composition", stage, key, decoded)
		}
	}
	if len(decoded) != len(wanted) || stamp != version || !due.Equal(time.Date(2099, 1, 2, 3, 4, 5, 0, time.UTC)) {
		t.Fatal("wrong target encoding or delayed schedule", stage, stamp, decoded, due)
	}
	raw, err := rt.ParseJSON([]byte(body))
	if err != nil {
		t.Fatal(err)
	}
	if !decodeNew0(raw).OK() || decodeOld0(raw).OK() {
		t.Fatal("upgrade did not exercise incompatible frozen/current codecs", stage)
	}
}

func TestThreeNonAdditiveQueueUpgrades(t *testing.T) {
	if upgradeStage != 1 {
		t.Skip("orchestrated by V1/V2 binary")
	}
	f := rt.OpenQueueConversionRootForTest(t, Conversion0)
	for _, job := range []struct{ id, text, status string }{{"carry", "kept", "pending"}, {"rejected-v2", "", "pending"}, {"dead", "", "dead"}} {
		body := fmt.Sprintf(`{"oldText":%q}`, job.text)
		due := time.Now().UTC()
		if job.id == "carry" {
			due = time.Date(2099, 1, 2, 3, 4, 5, 0, time.UTC)
		}
		if err := f.Enqueue(job.id, body, job.status, due); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := f.Installer.Exec(f.Context, "update mail.tesl_jobs set attempts=7 where id='dead'"); err != nil {
		t.Fatal(err)
	}
	child := func(stage int, probe bool) {
		binary := os.Getenv(fmt.Sprintf("QUEUE_UPGRADE_BINARY_%d", stage))
		if binary == "" {
			t.Fatal("missing separately compiled successor", stage)
		}
		command := exec.CommandContext(f.Context, binary, "-test.run=^TestThreeQueueUpgradesChild$", "-test.v")
		for _, v := range os.Environ() {
			if !strings.HasPrefix(v, "TESL_MIGRATION_TEST_DSN=") && !strings.HasPrefix(v, "TESL_TEST_POSTGRES_SHARED_") {
				command.Env = append(command.Env, v)
			}
		}
		command.Env = append(command.Env, f.UpgradeProcessEnvironment()...)
		if probe {
			command.Env = append(command.Env, "TESL_QUEUE_UPGRADE_PROBE=1")
		}
		output, err := command.CombinedOutput()
		if err != nil {
			t.Fatalf("successor stage %d: %v\n%s", stage, err, output)
		}
		if !strings.Contains(string(output), "--- PASS: TestThreeQueueUpgradesChild") {
			t.Fatalf("successor did not run: %s", output)
		}
	}
	// A new compiled successor must not leap across an unresolved/retiring edge.
	var initial string
	if err := f.Installer.QueryRow(f.Context, "select pg_catalog.to_jsonb(s)::text from mail.tesl_queue_conversion_scope s").Scan(&initial); err != nil {
		t.Fatal(err)
	}
	var installation struct{ Identity string }
	if err := json.Unmarshal([]byte(initial), &installation); err != nil {
		t.Fatal(err)
	}
	child(2, true)
	var after string
	if err := f.Installer.QueryRow(f.Context, "select pg_catalog.to_jsonb(s)::text from mail.tesl_queue_conversion_scope s").Scan(&after); err != nil || after != initial {
		t.Fatal("refused successor altered installation", after, err)
	}
	runUpgrade(t, f, 1)
	var firstReceipt string
	if err := f.Installer.QueryRow(f.Context, "select pg_catalog.to_jsonb(r)::text from mail.tesl_queue_conversion_receipts r join mail.tesl_queue_conversion_sources s on s.digest=r.source_digest where r.job_id='carry' and s.from_version=1 and s.revision=0").Scan(&firstReceipt); err != nil {
		t.Fatal(err)
	}
	child(3, true) // Skipping V3 is refused even after V1 retirement.
	child(2, false)
	child(3, false)
	var retainedReceipt string
	if err := f.Installer.QueryRow(f.Context, "select pg_catalog.to_jsonb(r)::text from mail.tesl_queue_conversion_receipts r join mail.tesl_queue_conversion_sources s on s.digest=r.source_digest where r.job_id='carry' and s.from_version=1 and s.revision=0").Scan(&retainedReceipt); err != nil || retainedReceipt != firstReceipt {
		t.Fatal("later upgrade rewrote V1 conversion history", retainedReceipt, err)
	}
	var from, to, floor, jobs, receipts, sources, payloads int
	var identity string
	if err := f.Installer.QueryRow(f.Context, `select from_version,to_version,floor,identity::text,
 (select count(*) from mail.tesl_jobs),(select count(*) from mail.tesl_queue_conversion_receipts),
 (select count(*) from mail.tesl_queue_conversion_sources),(select count(*) from mail.tesl_queue_payloads)
 from mail.tesl_queue_conversion_scope`).Scan(&from, &to, &floor, &identity, &jobs, &receipts, &sources, &payloads); err != nil {
		t.Fatal(err)
	}
	if from != 3 || to != 4 || floor != 4 || jobs != 5 || receipts != 20 || sources != 9 || payloads != 4 || identity != installation.Identity {
		t.Fatal("three upgrades lost durable history", from, to, floor, identity, jobs, receipts, sources, payloads)
	}
	var attempts, stamp int
	var status string
	if err := f.Installer.QueryRow(f.Context, "select attempts,status,schema_version from mail.tesl_jobs where id='dead'").Scan(&attempts, &status, &stamp); err != nil || attempts != 7 || status != "dead" || stamp != 4 {
		t.Fatal("dead job did not survive all three upgrades", attempts, status, stamp, err)
	}
	if err := f.Reopen(f.Worker, upgradeRepairDigest); err == nil {
		t.Fatal("old binary reopened the V4 active transition")
	}
}

func TestThreeQueueUpgradesChild(t *testing.T) {
	if os.Getenv("TESL_QUEUE_REPAIR_CHILD") != "1" {
		t.Skip("separately compiled successor process")
	}
	f, err := rt.UpgradeQueueProcessForTest(t, Conversion0)
	if os.Getenv("TESL_QUEUE_UPGRADE_PROBE") == "1" {
		if err == nil {
			t.Fatal("unretired or non-adjacent successor installed")
		}
		return
	}
	if err != nil {
		t.Fatal(err)
	}
	// Retrying the same install preserves its root and database identity.
	if err := f.Register(f.Installer, Conversion0); err != nil {
		t.Fatal(err)
	}
	if err := f.ReplayUpgrade(Conversion0); err != nil {
		t.Fatal("adjacent upgrade replay failed", err)
	}
	runUpgrade(t, f, upgradeStage)
}
