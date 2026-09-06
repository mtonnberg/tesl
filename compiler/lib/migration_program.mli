(** Checked history carried by a complete Go build. This is compile-time input
    to the boot/executor's independent persisted-history checks, never database authority. *)
type origin = {
  initial_version : int;
  steps : (Migration_expansion.step list, Migration_sparse.error list) result;
}
type queue_payload = {job:string;contract:string;contract_hash:string}
type queue_contract = {queue:string;payloads:queue_payload list}
type queue_version = {version:int;storage_snapshot_hash:string;schema_snapshot_hash:string;
 source_seal_inventory:string;contracts:queue_contract list}
type queue_binding = {application_queue:string;database_identity:string;family:string;queue_identity:string;
 current_version:int;jobs:(string * string * string) list}
type database = {
  identity : string;
  family : string;
  namespace : string;
  current_version : int;
  origins : origin list;
  queue_versions : queue_version list;
}
type t
val databases : t -> database list
val compiler_abi : t -> string
val stored_value_compatibility : t -> string
(** Capture application/history guards before invoking compilation. The supplied
    entry bytes and active overlays are authoritative. Actual stdlib resources
    are pinned, then all guards are checked again before a result is released.
    A non-versioned or Memory-only application yields None without an ABI load. *)
val with_history : entry:Ast.module_form -> source:string ->
  (t option -> 'a) -> ('a, Migration_sparse.error list) result
(** The actual modules selected for emission must still own exactly the captured
    PostgreSQL histories. Missing metadata is a build error; runtime boot and DDL
    enforcement remain separate obligations. *)
val verify_bindings : t option -> Ast.module_form list ->
  (unit, Migration_sparse.error list) result
val to_json : quote:(string -> string) -> t -> string

(** Complete source inventory, including empty and unrecorded initial V1. This
    does not assert persisted baseline completeness or authorize queue claims. *)
val queues_to_json : quote:(string -> string) -> t -> string
val queue_bindings : t -> queue_binding list

val queue_codec_records : t -> string list
