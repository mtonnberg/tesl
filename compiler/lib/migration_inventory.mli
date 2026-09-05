(** A complete, checked schema inventory loaded from saved source files.
    No caller-supplied declaration list can omit a private fact producer.
    This is semantic inventory construction, not history/adoption validation. *)
type t

val load : compiler_abi:string -> root_file:string ->
  (t, Migration_ir.error) result

val module_names : t -> string list
val snapshot : t -> Migration_canonical.node
val closure : t -> (Migration_ir.namespace * string) list ->
  (Migration_canonical.node, Migration_ir.error) result
