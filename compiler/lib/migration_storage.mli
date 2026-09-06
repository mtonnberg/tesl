(** PostgreSQL storage descriptions from a complete checked schema inventory.
    This initial mapping is deliberately bounded; unsupported carriers and
    catalog-dependent types refuse rather than pretending to be additive.
    Descriptions are not catalog evidence, a migration plan or DDL authority. *)
type scalar = Numeric | Float8 | Text | Bool | Int4 | Int8 | Jsonb
val scalar_name : scalar -> string

type column = {
  field : Migration_inventory.stored_field;
  name : string;
  scalar : scalar;
  nullable : bool;
  primary_key : bool;
}
type index = {name:string;columns:string list;unique:bool}
type table = {
  entity : Migration_inventory.stored_entity;
  name : string;
  columns : column list;
  indexes : index list;
}
type t
val describe : Migration_inventory.t -> (t,Migration_sparse.error list) result
val inventory : t -> Migration_inventory.t
val tables : t -> table list
(** Stable description identity includes the complete semantic inventory and the
    storage mapping version, not just SQL column names. *)
val digest : t -> string
