package teslrt

import (
	"bytes"
	"context"
	"fmt"
	"reflect"
	"strings"

	"github.com/jackc/pgx/v5"
)

type pgControlPreparation interface {
	inspect(context.Context, pgx.Tx, string, PgMigrationControlRoles) (PgMigrationControlState, error)
	prepareFresh(context.Context, pgx.Tx, PgMigrationControlState) error
	verify(context.Context, pgx.Tx, PgMigrationControlState) error
}

func (p *pgRowBaselinePreparation) prepareFresh(ctx context.Context, tx pgx.Tx, state PgMigrationControlState) error {
	if state.Format != 3 || state.InitialVersion != 1 || state.Current != 0 || state.InstallingVersion != 1 {
		return fmt.Errorf("row baseline requires an uncommitted genuinely fresh origin")
	}
	b := p.baseline
	ns := quoteIdentifier(b.history.Namespace) + "."
	readers := quoteIdentifier(p.roles.Worker)
	if p.roles.Request != "" {
		readers += "," + quoteIdentifier(p.roles.Request)
	}
	if _, err := tx.Exec(ctx, "set local role "+quoteIdentifier(p.roles.Owner)); err != nil {
		return err
	}
	for _, spec := range pgRowControlTables() {
		if _, err := tx.Exec(ctx, "create table "+ns+quoteIdentifier(spec.name)+"("+spec.columns+"); grant select on "+ns+quoteIdentifier(spec.name)+" to "+readers); err != nil {
			return err
		}
		migrationBoundary("row-baseline-table-" + spec.name)
	}
	if _, err := tx.Exec(ctx, "insert into "+ns+"tesl_row_baseline values(1,1,'fresh-install','complete',$1,$2,'complete',0,'complete',0)", []byte(b.inventory), b.inventoryHash); err != nil {
		return err
	}
	schema, err := pgRowBaselineHex(b.version.SchemaContract)
	if err != nil {
		return err
	}
	storage, err := pgRowBaselineHex(b.version.StorageContract)
	if err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, "insert into "+ns+"tesl_row_versions values(1,$1,$2,$3,$4,$5,$6,$7,$8,0,0,$9,$10)", b.history.Family, schema, b.version.SchemaSnapshotHash, storage, b.version.StorageSnapshotHash, b.inventoryHash, b.catalogHash, len(b.entities), b.history.SourceCompilerABI, b.history.StoredValueCompatibility); err != nil {
		return err
	}
	if b.physical != nil {
		contract, err := pgRowBaselineHex(b.physical.contract)
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, "insert into "+ns+"tesl_row_physical values(1,'',$1,$2,$3,$4,0)", contract, b.physical.hash, b.history.SourceCompilerABI, b.history.StoredValueCompatibility); err != nil {
			return err
		}
	}
	for _, entity := range b.entities {
		contract, err := pgRowBaselineHex(entity.source.TypeContract)
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, "insert into "+ns+"tesl_row_entities values(1,$1,$2,1,1,$3,$4,$5,$6,$7,$8)", entity.source.Entity, entity.source.Table, contract, entity.source.TypeContractHash, []byte(entity.physical), entity.physicalHash, entity.ordinal, pgMigrationObjectHash(b.inventoryHash, entity.ordinal)); err != nil {
			return err
		}
	}
	// Base-format objects existed only inside this uncommitted installer txn.
	// Replace their function catalog before publishing the new format atomically.
	for _, fn := range pgMigrationControlFunctions(b.history.Namespace) {
		if _, err := tx.Exec(ctx, "drop function "+ns+quoteIdentifier(fn.name)+"("+pgControlArgumentTypes(fn)+")"); err != nil {
			return err
		}
	}
	for _, fn := range pgRowControlFunctions(b.history.Namespace) {
		if _, err := tx.Exec(ctx, pgControlFunctionSQL(b.history.Namespace, p.roles.Owner, fn)); err != nil {
			return err
		}
		grantees := pgControlFunctionRoles(p.roles, fn)
		for i := range grantees {
			grantees[i] = quoteIdentifier(grantees[i])
		}
		if _, err := tx.Exec(ctx, "revoke all on function "+ns+quoteIdentifier(fn.name)+"("+pgControlArgumentTypes(fn)+") from public; grant execute on function "+ns+quoteIdentifier(fn.name)+"("+pgControlArgumentTypes(fn)+") to "+strings.Join(grantees, ",")); err != nil {
			return err
		}
	}
	migrationBoundary("row-baseline-inventory")
	_, err = tx.Exec(ctx, "update "+ns+"tesl_schema_meta set format_version=5 where id=1 and format_version=3")
	return err
}

