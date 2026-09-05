module I = Migration_inventory
module H = Migration_history_sources
module S = Migration_seal
module Header = Migration_header
module M = Migration_manifest
module E = Migration_sparse
type error = { path : string; message : string }
type preview = { family : string; frozen_version : int; current_version : int; manifest : M.t }
type refresh_preview = { family : string; current_version : int; manifest : M.t;
                         diagnostics : Compile.diagnostic list }
exception Invalid of error list
let reject path message = raise (Invalid [{path;message}])
let sparse = function Ok x -> x | Error errors -> raise (Invalid (List.map (fun (e : E.error) -> {path=e.loc.file;message=e.code ^ ": " ^ e.message}) errors))
let seal = function Ok x -> x | Error (e : S.error) -> reject e.loc.file e.message
let history = function Ok x -> x | Error (e : H.error) -> reject e.loc.file e.message
let inventory = function Ok x -> x | Error (e : Migration_ir.error) -> reject e.loc.file e.message
let manifest = function Ok x -> x | Error errors -> raise (Invalid (List.map (fun (e : M.error) -> {path=e.path;message=e.message}) errors))
let module_path root name = match Validation_common.schema_module_relative_path name with
  | Some relative -> Filename.concat root relative | None -> reject root ("invalid schema module " ^ name)
let parse file source = match Parser.parse_module file source with
  | Ok m -> m | Err e -> reject file e.msg
let check file source =
  let diagnostics = Compile.check_source file source |> List.filter (fun (d : Compile.diagnostic) -> d.severity = "error") in
  if diagnostics <> [] then raise (Invalid (List.map (fun (d : Compile.diagnostic) -> {path=d.file;message=d.code ^ ": " ^ d.message}) diagnostics))
let graph file source =
  let m = parse file source in Frontend_check.build_local_import_graph ~entry:m file
let paths graph = Hashtbl.fold (fun file _ files -> file :: files) graph [] |> List.sort String.compare
let overlay root inputs f =
  Source_input.with_overlays ~project_root:(Option.value (Source_input.project_root ()) ~default:root) inputs f
let rewrite family after source = match Migration_source.rewrite_version ~family ~before:"VCurrent" ~after source with
  | Ok source -> source | Error message -> reject "" message
let next_body family version before after =
  let pairs = inventory (I.same_candidates ~before ~after) |> List.map (fun same ->
    let old,fresh = I.same_declarations same in old.I.qualified_name,fresh.I.qualified_name) |> List.sort_uniq compare in
  let same = match pairs with [] -> "[]" | _ -> "[\n    " ^
    String.concat ",\n    " (List.map (fun (old,fresh) -> "Same " ^ old ^ " " ^ fresh) pairs) ^ "\n  ]" in
  Printf.sprintf {|module %s.Migrate.V%d exposing [migration]
import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Same(..)]
import %s
import %s

migration = Migration {
  from: %s
  to: %s
  same: %s
  entities: {}
}
|} family version (I.root_module before) (I.root_module after) (I.root_module before) (I.root_module after) same

let mark_next file source ~previous ~current =
  let view = match Migration_source_syntax.read ~file ~source with
    | Ok view -> view | Error error -> reject file error.message in
  let declaration = List.find_map (function Ast.DConst c when c.name = "migration" -> Some c | _ -> None)
    (Migration_source_syntax.module_ view).decls |> Option.get in
  let entries = match Migration_form.application declaration.value with
    | "Migration",[Ast.ERecord {fields;_}] -> (match List.assoc "same" fields with
      | Ast.EList {elems;_} -> elems | _ -> assert false)
    | _ -> assert false in
  let nodes = List.map (fun expression ->
    match Migration_form.application expression with
    | "Same",[Ast.EConstructor {name;args=[];_};_] when String.starts_with ~prefix:(previous ^ ".") name ->
      "same:" ^ String.sub name (String.length previous + 1) (String.length name - String.length previous - 1),expression
    | _ -> reject file "generated Same expression has an unexpected source form") entries in
  match Migration_provenance.annotate view ~previous ~current nodes with
  | Ok source -> source | Error error -> reject file error.message

