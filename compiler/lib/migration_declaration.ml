(** Contextual checking of the initial additive Migration source form. The result
    describes logical values; it grants no persisted-proof, DDL or execution authority. *)
open Ast
module S = Migration_sparse
module I = Migration_inventory
module H = Migration_history_sources
module A = Migration_additive
module R = Migration_transform_rules
module T = Migration_transform

type t = { coverage : S.t; additive : A.t; transforms : T.t option; queue_transforms : Migration_queue_transform.t list; version : int; source_seals : Migration_header.checked option }
type prepared = { pcoverage : S.t; padditive : A.t; ptransforms : T.prepared option;
   pversion : int; pseals : Migration_header.checked option; pgraph : T.captured;
   pqueue_transforms : Migration_queue_transform.t list; pproject_root : string }
let coverage t = t.coverage
let additive t = t.additive
let transforms t = t.transforms
let queue_transforms t = t.queue_transforms
let version t = t.version
let source_seals t = t.source_seals
exception Invalid of S.error list
let reject code loc message = raise (Invalid [{S.code;loc;message;related=[]}])
let checked = function Ok value -> value | Error errors -> raise (Invalid errors)
let at = Checker.expr_loc
let application = Migration_form.application

let root_version (m : module_form) =
  match Validation_common.schema_module_parts m.module_name with
  | Some (family,"Migrate",[revision]) when Migration_source.valid_family family &&
        Migration_source.valid_revision revision && revision <> "VCurrent" ->
    Some (family, int_of_string (String.sub revision 1 (String.length revision - 1)))
  | _ -> None

let record code expression = match expression with
  | ERecord {fields;type_hint=None;_} ->
    let seen = Hashtbl.create 8 in
    List.iter (fun (name,value) ->
      if Hashtbl.mem seen name then reject code (at value) ("duplicate record field `" ^ name ^ "`");
      Hashtbl.add seen name ()) fields;
    fields
  | _ -> reject code (at expression) "expected a literal record"
let list code expression = match expression with
  | EList {elems;_} -> elems
  | _ -> reject code (at expression) "expected a literal list"
let reference code expression = match expression with
  | EConstructor {name;args=[];_} -> name
  | EField {obj=EConstructor {name;args=[];_};field;_} -> name ^ "." ^ field
  | _ -> reject code (at expression) "expected a qualified schema declaration reference"
let field_name expression = match expression with
  | EVar {name;_} -> name
  | _ -> reject "MIG022" (at expression) "a rule must name a bare field of its entity"
let literal (m : module_form) expression =
  let boolean_constructor name loc =
    let local = List.exists (function
      | DType (TypeAdt {variants;_}) -> List.exists (fun (v : adt_variant) -> v.ctor = name) variants
      | DType (TypeNewtype {name=declared;_}) -> name = declared
      | _ -> false) m.decls in
    if local || List.mem_assoc name (Checker.load_imported_ctors m) then
      reject "MIG022" loc ("`" ^ name ^ "` resolves to a user constructor, not a primitive Bool literal");
    A.Boolean (name = "True") in
  let rec read = function
    | ELit {lit=LInt value;_} -> A.Integer (string_of_int value)
    | ELit {lit=LBigInt value;_} -> A.Integer value
    | ELit {lit=LFloat value;_} -> A.Floating value
    | ELit {lit=LBool value;_} -> A.Boolean value
    | ELit {lit=LString value;_} -> A.Text value
    | EConstructor {name=("True" | "False") as name;args=[];loc}
        when Frontend_check.has_prelude_bool_ctor_import m -> boolean_constructor name loc
    | EUnop {op=UNeg;arg=(ELit {lit=(LInt _ | LBigInt _ | LFloat _);_} as arg);_} ->
      (match read arg with
       | A.Integer value -> A.Integer ("-" ^ value)
       | A.Floating value -> A.Floating (-. value)
       | _ -> assert false)
    | other -> reject "MIG022" (at other) "Default requires a primitive literal of the new field's exact type" in
  read expression

