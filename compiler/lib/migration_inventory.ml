open Ast
open Migration_ir

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

type field_entry = {
  identity : string;
  definition : Migration_canonical.node;
  field : stored_field;
}

type t = {
  compiler_abi : string;
  scopes : Migration_canonical.scope list;
  modules : string list;
  definitions : definition list;
  fields : field_entry list;
  sources : (string * string) list;
}

let module_names inventory = inventory.modules
let root_module inventory = match inventory.scopes with
  | [scope] -> scope.family ^ "." ^ scope.revision
  | _ -> assert false (* load publishes exactly one schema revision *)
let source_inputs inventory = inventory.sources
let stored_fields inventory = List.map (fun entry -> entry.field) inventory.fields

let with_abi inventory body = Migration_canonical.Seq [
  Bytes "compiler-semantics"; Bytes inventory.compiler_abi; body]

let closure inventory roots =
  match Migration_ir.closure ~scopes:inventory.scopes
      ~definitions:inventory.definitions
      ~roots:(List.map (fun (ns, name) -> ns, Global name) roots) with
  | Ok body -> Ok (with_abi inventory body)
  | Error _ as error -> error

let snapshot inventory =
  match Migration_ir.closure ~scopes:inventory.scopes
      ~definitions:inventory.definitions
      ~roots:(List.map (fun d -> d.key) inventory.definitions) with
  | Ok body -> with_abi inventory body
  | Error _ -> assert false (* load checks this exact closure before publishing t *)

let field_changes ~before ~after =
  let loc = Location.dummy_loc "<migration-field-impact>" in
  if List.map (fun (scope : Migration_canonical.scope) -> scope.family) before.scopes <>
     List.map (fun (scope : Migration_canonical.scope) -> scope.family) after.scopes then
    Error {loc; message="stored field comparison requires the same schema family"}
  else if before.compiler_abi <> after.compiler_abi then
    Error {loc; message="stored field comparison requires the same recorded compiler ABI; recompiling historical source cannot establish the meaning of previously stored values"}
  else
    let rec merge changes previous current = match previous, current with
      | [], [] -> List.rev changes
      | old :: rest, [] -> merge (Removed_field old.field :: changes) rest []
      | [], fresh :: rest -> merge (Added_field fresh.field :: changes) [] rest
      | old :: old_rest, fresh :: fresh_rest ->
        let order = String.compare old.identity fresh.identity in
        if order < 0 then merge (Removed_field old.field :: changes) old_rest current
        else if order > 0 then merge (Added_field fresh.field :: changes) previous fresh_rest
        else
          let changes = if old.field.contract = fresh.field.contract then changes
            else Changed_field { previous=old.field; current=fresh.field;
              definition_changed=old.definition <> fresh.definition } :: changes in
          merge changes old_rest fresh_rest in
    Ok (merge [] before.fields after.fields)

let names = function
  | DFunc f -> [Value, f.name]
  | DType (TypeNewtype t) -> [Type, t.name; Value, t.name]
  | DType (TypeAdt t) -> (Type, t.name) ::
      List.map (fun (v : adt_variant) -> Value, v.ctor) t.variants
  | DRecord r -> [Type, r.name; Value, r.name]
  | DEntity e -> [Type, e.name; Value, e.name]
  | DFact f -> [Predicate, f.name]
  | DCodec c -> [Codec, c.name]
  | DDatabase _ | DCapability _ | DConst _ | DQueue _ | DChannel _
  | DWorkers _ | DCache _ | DAgent _ | DEmail _ | DCapture _ | DApi _
  | DServer _ | DTest _ | DApiTest _ | DLoadTest _ -> []

let wants (import : import_decl) (owner : module_form) (ns, name) =
  match import.names with
  | ImportAll -> false
  | ImportExposing exposed ->
    List.mem name exposed ||
    ns = Value && List.exists (function
      | DType (TypeAdt t) -> List.mem (t.name ^ "(..)") exposed &&
          List.exists (fun (v : adt_variant) -> v.ctor = name) t.variants
      | _ -> false) owner.decls

