package teslrt

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"strconv"
	"unicode/utf8"
)

// Compiled history has a closed wire format. In particular, encoding/json's
// case-insensitive field matching and last-duplicate-wins behavior must not
// silently change what the compiler wrote. Object readers below require exact
// decoded keys; this pass additionally rejects duplicate keys and trailing data.
func pgMigrationCheckJSON(payload string) error {
	if !utf8.ValidString(payload) {
		return fmt.Errorf("migration history is not UTF-8")
	}
	if err := pgMigrationJSONUnicode(payload); err != nil {
		return err
	}
	d := json.NewDecoder(bytes.NewBufferString(payload))
	d.UseNumber()
	var walk func(int) error
	walk = func(depth int) error {
		if depth > 32 {
			return fmt.Errorf("migration history exceeds nesting limit")
		}
		token, err := d.Token()
		if err != nil {
			return err
		}
		switch token {
		case json.Delim('{'):
			seen := map[string]bool{}
			for d.More() {
				key, err := d.Token()
				if err != nil {
					return err
				}
				name, ok := key.(string)
				if !ok || seen[name] {
					return fmt.Errorf("migration history has duplicate or invalid object key")
				}
				seen[name] = true
				if err := walk(depth + 1); err != nil {
					return err
				}
			}
		case json.Delim('['):
			for d.More() {
				if err := walk(depth + 1); err != nil {
					return err
				}
			}
		default:
			return nil
		}
		_, err = d.Token()
		return err
	}
	if err := walk(0); err != nil {
		return err
	}
	if _, err := d.Token(); err != io.EOF {
		return fmt.Errorf("migration history has trailing data")
	}
	return nil
}

// encoding/json replaces an unpaired escaped surrogate with U+FFFD. Source
// identities cover exact Unicode scalar values, so lossy decoding must refuse.
// The JSON decoder separately checks syntax; escaped backslashes are skipped.
func pgMigrationJSONUnicode(payload string) error {
	for i := 0; i < len(payload); i++ {
		if payload[i] != '\\' {
			continue
		}
		i++
		if i >= len(payload) || payload[i] != 'u' {
			continue
		}
		if i+5 > len(payload) {
			return fmt.Errorf("truncated Unicode escape in migration history")
		}
		code, err := strconv.ParseUint(payload[i+1:i+5], 16, 16)
		if err != nil {
			return fmt.Errorf("invalid Unicode escape in migration history")
		}
		i += 4
		if code >= 0xdc00 && code <= 0xdfff {
			return fmt.Errorf("unpaired Unicode surrogate in migration history")
		}
		if code < 0xd800 || code > 0xdbff {
			continue
		}
		if i+7 > len(payload) || payload[i+1:i+3] != `\u` {
			return fmt.Errorf("unpaired Unicode surrogate in migration history")
		}
		low, err := strconv.ParseUint(payload[i+3:i+7], 16, 16)
		if err != nil || low < 0xdc00 || low > 0xdfff {
			return fmt.Errorf("unpaired Unicode surrogate in migration history")
		}
		i += 6
	}
	return nil
}

// Readers retain the first error, so callers cannot accidentally accept a zero
// value after a malformed or missing field. Even a nullable field must be present.
type pgMigrationWireReader struct{ err error }

func (r *pgMigrationWireReader) fail(message string) {
	if r.err == nil {
		r.err = fmt.Errorf("invalid compiled migration history: %s", message)
	}
}

func pgMigrationRead[T any](r *pgMigrationWireReader, raw json.RawMessage) (v T) {
	if r.err != nil {
		return v
	}
	if len(raw) == 0 || bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		r.fail("missing or null value")
	} else if err := json.Unmarshal(raw, &v); err != nil {
		r.err = fmt.Errorf("invalid compiled migration history: %w", err)
	}
	return v
}

func (r *pgMigrationWireReader) object(raw json.RawMessage, keys ...string) map[string]json.RawMessage {
	object := pgMigrationRead[map[string]json.RawMessage](r, raw)
	if len(object) != len(keys) {
		r.fail("unexpected object fields")
	}
	for _, key := range keys {
		if _, ok := object[key]; !ok {
			r.fail("missing field " + key)
		}
	}
	return object
}

