package teslrt

import (
	"context"
	"encoding/hex"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
)

type pgRowPersistedContract struct {
	contract                                       *pgRowContract
	settled                                        *pgRowPhysicalPlan
	document, hash, windowHash, prior, compilerABI string
	operationCount, preparationCount, completed    int
}

func pgReadRowContracts(ctx context.Context, tx pgx.Tx, b *pgRowBaseline) (map[int]*pgRowPersistedContract, error) {
	ns := quoteIdentifier(b.history.Namespace) + "."
	rows, err := tx.Query(ctx, "select version,predecessor_hash,contract,contract_hash,window_hash,settled,settled_hash,operation_count,preparation_count,compiler_abi from "+ns+"tesl_row_contracts order by version")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := map[int]*pgRowPersistedContract{}
	previous := ""
	for rows.Next() {
		var version int
		var doc, settledDoc []byte
		var settledHash string
		item := &pgRowPersistedContract{}
		if err := rows.Scan(&version, &item.prior, &doc, &item.hash, &item.windowHash, &settledDoc, &settledHash, &item.operationCount, &item.preparationCount, &item.compilerABI); err != nil {
			return nil, err
		}
		if version < 2 || result[version] != nil || item.prior != previous || !pgMigrationDigest(item.windowHash) || item.operationCount < 0 || !strings.HasPrefix(item.compilerABI, "tesl-source-abi-v1:") || !pgMigrationDigest(strings.TrimPrefix(item.compilerABI, "tesl-source-abi-v1:")) {
			return nil, fmt.Errorf("invalid persisted Contract lineage or provenance")
		}
		settled, err := pgParseRowSettledPlan(hex.EncodeToString(settledDoc), settledHash)
		if err != nil {
			return nil, err
		}
		if settled.version != version || settled.family != b.history.Family || settled.namespace != b.history.Namespace {
			return nil, fmt.Errorf("persisted settled plan belongs to another owner")
		}
		item.document = hex.EncodeToString(doc)
		item.settled = settled
		// Validate framing/domain now; exact operation grammar needs its linked window.
		reader := &pgMigrationWireReader{}
		node := pgRowDocument(reader, item.document, item.hash, "contract")
		if reader.err != nil || !node.list(10) {
			return nil, fmt.Errorf("persisted Contract framing differs")
		}
		result[version] = item
		previous = item.hash
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	rows.Close()
	receipts, err := tx.Query(ctx, "select version,ordinal,operation_hash from "+ns+"tesl_row_contract_objects order by version,ordinal")
	if err != nil {
		return nil, err
	}
	defer receipts.Close()
	for receipts.Next() {
		var version, ordinal int
		var hash string
		if err := receipts.Scan(&version, &ordinal, &hash); err != nil {
			return nil, err
		}
		item := result[version]
		if item == nil || ordinal != item.completed || ordinal >= item.operationCount || hash != pgMigrationObjectHash(item.hash, ordinal) {
			return nil, fmt.Errorf("row Contract receipts differ from exact committed prefix")
		}
		item.completed++
	}
	if err := receipts.Err(); err != nil {
		return nil, err
	}
	return result, nil
}
