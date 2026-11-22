module I = Migration_inventory
module H = Migration_history_sources
module S = Migration_seal
module Header = Migration_header
module M = Migration_manifest
module E = Migration_sparse
type error = { path : string; message : string }
type preview = { family : string; frozen_version : int; current_version : int; manifest : M.t }
type decision_option = { id:string; label:string; template:string; help:string; needs_custom_code:bool }
type decision = { id:string; entity:string; file:string; line:int; col:int; reason:string; options:decision_option list }
type choice = {decision_id:string;option_id:string}
type refresh_preview = { family : string; current_version : int; manifest : M.t;
                         diagnostics : Compile.diagnostic list; decisions:decision list }
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

let start_with_compatibility ~stored_value_compatibility ~compiler_abi ~project_root:root ~family ~version ~documents =
  try
    let h = history (H.discover_with_compatibility ~stored_value_compatibility ~compiler_abi ~project_root:root ~family) in
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
      let previous_seal,current_seal = Header.seals checked in
      List.iter (fun recorded -> ignore (seal (S.verify_semantics ?stored_value_compatibility ~compiler_abi
        (seal (S.verify_sources ~project_root:root recorded))))) [previous_seal;current_seal];
      check migration.path migration.contents;
      migration,checked) (completed @ Option.to_list existing) in
    let old_target = match existing with
      | None -> None
      | Some migration ->
        let _,checked = List.find (fun ((m : H.migration_source),_) -> m.path = migration.path) checked_edges in
        let previous,_ = Header.seals checked in
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
      let before = inventory (I.load_with_compatibility ~stored_value_compatibility ~compiler_abi ~root_file:frozen_root) in
      let frozen_seal = seal (S.create ~project_root:root before) in
      let frozen_seal = match existing with
        | None -> frozen_seal
        | Some migration ->
          let _,checked = List.find (fun ((m:H.migration_source),_) -> m.path=migration.path) checked_edges in
          let _,recorded_target = Header.seals checked in
          S.inherit_queue_inventory ~from:recorded_target frozen_seal in
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
    (* Retarget every helper first, then seal the exact completed closure. The
       root hashes its schema header too, excluding only its own closure block. *)
    let writes = match existing with
      | None -> writes
      | Some migration -> overlay root writes (fun () ->
        let source = List.assoc migration.path writes in
        let closure = sparse (Migration_closure.capture ~project_root:root
          ~root_file:migration.path ~source) in
        let source = sparse (Migration_closure.attach ~file:migration.path ~source closure) in
        (migration.path,source) :: List.remove_assoc migration.path writes) in
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
      ignore (history (H.discover_with_compatibility ~stored_value_compatibility ~compiler_abi ~project_root:root ~family)));
    history (H.verify_unchanged h);
    manifest (M.verify_source source_manifest ~documents);
    manifest (M.verify_disk source_manifest);
    {family;frozen_version=n;current_version=next;manifest=source_manifest} |> Result.ok
  with
  | Invalid errors -> Error errors
  | Sys_error message | Failure message | Invalid_argument message -> Error [{path=root;message}]
  | Unix.Unix_error (error,operation,path) -> Error [{path;message=operation ^ ": " ^ Unix.error_message error}]

