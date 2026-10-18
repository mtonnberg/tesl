package teslrt

// Negative witnesses for the still-refused promotion writer. An EXPLAIN result
// is not a capability to execute that same plan later, even on one transaction.
// Keep these tests independent of any future guard implementation: passing them
// does NOT implement or authorize promotion.
import (
	"context"
	"encoding/json"
	"fmt"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

type stageProbeWitnessPlan struct {
	Kind    string                  `json:"Node Type"`
	Index   string                  `json:"Index Name"`
	Removed float64                 `json:"Rows Removed by Filter"`
	Plans   []stageProbeWitnessPlan `json:"Plans"`
}

func stageProbeWitnessExplain(t *testing.T, ctx context.Context, tx pgx.Tx, analyze bool) stageProbeWitnessPlan {
	t.Helper()
	options := "format json, costs false"
	if analyze {
		options += ", analyze true, timing false"
	}
	var raw []byte
	if err := tx.QueryRow(ctx, "explain ("+options+") execute stage_probe(-1)").Scan(&raw); err != nil {
		t.Fatal(err)
	}
	var result []struct{ Plan stageProbeWitnessPlan }
	if err := json.Unmarshal(raw, &result); err != nil || len(result) != 1 {
		t.Fatal("explain result", string(raw), err)
	}
	t.Log(string(raw))
	return result[0].Plan
}

func stageProbeWitnessContains(plan stageProbeWitnessPlan, kind, index string) bool {
	if plan.Kind == kind && (index == "" || plan.Index == index) {
		return true
	}
	for _, child := range plan.Plans {
		if stageProbeWitnessContains(child, kind, index) {
			return true
		}
	}
	return false
}

func stageProbeWitnessFilteredRows(plan stageProbeWitnessPlan) float64 {
	count := plan.Removed
	for _, child := range plan.Plans {
		count += stageProbeWitnessFilteredRows(child)
	}
	return count
}

func stageProbeWitnessSetup(t *testing.T) *pgControlTestFixture {
	t.Helper()
	f := pgNewControlTest(t)
	f.install(t, 1)
	f.call(t, `create table notes_app.stage_probe_data(k integer not null, padding text not null) with (autovacuum_enabled=false);
 insert into notes_app.stage_probe_data select n,repeat('x',100) from generate_series(1,50000) n;
 create index stage_probe_lookup on notes_app.stage_probe_data(k);
 analyze notes_app.stage_probe_data;
 create table notes_app.stage_probe_other(id integer)`)
	return f
}

func stageProbeWitnessTransaction(t *testing.T, f *pgControlTestFixture, disableSeqScan bool) pgx.Tx {
	t.Helper()
	tx, err := f.worker.BeginTx(f.ctx, pgx.TxOptions{IsoLevel: pgx.ReadCommitted})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = tx.Rollback(context.Background()) })
	settings := `set local plan_cache_mode=force_generic_plan;
 set local max_parallel_workers_per_gather=0; set local jit=off;`
	if disableSeqScan {
		settings += `set local enable_seqscan=off; set local enable_bitmapscan=off;`
	}
	if _, err := tx.Exec(f.ctx, settings); err != nil {
		t.Fatal(err)
	}
	// A key lock does not serialize ANALYZE or index DDL. No mutation follows
	// the deliberately unsafe probe in these tests.
	if _, err := tx.Exec(f.ctx, `select pg_catalog.pg_advisory_xact_lock(-1::bigint)`); err != nil {
		t.Fatal(err)
	}
	if _, err := tx.Exec(f.ctx, `prepare stage_probe(integer) as select 1 from notes_app.stage_probe_data where k operator(pg_catalog.=) $1 limit 1`); err != nil {
		t.Fatal(err)
	}
	before := stageProbeWitnessExplain(t, f.ctx, tx, false)
	if !stageProbeWitnessContains(before, "Index Only Scan", "stage_probe_lookup") && !stageProbeWitnessContains(before, "Index Scan", "stage_probe_lookup") {
		t.Fatal("fixture did not begin with an indexed prepared plan")
	}
	return tx
}

