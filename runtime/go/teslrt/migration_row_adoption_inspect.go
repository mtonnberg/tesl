package teslrt

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"reflect"
	"slices"

	"github.com/jackc/pgx/v5"
)

// PgRowAdoptionSummary describes one read-only observation. Neither its hashes
// nor the proposed anchor authorize DDL, registration or subsequent admission.
// An eventual installer must observe again under its own reviewed lock protocol.
type PgRowAdoptionSummary struct {
	Database                 string               `json:"database"`
	Family                   string               `json:"family"`
	Namespace                string               `json:"namespace"`
	DatabaseUUID             string               `json:"databaseUuid"`
	FenceNamespace           int                  `json:"fenceNamespace"`
	LegacyInitialVersion     int                  `json:"legacyInitialVersion"`
	AnchorVersion            int                  `json:"anchorVersion"`
	LegacyReceiptHash        string               `json:"legacyReceiptHash"`
	SourceSnapshotHash       string               `json:"sourceSnapshotHash"`
	CatalogHash              string               `json:"catalogHash"`
	StoredValueCompatibility string               `json:"storedValueCompatibility"`
	Tables                   []PgRowAdoptionTable `json:"tables"`
	SourceSealInventory      []string             `json:"sourceSealInventory"`
}
type PgRowAdoptionTable struct {
	Table      string `json:"table"`
	Generation int    `json:"generation"`
}
type PgRowAdoptionInspection struct{ summary PgRowAdoptionSummary }

func (inspection PgRowAdoptionInspection) Summary() PgRowAdoptionSummary {
	summary := inspection.summary
	summary.Tables = slices.Clone(summary.Tables)
	summary.SourceSealInventory = slices.Clone(summary.SourceSealInventory)
	return summary
}

type pgLegacyRowAdoptionSource struct {
	history PgCompiledMigrationHistory
	queues  PgQueueSourceInventory
}

// This is a restriction of existing registered source, not a history factory.
func pgCompiledLegacyRowAdoptionSource(database *Database) (pgLegacyRowAdoptionSource, error) {
	pgMigrationRegistrations.Lock()
	defer pgMigrationRegistrations.Unlock()
	var empty pgLegacyRowAdoptionSource
	history, ok := database.CompiledMigrationHistory()
	if !ok {
		return empty, fmt.Errorf("row adoption inspection requires an actual compiled database")
	}
	linked, ok := compiledMigrationHistories.Load(history.Family)
	if !ok || linked != history {
		return empty, fmt.Errorf("row adoption source differs from linked compiler history")
	}
	database.mutex.RLock()
	sealed := database.applicationPreflightClosed
	unsupported := len(database.migrationFacilities) != 0 || len(database.migrationQueues) != 0
	namespace := database.Config.Schema
	database.mutex.RUnlock()
	if !sealed || unsupported || namespace != history.Namespace {
		return empty, fmt.Errorf("row adoption inspection requires a sealed facility-free application and exact namespace")
	}
	owners := map[*Database]bool{}
	databaseIdentities.Range(func(_, value any) bool {
		candidate, valid := value.(*Database)
		if !valid {
			return true
		}
		if h, versioned := candidate.CompiledMigrationHistory(); versioned && h.Database == history.Database {
			owners[candidate] = true
		}
		return true
	})
	if len(owners) != 1 || !owners[database] {
		return empty, fmt.Errorf("row adoption requires its exact unique compiled database owner")
	}
	if _, err := history.ExpansionPlan(1); err != nil {
		return empty, err
	}
	queues, err := history.QueueSourceInventory(1)
	if err != nil {
		return empty, err
	}
	if len(queues.Versions) != history.CurrentVersion {
		return empty, fmt.Errorf("row adoption source inventory is incomplete")
	}
	for _, version := range queues.Versions {
		if len(version.Contracts) != 0 {
			return empty, fmt.Errorf("row adoption inspection does not support queued source histories")
		}
	}
	return pgLegacyRowAdoptionSource{history: history, queues: queues}, nil
}

