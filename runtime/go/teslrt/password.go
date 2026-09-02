package teslrt

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"fmt"
	"strconv"
	"strings"
	"sync"

	"golang.org/x/crypto/argon2"
)

// Password storage: Argon2id, in the SAME encoding the Racket runtime writes.
//
// This is the one place the emitted runtime takes a dependency outside Go's standard library
// (`golang.org/x/crypto/argon2`), and it is a deliberate, approved decision rather than a
// convenience: Racket hashes with libsodium's Argon2id, and the two alternatives are both
// worse. Substituting stdlib PBKDF2 would mint hashes the Racket side cannot verify, so a
// shared database becomes a silent lockout on migration; hand-writing Argon2id would put
// hand-rolled cryptography in the runtime. The dependency ships ONLY with this file, which is
// ONLY emitted for a program that stores passwords, so nothing else carries it.
//
// The encoding is the PHC string libsodium's `crypto_pwhash_str` produces at its INTERACTIVE
// parameters:
//
//	$argon2id$v=19$m=65536,t=2,p=1$<salt>$<hash>
//
// with standard-alphabet base64 and no padding, a 16-byte salt and a 32-byte tag. A hash
// written by either backend therefore verifies on both — which is the whole point, and what a
// test asserts against a real libsodium string.
const (
	argonMemoryKiB = 64 * 1024 // libsodium crypto_pwhash_MEMLIMIT_INTERACTIVE, in KiB
	argonTime      = 2         // libsodium crypto_pwhash_OPSLIMIT_INTERACTIVE
	argonThreads   = 1
	argonSaltBytes = 16
	argonKeyBytes  = 32

	// A password longer than this is refused rather than hashed: hashing is deliberately
	// expensive, so an unbounded input is a denial-of-service amplifier. Same limit as the
	// Racket runtime's.
	maxPasswordBytes = 1024
)

// PasswordHash is opaque to Tesl: it holds the PHC string, and a program can store it, verify
// against it, or ask whether it needs re-minting — never read it apart.
type PasswordHash struct {
	Value string
}

func requirePasswordLength(who string, plaintext SecretString) {
	if len(plaintext.Reveal()) > maxPasswordBytes {
		// A rejection at the request boundary, not a crash: the input came from a client, and
		// inside a handler this answers 400 the way any other check rejection does.
		panic(RequestRejection{
			Status: 400,
			Message: fmt.Sprintf(
				"%s: password is too long: %d bytes, maximum is %d. Reject over-long input at "+
					"the request boundary; hashing it is a denial-of-service amplifier.",
				who, len(plaintext.Reveal()), maxPasswordBytes),
		})
	}
}

// HashPassword is `Crypto.hashPassword`: a fresh random salt, then Argon2id at the interactive
// parameters. The `::: HashFor plaintext` half of its Tesl type is compile-time only — the fact
// is about the argument, and proofs erase — so what it buys is that storing the WRONG
// password's hash does not compile.
//
// The plaintext arrives as a SecretString so that the emitted CALL SITE never handles it as an
// ordinary string: a `secret Password = String` hands over its payload, and a plain String is
// wrapped on the way in. The plaintext therefore exists only inside this file.
func HashPassword(plaintext SecretString) PasswordHash {
	requirePasswordLength("Crypto.hashPassword", plaintext)
	salt := make([]byte, argonSaltBytes)
	if _, err := rand.Read(salt); err != nil {
		panic("Crypto.hashPassword: no source of randomness: " + err.Error())
	}
	return PasswordHash{Value: encodeArgon2id(salt,
		argon2.IDKey([]byte(plaintext.Reveal()), salt, argonTime, argonMemoryKiB, argonThreads,
			argonKeyBytes))}
}

func encodeArgon2id(salt, key []byte) string {
	raw := base64.RawStdEncoding
	return fmt.Sprintf("$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s",
		argon2.Version, argonMemoryKiB, argonTime, argonThreads,
		raw.EncodeToString(salt), raw.EncodeToString(key))
}

// argon2Params is what a stored PHC string says it was minted with.
type argon2Params struct {
	memoryKiB uint32
	time      uint32
	threads   uint8
	salt      []byte
	key       []byte
}

