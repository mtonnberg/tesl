(** Raw integrity metadata for the complete source closure of a frozen migration.
    Root bytes include schema seals and exclude only their own closure block.
    Helper bytes are exact. No entry grants proof transport or execution authority. *)
type t
type located
val read : file:string -> string -> (located option, Migration_sparse.error list) result
val root : located -> string
val sources : located -> (string * string) list
val mentions_file : project_root:string -> file:string -> located -> bool
val capture : project_root:string -> root_file:string -> source:string ->
  (t, Migration_sparse.error list) result
val attach : file:string -> source:string -> t -> (string, Migration_sparse.error list) result
val verify : project_root:string -> root_file:string -> source:string -> located ->
  (unit, Migration_sparse.error list) result
