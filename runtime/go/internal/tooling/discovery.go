package tooling

import (
	"os"
	"tesl.dev/runtime/go/internal/toolchain"
)

func CompilerFromEnvironment() Client {
	resolver := toolchain.Default()
	executable, err := resolver.Resolve("compiler")
	environment, envErr := resolver.CompilerEnvironment(nil)
	if err == nil {
		err = envErr
	}
	client := Client{Executable: executable, DiscoveryError: err, Environment: environment}
	if os.Getenv("TESL_COMPILER_SESSION") != "0" {
		client.Sessions = NewWorkspaceSessions()
	}
	return client
}
