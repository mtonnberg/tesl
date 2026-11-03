package teslrt

import (
	"context"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// A nonnil sentinel preserves tests that require rejection before any SQL.
// Returning an error here could let a missing early guard satisfy those tests.
type pgNoSQLTransaction struct{ pgx.Tx }

func (pgNoSQLTransaction) Query(context.Context, string, ...any) (pgx.Rows, error) {
	panic("unexpected SQL before migration refusal")
}
func (pgNoSQLTransaction) QueryRow(context.Context, string, ...any) pgx.Row {
	panic("unexpected SQL before migration refusal")
}
func (pgNoSQLTransaction) Exec(context.Context, string, ...any) (pgconn.CommandTag, error) {
	panic("unexpected SQL before migration refusal")
}
