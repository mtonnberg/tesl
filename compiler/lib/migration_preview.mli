(** Source generation using the actual compiler context and complete application
    diagnostics. This is not a physical database plan and executes no operations. *)
type operation = Start | Refresh
type t
type error = {loc:Location.loc;message:string;candidates:Migration_target.candidate list}
val generate : project_root:string -> entry_file:string -> database:string option ->
  new_revision:bool -> documents:Migration_manifest.document list -> (t,error list) result
val operation : t -> operation
val selection : t -> Migration_target.selection
val revision_after : t -> int
val compiler_abi : t -> string
val manifest : t -> Migration_manifest.t
val diagnostics : t -> Compile.diagnostic list
val compilable : t -> bool
(** Recheck source, disk, documents and active compiler-resource ABI before use. *)
val verify : t -> documents:Migration_manifest.document list -> (unit,error list) result
val to_json : t -> string
val errors_to_json : error list -> string
