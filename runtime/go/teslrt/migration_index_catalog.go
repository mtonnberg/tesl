package teslrt

import (
	"fmt"
	"slices"
)

// pgPrepareIndexJobCatalog removes only the exact indexes described by verified
// protected jobs from the ordinary strict comparison. It checks those indexes
// separately because a concurrent build can legitimately be absent or invalid.
// The original observations remain untouched for catalog fingerprints. Callers
// must first verify the control format, immutable history and job provenance.
func pgPrepareIndexJobCatalog(metadata *pgCatalogExpectations, actual, expected *pgCatalogTable,
	jobs []pgMigrationIndexJob, version int, report *PgMigrationCatalogReport) (*pgCatalogTable, *pgCatalogTable, bool, error) {
	return pgPrepareIndexJobCatalogForAdmission(metadata, actual, expected, jobs, version, version, report)
}

// Row observation may reconstruct a newer full physical catalog while retaining
// an older application's write capability. Shape ownership and readiness must
// therefore use distinct exact versions; ordinary format3 callers use one.
func pgPrepareIndexJobCatalogForAdmission(metadata *pgCatalogExpectations, actual, expected *pgCatalogTable,
	jobs []pgMigrationIndexJob, version, admissionVersion int, report *PgMigrationCatalogReport) (*pgCatalogTable, *pgCatalogTable, bool, error) {
	if admissionVersion < 0 || admissionVersion > version {
		return nil, nil, false, fmt.Errorf("index catalog admission exceeds its checked shape revision")
	}
	live, want := *actual, *expected
	live.Indexes, want.Indexes = slices.Clone(actual.Indexes), slices.Clone(expected.Indexes)
	ready := true
	seen := make(map[string]bool)
	for _, job := range jobs {
		if job.Table != actual.Name {
			continue
		}
		if err := pgIndexJobCatalogShape(job); err != nil {
			return nil, nil, false, err
		}
		if seen[job.Index.Name] {
			return nil, nil, false, fmt.Errorf("duplicate protected index job for %s.%s", job.Table, job.Index.Name)
		}
		seen[job.Index.Name] = true
		// Contract requires its own floor/terminal-version protocol. A terminal
		// row is never permission to ignore an index in this additive bridge.
		if job.State == "terminal" {
			if job.stageCancellationVersion == 0 || job.TerminalVersion == nil || job.stageCancellationVersion != *job.TerminalVersion {
				return nil, nil, false, fmt.Errorf("terminal index job requires the contract executor")
			}
			if slices.ContainsFunc(live.Indexes, func(i pgCatalogIndex) bool { return i.Name == job.Index.Name }) {
				return nil, nil, false, fmt.Errorf("cancelled preparation index is still present")
			}
			want.Indexes = slices.DeleteFunc(want.Indexes, func(i pgCatalogIndex) bool { return i.Name == job.Index.Name })
			continue
		}
		declared := slices.IndexFunc(want.Indexes, func(i pgCatalogIndex) bool { return i.Name == job.Index.Name })
		shape, err := metadata.index(job.Index.Name, actual, job.Index.Columns, false, job.Index.Unique, false)
		if err != nil {
			return nil, nil, false, err
		}
		if job.Version <= version {
			if declared < 0 || want.Indexes == nil || !pgEquivalentMigrationIndex(actual, expected, shape, want.Indexes[declared]) {
				return nil, nil, false, fmt.Errorf("protected index job differs from compiled catalog: %s.%s", job.Table, job.Index.Name)
			}
		} else if declared >= 0 || !pgFutureIndexSafeForWrites(actual, expected, job.Index) {
			return nil, nil, false, fmt.Errorf("future index job can change admitted writes: %s.%s", job.Table, job.Index.Name)
		}
		if declared >= 0 {
			want.Indexes = slices.Delete(want.Indexes, declared, declared+1)
		}
		position := slices.IndexFunc(live.Indexes, func(i pgCatalogIndex) bool { return i.Name == job.Index.Name })
		valid := false
		if position < 0 || live.Indexes == nil {
			if job.State == "valid" {
				report.Missing = append(report.Missing, PgMigrationCatalogIssue{job.Table, job.Index.Name, "completed index job has no physical index"})
			}
		} else {
			index := live.Indexes[position]
			if !pgEquivalentMigrationIndex(actual, actual, index, shape) {
				report.Drift = append(report.Drift, PgMigrationCatalogIssue{job.Table, job.Index.Name, "index differs from its protected concurrent-build descriptor"})
			} else {
				valid = index.Valid && index.Ready && index.Live
				if job.State == "valid" && !valid {
					report.Drift = append(report.Drift, PgMigrationCatalogIssue{job.Table, job.Index.Name, "completed index job is not valid, ready and live"})
				}
			}
			live.Indexes = slices.Delete(live.Indexes, position, position+1)
		}
		if pgIndexRequiresValidForWrites(actual, job.Index) && job.Version <= admissionVersion && !(job.stagePromotion && job.Version == admissionVersion) && (!valid || job.State != "valid") {
			ready = false
		}
	}
	return &live, &want, ready, nil
}

