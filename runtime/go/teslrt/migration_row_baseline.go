package teslrt

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"slices"
	"strings"

	"github.com/jackc/pgx/v5"
)

const pgRowControlFormat = 5

type pgRowBaselineEntity struct {
	source                 PgRowSourceEntity
	catalog                PgMigrationCatalogTable
	physical, physicalHash string
	ordinal                int
}
type pgRowBaseline struct {
	database                              *Database
	history                               PgCompiledMigrationHistory
	version                               PgRowSourceVersion
	entities                              []pgRowBaselineEntity
	inventory, inventoryHash, catalogHash string
	physical, target                      *pgRowPhysicalPlan
}

// Only the exact private linked compiler artifact and actual sealed App owner
// select this protocol. An arbitrary parsed history or catalog grants nothing.
func pgCompiledRowBaseline(database *Database) (*pgRowBaseline, error) {
	pgMigrationRegistrations.Lock()
	defer pgMigrationRegistrations.Unlock()
	history, versioned := database.CompiledMigrationHistory()
	if !versioned {
		return nil, fmt.Errorf("missing compiled row baseline history")
	}
	compiled := compiledRowHistories[history.Family]
	if compiled == nil {
		return nil, fmt.Errorf("missing compiled row baseline companion")
	}
	if err := pgCheckRowOwner(database, compiled); err != nil {
		return nil, err
	}
	database.mutex.RLock()
	sealed := database.applicationPreflightClosed
	facilityCount := len(database.migrationFacilities)
	database.mutex.RUnlock()
	if !sealed || facilityCount != 0 {
		return nil, fmt.Errorf("row baseline requires sealed complete App facility absence")
	}
	physical := compiledRowPhysicalHistories[compiled]
	if history.CurrentVersion < 1 || history.CurrentVersion > 2147483646 || (history.CurrentVersion != 1 && physical == nil) || (physical == nil && (len(compiled.inventory.Versions) != 1 || len(compiled.inventory.Transforms) != 0)) {
		return nil, fmt.Errorf("row baseline currently supports only fresh V1; data-transform execution is unavailable")
	}
	v := compiled.inventory.Versions[0]
	r := &pgMigrationWireReader{}
	for _, sourceVersion := range compiled.inventory.Versions {
		schema := pgRowDocument(r, sourceVersion.SchemaContract, sourceVersion.SchemaSnapshotHash, "snapshot")
		_, definitions := pgRowClosure(r, schema, history.SourceCompilerABI, history.StoredValueCompatibility)
		for _, definition := range definitions {
			if !definition.atom && len(definition.children) > 0 && definition.children[0].isAtom("queue-schema") {
				r.fail("row baseline requires complete empty queue-schema inventory")
			}
		}
	}
	if r.err != nil {
		return nil, r.err
	}
	result := &pgRowBaseline{database: database, history: history, version: v}
	if physical != nil {
		result.physical = physical.versions[0]
		result.target = physical.versions[history.CurrentVersion-1]
		if history.CurrentVersion > 1 {
			previous := physical.versions[history.CurrentVersion-2]
			if result.target.requiresContractVersion > 0 {
				var err error
				previous, err = pgRowSettledSourceShape(compiled, previous)
				if err != nil {
					return nil, err
				}
			}
			if _, err := pgRowForwardOperations(previous, result.target); err != nil {
				return nil, err
			}
		}
	}
	storage := pgRowDocument(r, v.StorageContract, v.StorageSnapshotHash, "migration")
	if r.err != nil || !storage.list(3) {
		return nil, fmt.Errorf("invalid linked row baseline storage")
	}
	tables := map[string]pgRowCanonical{}
	for _, table := range storage.children[2].children {
		tables[table.children[0].value] = table
	}
	physicalEntries := []pgRowCanonical{}
	inventoryEntries := []pgRowCanonical{}
	for i, entity := range v.Entities {
		if entity.Generation != 1 {
			return nil, fmt.Errorf("row baseline requires original entity generation 1")
		}
		catalog := PgMigrationCatalogTable{Name: entity.Table}
		for _, column := range entity.Columns {
			catalog.Columns = append(catalog.Columns, PgMigrationCatalogColumn{Name: column.Name, Type: column.Type, Nullable: column.Nullable, PrimaryKey: column.PrimaryKey})
		}
		for _, index := range tables[entity.Table].children[2].children {
			item := PgMigrationCatalogIndex{Name: index.children[0].value, Unique: pgRowBool(index.children[2], true)}
			for _, column := range index.children[1].children {
				item.Columns = append(item.Columns, column.value)
			}
			catalog.Indexes = append(catalog.Indexes, item)
		}
		if err := pgValidateMigrationCatalog([]PgMigrationCatalogTable{catalog}); err != nil {
			return nil, err
		}
		catalog.Columns = append(catalog.Columns, PgMigrationCatalogColumn{Name: "_tesl_v", Type: "int2", Default: &PgMigrationCatalogConstant{Kind: "int", Value: "1"}})
		slices.SortFunc(catalog.Columns, func(a, b PgMigrationCatalogColumn) int { return strings.Compare(a.Name, b.Name) })
		columns := []pgRowCanonical{}
		for _, column := range entity.Columns {
			columns = append(columns, pgRowList(pgRowAtom(column.Field), pgRowAtom(column.Name), pgRowAtom(column.Type), pgRowBoolNode(column.Nullable), pgRowBoolNode(column.PrimaryKey)))
		}
		physicalNode := pgRowList(pgRowAtom("tesl-retained-row-storage-v1"), pgRowAtom(history.Family), pgRowAtom(entity.Entity), pgRowAtom(entity.Table), pgRowAtom("1"), pgRowAtom("1"), pgRowList(columns...), tables[entity.Table].children[2], pgRowList(pgRowAtom("_tesl_v"), pgRowAtom("int2"), pgRowAtom("not-null"), pgRowAtom("1")))
		physical, hash := pgRowBaselineDocument(physicalNode)
		result.entities = append(result.entities, pgRowBaselineEntity{source: entity, catalog: catalog, physical: physical, physicalHash: hash, ordinal: i})
		physicalEntries = append(physicalEntries, physicalNode)
		typeNode, _, err := pgReadRowCanonical(entity.TypeContract)
		if err != nil {
			return nil, err
		}
		inventoryEntries = append(inventoryEntries, pgRowList(pgRowAtom(entity.Entity), typeNode, physicalNode))
	}
	_, result.catalogHash = pgRowBaselineDocument(pgRowList(pgRowAtom("tesl-row-baseline-catalog-v1"), pgRowAtom(history.Family), pgRowList(physicalEntries...)))
	result.inventory, result.inventoryHash = pgRowBaselineDocument(pgRowList(pgRowAtom("tesl-row-baseline-inventory-v1"), pgRowAtom(history.Family), pgRowAtom("1"), pgRowAtom(v.SchemaSnapshotHash), pgRowAtom(v.StorageSnapshotHash), pgRowAtom(history.StoredValueCompatibility), pgRowList(inventoryEntries...), pgRowList(pgRowAtom("complete-queues"), pgRowList()), pgRowList(pgRowAtom("complete-facilities"), pgRowList())))
	return result, nil
}
func pgRowBoolNode(value bool) pgRowCanonical {
	if value {
		return pgRowList(pgRowAtom("bool"), pgRowAtom("true"))
	}
	return pgRowList(pgRowAtom("bool"), pgRowAtom("false"))
}
func pgRowBaselineDocument(node pgRowCanonical) (string, string) {
	raw := pgRowEncode(pgRowList(pgRowAtom("tesl-migration-canonical"), pgRowAtom("1"), pgRowAtom("migration"), node))
	return raw, fmt.Sprintf("%x", sha256.Sum256([]byte(raw)))
}
func pgRowBaselineHex(value string) ([]byte, error) {
	data, err := hex.DecodeString(value)
	if err != nil {
		return nil, fmt.Errorf("invalid linked row baseline bytes")
	}
	return data, nil
}

