//go:build tesl_migration_test

package teslrt

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/jackc/pgx/v5"
	"slices"
	"strings"
	"testing"
	"time"
)

// Uses the production format3 executor, Request readiness, and index worker.
// The existing canonical-history fixture seal is explicit; no generated App claim.
func TestPgMigrationIndexNewNullWaitsForPhysicalAndProtectedValidity(t *testing.T) {
	for _, unique := range []bool{false, true} {
		t.Run(map[bool]string{false: "plain-unbounded", true: "unique"}[unique], func(t *testing.T) {
			f, request := pgNewWorkerTest(t)
			f.install(t, 1)
			var state PgMigrationControlState
			for _, v := range []int{1, 3} {
				var err error
				state, err = ExecutePgMigrationExpansion(f.ctx, f.worker, pgNullableIndexReadinessHistory(f.namespace, v, unique), f.roles)
				if err != nil {
					t.Fatal(err)
				}
			}
			old := pgNullableIndexReadinessHistory(f.namespace, 1, unique)
			if _, err := pgWaitForMigrationReadiness(f.ctx, request, old, f.roles); err != nil {
				t.Fatal("old readiness", err)
			}
			if _, err := request.Exec(f.ctx, "insert into notes_app.notes(id,active) values('old',false)"); err != nil {
				t.Fatal(err)
			}
			pending := func(version int) {
				t.Helper()
				arrived, resume := pgPauseExpansionBoundary(t, "request-readiness-pending", 1)
				ctx, cancel := context.WithCancel(f.ctx)
				done := make(chan error, 1)
				go func() {
					_, err := pgWaitForMigrationReadiness(ctx, request, pgNullableIndexReadinessHistory(f.namespace, version, unique), f.roles)
					done <- err
				}()
				select {
				case <-arrived:
				case err := <-done:
					cancel()
					resume()
					t.Fatal("current writer escaped incomplete index", version, err)
				case <-f.ctx.Done():
					cancel()
					resume()
					t.Fatal(f.ctx.Err())
				}
				cancel()
				resume()
				if err := pgIndexExpansionWaitDone(t, f, done); !errors.Is(err, context.Canceled) {
					t.Fatal("pending readiness cancellation", err)
				}
			}
			// Both introducing and later versions are excluded even before CIC exists.
			pending(2)
			pending(3)
			query := "create index concurrently token__v2 on notes_app.notes(token)"
			if unique {
				query = "create unique index concurrently token__v2 on notes_app.notes(token)"
			}
			f.call(t, query)
			// A physical valid index alone is insufficient: durable completion is pending.
			pending(2)
			pending(3)
			if _, err := pgWaitForMigrationReadiness(f.ctx, request, old, f.roles); err != nil {
				t.Fatal("old fleet stopped while job pending", err)
			}
			if _, err := request.Exec(f.ctx, "update notes_app.notes set active=true where id='old'"); err != nil {
				t.Fatal("old non-HOT update", err)
			}
			config := f.worker.Config().Copy()
			conn, err := pgx.ConnectConfig(f.ctx, config.Copy())
			if err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithCancel(f.ctx)
			service := &pgIndexTestService{cancel: cancel, done: make(chan struct{}), ready: make(chan PgMigrationControlState, 2), pid: conn.PgConn().PID()}
			go func() {
				service.err = pgRunMigrationIndexWorkerWithSettings(ctx, conn, config, pgNullableIndexReadinessHistory(f.namespace, 3, unique), f.roles, state, func(state PgMigrationControlState) error { service.ready <- state; return nil }, pgIndexTestSettings())
				close(service.done)
			}()
			t.Cleanup(func() {
				cancel()
				select {
				case <-service.done:
				case <-time.After(7 * time.Second):
					t.Error("index worker failed to stop")
				}
			})
			pgIndexTestReady(t, f, service)
			job := pgIndexTestValid(t, f, service)
			if job.State != "valid" {
				t.Fatal("missing durable completion")
			}
			for _, v := range []int{1, 2, 3} {
				if _, err := pgWaitForMigrationReadiness(f.ctx, request, pgNullableIndexReadinessHistory(f.namespace, v, unique), f.roles); err != nil {
					t.Fatal("valid writer did not resume", v, err)
				}
			}
			if _, err := request.Exec(f.ctx, "insert into notes_app.notes(id,active,token) values('new',false,'safe');update notes_app.notes set active=true where id='new'"); err != nil {
				t.Fatal("post-valid new value and old-field update", err)
			}
			pgIndexTestStop(t, service)
		})
	}
}

func pgNullableIndexReadinessHistory(namespace string, current int, unique bool) PgCompiledMigrationHistory {
	index := PgMigrationCatalogIndex{Name: "token__v2", Columns: []string{"token"}}
	if unique {
		index = PgMigrationCatalogIndex{Name: "token__v2", Columns: []string{"token"}, Unique: true}
	}
	steps := []PgMigrationExpansionStep{
		{Version: 1, SnapshotHash: strings.Repeat("1", 64), EpochPreserving: true, Operations: []PgMigrationExpansionOperation{
			{Kind: "create-table", Table: "notes", Columns: []PgMigrationCatalogColumn{
				pgPlanTestColumn("id", "text", false, true), pgPlanTestColumn("active", "bool", false, false)}, Indexes: []PgMigrationCatalogIndex{{Name: "old_active_lookup", Columns: []string{"active"}}}},
		}},
		{Version: 2, SnapshotHash: strings.Repeat("2", 64), EpochPreserving: true, Operations: []PgMigrationExpansionOperation{
			{Kind: "add-column", Table: "notes", Column: &PgMigrationCatalogColumn{Name: "token", Type: "text", Nullable: true}},
			{Kind: "build-index-concurrently", Table: "notes", Index: &index},
		}},
		{Version: 3, SnapshotHash: strings.Repeat("3", 64), EpochPreserving: true, Operations: []PgMigrationExpansionOperation{
			{Kind: "add-column", Table: "notes", Column: &PgMigrationCatalogColumn{Name: "note", Type: "text", Nullable: true}},
			{Kind: "retain-index", Table: "notes", Index: &index},
		}},
	}[:current]
	pgPlanTestSeal(steps)
	origins := []any{}
	for origin := range current {
		baseline := PgMigrationExpansionStep{Version: origin + 1, SnapshotHash: steps[origin].SnapshotHash, EpochPreserving: true}
		for _, table := range steps[origin].Catalog {
			baseline.Operations = append(baseline.Operations, PgMigrationExpansionOperation{
				Kind: "create-table", Table: table.Name, Columns: slices.Clone(table.Columns), Indexes: table.Indexes})
		}
		chain := append([]PgMigrationExpansionStep{baseline}, steps[origin+1:]...)
		pgPlanTestSeal(chain)
		origins = append(origins, map[string]any{"initialVersion": origin + 1, "steps": pgPlanTestStepsJSON(chain), "errors": []any{}})
	}
	history := PgCompiledMigrationHistory{Database: "App.Main", Family: "NotesSchema", Namespace: namespace, CurrentVersion: current,
		SourceCompilerABI: pgTestSourceABI, StoredValueCompatibility: pgTestStoredValueCompatibility}
	encoded, err := json.Marshal(map[string]any{"version": 3, "kind": "compiled-migration-history", "compilerAbi": history.SourceCompilerABI,
		"storedValueCompatibility": history.StoredValueCompatibility, "databases": []any{map[string]any{
			"database": history.Database, "family": history.Family, "namespace": namespace, "currentVersion": current, "origins": origins}}})
	if err != nil {
		panic(err)
	}
	history.HistoryJSON = string(encoded)
	return history
}
