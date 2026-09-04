package teslrt

import (
	"fmt"
	"strings"
	"sync"
	"time"
)

// `cache C = Cache { … }`: a keyed store with per-entry expiry.
//
// WHAT THIS IS AND IS NOT. On Racket a cache reads and writes a `tesl_cache` TABLE whenever a
// PostgreSQL runtime is bound, and its own in-memory hash otherwise — and nothing binds one
// until `call-with-database`, so the in-memory store is what a program actually uses unless it
// opens a connection. This is that store, with the same rules:
//
//	an entry with no TTL never expires;
//	a TTL is seconds from the moment of the SET, not from the declaration;
//	a READ is what notices expiry — the entry is removed and the read answers Nothing, so a
//	stale value can never be returned, and no sweeper goroutine is needed;
//	`invalidate` matches a LITERAL prefix, not a LIKE pattern. Racket's PostgreSQL path spells
//	that `left(key, length($1)) = $1` precisely because `key LIKE $1 || '%'` treats `%` in the
//	prefix as a wildcard — a prefix containing one would wipe far more than it names.
//
// The value is typed: `valueType: String` makes it a `Cache[string]`, so a hit needs no decode
// and cannot answer the wrong shape. That is a departure from Racket, which stores JSON text in
// the table and decodes on read — the JSON round trip exists there because a SQL column has to
// hold something, and it is precisely what this store does not need.
//
// BOUNDS. A cache keyed on request data (the spec's own `"user_<id>_*"` example) is a memory
// sink unless something reclaims it, and a read-driven expiry reclaims nothing a program
// never reads again. So the store is bounded two ways: expired entries are swept on a write
// once per second, and the entry count is capped — a write past the cap evicts expired
// entries first and then the OLDEST write, so a hot key set survives and a churned one does
// not accumulate. Neither changes what a read can answer: a live value or Nothing.
type cacheEntry[V any] struct {
	value V
	// expiresAt is Unix seconds, or 0 for "never" — the same distinction Racket makes with
	// a #f expiry.
	expiresAt int64
	// seq is the write's position in the cache's own sequence; what "oldest" means.
	seq int64
}

// defaultCacheMaxEntries bounds one cache declaration's entry count.
const defaultCacheMaxEntries = 100000

// cacheNow is the clock, a variable so the runtime's own tests can move it.
var cacheNow = func() int64 { return time.Now().Unix() }

type Cache[V any] struct {
	mutex sync.Mutex
	// entries is allocated with the cache and never becomes nil again — a nil map here would
	// be a nil flow into every operation that reads or writes it.
	entries map[string]cacheEntry[V]
	// defaultTTL is `defaultTtl:` in seconds, or 0 when the declaration omits it.
	defaultTTL int64
	maxEntries int
	// writes is the FIFO of (key, seq) in write order, from which the oldest live entry is
	// found in amortised O(1): an entry whose key now maps to a newer seq is stale and
	// skipped. It is trimmed whenever it grows past twice the entry count.
	writes    []cacheWrite
	nextSeq   int64
	lastSweep int64
	// backend is the DURABLE store — the `tesl_cache` table — when the declaration names a
	// Postgres-backed database (`NewCacheOn` in pgstores.go attaches it); nil otherwise.
	// Each operation asks `durable()` and uses the map above when the backend is absent or
	// its database is not bound: a `test` block without `with database` keeps the in-memory
	// cache, a served program shares the table with every other instance.
	backend cacheBackend
}

// cacheBackend is what a durable cache answers, in this file's vocabulary: a value or a miss,
// a TTL in seconds (0 = never expires), a literal prefix. It names no driver type, and it is
// NOT generic: values cross it as `any` (the backend holds the declaration's codec, so what
// comes back is the value type), because a generic backend's methods are invisible to the
// `unused` lint that gates emitted code when a program declares no cache.
type cacheBackend interface {
	active() bool
	get(key string) (any, bool)
	set(key string, value any, ttlSeconds int64)
	del(key string)
	invalidatePrefix(prefix string)
	reset()
}

// durable answers the backend this call runs against, or nil for the in-memory path.
func (cache *Cache[V]) durable() cacheBackend {
	if backend := cache.backend; backend != nil && backend.active() {
		return backend
	}
	return nil
}

type cacheWrite struct {
	key string
	seq int64
}

// NewCache is what a `cache` declaration becomes: one package-level value per declaration.
func NewCache[V any](defaultTTLSeconds int64) *Cache[V] {
	return &Cache[V]{entries: map[string]cacheEntry[V]{}, defaultTTL: defaultTTLSeconds,
		maxEntries: defaultCacheMaxEntries}
}

