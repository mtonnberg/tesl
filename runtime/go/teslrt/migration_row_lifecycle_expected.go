package teslrt

import "fmt"

func pgExpectedRowLifecycleControl(e *pgCatalogExpectations, owner, name string) (*pgCatalogTable, error) {
	columns := []pgControlExpectedColumn{}
	constraints := []pgControlExpectedConstraint{}
	col := func(name, typ string, required bool, def string) {
		columns = append(columns, pgControlExpectedColumn{name: name, typeName: typ, required: required, defaultSQL: def})
	}
	con := func(kind, expression string, keys ...string) {
		constraints = append(constraints, pgControlExpectedConstraint{kind: kind, expression: expression, keys: keys})
	}
	check := func(expression string, keys ...string) { con("c", expression, keys...) }
	hash := func(name string) { check("("+name+" ~ '^[0-9a-f]{64}$'::text)", name) }
	bounded := func(name string, lo, hi string) { check("(("+name+" >= "+lo+") AND ("+name+" <= "+hi+"))", name) }
	abi := func() {
		col("compiler_abi", "text", true, "")
		check("(compiler_abi ~ '^tesl-source-abi-v1:[0-9a-f]{64}$'::text)", "compiler_abi")
	}
	switch name {
	case "tesl_schema_backfill_shards":
		col("version", "int4", true, "")
		bounded("version", "2", "2147483646")
		col("entity", "text", true, "")
		col("target_generation", "int2", true, "")
		bounded("target_generation", "2", "32767")
		col("shard", "int2", true, "")
		check("(shard >= 0)", "shard")
		for _, n := range []string{"lo_pk", "hi_pk", "last_pk"} {
			col(n, "jsonb", false, "")
		}
		col("rows_done", "int8", true, "0")
		check("(rows_done >= 0)", "rows_done")
		col("state", "text", true, "'pending'::text")
		check("(state = ANY (ARRAY['pending'::text, 'running'::text, 'provisional'::text, 'final'::text]))", "state")
		col("lease_name", "text", true, "")
		col("updated_at", "timestamptz", true, "clock_timestamp()")
		con("p", "", "entity", "target_generation", "shard")
		con("u", "", "lease_name")
	case "tesl_row_finality":
		col("entity", "text", true, "")
		col("generation", "int2", true, "")
		bounded("generation", "1", "32767")
		col("version", "int4", true, "")
		bounded("version", "1", "2147483646")
		for _, n := range []string{"physical_hash", "retirement_hash"} {
			col(n, "text", true, "")
			hash(n)
		}
		abi()
		col("finalized_at", "timestamptz", true, "clock_timestamp()")
		con("p", "", "entity", "generation")
	case "tesl_row_contracts":
		col("version", "int4", true, "")
		bounded("version", "2", "2147483646")
		col("predecessor_hash", "text", true, "")
		col("contract", "bytea", true, "")
		for _, n := range []string{"contract_hash", "window_hash"} {
			col(n, "text", true, "")
			hash(n)
		}
		col("settled", "bytea", true, "")
		col("settled_hash", "text", true, "")
		hash("settled_hash")
		col("operation_count", "int4", true, "")
		check("(operation_count >= 0)", "operation_count")
		col("preparation_count", "int4", true, "")
		check("((preparation_count >= 0) AND (preparation_count <= operation_count))", "preparation_count", "operation_count")
		abi()
		con("p", "", "version")
		check("(encode(sha256(contract), 'hex'::text) = contract_hash)", "contract", "contract_hash")
		check("(encode(sha256(settled), 'hex'::text) = settled_hash)", "settled", "settled_hash")
	case "tesl_row_contract_objects":
		col("version", "int4", true, "")
		bounded("version", "2", "2147483646")
		col("ordinal", "int4", true, "")
		check("(ordinal >= 0)", "ordinal")
		col("operation_hash", "text", true, "")
		hash("operation_hash")
		col("committed_at", "timestamptz", true, "clock_timestamp()")
		con("p", "", "version", "ordinal")
	default:
		return nil, fmt.Errorf("unknown lifecycle control table")
	}
	return pgBuildExpectedControlTable(e, owner, name, columns, constraints)
}
