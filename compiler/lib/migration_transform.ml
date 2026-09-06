(** Source-only transformation judgment. Physical planning still refuses these
    entries; this descriptor grants no callback, generation or persisted authority. *)
open Ast
module S = Migration_sparse
module R = Migration_transform_rules
module I = Migration_inventory
module IR = Migration_ir
module C = Migration_canonical

type requested = { entity : string; function_ref : expr; loc : Location.loc }
type function_binding = { identity : string; owner : module_form; declaration : func_decl }
type row = { mapping : R.entity; function_binding : function_binding option; fixtures : function_binding list }
type t = { rules : R.t; rows : row list; source_inputs : (string * string) list }
let rows t = t.rows
let rules t = t.rules
let source_inputs t = t.source_inputs
exception Invalid of S.error list
let reject code loc message = raise (Invalid [{S.code;loc;message;related=[]}])
let at = Checker.expr_loc

let names = function
  | DFunc f -> [IR.Value,f.name]
  | DType (TypeNewtype t) -> [IR.Type,t.name;IR.Value,t.name]
  | DType (TypeAdt t) -> (IR.Type,t.name) :: List.map (fun (v:adt_variant) -> IR.Value,v.ctor) t.variants
  | DRecord r -> [IR.Type,r.name;IR.Value,r.name]
  | DEntity e -> [IR.Type,e.name;IR.Value,e.name]
  | DFact f -> [IR.Predicate,f.name]
  | DCodec c -> [IR.Codec,c.name]
  | DQueueSchema q -> [IR.Value,q.name]
  | DConst c -> [IR.Value,c.name]
  | DDatabase _ | DCapability _ | DQueue _ | DChannel _ | DWorkers _ | DCache _
  | DAgent _ | DEmail _ | DCapture _ | DApi _ | DServer _ | DTest _ | DApiTest _ | DLoadTest _ -> []

let builtin m namespace name =
  let candidates = Type_system.tesl_module_exports |> List.filter_map (fun (home,exports) ->
    if List.mem name exports && List.exists (fun (i:import_decl) -> i.module_name=home) m.imports
    then Some home else None) |> List.sort_uniq compare in
  let allowed = match namespace with
    | IR.Codec -> List.mem_assoc name Validation_common.builtin_codec_type
    | IR.Predicate -> List.exists (fun (_,predicates) -> List.mem name predicates) Checker.tesl_module_predicate_exports
    | IR.Type -> name<>"" && name.[0]>='A' && name.[0]<='Z'
    | IR.Value -> Type_system.stdlib_capabilities_of name=[] in
  if not allowed then None else match candidates with
  | [home] -> Some (IR.Primitive (home ^ "." ^ name))
  | [] when List.mem name Type_system.always_available_stdlib_names -> Some (IR.Primitive ("Tesl.Prelude." ^ name))
  | _ -> None

let graph ~before ~after ~source (root:module_form) =
  let previous = I.root_module before and current = I.root_module after in
  let family = Option.get (Migration_schema.migration_family root.module_name) in
  let found = Hashtbl.create 16 in
  let rec visit source (m:module_form) =
    if not (Hashtbl.mem found m.module_name) then begin
      Hashtbl.add found m.module_name (m,source);
      let migration = Migration_schema.migration_family m.module_name=Some family in
      (match Migration_schema.check_contents ~migration m with
       | [] -> () | error::_ -> reject "MIG010" error.loc error.message);
      List.iter (fun (imp:import_decl) ->
        if not (String.starts_with ~prefix:"Tesl." imp.module_name) then begin
          if not (Migration_schema.migration_family imp.module_name=Some family ||
                  Migration_schema.within previous imp.module_name || Migration_schema.within current imp.module_name)
          then reject "MIG010" imp.loc "row-function closure must stay in its migration family and the exact adjacent schema pair";
          if not (Hashtbl.mem found imp.module_name) then begin
            let path = Validation_common.resolve_local_import_path m.source_file imp.module_name in
            let body = Source_input.read path in
            match Parser.parse_module path body with
            | Err e -> reject "MIG010" e.loc e.msg
            | Ok child when child.module_name=imp.module_name -> visit body child
            | Ok _ -> reject "MIG010" imp.loc "row-function import resolves to another module"
          end
        end) m.imports
    end in
  visit source root;
  let sources = Hashtbl.to_seq_values found |> List.of_seq |> List.sort (fun (a,_) (b,_) -> String.compare a.module_name b.module_name) in
  let inputs = List.map (fun (m,body) -> m.source_file,Migration_hash.digest body) sources in
  List.iter (fun (file,digest) -> if List.assoc_opt file inputs<>Some digest then
    reject "MIG013" (Location.dummy_loc file) "schema source changed after the transformation inventory was checked")
    (I.source_inputs before @ I.source_inputs after);

  sources