let identities before after expressions =
  List.concat_map (fun expression ->
    match application expression with
    | "Same", [left;right] ->
      let previous = reference "MIG024" left and current = reference "MIG024" right in
      let eligible inventory name = I.declarations inventory |> List.filter (fun (d : I.declaration) ->
        d.qualified_name = name && match d.declaration_kind with
        | I.Newtype | I.Adt | I.Record | I.Fact | I.Codec_declaration | I.Queue_schema -> true
        | I.Entity | I.Function -> false) in
      let old = eligible before previous and fresh = eligible after current in
      let namespaces declarations = List.map (fun (d : I.declaration) -> d.namespace) declarations |> List.sort_uniq compare in
      (* A record and its codec commonly share one spelling. The claim covers
         every eligible namespace with that spelling, never an arbitrary first
         lookup hit. Each namespace is still independently checked by Sparse. *)
      if old = [] || namespaces old <> namespaces fresh then
        reject "MIG024" (at expression)
          "Same must pair matching owned type/fact/codec/queueSchema declarations from the previous and current schemas";
      List.map (fun (d : I.declaration) ->
        {S.previous=(d.namespace,previous);current=(d.namespace,current);loc=at expression}) old
    | _ -> reject "MIG024" (at expression) "expected `Same From.Declaration To.Declaration`") expressions

type syntax = {
  declaration : const_form;
  family : string;
  target : int;
  fields : (string * expr) list;
  previous_expr : expr;
  current_expr : expr;
  previous_root : string;
  current_root : string;
  same : expr;
  entities : expr;
}

let read_syntax (m : module_form) =
  try
    let declarations = List.filter_map (function
      | DConst c when Migration_form.is_declaration m c -> Some c | _ -> None) m.decls in
    match declarations with
    | [] ->
      if root_version m <> None then reject "MIG020" (Location.dummy_loc m.source_file)
        "a Migrate.V<n> root requires exactly one `migration = Migration { ... }` declaration; put standalone pure helpers and tests in a helper module";
      Ok None
    | _ :: duplicate :: _ -> reject "MIG020" duplicate.loc "a migration module owns exactly one Migration declaration"
    | [declaration] ->
      if declaration.name <> "migration" then reject "MIG020" declaration.loc "name the folded Migration declaration `migration`";
      Ast_visitor.iter (fun expression ->
        let name = match expression with
          | EConstructor {name;_} | ERecord {type_hint=Some name;_} -> Some name
          | _ -> None in
        match name with
        | Some name when List.mem name Migration_form.names && not (Migration_form.imported_name m name) ->
          reject "T001" (at expression) ("`" ^ name ^ "` is not exposed by the Tesl.Migration import; name the constructor explicitly or expose its owning type with (..)")
        | _ -> ()) declaration.value;
      let family, target = match root_version m with
        | Some pair -> pair
        | None -> reject "MIG020" declaration.loc "Migration belongs in its family's Migrate.V<n> root module" in
      let fields = match application declaration.value with
        | "Migration", [expression] -> record "MIG020" expression
        | _ -> reject "MIG020" declaration.loc "expected `migration = Migration { from, to, same, entities }`" in
      List.iter (fun (name,value) -> if not (List.mem name ["from";"to";"same";"entities";"fixtures";"jobs"]) then
        reject "MIG020" (at value) ("unknown Migration field `" ^ name ^ "`")) fields;
      let required name = match List.assoc_opt name fields with
        | Some value -> value
        | None -> reject "MIG020" declaration.loc ("Migration requires `" ^ name ^ "`" ) in
      let previous_expr = required "from" and current_expr = required "to" in
      let previous_root = reference "MIG020" previous_expr and current_root = reference "MIG020" current_expr in
      List.iter (fun (root,expression) ->
        if not (List.exists (fun (i : import_decl) -> i.module_name = root) m.imports) then
          reject "MIG020" (at expression) ("import the schema root `" ^ root ^ "` directly"))
        [previous_root,previous_expr;current_root,current_expr];
      let same = required "same" and entities = required "entities" in
      Ok (Some {declaration;family;target;fields;previous_expr;current_expr;
        previous_root;current_root;same;entities})
  with Invalid errors -> Error errors

let identity_claims ~before ~after syntax =
  try Ok (identities before after (list "MIG024" syntax.same)) with Invalid errors -> Error errors

let entry_holes expression =
  let holes = ref [] in
  Ast_visitor.iter (function
    | EApp {fn=EVar {name="todo";_};arg=ELit {lit=LString reason;_};loc} ->
      holes := {S.code="MIG003";loc;message="unresolved migration decision: " ^ reason;related=[]} :: !holes
    | _ -> ()) expression;
  List.rev !holes

(* Source checking of explicit job decisions is independent of executable
   application history. The Program/Go boundaries still refuse these edges
   until protected conversion and repair registration exists. *)
