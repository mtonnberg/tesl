module A = Migration_abi
module T = Migration_target
module M = Migration_manifest
type operation = Start | Refresh | Contract
type error = {loc:Location.loc;message:string;candidates:T.candidate list}
type cleanup = {version:int;file:string;present:bool}
type t = {operation:operation;selection:T.selection;revision_after:int;abi:A.t;
          manifest:M.t;diagnostics:Compile.diagnostic list;decisions:Migration_generate.decision list;
          cleanup:cleanup list;contract_version:int option}
let operation p = p.operation
let selection p = p.selection
let revision_after p = p.revision_after
let compiler_abi p = A.id p.abi
let operation_name = function Start->"start" | Refresh->"refresh" | Contract->"contract"
let input_digest p =
  let s=p.selection in
  Migration_hash.digest(Migration_canonical.encode(Migration_canonical.Seq(
    List.map(fun x->Migration_canonical.Bytes x)
      ["tesl-migration-choice-input-v1";compiler_abi p;M.digest p.manifest;operation_name p.operation;
       s.entry_file;s.database_file;s.database_name;s.family;s.schema_root;
       Option.fold ~none:"none" ~some:string_of_int s.previous_version;
       string_of_int s.current_version;string_of_int p.revision_after])))
let manifest p = p.manifest
let diagnostics p = p.diagnostics
let compilable p = not (List.exists (fun (d : Compile.diagnostic) -> d.severity="error") p.diagnostics)
exception Invalid of error list
let abi = function Ok x -> x | Error (e : A.error) ->
  raise (Invalid [{loc=Location.dummy_loc e.path;message=e.message;candidates=[]}])
let target = function Ok x -> x | Error errors ->
  raise (Invalid (List.map (fun (e : T.error) -> {loc=e.loc;message=e.message;candidates=e.candidates}) errors))
let source_guard = function Ok x -> x | Error errors ->
  raise (Invalid (List.map (fun (e : M.error) -> {loc=Location.dummy_loc e.path;message=e.message;candidates=[]}) errors))
let protect file f = try Ok (f ()) with
  | Invalid errors -> Error errors
  | Sys_error message | Invalid_argument message | Failure message -> Error [{loc=Location.dummy_loc file;message;candidates=[]}]
   | Unix.Unix_error (error,operation,path) -> Error [{loc=Location.dummy_loc path;message=operation ^ ": " ^ Unix.error_message error;candidates=[]}]
let cleanup_for (selection:T.selection) diagnostics =
 if List.exists(fun(d:Compile.diagnostic)->d.severity="error")diagnostics then [],diagnostics else
 let source=Source_input.read selection.entry_file in
 match Parser.parse_module selection.entry_file source with
 | Err _->[],diagnostics
 | Ok entry->
   let result=Migration_program.with_source_history ~entry ~source(function
    | None->Ok []
    | Some history->match List.assoc_opt selection.database_name(Migration_program.row_histories history)with
      | None->Ok []
      | Some rows->Result.map(fun plan->Migration_retained_storage.versions plan |>List.filter_map(fun(v:Migration_retained_storage.version)->
        if v.windows=[] && v.retirements=[] && v.promotions=[]then None else
        let file=Filename.concat selection.migration_directory(Printf.sprintf "v%d-contract.tesl" v.version)in
        Some{version=v.version;file;present=Source_input.exists file})) (Migration_retained_storage.plan rows)) |> Result.join in
   match result with Ok cleanup->cleanup,diagnostics|Error errors->[],diagnostics @ Migration_declaration.diagnostics_of_errors errors
let verify p ~documents = protect p.selection.entry_file (fun () ->
  abi (A.verify p.abi);
  source_guard (M.verify_source p.manifest ~documents);
  source_guard (M.verify_disk p.manifest))