// InstallPgCompiledRowBaseline creates only the format-5 control baseline. The
// Worker subsequently creates marker-bearing entities; requests cannot enter
// until that complete physical baseline is published. Existing formats refuse.
func InstallPgCompiledRowBaseline(ctx context.Context, conn *pgx.Conn, database *Database, roles PgMigrationControlRoles) (PgMigrationControlState, error) {
	if err := PreflightApplicationDatabases(database); err != nil {
		return PgMigrationControlState{}, err
	}
	baseline, err := pgCompiledRowBaseline(database)
	if err != nil {
		return PgMigrationControlState{}, err
	}
	return pgInstallMigrationControlPrepared(ctx, conn, baseline.history.Namespace, roles, 1, nil, &pgRowBaselinePreparation{baseline: baseline, roles: roles})
}

type pgRowBaselinePreparation struct {
	baseline *pgRowBaseline
	roles    PgMigrationControlRoles
}

func (p *pgRowBaselinePreparation) inspect(ctx context.Context, tx pgx.Tx, namespace string, roles PgMigrationControlRoles) (PgMigrationControlState, error) {
	return pgInspectRowControl(ctx, tx, namespace, roles)
}
func (p *pgRowBaselinePreparation) verify(ctx context.Context, tx pgx.Tx, state PgMigrationControlState) error {
	_, _, err := pgReadRowBaselineState(ctx, tx, p.baseline, p.roles, false)
	return err
}

