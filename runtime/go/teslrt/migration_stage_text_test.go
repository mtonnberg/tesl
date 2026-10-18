package teslrt

import (
	"crypto/sha256"
	"fmt"
	"testing"
)

func TestStageTextDescriptorEquality(t *testing.T) {
	a, l := pgRowAtom, pgRowList
	for _, equality := range []string{"default-text-btree-libc-c-posix-v1", "default-btree", "C"} {
		semantic := l(a("staged-unique-key-v1"), a("owner"), a("notes"), a("title"), l(), a(equality), a("nulls-distinct"), a("immediate"))
		id := fmt.Sprintf("%x", sha256.Sum256([]byte(pgRowEncode(l(a("tesl-migration-canonical"), a("1"), a("snapshot"), semantic)))))
		entry := l(a("staged-unique-preparation-v1"), a(id), semantic, a("Note"), a("title"), a("notes"), a("title"), a("text"), l(a("bool"), a("false")), a("title_lookup"))
		_, err := pgParseStagePreparations(l(entry))
		if (err == nil) != (equality == "default-text-btree-libc-c-posix-v1") {
			t.Fatal(equality, err)
		}
	}
}

func TestStageTextDefaultResolution(t *testing.T) {
	good := pgStageTextDefault{100, "pg_catalog", "default", "d", "c", "C", "C", true}
	if !good.supported() {
		t.Fatal("builtin C default refused")
	}
	posix := good
	posix.collate, posix.ctype = "POSIX", "POSIX"
	if !posix.supported() {
		t.Fatal("builtin POSIX default refused")
	}
	for _, mutate := range []func(*pgStageTextDefault){
		func(d *pgStageTextDefault) { d.collate = "en_US.UTF-8" },
		func(d *pgStageTextDefault) { d.collate = "C.UTF-8" },
		func(d *pgStageTextDefault) { d.ctype = "en_US.UTF-8" },
		func(d *pgStageTextDefault) { d.databaseProvider = "i" },
		func(d *pgStageTextDefault) { d.databaseProvider = "b" },
		func(d *pgStageTextDefault) { d.provider = "c"; d.name = "C" },
		func(d *pgStageTextDefault) { d.deterministic = false },
		func(d *pgStageTextDefault) { d.oid = 99999 },
		func(d *pgStageTextDefault) { d.namespace = "public" },
	} {
		bad := good
		mutate(&bad)
		if bad.supported() {
			t.Fatalf("unsupported catalog accepted: %+v", bad)
		}
	}
}
