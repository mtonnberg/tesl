package teslrt

import (
	"encoding/hex"
	"encoding/json"
	"strconv"
	"strings"
	"testing"
	"unicode/utf8"
)

// Tests build and edit history documents with each contract as its
// hexadecimal canonical text. pgTestCompactHistory converts such a document
// to the linked wire form (a node table per database and node references);
// pgTestExpandHistory is its inverse for a decoded linked document.

// pgTestContractFields names, per document kind, where contracts occur in
// each database object: the array of records and the contract fields of each
// record (entities nest inside source versions).
var pgTestContractFields = map[string]struct {
	records string
	fields  []string
}{
	"compiled-migration-source-history":  {"versions", []string{"schemaContract", "storageContract"}},
	"compiled-row-transform-history":     {"transforms", []string{"transformContract"}},
	"compiled-retained-physical-history": {"versions", []string{"contract"}},
	"compiled-row-contract-history":      {"contracts", []string{"contract", "settled"}},
}

type pgTestNodeTable struct {
	entries []any
	index   map[string]int
}

func (table *pgTestNodeTable) intern(node pgRowCanonical) int {
	entry := make([]any, 0, len(node.children))
	for _, child := range node.children {
		switch {
		case !child.atom:
			entry = append(entry, table.intern(child))
		case utf8.ValidString(child.value):
			entry = append(entry, child.value)
		default:
			entry = append(entry, map[string]any{"hex": hex.EncodeToString([]byte(child.value))})
		}
	}
	key, err := json.Marshal(entry)
	if err != nil {
		panic(err)
	}
	if index, ok := table.index[string(key)]; ok {
		return index
	}
	table.index[string(key)] = len(table.entries)
	table.entries = append(table.entries, entry)
	return len(table.entries) - 1
}

// reference replaces a hexadecimal contract field with its node reference. A
// value that is not a canonical contract is left as it is, so the reader
// refuses it.
func (table *pgTestNodeTable) reference(record map[string]any, field string) {
	text, ok := record[field].(string)
	if !ok {
		return
	}
	node, _, err := pgReadRowCanonical(text)
	if err != nil || node.atom {
		return
	}
	record[field] = table.intern(node)
}

func pgTestCompactHistory(doc map[string]any) map[string]any {
	kind, _ := doc["kind"].(string)
	shape, ok := pgTestContractFields[kind]
	if !ok {
		return doc
	}
	if _, done := doc["contractEncoding"]; done {
		return doc
	}
	doc["contractEncoding"] = pgCanonicalNodesEncoding
	databases, _ := doc["databases"].([]any)
	for _, raw := range databases {
		database, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		table := &pgTestNodeTable{index: map[string]int{}}
		records, _ := database[shape.records].([]any)
		for _, raw := range records {
			record, ok := raw.(map[string]any)
			if !ok {
				continue
			}
			for _, field := range shape.fields {
				table.reference(record, field)
			}
			if kind == "compiled-migration-source-history" {
				entities, _ := record["entities"].([]any)
				for _, raw := range entities {
					if entity, ok := raw.(map[string]any); ok {
						table.reference(entity, "typeContract")
					}
				}
			}
		}
		database["canonicalNodes"] = append([]any{}, table.entries...)
	}
	return doc
}

