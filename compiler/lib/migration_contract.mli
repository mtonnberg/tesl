(** Explicit source authority for an exact checked window-to-settled transition.
    A checked value is not a database receipt and never proves rows are final. *)
type t
val check : plan:Migration_retained_storage.t -> namespace:string ->
  file:string -> source:string -> (t,Migration_sparse.error list) result
val version : t -> int
val family : t -> string
val namespace : t -> string
val source_file : t -> string
val source_digest : t -> string
val window : t -> Migration_retained_storage.version
val settled : t -> Migration_retained_storage.version
val final_generations : t -> (string * int) list
val operations : t -> Migration_canonical.node list
val canonical : t -> Migration_canonical.node
val digest : t -> string
val encoded : t -> string
val settled_encoded : t -> string
val settled_hash : t -> string
(** Produce the reviewable source from checked inventory only. It does not write
    files, manufacture source approval or execute a contract. *)
val source : plan:Migration_retained_storage.t -> version:int ->
  (string,Migration_sparse.error list) result
(** Revalidate captured source/checked history before publishing an artifact.
    Whole-program source/disk/import-directory guards remain mandatory. *)
val revalidate : t -> (unit,Migration_sparse.error list) result
(** Public source diagnostics, including implicit history ownership and complete
    checked source linkage. The validation-only namespace is not an app binding. *)
val check_module : compiler_abi:string -> source:string -> Ast.module_form ->
  (t option,Migration_sparse.error list) result
val diagnostics : string -> Ast.module_form -> Frontend_check.diagnostic list
