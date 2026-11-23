open Ast
module A = Migration_abi
module D = Migration_declaration
module E = Migration_expansion
module H = Migration_history_sources
module M = Migration_manifest
module S = Migration_sparse
module T = Migration_selection
module RH = Migration_row_history
type origin = {initial_version:int;steps:(E.step list,S.error list) result}
type queue_payload = Migration_records.queue_payload = {job:string;contract:string;contract_hash:string}
type queue_contract = Migration_records.queue_contract = {queue:string;payloads:queue_payload list}
type queue_version = Migration_records.queue_version = {version:int;storage_snapshot_hash:string;schema_snapshot_hash:string;
 source_seal_inventory:string;contracts:queue_contract list}
type queue_binding = {application_queue:string;database_identity:string;family:string;queue_identity:string;
 current_version:int;jobs:(string * string * string) list}
type database = {identity:string;family:string;namespace:string;current_version:int;origins:origin list;
 queue_versions:queue_version list}
type t = {abi:A.t;databases:database list;inputs:(string * string) list;
 queue_bindings:queue_binding list;inventories:(string * Migration_inventory.t) list;
 row_histories:(string * RH.t) list;contracts:(string * Migration_contract.t list) list;captured_modules:(module_form * string) list;validate:(unit -> unit);
 resumed:bool;records:(string * Migration_records.t) list;resumed_through:(string * int) list}
let databases t = t.databases
let contracts t = t.contracts
let queue_bindings t = t.queue_bindings
let queue_codec_records t =
 List.concat_map (fun (_,inventory) -> Migration_inventory.queue_contracts inventory |>
  List.concat_map (fun (q:Migration_inventory.queue_contract) -> q.payloads |> List.concat_map (fun payload ->
    Migration_inventory.queue_payload_codec_records inventory payload |> List.filter_map (fun declaration ->
     if declaration.Migration_inventory.declaration_kind=Migration_inventory.Record then Some declaration.qualified_name else None)))) t.inventories
 |> List.sort_uniq compare
let compiler_abi t = A.id t.abi
let stored_value_compatibility t = A.stored_value_compatibility t.abi
exception Invalid of S.error list
let reject ?(code="MIG020") loc message = raise (Invalid [{S.code;loc;message;related=[]}])
let checked = function Ok x -> x | Error es -> raise (Invalid es)
let target = function Ok x -> x | Error es -> raise (Invalid (List.map (fun (e:T.error) ->
  {S.code="MIG020";loc=e.loc;message=e.message;related=[]}) es))
let abi = function Ok x -> x | Error (e:A.error) -> reject ~code:"MIG013" (Location.dummy_loc e.path) e.message
let history = function Ok x -> x | Error (e:H.error) -> reject e.loc e.message
let guard = function Ok x -> x | Error es -> raise (Invalid (List.map (fun (e:M.error) ->
  {S.code="MIG013";loc=Location.dummy_loc e.path;message=e.message;related=[]}) es))
let protect file f = try Ok (f ()) with
 | Invalid es -> Error es
 | Sys_error message | Invalid_argument message | Failure message ->
   Error [{S.code="MIG020";loc=Location.dummy_loc file;message;related=[]}]
 | Unix.Unix_error (error,operation,path) ->
   Error [{S.code="MIG020";loc=Location.dummy_loc path;message=operation ^ ": " ^ Unix.error_message error;related=[]}]
let parse file source = match Parser.parse_module file source with
 | Ok m -> m | Err e -> reject e.loc e.msg
let candidates (modules:module_form list) =
 List.concat_map (fun (m:module_form) -> List.filter_map (function
  | DDatabase d ->
    let fields = Option.fold ~none:[] ~some:Desugar.config_record_fields d.config_expr in
    (match List.assoc_opt "schema" fields,List.assoc_opt "migrations" fields,List.assoc_opt "backend" fields with
     | Some (EConstructor {name=root;args=[];_}),Some (EConstructor {name=prefix;args=[];_}),Some backend ->
       (match Validation_common.schema_module_parts root,Migration_form.application backend with
        | Some (family,"VCurrent",[]),("Postgres",[config]) when Migration_source.valid_family family && prefix=family ^ ".Migrate" ->
          let namespace = match List.assoc_opt "namespace" (Desugar.config_record_fields config) with
           | Some (ELit {lit=LString name;_}) when name<>"" && String.length name<=63 &&
               String.is_valid_utf_8 name && not (String.contains name '\000') -> name
           | _ -> reject ~code:"MIG016" d.loc "versioned PostgreSQL builds require a static namespace fitting 63 UTF-8 bytes" in
          Some (m.module_name ^ "." ^ d.name,family,namespace,d.loc)
        | _ -> None)
     | _ -> None)
  | _ -> None) m.decls) modules |> List.sort_uniq compare