let start = start_with_compatibility ~stored_value_compatibility:None

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
let decision_body before after identity (errors : E.error list) =
  let shapes inv=I.field_shapes inv |> List.filter(fun s->relative(I.root_module inv)s.I.stored_field.entity=identity)in
  let old=shapes before and fresh=shapes after in
  let changed=List.filter_map(fun s->Option.bind(List.find_opt(fun p->p.I.stored_field.name=s.I.stored_field.name)old)
    (fun p->if p.stored_field.contract=s.stored_field.contract then None else Some(p,s)))fresh in
  let optional_message=if changed<>[] && List.length old=List.length fresh &&
    List.for_all(fun(p,s)->Migration_scaffold.required_value p s)changed &&
    List.for_all(fun(e:E.error)->Compile.string_contains e.message "Additive requires the existing field")errors then
    Some(String.concat " "(List.map(fun(_,s)->identity ^ "." ^ s.I.stored_field.name ^
      " is now required. Choose a value for rows where it is missing; existing values can be kept.")changed))else None in
  let names fields=String.concat ", "(List.map(fun s->identity ^ "." ^ s.I.stored_field.name)fields)in
  let added=List.filter(fun s->not(List.exists(fun p->p.I.stored_field.name=s.I.stored_field.name)old))fresh
  and removed=List.filter(fun p->not(List.exists(fun s->p.I.stored_field.name=s.I.stored_field.name)fresh))old in
  let descriptions=(if added=[]then[]else["Choose values for new fields " ^ names added]) @
    (if removed=[]then[]else["Choose an explicit rename or old-writer values for removed fields " ^ names removed]) @
    List.map(fun(p,s)->
      if p.I.proof_identity=None && s.I.proof_identity<>None then
        "a first proof was added to " ^ identity ^ "." ^ s.stored_field.name ^ "; choose how existing rows are checked and what happens to rows that fail"
      else if p.I.proof_identity<>None && s.I.proof_identity=None then
        "the proof on " ^ identity ^ "." ^ s.stored_field.name ^ " was removed; choose what old binaries receive for values the old proof would reject"
      else if p.I.proof_identity<>None || s.I.proof_identity<>None then "stored proof contract changed for " ^ identity ^ "." ^ s.stored_field.name
      else "Map the changed type or codec of " ^ identity ^ "." ^ s.stored_field.name)changed in
  let reason=if descriptions=[]then String.concat "; "(List.map(fun(e:E.error)->e.message)errors)
    else String.concat ". " descriptions ^ "."in
  "todo " ^ Compile.json_encode_string(Option.value optional_message ~default:reason)
let additive_coverage requirements loc identity =
    (* Select one additive candidate while satisfying only the other entries'
       coverage. Transform here is a local classification probe, never a checked
       row function or execution permission. *)
    let entries = E.requirement_entities requirements |> List.filter_map (fun (name,entity) ->
      if not (required entity) then None else
      let kind = if name = identity then E.Additive else match entity with
        | E.Added _ -> E.New | E.Removed _ -> E.Drop | E.Paired _ -> E.Transform in
      Some {E.entity=name;kind;loc}) in
    E.check_requirements requirements ~entries ~loc
let inferred_entry requirements before after loc identity entity =
  match entity with
  | E.Added _ -> "New"
  | E.Removed _ -> "Drop"
  | E.Paired _ ->
    let checked = match additive_coverage requirements loc identity with
      | Error errors -> Error errors
      | Ok coverage -> Result.map (fun _ -> ()) (Migration_additive.check coverage ~defaults:[]) in
    (match checked with Ok () -> "Additive []" | Error errors -> decision_body before after identity errors)
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
        body=inferred_entry requirements before after syntax.declaration.loc identity entity}) in
    (source_result file (Merge.reconcile view ~collection:syntax.entities ~previous ~current ~existing ~desired)).source

(* Advisory source templates come from the same checked inventories and additive
   classifier as generation. Probe literals establish only that the exact shape
   permits defaults; they are never emitted as a guessed data policy. Neither a
   template nor this metadata is an executable plan or source-write authority. *)
