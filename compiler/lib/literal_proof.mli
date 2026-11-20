(** Explicit, fact-owned literal proof introduction. Validators are checked
    without literal inference, then evaluated with bounded, pure semantics. *)
type error = { loc : Location.loc; message : string }
val with_module : source:string -> Ast.module_form -> (unit -> 'a) -> 'a * error list

(** Bind checking and emission to the captured source graph; reject changed
    dependencies or import resolution before publishing an artifact. *)
val with_graph : entry:string -> (Ast.module_form * string) list ->
  (unit -> 'a) -> ('a, error list) result
