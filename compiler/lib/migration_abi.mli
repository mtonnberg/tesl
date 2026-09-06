(** A conservative identity for the compiler build, its embedded Go runtime, and
    the active lifted stdlib source. It never substitutes a recorded old tag for
    current semantics. Different identities need not mean different behavior;
    compatibility across identities requires its own checked migration path. *)
type t
type error = {path:string;message:string}
val current : unit -> (t,error) result
val id : t -> string
(** Explicit compiler-owned stored-value semantics contract plus the active
    stdlib source digests. Independent of unrelated build bytes; equality is not
    permission to switch a persisted processing ABI. *)
val stored_value_compatibility : t -> string
val valid_stored_value_compatibility : string -> bool
(** Verify that mutable stdlib resources still have the same identity. This does
    not attest a database's processing ABI or authorize an ABI drift override. *)
val verify : t -> (unit,error) result
val source_inputs : t -> (string * string) list

(** Run generation against the captured resource bytes and resolution, preserving
    the application's source overlay root. Changed resource guards refuse the
    result; even a temporary change followed by restoration cannot mix stdlib
    versions inside the callback. Callbacks and source scopes are serialized. *)
val with_snapshot : t -> (unit -> 'a) -> ('a,error) result
