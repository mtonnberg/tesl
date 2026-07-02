# 03 — Module System, Import Graph, and SCC Detection

> Audience: contributors working on multi-module compilation in the compiler (`compiler/lib/`).

Tesl supports cyclic imports between modules. This guide explains how the
compiler handles multi-module compilation and mutually recursive modules.

---

## Module metadata

Every `.tesl` module (and every special built-in module) is represented as a
**metadata dict**. This dict is the central data structure throughout compilation.

```python
{
    "source_path":    pathlib.Path,     # absolute path to .tesl file
    "module_name":    str,              # e.g. "MyApp.Auth"
    "exports":        list[str],        # sorted list of exported names
    "exported_names": set[str],         # fast membership test
    "imports":        list[ImportDecl], # parsed import declarations
    "forms":          list[dict],       # parsed top-level forms
    "local_names":    set[str],         # names defined in this module
    "function_kinds": dict[str,str],    # name → "fn"|"check"|"auth"|...
    "function_decls": dict[str,FunctionDecl],
    "adt_constructors": dict[str, tuple[str,...]],
    "adt_variant_fields": dict[str, tuple[str,...]],
    "exported_adt_constructors": dict[str, set[str]],
    "proof_predicates": set[str],       # predicates this module owns
    "required_capabilities": dict[str,set[str]],
    "capability_names": set[str],
    "capability_implications": dict[str,set[str]],
    "is_special": bool,                 # True for stdlib modules
}
```

### Loading module metadata

```python
def load_module_metadata(source_path, cache) -> dict:
    # 1. Read and strip comments
    # 2. parse_module() → forms, imports
    # 3. collect_module_defined_names() → local_names, function_kinds
    # 4. collect_module_proof_predicates() → proof_predicates
    # 5. collect_module_adt_constructors/variant_fields()
    # 6. expand_local_export_names() → validate exports against local_names
    # 7. Build and return the metadata dict
```

Results are cached by path — a module parsed once is never re-parsed.

---

## Special (built-in) modules

Standard library modules like `Tesl.String`, `Tesl.Time`, `Tesl.Queue` are
**not** `.tesl` files — they are Racket files. Their metadata is hand-crafted
via `make_special_module_metadata`:

```python
def make_special_module_metadata(
    source_path: pathlib.Path,
    module_name: str,
    export_names: set[str],
    *,
    adt_constructors=None,
    adt_variant_fields=None,
    required_capabilities=None,
    capability_names=None,
    capability_implications=None,
) -> dict:
    return {
        "source_path": source_path,
        "module_name": module_name,
        "exports": sorted(export_names),
        "exported_names": set(export_names),
        "imports": [],
        "forms": [],
        "local_names": set(export_names),
        "function_kinds": {},
        "function_decls": {},
        ...
        "is_special": True,
    }
```

Special modules are identified by `special_module_metadata(module_name)` —
a lookup table mapping well-known module names to their hand-crafted metadata.

### Adding a new stdlib module (quick version)

1. Create `tesl/your-module.rkt` with `(define-newtype ...)`, `(define ...)`, `(provide ...)`
2. Add a constant: `YOUR_MODULE_NAME = "Tesl.YourModule"`
3. Add a metadata function:

```python
def your_module_metadata() -> dict:
    repo_root = pathlib.Path(__file__).resolve().parents[2]
    return make_special_module_metadata(
        repo_root / "tesl" / "your-module.rkt",
        YOUR_MODULE_NAME,
        {"YourFunc", "YourType"},
    )
```

4. Register it in `special_module_metadata()`:

```python
if module_name == YOUR_MODULE_NAME:
    return your_module_metadata()
```

See `dev-docs/05-adding-stdlib-function.md` for the full walkthrough.

---

## Import graph

`build_import_graph` constructs a directed graph of all modules reachable from
an entry module:

```python
def build_import_graph(
    source_path: pathlib.Path,
    metadata_cache: dict,
) -> dict[pathlib.Path, list[pathlib.Path]]:
    # Returns: { module_path → [dependency_path, ...] }
```

