(** Read-only PostgreSQL planning for complete checked source histories.
    Additive previews describe storage from the selected initial installation
    version. Transforming, entity-only histories expose a row-history preview
    from V1 with retained tables, generations, field mappings, runtime proof
    enforcement, codec observations and checked Contract source summaries.
    Neither form inspects a database, attests persisted receipts/finality, admits
    an application or authorizes execution, in-place rewrites or decoder pruning.
    Codec observations are not compatibility proofs; typed Retype/WriteBack and
    retained physical storage remain the conservative representation-change path.
    Existing-table indexes require concurrent building; narrowing a compatibility
    window requires the corresponding checked epoch/Contract lifecycle. *)
type default = Migration_expansion.default = Null | Constant of Migration_canonical.node
type operation = Migration_expansion.operation =
  | Create_table of Migration_storage.table
  | Add_column of {table:string;column:Migration_storage.column;default:default}
  | Build_index of {table:string;index:Migration_storage.index;window_risk:string option}
  | Retain_table of string
  | Retain_index of {table:string;index:Migration_storage.index;window_risk:string option}
type catalog_column = Migration_expansion.catalog_column = {column:Migration_storage.column;default:default}
type catalog_table = Migration_expansion.catalog_table = {name:string;columns:catalog_column list;indexes:Migration_storage.index list}
type step = Migration_expansion.step = {version:int;snapshot_hash:string;operations:operation list;epoch_preserving:bool;
             catalog:catalog_table list}
type t
val generate : project_root:string -> entry_file:string -> database:string option -> initial_version:int ->
  documents:Migration_manifest.document list -> (t,Migration_sparse.error list) result
val selection : t -> Migration_target.selection
(** Additive expansion steps. Retained-row previews expose their separate
    source-only table/transform/codec descriptions through [to_json]. *)
val steps : t -> step list
val digest : t -> string
val compiler_abi : t -> string
val verify : t -> documents:Migration_manifest.document list -> (unit,Migration_sparse.error list) result
val to_json : t -> string
val errors_to_json : Migration_sparse.error list -> string
