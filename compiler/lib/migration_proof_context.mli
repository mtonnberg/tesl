(** Serialized, invocation-local proof transport. A context is a checking aid,
    never persisted evidence or permission to cast a value. *)
type t
type site = { owner : Ast.module_form; constructor : string; field : string;
  argument : Ast.expr; projection : Proof_kernel.proven_fact list; predicates : (string * string) list }
val create : sources:(Ast.module_form * string) list -> sites:site list ->
  revalidate:(unit -> unit) -> t
val revalidate : t -> unit
val require_graph : t -> (Ast.module_form * string) list -> unit
val with_contexts : t list -> (unit -> 'a) -> 'a
val with_context : t -> (unit -> 'a) -> 'a
val without_context : (unit -> 'a) -> 'a
val with_module : Ast.module_form -> (unit -> 'a) -> 'a
val transport : constructor:string -> field:string -> Ast.expr ->
  Proof_kernel.proven_fact list -> Proof_kernel.proven_fact list
