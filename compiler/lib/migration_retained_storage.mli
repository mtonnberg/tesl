(** Retained physical lineage from one complete checked row history. This describes
    expansion with no contracted columns/indexes removed. It grants no database,
    DDL, callback, admission or finality authority. Runtime catalog verification
    and source/ABI publication guards remain required. *)
type column = {
  name : string;
  scalar : Migration_storage.scalar;
  nullable : bool;
  primary_key : bool;
  default : Migration_expansion.default;
  introduced_version : int;
}
type field = { logical : Migration_storage.column; physical : column }
type reverse_write = { previous:string; current:string option; physical:column }
type entity = {
  source : Migration_row_history.entity;
  columns : column list;
  projection : field list;
  indexes : Migration_storage.index list;
  marker_default_generation : int;
  (** Current logical field -> every retained historical physical alias.
      These write obligations survive additive revisions and predecessor finality;
      subsequent renames compose them transitively until explicit contraction. *)
  rename_dual_writes : (string * column) list;
  (** A typed reverse constructor supplies these previous logical fields. These
      values are encoded by the previous codec, even for equal JSONB carriers. *)
  reverse_writes : reverse_write list;
}
type window = {
  binding : Migration_row_history.binding;
  before : entity;
  after : entity;
  (** The predecessor generation must be final before expanding this window.
      This is a prerequisite, never evidence that it has been satisfied. *)
  requires_final_generation : int;
  invalidation_columns : column list;
  (** Complete alias write obligations of [after], including earlier windows. *)
  rename_dual_writes : (string * column) list;
}
type version = {
 version : int; entities : entity list; windows : window list;
 (** A later transforming expansion uses the settled predecessor shape and
     requires the exact checked contract receipt for this earlier transformation.
     An intervening additive revision does not invent another contract. *)
 requires_contract_version : int option;
}
type t
val plan : Migration_row_history.t -> (t, Migration_sparse.error list) result
val history : t -> Migration_row_history.t
val versions : t -> version list
(** Resolves exactly the requested logical order; rejects omissions, duplicates,
    unknown fields, and owners outside the checked history. No SELECT order
    is inferred from canonical catalog order. *)
type projection
val project : t -> version:int -> entity:string -> logical_fields:string list ->
  (projection, Migration_sparse.error list) result
val projection_fields : projection -> field list
val projection_entity : projection -> entity

(** The physical shape after this revision's contract has completed. This pure
    description grants no finality, floor or DDL authority. A checked contract
    and verified durable lifecycle must authorize its selection. *)
val settled_version : t -> version:int -> (version, Migration_sparse.error list) result
