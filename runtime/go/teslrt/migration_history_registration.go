package teslrt

// The compiler emits each application's migration history into its own
// generated package, internal/teslhistory, whose init registers it here. The
// runtime package therefore stays byte-identical across an application's
// revisions, so Go's build cache reuses it instead of recompiling it whenever
// a migration is added. Generated packages that register databases import
// teslhistory, so this registration runs before theirs.

// RegisterCompiledMigrationHistory registers one database's compiled source history.
func RegisterCompiledMigrationHistory(database, family, namespace string, version int, sourceABI, compatibility, history string) {
	registerCompiledMigrationHistory(database, family, namespace, version, sourceABI, compatibility, history)
}

// RegisterCompiledQueueHistory registers the compiled queue history companion.
func RegisterCompiledQueueHistory(payload string) { registerCompiledQueueHistory(payload) }

// RegisterCompiledRowHistory registers the compiled row transform history.
func RegisterCompiledRowHistory(payload string) { registerCompiledRowHistory(payload) }

// RegisterCompiledRowPhysicalHistory registers the retained physical row history.
func RegisterCompiledRowPhysicalHistory(payload string) { registerCompiledRowPhysicalHistory(payload) }

// RegisterCompiledRowContractHistory registers the reviewed row Contract history.
func RegisterCompiledRowContractHistory(payload string) { registerCompiledRowContractHistory(payload) }
