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
(** Identity of the active overlay and pinned resources (not of disk bytes). *)
type view_token
val view_token : unit -> view_token
val same_view : view_token -> bool
(** Run [f], declaring the current scope equivalent to the view [parent] was
    taken in: only for a scope entered to freeze bytes that view supplied (an
    overlay or pinned resources holding exactly the bytes read there). *)
val with_equivalent_view : view_token -> (unit -> 'a) -> 'a

(** A filesystem observation made through this module, with its answer. *)
type observation
(** Run [f] and return every observation it made through [read], [read_text],
    [exists], [kind], [realpath] and [readdir], with the answers it got. *)
val recording : (unit -> 'a) -> 'a * observation list
(** A judgment (taken under [token]) whose filesystem observations were
    exactly [observations] observes the same inputs now: each observation,
    repeated in the current view, gets the same answer (equal bytes for a
    read). *)
val same_reads : view_token -> observation list -> bool
(** Whether compiler resources are pinned in the current scope. *)
val has_pinned_files : unit -> bool

(** Run [f] computing each directory's canonical spelling at most once (see
    source_input.ml). For one bounded judgment; never around a final guard. *)
val with_path_memo : (unit -> 'a) -> 'a
(** Run [f] resolving canonical spellings with one fresh table, independent of
    any enclosing memo: for checks that must observe the filesystem anew. *)
val with_fresh_path_memo : (unit -> 'a) -> 'a
(** Run [f] with one canonical-spelling table per source view for the whole
    scope (one compilation). [with_fresh_path_memo] still observes anew. *)
val with_scope_path_memo : (unit -> 'a) -> 'a
(** Inside [with_scope_path_memo], disk answers (file bytes, lstat, directory
    listings, existence) are read from disk once and shared by every source view
    of the scope; [with_fresh_path_memo] observes disk anew. A command that
    publishes a result computed from them checks [disk_changed] first (its final
    guard) and, on a change, calls [reset_disk_memo] and computes again. *)
val disk_changed : unit -> bool
val reset_disk_memo : unit -> unit