// InspectPgCompiledRowAdoption performs no durable changes and never opens an
// installer connection. It requires the configured Request role and complete
// current legacy source. It does not make a format3 application row5-capable.
func InspectPgCompiledRowAdoption(ctx context.Context, conn *pgx.Conn, database *Database) (PgRowAdoptionInspection, error) {
	var result PgRowAdoptionInspection
	source, err := pgCompiledLegacyRowAdoptionSource(database)
	if err != nil {
		return result, err
	}
	if conn == nil || conn.IsClosed() || conn.PgConn().TxStatus() != 'I' {
		return result, fmt.Errorf("row adoption inspection requires an idle dedicated Request connection")
	}
	roles, err := pgMigrationRoles(database.Config, database.Config.User)
	if err != nil {
		return result, err
	}
	if roles.Request == "" {
		return result, fmt.Errorf("row adoption inspection currently requires Worker topology")
	}
	bounded, cancel := context.WithTimeout(ctx, pgLeaseTimeout())
	defer cancel()
	err = pgControlSnapshotMode(bounded, conn, pgx.ReadOnly, func(tx pgx.Tx) error {
		if err := pgControlRoles(bounded, tx, roles, false); err != nil {
			return err
		}
		var currentUser, sessionUser string
		if err := tx.QueryRow(bounded, "select current_user,session_user").Scan(&currentUser, &sessionUser); err != nil {
			return err
		}
		if currentUser != roles.Request || sessionUser != roles.Request {
			return fmt.Errorf("row adoption inspection requires the configured Request login")
		}
		state, err := pgInspectControlReadOnly(bounded, tx, source.history.Namespace, roles)
		if err != nil {
			return err
		}
		plan, err := source.history.ExpansionPlan(state.InitialVersion)
		if err != nil {
			return err
		}
		intents, err := pgReadExpansionIntents(bounded, tx, source.history.Namespace)
		if err != nil {
			return err
		}
		if err := pgVerifyExpansionHistory(state, plan, intents); err != nil {
			return err
		}
		jobs, err := pgReadMigrationIndexJobs(bounded, tx, source.history.Namespace, intents)
		if err != nil {
			return err
		}
		if err := pgVerifyMigrationIndexJobs(plan, intents, jobs, false); err != nil {
			return err
		}
		if err := pgLegacyRowAdoptionComplete(state, plan, intents, jobs); err != nil {
			return err
		}
		catalog, err := pgExpansionRecordedCatalog(plan, intents)
		if err != nil {
			return err
		}
		fingerprint, err := pgLegacyRowAdoptionCatalog(bounded, tx, source.history.Namespace, roles, catalog)
		if err != nil {
			return err
		}
		if err := pgVerifyRequestGrants(bounded, tx, source.history.Namespace, roles, catalog); err != nil {
			return err
		}
		receiptHash, err := pgLegacyRowAdoptionReceiptHash(bounded, tx, source.history.Namespace)
		if err != nil {
			return err
		}
		summary := PgRowAdoptionSummary{Database: source.history.Database, Family: source.history.Family, Namespace: source.history.Namespace,
			DatabaseUUID: state.DatabaseUUID, FenceNamespace: state.FenceNamespace, LegacyInitialVersion: state.InitialVersion, AnchorVersion: state.Current,
			LegacyReceiptHash: receiptHash, SourceSnapshotHash: plan.Steps[len(plan.Steps)-1].SnapshotHash, CatalogHash: fingerprint,
			StoredValueCompatibility: source.history.StoredValueCompatibility, Tables: []PgRowAdoptionTable{}, SourceSealInventory: []string{}}
		for _, table := range catalog {
			summary.Tables = append(summary.Tables, PgRowAdoptionTable{Table: table.Name, Generation: 1})
		}
		for _, version := range source.queues.Versions {
			summary.SourceSealInventory = append(summary.SourceSealInventory, version.SourceSealInventory)
		}
		result.summary = summary
		return nil
	})
	if err != nil {
		return PgRowAdoptionInspection{}, err
	}
	return result, nil
}

func pgLegacyRowAdoptionComplete(state PgMigrationControlState, plan PgMigrationExpansionPlan, intents map[int]*pgExpansionIntent, jobs []pgMigrationIndexJob) error {
	if state.Format != 3 || state.Current < 1 || state.InstallingVersion != 0 || state.Current != plan.CurrentVersion ||
		state.MaxObservedProtocol != 1 || len(plan.Steps) == 0 || len(intents) != state.Current-state.InitialVersion+1 {
		return fmt.Errorf("row adoption inspection requires exact completed format3 history at this binary's current revision")
	}
	for _, job := range jobs {
		if job.State != "valid" {
			return fmt.Errorf("row adoption requires every index job complete and valid: %s", job.Index.Name)
		}
	}
	return nil
}

