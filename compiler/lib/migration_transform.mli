(** Checked row-function source, not a linked transform callback. No execution
    authority or semantic callback hash is produced by this initial judgment. *)
type requested = { entity : string; function_ref : Ast.expr; loc : Location.loc }
type function_binding = { identity : string; owner : Ast.module_form; declaration : Ast.func_decl }
type row = { mapping : Migration_transform_rules.entity; function_binding : function_binding option; fixtures : function_binding list }
type t
val check : project_root:string -> source:string -> Ast.module_form -> Migration_transform_rules.t ->
  functions:requested list -> fixtures:Ast.expr list -> (t,Migration_sparse.error list) result
val rows : t -> row list
val rules : t -> Migration_transform_rules.t
val source_inputs : t -> (string * string) list
