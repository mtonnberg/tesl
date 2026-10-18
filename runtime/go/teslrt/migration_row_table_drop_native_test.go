//go:build tesl_migration_test

package teslrt

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"
)

// These are ordinary compiler-emitted applications. V1 alone exposes Archive;
// both revisions use the same surviving Note handlers and physical generation.
func TestPgRowTableDropActualApp(t *testing.T) {
	root := os.Getenv("TESL_ROW_TABLE_DROP_PROGRAMS")
	if root == "" {
		t.Skip("compiler-generated table Drop applications required")
	}
	for _, scenario := range []string{"overlap", "fresh-v2", "dependency", "successor", "unreceipted-drop"} {
		t.Run(scenario, func(t *testing.T) {
			f, request := pgNewWorkerTest(t)
			ctx, cancel := context.WithTimeout(context.Background(), 65*time.Second)
			t.Cleanup(cancel)
			f.ctx, f.namespace = ctx, "notes"
			run := func(version, mode string) { pgForwardNativeRun(t, f, root, version, mode, true) }
			call := func(base, method, path string, status int) string {
				return pgCallRowAccessApp(t, ctx, base, method, path, status)
			}
			noRowWork := func() {
				t.Helper()
				var processing, shards, fabricatedFinality, advanced int
				err := f.worker.QueryRow(ctx, `select
     (select count(*) from notes.tesl_row_processing),
     (select count(*) from notes.tesl_schema_backfill_shards),
     (select count(*) from notes.tesl_row_finality where generation>1),
     (select count(*) from notes.notes where _tesl_v<>1)`).Scan(&processing, &shards, &fabricatedFinality, &advanced)
				if err != nil || processing != 0 || shards != 0 || fabricatedFinality != 0 || advanced != 0 {
					t.Fatal("Drop invented row migration work or advanced surviving generation", processing, shards, fabricatedFinality, advanced, err)
				}
			}
			snapshot := func() string {
				t.Helper()
				var value string
				if err := f.worker.QueryRow(ctx, `select jsonb_build_object(
                 'state',(select to_jsonb(s) from notes.tesl_schema_state s),
                 'contracts',(select jsonb_agg(to_jsonb(c) order by version) from notes.tesl_row_contracts c),
                 'objects',(select jsonb_agg(to_jsonb(o) order by version,ordinal) from notes.tesl_row_contract_objects o),
                 'physical',(select jsonb_agg(to_jsonb(p) order by version) from notes.tesl_row_physical p),
                 'versions',(select jsonb_agg(to_jsonb(v) order by version,step) from notes.tesl_schema_versions v))::text`).Scan(&value); err != nil {
					t.Fatal(err)
				}
				return value
			}
			installed := "v1"
			if scenario == "fresh-v2" {
				installed = "v2"
			}
			run(installed, "install")
			run(installed, "worker")
			var v1 string
			var retiringToken, survivingToken, jobsBefore string
			var retiringSeq, survivingSeq int64
			queueSnapshot := func() string {
				t.Helper()
				var value string
				if err := f.installer.QueryRow(ctx, `select coalesce(jsonb_agg(to_jsonb(j)-'schema_version' order by id),'[]'::jsonb)::text from notes.tesl_jobs j`).Scan(&value); err != nil {
					t.Fatal(err)
				}
				return value
			}
			if scenario != "fresh-v2" {
				run("v2", "worker")
				// Use the compiled queue's protected enqueue/claim API, before
				// starting consumers. Both attempts own genuine V1 payloads.
				for _, id := range []string{"retiring", "surviving", "delayed"} {
					if _, err := request.Exec(ctx, `select notes.tesl_queue_enqueue(1,'Notifications','Notify',$1,jsonb_build_object('text',$1::text))`, id); err != nil {
						t.Fatal(err)
					}
				}
				var claimed string
				if err := request.QueryRow(ctx, `select job_id,token,attempt_seq from notes.tesl_queue_claim(1,'Notifications','pending','old-handler',300000)`).Scan(&claimed, &retiringToken, &retiringSeq); err != nil || claimed != "retiring" {
					t.Fatal("wrong retiring claim", claimed, err)
				}
				if err := request.QueryRow(ctx, `select job_id,token,attempt_seq from notes.tesl_queue_claim(2,'Notifications','pending','current-handler',300000)`).Scan(&claimed, &survivingToken, &survivingSeq); err != nil || claimed != "surviving" {
					t.Fatal("wrong surviving claim", claimed, err)
				}
				if _, err := f.installer.Exec(ctx, `update notes.tesl_jobs set next_attempt_at=clock_timestamp()+interval '1 day' where id='delayed'`); err != nil {
					t.Fatal(err)
				}
				v1 = pgStartRowAccessApp(t, f, root, "v1")
				call(v1, "POST", "/archive", 200)
				call(v1, "POST", "/one", 200)
			}
			v2 := pgStartRowAccessApp(t, f, root, "v2")
			if scenario == "fresh-v2" {
				call(v2, "POST", "/one", 200)
			}
			call(v2, "PUT", "/touch", 200)
			if body := call(v2, "GET", "/all", 200); !strings.Contains(body, `"memo":"touched"`) || !strings.Contains(body, `"id":"one"`) {
				t.Fatal("surviving handler lost data", body)
			}
			var present, index bool
			if err := request.QueryRow(ctx, "select to_regclass('notes.archive') is not null,to_regclass('notes.archive_body') is not null").Scan(&present, &index); err != nil || !present || !index {
				t.Fatal("expansion dropped retained table or ordinary index", present, index, err)
			}
			noRowWork()
			if scenario == "overlap" {
				before := snapshot()
				output := string(pgForwardNativeRun(t, f, root, "v2", "embedded", false))
				if !strings.Contains(output, "Embedded migration topology does not yet support versioned queues") {
					t.Fatal("queue-bearing Embedded Drop did not reach exact topology guard", output)
				}
				if after := snapshot(); after != before {
					t.Fatalf("Embedded refusal mutated durable lifecycle: before %s after %s", before, after)
				}
			}
			if v1 != "" {
				if body := call(v1, "GET", "/archive", 200); !strings.Contains(body, `"body":"retained"`) {
					t.Fatal("old reader lost retained row", body)
				}
				call(v1, "PUT", "/archive", 200)
				if body := call(v1, "GET", "/archive", 200); !strings.Contains(body, `"body":"edited"`) {
					t.Fatal("old writer no longer served during overlap", body)
				}
			}
			if scenario == "unreceipted-drop" {
				// Paired with the overlap crash-after-receipt case: unexplained
				// absence is drift, never an idempotent completed operation.
				if _, err := f.installer.Exec(ctx, "drop table notes.archive restrict"); err != nil {
					t.Fatal(err)
				}
				before := snapshot()
				output := string(pgForwardNativeRun(t, f, root, "v2", "contract", false))
				if !strings.Contains(output, `row baseline table \"archive\" differs`) {
					// JSON command output may escape the quoted table name.
					if !strings.Contains(output, `row baseline table "archive" differs`) {
						t.Fatal("missing unreceipted table refused for unrelated reason", output)
					}
				}
				if after := snapshot(); after != before {
					t.Fatalf("unreceipted absence advanced lifecycle: before %s after %s", before, after)
				}
				var minimum, floor, receipts int
				if err := f.worker.QueryRow(ctx, `select min_version,compat_floor,(select count(*) from notes.tesl_row_contract_objects) from notes.tesl_schema_state`).Scan(&minimum, &floor, &receipts); err != nil || minimum != 1 || floor != 1 || receipts != 0 {
					t.Fatal("unreceipted Drop received retirement authority", minimum, floor, receipts, err)
				}
				return
			}
			if scenario == "successor" {
				before := snapshot()
				output := string(pgForwardNativeRun(t, f, root, "v3", "worker", false))
				if !strings.Contains(output, "schema V3 requires completed Contract V2 before expansion") {
					t.Fatal("successor refused for wrong reason", output)
				}
				if after := snapshot(); after != before {
					t.Fatalf("premature successor changed durable lifecycle: before %s after %s", before, after)
				}
				call(v1, "PUT", "/archive", 200)
				call(v2, "GET", "/all", 200)
			}
			if v1 != "" {
				before, jobs := snapshot(), queueSnapshot()
				output := string(pgForwardNativeRun(t, f, root, "v2", "contract", false))
				if !strings.Contains(output, "retiring queue attempts are still leased") {
					t.Fatal("live old queue claim did not block Drop", output)
				}
				if after, afterJobs := snapshot(), queueSnapshot(); after != before || afterJobs != jobs {
					// The first Contract call registers its reviewed intent before
					// attempting execution. Only that registration may persist.
					var oldState, newState map[string]json.RawMessage
					if err := json.Unmarshal([]byte(before), &oldState); err != nil {
						t.Fatal(err)
					}
					if err := json.Unmarshal([]byte(after), &newState); err != nil {
						t.Fatal(err)
					}
					if string(oldState["contracts"]) != "null" || string(newState["contracts"]) == "null" || afterJobs != jobs {
						t.Fatal("old-claim refusal changed jobs or failed to register reviewed intent")
					}
					for key, value := range oldState {
						if key != "contracts" && string(value) != string(newState[key]) {
							t.Fatalf("old-claim refusal changed %s", key)
						}
					}
				}
				before = snapshot()
				output = string(pgForwardNativeRun(t, f, root, "v2", "contract", false))
				if !strings.Contains(output, "retiring queue attempts are still leased") || snapshot() != before || queueSnapshot() != jobs {
					t.Fatal("registered Contract retry changed lifecycle or jobs", output)
				}
				var completed bool
				if err := request.QueryRow(ctx, `select notes.tesl_queue_complete(1,'Notifications','retiring',$1,$2)`, retiringToken, retiringSeq).Scan(&completed); err != nil || !completed {
					t.Fatal("old handler could not finish before Drop", completed, err)
				}
				jobsBefore = queueSnapshot()
			}
			if scenario == "dependency" {
				// An external view must never be destroyed as a side effect of table Drop.
				if _, err := f.installer.Exec(ctx, "create view public.drop_archive_dependency as select * from notes.archive"); err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() {
					_, _ = f.installer.Exec(context.Background(), "drop view if exists public.drop_archive_dependency")
				})
				snapshot := func() string {
					t.Helper()
					var value string
					if err := f.worker.QueryRow(ctx, `select jsonb_build_object(
                        'state',(select to_jsonb(s) from notes.tesl_schema_state s),
                        'contracts',(select jsonb_agg(to_jsonb(c) order by version) from notes.tesl_row_contracts c),
                        'receipts',(select jsonb_agg(to_jsonb(r) order by version,step) from notes.tesl_schema_versions r))::text`).Scan(&value); err != nil {
						t.Fatal(err)
					}
					return value
				}
				before := snapshot()
				output := string(pgForwardNativeRun(t, f, root, "v2", "contract", false))
				if after := snapshot(); before != after {
					t.Fatalf("dependency refusal mutated floor, intent or receipts:\nbefore %s\nafter %s", before, after)
				}
				if queueSnapshot() != jobsBefore {
					t.Fatal("dependency refusal changed queued jobs")
				}
				if !strings.Contains(output, "depend") {
					t.Fatal("Contract failed for unrelated reason", output)
				}
				var body string
				var contracted int
				if err := f.installer.QueryRow(ctx, "select body from public.drop_archive_dependency where id='old'").Scan(&body); err != nil || body != "edited" {
					t.Fatal("refused dependent Drop changed external view or old data", body, err)
				}
				if err := f.worker.QueryRow(ctx, "select count(*) from notes.tesl_schema_versions where version=2 and step='contracted'").Scan(&contracted); err != nil || contracted != 0 {
					t.Fatal("refused Drop claimed completion", contracted, err)
				}
				if _, err := f.installer.Exec(ctx, "drop view public.drop_archive_dependency"); err != nil {
					t.Fatal(err)
				}
			}
			if scenario == "overlap" {
				// Hold the exact old writer admission fence in a request-role transaction,
				// and prove a real pending Contract cannot retire it before commit.
				tx, err := request.Begin(ctx)
				if err != nil {
					t.Fatal(err)
				}
				defer tx.Rollback(context.Background())
				var fence int
				if err := f.worker.QueryRow(ctx, "select fence_ns from notes.tesl_schema_meta where id=1").Scan(&fence); err != nil {
					t.Fatal(err)
				}
				if _, err := tx.Exec(ctx, "select pg_catalog.pg_advisory_xact_lock_shared($1::integer,1)", fence); err != nil {
					t.Fatal(err)
				}
				if _, err := tx.Exec(ctx, "select notes.tesl_admit(1)"); err != nil {
					t.Fatal(err)
				}
				if _, err := tx.Exec(ctx, "update notes.archive set body='committed-before-drop' where id='old'"); err != nil {
					t.Fatal(err)
				}
				pause := pgPauseConcurrentRowBoundaries(t, []pgExpansionBoundary{{"row-contract-after-receipt", 1}})[0]
				defer pause.resume()
				cmd := pgForwardNativeCommand(f, root, "v2", "contract")
				cmd.Env = append(cmd.Env, "TESL_MIGRATION_TEST_SOCKET="+os.Getenv("TESL_MIGRATION_TEST_SOCKET"))
				process := pgLaunchRepeatedProcess(t, cmd)
				deadline := time.Now().Add(12 * time.Second)
				for {
					var waiting bool
					if err := f.installer.QueryRow(ctx, `select exists(select 1 from pg_locks l join pg_stat_activity a on a.pid=l.pid where l.locktype='advisory' and not l.granted and l.classid=$1::oid and l.objid=1 and a.datname=current_database())`, fence).Scan(&waiting); err != nil {
						t.Fatal(err)
					}
					if waiting {
						break
					}
					select {
					case err := <-process.done:
						t.Fatalf("Contract escaped held old writer fence: %v %s", err, process.output.String())
					default:
					}
					if time.Now().After(deadline) {
						t.Fatal("Contract never waited for old writer", process.output.String())
					}
					time.Sleep(15 * time.Millisecond)
				}
				var floor int
				if err := f.worker.QueryRow(ctx, "select min_version from notes.tesl_schema_state").Scan(&floor); err != nil || floor != 1 {
					t.Fatal("old writer retired before commit", floor, err)
				}
				call(v2, "GET", "/all", 200)
				if err := tx.Commit(ctx); err != nil {
					t.Fatal(err)
				}
				select {
				case <-pause.arrived:
				case err := <-process.done:
					t.Fatal("Contract missed committed drop receipt boundary", err, process.output.String())
				case <-ctx.Done():
					t.Fatal(ctx.Err(), process.output.String())
				}
				if err := request.QueryRow(ctx, "select to_regclass('notes.archive') is null").Scan(&present); err != nil || !present {
					t.Fatal("drop receipt did not commit table absence", present, err)
				}
				if err := cmd.Process.Kill(); err != nil {
					t.Fatal(err)
				}
				select {
				case err := <-process.done:
					if err == nil {
						t.Fatal("killed Contract unexpectedly succeeded")
					}
				case <-ctx.Done():
					t.Fatal(ctx.Err())
				}
				pause.resume()
				// Resume a committed object receipt before Contract completion.
				// A lock-before-receipt executor fails here on the absent table.
				run("v2", "contract")
			} else {
				run("v2", "contract")
			}
			if err := request.QueryRow(ctx, "select to_regclass('notes.archive') is not null,to_regclass('notes.archive_body') is not null").Scan(&present, &index); err != nil || present || index {
				t.Fatal("Contract failed exact table/index removal", present, index, err)
			}
			noRowWork()
			if v1 != "" {
				if after := queueSnapshot(); after != jobsBefore {
					t.Fatal("Drop restamp changed payloads, scheduling or surviving claim", jobsBefore, after)
				}
				var count int
				if err := f.installer.QueryRow(ctx, `select count(*) from notes.tesl_jobs where schema_version=2`).Scan(&count); err != nil || count != 2 {
					t.Fatal("Drop did not restamp every retained job", count, err)
				}
				var completed bool
				if err := request.QueryRow(ctx, `select notes.tesl_queue_complete(2,'Notifications','surviving',$1,$2)`, survivingToken, survivingSeq).Scan(&completed); err != nil || !completed {
					t.Fatal("surviving handler lost its claim across Drop", completed, err)
				}
			}
			call(v2, "PUT", "/touch", 200)
			call(v2, "GET", "/all", 200)
			if v1 != "" {
				call(v1, "GET", "/archive", 503)
				call(v1, "PUT", "/archive", 503)
				call(v1, "GET", "/all", 503)
			}
			// Even a completed table Contract cannot be reused as row finality
			// authority; this protected check precedes the idempotent return.
			before := snapshot()
			_, err := f.worker.Exec(ctx, `select notes.tesl_retire_row_window(2,
             (select contract_hash from notes.tesl_row_contracts where version=2),
             (select artefact_hash from notes.tesl_schema_versions where version=2 and step='retired'),
             $1::text[],$2::smallint[],
             (select compiler_abi from notes.tesl_row_physical where version=2))`, []string{"Archive"}, []int16{2})
			if err == nil || !strings.Contains(err.Error(), "table Contract cannot fabricate row finality") {
				t.Fatal("forged table finality refused for wrong reason", err)
			}
			if after := snapshot(); after != before {
				t.Fatalf("forged finality mutated durable lifecycle: before %s after %s", before, after)
			}
			// Receipt-based resume must not LOCK TABLE the already absent relation.
			run("v2", "contract")
			run("v2", "worker")
			restarted := pgStartRowAccessApp(t, f, root, "v2")
			if body := call(restarted, "GET", "/all", 200); !strings.Contains(body, `"id":"one"`) {
				t.Fatal("restart lost surviving data", body)
			}
			noRowWork()
			if scenario == "successor" {
				run("v3", "worker")
				v3 := pgStartRowAccessApp(t, f, root, "v3")
				if body := call(v3, "GET", "/all", 200); !strings.Contains(body, `"id":"one"`) || !strings.Contains(body, `"memo":"touched"`) {
					t.Fatal("successor lost existing surviving data", body)
				}
				call(v3, "PUT", "/repair", 200)
				if body := call(v2, "GET", "/all", 200); !strings.Contains(body, `"title":"repaired"`) {
					t.Fatal("V2 cannot read V3 write", body)
				}
				call(v2, "PUT", "/touch", 200)
				run("v3", "worker")
				if body := call(v3, "GET", "/all", 200); !strings.Contains(body, `"title":"repaired"`) {
					t.Fatal("repeated successor worker lost current data", body)
				}
				var version int
				if err := request.QueryRow(ctx, "select current,to_regclass('notes.archive') is not null from notes.tesl_schema_state").Scan(&version, &present); err != nil || version != 3 || present {
					t.Fatal("successor failed to advance or resurrected retired table", version, present, err)
				}
				noRowWork()
			}
			if v1 != "" {
				// The ordinary compiled current queue handler decodes the
				// restamped payload and queries Note after Archive is gone.
				if _, err := f.installer.Exec(ctx, `update notes.tesl_jobs set next_attempt_at=clock_timestamp() where id='delayed'`); err != nil {
					t.Fatal(err)
				}
				deadline := time.Now().Add(12 * time.Second)
				for {
					var remaining int
					if err := f.installer.QueryRow(ctx, `select count(*) from notes.tesl_jobs where id='delayed'`).Scan(&remaining); err != nil {
						t.Fatal(err)
					}
					if remaining == 0 {
						break
					}
					if time.Now().After(deadline) {
						t.Fatal("current compiled queue handler could not consume restamped job after Drop")
					}
					time.Sleep(25 * time.Millisecond)
				}
			}
		})
	}
}