func pgIndexJobCatalogShape(job pgMigrationIndexJob) error {
	if job.Version < 1 || job.Version > 2147483646 || job.Ordinal < 0 ||
		!pgMigrationIdentifier(job.Table) || !pgMigrationIdentifier(job.Index.Name) ||
		len(job.Index.Columns) == 0 || len(job.Index.Columns) > 32 {
		return fmt.Errorf("invalid protected concurrent-index descriptor")
	}
	keys := make(map[string]bool)
	for _, key := range job.Index.Columns {
		if !pgMigrationIdentifier(key) || keys[key] {
			return fmt.Errorf("invalid or repeated protected index key")
		}
		keys[key] = true
	}
	switch job.State {
	case "pending", "building", "valid", "failed":
		if job.TerminalVersion != nil {
			return fmt.Errorf("nonterminal index job carries a removal target")
		}
	case "terminal":
		if job.TerminalVersion == nil || *job.TerminalVersion < job.Version || *job.TerminalVersion > 2147483646 {
			return fmt.Errorf("terminal index job lacks a valid removal target")
		}
	default:
		return fmt.Errorf("unsupported protected index state %q", job.State)
	}
	return nil
}

// Current writers must not populate an unbounded new key while a concurrent
// build is incomplete. A failed second scan leaves a maintained invalid index
// that can reject an old writer's non-HOT update of unrelated old columns.
// Unique indexes need the same gate for their existing enforcement promise.
func pgIndexRequiresValidForWrites(actual *pgCatalogTable, index PgMigrationCatalogIndex) bool {
	if index.Unique || actual == nil || len(index.Columns) == 0 {
		return true
	}
	for _, name := range index.Columns {
		position := slices.IndexFunc(actual.Columns, func(c pgCatalogColumn) bool { return c.Name == name })
		if len(actual.Columns) == 0 || position < 0 || position >= len(actual.Columns) {
			return true
		}
		column := actual.Columns[position]
		if column.TypeNamespace != "pg_catalog" || column.TypeKind != "b" || column.Typmod != -1 ||
			column.Generated != "" || column.Identity != "" || column.Collation != column.TypeCollation {
			return true
		}
		switch column.Type {
		case "bool", "int4", "int8", "float8":
		default:
			return true
		}
	}
	return false
}

// An older binary cannot trust a future compiler's ONLINE classification alone.
// It independently checks the actual key domain: old writes must either omit
// every key into default-free NULLs, or the plain index must use only bounded
// builtin scalar keys. The NULL case also requires every version that knows the
// new key to wait for physical and protected completion via the readiness gate
// above; omitted old INSERT keys alone do not protect old non-HOT UPDATEs.
// No expressions, nondefault opclasses or collations are
// introduced through this allowance; shape comparison enforces that separately.
func pgFutureIndexSafeForWrites(actual, expected *pgCatalogTable, index PgMigrationCatalogIndex) bool {
	allNewNull, bounded := true, true
	for _, name := range index.Columns {
		position := slices.IndexFunc(actual.Columns, func(c pgCatalogColumn) bool { return c.Name == name })
		if position < 0 || actual.Columns == nil {
			return false
		}
		column := actual.Columns[position]
		if column.TypeNamespace != "pg_catalog" || column.TypeKind != "b" || column.Typmod != -1 ||
			column.Generated != "" || column.Identity != "" || column.Collation != column.TypeCollation {
			return false
		}
		switch column.Type {
		case "bool", "int4", "int8", "float8":
		case "text", "numeric", "jsonb":
			bounded = false
		default:
			return false
		}
		if column.Required || column.Default != nil ||
			slices.ContainsFunc(expected.Columns, func(c pgCatalogColumn) bool { return c.Name == name }) {
			allNewNull = false
		}
	}
	return allNewNull || !index.Unique && bounded
}
