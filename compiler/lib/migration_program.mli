(** Checked history carried by a complete Go build. This is compile-time input
    to the pending boot/executor integration, never database authority. *)
type origin = {
  initial_version : int;
  steps : (Migration_expansion.step list, Migration_sparse.error list) result;
}
type database = {
  identity : string;
  family : string;
  namespace : string;
  current_version : int;
  origins : origin list;
}
type t
val databases : t -> database list
val compiler_abi : t -> string
(** Capture application/history guards before invoking compilation. The supplied
    entry bytes and active overlays are authoritative. Actual stdlib resources
    are pinned, then all guards are checked again before a result is released.
    A non-versioned or Memory-only application yields None without an ABI load. *)
val with_history : entry:Ast.module_form -> source:string ->
  (t option -> 'a) -> ('a, Migration_sparse.error list) result
(** The actual modules selected for emission must still own exactly the captured
    PostgreSQL histories. Missing metadata is a build error; runtime boot and DDL
    enforcement remain separate obligations. *)
val verify_bindings : t option -> Ast.module_form list ->
  (unit, Migration_sparse.error list) result
val to_json : quote:(string -> string) -> t -> string
