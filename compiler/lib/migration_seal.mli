(** Snapshot source seals are committed integrity metadata. They describe the
    complete checked owned closure, including private modules, separately from
    the semantic snapshot and its compiler/compatibility domain. Editing this metadata together with its
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
val stored_value_compatibility : t -> string option
val snapshot_digest : t -> string
val sources : t -> (string * string) list

(** Versioned comment block. Its ordered entries are schema module names and raw
    SHA-256 byte digests; creator ABI bytes are hex-encoded. V1 is same-ABI-only;
    v2 also records the explicit stored-value compatibility contract. Writers use LF; readers also
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

(** Recheck source integrity, then fully check source under the actual executing
    compiler. V1 requires the recorded creator ABI, even when a compatibility
    argument is supplied. V2 requires its matching explicit compatibility
    contract and preserves the creator ABI as provenance. A missing contract
    cannot borrow one from the seal. Callers supply their actual ABI/contract;
    the returned inventory never grants processing or database admission authority. *)
val verify_semantics : ?stored_value_compatibility:string -> compiler_abi:string ->
  source_check -> (Migration_inventory.t,error) result