let start ~compiler_abi ~project_root:root ~family ~version ~documents =
  try
    let h = history (H.discover ~compiler_abi ~project_root:root ~family) in
    let current = H.current h in
    let n = current.H.version and next = current.H.version + 1 in
    if n <> version then reject current.root_file "the selected schema revision changed; resolve the target again before starting a revision";
    if not (Migration_source.valid_revision ("V" ^ string_of_int next)) then reject current.root_file "schema version allocation overflow";
    let completed = H.completed_migrations h in
    let existing = H.current_migration h in
    if n > 1 && existing = None then reject current.root_file "refresh the current migration before starting another revision";
    (* Every existing edge must already be source-sealed and checked. In particular,
       a changed VCurrent is a refresh decision, not a license to freeze wrong bytes. *)
    let checked_edges = List.map (fun (migration : H.migration_source) ->
      let located = match sparse (Header.read ~file:migration.path migration.contents) with
        | Some located -> located | None -> reject migration.path "record the current migration's source seals before starting another revision" in
      let previous,current = Header.roots located in
      let checked = sparse (Header.verify ~project_root:root ~migration_module:(family ^ ".Migrate.V" ^ string_of_int migration.version)
        ~previous ~current located) in
      check migration.path migration.contents;
      migration,checked) (completed @ Option.to_list existing) in
    let old_target = match existing with
      | None -> None
      | Some migration ->
        let _,checked = List.find (fun ((m : H.migration_source),_) -> m.path = migration.path) checked_edges in
        let previous,current = Header.seals checked in
        ignore (seal (S.verify_semantics ~compiler_abi (seal (S.verify_sources ~project_root:root current))));
        Some previous in
    let copies = match Migration_source.freeze_closure ~project_root:root ~family ~version:n with
      | Ok copies -> copies | Error message -> reject current.root_file message in
    let frozen = List.map (fun (copy : Migration_source.frozen_copy) -> copy.target_path,copy.contents) copies in
    let rewrites = match existing with
      | None -> []
      | Some migration ->
        let shared = List.concat_map (fun (m : H.migration_source) -> paths (graph m.path m.contents)) completed in
        paths (graph migration.path migration.contents) |> List.filter_map (fun file ->
          let source = Source_input.read file in
          let m = parse file source in
          if Migration_schema.migration_family m.module_name <> Some family then None else
          let changed = rewrite family ("V" ^ string_of_int n) source in
          if changed = source then None else begin
            if List.mem file shared then reject file "a completed migration shares this helper's VCurrent references; isolate its history before freezing";
            Some (file,changed)
          end) in
    let frozen_root = module_path root (family ^ ".V" ^ string_of_int n) in
    let writes,frozen_inputs = overlay root frozen (fun () ->
      let before = inventory (I.load ~compiler_abi ~root_file:frozen_root) in
      let frozen_seal = seal (S.create ~project_root:root before) in
      let current_seal = seal (S.create ~project_root:root current.inventory) in
      let rewrites = match existing,old_target with
        | Some migration,Some previous ->
          let source = List.assoc migration.path rewrites in
          let header = sparse (Header.create ~previous ~current:frozen_seal) in
          let source = sparse (Header.replace ~file:migration.path ~source header) in
          (migration.path,source) :: List.remove_assoc migration.path rewrites
        | None,None -> rewrites
        | _ -> assert false in
      let header = sparse (Header.create ~previous:frozen_seal ~current:current_seal) in
      let next_file = module_path root (family ^ ".Migrate.V" ^ string_of_int next) in
      let next_source = mark_next next_file (Header.encode header ^ next_body family next before current.inventory)
        ~previous:(I.root_module before) ~current:(I.root_module current.inventory) in
      frozen @ rewrites @ [next_file,next_source],List.map fst (I.source_inputs before)) in
    let original_reads = List.map fst (H.source_inputs h) in
    let reads = original_reads @ frozen_inputs in
    let imports = List.concat_map (fun file ->
      let m = parse file (Source_input.read file) in
      List.filter_map (fun (i : Ast.import_decl) ->
        if String.starts_with ~prefix:"Tesl." i.module_name then None else Some (file,i.module_name)) m.imports) original_reads in
    let source_manifest = manifest (M.create ~project_root:root ~reads
      ~directories:[Filename.dirname current.root_file;Filename.dirname (module_path root (family ^ ".Migrate.V1"))]
      ~imports ~documents ~writes) in
    overlay root (M.overlays source_manifest) (fun () ->
      List.iter (fun (file,source) -> check file source) writes;
      ignore (history (H.discover ~compiler_abi ~project_root:root ~family)));
    history (H.verify_unchanged h);
    manifest (M.verify_source source_manifest ~documents);
    manifest (M.verify_disk source_manifest);
    {family;frozen_version=n;current_version=next;manifest=source_manifest} |> Result.ok
  with
  | Invalid errors -> Error errors
  | Sys_error message | Failure message | Invalid_argument message -> Error [{path=root;message}]
  | Unix.Unix_error (error,operation,path) -> Error [{path;message=operation ^ ": " ^ Unix.error_message error}]

module Syntax = Migration_source_syntax
module Merge = Migration_source_merge
module D = Migration_declaration
let syntax file source =
  let view = match Syntax.read ~file ~source with Ok v -> v | Error e -> reject file e.message in
  let syntax = match sparse (D.read_syntax (Syntax.module_ view)) with
    | Some syntax -> syntax | None -> reject file "expected a current Migration declaration" in
  view,syntax
