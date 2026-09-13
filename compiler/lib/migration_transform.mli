(** Checked row-function source, not a linked transform callback. No execution
    authority or semantic callback hash is produced by this initial judgment. *)
type requested = { entity : string; function_ref : Ast.expr; loc : Location.loc }
type function_binding = { identity : string; owner : Ast.module_form; declaration : Ast.func_decl }
type writeback_binding = { mapping : Migration_transform_rules.writeback; function_binding : function_binding }
type row = { mapping : Migration_transform_rules.entity; function_binding : function_binding option; fixtures : function_binding list; writebacks : writeback_binding list }
type t
val check : project_root:string -> source:string -> Ast.module_form -> Migration_transform_rules.t ->
  functions:requested list -> fixtures:Ast.expr list -> (t,Migration_sparse.error list) result
val rows : t -> row list
val rules : t -> Migration_transform_rules.t
val source_inputs : t -> (string * string) list

(** Prepared source/rule evidence is deliberately not a checked transformation. *)
type prepared
val prepare : project_root:string -> source:string -> Ast.module_form -> Migration_transform_rules.t ->
  functions:requested list -> fixtures:Ast.expr list -> (prepared,Migration_sparse.error list) result
val with_prepared : prepared -> (unit -> 'a) -> ('a,Migration_sparse.error list) result
val check_prepared : prepared -> (t,Migration_sparse.error list) result
val captured_sources : t -> (Ast.module_form * string) list
val root : t -> Ast.module_form
val proof_context : t -> Migration_proof_context.t

val with_prepared_list : prepared list -> (unit -> 'a) -> ('a,Migration_sparse.error list) result

(** Complete source and import-owner guard, also for roots with no row function. *)
type captured
val capture : before:Migration_inventory.t -> after:Migration_inventory.t -> source:string -> Ast.module_form -> (captured,Migration_sparse.error list) result
val with_captured : captured -> (unit -> 'a) -> ('a,Migration_sparse.error list) result
