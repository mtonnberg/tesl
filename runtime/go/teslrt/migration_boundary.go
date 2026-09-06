//go:build !tesl_migration_test

package teslrt

// The compiler eliminates this empty call in release builds. The control socket,
// environment knobs and synchronisation code exist only with the test build tag.
func migrationBoundary(_ string) {}