let queue_versions schemas edges = try Migration_records.queue_versions schemas edges with Migration_records.Storage_invalid es -> raise (Invalid es)
let capture_queue_bindings modules databases inventories =
 List.concat_map (fun database ->
  let inventory=List.assoc database.identity inventories in
  let owner,name= match List.rev (String.split_on_char '.' database.identity) with
   | name::owner -> String.concat "." (List.rev owner),name | _ -> assert false in
  let m=List.find (fun (m:module_form) -> m.module_name=owner) modules in
  let declaration=List.find_map (function DDatabase d when d.name=name -> Some d | _ -> None) m.decls |> Option.get in
  ignore (checked (match Migration_queue.application_bindings ~modules ~database_module:m ~database:declaration inventory with
   | [] -> Ok () | es -> Error es));
  List.concat_map (fun (m:module_form) -> List.filter_map (function
   | DQueue q ->
     let fields=Option.fold ~none:[] ~some:Desugar.config_record_fields q.config_expr in
     let resolve kind field=Option.bind (List.assoc_opt field fields) Migration_queue.constructor
       |> fun ref -> Option.bind ref (Migration_queue.visible_reference modules m kind) in
     if resolve (function DDatabase d -> Some d.name | _ -> None) "database" <> Some database.identity then None else
     let name=resolve (function DQueueSchema q -> Some q.name | _ -> None) "schema" |> Option.get in
     let queue_identity=Migration_queue.wire_identity inventory name in
     let contract=List.find (fun q -> q.queue=queue_identity) (List.hd (List.rev database.queue_versions)).contracts in
     let jobs=List.assoc "jobs" fields |> Desugar.job_entries |> List.map (fun (spelling,_,_) ->
       let name=Migration_queue.visible_reference modules m (function DRecord r -> Some r.name | _ -> None) spelling |> Option.get in
       let job=Migration_queue.wire_identity inventory name in
       let payload=List.find (fun p -> p.job=job) contract.payloads in spelling,job,payload.contract_hash) in
     Some {application_queue=m.module_name ^ "." ^ q.name;database_identity=database.identity;family=database.family;
       queue_identity;current_version=database.current_version;jobs=List.sort compare jobs}
   | _ -> None) m.decls) modules) databases |> List.sort compare
let verify_bindings expected modules = protect "<migration build>" (fun () ->
 Option.iter (fun t ->
  let paths = List.map fst t.inputs @ List.map fst (A.source_inputs t.abi) in
  List.iter (fun (m:module_form) ->
   if not (List.mem (Source_input.canonical_path m.source_file) paths) then
    reject ~code:"MIG013" (Location.dummy_loc m.source_file)
     "compilation selected an import outside its captured source history") modules) expected;
 let actual = candidates modules |> List.map (fun (identity,family,namespace,_) -> identity,family,namespace) |> List.sort compare in
 let expected_connections = Option.fold ~none:[] ~some:(fun t -> List.map (fun d -> d.identity,d.family,d.namespace) t.databases) expected |> List.sort compare in
 if actual<>expected_connections then reject ~code:"MIG013" (Location.dummy_loc "<migration build>")
  "database history bindings changed during compilation; rebuild from one source snapshot";
 Option.iter (fun t -> if capture_queue_bindings modules t.databases t.inventories <> t.queue_bindings then
  reject ~code:"MIG013" (Location.dummy_loc "<migration build>") "queue history bindings changed during compilation") expected)
let with_compilation_cache f = Parser.with_module_cache (fun () ->
 Migration_history_sources.with_cache (fun () -> Migration_inventory.with_cache (fun () ->
  Migration_analysis_cache.with_scope f)))