let entity_decision_guidance file source before after =
  let view,declaration = syntax file source in
  let requirements = match D.identity_claims ~before ~after declaration with
    | Error _ -> None
    | Ok identities -> (match E.requirements ~before ~after ~identities ~loc:declaration.declaration.loc with
      | Error _ -> None | Ok value -> Some value) in
  match requirements with None -> [] | Some requirements ->
  let old_shapes = I.field_shapes before and new_shapes = I.field_shapes after in
  let additive_option identity (previous:I.stored_entity) (current:I.stored_entity) loc =
    let old = List.filter (fun s -> s.I.stored_field.entity=previous.entity_name) old_shapes in
    let fresh = List.filter (fun s -> s.I.stored_field.entity=current.entity_name) new_shapes in
    let needed = List.filter (fun s ->
      not (List.exists (fun old -> old.I.stored_field.name=s.I.stored_field.name) old) &&
      not (Migration_additive.nullable s && s.proof_identity=None)) fresh in
    let primitive shape =
      if shape.I.proof_identity<>None then None else
      List.find_opt (fun (name,_,_) -> shape.type_identity=Migration_additive.primitive name)
        ["Tesl.Prelude.Int","Int",Migration_additive.Integer "0";
         "Tesl.Float.Float","Float",Migration_additive.Floating 0.;
         "Tesl.Prelude.Bool","Bool",Migration_additive.Boolean false;
         "Tesl.Prelude.String","String",Migration_additive.Text ""] in
    let choices = List.filter_map (fun shape -> Option.map (fun (_,name,value) ->
      shape.I.stored_field.name,name,value) (primitive shape)) needed in
    if needed=[] || List.length choices<>List.length needed then [] else
    let defaults = List.map (fun (field,_,value) -> {Migration_additive.entity=identity;field;value;loc}) choices in
    match additive_coverage requirements loc identity with
    | Error _ -> []
    | Ok coverage -> match Migration_additive.check coverage ~defaults with
      | Error _ -> []
      | Ok _ ->
        let rules = List.map (fun (field,ty,_) -> "Default " ^ field ^ " (todo " ^
          Compile.json_encode_string ("Choose a literal of type " ^ ty ^ " for " ^ identity ^ "." ^ field) ^ ")") choices in
        [{id="additive-default";label="Supply literal defaults for the new required fields";
          template="Additive [" ^ String.concat ", " rules ^ "]";
          help="The compiler checked that literal defaults can cover this additive shape. Replace every todo with a literal of the named primitive type. Choose values for existing rows deliberately; no default value has been guessed. Refresh and compile the complete application before reviewing the physical plan. Index and deployment readiness remain separate checks.";
          needs_custom_code=true}] in
  Syntax.members view declaration.entities |> source_result file |> List.filter_map (fun (key,expression) ->
    match key,expression with
    | Some key,Ast.EApp {fn=Ast.EVar {name="todo";_};arg=Ast.ELit {lit=Ast.LString reason;_};loc} ->
      let matches = E.requirement_entities requirements |> List.filter (fun (identity,entity) ->
        let owned = match entity with E.Added e | E.Removed e -> [e.I.entity_name]
          | E.Paired pair -> [pair.previous.I.entity_name;pair.current.I.entity_name] in
        List.mem key (identity :: List.hd (List.rev (String.split_on_char '.' identity)) :: owned)) in
      (match matches with
       | [identity,entity] ->
         let options = match entity with E.Paired pair ->
           additive_option identity pair.previous pair.current loc @
            List.map(fun (p:Migration_scaffold.t)->{id=p.id;label=p.label;template=p.template;help=p.help;needs_custom_code=Compile.string_contains p.template "todo \""})
            (Migration_scaffold.options ~file ~source ~before ~after ~requirements ~identity
              ~previous:pair.previous ~current:pair.current ~missing:pair.missing_identities ~loc)
           | _ -> [] in
          let reason=if options<>[]then reason else match entity with
           | E.Paired pair->let explanations=ref []in
             ignore(Migration_scaffold_general.options ~on_unsupported:(fun text->explanations:=text::!explanations)
               ~file ~source ~before ~after ~identity ~previous:pair.previous ~current:pair.current ~missing:pair.missing_identities
               ~validator:Migration_scaffold.validator ~constructor:Migration_scaffold.constructor_fixture ());
             (match List.sort_uniq compare !explanations with []->reason|messages->String.concat " " messages)
           | _->reason in
          Some {id="entity:" ^ identity;entity=identity;file;line=loc.start.line;col=loc.start.col;reason;options}
       | _ -> None)
    | _ -> None)

let refresh_jobs file source before after =
 let changes=Migration_scaffold_general.queue_changes before after in
 let view,declaration=syntax file source in
 let source=if changes=[] || List.mem_assoc "jobs" declaration.fields then source else
   match Migration_form.application declaration.declaration.value with
   | "Migration",[record]->let range=source_result file(Syntax.collection_range view record)in
     source_result file(Syntax.replace view [({Syntax.start_byte=range.start_byte+1;end_byte=range.start_byte+1},"jobs: {}, ")])
   | _->reject file "migration declaration changed before queue scaffolding"in
 let view,declaration=syntax file source in
 match List.assoc_opt "jobs" declaration.fields with None->source|Some jobs->
 let members=source_result file(Syntax.members view jobs)in
 let existing=List.map(fun(key,expr)->"job:" ^ Option.get key,expr)members in
 let desired=List.map(fun(change:Migration_scaffold_general.queue_change)->
   {Merge.id="job:" ^ change.key;key=Some change.key;body="todo " ^ Compile.json_encode_string change.reason})changes in
 (source_result file(Merge.reconcile view ~collection:jobs ~previous:(I.root_module before) ~current:(I.root_module after) ~existing ~desired)).source

