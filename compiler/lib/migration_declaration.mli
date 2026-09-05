(** Contextual source checking for additive Migration declarations. This binds
    sparse coverage and logical row adapters to the adjacent schema source view.
    Present history headers receive source-integrity checks. Mandatory sealed
    history, semantic ABI validation, runtime admission, physical planning, transformations and
    nonempty compatibility fixtures are separate, still-required judgments. *)
type t
val check : compiler_abi:string -> source:string -> Ast.module_form ->
  (t option, Migration_sparse.error list) result
val coverage : t -> Migration_sparse.t
val additive : t -> Migration_additive.t
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
