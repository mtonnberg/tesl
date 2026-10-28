package teslrt

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	"strconv"
	"strings"
)

// This is the compiler's versioned, length-framed Migration_canonical encoding,
// independently implemented here. JSON formatting, SQL spelling, application
// connection names and future steps do not participate in an individual hash.
func pgMigrationBytes(value string) string { return "s" + strconv.Itoa(len(value)) + ":" + value }
func pgMigrationSeq(values ...string) string {
	return "l" + strconv.Itoa(len(values)) + ":" + strings.Join(values, "")
}
func pgMigrationBool(value bool) string {
	return pgMigrationSeq(pgMigrationBytes("bool"), pgMigrationBytes(strconv.FormatBool(value)))
}
func pgMigrationNodes[T any](values []T, encode func(T) string) string {
	nodes := make([]string, len(values))
	for i, value := range values {
		nodes[i] = encode(value)
	}
	return pgMigrationSeq(nodes...)
}
func pgMigrationColumnNode(column PgMigrationCatalogColumn) string {
	return pgMigrationSeq(pgMigrationBytes(column.Name), pgMigrationBytes(column.Type), pgMigrationBool(column.Nullable), pgMigrationBool(column.PrimaryKey))
}
func pgMigrationIndexNode(index PgMigrationCatalogIndex) string {
	return pgMigrationSeq(pgMigrationBytes(index.Name), pgMigrationNodes(index.Columns, pgMigrationBytes), pgMigrationBool(index.Unique))
}
func pgMigrationConstantNode(value *PgMigrationCatalogConstant) string {
	if value == nil {
		return pgMigrationSeq(pgMigrationBytes("null"))
	}
	return pgMigrationSeq(pgMigrationBytes("constant"), pgMigrationSeq(pgMigrationBytes(value.Kind), pgMigrationBytes(value.Value)))
}
func pgMigrationRiskNode(value *string) string {
	if value == nil {
		return pgMigrationSeq()
	}
	return pgMigrationSeq(pgMigrationBytes(*value))
}
func pgMigrationOperationNode(op PgMigrationExpansionOperation) string {
	kind, table := pgMigrationBytes(op.Kind), pgMigrationBytes(op.Table)
	switch op.Kind {
	case "create-table":
		return pgMigrationSeq(kind, pgMigrationSeq(table, pgMigrationNodes(op.Columns, pgMigrationColumnNode), pgMigrationNodes(op.Indexes, pgMigrationIndexNode)))
	case "add-column":
		return pgMigrationSeq(kind, table, pgMigrationColumnNode(*op.Column), pgMigrationConstantNode(op.Column.Default))
	case "build-index-concurrently", "retain-index":
		return pgMigrationSeq(kind, table, pgMigrationIndexNode(*op.Index), pgMigrationRiskNode(op.WindowRisk))
	default: // Checked retain-table; unknown operations cannot reach hashing.
		return pgMigrationSeq(kind, table)
	}
}
func pgMigrationCatalogNode(table PgMigrationCatalogTable) string {
	columns := pgMigrationNodes(table.Columns, func(column PgMigrationCatalogColumn) string {
		return pgMigrationSeq(pgMigrationColumnNode(column), pgMigrationConstantNode(column.Default))
	})
	return pgMigrationSeq(pgMigrationBytes(table.Name), columns, pgMigrationNodes(table.Indexes, pgMigrationIndexNode))
}
func pgMigrationStepHash(step PgMigrationExpansionStep) string {
	node := pgMigrationSeq(pgMigrationBytes(strconv.Itoa(step.Version)), pgMigrationBytes(step.SnapshotHash), pgMigrationBool(step.EpochPreserving),
		pgMigrationNodes(step.Operations, pgMigrationOperationNode), pgMigrationNodes(step.Catalog, pgMigrationCatalogNode))
	encoded := pgMigrationSeq(pgMigrationBytes("tesl-migration-canonical"), pgMigrationBytes("1"), pgMigrationBytes("migration"),
		pgMigrationSeq(pgMigrationBytes("postgres-expansion-step-v1"), node))
	hash := sha256.Sum256([]byte(encoded))
	return hex.EncodeToString(hash[:])
}

// ObjectHash binds durable object progress to one position in an already
// identified step. The step hash covers the ordered operations and catalog.
// PostgreSQL independently derives the same value before accepting progress.
func (step PgMigrationExpansionStep) ObjectHash(ordinal int) (string, error) {
	if ordinal < 0 || ordinal >= len(step.Operations) || ordinal > 2147483646 || !pgMigrationDigest(step.StepHash) {
		return "", fmt.Errorf("invalid migration object identity or ordinal")
	}
	return pgMigrationObjectHash(step.StepHash, ordinal), nil
}

func pgMigrationObjectHash(stepHash string, ordinal int) string {
	if !pgMigrationDigest(stepHash) || ordinal < 0 || ordinal > 2147483646 {
		return ""
	}
	decoded, _ := hex.DecodeString(stepHash) // Digest validation makes decoding total.
	encoded := append([]byte("tesl-migration-object-v1"), decoded...)
	encoded = binary.BigEndian.AppendUint32(encoded, uint32(ordinal))
	digest := sha256.Sum256(encoded)
	return hex.EncodeToString(digest[:])
}
