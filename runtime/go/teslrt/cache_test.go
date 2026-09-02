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

// ── Bounds ────────────────────────────────────────────────────────────────────

// fakeCacheClock replaces the cache's clock for the test and answers a function that moves it.
func fakeCacheClock(t *testing.T) func(seconds int64) {
	t.Helper()
	now := time.Now().Unix()
	previous := cacheNow
	cacheNow = func() int64 { return now }
	t.Cleanup(func() { cacheNow = previous })
	return func(seconds int64) { now += seconds }
}

// Expired entries no longer wait for a read that may never come: the next write after the
// clock moves sweeps them, and the entry count never passes the bound meanwhile.
func TestCacheExpiredEntriesDoNotStayResident(t *testing.T) {
	advance := fakeCacheClock(t)
	cache := NewCache[string](1)
	for i := 0; i <= defaultCacheMaxEntries; i++ {
		CacheSet(cache, fmt.Sprintf("user_%d", i), "v")
	}
	if len(cache.entries) != defaultCacheMaxEntries {
		t.Fatalf("%d entries resident, want the %d bound", len(cache.entries), defaultCacheMaxEntries)
	}
	advance(2)
	CacheSet(cache, "fresh", "v")
	if len(cache.entries) != 1 {
		t.Fatalf("%d entries resident after every TTL passed, want just the fresh one", len(cache.entries))
	}
	if got := CacheGet(cache, "fresh"); !got.IsSomething() {
		t.Fatal("the fresh entry must survive the sweep")
	}
}

// At the bound, expired entries go first and then the OLDEST write; a live, recent entry is
// never the victim while an older one exists.
func TestCacheBoundEvictsExpiredThenOldest(t *testing.T) {
	advance := fakeCacheClock(t)
	cache := NewCache[string](0)
	cache.maxEntries = 3
	CacheSet(cache, "a", "v")
	CacheSetTTL(cache, "b", "v", FromInt64(1))
	CacheSet(cache, "c", "v")
	advance(2)
	CacheSet(cache, "d", "v") // b has expired: it is the one to go
	if _, still := cache.entries["b"]; still || len(cache.entries) != 3 {
		t.Fatalf("entries after d = %v", keysOf(cache))
	}
	CacheSet(cache, "e", "v") // nothing expired: the oldest live write (a) goes
	if _, still := cache.entries["a"]; still || len(cache.entries) != 3 {
		t.Fatalf("entries after e = %v", keysOf(cache))
	}
	CacheSet(cache, "c", "v2") // an overwrite is not a new entry and evicts nothing
	if len(cache.entries) != 3 {
		t.Fatalf("an overwrite changed the count: %v", keysOf(cache))
	}
	CacheSet(cache, "f", "v") // c was rewritten, so d is now the oldest
	if _, still := cache.entries["d"]; still {
		t.Fatalf("entries after f = %v, want d evicted (c was rewritten)", keysOf(cache))
	}
}

func keysOf[V any](cache *Cache[V]) []string {
	keys := make([]string, 0, len(cache.entries))
	for key := range cache.entries {
		keys = append(keys, key)
	}
	return keys
}