let queue_decision_guidance file source before after =
 let view,declaration=syntax file source in
 match List.assoc_opt "jobs" declaration.fields with None->[]|Some jobs->
 source_result file(Syntax.members view jobs)|>List.filter_map(function
 | Some key,Ast.EApp{fn=Ast.EVar{name="todo";_};arg=Ast.ELit{lit=Ast.LString reason;_};loc}->
   (match List.find_opt(fun(c:Migration_scaffold_general.queue_change)->c.key=key)(Migration_scaffold_general.queue_changes before after)with
    | None->None|Some change->
      let explanations=ref []in
      let plans=Migration_scaffold_general.queue_options ~on_unsupported:(fun reason->explanations:=reason::!explanations) ~file ~source ~before ~after ~change
        ~validator:Migration_scaffold.validator ~constructor:Migration_scaffold.constructor_fixture ()in
      let reason=if plans=[] && !explanations<>[]then String.concat " "(List.sort_uniq compare !explanations)else reason in
      Some{id="job:" ^ key;entity="Queued " ^ key;file;line=loc.start.line;col=loc.start.col;reason;
        options=List.map(fun(p:Migration_scaffold_general.queue_plan)->let o=p.option in
          {id=o.id;label=o.label;template=o.template;help=o.help;needs_custom_code=Compile.string_contains o.template "todo \""})plans})
 | _->None)

let decision_guidance file source before after =
  entity_decision_guidance file source before after @ queue_decision_guidance file source before after

(* Explicit Retype rules select fields; generation owns their physical name.
   This only proposes edits. The entire resulting migration is checked after
   sealing, so an invalid rule or WriteBack never acquires execution authority. *)
let retype_columns previous current migration =
 let _,declaration=syntax migration.H.path migration.contents in
 let entities=match declaration.entities with Ast.ERecord r -> r.fields | _ -> [] in
 let requested=List.concat_map (fun (entity,value) ->
  match Migration_form.application value with
  | "Migrate",[_;Ast.EList rules] -> List.filter_map (fun rule -> match Migration_form.application rule with
    | "Retype",[Ast.EVar field] ->
      let sources=List.filter_map (fun rule -> match Migration_form.application rule with
        | "Rename",[Ast.EVar old;Ast.EVar fresh] when fresh.name=field.name -> Some old.name
        | _ -> None) rules.elems in
      (* Ambiguous explicit mappings remain compiler diagnostics, never a
         reason to edit a schema field speculatively. *)
      (match sources with [] -> Some (entity,field.name,field.name)
       | [old] -> Some (entity,field.name,old) | _ -> None)
    | _ -> None) rules.elems
  | _ -> []) entities in
 let members=I.stored_entities current.H.inventory in
 let resolve name=List.filter (fun (e:I.stored_entity) ->
  let relative=relative (I.root_module current.inventory) e.entity_name in
  List.mem name [relative;e.entity_name;List.hd (List.rev (String.split_on_char '.' relative))]) members in
 let requested=List.filter_map (fun (entity,field,old) -> match resolve entity with
  | [entity] -> Some ((entity.I.entity_name,field),old) | _ -> None) requested |> List.sort_uniq compare in
 let previous_shapes=I.field_shapes previous.H.inventory in
 I.source_inputs current.inventory |> List.filter_map (fun (file,_) ->
  let view=source_result file (Syntax.read ~file ~source:(Source_input.read file)) in
  let owner=Syntax.module_ view in
  let edits=List.concat_map (function Ast.DEntity e -> List.filter_map (fun (f:Ast.field_def) ->
    let entity=owner.module_name ^ "." ^ e.name in
    match List.assoc_opt (entity,f.name) requested with
    | None -> None
    | Some old ->
      let name=Validation_common.sql_column_name f.name ^ "__v" ^ string_of_int current.version in
      let inherited=List.exists (fun shape ->
        relative (I.root_module previous.inventory) shape.I.stored_field.entity = relative (I.root_module current.inventory) entity &&
        shape.stored_field.name=old && shape.db_column=f.db_column) previous_shapes in
      (match f.db_column with
       | None ->
         let range=source_result file (Syntax.field_storage_point view f) in
         Some (range," @column(" ^ Migration_row_companion.quote name ^ ")")
       | Some column when column<>name && inherited ->
         let range=source_result file (Syntax.field_storage_value view f) in
         Some (range,Migration_row_companion.quote name)
       | Some _ -> None)) e.fields | _ -> []) owner.decls in
  if edits=[] then None else Some (file,source_result file (Syntax.replace view edits)))

