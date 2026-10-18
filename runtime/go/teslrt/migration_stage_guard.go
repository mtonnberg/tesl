package teslrt

import (
	"encoding/hex"
	"fmt"
	"slices"
	"strings"
)

type pgStageGuard struct {
	preparation        pgStagePreparation
	target, descriptor string
}

func pgParseStageGuards(n pgRowCanonical) ([]pgStageGuard, error) {
	if n.atom {
		return nil, fmt.Errorf("guard inventory must be a sequence")
	}
	var guards []pgStageGuard
	last := ""
	names := map[string]bool{}
	for _, entry := range n.children {
		if !entry.list(3) || !entry.children[0].isAtom("staged-unique-guard-v1") {
			return nil, fmt.Errorf("invalid guarded stage descriptor")
		}
		stages, err := pgParseStagePreparations(pgRowList(entry.children[1]))
		if err != nil {
			return nil, err
		}
		s := stages[0]
		target := entry.children[2]
		if s.id <= last || !target.list(3) || !target.children[0].atom || !pgMigrationIdentifier(target.children[0].value) ||
			!target.children[1].list(1) || !target.children[1].children[0].isAtom(s.column) || !pgRowBool(target.children[2], true) ||
			target.children[0].value == s.index || names[target.children[0].value] {
			return nil, fmt.Errorf("invalid guarded target identity")
		}
		last = s.id
		names[target.children[0].value] = true
		guards = append(guards, pgStageGuard{s, target.children[0].value, pgRowEncode(entry)})
	}
	return guards, nil
}

func pgStageGuardName(stage string) string { return "tesl_guard_" + stage[:48] }

// Check the entire typed field/dependency closure against sealed current source.
// Only the exact promoted declaration is rewritten to reuse the stage checker.
func pgCheckGuardSource(plan *pgRowPhysicalPlan, storage pgRowCanonical, guard pgStageGuard) error {
	s := guard.preparation
	found := guard.target == ""
	for _, table := range storage.children[2].children {
		if !table.list(3) || !table.children[0].isAtom(s.table) {
			continue
		}
		for _, index := range table.children[2].children {
			if guard.target == "" && index.list(3) && slices.ContainsFunc(index.children[1].children, func(c pgRowCanonical) bool { return c.isAtom(s.column) }) {
				return fmt.Errorf("cancellation requires no replacement index on the staged key")
			}
			if index.list(3) && index.children[0].isAtom(guard.target) && index.children[1].list(1) &&
				index.children[1].children[0].isAtom(s.column) && pgRowBool(index.children[2], true) {
				found = true
			}
		}
	}
	if !found {
		return fmt.Errorf("guard unique target differs from sealed source")
	}
	schema := storage.children[1]
	if !schema.list(3) {
		return fmt.Errorf("guard lacks complete schema")
	}
	ref := pgRowTypeReference(plan.family, s.entity)
	converted := false
	var rewrite func(pgRowCanonical) pgRowCanonical
	rewrite = func(n pgRowCanonical) pgRowCanonical {
		if n.list(6) && n.children[0].isAtom("entity") && pgRowCanonicalEqual(n.children[1], ref) {
			children := slices.Clone(n.children)
			indexes := slices.Clone(children[5].children)
			if guard.target == "" {
				indexes = append(indexes, pgRowList(pgRowAtom("staging-unique-index-v1"), pgRowList(pgRowAtom(s.field)), pgRowList(pgRowAtom("some"), pgRowAtom(s.index)), pgRowAtom("default-btree"), pgRowAtom("nulls-distinct"), pgRowAtom("immediate")))
				converted = true
			}
			for i, ix := range indexes {
				if ix.list(4) && ix.children[0].isAtom("index") && pgRowBool(ix.children[1], true) && ix.children[2].list(1) && ix.children[2].children[0].isAtom(s.field) {
					indexes[i] = pgRowList(pgRowAtom("staging-unique-index-v1"), ix.children[2], ix.children[3], pgRowAtom("default-btree"), pgRowAtom("nulls-distinct"), pgRowAtom("immediate"))
					converted = true
				}
			}
			children[5] = pgRowList(indexes...)
			return pgRowList(children...)
		}
		if n.atom {
			return n
		}
		children := make([]pgRowCanonical, len(n.children))
		for i, c := range n.children {
			children[i] = rewrite(c)
		}
		return pgRowList(children...)
	}
	schema = rewrite(schema)
	if !converted {
		return fmt.Errorf("guard lacks exact unique source declaration")
	}
	defs := schema.children[2].children[2].children
	slices.SortFunc(defs, func(a, b pgRowCanonical) int { return strings.Compare(pgRowEncode(a), pgRowEncode(b)) })
	prep, _, err := pgReadRowCanonical(hex.EncodeToString([]byte(s.descriptor)))
	if err != nil {
		return err
	}
	stages := []pgRowCanonical{}
	if storage.list(4) {
		stages = append(stages, storage.children[3].children...)
	}
	stages = append(stages, prep)
	slices.SortFunc(stages, func(a, b pgRowCanonical) int { return strings.Compare(a.children[1].value, b.children[1].value) })
	r := &pgMigrationWireReader{}
	pgCheckStageSource(r, schema, pgRowList(pgRowAtom("postgres-storage-v2"), schema, storage.children[2], pgRowList(stages...)), plan.family, schema.children[1].value, schema.children[1].value)
	return r.err
}
