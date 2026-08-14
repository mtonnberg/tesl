package teslrt

import "crypto/subtle"

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

// String makes redaction the DEFAULT: fmt reaches for this method, so every accidental
// print is safe without the call sites having to know they are handling a secret.
func (secret SecretString) String() string { return SecretRedaction }

// GoString covers `%#v`, which would otherwise print the struct with its field.
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
