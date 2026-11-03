package teslrt

import (
	"context"
	"fmt"
	"slices"

	"github.com/jackc/pgx/v5"
)

// OID 100 is PostgreSQL's pinned database-default collation, not a collation
// chosen by name. Resolve its provider through pg_database, including on PG14
// where datlocprovider does not exist. No session locale or search_path applies.
type pgStageTextDefault struct {
	oid                                                         uint32
	namespace, name, provider, databaseProvider, collate, ctype string
	deterministic                                               bool
}

func pgStageBuiltinText(typ pgRowCanonical, nullable bool) bool {
	primitive := func(n pgRowCanonical, name string) bool {
		return n.list(2) && n.children[0].isAtom("named") && n.children[1].list(3) &&
			n.children[1].children[0].isAtom("reference") && n.children[1].children[1].isAtom("type") &&
			n.children[1].children[2].list(2) && n.children[1].children[2].children[0].isAtom("primitive") &&
			n.children[1].children[2].children[1].isAtom(name)
	}
	if nullable {
		if !typ.list(3) || !typ.children[0].isAtom("apply") || !primitive(typ.children[1], "Tesl.Maybe.Maybe") {
			return false
		}
		typ = typ.children[2]
	}
	return primitive(typ, "Tesl.Prelude.String")
}

func (d pgStageTextDefault) supported() bool {
	c := func(s string) bool { return s == "C" || s == "POSIX" }
	return d.oid == 100 && d.namespace == "pg_catalog" && d.name == "default" &&
		d.provider == "d" && d.deterministic && d.databaseProvider == "c" && c(d.collate) && c(d.ctype)
}

func pgVerifyStageTextDefault(ctx context.Context, tx pgx.Tx, stages []pgStagePreparation) error {
	if !slices.ContainsFunc(stages, func(s pgStagePreparation) bool { return s.scalar == "text" }) {
		return nil
	}
	var d pgStageTextDefault
	err := tx.QueryRow(ctx, `select c.oid,n.nspname,c.collname,c.collprovider::text,c.collisdeterministic,
 coalesce(pg_catalog.to_jsonb(d)->>'datlocprovider','c'),d.datcollate,d.datctype
 from pg_catalog.pg_type t join pg_catalog.pg_namespace tn on tn.oid=t.typnamespace
 join pg_catalog.pg_collation c on c.oid=t.typcollation
 join pg_catalog.pg_namespace n on n.oid=c.collnamespace
 join pg_catalog.pg_database d on d.datname=pg_catalog.current_database()
 where tn.nspname='pg_catalog' and t.typname='text'`).Scan(
		&d.oid, &d.namespace, &d.name, &d.provider, &d.deterministic, &d.databaseProvider, &d.collate, &d.ctype)
	if err != nil {
		return err
	}
	if !d.supported() {
		return fmt.Errorf("staged TEXT requires builtin database-default collation with deterministic libc C/POSIX locale")
	}
	return nil
}