let resolver modules (m:module_form) namespace name =
  let local = List.concat_map names m.decls in
  if List.mem (namespace,name) local then Some (IR.Global (m.module_name ^ "." ^ name)) else
  let candidates = List.concat_map (fun (owner:module_form) ->
    let declarations = List.concat_map names owner.decls in
    let imported = List.find_opt (fun (i:import_decl) -> i.module_name=owner.module_name) m.imports in
    List.filter_map (fun (ns,short) ->
      let qualified = owner.module_name ^ "." ^ short in
      let direct = owner.module_name=m.module_name || Option.fold ~none:false ~some:(fun (_:import_decl) ->
        List.mem (ExportName short) owner.exports || List.exists (function
          | DType (TypeAdt t) -> List.mem (ExportAdt t.name) owner.exports && List.exists (fun (v:adt_variant) -> v.ctor=short) t.variants
          | _ -> false) owner.decls || ns=IR.Codec) imported in
      let exposed = Option.fold ~none:false ~some:(fun (i:import_decl) -> match i.names with
        | ImportAll -> false
        | ImportExposing exposed -> List.mem short exposed || List.exists (function
          | DType (TypeAdt t) -> List.mem (t.name ^ "(..)") exposed && List.exists (fun (v:adt_variant) -> v.ctor=short) t.variants
          | _ -> false) owner.decls) imported in
      if ns=namespace && direct && (name=qualified || (name=short && exposed)) then Some (IR.Global qualified) else None) declarations) modules
    |> List.sort_uniq compare in
  match candidates with [one] -> Some one | [] -> builtin m namespace name | _ -> None

let function_name = function
  | EVar {name;_} -> Some name
  | EField {obj=EConstructor {name;args=[];_};field;_} -> Some (name ^ "." ^ field)
  | _ -> None
let bind_function modules root expression =
  let identity = match Option.bind (function_name expression) (resolver modules root IR.Value) with
    | Some (IR.Global name) -> name
    | _ -> reject "MIG021" (at expression) "name a local or directly exported owned row function" in
  let candidates = List.concat_map (fun (owner:module_form) -> List.filter_map (function
    | DFunc declaration when owner.module_name ^ "." ^ declaration.name=identity -> Some {identity;owner;declaration}
    | _ -> None) owner.decls) modules in
  match candidates with
  | [binding] when binding.declaration.kind=FnKind && binding.declaration.capabilities=[] -> binding
  | _ -> reject "MIG021" (at expression) "migration functions must be ordinary fn declarations without capabilities"

let entity_type modules owner expected = function
  | TName {name;_} -> resolver modules owner IR.Type name=Some (IR.Global expected)
  | _ -> false
let result_type modules owner expected = function
  | RetPlain {ty=TApp {head=TName {name;_};arg;_};_} ->
    resolver modules owner IR.Type name=Some (IR.Primitive "Tesl.Migration.Migrated") && entity_type modules owner expected arg
  | _ -> false

