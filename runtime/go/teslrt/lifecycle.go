package teslrt

import "context"

// Backends register their active scope getters during package initialization.
// Memory and non-HTTP programs retain the unscoped default. The concrete group
// belongs to the database runtime; Memory-only bundles need no unused DB helpers.
var currentRuntimeLifecycle = func() context.Context { return context.Background() }

type runtimeWorkers interface {
	context() context.Context
	start(func())
	beginIteration() bool
}

var currentRuntimeWorkers = func() runtimeWorkers { return nil }