let generate ~project_root ~entry_file ~database ~new_revision ~documents = protect entry_file (fun () ->
  let context = abi (A.current ()) in
  let preview = abi (A.with_snapshot context (fun () ->
    let target_ = target (T.resolve_with_compatibility
      ~stored_value_compatibility:(Some (A.stored_value_compatibility context))
      ~compiler_abi:(A.id context) ~project_root ~entry_file ~database ~documents) in
     let selected = T.selection target_ in
     if new_revision && selected.current_version>1 then begin
       let cleanup,errors=cleanup_for selected [] in
       (match errors with
        | first::_ -> raise(Invalid[{loc=Location.make_loc first.file first.start_line first.start_col first.end_line first.end_col;message=first.message;candidates=[]}])
        | [] -> ());
       match List.find_opt(fun item->not item.present)cleanup with
       | Some item->raise(Invalid[{loc=Location.dummy_loc item.file;
           message=(if item.version=selected.current_version then
             Printf.sprintf "Prepare the cleanup source for V%d before freezing another revision. Continue the existing draft and review cleanup, or run tesl migrate contract %s --version %d." item.version entry_file item.version
             else Printf.sprintf "Frozen revision V%d is missing cleanup source. Restore the last undeployed state where that revision was current and prepare its cleanup before freezing it; do not amend deployed history." item.version);candidates=[]}])
       | None->()
     end;
    let operation,revision_after,manifest,decisions =
      if new_revision || selected.current_version=1 then
        let p = target (T.start target_ ~documents) in Start,p.current_version,p.manifest,[]
      else
        let p = target (T.refresh target_ ~documents) in Refresh,p.current_version,p.manifest,p.decisions in
    let cleanup,diagnostics = Source_input.with_overlays
      ~project_root:(Option.value (Source_input.project_root ()) ~default:project_root)
      (M.overlays manifest) (fun () -> cleanup_for selected (Compile.check_source entry_file (Source_input.read entry_file))) in
    {operation;selection=selected;revision_after;abi=context;manifest;diagnostics;decisions;cleanup;contract_version=None})) in
  (match verify preview ~documents with Ok () -> () | Error errors -> raise (Invalid errors));
  preview)
let generate_choice ~project_root ~entry_file ~database ~documents ~decision ~option_ ~expected_input_digest =
 protect entry_file(fun()->
  let reviewed=match generate ~project_root ~entry_file ~database ~new_revision:false ~documents with
    | Ok p->p | Error errors->raise(Invalid errors)in
  if reviewed.operation<>Refresh then raise(Invalid[{loc=Location.dummy_loc entry_file;
    message="a migration choice requires an existing current revision; prepare it and obtain a fresh preview";candidates=[]}]);
  if input_digest reviewed<>expected_input_digest then raise(Invalid[{loc=Location.dummy_loc entry_file;
    message="the reviewed migration preview is stale; source, documents, discovery or compiler inputs changed; obtain a fresh preview";candidates=[]}]);
  (match verify reviewed ~documents with Ok()->()|Error errors->raise(Invalid errors));
  let chosen=abi(A.with_snapshot reviewed.abi(fun()->
    let selected=target(T.resolve_with_compatibility
      ~stored_value_compatibility:(Some(A.stored_value_compatibility reviewed.abi))
      ~compiler_abi:(compiler_abi reviewed) ~project_root ~entry_file ~database ~documents)in
    let selection=T.selection selected in
    if selection<>reviewed.selection then raise(Invalid[{loc=Location.dummy_loc entry_file;
      message="migration selection changed since review; obtain a fresh preview";candidates=[]}]);
    let choice={Migration_generate.decision_id=decision;option_id=option_}in
    let p=target(T.refresh_choice selected ~choice ~documents)in
    let cleanup,diagnostics=Source_input.with_overlays
      ~project_root:(Option.value(Source_input.project_root())~default:project_root)
      (M.overlays p.manifest)(fun()->cleanup_for selection (Compile.check_source entry_file(Source_input.read entry_file)))in
    {operation=Refresh;selection;revision_after=p.current_version;abi=reviewed.abi;
      manifest=p.manifest;diagnostics;decisions=p.decisions;cleanup;contract_version=None}))in
  (match verify reviewed ~documents with Ok()->()|Error errors->raise(Invalid errors));
  (match verify chosen ~documents with Ok()->()|Error errors->raise(Invalid errors));chosen)
