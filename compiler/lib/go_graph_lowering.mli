(** Deterministic Go-only lowering of a supplied complete original graph. No
    imports or bytes are recollected. A token records exact original ownership,
    emitted declarations and expression correspondence; it grants no proof. *)
type t
val lower : entry:Ast.module_form -> Ast.module_form list -> (t,string) result
val modules : t -> Ast.module_form list
val entry : t -> Ast.module_form
val owner : t -> string -> string option
val symbol : t -> owner:string -> string -> (string * string) option
val original_expr : t -> Ast.expr -> Ast.expr
val function_binding : t -> owner:Ast.module_form -> Ast.func_decl ->
 (Ast.module_form * Ast.func_decl) option