// Adoption has no benign-extra-object allowance. Reuse the row comparator's
// normalized attnum handling and separately retain named secondary identities.
func pgLegacyRowAdoptionCatalog(ctx context.Context, tx pgx.Tx, namespace string, roles PgMigrationControlRoles, catalog []PgMigrationCatalogTable) (string, error) {
	metadata, err := pgReadCatalogExpectations(ctx, tx)
	if err != nil {
		return "", err
	}
	names := []string{}
	for _, table := range pgControlTablesForFormat(3) {
		names = append(names, table.name)
	}
	observed := []*pgCatalogTable{}
	for _, table := range catalog {
		names = append(names, table.Name)
		for _, column := range table.Columns {
			if column.Name == "_tesl_v" {
				return "", fmt.Errorf("row adoption cannot accept an unrecorded permanent marker")
			}
		}
		actual, err := pgReadMigrationTable(ctx, tx, namespace, table.Name)
		if err != nil {
			return "", err
		}
		expected, err := metadata.entity(ctx, tx, table, roles.Worker)
		if err != nil {
			return "", err
		}
		if actual == nil || !reflect.DeepEqual(pgCanonicalMigrationTable(actual), pgCanonicalMigrationTable(expected)) {
			return "", fmt.Errorf("row adoption catalog differs from exact source table %q", table.Name)
		}
		actualIndexes, err := pgRowNamedSecondaryIndexes(actual)
		if err != nil {
			return "", err
		}
		expectedIndexes, err := pgRowNamedSecondaryIndexes(expected)
		if err != nil {
			return "", err
		}
		if !reflect.DeepEqual(actualIndexes, expectedIndexes) {
			return "", fmt.Errorf("row adoption secondary index names or shapes differ")
		}
		observed = append(observed, actual)
	}
	var extra bool
	if err := tx.QueryRow(ctx, `select exists(select 1 from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid=c.relnamespace
 where n.nspname=$1 and c.relkind not in ('i','I') and not(c.relname=any($2::text[])))
 or exists(select 1 from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace join pg_catalog.pg_roles r on r.oid=p.proowner
 where n.nspname=$1 and r.rolname<>$3)`, namespace, names, roles.Owner).Scan(&extra); err != nil {
		return "", err
	}
	if extra {
		return "", fmt.Errorf("row adoption namespace contains an unrecorded entity or facility object")
	}
	report, err := pgFinishMigrationCatalogReport(PgMigrationCatalogReport{}, namespace, roles.Worker, observed)
	return report.Fingerprint, err
}

func pgLegacyRowAdoptionReceiptHash(ctx context.Context, tx pgx.Tx, namespace string) (string, error) {
	ns := quoteIdentifier(namespace) + "."
	// Fixed closed-format relations only. Preserve all receipt fields, including
	// creator provenance and timestamps; never relabel them as row-format history.
	parts := []json.RawMessage{}
	for _, item := range []struct{ name, order string }{
		{"tesl_schema_meta", "id"}, {"tesl_schema_state", "id"}, {"tesl_schema_versions", "version,step,seq"},
		{"tesl_schema_expansions", "version"}, {"tesl_schema_expansion_objects", "version,ordinal"}, {"tesl_schema_index", "version,ordinal"},
	} {
		var encoded []byte
		query := "select coalesce(pg_catalog.jsonb_agg(pg_catalog.to_jsonb(receipt) order by " + item.order + "),'[]'::jsonb) from " + ns + quoteIdentifier(item.name) + " receipt"
		if err := tx.QueryRow(ctx, query).Scan(&encoded); err != nil {
			return "", err
		}
		parts = append(parts, json.RawMessage(encoded))
	}
	encoded, err := json.Marshal(parts)
	if err != nil {
		return "", err
	}
	hash := sha256.Sum256(append([]byte("tesl-row-adoption-legacy-receipts-v1\x00"+namespace+"\x00"), encoded...))
	return hex.EncodeToString(hash[:]), nil
}
