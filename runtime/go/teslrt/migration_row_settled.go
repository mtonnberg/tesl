package teslrt

import (
	"context"
	"encoding/hex"
	"fmt"

	"github.com/jackc/pgx/v5"
)

// The floor is an admission input, never sufficient authority for a changed SQL
// shape. The exact local Contract and its protected contracting/contracted
// receipt must agree before this transaction selects settled storage.
func pgRowSettledMode(ctx context.Context, tx pgx.Tx, database *Database, window *pgRowPhysicalPlan) (bool, error) {
	if tx == nil || database == nil || window == nil || window.compiled == nil || window.settled {
		return false, fmt.Errorf("missing exact window for settled admission")
	}
	selected, err := pgCompiledRowPhysicalPlan(database, window.version)
	if err != nil || selected != window {
		return false, fmt.Errorf("settled admission requires original registered window")
	}
	var floor int
	if err := tx.QueryRow(ctx, "select "+pgx.Identifier{window.namespace, "tesl_admit"}.Sanitize()+"($1)", window.version).Scan(&floor); err != nil {
		return false, &pgMigrationAdmissionError{cause: err}
	}
	if window.version == 1 || floor < window.version {
		return false, nil
	}
	settled, err := pgCompiledRowSettledPlan(database, window.version)
	if err != nil {
		return false, err
	}
	pgMigrationRegistrations.Lock()
	contract := compiledRowContracts[window.compiled][window.version]
	pgMigrationRegistrations.Unlock()
	if contract == nil || contract.window != window || contract.settled != settled {
		return false, fmt.Errorf("settled admission lacks exact compiler Contract")
	}
	ns := quoteIdentifier(window.namespace) + "."
	var doc, storedSettled []byte
	var hash, windowHash, settledHash string
	var completed, contracting bool
	if err := tx.QueryRow(ctx, "select c.contract,c.contract_hash,c.window_hash,c.settled,c.settled_hash,exists(select 1 from "+ns+"tesl_schema_versions v where v.version=c.version and v.step='contracted' and v.artefact_hash=c.contract_hash),exists(select 1 from "+ns+"tesl_schema_versions v where v.version=c.version and v.step='contracting' and v.artefact_hash=c.contract_hash) from "+ns+"tesl_row_contracts c where c.version=$1", window.version).Scan(&doc, &hash, &windowHash, &storedSettled, &settledHash, &completed, &contracting); err != nil {
		return false, err
	}
	if (!completed && !contracting) || hash != contract.hash || windowHash != window.hash || settledHash != settled.hash || hex.EncodeToString(doc) != contract.contract || hex.EncodeToString(storedSettled) != settled.contract {
		return false, fmt.Errorf("compatibility floor has no exact Contract receipt")
	}
	return true, nil
}
