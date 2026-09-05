(** Snapshot source seals are committed integrity metadata. They describe the
    complete checked owned closure, including private modules, separately from
    the compiler-bound semantic snapshot. Editing this metadata together with its
    sources can change both: persisted database history must supply the independent
    boot/execution backstop. Nothing here authorizes DDL or proof transport. *)
type t
type error_kind = Invalid_record | Invalid_layout | Missing_source | Changed_source
  | Invalid_schema | Abi_mismatch | Semantic_mismatch
type error = {kind : error_kind; loc : Location.loc; message : string}

(** Capture only an already checked inventory whose sources still match its
    preconditions and canonical layout. Reads the active Source_input view. *)
val create : project_root:string -> Migration_inventory.t -> (t,error) result
val root_module : t -> string
val compiler_abi : t -> string
val snapshot_digest : t -> string
val sources : t -> (string * string) list

(** Versioned comment block. Its ordered entries are schema module names and raw
    SHA-256 byte digests; ABI bytes are hex-encoded. Writers use LF; readers also
    accept CRLF. Decode validates structure, not source/semantic integrity. Source
    token rewriting does not rewrite comment metadata: a generator must replace
    the seal using the checked frozen inventory when finalizing a target. *)
val encode : t -> string
val decode : string -> (t,error) result

type source_check
(** Check exact source bytes, canonical regular paths, complete owned import
    closure and import resolution. Does not interpret an old compiler's semantics.
    This judgment is available after an ABI change without relabelling current
    semantics as the recorded ABI. *)
val verify_sources : project_root:string -> t -> (source_check,error) result
val source_inputs : source_check -> (string * string) list

(** Recheck source integrity, require the actual executing compiler ABI to equal
    the recorded one, then run the full inventory judgment and compare semantics.
    Passing an old ABI string never runs old semantics; callers must supply their
    real ABI. Cross-ABI recovery and persisted-proof revalidation are separate
    production judgments. The returned inventory grants no execution authority. *)
val verify_semantics : compiler_abi:string -> source_check -> (Migration_inventory.t,error) result