let rec choose_entity_entry file source before after choice =
  let decisions=decision_guidance file source before after in
  let decision=match List.find_opt(fun (d:decision)->d.id=choice.decision_id)decisions with
    | Some d->d | None->reject file "the reviewed migration decision is unavailable; obtain a fresh preview" in
  let option_=match List.find_opt(fun (o:decision_option)->o.id=choice.option_id)decision.options with
    | Some o->o | None->reject file "the reviewed migration option is unavailable; obtain a fresh preview" in
  let view,declaration=syntax file source in
  let candidates=Syntax.members view declaration.entities |> source_result file |> List.filter_map(fun(_,expression)->
    let loc=Checker.expr_loc expression in
    if loc.start.line=decision.line && loc.start.col=decision.col then Some expression else None) in
  let expression=match candidates with [e]->e | _->reject file "migration decision no longer has one exact source member" in
  let requirements=match D.identity_claims ~before ~after declaration with
    | Ok identities->(match E.requirements ~before ~after ~identities ~loc:declaration.declaration.loc with
       | Ok r->r|Error _->reject file "migration identity requirements changed since review")
    | Error _->reject file "migration identity requirements changed since review"in
  let scaffold=if choice.option_id="additive-default"then None else
    E.requirement_entities requirements |> List.find_map(fun(identity,entity)->
      if identity<>decision.entity then None else match entity with
      | E.Paired pair->Migration_scaffold.options ~file ~source ~before ~after ~requirements ~identity
         ~previous:pair.previous ~current:pair.current ~missing:pair.missing_identities ~loc:(Checker.expr_loc expression)
         |> List.find_opt(fun(p:Migration_scaffold.t)->p.id=choice.option_id)
      | _->None)in
  if choice.option_id<>"additive-default" && scaffold=None then reject file "selected source scaffold is no longer available";
  let replacement=Option.fold ~none:option_.template ~some:(fun(p:Migration_scaffold.t)->p.replacement)scaffold in
  (* Replacing the expression leaves its prior generator fingerprint intact.
     The explicit choice is therefore user-owned on subsequent refreshes. *)
  let chosen=source_result file(Syntax.replace view [source_result file(Syntax.range view expression),
    Migration_source.source_fragment ~source replacement])in
  match scaffold with None->chosen | Some plan->
    append_plan file chosen plan

