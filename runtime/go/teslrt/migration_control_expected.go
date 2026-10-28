package teslrt

import (
	"context"
	"fmt"
	"reflect"

	"github.com/jackc/pgx/v5"
)

// Requests cannot create comparison objects. This independent description of
// the closed control format is checked against PostgreSQL-created probes in the
// mandatory migration matrix. Neither a source program nor stored SQL extends it.
type pgControlExpectedColumn struct {
	name, typeName string
	required       bool
	defaultSQL     string
	identity       bool
}

type pgControlExpectedConstraint struct {
	kind, expression string
	keys             []string
}

func pgKnownControlTable(spec pgMigrationControlTable) bool {
	if spec == pgMigrationFenceRegistry {
		return true
	}
	for _, known := range pgMigrationControlTables {
		if spec == known {
			return true
		}
	}
	return false
}

func pgExpectedControlTable(expected *pgCatalogExpectations, owner string, spec pgMigrationControlTable) (*pgCatalogTable, error) {
	if !pgKnownControlTable(spec) {
		return nil, fmt.Errorf("unsupported migration control table specification %q", spec.name)
	}
	var columns []pgControlExpectedColumn
	var constraints []pgControlExpectedConstraint
	check := func(expression string, keys ...string) {
		constraints = append(constraints, pgControlExpectedConstraint{kind: "c", expression: expression, keys: keys})
	}
	primary := func(keys ...string) {
		constraints = append(constraints, pgControlExpectedConstraint{kind: "p", keys: keys})
	}
	unique := func(keys ...string) {
		constraints = append(constraints, pgControlExpectedConstraint{kind: "u", keys: keys})
	}
	switch spec.name {
	case "tesl_schema_meta":
		columns = []pgControlExpectedColumn{
			{"id", "int2", true, "", false},
			{"format_version", "int4", true, "", false},
			{"database_uuid", "uuid", true, "", false},
			{"initial_version", "int4", true, "", false},
			{"max_observed_protocol", "int4", true, "", false},
			{"retirement_protocol_floor", "int4", true, "", false},
			{"fence_ns", "int4", true, "", false},
			{"fence_domain", "text", true, "", false},
		}
		primary("id")
		unique("database_uuid")
		check("(id = 1)", "id")
		check("((initial_version >= 1) AND (initial_version <= 2147483646))", "initial_version")
		check("((fence_ns >= 1) AND (fence_ns <= 2147483646))", "fence_ns")
	case "tesl_schema_state":
		columns = []pgControlExpectedColumn{
			{"id", "int2", true, "", false},
			{"min_version", "int4", true, "", false},
			{"current", "int4", true, "", false},
			{"installing_version", "int4", false, "", false},
			{"compat_floor", "int4", true, "0", false},
		}
		primary("id")
		check("(id = 1)", "id")
	case "tesl_schema_versions":
		columns = []pgControlExpectedColumn{
			{"version", "int4", true, "", false},
			{"step", "text", true, "", false},
			{"seq", "int2", true, "0", false},
			{"snapshot_hash", "text", false, "", false},
			{"artefact_hash", "text", true, "", false},
			{"source_abi", "text", true, "", false},
			{"stored_value_compatibility", "text", true, "", false},
			{"applied_at", "timestamptz", true, "now()", false},
			{"protocol_level", "int4", true, "", false},
			{"fence_domain", "text", true, "", false},
			{"epoch_preserving", "bool", false, "", false},
			{"executed_by", "text", false, "", false},
		}
		primary("version", "step", "seq")
		check("(step = ANY (ARRAY['expanded'::text, 'retired'::text, 'contracting'::text, 'contracted'::text, 'repair'::text]))", "step")
		check("((step = 'expanded'::text) = (epoch_preserving IS NOT NULL))", "step", "epoch_preserving")
	case "tesl_schema_expansions":
		columns = []pgControlExpectedColumn{
			{"version", "int4", true, "", false},
			{"snapshot_hash", "text", true, "", false},
			{"artefact_hash", "text", true, "", false},
			{"source_abi", "text", true, "", false},
			{"stored_value_compatibility", "text", true, "", false},
			{"operation_count", "int4", true, "", false},
			{"epoch_preserving", "bool", true, "", false},
			{"started_at", "timestamptz", true, "now()", false},
		}
		primary("version")
		check("((version >= 1) AND (version <= 2147483646))", "version")
		check("(operation_count >= 0)", "operation_count")
	case "tesl_schema_expansion_objects":
		columns = []pgControlExpectedColumn{
			{"version", "int4", true, "", false},
			{"ordinal", "int4", true, "", false},
			{"operation_hash", "text", true, "", false},
			{"committed_at", "timestamptz", true, "now()", false},
		}
		primary("version", "ordinal")
		check("(ordinal >= 0)", "ordinal")
	case "tesl_schema_instances":
		columns = []pgControlExpectedColumn{
			{"instance", "text", true, "", false},
			{"version", "int4", true, "", false},
			{"protocol_level", "int4", true, "", false},
			{"last_seen", "timestamptz", true, "", false},
			{"compat_floor_seen", "int4", true, "0", false},
		}
		primary("instance")
	case "tesl_schema_index":
		columns = []pgControlExpectedColumn{
			{"id", "text", true, "", false},
			{"version", "int4", true, "", false},
			{"ordinal", "int4", true, "", false},
			{"table_name", "text", true, "", false},
			{"index_name", "text", true, "", false},
			{"key_columns", "_text", true, "", false},
			{"is_unique", "bool", true, "", false},
			{"state", "text", true, "'pending'::text", false},
			{"terminal_version", "int4", false, "", false},
			{"attempts", "int8", true, "0", false},
			{"error", "text", false, "", false},
		}
		primary("id")
		unique("index_name")
		unique("version", "ordinal")
		check("((version >= 1) AND (version <= 2147483646))", "version")
		check("(ordinal >= 0)", "ordinal")
		check("(state = ANY (ARRAY['pending'::text, 'building'::text, 'valid'::text, 'failed'::text, 'terminal'::text]))", "state")
		check("((terminal_version >= 1) AND (terminal_version <= 2147483646))", "terminal_version")
		check("(attempts >= 0)", "attempts")
		check("((state = 'terminal'::text) = (terminal_version IS NOT NULL))", "state", "terminal_version")
	case "tesl_schema_leases":
		columns = []pgControlExpectedColumn{
			{"name", "text", true, "", false},
			{"holder", "text", false, "", false},
			{"token", "int8", true, "0", false},
			{"expires_at", "timestamptz", false, "", false},
		}
		primary("name")
		check("(token >= 0)", "token")
		check("((holder IS NULL) = (expires_at IS NULL))", "holder", "expires_at")
	case "tesl_fence_namespaces":
		columns = []pgControlExpectedColumn{
			{"fence_ns", "int4", true, "", true},
			{"database_uuid", "uuid", true, "", false},
		}
		primary("fence_ns")
		unique("database_uuid")
		check("((fence_ns >= 1) AND (fence_ns <= 2147483646))", "fence_ns")
	default:
		return nil, fmt.Errorf("control format %d has no read-only descriptor for %q", pgMigrationControlFormat, spec.name)
	}
	return pgBuildExpectedControlTable(expected, owner, spec.name, columns, constraints)
}

