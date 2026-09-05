(** Non-mutating, guarded source edit proposals. These are editor/file operations,
    not database plans or evidence that the proposed sources type-check. *)
type document = { path : string; version : int }
type edit = {
  path : string;
  before : string option;
  after : string;
  document_version : int option;
}
type error = { path : string; message : string }
type t
(** Capture exact bytes in both the active Source_input view and on disk. Every
    input/output parent directory is guarded, as are explicit discovery directories.
    Open documents require unique signed 32-bit versions. Writes may only target
    canonical .tesl files inside the existing project. Nothing is written. *)
val create : project_root:string -> reads:string list -> directories:string list ->
  imports:(string * string) list ->
  documents:document list -> writes:(string * string) list -> (t, error list) result
val project_root : t -> string
val edits : t -> edit list
val overlays : t -> (string * string) list
(** Recheck the source view and open-document versions, including read-only
    dependencies. A new/closed document invalidates the captured document set.
    This check does not replace the separate disk precondition. *)
val verify_source : t -> documents:document list -> (unit, error list) result
val verify_disk : t -> (unit, error list) result
(** Stable version-1 JSON with separate source/disk hashes, hashed directory
    membership, exact replacement bytes (lowercase hex) and editor versions.
    Paths are UTF-8. Source bytes need not be. It grants no execution authority.
    This module does not decode/apply an untrusted manifest. *)
val to_json : t -> string
val digest : t -> string
