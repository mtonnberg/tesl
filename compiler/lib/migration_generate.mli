(** Checked source generation, separate from physical migration planning. *)
type error = { path : string; message : string }
type preview = {
  family : string;
  frozen_version : int;
  current_version : int;
  manifest : Migration_manifest.t;
}
(** Start the next revision by freezing the entire current schema closure. If a
    current migration exists, preserve its code while retargeting it (and its
    unshared helpers) to the frozen schema, and recreate its target seal. All
    proposals receive normal compiler checks in a read-only source view.

    [version] is the explicitly selected current version; a changed selection
    refuses instead of silently starting another revision. The caller supplies
    the actual executing compiler ABI, not the old recorded
    tag. Finalizing an already recorded current target requires that same ABI.
    The generated next edge is initially unchanged; schema editing and refresh
    happen afterward. Target resolution, refresh, CLI/application and persisted
    migration semantics are separate integrations. No files are written. *)
val start : compiler_abi:string -> project_root:string -> family:string ->
  version:int ->
  documents:Migration_manifest.document list -> (preview, error list) result

type refresh_preview = {
  family : string;
  current_version : int;
  manifest : Migration_manifest.t;
  diagnostics : Compile.diagnostic list;
}
(** Refresh a selected, already sealed current migration after undeployed schema
    edits. Frozen history is verified before replacing the current target seal.
    Generated Same claims are rechecked; deliberate omissions are retained.
    New/Drop and proof-free additive adapters are generated where established by
    the checked inventories. Other required entries get compile-blocking todo
    decisions. User-owned entries, helpers and tests remain unchanged.

    The proposed view receives the full compiler check and its diagnostics are
    returned, including holes and stale handwritten entries. An error-bearing
    preview is not a compilable program. The compiler cannot infer deployment
    state; this source-only API provides no permission to change deployed history.
    No files are written. General row-function holes and transformations remain
    separate elaboration work. *)
val refresh : compiler_abi:string -> project_root:string -> family:string ->
  version:int -> documents:Migration_manifest.document list ->
  (refresh_preview,error list) result
