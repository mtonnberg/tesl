(** Read-only source views for compiler queries and migration previews. An overlay
    supplies complete source bytes at an absolute, canonical .tesl path inside one
    existing project directory. Missing files and parent directories are visible
    only within the scope; nothing is created on disk. Symlinks, special files,
    duplicate inputs and conflicting file/directory paths are refused.

    Scopes compose within one project (inner bytes win), restore on exceptions,
    and invalidate semantic query caches on entry and exit. Like Query_cache,
    these scopes are process-local: a query host must serialize compiler queries.
    This is an input view, not a filesystem transaction, history seal or authority
    to execute migrations. Manifest application must separately guard disk bytes
    and editor versions. *)
val with_overlays : project_root:string -> (string * string) list -> (unit -> 'a) -> 'a
val project_root : unit -> string option
(** Resolve existing ancestors, also for a not-yet-created source path. This does
    not assert that a file exists, is regular, or belongs to the project. *)
val canonical_path : string -> string

val read : string -> string
val read_text : string -> string
val exists : string -> bool
val is_directory : string -> bool
val kind : string -> Unix.file_kind
val realpath : string -> string
val readdir : string -> string array

(** Pin already captured compiler resource bytes during a serialized query.
    These regular, canonical inputs may be outside the application project.
    They do not create directories or change the project root. The caller must
    pin module resolution too and recheck resources before publishing results.
    Nested snapshots and project edits may not change a pinned resource. *)
val with_pinned_files : (string * string) list -> (unit -> 'a) -> 'a
(** Observe the underlying source view when verifying mutable resource guards.
    Both operations restore on exceptions and invalidate semantic caches. *)
val without_pinned_files : (unit -> 'a) -> 'a
