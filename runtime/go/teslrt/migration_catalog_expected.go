package teslrt

import (
	"context"
	"errors"
	"fmt"
	"math"
	"math/big"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// Request logins do not need CREATE or TEMPORARY privileges to check a stored
// schema. These expectations use only closed compiler types and PostgreSQL's
// builtin metadata. They never parse or execute a live default expression.
// Independent tests compare these structures with the installer's DDL probes
// on every supported PostgreSQL major.
type pgCatalogExpectedType struct {
	name, kind, sql string
	collation       uint32
	opclass         int64
}

type pgCatalogExpectations struct {
	types      map[string]pgCatalogExpectedType
	postgres18 bool
}

func pgReadCatalogExpectations(ctx context.Context, tx pgx.Tx) (*pgCatalogExpectations, error) {
	var version int
	if err := tx.QueryRow(ctx, "select pg_catalog.current_setting('server_version_num')::integer").Scan(&version); err != nil {
		return nil, err
	}
	if version < 140000 || version >= 190000 {
		return nil, fmt.Errorf("read-only migration catalog supports PostgreSQL 14 through 18, got %d", version)
	}
	names := []string{"int2", "int4", "int8", "numeric", "float8", "text", "bool", "jsonb", "uuid", "timestamptz", "_text"}
	rows, err := tx.Query(ctx, `select t.typname,t.typtype,pg_catalog.format_type(t.oid,-1),t.typcollation,o.oid::bigint
 from pg_catalog.pg_type t join pg_catalog.pg_namespace n on n.oid=t.typnamespace
 join pg_catalog.pg_opclass o on (o.opcintype=t.oid or
   (t.typname='_text' and o.opcintype='pg_catalog.anyarray'::pg_catalog.regtype)) and o.opcdefault and o.opcnamespace=n.oid
 join pg_catalog.pg_am a on a.oid=o.opcmethod and a.amname='btree'
 where n.nspname='pg_catalog' and t.typname=any($1::text[]) order by t.typname`, names)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	expected := &pgCatalogExpectations{types: make(map[string]pgCatalogExpectedType), postgres18: version >= 180000}
	for rows.Next() {
		var typ pgCatalogExpectedType
		if err := rows.Scan(&typ.name, &typ.kind, &typ.sql, &typ.collation, &typ.opclass); err != nil {
			return nil, err
		}
		if _, duplicate := expected.types[typ.name]; duplicate || typ.kind != "b" || typ.opclass == 0 {
			return nil, fmt.Errorf("ambiguous builtin migration type %q", typ.name)
		}
		expected.types[typ.name] = typ
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	if len(expected.types) != len(names) {
		return nil, fmt.Errorf("builtin migration catalog types or default btree operator classes are missing")
	}
	return expected, nil
}

func pgNewExpectedCatalogTable(name, owner string) *pgCatalogTable {
	return &pgCatalogTable{Name: name, Owner: owner, Kind: "r", Persistence: "p", Method: "heap",
		Columns: []pgCatalogColumn{}, Indexes: []pgCatalogIndex{}, Constraints: []pgCatalogConstraint{},
		Triggers: []string{}, Policies: []string{}, Rules: []string{}}
}

func (e *pgCatalogExpectations) column(number int, name, typeName string, required bool) (pgCatalogColumn, error) {
	typ, found := e.types[typeName]
	if !found || number < 1 || !pgMigrationIdentifier(name) {
		return pgCatalogColumn{}, fmt.Errorf("unsupported expected migration column %q/%q", name, typeName)
	}
	return pgCatalogColumn{Number: number, Name: name, Type: typeName, TypeNamespace: "pg_catalog", TypeKind: typ.kind,
		TypeSQL: typ.sql, Typmod: -1, Collation: typ.collation, TypeCollation: typ.collation, Required: required}, nil
}

func (e *pgCatalogExpectations) index(name string, table *pgCatalogTable, keys []string,
	primary, unique, constraintOwned bool) (pgCatalogIndex, error) {
	index := pgCatalogIndex{Name: name, Method: "btree", Primary: primary, Unique: unique, ConstraintOwned: constraintOwned,
		Immediate: true, Valid: true, Ready: true, Live: true, KeyCount: len(keys), AttributeCount: len(keys)}
	for _, key := range keys {
		found := false
		for _, column := range table.Columns {
			if column.Name == key {
				typ, known := e.types[column.Type]
				if !known {
					return index, fmt.Errorf("unsupported expected index type %q", column.Type)
				}
				index.Keys = append(index.Keys, column.Number)
				index.Opclasses = append(index.Opclasses, typ.opclass)
				index.Collations = append(index.Collations, int64(column.Collation))
				index.Options = append(index.Options, 0)
				found = true
				break
			}
		}
		if !found {
			return index, fmt.Errorf("missing expected migration index column %q", key)
		}
	}
	return index, nil
}

// This is PostgreSQL's deparse form of the closed literal language produced by
// pgMigrationColumnSQL, not a normalizer for arbitrary SQL. Numeric constants
// retain the parser's int4/int8/numeric choice; floats use the server's own
// float8 output function, including negative zero and its exponent spelling.
func pgExpectedMigrationDefault(ctx context.Context, tx pgx.Tx, column PgMigrationCatalogColumn) (*string, error) {
	if column.Default == nil {
		return nil, nil
	}
	input, err := pgMigrationConstantInput(column.Type, *column.Default)
	if err != nil {
		return nil, err
	}
	quote := func(value string) string { return "'" + strings.ReplaceAll(value, "'", "''") + "'" }
	var expression string
	switch column.Default.Kind {
	case "int":
		n, ok := new(big.Int).SetString(input, 10)
		if !ok {
			return nil, fmt.Errorf("invalid compiler numeric literal")
		}
		switch {
		case n.IsInt64() && n.Int64() >= 0 && n.Int64() <= math.MaxInt32:
			expression = input
		case n.IsInt64() && n.Int64() >= math.MinInt32 && n.Int64() <= math.MaxInt32:
			expression = quote(input) + "::integer"
		case n.IsInt64():
			expression = quote(input) + "::bigint"
		default:
			expression = quote(input) + "::numeric"
		}
	case "float64":
		var rendered string
		if err := tx.QueryRow(ctx, "select ($1::pg_catalog.float8)::pg_catalog.text", input).Scan(&rendered); err != nil {
			return nil, err
		}
		expression = quote(rendered) + "::double precision"
	case "string":
		expression = quote(input) + "::text"
	case "bool":
		expression = input
	default:
		return nil, fmt.Errorf("unsupported expected migration literal")
	}
	return &expression, nil
}

func (e *pgCatalogExpectations) entity(ctx context.Context, tx pgx.Tx, want PgMigrationCatalogTable, owner string) (*pgCatalogTable, error) {
	table := pgNewExpectedCatalogTable(want.Name, owner)
	var primary []string
	for i, c := range want.Columns {
		column, err := e.column(i+1, c.Name, c.Type, !c.Nullable)
		if err != nil {
			return nil, err
		}
		column.Default, err = pgExpectedMigrationDefault(ctx, tx, c)
		if err != nil {
			return nil, err
		}
		table.Columns = append(table.Columns, column)
		if c.PrimaryKey {
			primary = append(primary, c.Name)
		}
		if e.postgres18 && column.Required {
			table.Constraints = append(table.Constraints, pgCatalogConstraint{Kind: "n", Keys: []int{column.Number}, Validated: true, Enforced: true})
		}
	}
	index, err := e.index(want.Name+"_pkey", table, primary, true, true, true)
	if err != nil {
		return nil, err
	}
	table.Indexes = append(table.Indexes, index)
	table.Constraints = append(table.Constraints, pgCatalogConstraint{Kind: "p", Keys: index.Keys, Validated: true, Enforced: true})
	for _, declared := range want.Indexes {
		index, err := e.index(declared.Name, table, declared.Columns, false, declared.Unique, false)
		if err != nil {
			return nil, err
		}
		table.Indexes = append(table.Indexes, index)
	}
	return table, nil
}

func pgInspectMigrationCatalogReadOnlyInTx(ctx context.Context, tx pgx.Tx, namespace, owner string,
	expected []PgMigrationCatalogTable) (report PgMigrationCatalogReport, resultErr error) {
	report, _, resultErr = pgInspectMigrationCatalogWithIndexJobsInTx(ctx, tx, namespace, owner, expected, nil, 0)
	return report, resultErr
}

func pgInspectMigrationCatalogWithIndexJobsInTx(ctx context.Context, tx pgx.Tx, namespace, owner string,
	expected []PgMigrationCatalogTable, jobs []pgMigrationIndexJob, version int) (report PgMigrationCatalogReport, ready bool, resultErr error) {
	if !pgMigrationIdentifier(namespace) || !pgMigrationIdentifier(owner) {
		return report, false, fmt.Errorf("migration catalog requires valid namespace and owner names")
	}
	if err := pgValidateMigrationCatalog(expected); err != nil {
		return report, false, err
	}
	metadata, err := pgReadCatalogExpectations(ctx, tx)
	if err != nil {
		return report, false, err
	}
	ready = true
	var observed []*pgCatalogTable
	for _, want := range expected {
		actual, err := pgReadMigrationTable(ctx, tx, namespace, want.Name)
		if err != nil {
			return report, false, err
		}
		if actual == nil {
			observed = append(observed, &pgCatalogTable{Name: want.Name})
			report.Missing = append(report.Missing, PgMigrationCatalogIssue{Table: want.Name, Object: want.Name, Reason: "table is absent"})
			continue
		}
		observed = append(observed, actual)
		comparison, err := metadata.entity(ctx, tx, want, owner)
		if err != nil {
			return report, false, err
		}
		live, required, indexesReady, err := pgPrepareIndexJobCatalog(metadata, actual, comparison, jobs, version, &report)
		if err != nil {
			return report, false, err
		}
		ready = ready && indexesReady
		if err := pgCompareMigrationTableWithExtras(ctx, tx, owner, live, required, &report, pgBenignExtraColumnReadOnly); err != nil {
			return report, false, err
		}
	}
	report, resultErr = pgFinishMigrationCatalogReport(report, namespace, owner, observed)
	return report, ready && len(report.Missing) == 0 && len(report.Drift) == 0, resultErr
}

func pgBenignExtraColumnReadOnly(ctx context.Context, tx pgx.Tx, c pgCatalogColumn) (benign bool, resultErr error) {
	typeSQL, supported := pgCatalogColumnTypeSQL(c)
	if !supported || c.Generated != "" || c.Identity != "" || c.Collation != c.TypeCollation {
		return false, nil
	}
	if c.Default == nil {
		return !c.Required, nil
	}
	literal, ok := parsePgCatalogLiteral(*c.Default, c.Type)
	if !ok || literal.input == nil && c.Required {
		return false, nil
	}
	// Explicit varchar/char casts truncate; an assignment rejects overlength
	// non-space characters. Preserve the assignment check before using a SELECT
	// cast. PostgreSQL's length counts characters, and only ASCII spaces may be
	// discarded on assignment. The actual declared typmod includes four bytes.
	if literal.input != nil && (c.Type == "varchar" || c.Type == "bpchar") && c.Typmod >= 4 {
		if utf8.RuneCountInString(strings.TrimRight(*literal.input, " ")) > c.Typmod-4 {
			return false, nil
		}
	}
	if _, err := tx.Exec(ctx, "SAVEPOINT tesl_readonly_constant"); err != nil {
		return false, err
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_, err := tx.Exec(cleanup, "ROLLBACK TO SAVEPOINT tesl_readonly_constant; RELEASE SAVEPOINT tesl_readonly_constant")
		resultErr = errors.Join(resultErr, err)
	}()
	inputType := literal.inputType
	if inputType == "" {
		inputType = c.Type
	}
	var input any
	if literal.input != nil {
		input = *literal.input
	}
	var null bool
	err := tx.QueryRow(ctx, "select (($1::pg_catalog."+quoteIdentifier(inputType)+")::"+typeSQL+") is null", input).Scan(&null)
	if err == nil {
		return !null || !c.Required, nil
	}
	var pgErr *pgconn.PgError
	if errors.As(err, &pgErr) && strings.HasPrefix(pgErr.Code, "22") {
		return false, nil
	}
	return false, err
}
