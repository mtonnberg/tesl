package teslrt

import (
	"fmt"
	"math/big"
	"os"
)

// Reading the environment is an effect Tesl gates behind the `envRead` capability, which
// the checker enforces; nothing about that survives to run time.
//
// An EMPTY variable counts as unset everywhere here, which is what `tesl/private/runtime.rkt`
// does (`empty-string->false`): `FOO=` and an absent `FOO` are the same answer, so a blank
// value in a deployment cannot look like a configured one.
func envRaw(name string) (string, bool) {
	value := os.Getenv(name)
	if value == "" {
		return "", false
	}
	return value, true
}

// EnvMaybe is `env`: the value, or Nothing when unset.
func EnvMaybe(name string) Maybe[string] {
	if value, ok := envRaw(name); ok {
		return Something(value)
	}
	return Nothing[string]()
}

// EnvString is `envString`: the value, or the fallback when unset.
func EnvString(name, fallback string) string {
	if value, ok := envRaw(name); ok {
		return value
	}
	return fallback
}

// EnvInt is `envInt`: the value parsed as an exact integer, or the fallback when unset. A
// SET-but-unparseable value is a configuration error and traps — it must not quietly become
// the fallback, or a typo'd port would look like a deliberate default.
func EnvInt(name string, fallback Int) Int {
	value, ok := envRaw(name)
	if !ok {
		return fallback
	}
	parsed, valid := new(big.Int).SetString(value, 10)
	if !valid {
		panic(fmt.Sprintf("envInt: invalid integer environment value %s=%s", name, value))
	}
	return fromBig(parsed)
}

// RequireEnv is `requireEnv`: the value, or a trap. An unset variable is a configuration
// error, so it fails at the read rather than flowing on as an empty string.
func RequireEnv(name string) string {
	value, ok := envRaw(name)
	if !ok {
		panic(fmt.Sprintf("requireEnv: environment variable %s is not set (or is empty)", name))
	}
	return value
}
