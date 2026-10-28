package teslrt

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
)

// PgMigrationCatalogIssue names an observed catalog difference. A report is an
// observation, not authority to repair, expand, admit a binary or prune history.
type PgMigrationCatalogIssue struct {
	Table, Object, Reason string
}

type PgMigrationCatalogReport struct {
	Fingerprint string
	Missing     []PgMigrationCatalogIssue
	Drift       []PgMigrationCatalogIssue
	Benign      []PgMigrationCatalogIssue
}

// PgMigrationCatalogTable is the expected physical superset at one recorded
// history position, including columns and indexes retained for admitted builds.
// Defaults are canonical compiler literals; nil means no database default.
type PgMigrationCatalogTable struct {
	Name    string
	Columns []PgMigrationCatalogColumn
	Indexes []PgMigrationCatalogIndex
}
type PgMigrationCatalogColumn struct {
	Name, Type           string
	Nullable, PrimaryKey bool
	Default              *PgMigrationCatalogConstant
}
type PgMigrationCatalogConstant struct{ Kind, Value string }
type PgMigrationCatalogIndex struct {
	Name    string
	Columns []string
	Unique  bool
}

type pgCatalogColumn struct {
	Number                              int
	Name, Type, TypeNamespace, TypeKind string
	TypeSQL                             string
	Typmod                              int
	Collation, TypeCollation            uint32
	Required                            bool
	Generated, Identity                 string
	Default                             *string
}
type pgCatalogIndex struct {
	Name, Method                          string
	Unique, Primary, Exclusion, Immediate bool
	Valid, Ready, Live, NullsNotDistinct  bool
	ConstraintOwned                       bool
	KeyCount, AttributeCount              int
	Keys                                  []int
	Opclasses, Collations, Options        []int64
	Expression, Predicate                 *string
}
type pgCatalogConstraint struct {
	Name, Kind                                string
	Validated, Deferrable, Deferred, Enforced bool
	Keys                                      []int
	Expression                                *string
}
type pgCatalogTable struct {
	Name, Kind, Persistence, Owner, Method string
	RLS, ForceRLS, Partition, Inherits     bool
	Columns                                []pgCatalogColumn
	Indexes                                []pgCatalogIndex
	Constraints                            []pgCatalogConstraint
	Triggers, Policies, Rules              []string
	TriggerDefinitions                     []pgCatalogTrigger `json:",omitempty"`
}