let capture_history ?(resume=false) ~source_only ~entry ~source f = with_compilation_cache (fun () -> protect entry.source_file (fun () ->
 let entry_file = Source_input.canonical_path entry.source_file in
 let graph = Frontend_check.build_local_import_graph ~entry entry_file in
 let modules = Hashtbl.to_seq_keys graph |> List.of_seq |> List.sort String.compare |> List.filter_map (fun file ->
   if file=entry_file then Some entry else Frontend_check.parse_module_file file) in
 let selected = candidates modules in
 if selected=[] then f None else
 let rec filesystem_root file = let parent=Filename.dirname file in if parent=file then file else filesystem_root parent in
 let input_root = Option.value (Source_input.project_root ()) ~default:(filesystem_root entry_file) in
 Source_input.with_overlays ~project_root:input_root [entry_file,source] (fun () ->
  let context = abi (A.current ()) in
  let stored_value_compatibility = A.stored_value_compatibility context in
  abi (A.with_snapshot context (fun () ->
   (* Capture every connection before interpreting any history or emitting Go.
      Imported application modules and implicit historical dependencies all belong
      to these guards; no credentials are copied into the artifact. *)
   let targets = List.map (fun (identity,family,namespace,loc) ->
    let root = target (T.infer_project_root ~entry_file ~database:(Some identity)) in
    let selected = target (T.resolve_with_compatibility ~stored_value_compatibility:(Some stored_value_compatibility)
      ~compiler_abi:(A.id context) ~project_root:root ~entry_file
      ~database:(Some identity) ~documents:[]) in
    identity,family,namespace,loc,root,selected) selected in
   let guards = List.map (fun (_,_,_,_,_,selected) -> T.source_guard selected) targets in
   let inputs = List.concat_map (fun source_guard -> guard (M.source_files source_guard)) guards |> List.sort_uniq compare in
   let integrity = List.map (fun (_,_,_,_,root,selected) ->
    checked(Migration_source_integrity.capture ~project_root:root
      ~inputs:(guard(M.source_files(T.source_guard selected))))) targets in
   let rec with_integrity captures run = match captures with
    | [] -> run()
    | capture::rest -> checked(Migration_source_integrity.with_captured capture (fun()->with_integrity rest run)) in
   let result = with_integrity integrity (fun () -> Source_input.with_pinned_files inputs (fun () ->
   let inventories = ref [] and row_histories=ref [] and contracts=ref [] and resumed_any=ref false and records=ref [] and resumed_through=ref [] in
   let databases = List.map (fun (identity,family,namespace,loc,root,selected) ->
    let h = history (H.discover_with_compatibility ~stored_value_compatibility:(Some stored_value_compatibility)
      ~compiler_abi:(A.id context) ~project_root:root ~family) in
    List.iter (fun (file,digest) ->
     if Option.map Migration_hash.digest (List.assoc_opt file inputs) <> Some digest then
      reject ~code:"MIG013" (Location.dummy_loc file) "history selected a source outside its captured compilation snapshot")
      (H.source_inputs h);
    let schemas = H.frozen h @ [H.current h] in
    let sources = H.completed_migrations h @ Option.to_list (H.current_migration h) in
    if List.length sources+1<>List.length schemas then reject ~code:"MIG001" loc "a versioned build requires complete migration history from V1";
    (* A source-only capture that asked for it continues the newest checkpoint:
       completed revisions up to it were verified by their trust seals and are
       represented by its carried state, not re-derived. Such a capture never
       publishes artifacts ([resumed] guards every emitter). *)
    let checkpoint () =
      match Migration_checkpoint.resumed ~stored_value_compatibility ~compiler_abi:(A.id context)
          ~project_root:root ~family h ~through:(H.current h).version with
      | resumed -> resumed
      | exception Migration_checkpoint.Invalid errors -> raise (Invalid errors) in
    (* A publishing source capture continues the checkpoint too when every
       completed revision up to it stored its published records for this
       namespace: those records replace the prefix in every artifact. Without
       an installation refusal the expansion origins still need the complete
       fold. *)
    let frozen = ref None in
    let resumed = if not source_only then None else if resume then checkpoint () else
      (* Records come from every checkpoint through the newest; the analysis
         resumes one revision earlier, so the newest completed revision's
         Contract is checked against a plan that contains its predecessor, as
         the current revision's Contract prerequisite requires. *)
      let completed = H.completed_migrations h in
      match Migration_checkpoint.load ~project_root:root ~family completed with
      | exception Migration_checkpoint.Invalid errors -> raise (Invalid errors)
      | Some newest when newest.checkpoint.refusal<>None ->
        (match Migration_checkpoint.load_records ~project_root:root ~family ~namespace completed newest with
         | exception Migration_checkpoint.Invalid errors -> raise (Invalid errors)
         | None -> None
         | Some records ->
           match Migration_checkpoint.resumed ~stored_value_compatibility ~gap:2 ~compiler_abi:(A.id context)
               ~project_root:root ~family h ~through:(H.current h).version with
           | exception Migration_checkpoint.Invalid errors -> raise (Invalid errors)
           | Some ((usable:Migration_checkpoint.usable),_) as resumed when usable.through=newest.through-1 && usable.checkpoint.refusal<>None ->
             frozen := Some (newest.through,records); resumed
           | _ -> None)
      | _ -> None in
    if resumed<>None && !frozen=None then resumed_any:=true;
    let schemas = match resumed with
      | None -> schemas
      | Some (usable,_) -> List.filter (fun (s:H.schema) -> s.version>=usable.through) schemas in
    let edges = match resumed with
     | Some (_,rows) ->
       let edges=RH.declarations rows in
       if List.exists (fun edge -> D.source_seals edge=None) edges then
        reject ~code:"MIG013" loc "compiled migration history requires recorded schema source seals";
       edges
     | None -> List.mapi (fun index (s:H.migration_source) ->
     let edge = match checked (D.check ~stored_value_compatibility ~compiler_abi:(A.id context) ~source:s.contents (parse s.path s.contents)) with
      | Some edge -> edge | None -> reject loc "migration declaration missing from compiled history" in
     if D.version edge<>index+2 then reject loc "compiled migration history must start at V1 and remain consecutive";
     if D.source_seals edge=None then reject ~code:"MIG013" loc "compiled migration history requires recorded schema source seals";
     edge) sources in
    inventories := (identity,H.inventory (H.current h)) :: !inventories;
    let live_queue_versions=match resumed,!frozen with
     | None,_ -> queue_versions schemas edges
     | Some _,Some (through,_) -> queue_versions (List.filter (fun (s:H.schema) -> s.version>through) schemas) edges
     | Some _,None -> queue_versions [H.current h] edges in
    let queue_versions=match !frozen with
     | Some (_,(records:Migration_records.t)) -> records.queue_versions @ live_queue_versions
     | None -> live_queue_versions in
     let inventories = List.map H.inventory schemas in
     (match List.rev inventories with
      | after::before::_ ->
       let promoted=match Migration_inventory.stage_transitions ~before ~after with
        | Ok xs -> List.filter_map(function Migration_inventory.Promote s -> Some s | _ -> None) xs
        | Error _ -> [] in
       if promoted<>[] then List.iter (fun (m:module_form) ->
        List.iter(fun (imp:import_decl) -> match Validation_common.schema_module_parts imp.module_name with
         | Some(owner,revision,_) when owner=family && revision<>"VCurrent" ->
          reject ~code:"MIG030" imp.loc "guarded promotion applications must use VCurrent; historical schemas are retained only for migration code"
         | _ -> ()) m.imports;
        let check loc entity conflict =
         let resolved=Migration_queue.visible_reference modules m (function DEntity e -> Some e.name | _ -> None) entity in
         if List.exists (fun (s:Migration_inventory.staged_index) ->
          let current=Str.global_replace (Str.regexp_string (Migration_inventory.root_module before))
           (Migration_inventory.root_module after) s.stage_entity in
          conflict=[s.stage_field] && (resolved=Some current || entity=current)) promoted then
           reject ~code:"MIG030" loc "guarded promotion exposes no onConflict/reliance before a later enforced release" in
        let inspect e=Ast_visitor.iter (fun node -> match node with
         | ESqlQuery {query=QueryUpsert q;loc} -> check loc q.entity q.conflict
         | _ -> match Validation_common.collect_call_head_and_args [] node with
          | head,entity::_record::EVar{name="onConflict";_}::EList{elems;loc}::EVar{name="doUpdate";_}::EList _::[]
           when Validation_common.function_name_of_expr head=Some "upsert" ->
            let name=match entity with EVar{name;_}|EConstructor{name;_}->name|_->"" in
            check loc name (List.filter_map(function EVar{name;_}->Some name|EField{field;_}->Some field|_->None) elems)
          | _ -> ()) e in
        List.iter(function DFunc f -> inspect f.body | DConst c -> inspect c.value
         | DTest t -> List.iter inspect (List.concat_map Ast.test_stmt_exprs t.stmts) | _ -> ()) m.decls) modules
      | _ -> ());
    if source_only || H.contracts h<>[] then begin
      let rows=match resumed with
       | Some (_,rows) -> rows
       | None -> checked((if List.exists D.queue_transition edges then RH.check_queue_expansion else RH.check) ~schemas:inventories ~edges) in
      if RH.retirements rows<>[] then
       List.iter (fun (m:module_form) ->
         (* [modules] is the application's explicit transitive import graph;
            implicit retained sources are captured separately below. A helper
            reachable from the application must not gain historical access just
            because a frozen schema also captured it. *)
         List.iter (fun (imp:import_decl) ->
          match Validation_common.schema_module_parts imp.module_name with
          | Some (owner,revision,_) when owner=family && revision<>"VCurrent" ->
            reject ~code:"MIG016" (Location.dummy_loc m.source_file)
             "table Drop requires current application handlers to use VCurrent; historical schema imports are retained only for migration code"
          | _ -> ()) m.imports) modules;
     if source_only then row_histories := (identity,rows) :: !row_histories;
     let contracts_of_capture=ref [] in
     if H.contracts h<>[] then begin
      let plan=checked(Migration_retained_storage.plan rows) in
      (* Contracts of checkpointed revisions belong to trusted frozen closures. *)
      let live=match resumed with
       | None -> H.contracts h
       | Some (usable,_) -> List.filter (fun (s:H.migration_source) -> s.version>usable.through) (H.contracts h) in
      let checked_contracts=List.map(fun (s:H.migration_source) ->
       checked(Migration_contract.check ~plan ~namespace ~file:s.path ~source:s.contents)) live in
       contracts_of_capture := checked_contracts;
       contracts := (identity,checked_contracts) :: !contracts
     end;
     (* Every published per-revision record of this capture. A resumed
        capture computes only the revisions after its checkpoint. *)
     if source_only && (resumed=None || !frozen<>None) then begin
      let plan=checked(Migration_retained_storage.plan rows) in
      let prefix,low=match !frozen with Some (through,records) -> records,through+1 | None -> Migration_records.empty,1 in
      records := (identity,Migration_records.append prefix (Migration_records.of_history ~family ~namespace ~low ~high:max_int ~rows ~plan
        ~contracts:(List.map Migration_contract.record !contracts_of_capture) ~queue_versions:live_queue_versions)) :: !records;
      Option.iter (fun (through,_) -> resumed_through := (identity,through) :: !resumed_through) !frozen
     end
     ;if List.exists (fun inventory -> Migration_inventory.staged_indexes inventory<>[]) inventories then begin
      (* Only staged histories can introduce enforced reliance. Ordinary histories
         retain their public physical emitter's validation and diagnostic path. *)
      let plan=checked(Migration_retained_storage.plan rows) in
      List.iter(fun(v:Migration_retained_storage.version)->match v.reliance with
       | None->()|Some(prior,_)->if not(List.exists(fun c->Migration_contract.version c=prior)(Option.value(List.assoc_opt identity !contracts)~default:[])) then
        reject ~code:"MIG030" loc "unique reliance requires the exact reviewed prior PromoteStage Contract source") (Migration_retained_storage.versions plan)
     end
    end;
    (* Full-history mode recomputes every recorded checkpoint from the complete
       fold and refuses one that differs (a stale or edited checkpoint). *)
    if Migration_trust.full_history () && resumed=None && Migration_checkpoint.recorded (H.completed_migrations h) then begin
      let rows=checked((if List.exists D.queue_transition edges then RH.check_queue_expansion else RH.check) ~schemas:inventories ~edges) in
      let plan=checked(Migration_retained_storage.plan rows) in
      (* Stored records are recomputed from the same complete fold. *)
      let contracts=lazy (List.map (fun (s:H.migration_source) ->
        let c=checked(Migration_contract.check ~plan ~namespace ~file:s.path ~source:s.contents) in
        Migration_contract.record c,Migration_contract.view c) (H.contracts h)) in
      let derive through=Migration_checkpoint.records_for ~family ~namespace ~through ~rows ~plan
        ~contracts:(Lazy.force contracts) ~queue_versions in
      match Migration_checkpoint.verify_all ~project_root:root ~family ~compiler_abi:(A.id context)
          ~stored_value_compatibility ~rows ~plan ~records:(namespace,derive) (H.completed_migrations h) with
      | () -> ()
      | exception Migration_checkpoint.Invalid errors -> raise (Invalid errors)
    end;
    let generated = match resumed with
     | Some (usable,_) ->
       Option.bind usable.checkpoint.refusal (fun refusal ->
         E.resumed_origins ~refusal ~through:usable.through ~schemas:inventories ~edges) |> Option.value ~default:[]
     | None -> match E.generate_origins ~schemas:inventories ~edges with
     | [] -> [E.generate ~initial_version:1 ~schemas:inventories ~edges]
     | generated -> generated in
    if not source_only then ignore (checked (List.hd generated));
    let origins = List.mapi (fun index steps -> {initial_version=index+1;steps}) generated in
    history (H.verify_unchanged h);
    {identity;family;namespace;current_version=(T.selection selected).current_version;origins;queue_versions}) targets in
   let inventories= !inventories in
   let queue_bindings=capture_queue_bindings modules databases inventories in
   let row_histories=List.sort compare !row_histories in
   let linked_sources=List.concat_map (fun (_,rows) -> RH.captured_sources rows) row_histories in
   let captured_modules=if not source_only then [] else List.map (fun (path,bytes) ->
     match List.find_opt (fun (m,_) -> Source_input.canonical_path m.source_file=path) linked_sources with
     | Some (m,captured) when captured=bytes -> m,bytes
     | Some _ -> reject ~code:"MIG013" (Location.dummy_loc path) "linked module differs from captured history"
     | None -> (if path=entry_file then entry else parse path bytes),bytes) inputs in
   (* Lifted Go modules belong to the ABI snapshot, not the application's
      filesystem manifest. Select their bytes from that token before lowering;
      never recollect a mutable resolver result as emitted authority. *)
   let rec with_lifted captured pending seen = match pending with
    | [] -> captured
    | (m,_)::rest ->
      let additions,seen=List.fold_left (fun (additions,seen) (import:import_decl) ->
       if not(List.mem import.module_name Frontend_check.go_lifted_module_names) ||
          List.mem import.module_name seen then additions,seen else
       match A.lifted_source context import.module_name with
       | None -> reject ~code:"MIG013" (Location.dummy_loc m.source_file)
          "required Go stdlib module is absent from the captured compiler ABI"
       | Some(path,bytes) -> (parse path bytes,bytes)::additions,import.module_name::seen)
        ([],seen) m.imports in
      with_lifted (captured @ List.rev additions) (rest @ List.rev additions) seen in
   let captured_modules=with_lifted captured_modules captured_modules [] in
   let validate () =
    abi (A.verify context);
    List.iter(fun capture->ignore(checked(Migration_source_integrity.revalidate capture))) integrity;
    Source_input.without_pinned_files (fun () -> List.iter (fun source_guard -> guard (M.verify_source source_guard ~documents:[]);guard (M.verify_disk source_guard)) guards);
    List.iter (fun (_,rows) -> ignore (checked (RH.revalidate rows))) row_histories in
   let value={abi=context;databases;inputs;queue_bindings;inventories;row_histories;contracts=List.sort compare !contracts;captured_modules;validate;
     resumed= !resumed_any;records= !records;resumed_through= !resumed_through} in
   let result=f (Some value) in
   List.iter (fun (_,rows) -> ignore (checked (RH.revalidate rows))) row_histories;
   result)) in
   List.iter (fun source_guard -> guard (M.verify_source source_guard ~documents:[]);guard (M.verify_disk source_guard)) guards;
   result)))))

let unresumed t =
 if t.resumed then invalid_arg "a checkpoint-resumed history capture cannot publish complete history artifacts"
let resumed t = t.resumed
let to_json ~quote t =
 unresumed t;
 let array f xs = "[" ^ String.concat "," (List.map f xs) ^ "]" in
 let error (e:S.error) = Printf.sprintf {|{"code":%s,"message":%s}|} (quote e.code) (quote e.message) in
 let origin o = match o.steps with
  | Ok steps -> Printf.sprintf {|{"initialVersion":%d,"steps":%s,"errors":[]}|}
     o.initial_version (array (E.step_to_json ~include_catalog:false ~quote) steps)
  | Error es -> Printf.sprintf {|{"initialVersion":%d,"steps":null,"errors":%s}|} o.initial_version (array error es) in
 let database d = Printf.sprintf {|{"database":%s,"family":%s,"namespace":%s,"currentVersion":%d,"origins":%s}|}
  (quote d.identity) (quote d.family) (quote d.namespace) d.current_version (array origin d.origins) in
 Printf.sprintf {|{"version":3,"kind":"compiled-migration-history","compilerAbi":%s,"storedValueCompatibility":%s,"databases":%s}|}
  (quote (compiler_abi t)) (quote (stored_value_compatibility t)) (array database t.databases)

(** Companion wire keeps the strict expansion envelope bridge-compatible. No
    field here asserts that an installed baseline was inventoried or adopted. *)
let queues_to_json ~quote t =
 unresumed t;
 let array f xs="[" ^ String.concat "," (List.map f xs) ^ "]" in
 let version=Migration_records.queue_version_json ~quote in
  let has_transitions=List.exists(fun(_,rows)->List.exists D.queue_transition (RH.declarations rows))t.row_histories in
  let database d=
  let origin o=Printf.sprintf {|{"initialVersion":%d,"versions":%s}|} o.initial_version
   (array string_of_int (List.init (d.current_version-o.initial_version+1) (fun i -> o.initial_version+i))) in
   let transitions=if not has_transitions then "" else
    let nodes=match List.assoc_opt d.identity t.row_histories with
     | None -> []
     | Some rows -> let plan=checked(Migration_retained_storage.plan rows) in
       Migration_retained_storage.versions plan |> List.filter(fun v->List.exists(fun edge->D.version edge=v.Migration_retained_storage.version && D.queue_transition edge)(RH.declarations rows))
       |> List.map(fun v->let doc,hash=RH.contract Migration_canonical.Migration (Migration_retained_storage_canonical.version_node ~family:d.family ~namespace:d.namespace plan v) in
         Printf.sprintf {|{"contract":%s,"hash":%s}|}(quote doc)(quote hash)) in
    ",\"transitions\":[" ^ String.concat "," nodes ^ "]" in
   Printf.sprintf {|{"database":%s,"family":%s,"namespace":%s,"currentVersion":%d,"versions":%s,"origins":%s%s}|}
    (quote d.identity) (quote d.family) (quote d.namespace) d.current_version (array version d.queue_versions) (array origin d.origins) transitions in
  Printf.sprintf {|{"version":%d,"kind":"compiled-queue-history","compilerAbi":%s,"storedValueCompatibility":%s,"databases":%s}|}
   (if has_transitions then 2 else 1) (quote (compiler_abi t)) (quote (stored_value_compatibility t)) (array database t.databases)


let with_history ~entry ~source f = capture_history ~source_only:false ~entry ~source f

type source_history = {program:t;active:bool ref;lowering:(Go_graph_lowering.t,string) result Lazy.t}
let with_source_history ?resume ~entry ~source f =
 capture_history ?resume ~source_only:true ~entry ~source (function
  | None -> f None
  | Some program ->
   let history={program;active=ref true;lowering=lazy(Go_graph_lowering.lower ~entry (List.map fst program.captured_modules))} in
   Fun.protect ~finally:(fun () -> history.active:=false) (fun () -> f (Some history)))
let source_program source = source.program
let source_modules source = source.program.captured_modules
let resumed_through source identity = List.assoc_opt identity source.program.resumed_through
let records source identity = match List.assoc_opt identity source.program.records with
 | Some records -> records
 | None -> invalid_arg "history records are captured only for source histories" 
let row_histories source = source.program.row_histories
let source_lowering source = protect "<row source artifacts>" (fun () ->
 if not !(source.active) then reject ~code:"MIG013" (Location.dummy_loc "<row source artifacts>")
  "source-history artifact authority escaped its guarded capture scope";
 source.program.validate ();
 match Lazy.force source.lowering with Ok graph -> graph | Error message ->
 reject ~code:"MIG013" (Location.dummy_loc "<row source artifacts>") message)
let verify_source_history source modules = protect "<row source artifacts>" (fun () ->
 let graph=checked(source_lowering source) in
 let expected=Go_graph_lowering.modules graph in
 let order=List.sort (fun a b -> compare a.source_file b.source_file) in
 if order expected <> order modules then reject ~code:"MIG013" (Location.dummy_loc "<row source artifacts>")
  "row artifact graph differs from the complete captured and lowered source graph")
