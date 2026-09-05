(** A complete, checked schema inventory loaded from saved source files.
    No caller-supplied declaration list can omit a private fact producer.
    This is semantic inventory construction, not history/adoption validation. *)
type t

type stored_field = {
  entity : string;
  name : string;
  loc : Location.loc;
  contract : Migration_canonical.node;
}

type field_change =
  | Added_field of stored_field
  | Removed_field of stored_field
  | Changed_field of { previous : stored_field; current : stored_field;
                       definition_changed : bool }

(** [compiler_abi] identifies the compiler executing this load. Supplying an old
    tag does not execute old semantics or validate a persisted history record. *)
val load : compiler_abi:string -> root_file:string ->
  (t, Migration_ir.error) result

val module_names : t -> string list
val root_module : t -> string

(** Raw-byte SHA-256 preconditions for every saved source in the owned closure.
    These are edit preconditions, not semantic identities or history evidence. *)
val source_inputs : t -> (string * string) list

type declaration_kind = Newtype | Adt | Record | Entity | Fact | Codec_declaration | Function
type declaration = {
  namespace : Migration_ir.namespace;
  qualified_name : string;
  declaration_kind : declaration_kind;
  source_loc : Location.loc;
}

(** The complete owned declaration inventory, including private modules. Value
    constructors are aliases of their defining declaration, not extra entries. *)
val declarations : t -> declaration list

(** Compiler-local semantic equality evidence. This checks full canonical trees
    and can only be constructed from checked inventories in one family and ABI.
    It is NOT authority to cast values/proofs or accept a persisted row. The
    contextual Migration checker must additionally establish the adjacent source
    and target versions, sealed fact ownership and recorded execution semantics
    before introducing a cross-version type identity. *)
type same
type same_error_kind = Incompatible_inventories | Invalid_declaration | Different_kind | Different_closure
type difference = { previous : declaration option; current : declaration option }
type same_error = { kind : same_error_kind; message : string; difference : difference }
val verify_same : before:t -> after:t ->
  previous:(Migration_ir.namespace * string) -> current:(Migration_ir.namespace * string) ->
  (same, same_error) result
val same_declarations : same -> declaration * declaration
val same_digest : same -> string
val same_compiler_abi : same -> string

(** Deterministically propose every equal type/fact/codec pair, including private
    declarations. Missing/changed declarations are omitted. No user Same list is
    modified; omitting an equal pair deliberately remains possible. *)
val same_candidates : before:t -> after:t -> (same list, Migration_ir.error) result

val snapshot : t -> Migration_canonical.node
val closure : t -> (Migration_ir.namespace * string) list ->
  (Migration_canonical.node, Migration_ir.error) result

(** One location per declared entity field, including private entities. Contracts
    include the field's type/proof/storage annotation and the complete semantic
    closure of its dependencies. Plain records are reached through their stored
    occurrences; they do not create independent locations or generations. *)
val stored_fields : t -> stored_field list

(** Complete semantic dependencies of one owned stored field, including private
    declarations, recursive types and every reachable fact producer. None means
    the location is not owned by this inventory; Some [] is a primitive-only
    location. The order is the same deterministic declaration order as above. *)
val stored_dependencies : t -> entity:string -> field:string -> declaration list option

type field_shape = {
  stored_field : stored_field;
  type_identity : Migration_canonical.node;
  proof_identity : Migration_canonical.node option;
  db_type : string option;
}
(** Canonical, resolved logical field shape from the same checked lowering.
    These are not PostgreSQL catalog types or DDL permissions. *)
val field_shapes : t -> field_shape list
(** Canonical declared indexes, including uniqueness, order and explicit names.
    A change needs separate physical/catalog and admitted-writer safety checks. *)
val entity_indexes : t -> entity:string -> Migration_canonical.node option

(** Compare saved, checked inventories in one family and compiler ABI. Unchanged
    locations are folded out. [definition_changed=false] identifies a dependency
    change such as a codec, nested ADT or fact producer under unchanged field text.
    This is field impact, not a physical-catalog diff, compatibility proof, verified
    Same bridge, migration plan or permission to prune a decoder. *)
val field_changes : before:t -> after:t ->
  (field_change list, Migration_ir.error) result

type stored_entity = {
  entity_name : string;
  entity_loc : Location.loc;
  table_name : string;
  primary_key : string;
  entity_contract : Migration_canonical.node;
}
type entity_change =
  | Added_entity of stored_entity
  | Removed_entity of stored_entity
  | Changed_entity of { previous : stored_entity; current : stored_entity;
                        definition_changed : bool }

(** Every owned table, including private entities. Its contract is the same
    complete closure as [closure inventory [Type, entity_name]], so table/primary
    key/index mappings and transitive proof/codec dependencies cannot disappear
    when all individual field definitions stay equal. *)
val stored_entities : t -> stored_entity list

(** Entity impact for checking sparse migration records. Revisions are
    alpha-renamed; different owning modules or entity names remain distinct.
    Unchanged entities are folded out; only dependency changes set
    [definition_changed=false]. This does not classify online safety, establish
    that a user supplied every required Same entry, or authorize DDL. *)
val entity_changes : before:t -> after:t ->
  (entity_change list, Migration_ir.error) result
