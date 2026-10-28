package teslrt

import (
	"context"
	"fmt"
	"slices"

	"github.com/jackc/pgx/v5"
)

type pgRowNotNullProof struct {
	name, physical string
	validated      bool
}

func pgRowNotNullProofNode(node pgRowCanonical) pgRowNotNullProof {
	return pgRowNotNullProof{name: node.children[1].value, physical: node.children[2].value, validated: node.children[3].value == "true"}
}

// Remove only exact manifested temporary proofs from the ordinary complete
// catalog comparison. Names are not erased here; an equivalent or extra CHECK
// cannot substitute for the independently derived Contract receipt.
func pgVerifyRowNotNullProofs(ctx context.Context, tx pgx.Tx, namespace string, actual *pgCatalogTable, proofs map[string]pgRowNotNullProof) error {
	remaining := slices.Clone(actual.Constraints)
	for name, proof := range proofs {
		number := 0
		for _, column := range actual.Columns {
			if column.Name == proof.physical {
				number = column.Number
				break
			}
		}
		if number == 0 {
			return fmt.Errorf("row nullability proof references missing column")
		}
		var expression string
		if err := tx.QueryRow(ctx, "select '(' || pg_catalog.quote_ident($1::text) || ' IS NOT NULL)'", proof.physical).Scan(&expression); err != nil {
			return err
		}
		found := -1
		for i, constraint := range remaining {
			if constraint.Name != name {
				continue
			}
			if found >= 0 || constraint.Kind != "c" || constraint.Validated != proof.validated || constraint.Deferrable || constraint.Deferred || !constraint.Enforced || !slices.Equal(constraint.Keys, []int{number}) || constraint.Expression == nil || *constraint.Expression != expression {
				return fmt.Errorf("row nullability proof definition differs")
			}
			found = i
		}
		if found < 0 {
			return fmt.Errorf("row nullability proof is absent")
		}
		var local, noInherit bool
		var ancestors int
		if err := tx.QueryRow(ctx, `select k.conislocal,k.coninhcount,k.connoinherit from pg_catalog.pg_constraint k
   join pg_catalog.pg_class c on c.oid=k.conrelid join pg_catalog.pg_namespace n on n.oid=c.relnamespace
   where n.nspname=$1 and c.relname=$2 and k.conname=$3`, namespace, actual.Name, name).Scan(&local, &ancestors, &noInherit); err != nil {
			return err
		}
		if !local || ancestors != 0 || noInherit {
			return fmt.Errorf("row nullability proof inheritance differs")
		}
		remaining = slices.Delete(remaining, found, found+1)
	}
	actual.Constraints = remaining
	return nil
}
