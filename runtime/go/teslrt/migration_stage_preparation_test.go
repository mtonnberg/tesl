package teslrt

import (
	"slices"
	"strings"
	"testing"
)

func TestStageDependencyClosureIncludesPrivateProducers(t *testing.T) {
	a, l := pgRowAtom, pgRowList
	ref := func(namespace, name string) pgRowCanonical {
		n := pgRowTypeReference("Schema.Stages", name)
		n.children[1] = a(namespace)
		return n
	}
	boolean := l(a("reference"), a("type"), l(a("primitive"), a("Tesl.Prelude.Bool")))
	fact, producer, helper := ref("predicate", "Approved"), ref("value", "approve"), ref("value", "desired")
	definitions := map[string]pgRowCanonical{
		pgRowEncode(fact):     l(a("fact"), fact, l(boolean)),
		pgRowEncode(producer): l(a("function"), producer, a("establish"), l(boolean), l(fact), l(helper)),
		pgRowEncode(helper):   l(a("function"), helper, a("fn"), l(), l(boolean), l(a("true"))),
	}
	field := l(a("field"), a("active"), l(a("named"), boolean), l(a("some"), fact), l(a("none")))
	roots := []pgRowCanonical{boolean, fact}
	slices.SortFunc(roots, func(a, b pgRowCanonical) int { return strings.Compare(pgRowEncode(a), pgRowEncode(b)) })
	closure := l(a("closure"), l(roots...), l())
	provided := map[string]bool{pgRowEncode(fact): true, pgRowEncode(producer): true, pgRowEncode(helper): true}
	if err := pgStageDependencyClosure(field, closure, definitions, provided); err != nil {
		t.Fatal(err)
	}
	for _, missing := range []pgRowCanonical{producer, helper} {
		delete(provided, pgRowEncode(missing))
		if err := pgStageDependencyClosure(field, closure, definitions, provided); err == nil {
			t.Fatal("trimmed private dependency closure accepted")
		}
		provided[pgRowEncode(missing)] = true
	}
	if err := pgStageDependencyClosure(field, l(a("closure"), l(boolean), l()), definitions, provided); err == nil {
		t.Fatal("omitted proof root accepted")
	}
}

func TestStagePreparationRefusesUnknownStorageFormats(t *testing.T) {
	for _, node := range []pgRowCanonical{
		pgRowList(),
		pgRowList(pgRowAtom("postgres-storage-v3"), pgRowList(), pgRowList()),
		pgRowList(pgRowAtom("postgres-storage-v2"), pgRowList(), pgRowList(), pgRowList()),
	} {
		if _, err := pgStagesFromStorage(node); err == nil {
			t.Fatal("unsupported/empty stage protocol accepted")
		}
	}
}