let prepare_queue_decisions ~project_root ~before ~after ~previous_file ~current_file
    ~version ~graph ~root ~fixtures jobs =
  match jobs with
  | None ->
    let errors=Migration_queue.changes ~before ~after in
    if errors<>[] then raise(Invalid errors);
    [],fixtures
  | Some expression ->
    let holes=entry_holes expression in
    if holes<>[] then raise(Invalid holes);
    let entries=record "MIG028" expression in
    let payloads inventory = I.queue_contracts inventory |> List.concat_map(fun q ->
      List.map(fun p -> Migration_queue.wire_identity inventory p.I.payload_name,
        (Migration_queue.wire_identity inventory q.I.queue_name,p))q.payloads) in
    let old=payloads before and fresh=payloads after in
    List.iter(fun q ->
      let identity=Migration_queue.wire_identity before q.I.queue_name in
      if not(List.exists(fun current -> Migration_queue.wire_identity after current.I.queue_name=identity)(I.queue_contracts after)) then
        reject "MIG028" q.queue_loc "jobs: does not yet support queue removal or renaming") (I.queue_contracts before);
    let selected=Hashtbl.create 8 in
    List.iter(fun(name,value)->
      let matches=List.filter(fun(identity,(_,payload))->
        let short=List.hd(List.rev(String.split_on_char '.' identity)) in
        List.mem name [identity;short;payload.I.payload_name;I.root_module after ^ "." ^ identity])old in
      match matches with
      | [identity,_] ->
        if Hashtbl.mem selected identity then reject "MIG023" (at value) "duplicate queue payload decision";
        Hashtbl.add selected identity value
      | _ -> reject "MIG028" (at value) "jobs: must name one exact previous payload; qualify ambiguous names") entries;
    let modules=List.map fst(T.captured_source_texts graph) in
    let fixture_bindings=checked(T.bind_pure_functions modules root fixtures) in
    let used=Hashtbl.create 8 in
    let context=match Migration_abi.current() with Ok c->c|Error e->reject "MIG013" (Location.dummy_loc e.path) e.message in
    let load path=match I.load_with_compatibility ~compiler_abi:(Migration_abi.id context)
      ~stored_value_compatibility:(Some(Migration_abi.stored_value_compatibility context)) ~root_file:path with
      | Ok i->i|Error e->reject "MIG028" e.loc e.message in
    let before_checked=lazy(load previous_file) and after_checked=lazy(load current_file) in
    let decisions=List.filter_map(fun(identity,(queue,(previous:I.queue_payload)))->
      match List.assoc_opt identity fresh with
      | None -> reject "MIG028" previous.payload_loc "jobs: does not yet support payload removal or renaming"
      | Some(current_queue,current) when current_queue<>queue ->
        reject "MIG028" current.payload_loc "jobs: cannot move a payload between queues"
      | Some(_,current) ->
        match Hashtbl.find_opt selected identity with
        | None when previous.payload_contract=current.payload_contract -> None
        | None -> reject "MIG028" current.payload_loc ("changed queue payload `" ^ identity ^ "` requires an explicit jobs: Migrate decision")
        | Some value when previous.payload_contract=current.payload_contract ->
          reject "MIG028" (at value) "unchanged queue payloads must not carry a conversion"
        | Some value ->
          let callback=match application value with
            | "Migrate",[callback] -> callback
            | _ -> reject "MIG028" (at value) "jobs: currently expects Migrate followed by a typed conversion function" in
          let binding=List.hd(checked(T.bind_pure_functions modules root [callback])) in
          if binding.owner.module_name=root.module_name then reject "MIG028" (at callback)
            "queue conversion callbacks currently belong in a pure migration helper module";
          let selected_fixtures=List.filter_map(fun(expr,(f:T.function_binding))->
            match f.declaration.return_spec with
            | RetPlain result when f.declaration.params=[] && Option.is_some(T.fixture_type modules f.owner previous.payload_name result.ty) ->
              Hashtbl.replace used f.identity ();
              Some(EVar{name=f.identity;loc=at expr})
            | _ -> None) (List.combine fixtures fixture_bindings) in
          let source=snd(List.find(fun(owner,_)->owner==binding.owner)(T.captured_source_texts graph)) in
          Some(checked(Migration_queue_transform.check ~project_root
            ~before:(Lazy.force before_checked) ~after:(Lazy.force after_checked) ~version ~queue ~job:identity
            ~source binding.owner ~callback:(EVar{name=binding.declaration.name;loc=at callback}) ~fixtures:selected_fixtures))) old in
    let remaining=List.combine fixtures fixture_bindings |> List.filter_map(fun(expr,(binding:T.function_binding))->
      if Hashtbl.mem used binding.identity then None else Some expr) in
    decisions,remaining

