package teslrt

import (
	"context"
	"fmt"
	"reflect"

	"github.com/jackc/pgx/v5"
)

// Independent read-only catalog expectations; Request needs no TEMP privilege.
func pgExpectedRowControl(e *pgCatalogExpectations, owner, name string) (*pgCatalogTable, error) {
	columns := []pgControlExpectedColumn{}
	constraints := []pgControlExpectedConstraint{}
	col := func(n, typ string) {
		columns = append(columns, pgControlExpectedColumn{name: n, typeName: typ, required: true})
	}
	con := func(kind, expression string, keys ...string) {
		constraints = append(constraints, pgControlExpectedConstraint{kind: kind, expression: expression, keys: keys})
	}
	check := func(expression string, keys ...string) { con("c", expression, keys...) }
	hash := func(n string) { check("("+n+" ~ '^[0-9a-f]{64}$'::text)", n) }
	digest := func(value, hash string) { check("(encode(sha256("+value+"), 'hex'::text) = "+hash+")", value, hash) }
	bounded := func(n string) { check("(("+n+" >= 1) AND ("+n+" <= 2147483646))", n) }
	switch name {
	case "tesl_row_baseline":
		col("id", "int2")
		col("initial_version", "int4")
		col("established_by", "text")
		col("inventory_authority", "text")
		col("inventory", "bytea")
		col("inventory_hash", "text")
		col("queue_authority", "text")
		col("queue_count", "int4")
		col("facility_authority", "text")
		col("facility_count", "int4")
		con("p", "", "id")
		check("(id = 1)", "id")
		check("(initial_version = 1)", "initial_version")
		check("(established_by = 'fresh-install'::text)", "established_by")
		check("(inventory_authority = 'complete'::text)", "inventory_authority")
		hash("inventory_hash")
		check("(queue_authority = 'complete'::text)", "queue_authority")
		check("(queue_count = 0)", "queue_count")
		check("(facility_authority = 'complete'::text)", "facility_authority")
		check("(facility_count = 0)", "facility_count")
		digest("inventory", "inventory_hash")
	case "tesl_row_versions":
		col("version", "int4")
		col("family", "text")
		col("schema_snapshot", "bytea")
		col("schema_snapshot_hash", "text")
		col("storage_snapshot", "bytea")
		col("storage_snapshot_hash", "text")
		col("inventory_hash", "text")
		col("catalog_hash", "text")
		col("entity_count", "int4")
		col("queue_count", "int4")
		col("facility_count", "int4")
		col("compiler_abi", "text")
		col("stored_value_compatibility", "text")
		con("p", "", "version")
		bounded("version")
		for _, n := range []string{"schema_snapshot_hash", "storage_snapshot_hash", "inventory_hash", "catalog_hash"} {
			hash(n)
		}
		check("(entity_count >= 0)", "entity_count")
		check("(queue_count = 0)", "queue_count")
		check("(facility_count = 0)", "facility_count")
		check("(compiler_abi ~ '^tesl-source-abi-v1:[0-9a-f]{64}$'::text)", "compiler_abi")
		check("(stored_value_compatibility ~ '^tesl-stored-value-v1:[0-9a-f]{64}$'::text)", "stored_value_compatibility")
		digest("schema_snapshot", "schema_snapshot_hash")
		digest("storage_snapshot", "storage_snapshot_hash")
	case "tesl_row_physical":
		col("version", "int4")
		col("predecessor_hash", "text")
		col("contract", "bytea")
		col("contract_hash", "text")
		col("compiler_abi", "text")
		col("stored_value_compatibility", "text")
		col("operation_count", "int4")
		col("epoch_preserving", "bool")
		con("p", "", "version")
		check("((version >= 1) AND (version <= 2147483646))", "version")
		hash("contract_hash")
		check("(compiler_abi ~ '^tesl-source-abi-v1:[0-9a-f]{64}$'::text)", "compiler_abi")
		check("(stored_value_compatibility ~ '^tesl-stored-value-v1:[0-9a-f]{64}$'::text)", "stored_value_compatibility")
		check("(operation_count >= 0)", "operation_count")
		check("(((version = 1) AND (predecessor_hash = ''::text) AND (operation_count = 0)) OR ((version > 1) AND (predecessor_hash ~ '^[0-9a-f]{64}$'::text) AND (operation_count >= 0)))", "version", "predecessor_hash", "operation_count")
		digest("contract", "contract_hash")
	case "tesl_row_epochs":
		col("through_version", "int4")
		col("old_min", "int4")
		col("retirement", "bytea")
		col("retirement_hash", "text")
		col("compiler_abi", "text")
		col("forced", "bool")
		con("p", "", "through_version")
		check("((through_version >= 2) AND (through_version <= 2147483646))", "through_version")
		check("((old_min >= 1) AND (old_min < through_version))", "old_min", "through_version")
		hash("retirement_hash")
		check("(compiler_abi ~ '^tesl-source-abi-v1:[0-9a-f]{64}$'::text)", "compiler_abi")
		digest("retirement", "retirement_hash")
	case "tesl_row_processing":
		col("version", "int4")
		col("compiler_abi", "text")
		con("p", "", "version")
		check("((version >= 2) AND (version <= 2147483646))", "version")
		check("(compiler_abi ~ '^tesl-source-abi-v1:[0-9a-f]{64}$'::text)", "compiler_abi")
	case "tesl_row_entities":
		col("version", "int4")
		col("entity", "text")
		col("table_name", "text")
		col("generation", "int2")
		col("insert_generation", "int2")
		col("type_contract", "bytea")
		col("type_contract_hash", "text")
		col("physical_storage", "bytea")
		col("physical_storage_hash", "text")
		col("ordinal", "int4")
		col("operation_hash", "text")
		con("p", "", "version", "entity")
		con("u", "", "version", "table_name")
		con("u", "", "version", "ordinal")
		bounded("version")
		check("((generation >= 1) AND (generation <= 32767))", "generation")
		check("((insert_generation >= 1) AND (insert_generation <= generation))", "insert_generation", "generation")
		hash("type_contract_hash")
		hash("physical_storage_hash")
		check("(ordinal >= 0)", "ordinal")
		hash("operation_hash")
		digest("type_contract", "type_contract_hash")
		digest("physical_storage", "physical_storage_hash")
	default:
		return pgExpectedRowLifecycleControl(e, owner, name)
	}
	return pgBuildExpectedControlTable(e, owner, name, columns, constraints)
}

