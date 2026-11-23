(** Raw integrity metadata for the complete source closure of a frozen migration.
    Root bytes include schema seals and exclude only their own closure block.
    Helper bytes are exact. No entry grants proof transport or execution authority. *)
type t
type located
val read : file:string -> string -> (located option, Migration_sparse.error list) result
val root : located -> string
val sources : located -> (string * string) list
val mentions_file : project_root:string -> file:string -> located -> bool
val capture : project_root:string -> root_file:string -> source:string ->
  (t, Migration_sparse.error list) result
val attach : file:string -> source:string -> t -> (string, Migration_sparse.error list) result
val verify : project_root:string -> root_file:string -> source:string -> located ->
  (unit, Migration_sparse.error list) result
(** The generated checkpoint beside a completed migration root (v<n>.checkpoint). *)
val checkpoint_file : string -> string
(** A root's bytes without its frozen-source block (the bytes its closure seal
    hashes); None when the block is malformed. *)
val without_block : file:string -> string -> string option
(** The declared name and imports of a module's bytes (for a root, without its
    frozen-source block): recorded facts (Migration_module_facts), else a parse. *)
type parsed = Recorded of Migration_module_facts.t | Parsed of Ast.module_form
val parsed_facts : parsed -> Migration_module_facts.t
val source_facts : file:string -> string -> (parsed, Parser.parse_error) result
(** The imports of [source_facts], in source order. *)
val imports : file:string -> string -> (string list, Parser.parse_error) result
(** SHA-256 of the root's checkpoint recorded in this block, if any. [verify]
    refuses a recorded checkpoint whose bytes differ (MIG013). *)
val checkpoint : located -> string option
val with_checkpoint : t -> string option -> t
