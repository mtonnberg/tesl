(** Immutable source-integrity discovery, separate from executable module inputs.
    Captures adjacent migration root inventories, recorded schema/closure members,
    and their local imports before the ordinary integrity judgment runs. *)
type t
val capture : project_root:string -> inputs:(string * string) list ->
  (t,Migration_sparse.error list) result
val revalidate : t -> (unit,Migration_sparse.error list) result
(** Pins the captured files, preserves discovered directory membership through the
    source overlay, and verifies the caller's source/disk view again on return. *)
val with_captured : t -> (unit -> 'a) -> ('a,Migration_sparse.error list) result