and append_plan file chosen (plan:Migration_scaffold.t) =
    let chosen=if plan.fixture="" then chosen else begin
    let view,declaration=syntax file chosen in
    let point,addition=match List.assoc_opt "fixtures" declaration.fields with
     | Some(Ast.EList{elems;_}as fixtures)->
       let range=source_result file(Syntax.collection_range view fixtures)in
       range.start_byte+1,plan.fixture ^ (if elems=[] then "" else ", ")
     | Some _->reject file "fixture scaffolding requires an existing literal fixtures list"
     | None->
       (match Migration_form.application declaration.declaration.value with
        | "Migration",[record]->
          let range=source_result file(Syntax.collection_range view record)in
          (* A multiline record keeps one field per line, as the formatter does. *)
          let multiline=range.start_byte+1<String.length chosen && (chosen.[range.start_byte+1]='\n' || chosen.[range.start_byte+1]='\r') in
          range.start_byte+1,
          if multiline then Migration_source.source_fragment ~source:chosen ("\n  fixtures: [" ^ plan.fixture ^ "]")
          else "fixtures: [" ^ plan.fixture ^ "], "
        | _->reject file "migration declaration changed before fixture insertion")in
    source_result file(Syntax.replace view [({Syntax.start_byte=point;end_byte=point},addition)])end in
    let view,_=syntax file chosen in
    let form=Syntax.module_ view in
    let available=ref form.imports in
    let exposed home name=
       if String.ends_with ~suffix:"(..)" name then
         let base=String.sub name 0 (String.length name-4)in
         if home="Tesl.Prelude" && base="Bool" then ["Bool";"True";"False"] else
         match List.find_opt(fun(m,t,_)->m=home && t=base)Type_system.stdlib_import_ctor_groups with
        | Some(_,_,ctors)->base::ctors | None->[name;base]
      else [name]in
    (* Collect the names each scaffold import adds, merged per module. *)
    let additions=ref [] in
    List.iter(fun text->
      let imported=match Parser.parse_module file("module " ^ form.module_name ^ " exposing []\n" ^ text ^ "\n")with
       | Ok m->List.hd m.imports|Err _->reject file "compiler scaffold import is malformed"in
      match imported.names with
      | Ast.ImportAll->
        if not(List.exists(fun(i:Ast.import_decl)->i.module_name=imported.module_name && i.names=Ast.ImportAll)!available)then begin
          available:=imported::!available;additions:= !additions @ [imported.module_name,None]end
      | Ast.ImportExposing needed->
        let actual=List.concat_map(fun(i:Ast.import_decl)->if i.module_name<>imported.module_name then []else
          match i.names with Ast.ImportAll->[]|Ast.ImportExposing names->List.concat_map(exposed i.module_name)names)!available in
        let missing=List.concat_map(exposed imported.module_name)needed |> List.filter(fun n->not(List.mem n actual)) |> List.sort_uniq compare in
        if missing<>[]then begin
          available:={imported with names=Ast.ImportExposing missing}::!available;
          additions:=(match List.assoc_opt imported.module_name !additions with
            | Some(Some names)->List.map(fun(m,n)->if m=imported.module_name then m,Some(List.sort_uniq compare(names @ missing))else m,n)!additions
            | _-> !additions @ [imported.module_name,Some missing])
        end)plan.imports;
    let helpers=let rec trim s=if String.ends_with ~suffix:"\n" s then trim(String.sub s 0(String.length s-1))else s in
      (* Generated helper text joins optional sections; keep one blank line
         between declarations. Generated strings escape their newlines. *)
      let collapsed=Str.global_replace(Str.regexp "\n\n\n+")"\n\n"plan.helpers in
      let rec lead s=if String.starts_with ~prefix:"\n" s then lead(String.sub s 1(String.length s-1))else s in
      trim(lead collapsed) in
    let lines=String.split_on_char '\n' chosen in
    let import_lines=List.map(fun(i:Ast.import_decl)->i.loc.start.line)form.imports in
    (* A scaffold names every import its templates might use; keep only names the
       resulting source references, so a plain rename does not add unused imports.
       Names a placeholder suggests (`Reject`, `Something`) stay importable for the
       value the user writes in its place. *)
    let text=List.filteri(fun index _->not(List.mem index import_lines))lines |> String.concat "\n" |>
      fun body->body ^ "\n" ^ helpers ^ "\n" ^ plan.replacement in
    let suggested=["Reject";"Row";"KeepRow";"DeleteRow";"RejectRow";"Something";"Nothing"] in
    let words=
      let tokens=try Lexer.tokenize file text with _->[] in
      List.concat_map(fun(t:Lexer.full_token)->match t.tok with
        | Token.STRING text->List.filter(fun w->List.mem w suggested)(Str.split(Str.regexp "[^A-Za-z0-9_]+")text)
        | tok->[Format.asprintf "%a" Token.pp tok])tokens in
    let used name=List.mem name words || (String.contains name '.' && Compile.string_contains text name) in
    let additions=List.filter_map(fun(m,names)->match names with
      | None->Some(m,None)
      | Some names->(match List.filter used names with []->None|kept->Some(m,Some kept)))!additions in
    let crlf line=if String.ends_with ~suffix:"\r" line then "\r" else "" in
    (* Render each written import exactly as the formatter would (long exposing
       lists wrap one name per line), so generated source is formatter-clean. *)
    let render text=
      let header="module " ^ form.module_name ^ " exposing []\n" in
      match (try Some(Formatter.format_source(header ^ text ^ "\n"))with _->None)with
      | Some formatted when String.starts_with ~prefix:header formatted->
        let body=String.sub formatted(String.length header)(String.length formatted-String.length header)in
        let rec trim s=if String.ends_with ~suffix:"\n" s then trim(String.sub s 0(String.length s-1))else s in
        trim body
      | _->text in
    let render_line text line=String.split_on_char '\n'(render text)|>List.map(fun l->l ^ crlf line)|>String.concat "\n" in
    let merged=ref [] and dropped=ref [] in
    let lines=List.mapi(fun index line->
      match List.find_opt(fun(i:Ast.import_decl)->i.loc.start.line=index)form.imports with
      | Some({names=Ast.ImportExposing names;_} as i) when List.mem_assoc i.module_name additions && not(List.mem i.module_name !merged)->
        (match List.assoc i.module_name additions with
         | Some extra->merged:=i.module_name:: !merged;
           (* A wrapped exposing list spans several lines; replace all of them. *)
           for later=index+1 to i.loc.stop.line do dropped:=later:: !dropped done;
           render_line("import " ^ i.module_name ^ " exposing [" ^ String.concat ", "(names @ extra) ^ "]")line
         | None->line)
      | _->line)lines in
    let fresh=List.filter_map(fun(m,names)->if List.mem m !merged then None else Some(match names with
      | None->"import " ^ m
      | Some names->"import " ^ m ^ " exposing [" ^ String.concat ", " names ^ "]"))additions in
    let last_import=List.fold_left max(-1)(List.map(fun(i:Ast.import_decl)->i.loc.stop.line)form.imports)in
    let first=match form.decls with d::_->(Ast.top_decl_loc d).start.line|[]->reject file "migration declaration disappeared"in
    let insert_at,separator=if last_import>=0 then last_import+1,"" else first,"\n" in
    let lines=List.concat(List.mapi(fun index line->
      let kept=if List.mem index !dropped then [] else [line] in
      if index=insert_at && fresh<>[] then
        List.map(fun text->render_line text line)fresh @ (if separator="" then [] else [crlf line]) @ kept else kept)lines) in
    let chosen=String.concat "\n" lines in
    let chosen=let rec trim s=if String.ends_with ~suffix:"\n" s || String.ends_with ~suffix:"\r" s then trim(String.sub s 0(String.length s-1))else s in trim chosen in
    let complete=chosen ^ Migration_source.source_fragment ~source:chosen(if helpers="" then "\n" else "\n\n" ^ helpers ^ "\n")in
    ignore(source_result file(Syntax.read ~file ~source:complete));complete

