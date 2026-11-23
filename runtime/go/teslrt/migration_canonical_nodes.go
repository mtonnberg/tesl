package teslrt

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strconv"
	"unicode/utf8"
)

// Compiled history documents carry their canonical contracts compactly. Each
// database object has one table of hash-consed canonical list nodes
// ("canonicalNodes"), and each contract field is the index of its root node.
// The contract is the exact canonical encoding of that node, so every digest
// is checked against the same bytes as before; the table only removes the
// repetition of schema and storage snapshots across revisions.
//
// A table is a JSON array of list nodes. A list node is a JSON array of its
// children in order: an integer is the index of an earlier list node, a string
// is an atom whose bytes are valid UTF-8, and {"hex":H} is an atom that is not
// valid UTF-8, as lowercase hexadecimal. The compiler writes each node once
// and each atom in its string form when it has one, so its tables are
// deterministic; readers need not check that, because every contract's bytes
// are digest-checked after expansion.
const pgCanonicalNodesEncoding = "tesl-canonical-nodes-v1"

// Expanded contracts stay within the size the hexadecimal contract text had.
const pgCanonicalNodesExpandLimit = pgRowSourceLimit / 2

type pgCanonicalNodeChild struct {
	node int // index of a list node, or -1 for an atom
	atom string
}

type pgCanonicalNodes struct {
	nodes [][]pgCanonicalNodeChild
	sizes []int // encoded byte length, capped above pgCanonicalNodesExpandLimit
}

// pgReadCanonicalNodes decodes one database's node table with the strict
// history JSON checks applied to its text.
func pgReadCanonicalNodes(raw string) (*pgCanonicalNodes, error) {
	fail := func(message string) (*pgCanonicalNodes, error) {
		return nil, fmt.Errorf("invalid compiled migration history: %s", message)
	}
	if err := pgMigrationCheckJSON(raw); err != nil {
		return nil, err
	}
	entries, err := pgJSONArray(raw)
	if err != nil {
		return nil, err
	}
	if len(entries) > 1_000_000 {
		return fail("canonical node table exceeds its budget")
	}
	table := &pgCanonicalNodes{nodes: make([][]pgCanonicalNodeChild, 0, len(entries)), sizes: make([]int, 0, len(entries))}
	for index, entry := range entries {
		elements, err := pgJSONArray(entry)
		if err != nil {
			return nil, err
		}
		children := make([]pgCanonicalNodeChild, 0, len(elements))
		size := 2 + len(strconv.Itoa(len(elements)))
		for _, element := range elements {
			var child pgCanonicalNodeChild
			switch element[0] {
			case '"':
				// The table text passed the strict checks above.
				value, err := pgJSONKey(element)
				if err != nil {
					return nil, err
				}
				child = pgCanonicalNodeChild{node: -1, atom: value}
			case '{':
				fields, err := pgJSONObject(element, "hex")
				if err != nil {
					return nil, err
				}
				text, err := pgJSONValue[string](fields["hex"])
				if err != nil {
					return nil, err
				}
				value, err := hex.DecodeString(text)
				if err != nil || hex.EncodeToString(value) != text || utf8.Valid(value) {
					return fail("canonical node atom requires its string form or lowercase hex of non-UTF-8 bytes")
				}
				child = pgCanonicalNodeChild{node: -1, atom: string(value)}
			default:
				reference, err := strconv.Atoi(element)
				if err != nil || reference < 0 || reference >= index || strconv.Itoa(reference) != element {
					return fail("canonical node must reference an earlier node")
				}
				child = pgCanonicalNodeChild{node: reference}
			}
			if child.node < 0 {
				size += 2 + len(strconv.Itoa(len(child.atom))) + len(child.atom)
			} else {
				size += table.sizes[child.node]
			}
			size = min(size, pgCanonicalNodesExpandLimit+1)
			children = append(children, child)
		}
		table.nodes = append(table.nodes, children)
		table.sizes = append(table.sizes, size)
	}
	return table, nil
}

// hex returns the lowercase hexadecimal canonical bytes of one root node: the
// text every contract reader parses and digests.
func (table *pgCanonicalNodes) hex(index int) (string, error) {
	if table == nil || index < 0 || index >= len(table.nodes) {
		return "", fmt.Errorf("invalid compiled migration history: canonical contract references a missing node")
	}
	if table.sizes[index] > pgCanonicalNodesExpandLimit {
		return "", fmt.Errorf("invalid compiled migration history: canonical contract exceeds its size budget")
	}
	out := make([]byte, 0, table.sizes[index])
	var encode func(int, int) bool
	encode = func(node, depth int) bool {
		if depth > 512 {
			return false
		}
		children := table.nodes[node]
		out = append(out, 'l')
		out = strconv.AppendInt(out, int64(len(children)), 10)
		out = append(out, ':')
		for _, child := range children {
			if child.node >= 0 {
				if !encode(child.node, depth+1) {
					return false
				}
				continue
			}
			out = append(out, 's')
			out = strconv.AppendInt(out, int64(len(child.atom)), 10)
			out = append(out, ':')
			out = append(out, child.atom...)
		}
		return true
	}
	if !encode(index, 0) {
		return "", fmt.Errorf("invalid compiled migration history: canonical contract exceeds its nesting budget")
	}
	return hex.EncodeToString(out), nil
}

// pgCanonicalReference resolves one contract field (a node index) to its
// hexadecimal canonical bytes.
func pgCanonicalReference(table *pgCanonicalNodes, raw string) (string, error) {
	index, err := pgJSONValue[int](raw)
	if err != nil {
		return "", err
	}
	return table.hex(index)
}

// pgCanonicalEncodingCheck refuses a document whose contracts are not encoded
// as canonical node tables.
func pgCanonicalEncodingCheck(raw string) error {
	encoding, err := pgJSONValue[string](raw)
	if err != nil {
		return err
	}
	if encoding != pgCanonicalNodesEncoding {
		return fmt.Errorf("invalid compiled migration history: unsupported contract encoding")
	}
	return nil
}

// canonicalNodes decodes the node table of the database object being read;
// later contract fields of that object resolve against it.
func (r *pgMigrationWireReader) canonicalNodes(raw json.RawMessage) *pgCanonicalNodes {
	if r.err != nil {
		return nil
	}
	table, err := pgReadCanonicalNodes(string(raw))
	if err != nil {
		r.err = err
		return nil
	}
	r.nodes = table
	return table
}

// contract reads one contract field against the current node table.
func (r *pgMigrationWireReader) contract(raw json.RawMessage) string {
	index := pgMigrationRead[int](r, raw)
	if r.err != nil {
		return ""
	}
	text, err := r.nodes.hex(index)
	if err != nil {
		r.err = err
	}
	return text
}

// contractEncoding checks a document's contract encoding field.
func (r *pgMigrationWireReader) contractEncoding(raw json.RawMessage) {
	if r.err != nil {
		return
	}
	if err := pgCanonicalEncodingCheck(string(raw)); err != nil {
		r.err = err
	}
}