// ExecutePgCompiledRowBaseline borrows the configured Worker connection for the
// exact V1 baseline or a compiler-linked, bounded V1-to-V2 physical expansion.
// Later transitions require a separate protected protocol upgrade.
func ExecutePgCompiledRowBaseline(ctx context.Context, conn *pgx.Conn, database *Database, roles PgMigrationControlRoles) (PgMigrationControlState, error) {
	baseline, err := pgCompiledRowBaseline(database)
	if err != nil {
		return PgMigrationControlState{}, err
	}
	return pgExecuteRowBaseline(ctx, conn, baseline, roles)
}

func pgReadRowBaselineState(ctx context.Context, tx pgx.Tx, b *pgRowBaseline, roles PgMigrationControlRoles, executor bool) (PgMigrationControlState, int, error) {
	state, err := pgInspectRowControl(ctx, tx, b.history.Namespace, roles)
	if err != nil {
		return state, 0, err
	}
	if err := pgVerifyRowBaseline(ctx, tx, b, state); err != nil {
		return state, 0, err
	}
	intents, err := pgReadExpansionIntents(ctx, tx, b.history.Namespace)
	if err != nil {
		return state, 0, err
	}
	forward, err := pgReadRowForwardManifest(ctx, tx, b)
	if err != nil {
		return state, 0, err
	}
	if err := pgVerifyRowExpansionHistory(state, b, intents, forward, executor); err != nil {
		return state, 0, err
	}
	if err := pgVerifyRowWorkState(ctx, tx, b, state, forward); err != nil {
		return state, 0, err
	}
	count := 0
	if intent := intents[1]; intent != nil {
		count = len(intent.Objects)
	}
	completed := 0
	if forward != nil {
		if intent := intents[forward.plan.version]; intent != nil {
			completed = len(intent.Objects)
		}
	}
	if err := pgVerifyRowForwardCatalog(ctx, tx, b, roles, count, forward, completed); err != nil {
		return state, 0, err
	}
	return state, count, nil
}