func pgInspectRowControl(ctx context.Context, tx pgx.Tx, namespace string, roles PgMigrationControlRoles) (PgMigrationControlState, error) {
	state, err := pgInspectControlProtocolMode(ctx, tx, namespace, roles, true, pgRowControlFormat)
	if err != nil {
		return PgMigrationControlState{}, err
	}
	if state.Format != pgRowControlFormat || state.InitialVersion != 1 {
		return PgMigrationControlState{}, fmt.Errorf("row baseline requires bounded format5 fresh V1 origin")
	}
	return state, nil
}

func pgVerifyRowBaseline(ctx context.Context, tx pgx.Tx, b *pgRowBaseline, state PgMigrationControlState) error {
	if b == nil || state.Format != pgRowControlFormat || state.InitialVersion != 1 {
		return fmt.Errorf("row baseline installation identity differs")
	}
	ns := quoteIdentifier(b.history.Namespace) + "."
	var inventory []byte
	var hash string
	var initial, queueCount, facilityCount int
	var established, authority, queueAuthority, facilityAuthority string
	if err := tx.QueryRow(ctx, "select initial_version,established_by,inventory_authority,inventory,inventory_hash,queue_authority,queue_count,facility_authority,facility_count from "+ns+"tesl_row_baseline where id=1").Scan(&initial, &established, &authority, &inventory, &hash, &queueAuthority, &queueCount, &facilityAuthority, &facilityCount); err != nil {
		return err
	}
	if initial != 1 || established != "fresh-install" || authority != "complete" || queueAuthority != "complete" || queueCount != 0 || facilityAuthority != "complete" || facilityCount != 0 || hash != b.inventoryHash || !bytes.Equal(inventory, []byte(b.inventory)) {
		return fmt.Errorf("persisted complete row/facility baseline differs from source")
	}
	var version, entityCount int
	var family, schemaHash, storageHash, inventoryHash, catalogHash, sourceABI, compatibility string
	var schema, storage []byte
	if err := tx.QueryRow(ctx, "select version,family,schema_snapshot,schema_snapshot_hash,storage_snapshot,storage_snapshot_hash,inventory_hash,catalog_hash,entity_count,queue_count,facility_count,compiler_abi,stored_value_compatibility from "+ns+"tesl_row_versions").Scan(&version, &family, &schema, &schemaHash, &storage, &storageHash, &inventoryHash, &catalogHash, &entityCount, &queueCount, &facilityCount, &sourceABI, &compatibility); err != nil {
		return err
	}
	expectedSchema, err := pgRowBaselineHex(b.version.SchemaContract)
	if err != nil {
		return err
	}
	expectedStorage, err := pgRowBaselineHex(b.version.StorageContract)
	if err != nil {
		return err
	}
	if version != 1 || family != b.history.Family || schemaHash != b.version.SchemaSnapshotHash || storageHash != b.version.StorageSnapshotHash || !bytes.Equal(schema, expectedSchema) || !bytes.Equal(storage, expectedStorage) || inventoryHash != b.inventoryHash || catalogHash != b.catalogHash || entityCount != len(b.entities) || queueCount != 0 || facilityCount != 0 || !strings.HasPrefix(sourceABI, "tesl-source-abi-v1:") || !pgMigrationDigest(strings.TrimPrefix(sourceABI, "tesl-source-abi-v1:")) || compatibility != b.history.StoredValueCompatibility {
		return fmt.Errorf("persisted row source version differs")
	}
	var versions, entities, indexJobs, leases int
	if err := tx.QueryRow(ctx, "select (select count(*) from "+ns+"tesl_row_versions),(select count(*) from "+ns+"tesl_row_entities),(select count(*) from "+ns+"tesl_schema_index),(select count(*) from "+ns+"tesl_schema_leases)").Scan(&versions, &entities, &indexJobs, &leases); err != nil {
		return err
	}
	if versions != 1 || entities != len(b.entities) || indexJobs != 0 {
		return fmt.Errorf("persisted row baseline inventory is incomplete or unsupported")
	}
	rows, err := tx.Query(ctx, "select version,entity,table_name,generation,insert_generation,type_contract,type_contract_hash,physical_storage,physical_storage_hash,ordinal,operation_hash from "+ns+"tesl_row_entities order by ordinal")
	if err != nil {
		return err
	}
	i := 0
	for rows.Next() {
		var v, g, insert, ordinal int
		var entity, table, typeHash, physicalHash, operationHash string
		var contract, physical []byte
		if err := rows.Scan(&v, &entity, &table, &g, &insert, &contract, &typeHash, &physical, &physicalHash, &ordinal, &operationHash); err != nil {
			rows.Close()
			return err
		}
		if i >= len(b.entities) {
			rows.Close()
			return fmt.Errorf("extra row baseline entity")
		}
		want := b.entities[i]
		expectedType, err := pgRowBaselineHex(want.source.TypeContract)
		if err != nil {
			rows.Close()
			return err
		}
		if v != 1 || entity != want.source.Entity || table != want.source.Table || g != 1 || insert != 1 || typeHash != want.source.TypeContractHash || !bytes.Equal(contract, expectedType) || physicalHash != want.physicalHash || !bytes.Equal(physical, []byte(want.physical)) || ordinal != i || operationHash != pgMigrationObjectHash(b.inventoryHash, i) {
			rows.Close()
			return fmt.Errorf("persisted entity generation/retained storage differs")
		}
		i++
	}
	if err := rows.Err(); err != nil {
		return err
	}
	rows.Close()
	if i != len(b.entities) {
		return fmt.Errorf("missing row baseline entity")
	}
	return nil
}

