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
(** First words of the MIG001 refusal for an edited current target. *)
val changed_current_prefix : string
(** Current-target sources whose saved bytes differ from the seal recorded in the
    migration file: family, target revision and (module, path, recorded SHA-256).
    Read-only description of a refusal, not integrity evidence. *)
val changed_current_sources : file:string -> (string * int * (string * string * string) list) option
val verify_unchanged : checked -> (unit, Migration_sparse.error list) result
val seals : checked -> Migration_seal.t * Migration_seal.t
