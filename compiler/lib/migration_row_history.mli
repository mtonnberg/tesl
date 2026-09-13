(** Complete checked source generations and callback links. These per-schema
    descriptions are not installed markers, retained catalogs, SQL projections or
    authority to migrate rows. Source publication remains guarded by Program. *)
type entity = {
  identity : string;
  generation : int;
  table : Migration_storage.table;
  type_contract : Migration_canonical.node;
}
type version = {
  version : int;
  schema : Migration_inventory.t;
  storage : Migration_storage.t;
  entities : entity list;
}
type binding
val migration_version : binding -> int
val previous : binding -> entity
val current : binding -> entity
val link : binding -> Migration_transform_link.t
val row : binding -> Migration_transform.row

type t
val check : schemas:Migration_inventory.t list -> edges:Migration_declaration.t list ->
  (t,Migration_sparse.error list) result
val versions : t -> version list
val bindings : t -> binding list
val captured_sources : t -> (Ast.module_form * string) list
(** Recheck each retained link; the owning Program also checks the complete source
    manifest, including additive declarations and directory membership. *)
val revalidate : t -> (unit,Migration_sparse.error list) result
(** Check the exact callback/mode pairing retained by the checked history.
    Migrate owns a real source function; Derived owns its checked mapping and
    never fabricates a source callback. The emitter separately validates every
    generated target field against its actual nominal type environment. *)
val validate_adapter_modes : t -> (unit,Migration_sparse.error list) result
val hex : string -> string
val contract : Migration_canonical.domain -> Migration_canonical.node -> string * string

(** Validate arithmetic only; this does not assign a history generation. *)
val next_generation : int -> (int,Migration_sparse.error list) result

(** Exact checked adjacent declarations, including additive default judgments. *)
val declarations : t -> Migration_declaration.t list