// Catalog observation is kept independent of the test harness's catalog reader.
// No live entity row is selected. Names and deparsed expressions are data; none
// of the SQL below evaluates a stored default, rule, policy or trigger.
const pgMigrationCatalogSQL = `select jsonb_build_object(
 'Name',c.relname,'Kind',c.relkind,'Persistence',c.relpersistence,'Owner',owner.rolname,'Method',am.amname,
 'RLS',c.relrowsecurity,'ForceRLS',c.relforcerowsecurity,'Partition',c.relispartition,
 'Inherits',exists(select 1 from pg_catalog.pg_inherits h where h.inhrelid=c.oid or h.inhparent=c.oid),
 'Columns',coalesce((select jsonb_agg(jsonb_build_object(
  'Number',a.attnum,'Name',a.attname,'Type',t.typname,'TypeNamespace',tn.nspname,'TypeKind',t.typtype,
  'TypeSQL',pg_catalog.format_type(a.atttypid,a.atttypmod),'Typmod',a.atttypmod,
  'Collation',a.attcollation::bigint,'TypeCollation',t.typcollation::bigint,'Required',a.attnotnull,
  'Generated',a.attgenerated,'Identity',a.attidentity,'Default',pg_catalog.pg_get_expr(d.adbin,d.adrelid)) order by a.attname)
  from pg_catalog.pg_attribute a join pg_catalog.pg_type t on t.oid=a.atttypid
  join pg_catalog.pg_namespace tn on tn.oid=t.typnamespace
  left join pg_catalog.pg_attrdef d on d.adrelid=a.attrelid and d.adnum=a.attnum
  where a.attrelid=c.oid and a.attnum>0 and not a.attisdropped),'[]'::jsonb),
 'Indexes',coalesce((select jsonb_agg(jsonb_build_object(
  'Name',ix.relname,'Method',ia.amname,'Unique',i.indisunique,'Primary',i.indisprimary,
  'Exclusion',i.indisexclusion,'Immediate',i.indimmediate,'Valid',i.indisvalid,'Ready',i.indisready,'Live',i.indislive,
  'NullsNotDistinct',coalesce((to_jsonb(i)->>'indnullsnotdistinct')::boolean,false),
  'ConstraintOwned',exists(select 1 from pg_catalog.pg_constraint k where k.conindid=i.indexrelid and k.conrelid=c.oid),
  'KeyCount',i.indnkeyatts,'AttributeCount',i.indnatts,'Keys',i.indkey::smallint[],
  'Opclasses',i.indclass::oid[]::bigint[],'Collations',i.indcollation::oid[]::bigint[],'Options',i.indoption::smallint[],
  'Expression',pg_catalog.pg_get_expr(i.indexprs,i.indrelid),'Predicate',pg_catalog.pg_get_expr(i.indpred,i.indrelid)) order by ix.relname)
  from pg_catalog.pg_index i join pg_catalog.pg_class ix on ix.oid=i.indexrelid
  join pg_catalog.pg_am ia on ia.oid=ix.relam where i.indrelid=c.oid),'[]'::jsonb),
 'Constraints',coalesce((select jsonb_agg(jsonb_build_object(
  'Name',k.conname,'Kind',k.contype,'Validated',k.convalidated,'Deferrable',k.condeferrable,'Deferred',k.condeferred,
  'Enforced',coalesce((to_jsonb(k)->>'conenforced')::boolean,true),'Keys',k.conkey,
  'Expression',pg_catalog.pg_get_expr(k.conbin,k.conrelid)) order by k.conname)
  from pg_catalog.pg_constraint k where k.conrelid=c.oid),'[]'::jsonb),
 'Triggers',coalesce((select jsonb_agg(t.tgname order by t.tgname) from pg_catalog.pg_trigger t where t.tgrelid=c.oid),'[]'::jsonb),
 'TriggerDefinitions',` + pgMigrationTriggerCatalogSQL + `,
 'Policies',coalesce((select jsonb_agg(p.polname order by p.polname) from pg_catalog.pg_policy p where p.polrelid=c.oid),'[]'::jsonb),
 'Rules',coalesce((select jsonb_agg(r.rulename order by r.rulename) from pg_catalog.pg_rewrite r where r.ev_class=c.oid),'[]'::jsonb)
)::text from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace
 join pg_catalog.pg_roles owner on owner.oid=c.relowner left join pg_catalog.pg_am am on am.oid=c.relam
 where n.nspname=$1 and c.relname=$2`

func pgReadMigrationTable(ctx context.Context, tx pgx.Tx, namespace, name string) (*pgCatalogTable, error) {
	return pgReadMigrationTableForRoles(ctx, tx, namespace, name, nil)
}

// pgReadMigrationTableForRoles adds effective function privileges for the named
// deployment roles. Unrelated cluster roles are not part of the observation.
func pgReadMigrationTableForRoles(ctx context.Context, tx pgx.Tx, namespace, name string, roles []string) (*pgCatalogTable, error) {
	roles = slices.Clone(roles)
	slices.Sort(roles)
	roles = slices.Compact(roles)
	for _, role := range roles {
		if !pgMigrationIdentifier(role) {
			return nil, fmt.Errorf("invalid migration catalog role name")
		}
	}
	var raw string
	if err := tx.QueryRow(ctx, pgMigrationCatalogSQL, namespace, name, roles).Scan(&raw); err == pgx.ErrNoRows {
		return nil, nil
	} else if err != nil {
		return nil, err
	}
	if len(raw) > 64<<20 {
		return nil, fmt.Errorf("migration catalog observation exceeds 64 MiB")
	}
	var table pgCatalogTable
	if err := json.Unmarshal([]byte(raw), &table); err != nil {
		return nil, fmt.Errorf("decode migration catalog: %w", err)
	}
	// Empty optional observations stay nil so legacy no-trigger fingerprints and
	// read-only expected tables keep their exact representation.
	if len(table.TriggerDefinitions) == 0 {
		table.TriggerDefinitions = nil
	}
	for _, trigger := range table.TriggerDefinitions {
		for _, role := range trigger.Function.Roles {
			if !role.Exists {
				return nil, fmt.Errorf("migration catalog role %q is missing", role.Role)
			}
		}
	}
	return &table, nil
}

