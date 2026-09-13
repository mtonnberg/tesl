package teslrt

import (
	"context"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
)

func pgVerifyRowWorkState(ctx context.Context, tx pgx.Tx, b *pgRowBaseline, state PgMigrationControlState, forward *pgRowForwardManifest) error {
	type final struct {
		version, generation               int
		entity, physical, retirement, abi string
	}
	expected := map[string]final{}
	manifests := map[int]*pgRowForwardManifest{}
	key := func(entity string, generation int) string { return fmt.Sprintf("%s\x00%d", entity, generation) }
	if state.Current >= 1 {
		abi := ""
		for _, row := range state.Versions {
			if row.Version == 1 && row.Step == "expanded" {
				abi = row.SourceABI
			}
		}
		physical := b.inventoryHash
		if b.physical != nil {
			physical = b.physical.hash
		}
		for _, entity := range b.entities {
			expected[key(entity.source.Entity, 1)] = final{1, 1, entity.source.Entity, physical, b.inventoryHash, abi}
		}
	}
	for m := forward; m != nil; m = m.previous {
		manifests[m.plan.version] = m
		// A newly created table has generation-one finality from its exact
		// expansion publication. Seed the complete inventory even when every
		// persisted birth record is absent.
		for _, row := range state.Versions {
			if row.Version != m.plan.version || row.Step != "expanded" {
				continue
			}
			for ordinal, operation := range m.operations {
				if operation.table == nil {
					continue
				}
				entity := operation.entity.identity
				expected[key(entity, 1)] = final{m.plan.version, 1, entity, m.plan.hash, pgMigrationObjectHash(m.plan.hash, ordinal), row.SourceABI}
			}
		}
		for _, row := range state.Versions {
			if row.Version != m.plan.version || row.Step != "retired" {
				continue
			}
			if len(m.plan.windows) == 0 && m.epoch != nil && row.ArtifactHash == m.epoch.hash && row.SourceABI == m.epoch.executorABI {
				// Closing an additive epoch changes admission only. Its exact
				// receipt adds no entity generation or backfill obligation.
				continue
			}
			if m.contraction == nil {
				return fmt.Errorf("finality lacks exact Contract")
			}
			for _, window := range m.plan.windows {
				expected[key(window.entity, window.targetGeneration)] = final{m.plan.version, window.targetGeneration, window.entity, m.plan.hash, pgRowRetirementHash(m.contraction.contract), row.SourceABI}
			}
		}
	}
	ns := quoteIdentifier(b.history.Namespace) + "."
	rows, err := tx.Query(ctx, "select entity,generation,version,physical_hash,retirement_hash,compiler_abi from "+ns+"tesl_row_finality")
	if err != nil {
		return err
	}
	defer rows.Close()
	for rows.Next() {
		var actual final
		if err := rows.Scan(&actual.entity, &actual.generation, &actual.version, &actual.physical, &actual.retirement, &actual.abi); err != nil {
			return err
		}
		identity := key(actual.entity, actual.generation)
		want, ok := expected[identity]
		if !ok || actual != want {
			return fmt.Errorf("per-entity finality differs from exact lifecycle receipt")
		}
		delete(expected, identity)
	}
	if err := rows.Err(); err != nil {
		return err
	}
	rows.Close()
	if len(expected) != 0 {
		return fmt.Errorf("missing per-entity finality receipt")
	}
	shards, err := tx.Query(ctx, "select s.version,s.entity,s.target_generation,s.shard,s.lo_pk is null,s.hi_pk is null,s.state,s.lease_name,l.name,l.holder,l.token from "+ns+"tesl_schema_backfill_shards s left join "+ns+"tesl_schema_leases l on l.name=s.lease_name order by s.version,s.entity,s.shard")
	if err != nil {
		return err
	}
	defer shards.Close()
	counts := map[int]int{}
	// Retirement permanently requires its complete final shard inventory.
	// Seed even absent versions: deleting every shard must not erase the
	// obligation merely because no observed row contributes to this map.
	for _, row := range state.Versions {
		if row.Version > 1 && row.Step == "retired" {
			counts[row.Version] = 0
		}
	}
	total := 0
	for shards.Next() {
		var version, generation, shard int
		var entity, status, lease string
		var lo, hi bool
		var stored, holder *string
		var token *int64
		if err := shards.Scan(&version, &entity, &generation, &shard, &lo, &hi, &status, &lease, &stored, &holder, &token); err != nil {
			return err
		}
		m := manifests[version]
		if m == nil || state.Current < version {
			return fmt.Errorf("row work precedes its installed manifest")
		}
		found := false
		for _, w := range m.plan.windows {
			if w.entity == entity && w.targetGeneration == generation {
				found = true
				break
			}
		}
		if !found || shard != 0 || !lo || !hi || lease != pgRowLeaseName(entity, generation, shard) || stored == nil || *stored != lease || token == nil || *token < 0 || holder != nil && !strings.HasPrefix(*holder, "tesl-exec:") {
			return fmt.Errorf("row shard/lease differs from exact current work inventory")
		}
		final := false
		for _, row := range state.Versions {
			if row.Version == version && row.Step == "retired" {
				final = true
			}
		}
		if (status == "final") != final {
			return fmt.Errorf("row shard finality differs from retirement receipt")
		}
		counts[version]++
		total++
	}
	if err := shards.Err(); err != nil {
		return err
	}
	shards.Close()
	for version, count := range counts {
		manifest := manifests[version]
		if manifest == nil || manifest.plan == nil || count != len(manifest.plan.windows) {
			return fmt.Errorf("row work inventory is incomplete")
		}
	}
	var leases int
	if err := tx.QueryRow(ctx, "select count(*) from "+ns+"tesl_schema_leases").Scan(&leases); err != nil {
		return err
	}
	if leases != total {
		return fmt.Errorf("orphan row worker lease")
	}
	return nil
}
