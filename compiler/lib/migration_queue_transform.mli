(** Sealed source evidence for a same-identity queue payload conversion.
    This is not installed decoder, claim, repair or retirement authority.
    The scoped public consecutive queue-only protocol separately consumes and verifies
    the complete descriptor against the installed application. *)
type t
type policy = Convert | Rejected | Execution_failed | Discard
val policy : t -> policy
type request = { queue : string; job : string; callback : Ast.expr; fixtures : Ast.expr list }
val check_many : project_root:string -> before:Migration_inventory.t -> after:Migration_inventory.t ->
  version:int -> source:string -> Ast.module_form -> requests:request list ->
  (t list,Migration_sparse.error list) result
val check : project_root:string -> before:Migration_inventory.t -> after:Migration_inventory.t ->
  version:int -> queue:string -> job:string -> source:string -> Ast.module_form ->
  callback:Ast.expr -> fixtures:Ast.expr list -> (t,Migration_sparse.error list) result
val semantic : t -> Migration_canonical.node
val digest : t -> string
val callback : t -> Migration_transform.function_binding
val fixtures : t -> Migration_transform.function_binding list
val root : t -> Ast.module_form
val source_texts : t -> (Ast.module_form * string) list
val payload_names : t -> string * string
val with_checked : t -> (unit -> 'a) -> ('a,Migration_sparse.error list) result
(* Internal source boundary: a new immutable callback retries the original
   historical type against the same target. No durable repair authority. *)
val check_repair : ?policy:policy -> ?discard_reason:string -> rejected:t -> revision:int -> t -> (t,Migration_sparse.error list) result
val repair_revision : t -> int
val lineage : t -> t list
val queue_job : t -> string * string
val check_repair_source : ?policy:policy -> project_root:string -> contextual_declarations:(Ast.module_form * string * Ast.const_form) list -> rejected:t -> revision:int -> source:string -> Ast.module_form ->
  callback:Ast.expr -> fixtures:Ast.expr list -> (t,Migration_sparse.error list) result
val check_discard_source : project_root:string -> contextual_declarations:(Ast.module_form * string * Ast.const_form) list -> rejected:t -> revision:int -> reason:string -> source:string -> Ast.module_form -> (t,Migration_sparse.error list) result
