package teslrt

import (
	"context"
	"fmt"
	"reflect"

	"github.com/jackc/pgx/v5"
)

// Broadcast rows are never queue claims. The counter lock lasts until publisher
// commit, including an enclosing application transaction, and survives pruning.
const pgBroadcastTable = "tesl_sse_broadcast"
const pgBroadcastClock = "tesl_sse_clock"

func pgHasBroadcast(database *Database) bool {
	database.mutex.RLock()
	defer database.mutex.RUnlock()
	for facility := range database.migrationFacilities {
		if facility.kind == "SSE channel" {
			return true
		}
	}
	return false
}

func pgVerifyBroadcast(ctx context.Context, tx pgx.Tx, namespace string, roles PgMigrationControlRoles, required bool) (bool, error) {
	present, err := pgControlTableExists(ctx, tx, namespace, pgBroadcastTable)
	if err != nil {
		return false, err
	}
	clock, err := pgControlTableExists(ctx, tx, namespace, pgBroadcastClock)
	if err != nil {
		return false, err
	}
	if !present && !clock && !required {
		if err := pgFacilityFunctionCount(ctx, tx, namespace, "tesl_sse_", 0); err != nil {
			return false, err
		}
		return false, nil
	}
	if !present || !clock || roles.Request == "" {
		return false, fmt.Errorf("SSE broadcast storage missing or topology unsupported; run --schema install as Installer")
	}
	metadata, err := pgReadCatalogExpectations(ctx, tx)
	if err != nil {
		return false, err
	}
	for _, name := range []string{pgBroadcastTable, pgBroadcastClock} {
		columns := []pgControlExpectedColumn{{"dispatch_seq", "int8", true, "", false}, {"channel", "text", true, "", false}, {"key", "text", true, "", false}, {"payload", "jsonb", true, "", false}, {"dispatched_at", "timestamptz", true, "", false}}
		keys := []string{"dispatch_seq"}
		checks := []pgControlExpectedConstraint{{kind: "c", expression: "(dispatch_seq > 0)", keys: []string{"dispatch_seq"}}}
		if name == pgBroadcastClock {
			columns = []pgControlExpectedColumn{{"name", "text", true, "", false}, {"value", "int8", true, "", false}}
			keys = []string{"name"}
			checks = []pgControlExpectedConstraint{
				{kind: "c", expression: "(name = 'broadcast'::text)", keys: []string{"name"}},
				{kind: "c", expression: "(value >= 0)", keys: []string{"value"}},
			}
		}
		expected, err := pgBuildExpectedControlTable(metadata, roles.Owner, name, columns, append(checks, pgControlExpectedConstraint{kind: "p", keys: keys}))
		if err != nil {
			return false, err
		}
		actual, err := pgReadMigrationTable(ctx, tx, namespace, name)
		if err != nil {
			return false, err
		}
		if actual == nil || !reflect.DeepEqual(pgCanonicalMigrationTable(actual), pgCanonicalMigrationTable(expected)) {
			return false, fmt.Errorf("SSE catalog differs for %s", name)
		}
		if len(actual.Indexes) != 1 || actual.Indexes[0].Name != name+"_pkey" {
			return false, fmt.Errorf("SSE index identity differs")
		}
		for _, constraint := range actual.Constraints {
			if constraint.Kind == "p" && constraint.Name != name+"_pkey" {
				return false, fmt.Errorf("SSE primary constraint identity differs")
			}
		}
		for _, column := range actual.Columns {
			if column.Number < 1 || column.Number > len(expected.Columns) || column.Name != expected.Columns[column.Number-1].Name {
				return false, fmt.Errorf("SSE physical layout differs")
			}
		}
		var valid bool
		err = tx.QueryRow(ctx, `select
 not exists(select 1 from pg_catalog.aclexplode(coalesce(c.relacl,pg_catalog.acldefault('r',c.relowner))) a
 where a.grantee<>c.relowner and (a.grantee<>(select oid from pg_catalog.pg_roles where rolname=$3)
 or a.privilege_type<>'SELECT' or a.is_grantable))
 and (select count(*) from pg_catalog.aclexplode(c.relacl) a where a.grantee=(select oid from pg_catalog.pg_roles where rolname=$3))=1
 and not pg_catalog.has_table_privilege($3,c.oid,'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
 and not exists(select 1 from pg_catalog.pg_attribute a where a.attrelid=c.oid and a.attacl is not null)
 and not pg_catalog.has_table_privilege($4,c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
 from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace
 where n.nspname=$1 and c.relname=$2`, namespace, name, roles.Request, roles.Worker).Scan(&valid)
		if err != nil {
			return false, err
		}
		if !valid {
			return false, fmt.Errorf("SSE ACL differs for %s", name)
		}
	}
	if err := pgQueueForeignKeyCatalog(ctx, tx, namespace, []string{pgBroadcastClock, pgBroadcastTable}, nil, []string{}); err != nil {
		return false, err
	}
	for _, fn := range pgBroadcastFunctions(namespace) {
		if err := pgControlFunctionCatalog(ctx, tx, namespace, roles, fn); err != nil {
			return false, err
		}
	}
	if err := pgFacilityFunctionCount(ctx, tx, namespace, "tesl_sse_", len(pgBroadcastFunctions(namespace))); err != nil {
		return false, err
	}
	// Worker verifies catalogs without reading event contents. Request startup
	// reads the singleton clock and rejects missing or regressed state.
	return true, nil
}

