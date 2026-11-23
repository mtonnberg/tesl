(** A conservative identity for the compiler build, its embedded Go runtime, and
    the active lifted stdlib source. It never substitutes a recorded old tag for
    current semantics. Different identities need not mean different behavior;
    compatibility across identities requires its own checked migration path. *)
type t
type error = {path:string;message:string}
val current : unit -> (t,error) result
val id : t -> string
(** The stored-value identity (`tesl-stored-value-v1:<hex>`) that seals,
    compiled histories and databases record. It is derived from [fingerprint],
    not from source bytes, so comment and formatting edits to the stdlib keep
    it; the v1 baseline identity is kept while the fingerprint equals the
    baseline (see [known_identities] in the implementation). Independent of
    unrelated build bytes; equality is not permission to switch a persisted
    processing ABI. *)
val stored_value_compatibility : t -> string
val valid_stored_value_compatibility : string -> bool
(** `tesl-stored-value-fingerprint-v2:<hex>`: the canonical semantics of every
    stdlib module written in Tesl (comments, formatting and tests excluded) plus
    the reviewed builtin behaviour revisions in Stored_value_revisions. *)
val fingerprint : t -> string
(** Per stdlib module (resource basename), the digest of its canonical form. *)
val stdlib_semantics : t -> (string * string) list
(** The v1 byte-derived identity of the same stdlib resources. *)
val legacy_stored_value_compatibility : t -> string
(** Canonical form of one stdlib module's source, exposed for tests. *)
val canonical_stdlib : name:string -> string -> string
val derive_fingerprint : stdlib_semantics:(string * string) list -> revisions:(string * int) list -> string
val derived_identity : string -> string
type known = {identity:string;known_fingerprint:string;stdlib:(string * string) list;builtins:(string * int) list}
val known_identities : known list
(** Human-readable differences between a recorded identity and this compiler,
    for MIG013 diagnostics. *)
val explain_difference : t -> recorded:string -> string list
(** The command that re-checks a sealed history under new semantics. *)
val reseal_command : string
(** Verify that mutable stdlib resources still have the same identity. This does
    not attest a database's processing ABI or authorize an ABI drift override. *)
val verify : t -> (unit,error) result
val source_inputs : t -> (string * string) list
(** Exact captured source bytes for a known lifted stdlib module. This accessor
    does not consult the current filesystem or grant source proof authority. *)
val lifted_source : t -> string -> (string * string) option

(** Run generation against the captured resource bytes and resolution, preserving
    the application's source overlay root. Changed resource guards refuse the
    result; even a temporary change followed by restoration cannot mix stdlib
    versions inside the callback. Callbacks and source scopes are serialized. *)
val with_snapshot : t -> (unit -> 'a) -> ('a,error) result
(** MIG013 text for a seal recorded under [recorded]: both identities, what
    changed, and the revalidation command. *)
val mismatch_message : recorded:string -> string
