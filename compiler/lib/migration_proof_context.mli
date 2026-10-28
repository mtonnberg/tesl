(** Serialized, invocation-local proof transport. A context is a checking aid,
    never persisted evidence or permission to cast a value. *)
type t
type nominal_type = { identity : string; declaration : Location.loc }
type nominal_shape = Named of nominal_type | Primitive of string | Applied of nominal_shape * nominal_shape
type nominal_spec = { previous : nominal_shape; current : nominal_shape;
  previous_entity : nominal_type; previous_field : string;
  entity : nominal_type; types : (nominal_type * nominal_type) list }
type site = { owner : Ast.module_form; constructor : string; field : string;
  argument : Ast.expr; projection : Proof_kernel.proven_fact list; predicates : (string * string) list;
  nominal : nominal_spec option }
val create : sources:(Ast.module_form * string) list -> sites:site list ->
  resolve_type:(Ast.module_form -> string -> string option) ->
  revalidate:(unit -> unit) -> t
val revalidate : t -> unit
val require_graph : t -> (Ast.module_form * string) list -> unit
val with_contexts : t list -> (unit -> 'a) -> 'a
val with_context : t -> (unit -> 'a) -> 'a
val without_context : (unit -> 'a) -> 'a
val with_module : Ast.module_form -> (unit -> 'a) -> 'a
val transport : constructor:string -> field:string -> Ast.expr ->
  Proof_kernel.proven_fact list -> Proof_kernel.proven_fact list
(** A value transport is restricted to the exact checked final-row projection.
    It never changes inference of that projection or ordinary nominal equality. *)
type nominal
val nominal : constructor:string -> field:string -> Ast.expr -> nominal option
val accepts_nominal : nominal -> actual:Type_system.ty -> expected:Type_system.ty -> bool
(** Lowering consumes these only behind the original-to-lowered complete graph
    guard in Migration_program; a structurally matching Go type is insufficient. *)
val nominal_transports : t -> nominal list
(** Identity of the exact checked source-site certificate, including its complete
    source context. Equal type shapes or declaration names cannot substitute. *)
val same_nominal : nominal -> nominal -> bool
val nominal_module : nominal -> string
val nominal_argument : nominal -> Ast.expr
val nominal_field : nominal -> string
val nominal_spec : nominal -> nominal_spec
val revalidate_nominal : nominal -> unit
