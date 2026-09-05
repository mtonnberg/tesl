(** Source-view discovery for a database's schema family. This collects complete
    checked schema inventories and consecutive migration source files; it does
    not elaborate Migration records, verify frozen hash headers, permit pruning,
    establish Same, or authorize a database transition. *)
type schema = {
  version : int;
  root_file : string;
  inventory : Migration_inventory.t;
}

type migration_source = {
  version : int;
  path : string;
  contents : string;
  source_digest : string;
}

(** Internal discovery failures, not public migration diagnostics. In particular,
    a type error is not evidence of an edited frozen hash (MIG013). *)
type error_kind = Missing_source | Invalid_layout | Invalid_source | Changed_source
type error = { kind : error_kind; loc : Location.loc; message : string }
type t

(** VCurrent is one beyond the highest frozen revision, or V1 for a new family.
    Until evidence-backed pruning exists, frozen revisions must start at V1 and
    be consecutive. An absent current migration is returned as None so the
    generator can create it; absent intermediate migrations are errors.
    All paths are canonical regular files within [project_root]. Migration roots
    and their transitive helpers are parsed and checked for schema-only ownership
    and pure declarations; their types and Migration records still need elaboration.
    Reads saved files by default or the active Source_input overlay, including
    proposed revision roots and private dependencies. No writes. A preview's
    inventories and input guards do not establish persisted history. *)
val discover : compiler_abi:string -> project_root:string -> family:string ->
  (t, error) result

val current : t -> schema
val frozen : t -> schema list
val completed_migrations : t -> migration_source list
val current_migration : t -> migration_source option

(** All source-byte preconditions, including private schema dependencies and
    migration modules. The caller must additionally guard file creations and
    directory membership when applying a generated multi-file manifest. *)
val source_inputs : t -> (string * string) list

(** Recheck source bytes, regular canonical paths, and revision-root membership
    before deriving a preview from this inventory. This is not an atomic apply
    lock and does not guard output paths or editor document versions. Guards are
    checked against the active source view; a preview that differs from disk will
    not verify after its overlay scope ends. *)
val verify_unchanged : t -> (unit, error) result


(** Complete checked schema chain, returning only the requested adjacent pair.
    Migration records are not parsed here: the contextual checker uses its given
    AST, including unsaved migration buffers. This does not validate migration
    sources, provide frozen-history evidence, or grant execution authority. *)
val adjacent_pair : compiler_abi:string -> project_root:string -> family:string ->
  previous:string -> current:string -> (schema * schema, error) result
