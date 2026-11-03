package teslrt

// NewCacheOnArtifact uses the digest of the complete generated artifact, including
// codecs and runtime. Different artifacts prefer a miss to unproven compatibility.
func NewCacheOnArtifact[V any](database *Database, name string, defaultTTLSeconds int64,
	encode func(V) any, decode func(any) (V, error), identity string) *Cache[V] {
	if !pgMigrationDigest(identity) {
		panic("cache: missing compiler artifact codec identity")
	}
	pgRegisterMigrationFacility(database, "artifact cache", name)
	cache := NewCache[V](defaultTTLSeconds)
	cache.backend = &pgCacheBackend{pgStore: pgStore{database: database}, name: name, codec: identity,
		encode: func(value any) any { return encode(value.(V)) },
		decode: func(raw any) (any, error) { return decode(raw) }}
	return cache
}

func (backend *pgCacheBackend) artifactConnection() *PostgresDB {
	db := backend.connection()
	if db.migration == nil || db.migration.roles.Request == "" {
		return nil
	}
	pgRequireArtifactCache(db, backend.codec)
	return db
}

func (backend *pgCacheBackend) artifactGet(key string) (any, bool) {
	db := backend.connection()
	rows := PgQuery(db, "select value::text from "+db.QualifiedTable(pgArtifactCacheTable)+
		" where cache_name=$1 and codec=$2 and key=$3 and (expires_at is null or expires_at>now())",
		[]any{backend.name, backend.codec, key}, scanText)
	if len(rows) == 0 {
		return nil, false
	}
	raw, err := ParseJSON([]byte(rows[0]))
	if err != nil {
		return nil, false
	}
	value, err := backend.decode(raw)
	// Never delete a concurrent replacement after a failed decode.
	return value, err == nil
}

func (backend *pgCacheBackend) artifactSet(key string, value any, ttl int64) {
	db := backend.connection()
	table := db.QualifiedTable(pgArtifactCacheTable)
	backend.sweepExpired(db, table)
	PgExec(db, "insert into "+table+" (cache_name,codec,key,value,expires_at) values ($1,$2,$3,$4::jsonb,"+
		"case when $5::bigint>0 then now()+($5::bigint*interval '1 second') else null end) "+
		"on conflict(cache_name,codec,key) do update set value=excluded.value,expires_at=excluded.expires_at",
		[]any{backend.name, backend.codec, key, jsonbText(backend.encode(value)), ttl})
}

func (backend *pgCacheBackend) artifactDelete(predicate string, arguments ...any) {
	db := backend.connection()
	// Explicit invalidation clears the logical cache across rolling artifacts.
	args := append([]any{backend.name}, arguments...)
	PgExec(db, "delete from "+db.QualifiedTable(pgArtifactCacheTable)+" where cache_name=$1"+predicate, args)
}