func pgRowControlCatalog(ctx context.Context, tx pgx.Tx, namespace string, roles PgMigrationControlRoles) error {
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
	var extra bool
	if err := tx.QueryRow(ctx, `select exists(select 1 from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace join pg_catalog.pg_roles r on r.oid=c.relowner where n.nspname=$1 and c.relkind not in ('i','I') and ((r.rolname=$2 and not(c.relname=any($3::text[]))) or ((left(c.relname,12)='tesl_schema_' or left(c.relname,9)='tesl_row_' or left(c.relname,11)='tesl_queue_' or c.relname='tesl_jobs') and not(c.relname=any($3::text[])))))`, namespace, roles.Owner, names).Scan(&extra); err != nil {
		return err
	}
	if extra {
		return fmt.Errorf("unrecorded protected relation in row format 5")
	}
	for _, spec := range pgRowControlTables() {
		expected, err := pgExpectedRowControl(metadata, roles.Owner, spec.name)
		if err != nil {
			return err
		}
		actual, err := pgReadMigrationTable(ctx, tx, namespace, spec.name)
		if err != nil {
			return err
		}
		if actual == nil || !reflect.DeepEqual(pgCanonicalMigrationTable(actual), pgCanonicalMigrationTable(expected)) {
			return fmt.Errorf("protected row table %s differs from format 5", spec.name)
		}
		principals := []string{roles.Worker}
		if roles.Request != "" {
			principals = append(principals, roles.Request)
		}
		for _, principal := range principals {
			if err := pgControlTableACL(ctx, tx, namespace, spec.name, principal); err != nil {
				return err
			}
		}
		seqs, err := pgReadControlSequences(ctx, tx, namespace, spec.name, roles.Worker)
		if err != nil {
			return err
		}
		if len(seqs) != 0 {
			return fmt.Errorf("unexpected row control sequence")
		}
	}
	return nil
}
