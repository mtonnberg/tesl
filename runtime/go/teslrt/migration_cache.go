package teslrt

import (
	"context"
	"fmt"
	"reflect"

	"github.com/jackc/pgx/v5"
)

// Optional format5 storage installed only by Installer. Cache entries are
// disposable and artifact-scoped; legacy lazy tesl_cache storage is not adopted.
const pgArtifactCacheTable = "tesl_cache_artifacts"
const pgArtifactCacheColumns = "cache_name text not null, codec text not null, key text not null, value jsonb not null, expires_at timestamptz, primary key(cache_name,codec,key)"

func pgVerifyArtifactCache(ctx context.Context, tx pgx.Tx, namespace string, roles PgMigrationControlRoles, required bool) (bool, error) {
	present, err := pgControlTableExists(ctx, tx, namespace, pgArtifactCacheTable)
	if err != nil || !present {
		if err == nil && required {
			err = fmt.Errorf("durable cache storage is missing; run the cache-capable binary's --schema install as Installer")
		}
		return false, err
	}
	if roles.Request == "" {
		return false, fmt.Errorf("artifact cache storage requires Worker topology")
	}
	metadata, err := pgReadCatalogExpectations(ctx, tx)
	if err != nil {
		return false, err
	}
	expected, err := pgBuildExpectedControlTable(metadata, roles.Owner, pgArtifactCacheTable,
		[]pgControlExpectedColumn{{"cache_name", "text", true, "", false}, {"codec", "text", true, "", false}, {"key", "text", true, "", false}, {"value", "jsonb", true, "", false}, {"expires_at", "timestamptz", false, "", false}},
		[]pgControlExpectedConstraint{{kind: "p", keys: []string{"cache_name", "codec", "key"}}})
	if err != nil {
		return false, err
	}
	expected.Persistence = "u"
	actual, err := pgReadMigrationTable(ctx, tx, namespace, pgArtifactCacheTable)
	if err != nil {
		return false, err
	}
	if actual == nil || !reflect.DeepEqual(pgCanonicalMigrationTable(actual), pgCanonicalMigrationTable(expected)) {
		return false, fmt.Errorf("artifact cache catalog differs from the installed contract")
	}
	if len(actual.Indexes) != 1 || actual.Indexes[0].Name != pgArtifactCacheTable+"_pkey" {
		return false, fmt.Errorf("artifact cache primary index identity differs")
	}
	for _, constraint := range actual.Constraints {
		if constraint.Kind == "p" && constraint.Name != pgArtifactCacheTable+"_pkey" {
			return false, fmt.Errorf("artifact cache primary constraint identity differs")
		}
	}
	for _, column := range actual.Columns {
		if column.Number < 1 || column.Number > len(expected.Columns) || column.Name != expected.Columns[column.Number-1].Name {
			return false, fmt.Errorf("artifact cache physical column layout differs")
		}
	}
	var valid bool
	err = tx.QueryRow(ctx, `select
 not exists(select 1 from pg_catalog.aclexplode(coalesce(c.relacl,pg_catalog.acldefault('r',c.relowner))) a
 where a.grantee<>c.relowner and (a.grantee<>(select oid from pg_catalog.pg_roles where rolname=$3)
 or a.privilege_type not in ('SELECT','INSERT','UPDATE','DELETE') or a.is_grantable))
 and (select count(*) from pg_catalog.aclexplode(c.relacl) a where a.grantee=(select oid from pg_catalog.pg_roles where rolname=$3))=4
 and not exists(select 1 from pg_catalog.pg_attribute a where a.attrelid=c.oid and a.attacl is not null)
 and not pg_catalog.has_table_privilege($4,c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
 from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace
 where n.nspname=$1 and c.relname=$2`, namespace, pgArtifactCacheTable, roles.Request, roles.Worker).Scan(&valid)
	if err != nil {
		return false, err
	}
	if !valid {
		return false, fmt.Errorf("artifact cache ACL differs from the request-only DML profile")
	}
	if err := pgVerifyRequestGrants(ctx, tx, namespace, roles, []PgMigrationCatalogTable{{Name: pgArtifactCacheTable}}); err != nil {
		return false, err
	}
	if err := pgQueueForeignKeyCatalog(ctx, tx, namespace, []string{pgArtifactCacheTable}, nil, []string{}); err != nil {
		return false, err
	}
	return true, nil
}

func pgInstallArtifactCache(ctx context.Context, tx pgx.Tx, namespace string, roles PgMigrationControlRoles) error {
	if roles.Request == "" {
		return fmt.Errorf("artifact cache storage requires Worker topology")
	}
	present, err := pgVerifyArtifactCache(ctx, tx, namespace, roles, false)
	if err != nil || present {
		return err
	}
	if _, err := tx.Exec(ctx, "set local role "+quoteIdentifier(roles.Owner)); err != nil {
		return err
	}
	qualified := pgx.Identifier{namespace, pgArtifactCacheTable}.Sanitize()
	if _, err := tx.Exec(ctx, "create unlogged table "+qualified+" ("+pgArtifactCacheColumns+"); revoke all on "+qualified+" from public; grant select,insert,update,delete on "+qualified+" to "+quoteIdentifier(roles.Request)); err != nil {
		return err
	}
	_, err = pgVerifyArtifactCache(ctx, tx, namespace, roles, true)
	return err
}

func pgRequireArtifactCache(db *PostgresDB, codec string) {
	if !pgMigrationDigest(codec) {
		panic("artifact cache requires a compiler codec identity and Worker connection")
	}
	pgCheckArtifactCacheConnection(db)
}

func pgCheckArtifactCacheConnection(db *PostgresDB) {
	if db.migration == nil || db.migration.controlFormat != pgRowControlFormat || db.migration.roles.Request == "" {
		panic("artifact cache requires a format5 Worker connection")
	}
	ctx, cancel := context.WithTimeout(context.Background(), pgLeaseTimeout())
	defer cancel()
	if tx := currentTransactionFor(db); tx != nil {
		if _, err := pgVerifyArtifactCache(ctx, tx, db.schema, db.migration.roles, true); err != nil {
			panic(err)
		}
		return
	}
	tx, err := db.pool.BeginTx(ctx, pgx.TxOptions{AccessMode: pgx.ReadOnly})
	if err != nil {
		panic(err)
	}
	defer func() { _ = tx.Rollback(ctx) }()
	if err := pgControlSession(ctx, tx); err != nil {
		panic(err)
	}
	if _, err := pgVerifyArtifactCache(ctx, tx, db.schema, db.migration.roles, true); err != nil {
		panic(err)
	}
}

func pgHasArtifactCaches(database *Database) bool {
	database.mutex.RLock()
	defer database.mutex.RUnlock()
	for facility := range database.migrationFacilities {
		if facility.kind == "artifact cache" {
			return true
		}
	}
	return false
}
