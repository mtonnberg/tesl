package teslrt

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"slices"
	"strings"
)

// The settled stage representation adds only the reviewed UNIQUE targets. It
// retains preparation indexes, columns, marker defaults and actual generations.
func pgStageSettledShape(window *pgRowPhysicalPlan) (*pgRowPhysicalPlan, error) {
	r := &pgMigrationWireReader{}
	n := pgRowDocument(r, window.contract, window.hash, "migration")
	if r.err != nil || !n.list(10) || !n.children[0].isAtom("tesl-retained-physical-version-v10") {
		return nil, fmt.Errorf("stage settled shape requires guarded window")
	}
	body := make([]pgRowCanonical, 8)
	copy(body, n.children[:8])
	body[0] = pgRowAtom("tesl-settled-physical-version-v1")
	entities := slices.Clone(body[6].children)
	for i, e := range entities {
		children := slices.Clone(e.children)
		if children == nil || len(children) != 9 {
			return nil, fmt.Errorf("stage settled shape requires complete entity descriptors")
		}
		indexes := slices.Clone(children[7].children)
		for _, g := range window.stageGuards {
			if g.preparation.entity == e.children[0].value {
				indexes = append(indexes, pgRowIndexNode(PgMigrationCatalogIndex{Name: g.target, Columns: []string{g.preparation.column}, Unique: true}))
			}
		}
		slices.SortFunc(indexes, func(a, b pgRowCanonical) int { return strings.Compare(a.children[0].value, b.children[0].value) })
		children[7] = pgRowList(indexes...)
		entities[i] = pgRowList(children...)
	}
	body[6] = pgRowList(entities...)
	raw := pgRowEncode(pgRowList(pgRowAtom("tesl-migration-canonical"), pgRowAtom("1"), pgRowAtom("migration"), pgRowList(body...)))
	settled, err := pgParseRowSettledPlan(hex.EncodeToString([]byte(raw)), fmt.Sprintf("%x", sha256.Sum256([]byte(raw))))
	if err == nil {
		settled.stages = slices.Clone(window.stages)
		settled.compiled = window.compiled
	}
	return settled, err
}

func pgParseStageContract(c *pgRowContract, n pgRowCanonical) (*pgRowContract, error) {
	if len(c.window.stageGuards) == 0 || !n.children[8].list(0) {
		return nil, fmt.Errorf("stage Contract lacks exact guarded window")
	}
	settled, err := pgStageSettledShape(c.window)
	if err != nil {
		return nil, err
	}
	if settled.hash != c.settled.hash || settled.contract != c.settled.contract {
		return nil, fmt.Errorf("stage Contract changes storage beyond target indexes")
	}
	ops := []pgRowCanonical{}
	for _, g := range c.window.stageGuards {
		descriptor, _, err := pgReadRowCanonical(hex.EncodeToString([]byte(g.descriptor)))
		if err != nil {
			return nil, err
		}
		ops = append(ops, pgRowList(pgRowAtom("promote-stage"), pgRowAtom(g.preparation.entity), descriptor))
	}
	behavior := pgRowEncode(pgRowList(pgRowAtom("tesl-migration-canonical"), pgRowAtom("1"), pgRowAtom("contract"), pgRowList(pgRowAtom("tesl-stage-promotion-v1"), pgRowList(ops...))))
	if !n.children[5].isAtom(fmt.Sprintf("%x", sha256.Sum256([]byte(behavior)))) || !pgRowCanonicalEqual(n.children[9], pgRowList(ops...)) {
		return nil, fmt.Errorf("PromoteStage authority differs from complete source/target descriptors")
	}
	c.operations = ops
	return c, nil
}
