(** Public source-only repair declarations. Database installation and progress
    remain separate authorities; this judgment produces pure checked artifacts. *)
open Ast
module D = Migration_declaration
module Q = Migration_queue_transform
module S = Migration_sparse
exception Invalid of S.error list
let reject code loc message = raise(Invalid [{S.code;loc;message;related=[]}])
let checked = function Ok value -> value | Error errors -> raise(Invalid errors)
let at = Checker.expr_loc
let rec reference = function
  | EVar {name;_} | EConstructor {name;args=[];_} -> name
  | EField {obj;field;_} -> reference obj ^ "." ^ field
  | expression -> reject "MIG020" (at expression) "repair predecessor must name a directly imported migration or repair declaration"

let check ~source (entry:module_form) =
  let rec visit seen source (m:module_form) =
    (match Frontend_check.module_complexity_diagnostics m with
      | [] -> () | error::_ -> reject error.code (Location.dummy_loc m.source_file) error.message);
    let declarations=List.filter_map(function
      | DConst c when Migration_form.is_queue_repair m c -> Some c | _ -> None)m.decls in
    match declarations with
    | [] -> None
    | _::duplicate::_ -> reject "MIG020" duplicate.loc "a module owns exactly one QueueRepair declaration"
    | [declaration] ->
      let path=Validation_common.canonical_import_path m.source_file in
      if List.mem path seen then reject "MIG020" declaration.loc "cyclic queue repair predecessor history";
      if List.length seen>=128 then reject "MIG020" declaration.loc "queue repair predecessor history exceeds the source checking limit of 128 revisions";
      if declaration.name<>"repair" then reject "MIG020" declaration.loc "name the QueueRepair declaration `repair`";
      let migration_root=match Validation_common.schema_module_parts m.module_name with
        | Some(_,"Migrate",[revision]) -> Migration_source.valid_revision revision
        | _ -> false in
      let family=match Migration_schema.migration_family m.module_name with
        | Some family when not migration_root -> family
        | _ -> reject "MIG020" declaration.loc "QueueRepair belongs in a schema family's pure migration helper module" in
      let current_path=Validation_common.resolve_local_import_path path (family ^ ".VCurrent") in
      let project_root=Filename.dirname(Filename.dirname(Filename.dirname current_path)) in
      let relative=match Validation_common.schema_module_relative_path m.module_name with
        | Some path -> path | None -> reject "MIG020" declaration.loc "invalid queue repair module name" in
      if path<>Filename.concat project_root relative then reject "MIG020" declaration.loc "queue repair must use its canonical module path";
      let fields=match Migration_form.application declaration.value with
        | "QueueRepair",[ERecord {fields;type_hint=None;_}] -> fields
        | _ -> reject "MIG020" declaration.loc "expected `repair = QueueRepair { predecessor, job, revision, migrate, fixtures }`" in
      let names=Hashtbl.create 8 in
      List.iter(fun(name,value)->
        if not(List.mem name ["predecessor";"job";"revision";"migrate";"fixtures"]) then
          reject "MIG020" (at value) ("unknown QueueRepair field `" ^ name ^ "`");
        if Hashtbl.mem names name then reject "MIG023" (at value) ("duplicate QueueRepair field `" ^ name ^ "`");
        Hashtbl.add names name ())fields;
      let field name=match List.assoc_opt name fields with Some value->value | None ->
        reject "MIG020" declaration.loc ("QueueRepair requires `" ^ name ^ "`") in
      let predecessor=field "predecessor" in
      let owner,name=match List.rev(String.split_on_char '.' (reference predecessor)) with
        | name::(_::_ as owner) -> String.concat "." (List.rev owner),name
        | _ -> reject "MIG020" (at predecessor) "qualify the repair predecessor with its imported module" in
      if not(List.exists(fun(i:import_decl)->i.module_name=owner)m.imports) then
        reject "MIG020" (at predecessor) "import the repair predecessor module directly";
      if Migration_schema.migration_family owner<>Some family then
        reject "MIG028" (at predecessor) "repair predecessor belongs to another schema family";
      let job=match field "job" with ELit {lit=LString value;_} -> value | expression ->
        reject "MIG020" (at expression) "QueueRepair job requires an exact payload identity string" in
      let revision=match field "revision" with ELit {lit=LInt value;_} when value>0 && value<=2147483646 -> value | expression ->
        reject "MIG028" (at expression) "QueueRepair revision requires a positive integer no greater than 2147483646" in
      let fixtures=match field "fixtures" with EList {elems;_}->elems | expression ->
        reject "MIG020" (at expression) "QueueRepair fixtures requires a literal list" in
      let callback=field "migrate" in
      Source_input.with_overlays ~project_root:(Option.value(Source_input.project_root()) ~default:project_root)
        [path,source] (fun () ->
        let parent_path=Validation_common.resolve_local_import_path path owner |> Validation_common.canonical_import_path in
        let parent_source=Source_input.read parent_path in
        let parent=match Parser.parse_module parent_path parent_source with
          | Ok m -> m | Err error -> reject "MIG020" error.loc error.msg in
        if parent.module_name<>owner then reject "MIG020" (at predecessor) "repair predecessor module identity differs from its import";
        if not(List.exists(function ExportName exported -> exported=name | _ -> false)parent.exports) then
          reject "MIG020" (at predecessor) "repair predecessor declaration is not exported";
        let rejected,contextual_declarations=match name with
          | "repair" -> (match visit (path::seen) parent_source parent with
            | Some repair -> repair
            | None -> reject "MIG020" (at predecessor) "repair predecessor has no QueueRepair declaration")
          | "migration" ->
            let migration=match checked(D.check ~compiler_abi:"compiler-local-unsealed-comparison" ~source:parent_source parent) with
              | Some migration -> migration | None -> reject "MIG020" (at predecessor) "repair predecessor has no Migration declaration" in
            (match List.filter(fun conversion->snd(Q.queue_job conversion)=job)(D.queue_transforms migration) with
              | [conversion] -> conversion,List.filter_map(function
                  | DConst c when Migration_form.is_declaration parent c -> Some(parent,parent_source,c) | _ -> None)parent.decls
              | _ -> reject "MIG028" (at predecessor) "repair job has no exact checked conversion in its predecessor")
          | _ -> reject "MIG020" (at predecessor) "repair predecessor must name `migration` or `repair`" in
        if snd(Q.queue_job rejected)<>job then reject "MIG028" (at predecessor) "repair job differs from its predecessor";
        let contextual_declarations=(m,source,declaration)::contextual_declarations in
        Some(checked(Q.check_repair_source ~project_root ~contextual_declarations ~rejected ~revision ~source m ~callback ~fixtures),contextual_declarations)) in
  try
    Ok(Option.map fst(visit [] source entry))
  with Invalid errors -> Error errors
    | Sys_error message | Invalid_argument message | Failure message ->
      Error [{S.code="MIG013";loc=Location.dummy_loc entry.source_file;message;related=[]}]
    | Unix.Unix_error(error,operation,path) ->
      Error [{S.code="MIG013";loc=Location.dummy_loc entry.source_file;
        message=operation ^ ": " ^ path ^ ": " ^ Unix.error_message error;related=[]}]

let diagnostics source m = match check ~source m with
  | Ok _ -> [] | Error errors -> D.diagnostics_of_errors errors