let generate_contract ~project_root ~entry_file ~database ~version ~documents = protect entry_file (fun () ->
 let context=abi(A.current()) in
 let checked = function Ok value -> value | Error errors ->
  raise(Invalid(List.map(fun(e:Migration_sparse.error)->{loc=e.loc;message=e.message;candidates=[]})errors)) in
 let result=abi(A.with_snapshot context(fun () ->
  let target_=target(T.resolve_with_compatibility
   ~stored_value_compatibility:(Some(A.stored_value_compatibility context)) ~compiler_abi:(A.id context)
   ~project_root ~entry_file ~database ~documents) in
  let selection=T.selection target_ in
  if version<2 || version>selection.current_version then raise(Invalid[{loc=Location.dummy_loc entry_file;message="contract version must name an existing transforming migration";candidates=[]}]);
  let file=Filename.concat selection.migration_directory (Printf.sprintf "v%d-contract.tesl" version) in
  (match Source_input.kind file with
   | _ -> raise(Invalid[{loc=Location.dummy_loc file;message="contract source already exists; review the existing file; generating a contract never replaces reviewed authority";candidates=[]}])
   | exception Unix.Unix_error(Unix.ENOENT,_,_) -> ());
  let source=Source_input.read entry_file in
  let entry=match Parser.parse_module entry_file source with Ok m -> m | Err e -> raise(Invalid[{loc=e.loc;message=e.msg;candidates=[]}]) in
  let contents=checked(Migration_program.with_source_history ~entry ~source(function
   | None -> raise(Invalid[{loc=Location.dummy_loc entry_file;message="contract generation requires a PostgreSQL database history";candidates=[]}])
   | Some history ->
     let rows=match List.assoc_opt selection.database_name (Migration_program.row_histories history) with
      | Some rows -> rows | None -> raise(Invalid[{loc=Location.dummy_loc entry_file;message="selected database does not own a PostgreSQL row history";candidates=[]}]) in
     checked(Migration_contract.source ~plan:(checked(Migration_retained_storage.plan rows)) ~version))) in
  let edits=source_guard(M.create ~project_root ~reads:[] ~directories:[selection.migration_directory]
    ~imports:[] ~documents ~writes:[file,contents]) in
  let manifest=source_guard(M.combine (T.source_guard target_) edits ~documents) in
   let cleanup,diagnostics=Source_input.with_overlays ~project_root:(Option.value(Source_input.project_root())~default:project_root)
    (M.overlays manifest) (fun () -> cleanup_for selection (Compile.check_source entry_file (Source_input.read entry_file))) in
   (match List.find_opt(fun(d:Compile.diagnostic)->d.severity="error")diagnostics with
    | Some d->raise(Invalid[{loc=Location.make_loc d.file d.start_line d.start_col d.end_line d.end_col;message=d.message;candidates=[]}])
    | None->());
   {operation=Contract;selection;revision_after=selection.current_version;abi=context;manifest;diagnostics;decisions=[];cleanup;contract_version=Some version})) in
 (match verify result ~documents with Ok () -> () | Error errors -> raise(Invalid errors));result)
let quote = Compile.json_encode_string
let option_int = function None -> "null" | Some n -> string_of_int n
let to_json p =
  let s = p.selection in
  let option (o:Migration_generate.decision_option) = Printf.sprintf
    {|{"id":%s,"label":%s,"template":%s,"help":%s,"needsCustomCode":%b}|}
    (quote o.id) (quote o.label) (quote o.template) (quote o.help) o.needs_custom_code in
  let decision (d:Migration_generate.decision) = Printf.sprintf
    {|{"id":%s,"entity":%s,"file":%s,"line":%d,"col":%d,"reason":%s,"options":[%s]}|}
    (quote d.id) (quote d.entity) (quote d.file) d.line d.col (quote d.reason)
    (String.concat "," (List.map option d.options)) in
  Printf.sprintf {|{"version":1,"kind":"migration-source-preview","ok":true,"operation":%s,"compilerAbi":%s,"inputDigest":%s,"compilable":%b,"selection":{"entryFile":%s,"databaseFile":%s,"database":%s,"family":%s,"schemaRoot":%s,"previousVersion":%s,"revisionBefore":%d,"revisionAfter":%d},"diagnostics":%s,"decisions":[%s],"manifest":%s,"contractVersion":%s,"cleanup":[%s]}|}
    (quote (match p.operation with Start -> "start" | Refresh -> "refresh" | Contract -> "contract"))
    (quote (compiler_abi p)) (quote(input_digest p)) (compilable p) (quote s.entry_file) (quote s.database_file)
    (quote s.database_name) (quote s.family) (quote s.schema_root) (option_int s.previous_version)
    s.current_version p.revision_after (Compile.diagnostics_to_json p.diagnostics)
    (String.concat "," (List.map decision p.decisions)) (M.to_json p.manifest) (option_int p.contract_version)
    (String.concat ","(List.map(fun item->Printf.sprintf {|{"version":%d,"file":%s,"present":%b}|} item.version (quote item.file) item.present)p.cleanup))
let errors_to_json errors =
  let candidate (c : T.candidate) = Printf.sprintf {|{"database":%s,"file":%s}|} (quote c.database_name) (quote c.database_file) in
  let error (e : error) = Printf.sprintf {|{"file":%s,"line":%d,"col":%d,"message":%s,"candidates":[%s]%s}|}
    (quote e.loc.file) e.loc.start.line e.loc.start.col (quote e.message)
    (String.concat "," (List.map candidate e.candidates))
    (if String.starts_with ~prefix:"Prepare the cleanup source for V" e.message then {|,"action":"review-cleanup"|}else "") in
  {|{"version":1,"kind":"migration-source-preview","ok":false,"errors":[|} ^
    String.concat "," (List.map error errors) ^ {|],"manifest":null}|}