func pgMigrationIdentifier(name string) bool {
	return name != "" && len(name) <= 63 && utf8.ValidString(name) && !strings.ContainsRune(name, 0)
}

// InspectPgMigrationCatalog borrows an idle connection exclusively and rolls back
// its own repeatable-read transaction, including every temporary comparison
// object and local setting. A caller applying a plan must additionally hold its
// migration coordination locks and validate persisted history/ABI/ownership.
func InspectPgMigrationCatalog(ctx context.Context, conn *pgx.Conn, namespace, owner string,
	expected []PgMigrationCatalogTable) (report PgMigrationCatalogReport, resultErr error) {
	if !pgMigrationIdentifier(namespace) || !pgMigrationIdentifier(owner) {
		return report, fmt.Errorf("migration catalog requires valid namespace and owner names")
	}
	if err := pgValidateMigrationCatalog(expected); err != nil {
		return report, err
	}
	if conn == nil || conn.IsClosed() || conn.PgConn().TxStatus() != 'I' {
		return report, fmt.Errorf("migration catalog inspection requires an idle open connection")
	}
	if err := ctx.Err(); err != nil {
		return report, err
	}
	tx, err := conn.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead})
	if err != nil {
		return report, err
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := tx.Rollback(cleanup); err != nil && !errors.Is(err, pgx.ErrTxClosed) {
			resultErr = errors.Join(resultErr, fmt.Errorf("rollback migration catalog inspection: %w", err))
			_ = conn.Close(cleanup)
		}
	}()
	if _, err = tx.Exec(ctx, `set local search_path = ''; set local standard_conforming_strings = on;
set local DateStyle = 'ISO, YMD'; set local IntervalStyle = 'postgres'; set local TimeZone = 'UTC';
set local extra_float_digits = 3; set local bytea_output = 'hex'`); err != nil {
		return report, err
	}
	var serverVersion int
	if err = tx.QueryRow(ctx, "select pg_catalog.current_setting('server_version_num')::integer").Scan(&serverVersion); err != nil {
		return report, err
	}
	if serverVersion < 140000 || serverVersion >= 190000 {
		return report, fmt.Errorf("migration catalog inspection supports PostgreSQL 14 through 18, got %d", serverVersion)
	}
	return pgInspectMigrationCatalogInTx(ctx, tx, namespace, owner, expected)
}

