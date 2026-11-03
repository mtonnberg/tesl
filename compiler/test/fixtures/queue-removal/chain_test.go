package teslmodtodoapp

import (
	"context"
	"os"
	"strconv"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

// All four executables are actual compiler output. V4 owns the full history;
// selecting V3 below never changes that binary's registered source version/ABI.
func (f *removalFixture) chainState(current, minimum int) {
	f.t.Helper()
	var got, low, floor int
	if err := f.db.QueryRow(f.ctx, "select current,min_version,compat_floor from todo.tesl_schema_state").Scan(&got, &low, &floor); err != nil || got != current || low != minimum || floor != minimum {
		f.t.Fatalf("state %d/%d/%d want %d/%d: %v", got, low, floor, current, minimum, err)
	}
}

func (f *removalFixture) chainInstall(version int) {
	f.run(f.command(version, f.cfg.User, "app", "--schema", "install", "--worker", f.worker, "--request", f.requestRole))
}

func (f *removalFixture) chainEnqueue(version int, queue, id string) {
	f.t.Helper()
	job := "Keep"
	if queue == "Notifications" {
		job = "Notify"
	}
	var got string
	if err := f.request.QueryRow(f.ctx, `select todo.tesl_queue_enqueue($1,$2,$3,$4,'{"text":"survives all steps"}'::jsonb)`, version, queue, job, id).Scan(&got); err != nil || got != id {
		f.t.Fatal(got, err)
	}
}

func (f *removalFixture) chainClaim(version int, queue string) removalClaim {
	f.t.Helper()
	var c removalClaim
	if err := f.request.QueryRow(f.ctx, "select * from todo.tesl_queue_claim($1,$2,'pending','chain-worker',300000)", version, queue).Scan(&c.id, &c.job, &c.payload, &c.version, &c.attempts, &c.token, &c.seq); err != nil {
		f.t.Fatal(err)
	}
	return c
}

func (f *removalFixture) chainComplete(version int, queue string, c removalClaim) {
	f.t.Helper()
	var done bool
	if err := f.request.QueryRow(f.ctx, "select todo.tesl_queue_complete($1,$2,$3,$4,$5)", version, queue, c.id, c.token, c.seq).Scan(&done); err != nil || !done {
		f.t.Fatal(done, err)
	}
}

func (f *removalFixture) chainStart(version int) {
	f.chainInstall(version)
	f.run(f.command(version, f.worker, "app", "--schema", "catch-up"))
}

func (f *removalFixture) chainNoRemovalPublished() {
	f.t.Helper()
	var count int
	if err := f.db.QueryRow(f.ctx, `select
 (select count(*) from todo.tesl_row_physical where version>=3)+
 (select count(*) from todo.tesl_queue_versions where version>=3)+
 (select count(*) from todo.tesl_row_queue_retirements)+
 (select count(*) from todo.tesl_row_queue_removal_restamps)`).Scan(&count); err != nil || count != 0 {
		f.t.Fatal("blocked removal published a partial target/receipt/audit", count, err)
	}
}

func (f *removalFixture) chainReplayWithLaterClaim() {
	f.t.Helper()
	f.chainEnqueue(4, "Survivors", "v4-live")
	c := f.chainClaim(4, "Survivors")
	if c.version != 4 {
		f.t.Fatal("expected actual V4 payload/claim", c)
	}
	before := f.snapshot()
	f.run(f.command(4, f.worker, "app", "--schema", "contract", "V3"))
	f.chainState(4, 3)
	if before != f.snapshot() {
		f.t.Fatal("historical replay changed later admitted claim or floors")
	}
	// Closing the additive suffix is a separate established operation. Removal
	// replay after it must retain floor 4, the V4 token, and original receipt ABI.
	f.run(f.command(4, f.worker, "app", "--schema", "close-epoch", "--through", "V4"))
	f.chainState(4, 4)
	before = f.snapshot()
	f.run(f.command(4, f.worker, "app", "--schema", "contract", "V3"))
	f.run(f.command(4, f.worker, "app", "--schema", "catch-up"))
	f.chainInstall(4)
	f.chainState(4, 4)
	if before != f.snapshot() {
		f.t.Fatal("replay rewrote a completed historical receipt or lowered later floor")
	}
	f.chainComplete(4, "Survivors", c)
}

func TestQueueRemovalChainBlockedResumeAndHistoricalCatchup(t *testing.T) {
	for _, historical := range []bool{false, true} {
		t.Run(strconv.FormatBool(historical), func(t *testing.T) {
			f := newRemovalFixture(t, false)
			f.chainStart(1)
			if _, err := f.request.Exec(f.ctx, "insert into todo.notes(id,title) values('original','retained row')"); err != nil {
				t.Fatal(err)
			}
			f.chainEnqueue(1, "Notifications", "blocked-v1")
			f.chainEnqueue(1, "Survivors", "survivor-v1")
			if historical {
				f.chainStart(2)
			}
			f.chainInstall(4) // May stage V3 before its real V2 predecessor exists.
			out, err := f.command(4, f.worker, "app", "--schema", "catch-up").CombinedOutput()
			if err == nil || !strings.Contains(string(out), "RemoveEmpty blocked") {
				t.Fatalf("expected removal blocker: %v\n%s", err, out)
			}
			f.chainState(2, 1) // No preliminary close-epoch may advance this floor.
			f.chainNoRemovalPublished()
			var stamp int
			if err := f.db.QueryRow(f.ctx, "select schema_version from todo.tesl_jobs where id='survivor-v1'").Scan(&stamp); err != nil || stamp != 1 {
				t.Fatal("blocked check restamped survivor", stamp, err)
			}
			f.chainEnqueue(2, "Notifications", "blocked-v2")
			f.chainEnqueue(2, "Survivors", "survivor-v2")
			before := f.snapshot()
			if _, err := f.command(4, f.worker, "app", "--schema", "catch-up").CombinedOutput(); err == nil {
				t.Fatal("nonempty predecessor admitted")
			}
			if before != f.snapshot() {
				t.Fatal("repeat refusal changed jobs or history")
			}
			// Resolve removed jobs through protected claim/completion, not test DELETE.
			for i := 0; i < 2; i++ {
				f.chainComplete(2, "Notifications", f.chainClaim(2, "Notifications"))
			}
			var originalABI string
			if err := f.db.QueryRow(f.ctx, "select compiler_abi from todo.tesl_row_physical where version=2").Scan(&originalABI); err != nil {
				t.Fatal(err)
			}
			f.run(f.command(4, f.worker, "app", "--schema", "catch-up"))
			f.chainState(4, 3)
			var valid bool
			if err := f.db.QueryRow(f.ctx, `select
 (select count(*)=4 from todo.tesl_row_physical) and
 (select count(*)=4 from todo.tesl_queue_versions) and
 (select compiler_abi=$1 from todo.tesl_row_physical where version=2) and
 (select count(*)=1 from todo.tesl_row_queue_retirements where version=3) and
 (select count(*)=2 from todo.tesl_row_queue_removal_restamps where to_version=3 and
  ((job_id='survivor-v1' and from_version=1) or (job_id='survivor-v2' and from_version=2))) and
 (select count(*)=2 from todo.tesl_jobs where schema_version=3 and payload='{"text":"survives all steps"}'::jsonb) and
 (select title='retained row' and detail is null and tag is null from todo.notes where id='original')`, originalABI).Scan(&valid); err != nil || !valid {
				t.Fatal("real prefix, audit, payloads or additive suffix lost", valid, err)
			}
			for _, version := range []int{1, 2} {
				if _, err := f.request.Exec(f.ctx, "select todo.tesl_queue_enqueue($1,'Notifications','Notify','late','{}'::jsonb)", version); err == nil {
					t.Fatal("old producer admitted", version)
				}
			}
			for i := 0; i < 2; i++ {
				f.chainComplete(4, "Survivors", f.chainClaim(4, "Survivors"))
			}
			// Ordinary additive job membership is allowed on either side of removal.
			// The removed Notify identity itself cannot be resurrected or moved.
			for _, job := range []string{"Early", "Later"} {
				var id string
				if err := f.request.QueryRow(f.ctx, `select todo.tesl_queue_enqueue(4,'Survivors',$1,$2,'{"text":"new identity"}'::jsonb)`, job, "added-"+job).Scan(&id); err != nil {
					t.Fatal(err)
				}
				c := f.chainClaim(4, "Survivors")
				if c.job != job {
					t.Fatal("additive job identity lost", c)
				}
				f.chainComplete(4, "Survivors", c)
			}
			f.chainReplayWithLaterClaim()
		})
	}
}

func TestQueueRemovalChainAlreadyRemovedPrefix(t *testing.T) {
	f := newRemovalFixture(t, false)
	f.chainStart(1)
	f.chainStart(2)
	f.chainStart(3) // Actual V3 executable, not a V4 binary relabelled as V3.
	f.chainEnqueue(3, "Survivors", "v3-live")
	c := f.chainClaim(3, "Survivors")
	var before string
	query := "select to_jsonb(j)::text from todo.tesl_jobs j where id='v3-live'"
	if err := f.db.QueryRow(f.ctx, query).Scan(&before); err != nil {
		t.Fatal(err)
	}
	f.chainStart(4)
	f.chainState(4, 3)
	var after string
	if err := f.db.QueryRow(f.ctx, query).Scan(&after); err != nil || before != after {
		t.Fatal("additive suffix disturbed admitted V3 claim", err)
	}
	f.run(f.command(4, f.worker, "app", "--schema", "contract", "V3"))
	if err := f.db.QueryRow(f.ctx, query).Scan(&after); err != nil || before != after {
		t.Fatal("historical removal replay disturbed V3 claim", err)
	}
	f.chainComplete(3, "Survivors", c)
	f.chainReplayWithLaterClaim()
}

func TestQueueRemovalChainFreshLatest(t *testing.T) {
	f := newRemovalFixture(t, false)
	cmd := f.command(4, f.requestRole, "app", "--schema", "deploy", "--json")
	worker := f.cfg.Copy()
	worker.User = f.worker
	cmd.Env = append(cmd.Env, "Q_DDL="+removalDSN(worker), "TESL_SCHEMA_INSTALLER_DSN="+removalDSN(f.cfg))
	f.run(cmd)
	f.chainState(4, 3)
	var versions []int
	if err := f.db.QueryRow(f.ctx, "select array_agg(version order by version) from todo.tesl_row_physical").Scan(&versions); err != nil || len(versions) != 4 || versions[0] != 1 || versions[3] != 4 {
		t.Fatal("fresh latest fabricated its origin", versions, err)
	}
	f.chainReplayWithLaterClaim()
}

func TestQueueRemovalChainProtectedBindingAndAllFences(t *testing.T) {
	f := newRemovalFixture(t, false)
	f.chainStart(1)
	f.chainStart(2)
	f.chainInstall(4)
	cfg := f.cfg.Copy()
	cfg.User = f.worker
	worker, err := pgx.ConnectConfig(f.ctx, cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer worker.Close(context.Background())
	var uuid, digest, abi, source string
	var fence int
	if err := f.db.QueryRow(f.ctx, `select m.database_uuid::text,m.fence_ns,t.contract_hash,t.compiler_abi,r.source::text
 from todo.tesl_schema_meta m cross join todo.tesl_row_queue_target_staging t
 join todo.tesl_row_queue_removal_staging r on r.version=t.version where t.version=3`).Scan(&uuid, &fence, &digest, &abi, &source); err != nil {
		t.Fatal(err)
	}
	refuse := func(versions []int, target int, sourceABI string, missing ...int) {
		t.Helper()
		before := f.snapshot()
		tx, err := worker.Begin(f.ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer tx.Rollback(f.ctx)
		for _, version := range versions {
			for _, domain := range []int{fence, -fence} {
				if len(missing) == 2 && missing[0] == domain && missing[1] == version {
					continue
				}
				if _, err := tx.Exec(f.ctx, "select pg_advisory_xact_lock($1::integer,$2::integer)", domain, version); err != nil {
					t.Fatal(err)
				}
			}
		}
		if _, err := tx.Exec(f.ctx, "select todo.tesl_remove_empty_queue($1,$2,$3,$4,$5)", uuid, fence, digest, sourceABI, target); err == nil {
			t.Fatal("forged or incompletely fenced removal accepted", versions, target)
		}
		_ = tx.Rollback(f.ctx)
		f.chainState(2, 1)
		f.chainNoRemovalPublished()
		if before != f.snapshot() {
			t.Fatal("protected refusal mutated history")
		}
	}
	refuse([]int{2}, 3, abi) // V1 producers are still admitted.
	refuse([]int{1}, 3, abi) // V2 producers are also admitted.
	for _, version := range []int{1, 2} {
		for _, domain := range []int{fence, -fence} {
			refuse([]int{1, 2}, 3, abi, domain, version)
		}
	}
	refuse([]int{1, 2}, 2, abi)
	refuse([]int{1, 2}, 4, abi)
	refuse([]int{1, 2}, 3, "tesl-source-abi-v1:"+strings.Repeat("0", 64))
	// Replace the true predecessor snapshot with V1 while retaining a real
	// staged V3 decision. The mutation function itself must reject it.
	if _, err := f.db.Exec(f.ctx, `update todo.tesl_row_queue_removal_staging set source=jsonb_set(source,'{oldSchema}',
 to_jsonb((select schema_snapshot_hash from todo.tesl_queue_versions where version=1))) where version=3`); err != nil {
		t.Fatal(err)
	}
	refuse([]int{1, 2}, 3, abi)
	if _, err := f.db.Exec(f.ctx, "update todo.tesl_row_queue_removal_staging set source=$1::jsonb where version=3", source); err != nil {
		t.Fatal(err)
	}
	// A real adjacent predecessor is not enough if an earlier prefix member was
	// substituted. The receipt pins all version/physical/source-inventory tuples.
	if _, err := f.db.Exec(f.ctx, `update todo.tesl_row_queue_removal_staging set source=jsonb_set(source,'{prefix,0,1}',
 to_jsonb((select contract_hash from todo.tesl_row_physical where version=2))) where version=3`); err != nil {
		t.Fatal(err)
	}
	refuse([]int{1, 2}, 3, abi)
	if _, err := f.db.Exec(f.ctx, "update todo.tesl_row_queue_removal_staging set source=$1::jsonb where version=3", source); err != nil {
		t.Fatal(err)
	}
	f.run(f.command(4, f.worker, "app", "--schema", "catch-up"))
	f.chainState(4, 3)
}

func TestQueueRemovalChainWitnessesPresent(t *testing.T) {
	for version := 1; version <= 4; version++ {
		if os.Getenv("QUEUE_REMOVAL_V"+strconv.Itoa(version)) == "" {
			t.Fatal("missing actual compiled witness", version)
		}
	}
}

func TestQueueRemovalChainOlderProducerAndClaimRace(t *testing.T) {
	for _, kind := range []string{"producer", "claim"} {
		t.Run(kind, func(t *testing.T) {
			f := newRemovalFixture(t, false)
			f.chainStart(1)
			f.chainStart(2)
			f.chainInstall(4)
			if kind == "claim" {
				f.chainEnqueue(1, "Survivors", "old-claim")
			}
			tx, err := f.request.Begin(f.ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer tx.Rollback(f.ctx)
			if kind == "producer" {
				f.enqueue(tx, "Notifications", "old-producer")
			} else {
				var c removalClaim
				if err := tx.QueryRow(f.ctx, "select * from todo.tesl_queue_claim(1,'Survivors','pending','old-worker',300000)").Scan(&c.id, &c.job, &c.payload, &c.version, &c.attempts, &c.token, &c.seq); err != nil {
					t.Fatal(err)
				}
			}
			cmd := f.command(4, f.worker, "app", "--schema", "catch-up")
			arrived, resume := removalGate(t, cmd, "row-epoch-compatibility-busy")
			done, output := startRemoval(t, cmd)
			waitRemovalGate(t, arrived, done, output)
			if err := tx.Commit(f.ctx); err != nil {
				t.Fatal(err)
			}
			before := f.snapshot()
			resume()
			if err := <-done; err == nil || !strings.Contains(output.String(), "RemoveEmpty blocked") {
				t.Fatalf("missed V1 %s behind V2: %v\n%s", kind, err, output.String())
			}
			f.chainState(2, 1)
			f.chainNoRemovalPublished()
			if before != f.snapshot() {
				t.Fatal("older writer/claim raced past removal preflight")
			}
		})
	}
}
