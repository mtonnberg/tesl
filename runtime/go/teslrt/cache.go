package teslrt

import (
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
type cacheEntry[V any] struct {
	value V
	// expiresAt is Unix seconds, or 0 for "never" — the same distinction Racket makes with
	// a #f expiry.
	expiresAt int64
}

type Cache[V any] struct {
	mutex sync.Mutex
	// entries is allocated with the cache and never becomes nil again — a nil map here would
	// be a nil flow into every operation that reads or writes it.
	entries map[string]cacheEntry[V]
	// defaultTTL is `defaultTtl:` in seconds, or 0 when the declaration omits it.
	defaultTTL int64
}

// NewCache is what a `cache` declaration becomes: one package-level value per declaration.
func NewCache[V any](defaultTTLSeconds int64) *Cache[V] {
	return &Cache[V]{entries: map[string]cacheEntry[V]{}, defaultTTL: defaultTTLSeconds}
}

// CacheGet answers the live value, or Nothing on a miss OR an expired entry — and removes the
// expired one on the way out, so the next read does no work either.
func CacheGet[V any](cache *Cache[V], key string) Maybe[V] {
	cache.mutex.Lock()
	defer cache.mutex.Unlock()
	entry, found := cache.entries[key]
	if !found {
		return Nothing[V]()
	}
	if entry.expiresAt != 0 && time.Now().Unix() > entry.expiresAt {
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
	cache.mutex.Lock()
	defer cache.mutex.Unlock()
	expiresAt := int64(0)
	if ttlSeconds > 0 {
		expiresAt = time.Now().Unix() + ttlSeconds
	}
	cache.entries[key] = cacheEntry[V]{value: value, expiresAt: expiresAt}
	return struct{}{}
}

// CacheDelete evicts one key. Deleting a key that is not there is not an error — the point of
// the call is the state afterwards.
func CacheDelete[V any](cache *Cache[V], key string) struct{} {
	cache.mutex.Lock()
	defer cache.mutex.Unlock()
	delete(cache.entries, key)
	return struct{}{}
}

// CacheInvalidatePrefix evicts every key that BEGINS WITH prefix, literally.
func CacheInvalidatePrefix[V any](cache *Cache[V], prefix string) struct{} {
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
	cache.mutex.Lock()
	defer cache.mutex.Unlock()
	cache.entries = map[string]cacheEntry[V]{}
}
