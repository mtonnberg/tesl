(** Logical row adapters for the initial additive subset. Input is the exact
    inventory pair bound into successful sparse coverage, not caller-asserted
    type names or hashes. These are NOT executable migrations, SQL defaults,
    physical catalog plans, online classifications or proof-cast authority. *)
type literal = Integer of string | Floating of float | Boolean of bool | Text of string
type default = {
  entity : string; (* normalized revision-relative identity from sparse coverage *)
  field : string;
  value : literal;
  loc : Location.loc;
}
type value_source =
  | Existing of { previous : Migration_inventory.stored_field; current : Migration_inventory.stored_field }
  | Empty_optional of Migration_inventory.stored_field
  | Constant of Migration_inventory.stored_field * Migration_canonical.node

type entity = {
  identity : string;
  previous : Migration_inventory.stored_entity;
  current : Migration_inventory.stored_entity;
  values : value_source list;
  indexes_changed : bool;
}
type t
val check : Migration_sparse.t -> defaults:default list ->
  (t, Migration_sparse.error list) result
val entities : t -> entity list
(** Plain primitive literals only in this initial subset. Nominal constructors,
    Money and proof-bearing defaults need additional contextual elaboration.
    PostgreSQL assignment/cast checks and index classification always follow this
    logical projection, even when every field has a value source. *)