It does a BFS from the entry module. For each module, it:
1. Loads metadata (parse + cache)
2. Resolves each import to a path on disk
3. Adds edges to the graph
4. Recurses into not-yet-visited modules

Special modules never generate file edges — they are leaves in the graph.

### Import resolution

```python
def resolve_import_source_path(source_path, module_name) -> pathlib.Path:
    # Tries:
    # 1. source_dir / "Module" / "Name.tesl"   (exact)
    # 2. source_dir / "module" / "name.tesl"   (kebab-case)
```

Import paths are relative to the importing file. `import Tesl.Auth` in
`src/api.tesl` looks for `src/Tesl/Auth.tesl` or `src/tesl/auth.tesl`.

---

## SCC detection (Tarjan's algorithm)

Tesl allows cyclic imports (Module A imports Module B imports Module A). The
compiler handles this via **Strongly Connected Components** (SCCs).

```python
def tarjan_sccs(
    graph: dict[pathlib.Path, list[pathlib.Path]]
) -> list[list[pathlib.Path]]:
    # Returns SCCs in topological order (dependencies first, entry last)
    # Each SCC is a list of modules that must be compiled together
```

An iterative implementation of Tarjan's algorithm is used (not recursive,
to avoid Python stack overflow on deep graphs).

### What an SCC means

- **SCC of size 1**: Normal module. No cyclic dependency.
- **SCC of size > 1**: Mutually recursive modules. They are compiled together
  into a single `.rkt` file so they can reference each other.

---

## Compilation pipeline for multiple modules

```python
def compile_module(source_path) -> str:
    # 1. build_import_graph(source_path)    → directed graph
    # 2. tarjan_sccs(graph)                 → SCCs in topo order
    # 3. For each dependency SCC:
    #      _process_sccs() → write each to a temp .rkt file
    # 4. For the entry SCC:
    #      _gen_single_module_content() or _gen_scc_content()
    #    → return the Racket string
```

For non-entry modules, compiled `.rkt` files are written to a temp directory
(keyed by source hash) so they can be reused across incremental compilations.
The entry module's Racket is returned as a string (for `--check`, piping, etc.).

### Single-module generation (`_gen_single_module_content`)

```python
def _gen_single_module_content(source_path, metadata_cache, compiled_cache) -> str:
    module = metadata_cache[source_path]
    resolved_imports = resolve_imports(module, metadata_cache)
    # Validate references, proof ownership, etc.
    validate_module(module, resolved_imports)
    # Build compiler context
    compiler = BodyCompiler(...)
    # Emit all forms → list of Racket strings
    lines = emit_requires(module, compiled_cache)
    lines += emit_forms(module["forms"], compiler)
    return "\n".join(lines)
```

### SCC generation (`_gen_scc_content`)

For a cyclic group, all modules' `require` clauses are merged into one file
and all forms emitted together. Type name mangling handles name collisions
between modules in the same SCC.

---

## Proof predicate ownership

One of the cross-module validation rules is **proof predicate ownership**. Each
predicate (like `ValidPort`, `Authenticated`) is "owned" by exactly one module —
the module that declares it via an `establish`, `check`, or `auth` function.

```python
def validate_proof_predicate_ownership(module, resolved_imports):
    # For each predicate declared by this module:
    #   - Check no imported module already owns the same predicate name
    # This ensures predicates are greppable (their home module is unique)
```

If Module A and Module B both declare `check isValid(...)` with the same
predicate name `IsValid`, the import chain will fail. One must import the other.

---

## Debugging the module system

**Print the import graph:**
```bash
tesl --deps example/todo-api.tesl
```

That prints the transitive local `.tesl` dependencies, one path per line. It is the easiest way to see what `tesl watch` will treat as part of the local dependency set.

**Inspect local import cycles:**
Run `tesl --deps your-file.tesl` from one of the files in the cycle to see the transitive local dependency set. Cyclic imports are supported, so the goal here is not to detect an illegal cycle, but to understand which files participate in the strongly connected component and how names and proofs flow across that group. If something inside the cycle behaves incorrectly, also run `tesl --check your-file.tesl` on one of the involved files to surface ordinary parse, type, proof, or validation errors.
