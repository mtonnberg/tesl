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
(** Read exact input bytes and compare each with its original source precondition.
    A build can pin these bytes while deriving output, then recheck source, disk,
    imports and directory guards after leaving the pinned scope. *)
val source_files : t -> ((string * string) list,error list) result
(** Union independent previews, preserving their original source/disk/import and
    directory preconditions. Different roots, document versions, preconditions or
    competing edits refuse. Equal operations are deduplicated deterministically.
    The combined proposed paths and current preconditions are checked; this does
    not apply edits, sequence dependent previews or re-capture changed inputs. *)
val combine : t -> t -> documents:document list -> (t,error list) result
(** The same checked union over a nonempty list. Verify the complete original
    preconditions once after merging; no intermediate snapshot is recaptured.
    This avoids repeatedly verifying an ever-growing discovery prefix. *)
val combine_many : t list -> documents:document list -> (t,error list) result
(** Incremental union of original guard observations. Adding a captured manifest
    deduplicates observations and refuses conflicts without recapturing inputs.
    The accumulator is not a manifest; finish verifies all current source, disk,
    import and directory preconditions before publishing the union. *)
type accumulator
val start_combine : t -> documents:document list -> (accumulator,error list) result
val add_to_combine : accumulator -> t -> (accumulator,error list) result
val finish_combine : accumulator -> (t,error list) result
(** Stable version-1 JSON with separate source/disk hashes, hashed directory
    membership, exact replacement bytes (lowercase hex) and editor versions.
    Paths are UTF-8. Source bytes need not be. It grants no execution authority.
    This module does not decode/apply an untrusted manifest. *)
val to_json : t -> string
val digest : t -> string