let source_result file = function Ok x -> x | Error (e : Syntax.error) -> reject file e.message
let relative root name =
  let prefix = root ^ "." in
  if String.starts_with ~prefix name then String.sub name (String.length prefix) (String.length name - String.length prefix)
  else name
let same_pair file expression =
  let reference = function Ast.EConstructor {name;args=[];_} -> name
    | Ast.EField {obj=Ast.EConstructor {name;args=[];_};field;_} -> name ^ "." ^ field
    | _ -> reject file "MIG024: expected a qualified Same reference" in
  match Migration_form.application expression with
  | "Same",[old;fresh] -> reference old,reference fresh
  | _ -> reject file "MIG024: expected a Same pair of qualified schema references"
let refresh_same file source before after =
  let view,syntax = syntax file source in
  let previous = I.root_module before and current = I.root_module after in
  let members = source_result file (Syntax.members view syntax.same) in
  (match syntax.same with Ast.EList _ -> () | _ -> reject file "MIG024: Same requires a literal list");
  let existing,desired = List.split (List.map (fun (_,expression) ->
    let old,fresh = same_pair file expression in
    let id = "same:" ^ relative previous old in
    let isolated = {syntax with D.same=Ast.EList {elems=[expression];loc=Checker.expr_loc expression}} in
    let equal = match D.identity_claims ~before ~after isolated with
      | Error _ -> false
      | Ok claims -> List.for_all (fun (claim : E.identity) ->
        match I.verify_same ~before ~after ~previous:claim.previous ~current:claim.current with
        | Ok _ -> true | Error _ -> false) claims in
    (* A record and same-named codec share surface syntax but have separate
       namespaces. The whole claim is retained only if every namespace matches. *)
    let wanted = if equal then
      Some {Merge.id;key=None;body="Same " ^ old ^ " " ^ fresh} else None in
    (id,expression),wanted) members) in
  (* A missing claim is a deliberate revalidation request. Only existing valid
     claims are retained; refresh never fills an omission with new Same evidence. *)
  (source_result file (Merge.reconcile view ~collection:syntax.same ~previous ~current
    ~existing ~desired:(List.filter_map Fun.id desired))).source
let required = function E.Paired {contract_changed=false;missing_identities=[];_} -> false | _ -> true
let decision_body before identity (errors : E.error list) =
  let fields = I.stored_fields before |> List.filter (fun (f : I.stored_field) -> relative (I.root_module before) f.entity = identity)
    |> List.map (fun (f : I.stored_field) -> f.name) |> List.sort String.compare in
  let reason = identity ^ ": " ^ String.concat "; " (List.map (fun (e : E.error) -> e.message) errors) ^
    "; old row fields: " ^ String.concat ", " fields in
  "todo " ^ Compile.json_encode_string reason
let inferred_entry requirements before loc identity entity =
  match entity with
  | E.Added _ -> "New"
  | E.Removed _ -> "Drop"
  | E.Paired _ ->
    (* Select one additive candidate while satisfying only the other entries'
       coverage. Transform here is a local classification probe, never a checked
       row function or execution permission. *)
    let entries = E.requirement_entities requirements |> List.filter_map (fun (name,entity) ->
      if not (required entity) then None else
      let kind = if name = identity then E.Additive else match entity with
        | E.Added _ -> E.New | E.Removed _ -> E.Drop | E.Paired _ -> E.Transform in
      Some {E.entity=name;kind;loc}) in
    let checked = match E.check_requirements requirements ~entries ~loc with
      | Error errors -> Error errors
      | Ok coverage -> Result.map (fun _ -> ()) (Migration_additive.check coverage ~defaults:[]) in
    (match checked with Ok () -> "Additive []" | Error errors -> decision_body before identity errors)