func pgInstallBroadcast(ctx context.Context, tx pgx.Tx, namespace string, roles PgMigrationControlRoles) error {
	present, err := pgVerifyBroadcast(ctx, tx, namespace, roles, false)
	if err != nil {
		return err
	}
	if roles.Request == "" {
		return fmt.Errorf("SSE requires Worker topology")
	}
	if _, err := tx.Exec(ctx, "set local role "+quoteIdentifier(roles.Owner)); err != nil {
		return err
	}
	if present {
		_, err := pgReadBroadcastClock(ctx, tx, &PostgresDB{schema: namespace})
		return err
	}
	definitions := []struct{ name, columns string }{
		{pgBroadcastClock, "name text primary key check(name='broadcast'), value bigint not null check(value>=0)"},
		{pgBroadcastTable, "dispatch_seq bigint primary key check(dispatch_seq>0), channel text not null, key text not null, payload jsonb not null, dispatched_at timestamptz not null"},
	}
	for _, definition := range definitions {
		qualified := pgx.Identifier{namespace, definition.name}.Sanitize()
		if _, err := tx.Exec(ctx, "create table "+qualified+" ("+definition.columns+"); revoke all on "+qualified+" from public,"+quoteIdentifier(roles.Request)+","+quoteIdentifier(roles.Worker)+"; grant select on "+qualified+" to "+quoteIdentifier(roles.Request)); err != nil {
			return err
		}
	}
	if _, err := tx.Exec(ctx, "insert into "+pgx.Identifier{namespace, pgBroadcastClock}.Sanitize()+" values ('broadcast',0)"); err != nil {
		return err
	}
	for _, fn := range pgBroadcastFunctions(namespace) {
		if _, err := tx.Exec(ctx, pgControlFunctionSQL(namespace, roles.Owner, fn)); err != nil {
			return err
		}
		target := pgx.Identifier{namespace, fn.name}.Sanitize() + "(" + pgControlArgumentTypes(fn) + ")"
		if _, err := tx.Exec(ctx, "revoke all on function "+target+" from public,"+quoteIdentifier(roles.Worker)+","+quoteIdentifier(roles.Request)+"; grant execute on function "+target+" to "+quoteIdentifier(roles.Request)); err != nil {
			return err
		}
	}
	_, err = pgVerifyBroadcast(ctx, tx, namespace, roles, true)
	return err
}

func pgBroadcastConnection(db *PostgresDB) bool {
	return db != nil && db.migration != nil && db.migration.controlFormat == pgRowControlFormat && db.migration.roles.Request != "" && db.queueRuntime != nil
}

func pgWriteBroadcast(ctx context.Context, executor pgExecutor, db *PostgresDB, channel, key, encoded string) (int64, error) {
	var sequence int64
	if db.migration == nil {
		return 0, fmt.Errorf("SSE publish requires a migration version")
	}
	err := executor.QueryRow(ctx, "select "+db.QualifiedTable("tesl_sse_publish")+"($1::integer,$2::text,$3::text,$4::jsonb)", db.migration.version, channel, key, encoded).Scan(&sequence)
	return sequence, err
}

func pgAdmitBroadcastTransaction(ctx context.Context, tx pgx.Tx, db *PostgresDB) error {
	if pgBroadcastConnection(db) {
		if _, err := tx.Exec(ctx, "select pg_catalog.pg_advisory_xact_lock_shared($1::integer,$2::integer)", -db.migration.fenceNamespace, db.migration.version); err != nil {
			return err
		}
	}
	return pgAdmitMigrationTransaction(ctx, tx, db, true)
}

// Both entry points retain fences through caller commit, including direct SQL.
func pgBroadcastFunctions(namespace string) []pgMigrationControlFunction {
	ns := quoteIdentifier(namespace) + "."
	clock := ns + pgBroadcastClock
	table := ns + pgBroadcastTable
	guard := `
 if pg_catalog.current_setting('transaction_isolation')<>'read committed' then raise exception 'tesl: SSE requires read committed'; end if;
 if v is null or v<1 or v>2147483646 then raise exception 'tesl: invalid SSE version'; end if;
 select fence_ns into fence from ` + ns + `tesl_schema_meta where id=1 and format_version=5;
 if not found then raise exception 'tesl: SSE requires format5'; end if;
 perform pg_catalog.pg_advisory_xact_lock_shared(-fence,v);
 perform pg_catalog.pg_advisory_xact_lock_shared(fence,v);
 perform ` + ns + `tesl_admit(v);
 select value into last_seq from ` + clock + ` where name='broadcast' for update;
 if not found or last_seq<0 or (select count(*) from ` + clock + `)<>1 then raise exception 'tesl: invalid SSE singleton clock'; end if;
 if exists(select 1 from ` + table + ` where dispatch_seq>last_seq or dispatch_seq<=0) then raise exception 'tesl: SSE clock is behind retained events'; end if;
`
	return []pgMigrationControlFunction{
		{"tesl_sse_publish", "v integer, channel_name text, channel_key text, encoded jsonb", "bigint", "volatile", `
declare fence integer; last_seq bigint;
begin` + guard + `
 if channel_name is null or channel_key is null or encoded is null then raise exception 'tesl: invalid SSE event'; end if;
 update ` + clock + ` set value=value+1 where name='broadcast' returning value into last_seq;
 insert into ` + table + ` values(last_seq,channel_name,channel_key,encoded,pg_catalog.clock_timestamp());
 perform pg_catalog.pg_notify('tesl_pubsub','');
 return last_seq;
end`},
		{"tesl_sse_prune", "v integer, through_seq bigint", "bigint", "volatile", `
declare fence integer; last_seq bigint; removed bigint;
begin` + guard + `
 if through_seq is null or through_seq<0 or through_seq>last_seq then raise exception 'tesl: invalid SSE prune cursor'; end if;
 delete from ` + table + ` where dispatch_seq<=through_seq and dispatched_at<pg_catalog.clock_timestamp()-interval '1 hour';
 get diagnostics removed = row_count;
 return removed;
end`},
	}
}