func TestPgStageProbePlanAnalyzeCanReplaceForcedGenericPlan(t *testing.T) {
	f := stageProbeWitnessSetup(t)
	// Change data BEFORE the proposed guard's transaction/lock. Leave the old
	// statistics in place, as can occur naturally between autovacuum analyses.
	f.call(t, `update notes_app.stage_probe_data set k=1`)
	tx := stageProbeWitnessTransaction(t, f, false)
	other, err := pgx.ConnectConfig(f.ctx, f.worker.Config().Copy())
	if err != nil {
		t.Fatal(err)
	}
	defer other.Close(context.Background())
	// A second backend can analyze while the guard's key and ACCESS SHARE locks
	// remain held. This is ordinary maintenance, not an application key write.
	if _, err := other.Exec(f.ctx, `analyze notes_app.stage_probe_data`); err != nil {
		t.Fatal(err)
	}
	// A new relation lock is a deterministic invalidation-message acceptance
	// boundary. It is permitted in an ordinary multi-statement transaction and
	// does not release the key lock or the already-held source relation locks.
	if _, err := tx.Exec(f.ctx, `lock table notes_app.stage_probe_other in access share mode`); err != nil {
		t.Fatal(err)
	}
	after := stageProbeWitnessExplain(t, f.ctx, tx, true)
	if !stageProbeWitnessContains(after, "Seq Scan", "") {
		t.Fatal("fixture did not witness a generic-plan replacement")
	}
	if count := stageProbeWitnessFilteredRows(after); count != 50000 {
		t.Fatal("the replacement must actually scan all live rows", count)
	}
	var generic, custom int64
	if err := tx.QueryRow(f.ctx, `select generic_plans,custom_plans from pg_catalog.pg_prepared_statements where name='stage_probe'`).Scan(&generic, &custom); err != nil || generic < 2 || custom != 0 {
		t.Fatal("witness must use forced generic plans throughout", generic, custom, err)
	}
}

func TestPgStageProbePlanDisabledSeqScanStillFallsBackAfterInvalidation(t *testing.T) {
	f := stageProbeWitnessSetup(t)
	tx := stageProbeWitnessTransaction(t, f, true)
	other, err := pgx.ConnectConfig(f.ctx, f.worker.Config().Copy())
	if err != nil {
		t.Fatal(err)
	}
	dropCtx, cancelDrop := context.WithCancel(f.ctx)
	finished := make(chan struct{})
	dropResult := make(chan error, 1)
	go func() {
		defer close(finished)
		_, err := other.Exec(dropCtx, `drop index concurrently notes_app.stage_probe_lookup`)
		dropResult <- err
	}()
	defer func() {
		cancelDrop()
		_ = tx.Rollback(context.Background())
		<-finished
		_ = other.Close(context.Background())
	}()
	ctx, cancel := context.WithTimeout(f.ctx, 10*time.Second)
	defer cancel()
	ticker := time.NewTicker(5 * time.Millisecond)
	defer ticker.Stop()
	for {
		var unavailable bool
		if err := f.installer.QueryRow(ctx, `select coalesce((select not indisvalid from pg_catalog.pg_index where indexrelid=pg_catalog.to_regclass('notes_app.stage_probe_lookup')),true)`).Scan(&unavailable); err != nil {
			t.Fatal(err)
		}
		if unavailable {
			break
		}
		select {
		case <-ctx.Done():
			t.Fatal("concurrent drop never invalidated the checked index", ctx.Err())
		case err := <-dropResult:
			if err != nil {
				t.Fatal(fmt.Errorf("concurrent drop: %w", err))
			}
		case <-ticker.C:
		}
	}
	if _, err := tx.Exec(f.ctx, `lock table notes_app.stage_probe_other in access share mode`); err != nil {
		t.Fatal(err)
	}
	after := stageProbeWitnessExplain(t, f.ctx, tx, true)
	if !stageProbeWitnessContains(after, "Seq Scan", "") {
		t.Fatal("missing-index fallback was not observed despite enable_seqscan=off")
	}
	if count := stageProbeWitnessFilteredRows(after); count != 50000 {
		t.Fatal("the fallback must actually scan all live rows", count)
	}
}