func (b *pgRowBaseline) expansionPlan() PgMigrationExpansionPlan {
	step := PgMigrationExpansionStep{Version: 1, SnapshotHash: b.catalogHash, StepHash: b.inventoryHash, EpochPreserving: true}
	for _, entity := range b.entities {
		step.Catalog = append(step.Catalog, entity.catalog)
		step.Operations = append(step.Operations, PgMigrationExpansionOperation{Kind: "create-table", Table: entity.catalog.Name, Columns: entity.catalog.Columns, Indexes: entity.catalog.Indexes})
	}
	return PgMigrationExpansionPlan{Database: b.history.Database, Family: b.history.Family, Namespace: b.history.Namespace, SourceCompilerABI: b.history.SourceCompilerABI, StoredValueCompatibility: b.history.StoredValueCompatibility, InitialVersion: 1, CurrentVersion: 1, Steps: []PgMigrationExpansionStep{step}}
}

func pgVerifyRowPhysicalCatalog(ctx context.Context, tx pgx.Tx, b *pgRowBaseline, roles PgMigrationControlRoles, count int) error {
	if count < 0 || count > len(b.entities) {
		return fmt.Errorf("invalid row baseline physical prefix")
	}
	catalog := []PgMigrationCatalogTable{}
	for _, entity := range b.entities[:count] {
		catalog = append(catalog, entity.catalog)
	}
	return pgVerifyRowCatalogSet(ctx, tx, b, roles, catalog, nil, nil)
}