// Compare within the caller's transaction, including its uncommitted DDL. The
// savepoint removes all comparison objects without rolling back caller changes.
func pgInspectMigrationCatalogInTx(ctx context.Context, tx pgx.Tx, namespace, owner string,
	expected []PgMigrationCatalogTable) (report PgMigrationCatalogReport, resultErr error) {
	if err := pgValidateMigrationCatalog(expected); err != nil {
		return report, err
	}
	if _, err := tx.Exec(ctx, "SAVEPOINT tesl_catalog_observation"); err != nil {
		return report, err
	}
	defer func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if _, err := tx.Exec(cleanup, "ROLLBACK TO SAVEPOINT tesl_catalog_observation; RELEASE SAVEPOINT tesl_catalog_observation"); err != nil {
			resultErr = errors.Join(resultErr, fmt.Errorf("clean up migration comparison objects: %w", err))
		}
	}()
	var observed []*pgCatalogTable
	for _, want := range expected {
		actual, err := pgReadMigrationTable(ctx, tx, namespace, want.Name)
		if err != nil {
			return report, err
		}
		if actual == nil {
			observed = append(observed, &pgCatalogTable{Name: want.Name})
			report.Missing = append(report.Missing, PgMigrationCatalogIssue{Table: want.Name, Object: want.Name, Reason: "table is absent"})
			continue
		}
		observed = append(observed, actual)
		probeName := "tesl_mig_probe_" + rand.Text()
		probe, err := pgCreateMigrationProbe(ctx, tx, probeName, want)
		if err != nil {
			return report, fmt.Errorf("migration comparison for %s: %w", want.Name, err)
		}
		if err := pgCompareMigrationTable(ctx, tx, owner, actual, probe, &report); err != nil {
			return report, err
		}
	}
	return pgFinishMigrationCatalogReport(report, namespace, owner, observed)
}

func pgFinishMigrationCatalogReport(report PgMigrationCatalogReport, namespace, owner string,
	observed []*pgCatalogTable) (PgMigrationCatalogReport, error) {
	// Physical attribute numbers and equivalent index/constraint names are not
	// storage semantics. Normalize a copy; diagnostics retain the original names.
	for i, table := range observed {
		observed[i] = pgCanonicalMigrationTable(table)
	}
	slices.SortFunc(observed, func(a, b *pgCatalogTable) int {
		return strings.Compare(a.Name, b.Name)
	})
	encoded, err := json.Marshal(struct {
		Namespace, Owner string
		Tables           []*pgCatalogTable
	}{namespace, owner, observed})
	if err != nil {
		return report, err
	}
	hash := sha256.Sum256(append([]byte("tesl-postgres-catalog-v1\x00"), encoded...))
	report.Fingerprint = hex.EncodeToString(hash[:])
	return report, nil
}

func pgCanonicalMigrationTable(table *pgCatalogTable) *pgCatalogTable {
	canonical := *table
	canonical.Columns = slices.Clone(table.Columns)
	canonical.Indexes = slices.Clone(table.Indexes)
	canonical.Constraints = slices.Clone(table.Constraints)
	canonical.TriggerDefinitions = slices.Clone(table.TriggerDefinitions)
	slices.SortFunc(canonical.Columns, func(a, b pgCatalogColumn) int { return strings.Compare(a.Name, b.Name) })
	ordinals := make(map[int]int, len(canonical.Columns))
	for i := range canonical.Columns {
		column := &canonical.Columns[i]
		ordinals[column.Number], column.Number = i+1, i+1
	}
	keys := func(numbers []int) []int {
		result := make([]int, len(numbers))
		for i, number := range numbers {
			// Zero denotes an expression index key. Negative numbers identify
			// system columns and retain their meaning across physical layouts.
			result[i] = number
			if number > 0 {
				result[i] = ordinals[number]
			}
		}
		return result
	}
	for i := range canonical.Indexes {
		index := &canonical.Indexes[i]
		index.Name, index.Keys = "", keys(index.Keys)
	}
	for i := range canonical.Constraints {
		constraint := &canonical.Constraints[i]
		constraint.Name, constraint.Keys = "", keys(constraint.Keys)
	}
	for i := range canonical.TriggerDefinitions {
		canonical.TriggerDefinitions[i].Columns = keys(canonical.TriggerDefinitions[i].Columns)
	}
	// These fixed structs contain only JSON primitives, so encoding cannot fail.
	slices.SortFunc(canonical.Indexes, func(a, b pgCatalogIndex) int {
		left, _ := json.Marshal(a)
		right, _ := json.Marshal(b)
		return strings.Compare(string(left), string(right))
	})
	slices.SortFunc(canonical.Constraints, func(a, b pgCatalogConstraint) int {
		left, _ := json.Marshal(a)
		right, _ := json.Marshal(b)
		return strings.Compare(string(left), string(right))
	})
	return &canonical
}
