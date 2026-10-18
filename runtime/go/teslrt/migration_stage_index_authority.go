package teslrt

import (
	"context"
	"encoding/hex"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
)

type pgStageIndexAuthority struct {
	version, ordinal int
	abi, state       string
	guard            pgStageGuard
}

// A Contract index has a distinct provenance from an expansion index. Never
// synthesize expansion receipts or rewrite the original expansion's creator ABI.
func pgStageIndexAuthorities(ctx context.Context, tx pgx.Tx, namespace string) (map[string]pgStageIndexAuthority, error) {
	result := map[string]pgStageIndexAuthority{}
	ns := quoteIdentifier(namespace) + "."
	var format int
	if err := tx.QueryRow(ctx, "select format_version from "+ns+"tesl_schema_meta where id=1").Scan(&format); err != nil {
		return nil, err
	}
	if format != pgRowControlFormat {
		return result, nil
	}
	rows, err := tx.Query(ctx, `select pr.stage_id,pr.version,pr.ordinal,pr.job_id,pr.state,c.contract,c.contract_hash,c.settled,c.settled_hash,c.compiler_abi,
 p.contract,p.contract_hash,p.operation_count,s.min_version,s.compat_floor,exists(select 1 from `+ns+`tesl_row_epochs where through_version=pr.version)
 from `+ns+`tesl_schema_stage_promotions pr join `+ns+`tesl_schema_stage_contracts c on c.version=pr.version and c.contract_hash=pr.contract_hash
 join `+ns+`tesl_row_physical p on p.version=pr.version and p.contract_hash=c.window_hash cross join `+ns+`tesl_schema_state s where s.id=1 order by pr.version,pr.ordinal`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var id, job, state, hash, settledHash, abi, physicalHash string
		var v, ordinal, operations, minVersion, floor int
		var epoch bool
		var doc, settledDoc, physical []byte
		if err := rows.Scan(&id, &v, &ordinal, &job, &state, &doc, &hash, &settledDoc, &settledHash, &abi, &physical, &physicalHash, &operations, &minVersion, &floor, &epoch); err != nil {
			return nil, err
		}
		if minVersion < v || floor < v || !epoch || !strings.HasPrefix(abi, "tesl-source-abi-v1:") || !pgMigrationDigest(strings.TrimPrefix(abi, "tesl-source-abi-v1:")) {
			return nil, fmt.Errorf("stage index lacks exact retired handoff and executor provenance")
		}
		window, err := pgParseRowPhysicalPlan(hex.EncodeToString(physical), physicalHash)
		if err != nil {
			return nil, err
		}
		settled, err := pgParseRowSettledPlan(hex.EncodeToString(settledDoc), settledHash)
		if err != nil {
			return nil, err
		}
		c, err := pgParseRowContract(hex.EncodeToString(doc), hash, window, settled)
		if err != nil {
			return nil, err
		}
		n := ordinal - operations
		if v != window.version || n < 0 || n >= len(c.window.stageGuards) || job != pgMigrationObjectHash(c.hash, n) || c.window.stageGuards[n].preparation.id != id {
			return nil, fmt.Errorf("stage index ordinal or semantic identity differs from reviewed Contract")
		}
		if state != "promoting" && state != "blocked_duplicates" && state != "enforced" {
			return nil, fmt.Errorf("invalid promotion state")
		}
		if _, ok := result[job]; ok {
			return nil, fmt.Errorf("duplicate stage index authority")
		}
		result[job] = pgStageIndexAuthority{v, ordinal, abi, state, c.window.stageGuards[n]}
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	rows.Close()
	var count int
	if err := tx.QueryRow(ctx, "select count(*) from "+ns+"tesl_schema_stage_promotions").Scan(&count); err != nil {
		return nil, err
	}
	if count != len(result) {
		return nil, fmt.Errorf("orphan stage handoff record")
	}
	return result, nil
}