let check_returns modules binding mapping =
  let old = (List.hd binding.declaration.params).name in
  let shadow name loc = if name=old then reject "MIG018" loc "the original row parameter cannot be shadowed in a migration" in
  let rec pattern loc = function
    | PVar name -> shadow name loc
    | PCon p -> List.iter (fun (_,p) -> pattern loc p) p.fields
    | PWild | PNullary _ | PLit _ -> () in
  let project previous = function EField {obj=EVar {name;_};field;_} -> name=old && field=previous | _ -> false in
  let literal fields loc =
    List.iter (function
      | R.Copy {previous;current} | R.Renamed {previous;current} as source ->
        let code = match source with R.Renamed _ -> "MIG017" | _ -> "MIG018" in
        (match List.assoc_opt current.name fields with
         | Some value when project previous.name value -> ()
         | value -> reject code (Option.fold ~none:loc ~some:at value)
             (Printf.sprintf "`%s` must copy the exact original projection `%s.%s`" current.name old previous.name))
      | R.Constant (field,expected) ->
        (* The full row literal remains user written; even a declared Default
           cannot justify returning a different constant during migration. *)
        let value = match List.assoc_opt field.name fields with
          | Some value -> value | None -> reject "MIG018" loc ("missing field " ^ field.name) in
        let literal = function
          | ELit {lit=LInt n;_} -> C.integer (string_of_int n)
          | ELit {lit=LBigInt n;_} -> C.integer n
          | ELit {lit=LString s;_} -> Ok (C.string s)
          | ELit {lit=LBool b;_} -> Ok (C.bool b)
          | EConstructor {name="True";args=[];_} -> Ok (C.bool true)
          | EConstructor {name="False";args=[];_} -> Ok (C.bool false)
          | ELit {lit=LFloat f;_} -> C.float f
          | EUnop {op=UNeg;arg=ELit {lit=LInt n;_};_} -> C.integer ("-" ^ string_of_int n)
          | EUnop {op=UNeg;arg=ELit {lit=LBigInt n;_};_} -> C.integer ("-" ^ n)
          | EUnop {op=UNeg;arg=ELit {lit=LFloat f;_};_} -> C.float (-. f)
          | _ -> Error "not an exact literal" in
        if literal value<>Ok expected then reject "MIG018" (at value) ("`" ^ field.name ^ "` must use its declared Default literal")
      | R.Empty_optional _ | R.Computed _ -> ()) mapping.R.values in
  let row value = match value with
    | ERecord {type_hint=Some name;fields;loc}
        when resolver modules binding.owner IR.Type name=Some (IR.Global mapping.R.current.entity_name) -> literal fields loc
    | EApp {fn=EConstructor {name;args=[];_};arg=ERecord {fields;loc;_};_}
        when resolver modules binding.owner IR.Type name=Some (IR.Global mapping.R.current.entity_name) -> literal fields loc
    | _ -> reject "MIG018" (at value) "Row must contain a complete target entity literal; record aliases and row-producing helpers cannot prove field identities" in
  let rec returns = function
    | ELet e -> shadow e.name e.loc; returns e.body
    | ELetProof e -> shadow e.value_name e.loc; shadow e.proof_name e.loc; returns e.body
    | EIf e -> returns e.then_; returns e.else_
    | ECase e -> List.iter (fun (arm:case_arm) -> pattern arm.loc arm.pattern; returns arm.body) e.arms
    | value -> (match Migration_form.application value with
      | "Row",[value] when resolver modules binding.owner IR.Value "Row"=Some (IR.Primitive "Tesl.Migration.Row") -> row value
      | "Reject",[_] when resolver modules binding.owner IR.Value "Reject"=Some (IR.Primitive "Tesl.Migration.Reject") -> ()
      | _ -> reject "MIG018" (at value) "every row-function result must be an explicit Row target literal or Reject reason") in
  returns binding.declaration.body

(* A row result is a non-propagating boundary. Follow named executable
   dependencies with their declaration-owner scope; HTTP checks must not become
   an implicit third result alongside Row/Reject through a helper or constant. *)
let check_pure_closure modules bindings =
  let seen = Hashtbl.create 16 in
  let rec pattern = function
    | PVar name -> [name]
    | PCon p -> List.concat_map (fun (_,p) -> pattern p) p.fields
    | PWild | PNullary _ | PLit _ -> [] in
  let rec expression owner bound value =
    (match value with
     | EFail {loc;_} -> reject "MIG021" loc "row-function closures cannot raise HTTP failure; return Reject or use an optional establish"
     | _ -> ());
    (match function_name value with
     | Some name when not (List.mem name bound) ->
       (match resolver modules owner IR.Value name with
        | Some (IR.Global identity) -> definition identity
        | Some (IR.Primitive _) when List.mem name Checker.stdlib_check_shaped_names ->
          reject "MIG021" (at value) "row-function closures cannot call stdlib HTTP checks; use an optional proof-producing function and return Reject"
        | _ -> ())
     | _ -> ());
    match value with
    | ELet e -> expression owner bound e.value; expression owner (e.name::bound) e.body
    | ELetProof e -> expression owner bound e.value; expression owner (e.value_name::e.proof_name::bound) e.body
    | ELambda e -> expression owner (List.map (fun (b:binding) -> b.name) e.params @ bound) e.body
    | ECase e -> expression owner bound e.scrut;
      List.iter (fun (arm:case_arm) -> let bound=pattern arm.pattern @ bound in
        Option.iter (expression owner bound) arm.guard; expression owner bound arm.body) e.arms
    | _ -> Ast_visitor.iter_children (expression owner bound) value
  and definition identity =
    if not (Hashtbl.mem seen identity) then begin
      Hashtbl.add seen identity ();
      List.iter (fun (owner:module_form) -> List.iter (function
        | DFunc declaration when owner.module_name ^ "." ^ declaration.name=identity ->
          if declaration.kind=CheckKind || declaration.capabilities<>[] || declaration.http_methods<>[] then
            reject "MIG021" declaration.loc "row-function closures require pure fn or establish helpers, never HTTP check functions";
          expression owner (List.map (fun (b:binding) -> b.name) declaration.params) declaration.body
        | DConst declaration when owner.module_name ^ "." ^ declaration.name=identity -> expression owner [] declaration.value
        | _ -> ()) owner.decls) modules
    end in
  List.iter (fun binding -> definition binding.identity) bindings

