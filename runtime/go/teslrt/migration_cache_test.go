package teslrt

import (
	"fmt"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

func pgArtifactCacheFixture(t *testing.T, f *pgControlTestFixture) *Database {
	return pgRowBaselineFixtureConfigured(t, f, nil, func(db *Database) {
		NewCacheOnArtifact(db, "Catalog", 0, func(value string) any { return value }, DecodeStringValue, strings.Repeat("a", 64))
	})
}

func TestArtifactCacheWorkerRuntime(t *testing.T) {
	f, request := pgNewWorkerTest(t)
	var old, fresh, reader *Cache[string]
	var replace func()
	encode := func(value string) any { return value }
	db := pgRowBaselineFixtureConfigured(t, f, nil, func(db *Database) {
		old = NewCacheOnArtifact(db, "Results", 0, encode, func(raw any) (string, error) {
			if replace != nil {
				replace()
				return "", fmt.Errorf("stale decoder")
			}
			return DecodeStringValue(raw)
		}, strings.Repeat("a", 64))
		reader = NewCacheOnArtifact(db, "Results", 0, encode, DecodeStringValue, strings.Repeat("a", 64))
		fresh = NewCacheOnArtifact(db, "Results", 0, encode, DecodeStringValue, strings.Repeat("b", 64))
	})
	if _, err := InstallPgCompiledRowBaseline(f.ctx, f.installer, db, f.roles); err != nil {
		t.Fatal(err)
	}
	if _, err := ExecutePgCompiledRowBaseline(f.ctx, f.worker, db, f.roles); err != nil {
		t.Fatal(err)
	}
	WithDatabase(db, func() {
		defer db.bound().closeRowPool()
		CacheSet(old, "key", "old")
		if CacheGet(fresh, "key").IsSomething() {
			t.Fatal("new codec read old codec's value")
		}
		CacheSet(fresh, "key", "new")
		replace = func() { CacheSet(reader, "key", "replacement") }
		if CacheGet(old, "key").IsSomething() {
			t.Fatal("failed decoder returned a hit")
		}
		if got := CacheGet(reader, "key"); !got.IsSomething() || got.SomethingValue != "replacement" {
			t.Fatal("failed decoder removed concurrent replacement", got)
		}
		if got := CacheGet(fresh, "key"); !got.IsSomething() || got.SomethingValue != "new" {
			t.Fatal("old codec damaged new codec's value", got)
		}
		CacheSet(fresh, "%literal", "yes")
		CacheSet(fresh, "expired", "gone")
		if _, err := request.Exec(f.ctx, "update "+pgx.Identifier{f.namespace, pgArtifactCacheTable}.Sanitize()+" set expires_at=now()-interval '1 second' where key='expired'"); err != nil {
			t.Fatal(err)
		}
		if CacheGet(fresh, "expired").IsSomething() {
			t.Fatal("expired durable value returned")
		}
		CacheSet(fresh, "other", "keep")
		CacheInvalidatePrefix(fresh, "%")
		if CacheGet(fresh, "%literal").IsSomething() || !CacheGet(fresh, "other").IsSomething() {
			t.Fatal("prefix invalidation used wildcard semantics")
		}
		CacheDelete(old, "key")
		if CacheGet(fresh, "key").IsSomething() {
			t.Fatal("explicit invalidation failed to clear another rolling version")
		}
	})
	if _, err := request.Exec(f.ctx, "create table "+pgx.Identifier{f.namespace, "unauthorized_cache"}.Sanitize()+"(key text)"); err == nil {
		t.Fatal("request acquired DDL privileges")
	}
}

func TestArtifactCacheCatalogAndACL(t *testing.T) {
	for _, drift := range []string{
		"alter table %s add column extra text",
		"alter table %s set logged",
		"alter table %s alter column key set default 'unexpected'",
		"alter table %s alter column value drop not null",
		"alter table %s rename constraint tesl_cache_artifacts_pkey to wrong_cache_key",
		"create index unexpected_cache_index on %s(key)",
		"grant select on %s to public",
		"grant truncate on %s to %s",
		"grant select(value) on %s to %s",
		"grant select on %s to %s with grant option",
	} {
		t.Run(drift, func(t *testing.T) {
			f, _ := pgNewWorkerTest(t)
			db := pgArtifactCacheFixture(t, f)
			if _, err := InstallPgCompiledRowBaseline(f.ctx, f.installer, db, f.roles); err != nil {
				t.Fatal(err)
			}
			err := pgControlTransaction(f.ctx, f.installer, true, func(tx pgx.Tx) error {
				if _, err := tx.Exec(f.ctx, "set local role "+quoteIdentifier(f.roles.Owner)); err != nil {
					return err
				}
				args := []any{pgx.Identifier{f.namespace, pgArtifactCacheTable}.Sanitize()}
				if strings.Count(drift, "%s") == 2 {
					args = append(args, quoteIdentifier(f.roles.Request))
				}
				if _, err := tx.Exec(f.ctx, fmt.Sprintf(drift, args...)); err != nil {
					return err
				}
				if _, err := pgVerifyArtifactCache(f.ctx, tx, f.namespace, f.roles, true); err == nil {
					t.Fatal("cache drift accepted", drift)
				}
				return nil
			})
			if err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestArtifactCacheInstallerAddsMissingExtension(t *testing.T) {
	f, request := pgNewWorkerTest(t)
	db := pgArtifactCacheFixture(t, f)
	if _, err := InstallPgCompiledRowBaseline(f.ctx, f.installer, db, f.roles); err != nil {
		t.Fatal(err)
	}
	qualified := pgx.Identifier{f.namespace, pgArtifactCacheTable}.Sanitize()
	if err := pgControlTransaction(f.ctx, f.installer, true, func(tx pgx.Tx) error {
		if _, err := tx.Exec(f.ctx, "set local role "+quoteIdentifier(f.roles.Owner)+"; drop table "+qualified); err != nil {
			return err
		}
		return tx.Commit(f.ctx)
	}); err != nil {
		t.Fatal(err)
	}
	// Existing format5 is inspectable, but a cache request cannot create storage.
	tx, err := request.Begin(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pgVerifyArtifactCache(f.ctx, tx, f.namespace, f.roles, true); err == nil {
		t.Fatal("missing storage admitted")
	}
	_ = tx.Rollback(f.ctx)
	if _, err := request.Exec(f.ctx, "create unlogged table "+qualified+" ("+pgArtifactCacheColumns+")"); err == nil {
		t.Fatal("request created missing storage")
	}
	for range 2 {
		if _, err := InstallPgCompiledRowBaseline(f.ctx, f.installer, db, f.roles); err != nil {
			t.Fatal("Installer failed to add or verify extension", err)
		}
	}
}
