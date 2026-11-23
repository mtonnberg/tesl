package teslrt

import (
	"encoding/json"
	"testing"
)

// Injected runtime tests edit contracts inside a generated history document.
// A database object keeps its contracts in its canonicalNodes table, and each
// contract field is a node index.

// testCanonicalHex returns the hexadecimal canonical bytes of one contract
// field of a decoded database object.
func testCanonicalHex(t *testing.T, database map[string]any, field any) string {
	t.Helper()
	raw, err := json.Marshal(database["canonicalNodes"])
	if err != nil {
		t.Fatal(err)
	}
	table, err := pgReadCanonicalNodes(string(raw))
	if err != nil {
		t.Fatal(err)
	}
	index, ok := field.(float64)
	if !ok {
		t.Fatal("contract field is not a node reference")
	}
	text, err := table.hex(int(index))
	if err != nil {
		t.Fatal(err)
	}
	return text
}

// testCanonicalAppend appends one complete canonical document to a decoded
// database object's table and returns the value for its contract field.
func testCanonicalAppend(database map[string]any, document pgRowCanonical) int {
	nodes, _ := database["canonicalNodes"].([]any)
	var add func(pgRowCanonical) int
	add = func(node pgRowCanonical) int {
		entry := []any{}
		for _, child := range node.children {
			if child.atom {
				entry = append(entry, child.value)
			} else {
				entry = append(entry, add(child))
			}
		}
		nodes = append(nodes, entry)
		return len(nodes) - 1
	}
	index := add(document)
	database["canonicalNodes"] = nodes
	return index
}