// parseArgon2id reads a stored hash. Anything that is not an Argon2id v19 PHC string — a
// foreign hash, a scheme that has been dropped, truncated text — fails to parse, and every
// caller treats that as "does not verify" and "needs re-minting".
func parseArgon2id(stored string) (argon2Params, bool) {
	fields := strings.Split(stored, "$")
	// "", "argon2id", "v=19", "m=…,t=…,p=…", salt, key
	if len(fields) != 6 || fields[0] != "" || fields[1] != "argon2id" {
		return argon2Params{}, false
	}
	if fields[2] != "v="+strconv.Itoa(argon2.Version) {
		return argon2Params{}, false
	}
	var memory, time uint64
	var threads uint64
	for _, setting := range strings.Split(fields[3], ",") {
		name, value, found := strings.Cut(setting, "=")
		if !found {
			return argon2Params{}, false
		}
		parsed, err := strconv.ParseUint(value, 10, 32)
		if err != nil {
			return argon2Params{}, false
		}
		switch name {
		case "m":
			memory = parsed
		case "t":
			time = parsed
		case "p":
			threads = parsed
		default:
			return argon2Params{}, false
		}
	}
	if memory == 0 || time == 0 || threads == 0 || threads > 255 {
		return argon2Params{}, false
	}
	raw := base64.RawStdEncoding
	salt, saltErr := raw.DecodeString(fields[4])
	key, keyErr := raw.DecodeString(fields[5])
	if saltErr != nil || keyErr != nil || len(salt) == 0 {
		return argon2Params{}, false
	}
	// The tag length is FIXED at 32 bytes: that is what libsodium's `crypto_pwhash_str` writes,
	// and pinning it keeps the recomputation below free of a length taken from the stored string
	// (which would be an attacker-influenced integer conversion). A hash with any other tag
	// length is treated as unparseable — fail closed, and `needsRehash` says to re-mint it.
	if len(key) != argonKeyBytes {
		return argon2Params{}, false
	}
	return argon2Params{
		memoryKiB: uint32(memory), time: uint32(time), threads: uint8(threads),
		salt: salt, key: key,
	}, true
}

func verifyArgon2id(stored, candidate string) bool {
	params, ok := parseArgon2id(stored)
	if !ok {
		return false
	}
	computed := argon2.IDKey([]byte(candidate), params.salt, params.time, params.memoryKiB,
		params.threads, argonKeyBytes)
	return subtle.ConstantTimeCompare(computed, params.key) == 1
}

// timingEqualiser is a real hash of a random password at the CURRENT parameters, computed once
// and reused. It exists so that verifying against a MISSING account costs the same as verifying
// a wrong password — otherwise a login endpoint answers in microseconds for an unknown address
// and in ~80ms for a known one, which enumerates the user table. Generated rather than
// hardcoded so it cannot drift from the live parameters.
var (
	timingEqualiserOnce sync.Once
	timingEqualiserPHC  string
)

func timingEqualiser() string {
	timingEqualiserOnce.Do(func() {
		filler := make([]byte, 32)
		if _, err := rand.Read(filler); err != nil {
			panic("Crypto.checkPassword: no source of randomness: " + err.Error())
		}
		timingEqualiserPHC = HashPassword(MakeSecret(string(filler))).Value
	})
	return timingEqualiserPHC
}

// CheckPassword is `Crypto.checkPassword`. It takes a `Maybe PasswordHash` deliberately: a
// missing account and a wrong password have to cost the same and answer the same, so `Nothing`
// still performs a full verification — against the timing equaliser — and then fails with the
// identical message. The caller does not have to know that this problem exists, which is the
// point.
func CheckPassword(stored Maybe[PasswordHash], candidate SecretString) Check[Maybe[PasswordHash]] {
	requirePasswordLength("Crypto.checkPassword", candidate)
	hash, present := stored.Value()
	phc := timingEqualiser()
	if present {
		phc = hash.Value
	}
	verified := verifyArgon2id(phc, candidate.Reveal())
	if !verified || !present {
		return Reject[Maybe[PasswordHash]](401, "invalid credentials")
	}
	return Accept(stored)
}

// NeedsRehash is `Crypto.needsRehash`: true when the stored hash was minted with weaker
// parameters than the current ones, or in a format this runtime cannot parse at all (a foreign
// hash, or one from a scheme that has been dropped) — in both cases the right move on the next
// successful login is to re-mint, so both answer true.
//
// Tesl deliberately does NOT perform the rehash: a crypto function writing to the database
// would be a hidden effect, and it is one explicit line in the application.
func NeedsRehash(stored PasswordHash) bool {
	params, ok := parseArgon2id(stored.Value)
	if !ok {
		return true
	}
	return params.memoryKiB < argonMemoryKiB || params.time < argonTime ||
		params.threads != argonThreads
}
