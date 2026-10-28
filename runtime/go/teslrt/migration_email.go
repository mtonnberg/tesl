package teslrt

import (
	"context"
	"fmt"
	"reflect"

	"github.com/jackc/pgx/v5"
)

// The optional format5 envelope survives application schema retirement. Legacy
// lazy storage is not adopted; requests never install or repair this extension.
const pgEmailTable = "tesl_email_messages"
const pgEmailState = "tesl_email_runtime"
const pgEmailEnvelope = "tesl-email-envelope-v1"

func pgEmailTables() []pgMigrationControlTable {
	return []pgMigrationControlTable{
		{pgEmailState, "id integer primary key, envelope text not null, next_id bigint not null"},
		{pgEmailTable, "id bigint primary key, recipient text, subject text, body_kind text, body_text text, body_html text, status text, attempts integer, next_attempt_at timestamptz, locked_at timestamptz, claim_token text, created_at timestamptz, sent_at timestamptz"},
	}
}

func pgHasEmail(database *Database) bool {
	database.mutex.RLock()
	defer database.mutex.RUnlock()
	_, ok := database.migrationFacilities[pgMigrationFacility{"email outbox", ""}]
	return ok
}

func pgVerifyEmail(ctx context.Context, tx pgx.Tx, namespace string, roles PgMigrationControlRoles, required bool) (bool, error) {
	present, err := pgControlTableExists(ctx, tx, namespace, pgEmailState)
	if err != nil {
		return false, err
	}
	messages, err := pgControlTableExists(ctx, tx, namespace, pgEmailTable)
	if err != nil {
		return false, err
	}
	if !present && !messages && !required {
		if err := pgFacilityFunctionCount(ctx, tx, namespace, "tesl_email_", 0); err != nil {
			return false, err
		}
		return false, nil
	}
	if !present || !messages || roles.Request == "" {
		return false, fmt.Errorf("durable email storage missing or topology unsupported; run --schema install as Installer")
	}
	metadata, err := pgReadCatalogExpectations(ctx, tx)
	if err != nil {
		return false, err
	}
	for _, spec := range pgEmailTables() {
		var columns []pgControlExpectedColumn
		if spec.name == pgEmailState {
			columns = []pgControlExpectedColumn{{"id", "int4", true, "", false}, {"envelope", "text", true, "", false}, {"next_id", "int8", true, "", false}}
		} else {
			columns = []pgControlExpectedColumn{{"id", "int8", true, "", false}}
			for _, name := range []string{"recipient", "subject", "body_kind", "body_text", "body_html", "status"} {
				columns = append(columns, pgControlExpectedColumn{name, "text", false, "", false})
			}
			columns = append(columns, pgControlExpectedColumn{"attempts", "int4", false, "", false}, pgControlExpectedColumn{"next_attempt_at", "timestamptz", false, "", false}, pgControlExpectedColumn{"locked_at", "timestamptz", false, "", false}, pgControlExpectedColumn{"claim_token", "text", false, "", false}, pgControlExpectedColumn{"created_at", "timestamptz", false, "", false}, pgControlExpectedColumn{"sent_at", "timestamptz", false, "", false})
		}
		expected, err := pgBuildExpectedControlTable(metadata, roles.Owner, spec.name, columns, []pgControlExpectedConstraint{{kind: "p", keys: []string{"id"}}})
		if err != nil {
			return false, err
		}
		actual, err := pgReadMigrationTable(ctx, tx, namespace, spec.name)
		if err != nil {
			return false, err
		}
		if actual == nil || !reflect.DeepEqual(pgCanonicalMigrationTable(actual), pgCanonicalMigrationTable(expected)) {
			return false, fmt.Errorf("durable email table %s differs from its immutable envelope", spec.name)
		}
		if len(actual.Indexes) != 1 || actual.Indexes[0].Name != spec.name+"_pkey" {
			return false, fmt.Errorf("durable email primary index differs")
		}
		for _, constraint := range actual.Constraints {
			if constraint.Kind == "p" && constraint.Name != spec.name+"_pkey" {
				return false, fmt.Errorf("durable email primary constraint differs")
			}
		}
		for _, column := range actual.Columns {
			if column.Number < 1 || column.Number > len(columns) || column.Name != columns[column.Number-1].name {
				return false, fmt.Errorf("durable email column layout differs")
			}
		}
		readers := []string{}
		if spec.name == pgEmailState {
			readers = []string{roles.Request, roles.Worker}
		}
		if err := pgQueueTableACL(ctx, tx, namespace, spec.name, readers); err != nil {
			return false, err
		}
		// Explicit ACLs alone do not detect inherited privileges such as
		// pg_read_all_data. Neither login may read claim tokens or mutate rows.
		var unsafe bool
		if err := tx.QueryRow(ctx, `select exists(select 1 from pg_catalog.pg_roles r
 where r.rolname=any($3::text[]) and (
 pg_catalog.has_table_privilege(r.oid,c.oid,'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
 or ($4 and pg_catalog.has_table_privilege(r.oid,c.oid,'SELECT'))))
 from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace
 where n.nspname=$1 and c.relname=$2`, namespace, spec.name, []string{roles.Request, roles.Worker}, spec.name == pgEmailTable).Scan(&unsafe); err != nil {
			return false, err
		}
		if unsafe {
			return false, fmt.Errorf("durable email effective storage privileges differ")
		}
		seqs, err := pgReadControlSequences(ctx, tx, namespace, spec.name, roles.Worker)
		if err != nil {
			return false, err
		}
		if len(seqs) != 0 {
			return false, fmt.Errorf("unexpected durable email sequence")
		}
	}
	if err := pgQueueForeignKeyCatalog(ctx, tx, namespace, []string{pgEmailState, pgEmailTable}, nil, []string{}); err != nil {
		return false, err
	}
	var valid bool
	err = tx.QueryRow(ctx, "select count(*)=1 and bool_and(id=1 and envelope=$1 and next_id>=0 and next_id<=4611686018427387904) from "+pgx.Identifier{namespace, pgEmailState}.Sanitize(), pgEmailEnvelope).Scan(&valid)
	if err != nil {
		return false, err
	}
	if !valid {
		return false, fmt.Errorf("durable email runtime envelope differs")
	}
	for _, fn := range pgEmailFunctions(namespace) {
		if err := pgControlFunctionCatalog(ctx, tx, namespace, roles, fn); err != nil {
			return false, err
		}
	}
	if err := pgFacilityFunctionCount(ctx, tx, namespace, "tesl_email_", len(pgEmailFunctions(namespace))); err != nil {
		return false, err
	}
	return true, nil
}

