(** Logical field mapping for transforming entries over the exact inventory pair
    bound by sparse coverage. This judgment does not type or execute a row function,
    assign generations, authorize proof transport, or produce an executable plan. *)
type rule =
  | Rename of { previous : string; current : string; loc : Location.loc }
  | Default of Migration_additive.default
type mode = Derived | Migrate
type entry = { entity : string; mode : mode; rules : rule list; loc : Location.loc }
type value_source =
  | Copy of { previous : Migration_inventory.stored_field; current : Migration_inventory.stored_field }
  | Renamed of { previous : Migration_inventory.stored_field; current : Migration_inventory.stored_field }
  | Empty_optional of Migration_inventory.stored_field
  | Constant of Migration_inventory.stored_field * Migration_canonical.node
  | Computed of Migration_inventory.stored_field
type entity = {
  identity : string;
  previous : Migration_inventory.stored_entity;
  current : Migration_inventory.stored_entity;
  mode : mode;
  values : value_source list;
  indexes_changed : bool;
}
type t
val check : Migration_sparse.t -> entries:entry list ->
  (t, Migration_sparse.error list) result
val entities : t -> entity list
(** Preserve the exact checked inventories and Same evidence for subsequent
    row-function and physical-plan judgments. *)
val coverage : t -> Migration_sparse.t
