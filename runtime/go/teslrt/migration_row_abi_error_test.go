package teslrt

import (
	"errors"
	"fmt"
	"github.com/jackc/pgx/v5/pgconn"
	"testing"
)

func TestRowABIAdmissionErrorIsExact(t *testing.T) {
	pinned := &pgconn.PgError{Code: "P0001", Message: "tesl: transforming generation compiler ABI is pinned"}
	for _, err := range []error{pinned, fmt.Errorf("protected ABI call: %w", pinned)} {
		got := pgRowABIAdmissionError(err)
		var admission *pgMigrationAdmissionError
		if !errors.As(got, &admission) || !errors.Is(got, err) {
			t.Fatal("exact ABI refusal omitted admission classification", got)
		}
	}
	for _, err := range []error{nil, errors.New(pinned.Message), &pgconn.PgError{Code: "P0001", Message: "user callback failure"}, &pgconn.PgError{Code: "42501", Message: pinned.Message}, &pgconn.PgError{Code: "P0001", Message: pinned.Message + " extra"}} {
		if got := pgRowABIAdmissionError(err); got != err {
			t.Fatal("unrelated error reclassified", err, got)
		}
	}
}
