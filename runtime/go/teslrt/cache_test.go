package teslrt

import (
	"fmt"
	"sync"
	"testing"
	"time"
)

func TestCacheMissAndHit(t *testing.T) {
	cache := NewCache[string](0)
	if got := CacheGet(cache, "absent"); got.IsSomething() {
		t.Fatalf("a miss answered %+v", got)
	}
	CacheSet(cache, "k", "v")
	got := CacheGet(cache, "k")
	if !got.IsSomething() || got.SomethingValue != "v" {
		t.Fatalf("hit answered %+v", got)
	}
	// A second read is still a hit: reading does not consume.
	if again := CacheGet(cache, "k"); !again.IsSomething() {
		t.Fatal("the second read missed")
	}
}

// The value is TYPED by the declaration, so an Int cache holds Ints — no JSON round trip, and
// no way to answer a wrongly shaped hit.
func TestCacheHoldsItsDeclaredType(t *testing.T) {
	cache := NewCache[Int](0)
	CacheSet(cache, "count", FromInt64(41))
	got := CacheGet(cache, "count")
	if !got.IsSomething() || !Equal(got.SomethingValue, FromInt64(41)) {
		t.Fatalf("hit answered %+v", got)
	}
}

func TestCacheOverwriteKeepsTheLastWrite(t *testing.T) {
	cache := NewCache[string](0)
	CacheSet(cache, "k", "first")
	CacheSet(cache, "k", "second")
	if got := CacheGet(cache, "k"); got.SomethingValue != "second" {
		t.Fatalf("hit answered %q", got.SomethingValue)
	}
}

// A cache with no default TTL never expires on its own.
func TestCacheWithoutTTLDoesNotExpire(t *testing.T) {
	cache := NewCache[string](0)
	CacheSet(cache, "k", "v")
	cache.entries["k"] = cacheEntry[string]{value: "v", expiresAt: 0}
	if got := CacheGet(cache, "k"); !got.IsSomething() {
		t.Fatal("an entry with no expiry was dropped")
	}
}

// An expired entry reads as a MISS and is removed on the way out, so no sweeper is needed.
func TestCacheExpiredEntryReadsAsMissAndIsEvicted(t *testing.T) {
	cache := NewCache[string](3600)
	CacheSet(cache, "k", "v")
	// Backdate it rather than sleeping: the rule under test is "expiry is noticed on read",
	// not how long a second is.
	cache.entries["k"] = cacheEntry[string]{value: "v", expiresAt: time.Now().Unix() - 1}
	if got := CacheGet(cache, "k"); got.IsSomething() {
		t.Fatalf("an expired entry answered %+v", got)
	}
	if _, still := cache.entries["k"]; still {
		t.Fatal("the expired entry was left behind")
	}
}

// An explicit TTL overrides the declaration's, and it is counted from the SET.
func TestCacheExplicitTTLOverridesTheDefault(t *testing.T) {
	cache := NewCache[string](3600)
	CacheSetTTL(cache, "short", "v", FromInt64(60))
	entry := cache.entries["short"]
	within := entry.expiresAt - time.Now().Unix()
	if within < 55 || within > 61 {
		t.Fatalf("explicit TTL produced an expiry %d seconds out", within)
	}
	CacheSet(cache, "long", "v")
	entry = cache.entries["long"]
	within = entry.expiresAt - time.Now().Unix()
	if within < 3595 || within > 3601 {
		t.Fatalf("default TTL produced an expiry %d seconds out", within)
	}
}

// A zero TTL means "no expiry", which is what a declaration without `defaultTtl:` gets.
func TestCacheZeroTTLNeverExpires(t *testing.T) {
	cache := NewCache[string](3600)
	CacheSetTTL(cache, "k", "v", FromInt64(0))
	if entry := cache.entries["k"]; entry.expiresAt != 0 {
		t.Fatalf("a zero TTL set an expiry at %d", entry.expiresAt)
	}
}

func TestCacheRejectsANegativeTTL(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("a negative TTL was accepted")
		}
	}()
	CacheSetTTL(NewCache[string](0), "k", "v", FromInt64(-1))
}

func TestCacheDeleteEvictsOneKeyOnly(t *testing.T) {
	cache := NewCache[string](0)
	CacheSet(cache, "a", "1")
	CacheSet(cache, "b", "2")
	CacheDelete(cache, "a")
	if CacheGet(cache, "a").IsSomething() {
		t.Fatal("the deleted key survived")
	}
	if !CacheGet(cache, "b").IsSomething() {
		t.Fatal("delete took a key it was not given")
	}
	// Deleting an absent key is not an error: the point of the call is the state after it.
	CacheDelete(cache, "absent")
}

func TestCacheInvalidatePrefixTakesTheWholeNamespace(t *testing.T) {
	cache := NewCache[string](0)
	CacheSet(cache, "profile:1", "a")
	CacheSet(cache, "profile:2", "b")
	CacheSet(cache, "session:1", "c")
	CacheInvalidatePrefix(cache, "profile:")
	if CacheGet(cache, "profile:1").IsSomething() || CacheGet(cache, "profile:2").IsSomething() {
		t.Fatal("a profile entry survived the invalidation")
	}
	if !CacheGet(cache, "session:1").IsSomething() {
		t.Fatal("the invalidation crossed into another namespace")
	}
}

// The prefix is LITERAL, not a LIKE pattern — Racket's PostgreSQL path spells this
// `left(key, length($1)) = $1` for exactly this reason, since `%` in a LIKE prefix would
// match far more than it names.
func TestCacheInvalidatePrefixIsLiteralNotAPattern(t *testing.T) {
	cache := NewCache[string](0)
	CacheSet(cache, "100%sure", "a")
	CacheSet(cache, "unrelated", "b")
	CacheInvalidatePrefix(cache, "%")
	if !CacheGet(cache, "unrelated").IsSomething() {
		t.Fatal("`%` was treated as a wildcard and wiped the namespace")
	}
	CacheInvalidatePrefix(cache, "100%")
	if CacheGet(cache, "100%sure").IsSomething() {
		t.Fatal("a literal prefix containing `%` matched nothing")
	}
}

func TestCacheResetEmptiesTheStore(t *testing.T) {
	cache := NewCache[string](0)
	CacheSet(cache, "k", "v")
	CacheReset(cache)
	if CacheGet(cache, "k").IsSomething() {
		t.Fatal("an entry survived the reset")
	}
	// Usable again afterwards: the reset drops the map, it does not poison the cache.
	CacheSet(cache, "k", "again")
	if !CacheGet(cache, "k").IsSomething() {
		t.Fatal("the cache was unusable after a reset")
	}
}

// One store, many goroutines: the emitted program serves requests concurrently, so the cache
// has to be safe under that. Run with -race, which the gate does.
func TestCacheIsSafeUnderConcurrentUse(t *testing.T) {
	cache := NewCache[string](3600)
	var waiting sync.WaitGroup
	for worker := range 8 {
		waiting.Add(1)
		go func() {
			defer waiting.Done()
			for index := range 64 {
				key := fmt.Sprintf("w%d:%d", worker, index)
				CacheSet(cache, key, "v")
				CacheGet(cache, key)
				if index%8 == 0 {
					CacheInvalidatePrefix(cache, fmt.Sprintf("w%d:", worker))
				}
				CacheDelete(cache, key)
			}
		}()
	}
	waiting.Wait()
}