let choose_entry file source before after choice =
 if not(String.starts_with ~prefix:"job:" choice.decision_id)then choose_entity_entry file source before after choice,[] else
 let key=String.sub choice.decision_id 4 (String.length choice.decision_id-4)in
 let change=match List.find_opt(fun(c:Migration_scaffold_general.queue_change)->c.key=key)(Migration_scaffold_general.queue_changes before after)with
  | Some c->c|None->reject file "queue decision changed; request a fresh preview"in
 let plan=match List.find_opt(fun(p:Migration_scaffold_general.queue_plan)->p.option.id=choice.option_id)
   (Migration_scaffold_general.queue_options ~file ~source ~before ~after ~change ~validator:Migration_scaffold.validator ~constructor:Migration_scaffold.constructor_fixture ())with
  | Some p->p|None->reject file "queue option is unavailable; request a fresh preview"in
 let p=plan.option in
 let source=append_plan file source {Migration_scaffold.id=p.id;label=p.label;template=p.template;help=p.help;
   replacement=p.replacement;imports=p.imports;helpers=p.helpers;fixture=p.fixture}in
 let view,declaration=syntax file source in
 let expression=match List.assoc_opt "jobs" declaration.fields with
  | None->reject file "queue decision no longer exists"
  | Some jobs->(match source_result file(Syntax.members view jobs)|>List.find_opt(fun(k,_)->k=Some key)with
    | Some(_, (Ast.EApp{fn=Ast.EVar{name="todo";_};arg=Ast.ELit{lit=Ast.LString _;_};_} as expression))->expression
    | _->reject file "queue decision is no longer an unresolved placeholder")in
 let chosen=source_result file(Syntax.replace view [source_result file(Syntax.range view expression),plan.option.replacement])in
 chosen,plan.writes

