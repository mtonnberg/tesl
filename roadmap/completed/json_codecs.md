# JSON Codecs

## Goal

Explicit codec declarations — attached to types — that control how records and ADTs are serialized
to and from JSON. Inspired by [Elm's `elm/json`](https://package.elm-lang.org/packages/elm/json/latest/)
and [elm-codec](https://package.elm-lang.org/packages/miniBill/elm-codec/latest/).

## Core principles

1. **One codec per type** — declared just below the type definition, identified by type name.
2. **Separate encoder and decoder** — `toJson` (single encoder) and `fromJson` (always a list,
   even for one decoder; supports historical formats without variance).
3. **All fields must be mentioned** — use `omitFromJson` to explicitly exclude a field from output.
   This prevents silently omitting newly-added fields.
4. **Automatic application** — the registered codec is used everywhere that type is serialised
   (HTTP responses, JSONB entity fields) with no per-handler wiring.
5. **`with_codec`** for nested codecs (not `via`, which is reserved for GDP proofs).
6. **`via checkerFn`** in `fromJson` field lines generates a proof after decoding.

---

## Syntax

### Record codec

```tesl
record User {
  name:         String
  email:        String
  internalScore: Int
}

codec User {
  toJson {
    name          -> "name"          with_codec Json.string
    email         -> "email"         with_codec Json.string
    internalScore -> omitFromJson                      # explicitly excluded from output
  }
  fromJson [
    {                                                  # decoder (current format)
      name          <- "name"          with_codec Json.string
      email         <- "email"         with_codec Json.string
      internalScore <- "internalScore" with_codec Json.int
    }
  ]
}
```

### Historical / versioned decoders

```tesl
codec User {
  toJson {
    name          -> "name"  with_codec Json.string
    email         -> "email" with_codec Json.string
    internalScore -> omitFromJson
  }
  fromJson [
    {                                   # try current format first
      name          <- "name"  with_codec Json.string
      email         <- "email" with_codec Json.string
      internalScore <- "internalScore" with_codec Json.int
    },
    {                                   # fall back to legacy format
      name          <- "full_name"      with_codec Json.string
      email         <- "email_address"  with_codec Json.string
      internalScore <- default 0        # field didn't exist in old rows
    }
  ]
}
```

### Nested type codec

```tesl
codec Order {
  toJson {
    id      -> "id"      with_codec Json.string
    address -> "address" with_codec Address
  }
  fromJson [
    {
      id      <- "id"      with_codec Json.string
      address <- "address" with_codec Address
    }
  ]
}
```

`with_codec Address` uses the codec registered for the `Address` type.

### Proof generation via `via`

```tesl
codec Project {
  toJson {
    name -> "name" with_codec Json.string
  }
  fromJson [
    {
      name <- "name" with_codec Json.string via validateProjectName
    }
  ]
}
```

`via validateProjectName` applies the check function after decoding and stores the resulting
proof-annotated value.

---

## Built-in codec names (Tesl.Json)

Used in `with_codec`:
- `string`      — `String`
- `int`         — `Int`
- `bool`        — `Bool`
- `float`       — `Float`
- `posixMillis` — `PosixMillis`

---

## Field line syntax

### In `toJson { ... }`
- `fieldName -> "json-key" with_codec codecRef` — encode field as `json-key`
- `fieldName -> omitFromJson` — explicitly exclude from encoded output

### In a `fromJson` decoder block `{ ... }`
- `fieldName <- "json-key" with_codec codecRef` — decode from `json-key`
- `fieldName <- "json-key" with_codec codecRef via checkerFn` — decode + apply proof checker
- `fieldName <- default expr` — use `expr` when the key is absent (no JSON mapping)

---

## Scope

Medium. Implementation in phases:

### Phase 1 — Record codec ✅
1. Parse `codec TypeName { toJson { ... } fromJson [ { ... }, ... ] }` blocks
2. Emit encoder function, list of decoder functions, registry call
3. Support `with_codec primitiveOrTypeName` for fields
4. Support `omitFromJson`, `default expr`, and `via checkerFn`
5. `runtime-value->jsexpr` and `jsexpr->typed-value` check registry first

### Phase 2 — ADT codec
1. ADT codec blocks: `tagField`, `Variant "json_tag" { ... }`, flat layout
2. Emit ADT-aware encoder/decoder

### Phase 3 — Historical / oneOf
Phase 1 already implements this via the `fromJson` list (multiple decoder blocks tried in order).

---

## Relation to `add_support_for_historical_json_formats.md`

Historical format support is built into Phase 1 via the `fromJson` list.
