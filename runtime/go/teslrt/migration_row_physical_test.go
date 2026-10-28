package teslrt

import (
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"maps"
	"strings"
	"testing"
)

// These are unchanged outputs from the checked two-version compiler fixture,
// retained as parser inputs. They carry no native callback or SQL authority.
//
//go:embed testdata/row-physical-compiler/retained-physical-history.json
var rowPhysicalCompilerSeed string

//go:embed testdata/row-physical-compiler/migration-source-history.json
var rowPhysicalSourceSeed string

//go:embed testdata/row-physical-compiler/row-transform-history.json
var rowPhysicalTransformSeed string

type rowPhysicalSeedEnvelope struct {
	CompilerABI              string `json:"compilerAbi"`
	StoredValueCompatibility string `json:"storedValueCompatibility"`
	Databases                []struct {
		Database       string `json:"database"`
		Family         string `json:"family"`
		Namespace      string `json:"namespace"`
		CurrentVersion int    `json:"currentVersion"`
		Versions       []struct {
			Contract string `json:"contract"`
			Hash     string `json:"hash"`
		} `json:"versions"`
	} `json:"databases"`
}

func rowPhysicalSeed(t testing.TB) rowPhysicalSeedEnvelope {
	t.Helper()
	var seed rowPhysicalSeedEnvelope
	if err := json.Unmarshal([]byte(rowPhysicalCompilerSeed), &seed); err != nil {
		t.Fatal(err)
	}
	if len(seed.Databases) != 1 || len(seed.Databases[0].Versions) != 2 {
		t.Fatal("expected actual complete V1/V2 compiler fixture")
	}
	return seed
}

func TestRowPhysicalCanonicalAndRefusals(t *testing.T) {
	seed := rowPhysicalSeed(t)
	var previous *pgRowPhysicalPlan
	for _, version := range seed.Databases[0].Versions {
		plan, err := pgParseRowPhysicalPlan(version.Contract, version.Hash)
		if err != nil || plan == nil || plan.compiled != nil {
			t.Fatal("compiler document must parse as observation only", err)
		}
		if err := pgValidateRowPhysicalLineage(previous, plan); err != nil {
			t.Fatal("actual adjacent compiler lineage refused", err)
		}
		previous = plan
	}
	version := seed.Databases[0].Versions[1]
	cases := map[string]func(*pgRowCanonical){
		"unknown format":            func(n *pgRowCanonical) { n.children[0] = pgRowAtom("unknown") },
		"noncanonical version":      func(n *pgRowCanonical) { n.children[3] = pgRowAtom("02") },
		"missing entities sequence": func(n *pgRowCanonical) { n.children[6] = pgRowAtom("") },
		"duplicate entity": func(n *pgRowCanonical) {
			n.children[6].children = append(n.children[6].children, n.children[6].children[0])
		},
		"invalid generation":    func(n *pgRowCanonical) { n.children[6].children[0].children[2] = pgRowAtom("32768") },
		"future default marker": func(n *pgRowCanonical) { n.children[6].children[0].children[3] = pgRowAtom("3") },
		"unknown SQL carrier": func(n *pgRowCanonical) {
			n.children[6].children[0].children[5].children[0].children[1] = pgRowAtom("varchar")
		},
		"invalid nullable": func(n *pgRowCanonical) {
			n.children[6].children[0].children[5].children[0].children[2] = pgRowList(pgRowAtom("bool"), pgRowAtom("unknown"))
		},
		"duplicate physical column": func(n *pgRowCanonical) {
			c := &n.children[6].children[0].children[5]
			c.children = append(c.children, c.children[0])
		},
		"missing projection target": func(n *pgRowCanonical) {
			n.children[6].children[0].children[6].children[0].children[1] = pgRowAtom("missing")
		},
		"omitted retained write source": func(n *pgRowCanonical) { n.children[6].children[0].children[8] = pgRowList() },
		"foreign window entity":         func(n *pgRowCanonical) { n.children[7].children[0].children[0] = pgRowAtom("Missing") },
		"duplicate window": func(n *pgRowCanonical) {
			n.children[7].children = append(n.children[7].children, n.children[7].children[0])
		},
		"missing invalidation": func(n *pgRowCanonical) { n.children[7].children[0].children[7] = pgRowList() },
	}
	for name, change := range cases {
		t.Run(name, func(t *testing.T) {
			document, _, err := pgReadRowCanonical(version.Contract)
			if err != nil {
				t.Fatal(err)
			}
			change(&document.children[3])
			raw, hash := pgRowBaselineDocument(document.children[3])
			if plan, err := pgParseRowPhysicalPlan(hex.EncodeToString([]byte(raw)), hash); err == nil || plan != nil {
				t.Fatal("freshly hashed malformed physical description accepted", err)
			}
		})
	}
}

