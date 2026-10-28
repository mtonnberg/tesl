(** Explicit application/database selection for source generation. No database
    connection is opened and deployment state cannot be inferred from source. *)
type selection = {
  entry_file : string;
  database_file : string;
  database_name : string;
  family : string;
  schema_root : string;
  previous_version : int option;
  current_version : int;
  migration_directory : string;
}
type candidate = { database_name : string; database_file : string }
type error = { loc : Location.loc; message : string; candidates : candidate list }
type t
(** [entry_file] is explicit and canonical. Resolve every database declaration in
    its local import graph; infer only a single candidate. [database] accepts a
    unique short name or its full module-qualified name. Legacy entities lists
    require the separate schema-ownership upgrade. This verifies schema ownership
    and inventory, not the complete application. Source guards include the entry,
    connection owner, imports, private schemas and editor document versions. *)
(** Infer the canonical source project from the schema file actually imported by
    the selected connection, not from an enclosing repository marker. Entry and
    local imports must be canonical regular files inside that project. This is
    preliminary discovery only; [resolve] captures and rechecks the selection. *)
val infer_project_root : entry_file:string -> database:string option -> (string,error list) result
val resolve : compiler_abi:string -> project_root:string -> entry_file:string ->
  database:string option -> documents:Migration_manifest.document list ->
  (t,error list) result
val resolve_with_compatibility : stored_value_compatibility:string option ->
  compiler_abi:string -> project_root:string -> entry_file:string ->
  database:string option -> documents:Migration_manifest.document list -> (t,error list) result
val selection : t -> selection
(** Immutable guards captured by selection, including the complete application
    imports and schema/migration discovery. Consumers recheck source and disk
    before returning a derived report. No writes are present. *)
val source_guard : t -> Migration_manifest.t
(** Generate using this exact selection, then combine its original guards with
    the source preview. Rebinding the application's database, changing imports,
    history or document versions invalidates the selection. No files are written.
    The caller still presents/checks the complete application and applies the
    manifest through the shared, separately implemented apply protocol. *)
val start : t -> documents:Migration_manifest.document list ->
  (Migration_generate.preview,error list) result
val refresh : t -> documents:Migration_manifest.document list ->
  (Migration_generate.refresh_preview,error list) result
