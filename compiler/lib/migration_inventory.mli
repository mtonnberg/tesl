(** A complete, checked schema inventory loaded from saved source files.
    No caller-supplied declaration list can omit a private fact producer.
    This is semantic inventory construction, not history/adoption validation. *)
type t

type stored_field = {
  entity : string;
  name : string;
  loc : Location.loc;
  contract : Migration_canonical.node;
}

type field_change =
  | Added_field of stored_field
  | Removed_field of stored_field
  | Changed_field of { previous : stored_field; current : stored_field;
                       definition_changed : bool }

val load : compiler_abi:string -> root_file:string ->
  (t, Migration_ir.error) result

val module_names : t -> string list
val snapshot : t -> Migration_canonical.node
val closure : t -> (Migration_ir.namespace * string) list ->
  (Migration_canonical.node, Migration_ir.error) result

(** One location per declared entity field, including private entities. Contracts
    include the field's type/proof/storage annotation and the complete semantic
    closure of its dependencies. Plain records are reached through their stored
    occurrences; they do not create independent locations or generations. *)
val stored_fields : t -> stored_field list

(** Compare saved, checked inventories in one family and compiler ABI. Unchanged
    locations are folded out. [definition_changed=false] identifies a dependency
    change such as a codec, nested ADT or fact producer under unchanged field text.
    This is field impact, not a physical-catalog diff, compatibility proof, verified
    Same bridge, migration plan or permission to prune a decoder. *)
val field_changes : before:t -> after:t ->
  (field_change list, Migration_ir.error) result
