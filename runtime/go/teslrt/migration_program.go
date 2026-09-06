package teslrt

import (
	"strings"
	"sync"
)

// PgCompiledMigrationHistory describes source compiled into this binary. It is
// not observed database state, a processing ABI, or permission to execute DDL.
// HistoryJSON is the compiler's complete guarded artifact; runtime boot must
// separately verify its persisted history and installation origin.
type PgCompiledMigrationHistory struct {
	Database, Family, Namespace string
	CurrentVersion              int
	SourceCompilerABI           string
	StoredValueCompatibility    string
	HistoryJSON                 string
}

var compiledMigrationHistories sync.Map // schema family -> immutable compiled information

// Called only by the compiler-generated file in this runtime package. Keeping
// the data in Go initialization links it into standalone executables; startup
// never reads a mutable source checkout or adjacent JSON file.
func registerCompiledMigrationHistory(database, family, namespace string, version int, sourceABI, compatibility, history string) {
	if database == "" || family == "" || namespace == "" || sourceABI == "" || !pgStoredValueCompatibility(compatibility) || history == "" ||
		version < 1 || version > 2147483646 || !pgMigrationFamily(family) {
		panic("database: invalid compiler-generated migration history")
	}
	info := PgCompiledMigrationHistory{Database: database, Family: family, Namespace: namespace,
		CurrentVersion: version, SourceCompilerABI: sourceABI, StoredValueCompatibility: compatibility, HistoryJSON: history}
	previous, loaded := compiledMigrationHistories.LoadOrStore(family, info)
	if loaded && previous != info {
		panic("database: conflicting compiled migration histories for " + family)
	}
}

// Schema.Todo names the schema/todo directory. Legacy TodoSchema families keep
// their original identity and source history; the two spellings are not aliases.
func pgMigrationFamily(family string) bool {
	var name string
	if strings.HasPrefix(family, "Schema.") {
		name = strings.TrimPrefix(family, "Schema.")
	} else if strings.HasSuffix(family, "Schema") && len(family) > len("Schema") {
		name = strings.TrimSuffix(family, "Schema")
	} else {
		return false
	}
	if name == "" || name[0] < 'A' || name[0] > 'Z' {
		return false
	}
	for _, c := range name {
		switch {
		case c >= 'A' && c <= 'Z', c >= 'a' && c <= 'z', c >= '0' && c <= '9', c == '_':
		default:
			return false
		}
	}
	return true
}

// RegisterDatabaseMigrationHistory binds the application's connection to its
// compiled schema family using its stable source identity. The source checker
// proves that one application connection owns each family; connection details
// remain separate from the schema's declarations.
func RegisterDatabaseMigrationHistory(database *Database, family string) *Database {
	if database == nil {
		panic("database: missing connection for compiled migration history")
	}
	value, ok := compiledMigrationHistories.Load(family)
	if !ok {
		panic("database: missing compiled migration history for " + family)
	}
	// Only registerCompiledMigrationHistory writes this private registry.
	info := value.(PgCompiledMigrationHistory) //nolint:forcetypeassert
	if database.Config.Schema != info.Namespace {
		panic("database: compiled migration namespace disagrees with its connection")
	}
	database.mutex.Lock()
	defer database.mutex.Unlock()
	if database.migrationHistory != nil && *database.migrationHistory != info {
		panic("database: connection belongs to conflicting migration histories")
	}
	database.migrationHistory = &info
	return database
}

// CompiledMigrationHistory returns an immutable value copy. An unversioned or
// manually constructed database has no compiled history. This does not connect
// to PostgreSQL or report that any migration has run.
func (database *Database) CompiledMigrationHistory() (PgCompiledMigrationHistory, bool) {
	if database == nil {
		return PgCompiledMigrationHistory{}, false
	}
	database.mutex.RLock()
	defer database.mutex.RUnlock()
	if database.migrationHistory == nil {
		return PgCompiledMigrationHistory{}, false
	}
	return *database.migrationHistory, true
}
