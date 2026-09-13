package teslrt

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5"
)

// An epoch receipt is observation of a completed admission transition. It never
// grants a row codec, a processing ABI, or permission to execute a SQL plan.
type pgRowEpochRetirement struct {
	from, through               int
	document, hash, executorABI string
	forced                      bool
}

func pgRowEpochDocument(b *pgRowBaseline, state PgMigrationControlState, from, through int, forced bool, plans map[int]*pgRowPhysicalPlan) (string, string, error) {
	if b == nil || from < 1 || through <= from || through > 2147483646 || through > len(plans) || state.DatabaseUUID == "" || state.FenceNamespace <= 0 {
		return "", "", fmt.Errorf("invalid additive epoch retirement identity")
	}
	prefix := make([]pgRowCanonical, 0, through)
	for version := 1; version <= through; version++ {
		plan := plans[version]
		if plan == nil || plan.version != version || plan.family != b.history.Family || plan.namespace != b.history.Namespace || len(plan.windows) != 0 || plan.requiresContractVersion != 0 || plan.settled || !pgMigrationDigest(plan.hash) {
			return "", "", fmt.Errorf("epoch retirement requires a complete purely additive physical prefix")
		}
		prefix = append(prefix, pgRowList(pgRowAtom(strconv.Itoa(version)), pgRowAtom(plan.hash)))
	}
	decision := "drained"
	if forced {
		decision = "forced"
	}
	payload := pgRowList(pgRowAtom("tesl-row-close-epoch-v1"), pgRowAtom(b.history.Database), pgRowAtom(b.history.Family), pgRowAtom(b.history.Namespace),
		pgRowAtom(state.DatabaseUUID), pgRowAtom(strconv.Itoa(state.FenceNamespace)), pgRowAtom("5"), pgRowAtom("tesl-1"),
		pgRowAtom(b.history.StoredValueCompatibility), pgRowAtom(strconv.Itoa(from)), pgRowAtom(strconv.Itoa(through)), pgRowAtom(decision), pgRowList(prefix...))
	document := pgRowEncode(pgRowList(pgRowAtom("tesl-migration-canonical"), pgRowAtom("1"), pgRowAtom("contract"), payload))
	return hex.EncodeToString([]byte(document)), fmt.Sprintf("%x", sha256.Sum256([]byte(document))), nil
}

func pgReadRowEpochRetirements(ctx context.Context, tx pgx.Tx, b *pgRowBaseline, plans map[int]*pgRowPhysicalPlan) (map[int]*pgRowEpochRetirement, error) {
	var state PgMigrationControlState
	ns := quoteIdentifier(b.history.Namespace) + "."
	if err := tx.QueryRow(ctx, "select database_uuid::text,fence_ns from "+ns+"tesl_schema_meta where id=1").Scan(&state.DatabaseUUID, &state.FenceNamespace); err != nil {
		return nil, err
	}
	rows, err := tx.Query(ctx, "select old_min,through_version,retirement,retirement_hash,compiler_abi,forced from "+ns+"tesl_row_epochs order by through_version")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := map[int]*pgRowEpochRetirement{}
	expectedFrom := 1
	for rows.Next() {
		epoch := &pgRowEpochRetirement{}
		var raw []byte
		if err := rows.Scan(&epoch.from, &epoch.through, &raw, &epoch.hash, &epoch.executorABI, &epoch.forced); err != nil {
			return nil, err
		}
		document, hash, err := pgRowEpochDocument(b, state, epoch.from, epoch.through, epoch.forced, plans)
		if err != nil {
			return nil, err
		}
		epoch.document = hex.EncodeToString(raw)
		if epoch.from != expectedFrom || epoch.document != document || epoch.hash != hash || !strings.HasPrefix(epoch.executorABI, "tesl-source-abi-v1:") || !pgMigrationDigest(strings.TrimPrefix(epoch.executorABI, "tesl-source-abi-v1:")) {
			return nil, fmt.Errorf("epoch receipt differs from exact additive retirement chain")
		}
		for target := epoch.from + 1; target <= epoch.through; target++ {
			if result[target] != nil {
				return nil, fmt.Errorf("overlapping additive epoch retirement slots")
			}
			result[target] = epoch
		}
		expectedFrom = epoch.through
	}
	return result, rows.Err()
}
