package tooling

import "tesl.dev/runtime/go/internal/toolchain"

func CompilerFromEnvironment() Client {
	executable, err := toolchain.Default().Resolve("compiler")
	return Client{Executable: executable, DiscoveryError: err}
}