func pgInstallEmail(ctx context.Context, tx pgx.Tx, namespace string, roles PgMigrationControlRoles) error {
	present, err := pgVerifyEmail(ctx, tx, namespace, roles, false)
	if err != nil || present {
		return err
	}
	if roles.Request == "" {
		return fmt.Errorf("durable email requires Worker topology")
	}
	if _, err := tx.Exec(ctx, "set local role "+quoteIdentifier(roles.Owner)); err != nil {
		return err
	}
	ns := quoteIdentifier(namespace) + "."
	for _, spec := range pgEmailTables() {
		if _, err := tx.Exec(ctx, "create table "+ns+quoteIdentifier(spec.name)+"("+spec.columns+"); revoke all on "+ns+quoteIdentifier(spec.name)+" from public,"+quoteIdentifier(roles.Request)+","+quoteIdentifier(roles.Worker)); err != nil {
			return err
		}
	}
	if _, err := tx.Exec(ctx, "insert into "+ns+pgEmailState+" values(1,$1,0)", pgEmailEnvelope); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, "grant select on "+ns+pgEmailState+" to "+quoteIdentifier(roles.Request)+","+quoteIdentifier(roles.Worker)); err != nil {
		return err
	}
	for _, fn := range pgEmailFunctions(namespace) {
		if _, err := tx.Exec(ctx, pgControlFunctionSQL(namespace, roles.Owner, fn)); err != nil {
			return err
		}
		target := ns + quoteIdentifier(fn.name) + "(" + pgControlArgumentTypes(fn) + ")"
		if _, err := tx.Exec(ctx, "revoke all on function "+target+" from public,"+quoteIdentifier(roles.Worker)+","+quoteIdentifier(roles.Request)+"; grant execute on function "+target+" to "+quoteIdentifier(roles.Request)); err != nil {
			return err
		}
	}
	_, err = pgVerifyEmail(ctx, tx, namespace, roles, true)
	return err
}

func pgRequireEmail(db *PostgresDB) {
	if db.migration == nil || db.migration.controlFormat != pgRowControlFormat || db.migration.roles.Request == "" {
		panic("durable email requires a format5 Worker connection")
	}
	ctx, cancel := context.WithTimeout(context.Background(), pgLeaseTimeout())
	defer cancel()
	verify := func(tx pgx.Tx) {
		if _, err := pgVerifyEmail(ctx, tx, db.schema, db.migration.roles, true); err != nil {
			panic(err)
		}
	}
	if tx := currentTransactionFor(db); tx != nil {
		verify(tx)
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
	verify(tx)
}
