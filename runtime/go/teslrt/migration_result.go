package teslrt

// Migrated is the ordinary Tesl result `Migrated a = Row a | Reject String`.
// A shared runtime representation lets pure row functions cross generated
// module boundaries. This value does not authorize a database transition.
type Migrated[A any] struct {
	Tag          MigratedTag
	RowValue     A
	RejectReason string
}

// MigratedTag distinguishes the accepted row from its rejection reason.
type MigratedTag int

const (
	// The zero value is a rejection, never a successful fabricated row.
	MigratedReject MigratedTag = iota
	MigratedRow
)