func TestRowPhysicalRegistrationRefusesAtomically(t *testing.T) {
	seed := rowPhysicalSeed(t)
	db := seed.Databases[0]
	if compiledRowHistories[db.Family] != nil {
		t.Fatal("compiler fixture family is unexpectedly already registered")
	}
	registerCompiledMigrationHistory(db.Database, db.Family, db.Namespace, db.CurrentVersion,
		seed.CompilerABI, seed.StoredValueCompatibility, rowPhysicalSourceSeed)
	registerCompiledRowHistory(rowPhysicalTransformSeed)
	compiled := compiledRowHistories[db.Family]
	if compiled == nil {
		t.Fatal("actual checked source companion failed to register")
	}
	t.Cleanup(func() {
		pgMigrationRegistrations.Lock()
		defer pgMigrationRegistrations.Unlock()
		delete(compiledRowPhysicalHistories, compiled)
		delete(compiledRowRegistrations, compiled)
		delete(compiledRowHistories, db.Family)
		delete(pgMigrationClosedFamilies, db.Family)
		compiledMigrationHistories.Delete(db.Family)
		databaseIdentities.Delete(db.Database)
	})
	rejected := func(t *testing.T, payload string) {
		t.Helper()
		before := maps.Clone(compiledRowPhysicalHistories)
		panicked := false
		func() { defer func() { panicked = recover() != nil }(); registerCompiledRowPhysicalHistory(payload) }()
		if !panicked || !maps.Equal(before, compiledRowPhysicalHistories) {
			t.Fatal("invalid physical envelope changed registration")
		}
	}
	for name, change := range map[string]func(map[string]any){
		"omitted complete database": func(n map[string]any) { n["databases"] = []any{} },
		"unbound database":          func(n map[string]any) { n["databases"].([]any)[0].(map[string]any)["database"] = "Foreign.Database" },
		"unbound family":            func(n map[string]any) { n["databases"].([]any)[0].(map[string]any)["family"] = "Foreign.Schema" },
		"missing retained version": func(n map[string]any) {
			d := n["databases"].([]any)[0].(map[string]any)
			d["versions"] = d["versions"].([]any)[:1]
		},
		"second version invalid": func(n map[string]any) {
			n["databases"].([]any)[0].(map[string]any)["versions"].([]any)[1].(map[string]any)["hash"] = "bad"
		},
		"extra envelope property": func(n map[string]any) { n["unrecognized"] = true },
		"foreign ABI":             func(n map[string]any) { n["compilerAbi"] = "foreign" },
	} {
		t.Run(name, func(t *testing.T) {
			var value map[string]any
			if err := json.Unmarshal([]byte(rowPhysicalCompilerSeed), &value); err != nil {
				t.Fatal(err)
			}
			change(value)
			payload, err := json.Marshal(value)
			if err != nil {
				t.Fatal(err)
			}
			rejected(t, string(payload))
		})
	}
	t.Run("malformed JSON", func(t *testing.T) { rejected(t, "{") })
	registerCompiledRowPhysicalHistory(rowPhysicalCompilerSeed)
	entry := compiledRowPhysicalHistories[compiled]
	if entry == nil || len(entry.versions) != 2 {
		t.Fatal("valid complete retry lost physical inventory")
	}
	for _, plan := range entry.versions {
		if plan.compiled != compiled {
			t.Fatal("physical registration changed exact source owner")
		}
	}
	registerCompiledRowPhysicalHistory(rowPhysicalCompilerSeed)
	if compiledRowPhysicalHistories[compiled] != entry {
		t.Fatal("identical registration replaced private handles")
	}
	owner := RegisterDatabaseMigrationHistory(RegisterDatabaseIdentity(db.Database, NewDatabase("Physical", PostgresConfig{Schema: db.Namespace}, nil)), db.Family)
	if _, err := pgCompiledRowPhysicalPlan(owner, 2); err == nil || !strings.Contains(err.Error(), "sealed exact application") {
		t.Fatal("unsealed callback inventory did not reach its precise execution guard", err)
	}
	if _, err := pgCompiledRowPhysicalPlan(nil, 1); err == nil {
		t.Fatal("missing owner granted executable physical plan")
	}
}

func FuzzRowPhysicalCanonical(f *testing.F) {
	for _, version := range rowPhysicalSeed(f).Databases[0].Versions {
		raw, err := hex.DecodeString(version.Contract)
		if err != nil {
			f.Fatal(err)
		}
		f.Add(raw)
	}
	f.Add([]byte{})
	f.Add([]byte("l0:"))
	f.Fuzz(func(t *testing.T, raw []byte) {
		if len(raw) > 65536 {
			return
		}
		hash := fmt.Sprintf("%x", sha256.Sum256(raw))
		contract := hex.EncodeToString(raw)
		plan, err := pgParseRowPhysicalPlan(contract, hash)
		if err != nil {
			if plan != nil {
				t.Fatal("failed parse returned a partial plan")
			}
			return
		}
		if plan == nil || plan.compiled != nil || plan.contract != contract || plan.hash != hash {
			t.Fatal("structural parse invented authority or changed source identity")
		}
		document, _, err := pgReadRowCanonical(plan.contract)
		if err != nil || pgRowEncode(document) != string(raw) {
			t.Fatal("successful physical parse did not retain exact canonical bytes", err)
		}
	})
}

func TestRowPhysicalSettledObservationIsNotAuthority(t *testing.T) {
	seed := rowPhysicalSeed(t).Databases[0].Versions[0]
	if _, err := pgParseRowSettledPlan(seed.Contract, seed.Hash); err == nil {
		t.Fatal("retained document entered settled parser")
	}
	document, _, err := pgReadRowCanonical(seed.Contract)
	if err != nil {
		t.Fatal(err)
	}
	document.children[3].children[0] = pgRowAtom("tesl-settled-physical-version-v1")
	raw, hash := pgRowBaselineDocument(document.children[3])
	encoded := hex.EncodeToString([]byte(raw))
	observed, err := pgParseRowSettledPlan(encoded, hash)
	if err != nil || observed == nil || observed.compiled != nil {
		t.Fatal("settled description must remain observation", err)
	}
	if _, err := pgParseRowPhysicalPlan(encoded, hash); err == nil {
		t.Fatal("settled document entered retained parser")
	}
	if err := pgBindRowSettledPlan(nil, nil, observed); err == nil || observed.compiled != nil {
		t.Fatal("settled source description granted authority without checked history", err)
	}
}
