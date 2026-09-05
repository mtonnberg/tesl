(** Comment metadata for an adjacent migration edge. Source integrity is checked
    independently of semantic ABI compatibility and persisted database history. *)
type t
type located
type checked
val create : previous:Migration_seal.t -> current:Migration_seal.t ->
  (t, Migration_sparse.error list) result
val encode : t -> string
val read : file:string -> string -> (located option, Migration_sparse.error list) result
val roots : located -> string * string
(** Decoded metadata, with no source or semantic evidence. Refresh verifies the
    frozen predecessor independently before replacing a stale current target. *)
val recorded_seals : located -> Migration_seal.t * Migration_seal.t
val module_name : located -> string
val mentions_file : project_root:string -> file:string -> located -> bool
val replace : file:string -> source:string -> t -> (string, Migration_sparse.error list) result
val verify : project_root:string -> migration_module:string ->
  previous:string -> current:string -> located -> (checked, Migration_sparse.error list) result
val verify_unchanged : checked -> (unit, Migration_sparse.error list) result
val seals : checked -> Migration_seal.t * Migration_seal.t