// pgTestCompactHistoryJSON converts an encoded test document.
func pgTestCompactHistoryJSON(t testing.TB, payload string) string {
	t.Helper()
	doc := map[string]any{}
	if err := json.Unmarshal([]byte(payload), &doc); err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(pgTestCompactHistory(doc))
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

func pgTestExpandHistory(t testing.TB, doc map[string]any) map[string]any {
	t.Helper()
	kind, _ := doc["kind"].(string)
	shape, ok := pgTestContractFields[kind]
	if !ok {
		return doc
	}
	delete(doc, "contractEncoding")
	databases, _ := doc["databases"].([]any)
	for _, raw := range databases {
		database := raw.(map[string]any) //nolint:forcetypeassert // test document
		encoded, err := json.Marshal(database["canonicalNodes"])
		if err != nil {
			t.Fatal(err)
		}
		table, err := pgReadCanonicalNodes(string(encoded))
		if err != nil {
			t.Fatal(err)
		}
		delete(database, "canonicalNodes")
		expand := func(record map[string]any, field string) {
			index, ok := record[field].(float64)
			if !ok {
				return
			}
			text, err := table.hex(int(index))
			if err != nil {
				t.Fatal(err)
			}
			record[field] = text
		}
		records, _ := database[shape.records].([]any)
		for _, raw := range records {
			record := raw.(map[string]any) //nolint:forcetypeassert // test document
			for _, field := range shape.fields {
				expand(record, field)
			}
			if kind == "compiled-migration-source-history" {
				entities, _ := record["entities"].([]any)
				for _, raw := range entities {
					expand(raw.(map[string]any), "typeContract") //nolint:forcetypeassert // test document
				}
			}
		}
	}
	return doc
}

// pgTestExpandHistoryJSON decodes a linked document into its test form.
func pgTestExpandHistoryJSON(t testing.TB, payload string) map[string]any {
	t.Helper()
	doc := map[string]any{}
	if err := json.Unmarshal([]byte(payload), &doc); err != nil {
		t.Fatal(err)
	}
	return pgTestExpandHistory(t, doc)
}

func TestCanonicalNodesRoundTripExactContracts(t *testing.T) {
	atom, list := pgRowAtom, pgRowList
	shared := list(atom("field"), atom("id"), list(atom("none")))
	first, firstHash := rowTestDoc("snapshot", list(shared, atom("one"), atom("\xff\xfe")))
	second, secondHash := rowTestDoc("snapshot", list(shared, atom("two"), list()))
	doc := pgTestCompactHistory(map[string]any{"kind": "compiled-row-contract-history", "databases": []any{map[string]any{
		"contracts": []any{map[string]any{"contract": first, "hash": firstHash, "settled": second, "settledHash": secondHash}}}}})
	database := doc["databases"].([]any)[0].(map[string]any) //nolint:forcetypeassert // test document
	encoded, err := json.Marshal(database["canonicalNodes"])
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(encoded), `{"hex":"fffe"}`) || strings.Count(string(encoded), `"field"`) != 1 {
		t.Fatalf("table does not share nodes or encode non-UTF-8 atoms: %s", encoded)
	}
	table, err := pgReadCanonicalNodes(string(encoded))
	if err != nil {
		t.Fatal(err)
	}
	record := database["contracts"].([]any)[0].(map[string]any) //nolint:forcetypeassert // test document
	for field, want := range map[string]string{"contract": first, "settled": second} {
		got, err := table.hex(record[field].(int)) //nolint:forcetypeassert // test document
		if err != nil || got != want {
			t.Fatalf("%s did not rebuild its exact canonical bytes: %v", field, err)
		}
	}
}

func TestCanonicalNodesRefuseMalformedTables(t *testing.T) {
	for name, table := range map[string]string{
		"forward reference":     `[[1],["a"]]`,
		"self reference":        `[[0]]`,
		"negative reference":    `[["a"],[-1]]`,
		"fractional reference":  `[["a"],[0.0]]`,
		"padded reference":      `[["a"],[00]]`,
		"non-list node":         `["a"]`,
		"hex of UTF-8 atom":     `[[{"hex":"61"}]]`,
		"uppercase hex atom":    `[[{"hex":"FF"}]]`,
		"extra hex field":       `[[{"hex":"ff","x":1}]]`,
		"boolean child":         `[[true]]`,
		"unpaired surrogate":    `[["\ud800"]]`,
		"duplicate object keys": `[[{"hex":"ff","hex":"fe"}]]`,
	} {
		if _, err := pgReadCanonicalNodes(table); err == nil {
			t.Errorf("%s: accepted %s", name, table)
		}
	}
	table, err := pgReadCanonicalNodes(`[["a"],[0,0]]`)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := table.hex(2); err == nil {
		t.Fatal("missing node resolved")
	}
	text, err := table.hex(1)
	if err != nil || text != hex.EncodeToString([]byte("l2:l1:s1:al1:s1:a")) {
		t.Fatalf("shared child expanded wrongly: %q %v", text, err)
	}
}

func TestCanonicalNodesBoundExpansion(t *testing.T) {
	// Each node doubles its predecessor: 64 references expand past any budget.
	entries := []string{`["aaaaaaaaaaaaaaaa"]`}
	for i := 1; i < 64; i++ {
		entries = append(entries, "["+strconv.Itoa(i-1)+","+strconv.Itoa(i-1)+"]")
	}
	table, err := pgReadCanonicalNodes("[" + strings.Join(entries, ",") + "]")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := table.hex(63); err == nil || !strings.Contains(err.Error(), "size budget") {
		t.Fatal("exponential expansion was not refused", err)
	}
}
