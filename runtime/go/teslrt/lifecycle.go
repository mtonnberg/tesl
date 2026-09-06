package teslrt

import "context"

// Backends register their active scope getter during package initialization.
// Keep the default in the base runtime so Memory and non-HTTP programs do not
// acquire PostgreSQL or server dependencies. The getter is immutable at run time;
// individual scopes provide fresh contexts rather than latching process shutdown.
var currentRuntimeLifecycle = func() context.Context { return context.Background() }