let prepare ?stored_value_compatibility ~compiler_abi ~source (m : module_form) =
  try
    (match Frontend_check.module_complexity_diagnostics m with
     | [] -> () | d::_ -> reject d.code (Location.dummy_loc m.source_file) d.message);
    match checked (read_syntax m) with
    | None -> Ok None
    | Some {declaration;family;target;fields;previous_expr=_;current_expr;
            previous_root;current_root;same;entities} ->
      let current_path = Validation_common.resolve_local_import_path m.source_file (family ^ ".VCurrent") in
      let project_root = Filename.dirname (Filename.dirname (Filename.dirname current_path)) in
      let expected_relative = Option.get (Validation_common.schema_module_relative_path m.module_name) in
      let expected_path = Filename.concat project_root expected_relative in
      if Validation_common.canonical_import_path m.source_file <> expected_path then
        reject "MIG020" declaration.loc ("migration root must use its canonical path: " ^ expected_path);
      let source_seals = match checked (Migration_header.read ~file:m.source_file source) with
        | None -> None
        | Some header -> Some (checked (Migration_header.verify ~project_root ~migration_module:m.module_name
            ~previous:previous_root ~current:current_root header)) in
      (* Ordinary diagnostics compare current source only. Production generation
         and builds supply their actual compatibility context and additionally
         verify persisted source metadata without borrowing its creator ABI. *)
      Option.iter (fun contract -> Option.iter (fun header ->
        let before,after = Migration_header.seals header in
        List.iter (fun seal ->
          let result = Result.bind (Migration_seal.verify_sources ~project_root seal)
            (Migration_seal.verify_semantics ~stored_value_compatibility:contract ~compiler_abi) in
          match result with Ok _ -> () | Error error ->
            reject "MIG013" error.loc error.message) [before;after]) source_seals) stored_value_compatibility;
      let closure = checked (Migration_closure.read ~file:m.source_file source) in
      Option.iter (fun located -> ignore (checked (Migration_closure.verify ~project_root
        ~root_file:(Validation_common.canonical_import_path m.source_file) ~source located))) closure;
      let previous,current = match H.adjacent_pair_with_compatibility ~stored_value_compatibility ~compiler_abi ~project_root ~family
          ~previous:previous_root ~current:current_root with
        | Ok pair -> pair
        | Error error -> raise (Invalid [{S.code="MIG020";loc=declaration.loc;message=error.message;
            related=[error.loc,"schema history"]}]) in
      if current.H.version <> target then reject "MIG020" (at current_expr)
        (Printf.sprintf "Migrate.V%d must target schema version %d" target target);
      if current_root <> family ^ ".VCurrent" && (source_seals=None || closure=None) then
        reject "MIG013" declaration.loc "a completed migration requires schema seals and its complete frozen source closure";
      if current_root = family ^ ".VCurrent" && closure <> None then
        reject "MIG013" declaration.loc "a current migration cannot claim a completed source closure";
      let holes = entry_holes entities in
      if holes <> [] then raise (Invalid holes);
      let fixtures = match List.assoc_opt "fixtures" fields with
        | None -> [] | Some expression -> list "MIG020" expression in
      let before = previous.H.inventory and after = current.H.inventory in
      let source_graph=checked (T.capture ~before ~after ~source m) in
      checked (T.with_captured source_graph (fun () ->
      let queue_errors = Migration_queue.historical_capability ~before ~after (Option.map Migration_header.seals source_seals) in
      if queue_errors <> [] then raise (Invalid queue_errors);
      let view_root=Option.value(Source_input.project_root()) ~default:project_root in
      (* The supplied root may be an unsaved buffer. Adjacent metadata readers
         must see that same source view, not a pinned-only view that disappears
         when an integrity guard checks the caller's source preconditions. *)
      let queue_transforms,fixtures=Source_input.with_overlays ~project_root:view_root [m.source_file,source] (fun () ->
        prepare_queue_decisions ~project_root ~before ~after
          ~previous_file:previous.root_file ~current_file:current.root_file ~version:target
          ~graph:source_graph ~root:m ~fixtures (List.assoc_opt "jobs" fields)) in
      let identities = identities before after (list "MIG024" same) in
      let definitions = record "MIG002" entities in
      let rules = ref [] in
      let transform_rules = ref [] and functions = ref [] in
      let entries = List.map (fun (entity,expression) ->
        let kind = match application expression with
          | "Additive", [rule_list] ->
            rules := (entity,list "MIG022" rule_list) :: !rules; S.Additive
          | "Derived", [rule_list] ->
            transform_rules := (entity,R.Derived,list "MIG022" rule_list,at expression) :: !transform_rules; S.Transform
          | "Migrate", [function_ref;rule_list] ->
            transform_rules := (entity,R.Migrate,list "MIG022" rule_list,at expression) :: !transform_rules;
            functions := {T.entity;function_ref;loc=at expression} :: !functions; S.Transform
          | "New", [] -> S.New
          | "Drop", [] -> S.Drop
          | _ -> reject "MIG016" (at expression)
            "expected Additive rules, Derived rules, Migrate rowFunction rules, New or Drop; other transformation forms are not implemented" in
        {S.entity;kind;loc=at expression}) definitions in
      let coverage = checked (S.check ~before ~after ~identities ~entries ~loc:declaration.loc) in
      let short name = match List.rev (String.split_on_char '.' name) with name::_ -> name | [] -> name in
      let normalize name = fst (List.find (fun (identity,_) ->
        List.mem name [identity;short identity;previous_root ^ "." ^ identity;current_root ^ "." ^ identity])
        (S.entries coverage)) in
      let defaults = List.concat_map (fun (entity,rules) ->
        let entity = normalize entity in
        List.map (fun expression -> match application expression with
          | "Default", [field;value] -> {A.entity;field=field_name field;value=literal m value;loc=at expression}
          | _ -> reject "MIG022" (at expression) "this additive adapter expects `Default newField literal`") rules)
        (List.rev !rules) in
      let additive = checked (A.check coverage ~defaults) in
      let transforms = if !transform_rules=[] then begin
        if fixtures<>[] then reject "MIG020" declaration.loc "nonempty compatibility fixtures require a transforming entry";
        None
      end else begin
        let entries = List.rev !transform_rules |> List.map (fun (entity,mode,rules,loc) ->
          let entity=normalize entity in
          let rules=List.map (fun expression -> match application expression with
            | "Rename",[previous;current] -> R.Rename {previous=field_name previous;current=field_name current;loc=at expression}
            | "Retype",[field] -> R.Retype {field=field_name field;loc=at expression}
            | "Revalidate",[field;function_ref] -> R.Revalidate {field=field_name field;function_ref;loc=at expression}
            | "WriteBack",[previous;current;function_ref] -> R.WriteBack {previous=field_name previous;current=field_name current;function_ref;loc=at expression}
            | "Legacy",[field;value] -> R.Legacy {field=field_name field;value=literal m value;loc=at expression}
            | "LegacyWith",[field;function_ref] -> R.LegacyWith {field=field_name field;function_ref;loc=at expression}
            | "Default",[field;value] -> R.Default {A.entity;field=field_name field;value=literal m value;loc=at expression}
            | _ -> reject "MIG022" (at expression) "expected Rename, Default, Retype, Revalidate, WriteBack, Legacy or LegacyWith transformation rules") rules in
          {R.entity;mode;rules;loc}) in
        let mapping=checked (R.check ~version:target coverage ~entries) in
        let functions=List.map (fun (f:T.requested) -> {f with entity=normalize f.entity}) (List.rev !functions) in
        Some (checked (T.prepare ~project_root ~source m mapping ~functions ~fixtures))
      end in
      Option.iter (fun header -> ignore (checked (Migration_header.verify_unchanged header))) source_seals;
      Option.iter (fun located -> ignore (checked (Migration_closure.verify ~project_root
        ~root_file:(Validation_common.canonical_import_path m.source_file) ~source located))) closure;
      Ok (Some {pcoverage=coverage;padditive=additive;ptransforms=transforms;pversion=target;pseals=source_seals;pgraph=source_graph;pqueue_transforms=queue_transforms;pproject_root=project_root})))
  with Invalid errors -> Error errors

let rec with_queue_conversions conversions run = match conversions with
  | [] -> run ()
  | checked::rest -> Result.join(Migration_queue_transform.with_checked checked (fun () -> with_queue_conversions rest run))

let with_captured_queues prepared run =
  Result.join(T.with_captured prepared.pgraph (fun () ->
    if prepared.pqueue_transforms=[] then run () else
    (* Validate the caller before installing the checked overlay. Otherwise a
       captured helper could conceal a real edit made after preparation. *)
    Source_input.with_overlays ~project_root:(Option.value(Source_input.project_root()) ~default:prepared.pproject_root)
      (List.map(fun(m,source)->m.source_file,source)(T.captured_source_texts prepared.pgraph))
      (fun()->with_queue_conversions prepared.pqueue_transforms run)))

let with_prepared prepared run = with_captured_queues prepared (fun () -> match prepared.ptransforms with
    | Some transforms -> T.with_prepared transforms run
    | None -> Ok (Migration_proof_context.without_context run))

let check_prepared prepared =
  Result.join (with_prepared prepared (fun () ->
  let transforms=match prepared.ptransforms with
    | None -> Ok None
    | Some transforms -> Result.map Option.some (T.check_prepared transforms) in
  Result.map (fun transforms -> {coverage=prepared.pcoverage;additive=prepared.padditive;
    transforms;queue_transforms=prepared.pqueue_transforms;version=prepared.pversion;source_seals=prepared.pseals}) transforms))
let with_prepared_list prepared run =
  let rec guards = function
    | [] -> T.with_prepared_list (List.filter_map (fun p -> p.ptransforms) prepared) run
    | p::rest -> with_captured_queues p (fun () -> guards rest) in
  guards prepared

let with_source_context ~source m run =
  match Migration_proof_context.without_context (fun () ->
    prepare ~compiler_abi:"compiler-local-unsealed-comparison" ~source m) with
  | Error errors -> Error errors
  | Ok None -> Ok (Migration_proof_context.without_context run)
  | Ok (Some prepared) -> with_prepared prepared run

let check ?stored_value_compatibility ~compiler_abi ~source m =
  Result.bind (prepare ?stored_value_compatibility ~compiler_abi ~source m) (function
    | None -> Ok None
    | Some prepared -> Result.map Option.some (check_prepared prepared))

let diagnostics_of_errors errors =
  (* One surface Same can check a type and its same-named codec. Their closures
     can fail at the very same dependency; report that source cause once while
     retaining distinct locations/causes and all independent checker judgments. *)
  let seen = Hashtbl.create 8 in
  List.filter_map (fun (error : S.error) ->
    if Hashtbl.mem seen error then None else begin
      Hashtbl.add seen error ();
      let loc = error.loc in
      let related = List.map (fun (loc,description) -> Printf.sprintf
        "%s: %s:%d:%d" description loc.Location.file (loc.start.line + 1) (loc.start.col + 1)) error.related in
      Some {Frontend_check.file=loc.file;start_line=loc.start.line;start_col=loc.start.col;
       end_line=loc.stop.line;end_col=loc.stop.col;severity="error";code=error.code;
       message=String.concat "\n" (error.message :: related);fix=None;source="migration";
       metadata=Some (Diagnostic_metadata.migration ~code:error.code ~message:error.message ~related:error.related);
       manual=Error_codes.manual_for ~code:error.code ~message:error.message ()}
    end) errors


let diagnostics source (m : module_form) =
  (* This judgment compares sources freshly compiled in this invocation. It is
     intentionally not the persisted execution ABI, which the sealed plan must
     obtain from the build's compiler/runtime semantics identity. *)
  let escapes = ref [] in
  if Migration_form.available m then begin
    List.iter (Ast_visitor.iter (fun expression ->
      let name = match expression with
        | EConstructor {name;_} | ERecord {type_hint=Some name;_} -> Some name
        | _ -> None in
      match name with
      | Some name when List.mem name Migration_form.names && Migration_form.imported_name m name ->
        escapes := {S.code="MIG020";loc=at expression;message=("`" ^ name ^ "` is contextual migration syntax, not a runtime value");related=[]} :: !escapes
      | _ -> ()))
      (Frontend_check.module_expression_roots {m with decls=Migration_form.runtime_declarations m})
  end;
  let result = match check ~compiler_abi:"compiler-local-unsealed-comparison" ~source m with
    | Ok _ when !escapes = [] -> Ok ()
    | Ok _ -> Error (List.rev !escapes)
    | Error errors -> Error (errors @ List.rev !escapes) in
  match result with
  | Ok _ -> []
  | Error errors -> diagnostics_of_errors errors