let refresh_internal ~choice ~stored_value_compatibility ~compiler_abi ~project_root:root ~family ~version ~documents =
  try
    let h = history (H.discover_with_compatibility ~stored_value_compatibility ~compiler_abi ~project_root:root ~family) in
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
      let checked = sparse (Header.verify ~project_root:root ~migration_module:(family ^ ".Migrate.V" ^ string_of_int edge.version)
        ~previous:old ~current:fresh header) in
      let before,after = Header.seals checked in
      List.iter (fun recorded -> ignore (seal (S.verify_semantics ?stored_value_compatibility ~compiler_abi
        (seal (S.verify_sources ~project_root:root recorded))))) [before;after]) (H.completed_migrations h);
    let header = match sparse (Header.read ~file:migration.path migration.contents) with
      | Some header -> header | None -> reject migration.path "current migration is missing its recorded source seals" in
    if Header.module_name header <> family ^ ".Migrate.V" ^ string_of_int version ||
       Header.roots header <> (initial.previous_root,initial.current_root) then
      reject migration.path "MIG013: current migration metadata does not match its adjacent schema references";
    let previous_seal,_ = Header.recorded_seals header in
    let checked_previous = seal (S.verify_sources ~project_root:root previous_seal) in
    ignore (seal (S.verify_semantics ?stored_value_compatibility ~compiler_abi checked_previous));
    let initial_column_writes=retype_columns previous current migration in
    let refreshed column_writes (migration:H.migration_source) = overlay root column_writes (fun () ->
      let target_inventory=inventory (I.load_with_compatibility ~stored_value_compatibility ~compiler_abi ~root_file:current.root_file) in
      let target_seal = seal (S.create ~project_root:root target_inventory) in
      let header = sparse (Header.create ~previous:previous_seal ~current:target_seal) in
      let source = refresh_same migration.path migration.contents previous.inventory target_inventory in
       let source = refresh_entities migration.path source previous.inventory target_inventory in
       let source = refresh_jobs migration.path source previous.inventory target_inventory in
      let source=sparse (Header.replace ~file:migration.path ~source header) in
      source,decision_guidance migration.path source previous.inventory target_inventory) in
    let initial_source,initial_decisions=refreshed initial_column_writes migration in
    let column_writes,extra_writes,source,decisions=match choice with
      | None->initial_column_writes,[],initial_source,initial_decisions
      | Some choice->
        let chosen,extra=overlay root initial_column_writes(fun()->
          let after=inventory(I.load_with_compatibility ~stored_value_compatibility ~compiler_abi ~root_file:current.root_file)in
          choose_entry migration.path initial_source previous.inventory after choice)in
        let chosen_migration={migration with H.contents=chosen}in
        let columns=retype_columns previous current chosen_migration in
        let source,decisions=overlay root extra(fun()->refreshed columns chosen_migration)in columns,extra,source,decisions in
    (* A completed edge's target is also the current edge's predecessor. The
       public source checker therefore sees both seals. Check completed bodies
       against the proposed refreshed header, after their own frozen seals have
       passed above; otherwise a legitimate VCurrent edit prevents V3+ refresh. *)
    overlay root (extra_writes @ column_writes @ [migration.path,source]) (fun () ->
      List.iter (fun (edge : H.migration_source) -> check edge.path edge.contents) (H.completed_migrations h));
    let reads = List.map fst (H.source_inputs h) in
    let imports = List.concat_map (fun file ->
      let m = parse file (Source_input.read file) in
      List.filter_map (fun (i : Ast.import_decl) ->
        if String.starts_with ~prefix:"Tesl." i.module_name then None else Some (file,i.module_name)) m.imports) reads in
    let generated_imports=List.concat_map(fun(file,source)->let m=parse file source in
      List.filter_map(fun(i:Ast.import_decl)->if String.starts_with ~prefix:"Tesl." i.module_name then None else Some(file,i.module_name))m.imports)
      ((migration.path,source)::extra_writes)in
    let source_manifest = manifest (M.create ~project_root:root ~reads ~imports:(imports @ generated_imports) ~documents
      ~directories:[Filename.dirname current.root_file;Filename.dirname migration.path;Filename.chop_suffix migration.path ".tesl"] ~writes:(extra_writes @ column_writes @ [migration.path,source])) in
    let diagnostics = overlay root (M.overlays source_manifest) (fun () -> Compile.check_source migration.path source) in
    history (H.verify_unchanged h);
    manifest (M.verify_source source_manifest ~documents);
    manifest (M.verify_disk source_manifest);
    Ok {family;current_version=version;manifest=source_manifest;diagnostics;decisions}
  with
  | Invalid errors -> Error errors
  | Sys_error message | Failure message | Invalid_argument message -> Error [{path=root;message}]
  | Unix.Unix_error (error,operation,path) -> Error [{path;message=operation ^ ": " ^ Unix.error_message error}]

let refresh_with_compatibility = refresh_internal ~choice:None
let refresh_choice_with_compatibility ~choice = refresh_internal ~choice:(Some choice)
let refresh = refresh_with_compatibility ~stored_value_compatibility:None
