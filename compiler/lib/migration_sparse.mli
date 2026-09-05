(** Coverage checking for sparse migration records. This establishes which owned
    entities need entries and which stored occurrences need explicit Same pairs.
    It does not elaborate row functions/rules, classify online safety, establish
    adjacent versions or persisted history, authorize DDL, or grant proof casts. *)
type identity = {
  previous : Migration_ir.namespace * string;
  current : Migration_ir.namespace * string;
  loc : Location.loc;
}
type entry_kind = Additive | Transform | New | Drop | Reset
type entry = { entity : string; kind : entry_kind; loc : Location.loc }
type error = {
  code : string;
  loc : Location.loc;
  message : string;
  related : (Location.loc * string) list;
}
type missing_identity = {
  previous_field : Migration_inventory.stored_field;
  current_field : Migration_inventory.stored_field;
  previous_declaration : Migration_inventory.declaration;
  current_declaration : Migration_inventory.declaration;
}
type entity =
  | Added of Migration_inventory.stored_entity
  | Removed of Migration_inventory.stored_entity
  | Paired of {
      previous : Migration_inventory.stored_entity;
      current : Migration_inventory.stored_entity;
      contract_changed : bool;
      missing_identities : missing_identity list;
    }
type t
(** Every identity is freshly verified against these inventories. Duplicate
    identities and entity aliases are refused. Entry names may be unique short
    names, revision-relative owning paths, or actual fully qualified old/new entity
    names. Transform/Reset only satisfies coverage; the function/offline reason
    still requires its contextual check before execution. *)
val check : before:Migration_inventory.t -> after:Migration_inventory.t ->
  identities:identity list -> entries:entry list -> loc:Location.loc ->
  (t, error list) result
(** Complete deterministic inventory and explicitly supplied verified identities.
    Every stored occurrence retains its own missing evidence. *)
val entities : t -> entity list
val identities : t -> Migration_inventory.same list
val unchanged_count : t -> int
(** Exact checked input inventories and normalized entry identities for subsequent
    rule elaboration. The row-rule checker must use these, not a different pair of
    snapshots paired with stale coverage evidence. *)
val inventories : t -> Migration_inventory.t * Migration_inventory.t
val entries : t -> (string * entry_kind) list