func pgExecuteRowBaseline(ctx context.Context, conn *pgx.Conn, b *pgRowBaseline, roles PgMigrationControlRoles) (PgMigrationControlState, error) {
	if b.target != nil && b.target.version > 1 {
		return pgExecuteRowForward(ctx, conn, b, roles)
	}
	var initial, result PgMigrationControlState
	err := pgControlTransaction(ctx, conn, false, func(tx pgx.Tx) error {
		if err := pgControlRoles(ctx, tx, roles, false); err != nil {
			return err
		}
		var user, session string
		if err := tx.QueryRow(ctx, "select current_user,session_user").Scan(&user, &session); err != nil {
			return err
		}
		if user != roles.Worker || session != roles.Worker {
			return fmt.Errorf("row baseline expansion requires exact Worker login")
		}
		var err error
		initial, _, err = pgReadRowBaselineState(ctx, tx, b, roles, true)
		return err
	})
	if err != nil {
		return result, err
	}
	err = pgMigrationSessionLock(ctx, conn, initial.FenceNamespace, 2147483647, true, func() error {
		return pgControlTransaction(ctx, conn, false, func(tx pgx.Tx) error {
			if err := pgControlRoles(ctx, tx, roles, false); err != nil {
				return err
			}
			state, count, err := pgReadRowBaselineState(ctx, tx, b, roles, true)
			if err != nil {
				return err
			}
			if state.DatabaseUUID != initial.DatabaseUUID || state.FenceNamespace != initial.FenceNamespace {
				return fmt.Errorf("row baseline identity changed while waiting for boot lock")
			}
			if state.Current >= 1 {
				result = state
				return nil
			}
			if err := tx.Rollback(ctx); err != nil {
				return err
			}
			ns := quoteIdentifier(b.history.Namespace) + "."
			if err := pgExpansionTransaction(ctx, conn, func(tx pgx.Tx) error {
				_, err := tx.Exec(ctx, "select "+ns+"tesl_begin_expansion(1,$1,$2,$3,$4,$5,true)", b.catalogHash, b.inventoryHash, b.history.SourceCompilerABI, b.history.StoredValueCompatibility, len(b.entities))
				return err
			}); err != nil {
				return err
			}
			for i := count; i < len(b.entities); i++ {
				entity := b.entities[i]
				if err := pgExpansionTransaction(ctx, conn, func(tx pgx.Tx) error {
					if err := pgExecuteExpansionOperation(ctx, tx, b.history.Namespace, PgMigrationExpansionOperation{Kind: "create-table", Table: entity.catalog.Name, Columns: entity.catalog.Columns, Indexes: entity.catalog.Indexes}); err != nil {
						return err
					}
					if roles.Request != "" {
						if _, err := tx.Exec(ctx, "grant select,insert,update,delete on "+pgx.Identifier{b.history.Namespace, entity.catalog.Name}.Sanitize()+" to "+quoteIdentifier(roles.Request)); err != nil {
							return err
						}
					}
					migrationBoundary("row-baseline-after-ddl")
					if err := pgVerifyRowPhysicalCatalog(ctx, tx, b, roles, i+1); err != nil {
						return err
					}
					_, err := tx.Exec(ctx, "select "+ns+"tesl_record_expansion_object(1,$1,$2)", i, pgMigrationObjectHash(b.inventoryHash, i))
					return err
				}); err != nil {
					return err
				}
			}
			if err := pgExpansionTransaction(ctx, conn, func(tx pgx.Tx) error {
				if _, _, err := pgReadRowBaselineState(ctx, tx, b, roles, true); err != nil {
					return err
				}
				migrationBoundary("row-baseline-before-publication")
				_, err := tx.Exec(ctx, "select "+ns+"tesl_record_expanded(1)")
				return err
			}); err != nil {
				return err
			}
			return pgControlSnapshotMode(ctx, conn, pgx.ReadOnly, func(tx pgx.Tx) error {
				var err error
				result, _, err = pgReadRowBaselineState(ctx, tx, b, roles, false)
				return err
			})
		})
	})
	if err != nil {
		return PgMigrationControlState{}, err
	}
	return result, nil
}
