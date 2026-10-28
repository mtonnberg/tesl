(** Contextual source checking for Migration declarations. This binds sparse
    coverage, additive adapters, row mappings and queue conversion source evidence
    to exact adjacent schemas. Present headers receive source-integrity checks.
    An explicit compatibility contract verifies seal semantics under the caller
    ABI; ordinary diagnostics do not make that persisted execution judgment.
    Source evidence alone never grants persisted execution authority. Queue
    transformations remain refused by physical planning, including later origins,
    until their protected execution and repair protocol is complete. *)
type t
val check : ?stored_value_compatibility:string -> compiler_abi:string -> source:string -> Ast.module_form ->
  (t option, Migration_sparse.error list) result
val coverage : t -> Migration_sparse.t
val additive : t -> Migration_additive.t
val transforms : t -> Migration_transform.t option
val queue_transforms : t -> Migration_queue_transform.t list
val queue_removal : t -> string option
val queue_transition : t -> bool
val version : t -> int
val source_seals : t -> Migration_header.checked option
val diagnostics : string -> Ast.module_form -> Frontend_check.diagnostic list

val diagnostics_of_errors : Migration_sparse.error list -> Frontend_check.diagnostic list

(** Structural reading only, including contextual import availability, required
    fields and direct root imports. No source seals, inventories or row rules have
    been checked. AST members retain their original physical identities. *)
type syntax = {
  declaration : Ast.const_form;
  family : string;
  target : int;
  fields : (string * Ast.expr) list;
  previous_expr : Ast.expr;
  current_expr : Ast.expr;
  previous_root : string;
  current_root : string;
  same : Ast.expr;
  entities : Ast.expr;
}
val read_syntax : Ast.module_form -> (syntax option,Migration_sparse.error list) result
val identity_claims : before:Migration_inventory.t -> after:Migration_inventory.t ->
  syntax -> (Migration_sparse.identity list,Migration_sparse.error list) result

type prepared
val prepare : ?stored_value_compatibility:string -> compiler_abi:string -> source:string -> Ast.module_form ->
  (prepared option, Migration_sparse.error list) result
val with_prepared : prepared -> (unit -> 'a) -> ('a,Migration_sparse.error list) result
val check_prepared : prepared -> (t,Migration_sparse.error list) result

val with_source_context : source:string -> Ast.module_form -> (unit -> 'a) -> ('a,Migration_sparse.error list) result

val with_prepared_list : prepared list -> (unit -> 'a) -> ('a,Migration_sparse.error list) result