func pgBuildExpectedControlTable(expected *pgCatalogExpectations, owner, name string, columns []pgControlExpectedColumn, constraints []pgControlExpectedConstraint) (*pgCatalogTable, error) {
	table := pgNewExpectedCatalogTable(name, owner)
	numbers := map[string]int{}
	for i, definition := range columns {
		column, err := expected.column(i+1, definition.name, definition.typeName, definition.required)
		if err != nil {
			return nil, err
		}
		if definition.defaultSQL != "" {
			value := definition.defaultSQL
			column.Default = &value
		}
		if definition.identity {
			column.Identity = "a"
		}
		numbers[column.Name] = column.Number
		table.Columns = append(table.Columns, column)
		if expected.postgres18 && definition.required {
			table.Constraints = append(table.Constraints, pgCatalogConstraint{Kind: "n", Validated: true, Enforced: true, Keys: []int{column.Number}})
		}
	}
	for _, definition := range constraints {
		constraint := pgCatalogConstraint{Kind: definition.kind, Validated: true, Enforced: true, Keys: []int{}}
		for _, key := range definition.keys {
			number, found := numbers[key]
			if !found {
				return nil, fmt.Errorf("closed control constraint references unknown column %q", key)
			}
			constraint.Keys = append(constraint.Keys, number)
		}
		if definition.expression != "" {
			expression := definition.expression
			constraint.Expression = &expression
		}
		table.Constraints = append(table.Constraints, constraint)
		if definition.kind == "p" || definition.kind == "u" {
			index, err := expected.index("", table, definition.keys, definition.kind == "p", true, true)
			if err != nil {
				return nil, err
			}
			table.Indexes = append(table.Indexes, index)
		}
	}
	return table, nil
}

// The caller uses pgControlSession so deparsing has the same fixed search path
// and formatting settings as installation. This verifier performs catalog reads
// only and works in a READ ONLY transaction without TEMP or schema CREATE grants.
func pgControlTableCatalogReadOnly(ctx context.Context, tx pgx.Tx, namespace, owner, principal string, spec pgMigrationControlTable) error {
	if !pgKnownControlTable(spec) {
		return fmt.Errorf("unsupported migration control table specification %q", spec.name)
	}
	metadata, err := pgReadCatalogExpectations(ctx, tx)
	if err != nil {
		return err
	}
	expected, err := pgExpectedControlTable(metadata, owner, spec)
	if err != nil {
		return err
	}
	actual, err := pgReadMigrationTable(ctx, tx, namespace, spec.name)
	if err != nil {
		return err
	}
	if actual == nil {
		return fmt.Errorf("protected migration table %s.%s is missing", namespace, spec.name)
	}
	if !reflect.DeepEqual(pgCanonicalMigrationTable(actual), pgCanonicalMigrationTable(expected)) {
		return fmt.Errorf("protected migration table %s.%s differs from control format %d", namespace, spec.name, pgMigrationControlFormat)
	}
	if err := pgControlTableACL(ctx, tx, namespace, spec.name, principal); err != nil {
		return err
	}
	sequences, err := pgReadControlSequences(ctx, tx, namespace, spec.name, principal)
	if err != nil {
		return err
	}
	expectedSequences := []pgControlSequence{}
	if spec == pgMigrationFenceRegistry {
		var int4 uint32
		if err := tx.QueryRow(ctx, "select 'pg_catalog.int4'::pg_catalog.regtype::oid").Scan(&int4); err != nil {
			return err
		}
		expectedSequences = append(expectedSequences, pgControlSequence{Column: "fence_ns", Owner: owner, Type: int4,
			Start: 1, Increment: 1, Min: 1, Max: 2147483647, Cache: 1})
	}
	if !reflect.DeepEqual(sequences, expectedSequences) {
		return fmt.Errorf("protected migration sequence for %s.%s has a different definition, owner or write grant", namespace, spec.name)
	}
	return nil
}
