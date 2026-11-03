(** A location-free semantic link for a checked transformation. This is not a
    generated callback, physical plan, generation assignment or runtime authority.
    Only Migration_transform.t supplies its checked source/evidence context. *)
type t
val link : Migration_transform.t -> (t, Migration_ir.error) result
(** Future emission consumes this exact binding from the link, never an
    independently supplied source descriptor paired with a hash. *)
val checked_transform : t -> Migration_transform.t
val semantic : t -> Migration_canonical.node
val digest : t -> string
val compiler_abi : t -> string
(** Checked source behavior under the stored-value compatibility contract. Keeps
    complete typed callback/fixture closures and Same judgments while separating
    build provenance. It cannot authorize execution under a persisted processing
    ABI; [semantic] retains the full ABI-bound identity. *)
val behavior : t -> Migration_canonical.node
val behavior_digest : t -> string
(** Mutable source/import resolution and compiler-resource preconditions are
    validity guards, deliberately excluded from the semantic node. *)
val source_inputs : t -> (string * string) list
val revalidate : t -> (unit, Migration_ir.error) result