let refresh_entities file source before after =
  let view,syntax = syntax file source in
  let previous = I.root_module before and current = I.root_module after in
  (* A stale user Same stays in place and receives its ordinary diagnostic. It
     cannot supply requirements for generating any dependent adapters. *)
  let requirements = match D.identity_claims ~before ~after syntax with
    | Error _ -> None
    | Ok identities -> (match E.requirements ~before ~after ~identities ~loc:syntax.declaration.loc with
      | Error _ -> None | Ok requirements -> Some requirements) in
  match requirements with
  | None -> source
  | Some requirements ->
    let projection = E.requirement_entities requirements in
    let members = source_result file (Syntax.members view syntax.entities) in
    (match syntax.entities with Ast.ERecord {type_hint=None;_} -> () | _ -> reject file "MIG002: entities requires a literal record");
    let names name entity =
      let short = List.hd (List.rev (String.split_on_char '.' name)) in
      name :: short :: (match entity with
        | E.Added e | E.Removed e -> [e.I.entity_name]
        | E.Paired e -> [e.previous.I.entity_name;e.current.I.entity_name]) in
    let selected = List.map (fun (key,expression) ->
      let key = Option.get key in
      let matches = List.filter (fun (name,entity) -> List.mem key (names name entity)) projection in
      let normalized = match matches with
        | [] -> None | [name,_] -> Some name
        | _ -> reject file ("MIG002: ambiguous entity key " ^ key ^ "; use its owning module path") in
      key,expression,normalized) members in
    let assigned = List.filter_map (fun (_,_,name) -> name) selected in
    if List.length (List.sort_uniq String.compare assigned) <> List.length assigned then
      reject file "MIG002: multiple source entries name the same owned entity";
    let existing = List.map (fun (key,expression,_) -> "entity:" ^ key,expression) selected in
    let desired = projection |> List.filter_map (fun (identity,entity) ->
      if not (required entity) then None else
      let key = match List.find_opt (fun (_,_,name) -> name = Some identity) selected with
        | Some (key,_,_) -> key | None -> identity in
      Some {Merge.id="entity:" ^ key;key=Some key;
        body=inferred_entry requirements before syntax.declaration.loc identity entity}) in
    (source_result file (Merge.reconcile view ~collection:syntax.entities ~previous ~current ~existing ~desired)).source

let refresh ~compiler_abi ~project_root:root ~family ~version ~documents =
  try
    let h = history (H.discover ~compiler_abi ~project_root:root ~family) in
    let current = H.current h in
    if current.H.version <> version then reject current.root_file "the selected schema revision changed; resolve the target again before refreshing";
    let migration = match H.current_migration h with
      | Some migration -> migration | None -> reject current.root_file "refresh requires an existing sealed current migration; start a revision first" in
    let _,initial = syntax migration.path migration.contents in
    let previous = match List.find_opt (fun (s : H.schema) -> s.version = version-1) (H.frozen h) with
      | Some previous -> previous | None -> reject migration.path "refresh requires an adjacent frozen predecessor" in
    if initial.previous_root <> I.root_module previous.inventory || initial.current_root <> I.root_module current.inventory then
      reject migration.path "MIG020: refresh requires the current edge's adjacent frozen/current schema references";
    List.iter (fun (edge : H.migration_source) ->
      let header = match sparse (Header.read ~file:edge.path edge.contents) with
        | Some header -> header | None -> reject edge.path "completed migration is missing its source seals" in
      let old,fresh = Header.roots header in
      ignore (sparse (Header.verify ~project_root:root ~migration_module:(family ^ ".Migrate.V" ^ string_of_int edge.version)
        ~previous:old ~current:fresh header));
      check edge.path edge.contents) (H.completed_migrations h);
    let header = match sparse (Header.read ~file:migration.path migration.contents) with
      | Some header -> header | None -> reject migration.path "current migration is missing its recorded source seals" in
    if Header.module_name header <> family ^ ".Migrate.V" ^ string_of_int version ||
       Header.roots header <> (initial.previous_root,initial.current_root) then
      reject migration.path "MIG013: current migration metadata does not match its adjacent schema references";
    let previous_seal,_ = Header.recorded_seals header in
    let checked_previous = seal (S.verify_sources ~project_root:root previous_seal) in
    ignore (seal (S.verify_semantics ~compiler_abi checked_previous));
    let target_seal = seal (S.create ~project_root:root current.inventory) in
    let header = sparse (Header.create ~previous:previous_seal ~current:target_seal) in
    let source = refresh_same migration.path migration.contents previous.inventory current.inventory in
    let source = refresh_entities migration.path source previous.inventory current.inventory in
    let source = sparse (Header.replace ~file:migration.path ~source header) in
    let reads = List.map fst (H.source_inputs h) in
    let imports = List.concat_map (fun file ->
      let m = parse file (Source_input.read file) in
      List.filter_map (fun (i : Ast.import_decl) ->
        if String.starts_with ~prefix:"Tesl." i.module_name then None else Some (file,i.module_name)) m.imports) reads in
    let source_manifest = manifest (M.create ~project_root:root ~reads ~imports ~documents
      ~directories:[Filename.dirname current.root_file;Filename.dirname migration.path] ~writes:[migration.path,source]) in
    let diagnostics = overlay root (M.overlays source_manifest) (fun () -> Compile.check_source migration.path source) in
    history (H.verify_unchanged h);
    manifest (M.verify_source source_manifest ~documents);
    manifest (M.verify_disk source_manifest);
    Ok {family;current_version=version;manifest=source_manifest;diagnostics}
  with
  | Invalid errors -> Error errors
  | Sys_error message | Failure message | Invalid_argument message -> Error [{path=root;message}]
  | Unix.Unix_error (error,operation,path) -> Error [{path;message=operation ^ ": " ^ Unix.error_message error}]
