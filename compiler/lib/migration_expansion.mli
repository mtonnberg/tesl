(** Physical expansion over complete checked histories. Validates the entire
    chain before deriving storage from the selected first-installed revision.
    This does not discover sources, run Go emission or authorize execution. *)
type default = Null | Constant of Migration_canonical.node
type operation =
  | Create_table of Migration_storage.table
  | Add_column of {table:string;column:Migration_storage.column;default:default}
  | Build_index of {table:string;index:Migration_storage.index;window_risk:string option}
  | Retain_table of string
  | Retain_index of {table:string;index:Migration_storage.index;window_risk:string option}
type catalog_column = {column:Migration_storage.column;default:default}
type catalog_table = {name:string;columns:catalog_column list;indexes:Migration_storage.index list}
type step = {version:int;snapshot_hash:string;operations:operation list;epoch_preserving:bool;
             catalog:catalog_table list}
val generate : initial_version:int -> schemas:Migration_inventory.t list ->
  edges:Migration_declaration.t list -> (step list,Migration_sparse.error list) result
val step_node : step -> Migration_canonical.node
(** Identity of one physical step, independent of application connection naming,
    later revisions and report formatting. Domain: Migration; payload:
    Seq [Bytes "postgres-expansion-step-v1"; step_node step]. This is not authority
    to execute the step or accept its snapshot's persisted proofs. *)
val step_hash : step -> string

val step_to_json : ?include_catalog:bool -> quote:(string -> string) -> step -> string
