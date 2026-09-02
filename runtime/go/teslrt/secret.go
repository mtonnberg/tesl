package teslrt

import (
	"crypto/subtle"
	"database/sql/driver"
	"fmt"
	"io"
)

// SecretRedaction is the one string every sink substitutes for a secret's payload.
//
// Fixed, and deliberately carrying no length, prefix or hash of the value: partial
// disclosure in a log or a debugger is the convenience that erodes the guarantee. Same text
// as `secret-redaction-text` in dsl/types.rkt, so the two backends redact identically.
const SecretRedaction = "[redacted]"

// SecretString is the payload of a `secret` newtype over String.
//
// It is a distinct type rather than a bare string so that a `%v`/`%s` of it — a log line, a
// panic message, a test failure — prints the redaction instead of the plaintext. The
// plaintext is reached through `Reveal`, which is spelled to be searchable: a review can ask
// where it is called.
type SecretString struct {
	plaintext string
}

func MakeSecret(plaintext string) SecretString {
	return SecretString{plaintext: plaintext}
}

// Format makes redaction the DEFAULT for EVERY verb. fmt consults `Stringer`/`GoStringer`
// only for `%v %s %x %X %q` and `%#v`; any other verb — `%d`, `%b`, `%o`, a typo — fell back
// to struct printing, which rendered the unexported field as `{%!d(string=<plaintext>)}`. A
// `Formatter` is consulted first for every verb, so there is no verb left that discloses.
// Flags and width are ignored on purpose: a padded or truncated redaction is still the same
// fixed text, never a partial disclosure.
func (secret SecretString) Format(state fmt.State, _ rune) {
	_, _ = io.WriteString(state, SecretRedaction)
}

// String keeps the non-fmt callers (string builders, a `Stringer`-typed parameter) redacting
// too; fmt itself goes through Format above.
func (secret SecretString) String() string { return SecretRedaction }

// GoString covers callers that ask for the Go-syntax form directly.
func (secret SecretString) GoString() string { return SecretRedaction }

// MarshalJSON keeps a secret out of an encoded payload the same way, rather than relying on
// every codec to remember.
func (secret SecretString) MarshalJSON() ([]byte, error) {
	return []byte(`"` + SecretRedaction + `"`), nil
}

// Reveal hands back the plaintext. Every use is a deliberate disclosure — sending it on the
// wire, hashing it, comparing it — and is meant to be greppable.
func (secret SecretString) Reveal() string { return secret.plaintext }

// SecretEqual compares two secrets without an early-exit data dependency, so a caller
// cannot learn a prefix from how long the comparison took. `subtle.ConstantTimeCompare`
// itself returns 0 for differing LENGTHS without comparing, which is the same shape Racket's
// `constant-time-bytes=?/secret` has.
func SecretEqual(left, right SecretString) bool {
	return subtle.ConstantTimeCompare([]byte(left.plaintext), []byte(right.plaintext)) == 1
}

// SecretParam is how a `secret` column's value reaches a SQL statement. Storage is the one
// place the plaintext legitimately travels, so the emitter used to bind `.Value.Reveal()` —
// a bare string — and every path that RENDERS a bound parameter (the `--debug` SQL capture's
// `Params` and `Preview`, a trap message quoting the arguments) saw the plaintext (whitebox
// campaign, 2026-09-02). This type carries the secret to the driver through `driver.Valuer`,
// which pgx honours when encoding, while every rendering path — fmt, Stringer, JSON — sees
// the redaction, exactly as for SecretString.
type SecretParam struct {
	secret SecretString
}

// PgSecret is the binding the emitter writes for a `secret` column.
func PgSecret(secret SecretString) SecretParam { return SecretParam{secret: secret} }

// Value hands the plaintext to the database driver — the storage disclosure, and nothing else.
func (param SecretParam) Value() (driver.Value, error) { return param.secret.Reveal(), nil }

func (param SecretParam) Format(state fmt.State, _ rune) {
	_, _ = io.WriteString(state, SecretRedaction)
}
func (param SecretParam) String() string   { return SecretRedaction }
func (param SecretParam) GoString() string { return SecretRedaction }
func (param SecretParam) MarshalJSON() ([]byte, error) {
	return []byte(`"` + SecretRedaction + `"`), nil
}
