package teslrt

import (
	"context"
	"fmt"
	"github.com/jackc/pgx/v5"
	"strings"
)

// Test-only bridge to the internal installer boundary. It accepts the actual
// generated database pointer; no source, hashes, codec callbacks or SQL names
// can be supplied as compiler authority.
func TeslTestRowQueueCatalogInstall(ctx context.Context, conn *pgx.Conn, database *Database, roles PgMigrationControlRoles) (PgMigrationControlState, error) {
	return pgInstallCompiledRowQueueCatalog(ctx, conn, database, roles)
}
func TeslTestRowQueueCatalogInspect(ctx context.Context, conn *pgx.Conn, database *Database, roles PgMigrationControlRoles) error {
	baseline, err := pgCompiledRowBaseline(database)
	if err != nil {
		return err
	}
	return pgControlSnapshotMode(ctx, conn, pgx.ReadOnly, func(tx pgx.Tx) error {
		_, _, err := pgReadRowBaselineState(ctx, tx, baseline, roles, false)
		return err
	})
}
func TeslTestRowQueueCatalogExpand(ctx context.Context, conn *pgx.Conn, database *Database, roles PgMigrationControlRoles) (PgMigrationControlState, error) {
	baseline, err := pgCompiledRowBaseline(database)
	if err != nil {
		return PgMigrationControlState{}, err
	}
	return pgExecuteRowBaseline(ctx, conn, baseline, roles)
}

// Direct Worker-function calibration from the actual emitted V2 plan. Only the
// negative source snapshot field is changed; canonical queue/binding hashes are
// rebuilt to ensure refusal is attributable to the stored physical header.
func TeslTestRowQueueBadSource(ctx context.Context, conn *pgx.Conn, database *Database, field string, persistPhysical bool) error {
	b, err := pgCompiledRowBaseline(database)
	if err != nil {
		return err
	}
	if b.target == nil || b.target.version != 2 || len(b.queues) != 2 {
		return fmt.Errorf("test requires actual V2 source")
	}
	plan := b.target
	operations, err := pgRowForwardOperations(b.physical, plan)
	if err != nil {
		return err
	}
	document, err := pgRowBaselineHex(plan.contract)
	if err != nil {
		return err
	}
	tx, err := conn.Begin(ctx)
	if err != nil {
		return err
	}
	defer func(owned pgx.Tx) { _ = owned.Rollback(ctx) }(tx)
	ns := quoteIdentifier(b.history.Namespace) + "."
	if _, err := tx.Exec(ctx, "select "+ns+"tesl_register_row_physical($1,$2,$3,$4,$5,$6,$7,$8)", 2, b.physical.hash, document, plan.hash, b.history.SourceCompilerABI, b.history.StoredValueCompatibility, len(operations), len(plan.windows) == 0); err != nil {
		return err
	}
	if persistPhysical {
		if err := tx.Commit(ctx); err != nil {
			return err
		}
		tx, err = conn.Begin(ctx)
		if err != nil {
			return err
		}
		defer func(owned pgx.Tx) { _ = owned.Rollback(ctx) }(tx)
	}
	source := b.queues[1].version
	switch field {
	case "schema":
		source.SchemaSnapshotHash = strings.Repeat("a", 64)
	case "storage":
		source.StorageSnapshotHash = strings.Repeat("b", 64)
	default:
		return fmt.Errorf("unknown negative field")
	}
	changed, err := pgRowQueueSourceBinding(b.history, source)
	if err != nil {
		return err
	}
	contracts, err := pgQueueRegistrationJSON(source.Contracts)
	if err != nil {
		return err
	}
	_, err = tx.Exec(ctx, "select "+ns+"tesl_register_row_queue_source($1,$2,$3,$4,$5,$6,$7,$8,$9::jsonb,$10,$11,$12)", b.history.Family, 2, source.StorageSnapshotHash, source.SchemaSnapshotHash, b.history.SourceCompilerABI, b.history.StoredValueCompatibility, source.SourceSealInventory, changed.inventoryHash, string(contracts), []byte(changed.binding), changed.bindingHash, plan.hash)
	return err
}

func TeslTestRowQueueHeaderCases(ctx context.Context, conn *pgx.Conn, database *Database) error {
	b, err := pgCompiledRowBaseline(database)
	if err != nil {
		return err
	}
	plan := b.target
	if plan == nil {
		return fmt.Errorf("missing actual physical plan")
	}
	raw, err := pgRowBaselineHex(plan.contract)
	if err != nil {
		return err
	}
	ns := quoteIdentifier(b.history.Namespace) + "."
	var valid bool
	if err := conn.QueryRow(ctx, "select h->>'family'=$2 and h->>'namespace'=$3 and h->>'version'=$4 and h->>'schema'=$5 and h->>'storage'=$6 from (select "+ns+"tesl_row_physical_source_header($1) h) s", raw, b.history.Family, b.history.Namespace, fmt.Sprint(plan.version), plan.schemaSnapshotHash, plan.storageSnapshotHash).Scan(&valid); err != nil || !valid {
		return fmt.Errorf("actual physical header: %v", err)
	}
	reader := &pgMigrationWireReader{}
	node := pgRowDocument(reader, plan.contract, plan.hash, "migration")
	if reader.err != nil {
		return reader.err
	}
	tag := node.children[0].value
	atom := fmt.Sprintf("s%d:", len(tag))
	prefix := "l4:s24:tesl-migration-canonicals1:1s9:migration"
	header := fmt.Sprintf("%sl%d:", prefix, len(node.children))
	cases := map[string][]byte{
		"huge length":        []byte(strings.Replace(string(raw), atom+tag, "s99999999999:"+tag, 1)),
		"leading zero":       []byte(strings.Replace(string(raw), atom+tag, "s0"+fmt.Sprint(len(tag))+":"+tag, 1)),
		"negative length":    []byte(strings.Replace(string(raw), atom+tag, "s-1:"+tag, 1)),
		"truncated prefix":   raw[:4],
		"truncated atom":     []byte(header + atom + "te"),
		"wrong list width":   []byte(strings.Replace(string(raw), header, prefix+"l7:", 1)),
		"unknown descriptor": []byte(strings.Replace(string(raw), tag, strings.TrimSuffix(tag, tag[len(tag)-1:])+"9", 1)),
	}
	node.children[4] = pgRowAtom(strings.Repeat("A", 64))
	changed, _ := pgRowBaselineDocument(node)
	cases["noncanonical hash"] = []byte(changed)
	for label, bytes := range cases {
		var result []byte
		if err := conn.QueryRow(ctx, "select "+ns+"tesl_row_physical_source_header($1)", bytes).Scan(&result); err == nil {
			return fmt.Errorf("physical header accepted %s", label)
		}
	}
	return nil
}