let check ~project_root ~source root rules ~functions ~fixtures =
  try
    let before,after = S.inventories (R.coverage rules) in
    let sources = graph ~before ~after ~source root in
    let modules = List.map fst sources in
    let fixture_functions = List.map (bind_function modules root) fixtures in
    let mappings = R.entities rules in
    List.iter (fun fixture ->
      if fixture.declaration.params<>[] || not (List.exists (fun mapping ->
        match fixture.declaration.return_spec with
        | RetPlain result -> entity_type modules fixture.owner mapping.R.previous.entity_name result.ty
        | _ -> false) mappings) then reject "MIG021" fixture.declaration.loc
        "fixtures must be parameterless functions returning an exact previous entity in this transformation") fixture_functions;
    let used = Hashtbl.create 8 in
    let rows = R.entities rules |> List.map (fun mapping ->
      let function_binding = match mapping.R.mode with
        | R.Derived -> None
        | R.Migrate ->
          let request = match List.filter (fun (f:requested) -> f.entity=mapping.identity) functions with
            | [one] -> one | _ -> reject "MIG021" mapping.current.entity_loc "missing or duplicate row-function binding" in
          let binding = bind_function modules root request.function_ref in
          (match binding.declaration.params with
           | [parameter] when parameter.proof_ann=None && entity_type modules binding.owner mapping.previous.entity_name parameter.type_expr &&
               result_type modules binding.owner mapping.current.entity_name binding.declaration.return_spec -> ()
           | _ -> reject "MIG021" request.loc (Printf.sprintf "%s requires exactly `%s -> Migrated %s`" mapping.identity mapping.previous.entity_name mapping.current.entity_name));
          check_returns modules binding mapping;
          Some binding in
      let fixtures = List.filter (fun binding ->
        binding.declaration.params=[] && match binding.declaration.return_spec with
          | RetPlain r -> entity_type modules binding.owner mapping.previous.entity_name r.ty
          | _ -> false) fixture_functions in
      List.iter (fun fixture -> Hashtbl.replace used fixture.identity ()) fixtures;
      if mapping.mode=R.Migrate && fixtures=[] then reject "MIG003" mapping.previous.entity_loc
        (Printf.sprintf "%s requires a representative fixture `fn old%s() -> %s`; add it to fixtures" mapping.identity mapping.identity mapping.previous.entity_name);
      {mapping;function_binding;fixtures}) in
    List.iter (fun fixture -> if not (Hashtbl.mem used fixture.identity) then reject "MIG021" fixture.declaration.loc
      "fixtures must be parameterless functions returning an exact previous entity in this transformation") fixture_functions;
    let seen = Hashtbl.create 8 in
    List.iter (fun fixture -> if Hashtbl.mem seen fixture.identity then reject "MIG023" fixture.declaration.loc "duplicate migration fixture" else Hashtbl.add seen fixture.identity ()) fixture_functions;
    check_pure_closure modules (fixture_functions @ List.filter_map (fun row -> row.function_binding) rows);
    (* Dependent type checks may import the root again (for example through a
       mutually recursive helper module). Keep every read in the captured source
       view, including a supplied root buffer that differs from its saved file. *)
    let captured=List.map (fun (m,body) -> Validation_common.canonical_import_path m.source_file,body) sources in
    let input_root=Option.value (Source_input.project_root ()) ~default:project_root in
    (try Source_input.with_overlays ~project_root:input_root captured (fun () ->
      List.iter (fun (m,source) ->
        (* No Migration_declaration additional callback: ordinary type/proof and
           import gates run without re-entering this contextual judgment. *)
        let ds=Frontend_check.check_module ~skip_dep_body:(fun _ -> true) source m in
        match List.find_opt (fun (d:Frontend_check.diagnostic) -> d.severity="error") ds with
        | None -> ()
        | Some d -> reject d.code (Location.make_loc d.file d.start_line d.start_col d.end_line d.end_col) d.message) sources)
     with Invalid_argument message -> reject "MIG013" (Location.dummy_loc root.source_file) message);
    (* No callback is emitted yet. Publish only the checked AST and immutable raw
       source preconditions; a typed semantic closure is the next required link
       judgment and must never be replaced by this source digest. *)
    let source_inputs = List.map (fun (file,body) -> file,Migration_hash.digest body) captured |> List.sort compare in
    List.iter (fun (file,digest) -> if file<>Validation_common.canonical_import_path root.source_file && Migration_hash.digest (Source_input.read file)<>digest then
      reject "MIG013" (Location.dummy_loc file) "row-function source changed while it was checked") source_inputs;
    Ok {rules;rows;source_inputs}
  with Invalid errors -> Error errors
    | Sys_error message -> Error [{S.code="MIG010";loc=Location.dummy_loc root.source_file;message;related=[]}]
    | Unix.Unix_error (error,operation,file) -> Error [{S.code="MIG010";loc=Location.dummy_loc file;
        message=operation ^ ": " ^ Unix.error_message error;related=[]}]