func pgVerifyRowCatalogSet(ctx context.Context, tx pgx.Tx, b *pgRowBaseline, roles PgMigrationControlRoles, catalog []PgMigrationCatalogTable, triggers map[string]pgRowInvalidation, checks map[string]map[string]pgRowNotNullProof) error {
	metadata, err := pgReadCatalogExpectations(ctx, tx)
	if err != nil {
		return err
	}
	names := []string{}
	for _, spec := range pgMigrationControlTables {
		names = append(names, spec.name)
	}
	for _, spec := range pgRowControlTables() {
		names = append(names, spec.name)
	}
	for _, entity := range catalog {
		names = append(names, entity.Name)
		expected, err := metadata.entity(ctx, tx, entity, roles.Worker)
		if err != nil {
			return err
		}
		actual, err := pgReadMigrationTable(ctx, tx, b.history.Namespace, entity.Name)
		if err != nil {
			return err
		}
		if actual != nil {
			if err := pgVerifyRowNotNullProofs(ctx, tx, b.history.Namespace, actual, checks[entity.Name]); err != nil {
				return err
			}
			if spec, ok := triggers[entity.Name]; ok {
				if err := pgVerifyRowInvalidation(ctx, tx, b.history.Namespace, roles, actual, spec); err != nil {
					return err
				}
				actual.Triggers = []string{}
				actual.TriggerDefinitions = nil
			}
		}
		if actual == nil || !reflect.DeepEqual(pgCanonicalMigrationTable(actual), pgCanonicalMigrationTable(expected)) {
			return fmt.Errorf("row baseline table %q differs, including its permanent generation marker", entity.Name)
		}
		// Retained descriptors bind explicit secondary index identities, unlike
		// legacy catalog observations where equivalent names can be benign.
		actualIndexes, err := pgRowNamedSecondaryIndexes(actual)
		if err != nil {
			return err
		}
		expectedIndexes, err := pgRowNamedSecondaryIndexes(expected)
		if err != nil {
			return err
		}
		if !reflect.DeepEqual(actualIndexes, expectedIndexes) {
			return fmt.Errorf("row baseline secondary index identity or storage differs")
		}

	}
	functions := []string{}
	for _, spec := range triggers {
		functions = append(functions, spec.name)
	}
	var extra bool
	if err := tx.QueryRow(ctx, `select exists(select 1 from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace where n.nspname=$1 and c.relkind not in ('i','I') and not(c.relname=any($2::text[]))) or exists(select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace join pg_catalog.pg_roles r on r.oid=p.proowner where n.nspname=$1 and r.rolname<>$3 and not(r.rolname=$4 and p.proname=any($5::text[]) and p.pronargs=0))`, b.history.Namespace, names, roles.Owner, roles.Worker, functions).Scan(&extra); err != nil {
		return err
	}
	if extra {
		return fmt.Errorf("row baseline contains an unrecorded entity/facility object")
	}
	return pgVerifyRequestGrants(ctx, tx, b.history.Namespace, roles, catalog)
}

// Normalize physical column ordinals with the existing catalog semantics while
// retaining the declared secondary index name as the map key. Separate sets of
// names and shapes cannot detect two different indexes exchanging their names.
func pgRowNamedSecondaryIndexes(table *pgCatalogTable) (map[string]pgCatalogIndex, error) {
	indexes := map[string]pgCatalogIndex{}
	for _, index := range table.Indexes {
		if index.Primary {
			continue
		}
		one := *table
		one.Indexes = []pgCatalogIndex{index}
		normalized := pgCanonicalMigrationTable(&one)
		if len(normalized.Indexes) != 1 {
			return nil, fmt.Errorf("invalid secondary index normalization")
		}
		indexes[index.Name] = normalized.Indexes[0]
	}
	return indexes, nil
}
