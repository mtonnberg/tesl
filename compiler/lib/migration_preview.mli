(** Source generation using the actual compiler context and complete application
    diagnostics. This is not a physical database plan and executes no operations. *)
type operation = Start | Refresh | Contract | Reseal
type t
type error = {loc:Location.loc;message:string;candidates:Migration_target.candidate list}
val generate : project_root:string -> entry_file:string -> database:string option ->
  new_revision:bool -> documents:Migration_manifest.document list -> (t,error list) result
val operation : t -> operation
val selection : t -> Migration_target.selection
val revision_after : t -> int
val compiler_abi : t -> string
val input_digest : t -> string
val manifest : t -> Migration_manifest.t
val diagnostics : t -> Compile.diagnostic list
val compilable : t -> bool
(** Recheck source, disk, documents and active compiler-resource ABI before use. *)
val verify : t -> documents:Migration_manifest.document list -> (unit,error list) result
val to_json : t -> string
val errors_to_json : error list -> string
val generate_choice : project_root:string -> entry_file:string -> database:string option ->
  documents:Migration_manifest.document list -> decision:string -> option_:string ->
  expected_input_digest:string -> (t,error list) result

(** Create one source Contract without overwriting existing authority. The complete
    proposed app is checked and the existing guarded writer applies this preview. *)
val generate_contract : project_root:string -> entry_file:string -> database:string option ->
 version:int -> documents:Migration_manifest.document list -> (t,error list) result

(** Re-record the stored-value identity of the selected family's seals after
    this compiler's stored-value semantics changed. Every recorded source byte
    must still match its seal; the complete history is re-checked under the
    proposed seals with trust disabled, and the preview is refused unless that
    check reports no error. Writes only seal headers, frozen-source blocks and
    checkpoints, through the same guarded manifest as other previews. *)
val generate_reseal : project_root:string -> entry_file:string -> database:string option ->
 documents:Migration_manifest.document list -> (t,error list) result