(** Resolve existing compiler builtins by their owning module and name. There
    is no new per-primitive version registry or retained historical lowering:
    the complete inventory is bound to the caller's compiler ABI above. *)
let builtin (m : module_form) ns name =
  let exports = Type_system.tesl_module_exports in
  let homes = List.filter_map (fun (home, members) ->
    if List.mem name members then Some home else None) exports in
  let chosen = List.filter (fun home -> List.exists (fun (i : import_decl) ->
    i.module_name = home && (ns <> Predicate || match i.names with
      | ImportAll -> false | ImportExposing exposed -> List.mem name exposed)) m.imports) homes in
  let homes = if chosen = [] then homes else chosen in
  let homes = List.sort_uniq String.compare homes in
  let kind_ok = match ns with
    | Codec -> List.mem_assoc name Validation_common.builtin_codec_type
    | Predicate -> List.exists (fun (_, preds) -> List.mem name preds)
        Checker.tesl_module_predicate_exports
    | Type -> name <> "" && name.[0] >= 'A' && name.[0] <= 'Z'
    | Value -> Type_system.stdlib_capabilities_of name = [] in
  if not kind_ok then None
  else match homes with
    | [home] -> Some (Primitive (home ^ "." ^ name))
    | [] when List.mem name Type_system.always_available_stdlib_names ->
      Some (Primitive ("Tesl.Prelude." ^ name))
    | _ -> None

let load ~compiler_abi ~root_file =
  let loc = Location.dummy_loc root_file in
  try
    if String.trim compiler_abi = "" then reject loc "compiler ABI identity is required for a semantic schema inventory";
    let sources = Hashtbl.create 16 in
    let read expected path =
      let path = Validation_common.canonical_import_path path in
      let source = In_channel.with_open_bin path In_channel.input_all in
      let m = match Parser.parse_module path source with
        | Ok m -> m
        | Err e -> reject e.loc e.msg in
      (match expected with
       | Some name when m.module_name <> name ->
         reject (Location.dummy_loc m.source_file) (Printf.sprintf "schema module `%s` declares `%s`" name m.module_name)
       | _ -> ());
      Hashtbl.replace sources path source;
      m in
    let root = read None root_file in
    let family, revision = match String.split_on_char '.' root.module_name with
      | [family; revision] when Migration_source.valid_family family &&
          Migration_source.valid_revision revision -> family, revision
      | _ -> reject (Location.dummy_loc root.source_file) "semantic inventory requires a schema revision root" in
    let modules = Hashtbl.create 16 in
    let rec visit m =
      if not (Hashtbl.mem modules m.module_name) then begin
        Hashtbl.add modules m.module_name m;
        (match Migration_schema.check_contents m with
         | error :: _ -> reject error.loc error.message
         | [] -> ());
        List.iter (fun (i : import_decl) ->
          if String.starts_with ~prefix:"Tesl." i.module_name then ()
          else if not (Migration_schema.within root.module_name i.module_name) then
            reject i.loc (Printf.sprintf "schema import `%s` escapes `%s`" i.module_name root.module_name)
          else if not (Hashtbl.mem modules i.module_name) then
            visit (read (Some i.module_name)
              (Validation_common.resolve_local_import_path m.source_file i.module_name))) m.imports
      end in
    visit root;
    let modules = Hashtbl.fold (fun _ m rest -> m :: rest) modules []
      |> List.sort (fun a b -> String.compare a.module_name b.module_name) in
    let members = List.concat_map (fun m -> List.filter_map (function
      | DEntity e -> Some (m.module_name ^ "." ^ e.name, e) | _ -> None) m.decls) modules in
    (match Migration_schema.check_member_storage members with
     | error :: _ -> reject error.loc error.message | [] -> ());
    (* Imported parses are content-aware. Semantic query caches additionally
       depend on the complete import snapshot, not just a module's own AST.
       Inventory calls may read several saved revisions in one process, so each
       complete load starts a fresh semantic query scope. *)
    Query_cache.clear ();
    let globals = List.concat_map (fun m -> List.concat_map (fun d ->
      List.map (fun (ns, name) -> (ns, m.module_name ^ "." ^ name),
        Global (m.module_name ^ "." ^ name)) (names d)) m.decls) modules in
    let scopes = [{ Migration_canonical.family; revision; role=Snapshot_role }] in
    let definitions = List.concat_map (fun m ->
      (* Reuse the public compiler judgment, including literal/complexity and
         cross-module checks. Type + proof checks alone are not its full gate.
         Every dependency body is checked by its own iteration here. *)
      let diagnostics = Compile.check_module ~skip_dep_body:(fun _ -> true)
        (Hashtbl.find sources m.source_file) m in
      (match List.find_opt (fun (d : Compile.diagnostic) -> d.severity = "error") diagnostics with
       | Some error -> reject (Location.make_loc error.file error.start_line
           error.start_col error.end_line error.end_col) error.message
       | None -> ());
      let typed_nodes, errors = Checker.check_module_with_typed_nodes m in
      (match errors with error :: _ -> reject error.loc error.message | [] -> ());
      let local = List.concat_map (fun d -> List.map (fun (ns, name) ->
        (ns, name), Global (m.module_name ^ "." ^ name)) (names d)) m.decls in
      let imported = List.concat_map (fun (i : import_decl) ->
        match List.find_opt (fun owner -> owner.module_name = i.module_name) modules with
        | None -> []
        | Some owner -> List.concat_map (fun d ->
            List.filter_map (fun ((ns, name) as key) ->
              if wants i owner key then Some ((ns, name), Global (owner.module_name ^ "." ^ name))
              else None) (names d)) owner.decls) m.imports in
      let resolve ns name = match List.assoc_opt (ns, name) local with
        | Some _ as result -> result
        | None ->
          let candidates = List.filter_map (fun (key, symbol) ->
            if key = (ns, name) then Some symbol else None) imported |> List.sort_uniq compare in
          (match candidates with
           | [symbol] -> Some symbol
           | _ :: _ -> reject (Location.dummy_loc m.source_file) ("ambiguous semantic reference `" ^ name ^ "`")
           | [] -> match List.assoc_opt (ns, name) globals with
             | Some _ as result -> result
             | None -> builtin m ns name) in
      List.map (fun d -> match Migration_ir.define ~scopes ~resolve ~typed_nodes m d with
        | Ok definition -> definition
        | Error error -> raise (Invalid error)) m.decls) modules in
    (* Validation and inference load imported interfaces themselves. Refuse a
       source change across these passes rather than publish mixed source state. *)
    Hashtbl.iter (fun path source ->
      if In_channel.with_open_bin path In_channel.input_all <> source then
        reject loc ("schema source changed during semantic inventory: " ^ path)) sources;
    (match Migration_ir.closure ~scopes ~definitions
        ~roots:(List.map (fun d -> d.key) definitions) with
     | Error error -> raise (Invalid error)
     | Ok _ -> ());
    let source_inputs = Hashtbl.to_seq sources |> List.of_seq
      |> List.map (fun (path, source) -> path, Migration_hash.digest source)
      |> List.sort compare in
    let inventory = { compiler_abi; scopes; definitions; fields=[]; sources=source_inputs;
      modules=List.map (fun m -> m.module_name) modules } in
    let fields = List.concat_map (fun d -> List.map (fun (name, body) ->
      let entity = match d.key with
        | Type, Global entity -> entity
        | _ -> reject loc "stored field has no owning entity identity" in
      let entity_form = List.assoc entity members in
      let field_form = List.find (fun (f : Ast.field_def) -> f.name = name) entity_form.fields in
      let dependencies = match Migration_ir.closure ~scopes ~definitions ~roots:body.references with
        | Ok node -> node | Error error -> raise (Invalid error) in
      let identity = Migration_canonical.encode (tag "stored-location" [
        require loc (Migration_canonical.reference scopes entity); Bytes name]) in
      let contract = with_abi inventory (tag "stored-field" [body.node; dependencies]) in
      { identity; definition=body.node; field={entity; name; loc=field_form.loc; contract} }
    ) d.stored_fields) definitions
      |> List.sort (fun a b -> String.compare a.identity b.identity) in
    let inventory = { inventory with fields } in
    Ok inventory
  with
  | Invalid error -> Error error
  | Sys_error message | Failure message | Invalid_argument message -> Error {loc; message}
  | Unix.Unix_error (error, operation, path) ->
    Error {loc; message=Printf.sprintf "%s: %s: %s" operation path (Unix.error_message error)}