// CacheGet answers the live value, or Nothing on a miss OR an expired entry — and removes the
// expired one on the way out, so the next read does no work either.
func CacheGet[V any](cache *Cache[V], key string) Maybe[V] {
	if backend := cache.durable(); backend != nil {
		if value, found := backend.get(key); found {
			if typed, ok := value.(V); ok {
				return Something(typed)
			}
			panic(fmt.Sprintf("cache: the stored value decoded to %T, not the declared value type", value))
		}
		return Nothing[V]()
	}
	cache.mutex.Lock()
	defer cache.mutex.Unlock()
	entry, found := cache.entries[key]
	if !found {
		return Nothing[V]()
	}
	if entry.expiresAt != 0 && cacheNow() > entry.expiresAt {
		delete(cache.entries, key)
		return Nothing[V]()
	}
	return Something(entry.value)
}

// CacheSet stores under the declaration's default TTL.
func CacheSet[V any](cache *Cache[V], key string, value V) struct{} {
	return cacheStore(cache, key, value, cache.defaultTTL)
}

// CacheSetTTL stores under an explicit TTL in seconds, which overrides the declaration's.
func CacheSetTTL[V any](cache *Cache[V], key string, value V, ttlSeconds Int) struct{} {
	seconds, exact := ttlSeconds.Int64()
	if !exact || seconds < 0 {
		panic("Cache.set: " + ttlSeconds.String() + " is not a TTL in seconds")
	}
	return cacheStore(cache, key, value, seconds)
}

func cacheStore[V any](cache *Cache[V], key string, value V, ttlSeconds int64) struct{} {
	if backend := cache.durable(); backend != nil {
		backend.set(key, value, ttlSeconds)
		return struct{}{}
	}
	cache.mutex.Lock()
	defer cache.mutex.Unlock()
	now := cacheNow()
	if now != cache.lastSweep {
		// At most one sweep per clock second, so a burst of writes into a large cache does
		// not pay an O(n) scan on each of them.
		cache.sweepExpired(now)
	}
	if _, present := cache.entries[key]; !present && len(cache.entries) >= cache.maxEntries {
		cache.sweepExpired(now)
		for len(cache.entries) >= cache.maxEntries {
			if !cache.evictOldest() {
				break
			}
		}
	}
	expiresAt := int64(0)
	if ttlSeconds > 0 {
		expiresAt = now + ttlSeconds
	}
	cache.nextSeq++
	cache.entries[key] = cacheEntry[V]{value: value, expiresAt: expiresAt, seq: cache.nextSeq}
	cache.writes = append(cache.writes, cacheWrite{key: key, seq: cache.nextSeq})
	if len(cache.writes) > 2*len(cache.entries)+16 {
		cache.compactWrites()
	}
	return struct{}{}
}

// sweepExpired removes every entry whose TTL has passed. The caller holds the mutex.
func (cache *Cache[V]) sweepExpired(now int64) {
	cache.lastSweep = now
	for key, entry := range cache.entries {
		if entry.expiresAt != 0 && now > entry.expiresAt {
			delete(cache.entries, key)
		}
	}
}

// evictOldest removes the entry with the earliest live write, skipping FIFO records that
// name a key since overwritten or deleted. It answers false when nothing is left to evict.
func (cache *Cache[V]) evictOldest() bool {
	for len(cache.writes) > 0 {
		oldest := cache.writes[0]
		cache.writes = cache.writes[1:]
		if entry, present := cache.entries[oldest.key]; present && entry.seq == oldest.seq {
			delete(cache.entries, oldest.key)
			return true
		}
	}
	return false
}

// compactWrites drops the stale FIFO records so the FIFO stays proportional to the entries
// rather than to the write history.
func (cache *Cache[V]) compactWrites() {
	live := make([]cacheWrite, 0, len(cache.entries))
	for _, write := range cache.writes {
		if entry, present := cache.entries[write.key]; present && entry.seq == write.seq {
			live = append(live, write)
		}
	}
	cache.writes = live
}

// CacheDelete evicts one key. Deleting a key that is not there is not an error — the point of
// the call is the state afterwards.
func CacheDelete[V any](cache *Cache[V], key string) struct{} {
	if backend := cache.durable(); backend != nil {
		backend.del(key)
		return struct{}{}
	}
	cache.mutex.Lock()
	defer cache.mutex.Unlock()
	delete(cache.entries, key)
	return struct{}{}
}

// CacheInvalidatePrefix evicts every key that BEGINS WITH prefix, literally.
func CacheInvalidatePrefix[V any](cache *Cache[V], prefix string) struct{} {
	if backend := cache.durable(); backend != nil {
		backend.invalidatePrefix(prefix)
		return struct{}{}
	}
	cache.mutex.Lock()
	defer cache.mutex.Unlock()
	for key := range cache.entries {
		if strings.HasPrefix(key, prefix) {
			delete(cache.entries, key)
		}
	}
	return struct{}{}
}

// CacheReset empties the store, for a test block that starts from an empty one. It is the
// cache's counterpart of `TableTruncate`, and exists for the same reason: one block's entries
// must not be another's.
func CacheReset[V any](cache *Cache[V]) {
	if backend := cache.durable(); backend != nil {
		backend.reset()
		return
	}
	cache.mutex.Lock()
	defer cache.mutex.Unlock()
	cache.entries = map[string]cacheEntry[V]{}
	cache.writes = nil
}
