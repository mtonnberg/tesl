(** Additional value-identity judgment for same-column proof introduction.
    Ordinary type/proof checking and the transform's other field rules remain
    prerequisites. This judgment never authorizes a nominal conversion. *)
val check :
  resolve:(Ast.module_form -> Migration_ir.resolver) ->
  modules:Ast.module_form list -> root:Ast.module_form ->
  owner:Ast.module_form -> declaration:Ast.func_decl ->
  mapping:Migration_transform_rules.entity ->
  (unit, Migration_sparse.error list) result
