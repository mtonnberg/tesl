package teslrt

import (
	"strings"
	"testing"
)

// A hash minted by the RACKET runtime (libsodium's crypto_pwhash_str at INTERACTIVE
// parameters) for the password "hunter2". Verifying it here is the whole reason this file takes
// a dependency instead of substituting a stdlib KDF: a database written by one backend has to
// keep working under the other, and a PBKDF2 substitute would lock every user out.
const libsodiumHunter2 = "$argon2id$v=19$m=65536,t=2,p=1$hEqGORzK/mF1IXCNIG173A" +
	"$GgtGSGOPiC6MrUOvE8AF5UxKQg9nusgA6+RuAtgpw+4"

func TestVerifiesAHashMintedByTheRacketRuntime(t *testing.T) {
	stored := Something(PasswordHash{Value: libsodiumHunter2})
	if result := CheckPassword(stored, MakeSecret("hunter2")); !result.OK() {
		t.Fatalf("a libsodium hash did not verify: %s", result.Message())
	}
	if result := CheckPassword(stored, MakeSecret("hunter3")); result.OK() {
		t.Fatal("the wrong password verified against a libsodium hash")
	}
	// And it is NOT asking to be re-minted: it was written at the parameters this runtime uses.
	if NeedsRehash(PasswordHash{Value: libsodiumHunter2}) {
		t.Fatal("a libsodium hash at the current parameters asked to be rehashed")
	}
}

// The other direction: what Go writes has to be the same shape, so the Racket side can read it.
func TestHashPasswordWritesTheSameEncoding(t *testing.T) {
	hash := HashPassword(MakeSecret("hunter2"))
	if !strings.HasPrefix(hash.Value, "$argon2id$v=19$m=65536,t=2,p=1$") {
		t.Fatalf("hash %q is not libsodium's interactive PHC shape", hash.Value)
	}
	fields := strings.Split(hash.Value, "$")
	if len(fields) != 6 {
		t.Fatalf("hash %q has %d fields", hash.Value, len(fields))
	}
	// 16-byte salt and 32-byte tag, base64 with no padding.
	if len(fields[4]) != 22 || len(fields[5]) != 43 {
		t.Fatalf("salt/tag lengths are %d/%d, want 22/43", len(fields[4]), len(fields[5]))
	}
	// Unpadded: `=` appears in the parameter fields (`v=19`), never in the salt or the tag.
	if strings.Contains(fields[4], "=") || strings.Contains(fields[5], "=") {
		t.Fatalf("hash %q is padded; libsodium writes unpadded base64", hash.Value)
	}
	if result := CheckPassword(Something(hash), MakeSecret("hunter2")); !result.OK() {
		t.Fatal("a freshly written hash did not verify")
	}
	// A fresh salt per call: two hashes of the same password must differ.
	if HashPassword(MakeSecret("hunter2")).Value == hash.Value {
		t.Fatal("two hashes of the same password are identical — the salt is not random")
	}
}

// A missing account must be indistinguishable from a wrong password: same status, same message,
// and a real verification performed either way so the timings match.
func TestMissingAccountAnswersLikeAWrongPassword(t *testing.T) {
	missing := CheckPassword(Nothing[PasswordHash](), MakeSecret("hunter2"))
	wrong := CheckPassword(Something(PasswordHash{Value: libsodiumHunter2}), MakeSecret("nope"))
	if missing.OK() || wrong.OK() {
		t.Fatal("a missing account or a wrong password verified")
	}
	if missing.Status() != wrong.Status() || missing.Message() != wrong.Message() {
		t.Fatalf("missing = %d %q, wrong = %d %q — they must be identical",
			missing.Status(), missing.Message(), wrong.Status(), wrong.Message())
	}
	if missing.Message() != "invalid credentials" {
		t.Fatalf("message = %q", missing.Message())
	}
}

func TestNeedsRehashOnWeakerOrForeignHashes(t *testing.T) {
	for label, stored := range map[string]string{
		"weaker memory":   "$argon2id$v=19$m=8192,t=2,p=1$hEqGORzK/mF1IXCNIG173A$GgtGSGOPiC6MrUOvE8AF5UxKQg9nusgA6+RuAtgpw+4",
		"weaker time":     "$argon2id$v=19$m=65536,t=1,p=1$hEqGORzK/mF1IXCNIG173A$GgtGSGOPiC6MrUOvE8AF5UxKQg9nusgA6+RuAtgpw+4",
		"other variant":   "$argon2i$v=19$m=65536,t=2,p=1$hEqGORzK/mF1IXCNIG173A$GgtGSGOPiC6MrUOvE8AF5UxKQg9nusgA6+RuAtgpw+4",
		"older version":   "$argon2id$v=16$m=65536,t=2,p=1$hEqGORzK/mF1IXCNIG173A$GgtGSGOPiC6MrUOvE8AF5UxKQg9nusgA6+RuAtgpw+4",
		"bcrypt":          "$2b$12$K3JNi7pRuLNvGrUsQxLxHOJHMBRW7t9SS0Lm6ZK3H4/9WlY1p1mFq",
		"not a hash":      "hunter2",
		"empty":           "",
		"truncated":       "$argon2id$v=19$m=65536,t=2,p=1$hEqGORzK/mF1IXCNIG173A",
		"bad base64":      "$argon2id$v=19$m=65536,t=2,p=1$!!!!$!!!!",
		"unknown setting": "$argon2id$v=19$m=65536,t=2,p=1,x=9$hEqGORzK/mF1IXCNIG173A$GgtGSGOPiC6MrUOvE8AF5UxKQg9nusgA6+RuAtgpw+4",
	} {
		if !NeedsRehash(PasswordHash{Value: stored}) {
			t.Errorf("%s did not ask to be rehashed", label)
		}
		// An unparseable or foreign hash must also never VERIFY — failing closed is the point.
		if result := CheckPassword(Something(PasswordHash{Value: stored}), MakeSecret("hunter2")); result.OK() {
			t.Errorf("%s verified", label)
		}
	}
}

// Hashing is deliberately expensive, so an unbounded input is a denial-of-service amplifier.
// The refusal is a 400 at the request boundary, not a crash.
func TestOverlongPasswordIsRejectedAsABadRequest(t *testing.T) {
	for label, thunk := range map[string]func(){
		"hashPassword": func() { _ = HashPassword(MakeSecret(strings.Repeat("x", 1025))) },
		"checkPassword": func() {
			_ = CheckPassword(Nothing[PasswordHash](), MakeSecret(strings.Repeat("x", 1025)))
		},
	} {
		func() {
			defer func() {
				recovered := recover()
				rejection, ok := recovered.(RequestRejection)
				if !ok {
					t.Fatalf("%s trapped with %v, want a RequestRejection", label, recovered)
				}
				if rejection.Status != 400 ||
					!strings.Contains(rejection.Message, "denial-of-service amplifier") {
					t.Fatalf("%s rejected as %d %q", label, rejection.Status, rejection.Message)
				}
			}()
			thunk()
		}()
	}
	// The limit itself is not off by one: exactly 1024 bytes still hashes.
	if hash := HashPassword(MakeSecret(strings.Repeat("x", 1024))); hash.Value == "" {
		t.Fatal("a 1024-byte password did not hash")
	}
}
