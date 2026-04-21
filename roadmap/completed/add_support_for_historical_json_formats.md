# Historical JSON Format Support

## Goal

Allow reading JSONB data stored in older formats without a data migration. The canonical use case: you add a field to a record type and store it in a PostgreSQL JSONB column; old rows don't have that field, new rows do. You want one codec that handles both.

## Motivation

When ADTs or records are stored as JSONB in PostgreSQL, schema changes accumulate:
- Field renamed (`email_address` → `email`)
- Field added (`internalScore` didn't exist in early rows)
- Tag naming changed (`Succeeded` → `succeeded` in a case-sensitive migration)

Today Tesl has no way to handle this gracefully — a decoder that expects `internalScore` will fail on rows that predate that field.

## Design

See `json_codecs.md` for the full codec design. This file describes the historical-format-specific parts.

### Multiple decoders with `oneOf`

```tesl
codec UserJsonV2 for User {
  email         "email"
  displayName   "displayName"
  internalScore "internalScore"
}

codec UserJsonV1 for User {
  email         "email_address"    # old key name
  displayName   "full_name"        # old key name
  internalScore default 0          # field did not exist; default to 0
}

# Combined codec: always encodes as V2, decodes from V2 or falls back to V1
codec UserDbCodec for User {
  encode UserJsonV2
  decode oneOf [UserJsonV2, UserJsonV1]
}
```

### On entity fields

```tesl
entity Task table "tasks" primaryKey id {
  id:     String
  result: TaskResult codec ResultCodecV2 fallback [ResultCodecV1]
}
```

The `fallback` list is tried in order when the primary codec's decode fails.

### Invariants

- There is always exactly one **encoder** — the primary (or `encode` reference). No ambiguity in what gets written.
- There can be any number of **decoders** — tried in order, first success wins.
- `internalScore default 0` means: if the field is absent in the JSON, use `0`; never emit an error for a missing optional field.

## Relation to `json_codecs.md`

This feature is Phase 3 of the codec roadmap. Phase 1 (field aliasing) and Phase 2 (ADT codec) must be implemented first.
