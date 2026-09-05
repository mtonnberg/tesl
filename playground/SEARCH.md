# Builtin discovery

Open **Search builtins** or press Ctrl/Cmd + K. Search a name (`String.length`),
description (`leading whitespace`), module (`Tesl.HttpClient`), diagnostic code
(`V001`) or type (`String -> Int`). Arrow keys browse results; Tab reaches actions;
Escape closes the dialog. Examples open in another tab, preserving the editor.

The same builtin search is available without a browser:

```sh
tesl search 'String -> Int'
tesl search --json 'Dict k v -> List k'
tesl --search-json 'String.length :: String -> Int'
tesl --catalog-json
```

The Go MCP server exposes `tesl.search` with `{ "query": "String -> Int" }`.
Diagnostic-code lookup in the playground uses `teslExplain`; native/MCP search
itself searches **builtins only**. Existing `tesl help search` remains the full-text
manual search. The legacy Racket MCP implementation does not gain new tools.

## Query contract, version 1

Text searches are case-insensitive, with deterministic ranking: exact name,
alias, generated family member, name prefix, unqualified name prefix, exact
module, all words in names/module, all words including description. When no
direct results exist, the existing builtin typo suggestions are used. Ties sort
by stable ID. Aliases point to the same entry; generated families stay aggregated.

Types are **exact structural shapes up to consistent generic renaming**. They
are not approximate unification, coercion or an assertion that a call will work.

```text
query       = text | type-with-arrow | [text] "::" type
type        = application ["->" type]       # right-associative
application = atom {atom}                   # left-associative
atom        = identifier | "(" type ")"
```

Uppercase-leading identifiers name nominal types; lowercase-leading identifiers
are generic variables. `Dict k v -> List k` preserves the relationship between
the key and the result. It does not match `Dict k v -> List v`. `Int32` differs
from `Int`; `a -> a` does not specialize to `Int -> Int`. Argument order and
arity are preserved. Higher-order functions use parentheses. A bare type/value
query uses `:: Set a`. There are no wildcard, proof, label or capability-filter
operators; unsupported type syntax returns a structured error. Zero-argument
function schemes retain the checker's `Unit` domain; the display signature and
parameter labels identify the actual zero-argument call.

Queries are limited to 256 UTF-8 bytes, type queries to 96 tokens and 24 recursive
levels. Responses return at most 20 entries, plus a total count. Narrow a large
set by name/module/description or combine a name with a type using `::`.

## Compiler-owned catalog

[`Builtin_search`](../compiler/lib/builtin_search.ml) uses the existing
`Stdlib_docs` catalog and real `Type_system.scheme` values. Both the native CLI
and the lazy js_of_ocaml artifact execute this one implementation. No browser
signature parser, generated prose or separately maintained type index is involved.

The version-1 response includes `catalog_id`, `scope`, `query`, `mode`, nullable
`error`, `total`, `limit` and ordered `results`. The catalog export carries the
same identity and every entry. Each entry includes:

| Field | Meaning |
|---|---|
| `id` | Stable module/name/kind identifier |
| `name`, `module`, `kind`, `aliases`, `doc` | Official documentation catalog fields |
| `signature` | Checker-rendered signature, or the catalog's explicitly labeled syntax sketch |
| `import` | Import text when a recipe is available; null otherwise |
| `parameter_labels` | Original names in argument order; null when unsupported |
| `type` | Recursive `con`, `var`, `app`, `fun` nodes from the actual scheme; null for prose-shaped entries |
| `quantified_variables` | First-occurrence variable IDs quantified by the checker scheme |
| `structural_status` | `checker-scheme`, `text-only`, or `incomplete-scheme` when checker quantification metadata is incomplete |
| `requirements.capabilities` | Known direct builtin capabilities from the compiler table |
| `requirements.capabilities_status` | `known-direct` or `unavailable`; neither claims complete callback requirements |
| `requirements.proofs_status`, `additional_requirements_status` | Explicitly `unavailable` in v1; never infer absence of requirements |

Only functions/values with real structured schemes enter type matching, and free
unquantified inference variables cannot masquerade as generics. Prose-shaped
special forms such as `List.map` remain findable by name and description. Proof
predicates and minted facts are visible where the existing prose names them;
they are not yet a structured proof index. **Check an actual use with the compiler.**

The first audit also found checker schemes whose quantified-variable list omits
variables appearing in their type (for example `Dict.map` omits the key variable).
Search exposes the actual type and quantification as `incomplete-scheme` and keeps
these entries in text lookup. It does not silently repair compiler metadata or
invent a polymorphic type. Their compiler-table audit is tracked separately.

`catalog_id` fingerprints the complete canonical catalog, including signatures,
types, quantified variables, aliases, docs, labels and requirements. Its MD5
digest is a content/version identity, not a security primitive. Delivery uses
SHA-256 Subresource Integrity for the checker, search code and example data.

## Source links, examples and delivery

The search UI stores query text in memory. Only **Copy search link** writes it
into the copied URL's `?q=` parameter. Existing query parameters and the source
fragment are preserved. That fragment may represent an earlier edit: use the
editor's **Copy share link** first when you want to share the latest source.
URL queries may appear in hosting access logs when a shared link is opened.

[`share.js`](share.js) keeps the historical compressed `#z…` and uncompressed
`#s…` source formats, `.L…` selections and `.H…` highlights. No new fragment router
or automatic URL/storage persistence is introduced.

[`search-examples.json`](search-examples.json) maps selected symbols to maintained
Tesl examples. The build runs each complete source through native `agent-context`
and browser `teslCheck`, rejects errors/unproven obligations, and records its
SHA-256. It links the complete source in a new tab. This verifies compilation,
not browser execution; the separate content workflow runs the title example's
runtime tests. The initial slice covers three examples and selected symbols;
other results link to the lesson index.

`playground-build.js` identifies source commit/local changes, catalog and the
three hashed compiler/data assets. Failed integrity checks or mismatched catalog
versions produce a retryable error while retaining the editor. The catalog/search
bundle and examples load only when a query needs them. The full embedded manual
is never linked into either browser artifact.

Source-containing links are immutable **source text**, checked by the current
deployment. They do not pin an archived compiler. Retaining and selecting
historical checker deployments is a separate release/hosting requirement; do
not call these links reproducible historical builds.

## Verification

```sh
nix develop --command bash -c 'cd compiler && dune runtest'
nix develop --command playground/build.sh
nix develop --command scripts/playground-parity.sh --dist playground/dist
nix shell --inputs-from . nixpkgs#playwright-test nixpkgs#playwright-driver.browsers \
  --command playwright test --config e2e/playground/playwright.config.cjs
```

The versioned [20-query relevance set](../compiler/test/search-queries.tsv), native
boundary tests and Node parity suite cover ordered results, full catalog metadata,
nominal/generic distinctions, malformed syntax, missing requirements and legacy
Go-output aliases. The existing lesson diagnostic parity check remains intact.
Chromium covers lazy loading, keyboard use, 375px dark layout, actual example
checking, sharing, copy-import, undo, simulated composition, stale responses,
load/mismatch recovery, fixes and client-code tabs. It records cold load, warm
query time, CPU-throttled time and asset bytes separately. Actual mobile IMEs,
screen-reader use and a representative device/network sample still need manual
validation. Deployment runs the native/browser parity and Chromium gates.

The optional [Elm screen and decision](elm-spike/DECISION.md) is excluded from
ordinary builds and deployment.