func pgMigrationReadArray[T any](r *pgMigrationWireReader, raw json.RawMessage, read func(json.RawMessage) T) []T {
	values := pgMigrationRead[[]json.RawMessage](r, raw)
	result := make([]T, 0, len(values))
	for _, value := range values {
		if r.err != nil {
			break
		}
		result = append(result, read(value))
	}
	return result
}

func (r *pgMigrationWireReader) column(raw json.RawMessage) PgMigrationCatalogColumn {
	o := r.object(raw, "name", "type", "nullable", "primaryKey")
	return PgMigrationCatalogColumn{Name: pgMigrationRead[string](r, o["name"]), Type: pgMigrationRead[string](r, o["type"]),
		Nullable: pgMigrationRead[bool](r, o["nullable"]), PrimaryKey: pgMigrationRead[bool](r, o["primaryKey"])}
}

func (r *pgMigrationWireReader) index(raw json.RawMessage) PgMigrationCatalogIndex {
	o := r.object(raw, "name", "columns", "unique", "method", "nullsDistinct")
	index := PgMigrationCatalogIndex{Name: pgMigrationRead[string](r, o["name"]),
		Columns: pgMigrationRead[[]string](r, o["columns"]), Unique: pgMigrationRead[bool](r, o["unique"])}
	if pgMigrationRead[string](r, o["method"]) != "btree" || !pgMigrationRead[bool](r, o["nullsDistinct"]) {
		r.fail("unsupported index semantics")
	}
	return index
}

func (r *pgMigrationWireReader) constant(raw json.RawMessage) *PgMigrationCatalogConstant {
	fields := pgMigrationRead[map[string]json.RawMessage](r, raw)
	kind := pgMigrationRead[string](r, fields["kind"])
	if kind == "null" {
		r.object(raw, "kind")
		return nil
	}
	o := r.object(raw, "kind", "value")
	return &PgMigrationCatalogConstant{Kind: kind, Value: pgMigrationRead[string](r, o["value"])}
}

func (r *pgMigrationWireReader) risk(raw json.RawMessage) *string {
	if bytes.Equal(bytes.TrimSpace(raw), []byte("null")) {
		return nil
	}
	value := pgMigrationRead[string](r, raw)
	if value == "" {
		r.fail("empty index window risk")
	}
	return &value
}

func (r *pgMigrationWireReader) operation(raw json.RawMessage) PgMigrationExpansionOperation {
	fields := pgMigrationRead[map[string]json.RawMessage](r, raw)
	kind := pgMigrationRead[string](r, fields["kind"])
	op := PgMigrationExpansionOperation{Kind: kind, Table: pgMigrationRead[string](r, fields["table"])}
	switch kind {
	case "create-table":
		o := r.object(raw, "kind", "table", "columns", "indexes")
		op.Columns = pgMigrationReadArray(r, o["columns"], r.column)
		op.Indexes = pgMigrationReadArray(r, o["indexes"], r.index)
	case "add-column":
		o := r.object(raw, "kind", "table", "column", "default")
		column := r.column(o["column"])
		column.Default = r.constant(o["default"])
		op.Column = &column
	case "build-index-concurrently", "retain-index":
		flag := "requiresConcurrentBuilder"
		if kind == "retain-index" {
			flag = "requiresContract"
		}
		o := r.object(raw, "kind", "table", "index", "windowRisk", flag)
		index := r.index(o["index"])
		op.Index = &index
		op.WindowRisk = r.risk(o["windowRisk"])
		if !pgMigrationRead[bool](r, o[flag]) {
			r.fail("missing index execution requirement")
		}
	case "retain-table":
		r.object(raw, "kind", "table")
	default:
		r.fail("unknown expansion operation")
	}
	return op
}

func (r *pgMigrationWireReader) step(raw json.RawMessage) PgMigrationExpansionStep {
	o := r.object(raw, "version", "snapshotHash", "stepHash", "epochPreserving", "operations")
	return PgMigrationExpansionStep{Version: pgMigrationRead[int](r, o["version"]),
		SnapshotHash: pgMigrationRead[string](r, o["snapshotHash"]), StepHash: pgMigrationRead[string](r, o["stepHash"]),
		EpochPreserving: pgMigrationRead[bool](r, o["epochPreserving"]), Operations: pgMigrationReadArray(r, o["operations"], r.operation)}
}
