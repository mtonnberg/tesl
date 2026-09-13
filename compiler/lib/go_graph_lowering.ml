(* Pure Go-only graph lowering. Original checked declarations remain distinct
   from their deterministic emission copies; no filesystem inputs are collected. *)
module Exprs = Hashtbl.Make(struct
 type t = Ast.expr
 let equal a b = a == b
 let hash = Hashtbl.hash
end)
type t = { originals:Ast.module_form list; modules:Ast.module_form list;
 entry:Ast.module_form; owners:(string * string) list;
 renamed:((string * string) * string) list; origins:Ast.expr Exprs.t }
let modules t = t.modules
let entry t = t.entry
let owner t name = List.assoc_opt name t.owners
let symbol t ~owner:source name = Option.map (fun target ->
 target,Option.value(List.assoc_opt (source,name) t.renamed) ~default:name) (owner t source)
let original_expr t expression = Option.value (Exprs.find_opt t.origins expression) ~default:expression
let function_binding t ~(owner:Ast.module_form) (declaration:Ast.func_decl) =
 match List.find_opt (fun (m:Ast.module_form)->m.module_name=owner.module_name && m=owner) t.originals,
       symbol t ~owner:owner.module_name declaration.name with
 | Some original,Some(target,name) when List.exists(function Ast.DFunc f -> f=declaration | _->false) original.decls ->
   List.find_map(fun(m:Ast.module_form)->if m.module_name<>target then None else
    List.find_map(function Ast.DFunc f when f.name=name && f.loc=declaration.loc -> Some(m,f) | _->None)m.decls)t.modules
 | _ -> None
let merge_exposed_imports (left : Ast.import_decl) (right : Ast.import_decl) =
  match left.names, right.names with
  (* ImportAll is rejected by the Go emitter with its own message; keep it visible rather
     than silently widening or narrowing the import. *)
  | Ast.ImportAll, _ | _, Ast.ImportAll -> { left with names = Ast.ImportAll }
  | Ast.ImportExposing ours, Ast.ImportExposing theirs ->
    { left with names = Ast.ImportExposing
                  (ours @ List.filter (fun name -> not (List.mem name ours)) theirs) }

let rec add_merged_import acc (imp : Ast.import_decl) =
  match acc with
  | [] -> [imp]
  | (existing : Ast.import_decl) :: rest when existing.module_name = imp.module_name ->
    merge_exposed_imports existing imp :: rest
  | existing :: rest -> existing :: add_merged_import rest imp

(* Go collapses an SCC into one package. Preserve the source module namespaces by
   alpha-renaming only the copied emission AST. '$' cannot occur in a Tesl identifier,
   and [Emit_go.go_ident] escapes it deterministically. *)
let alpha_rename_cycle_members origins ~(targets : Ast.module_form list)
    (members : Ast.module_form list) =
  let member_names = List.map (fun (m : Ast.module_form) -> m.module_name) members in
  let symbols (m : Ast.module_form) =
    List.concat_map (function
      | Ast.DFunc f -> [f.name]
      | Ast.DConst c -> [c.name]
      | Ast.DRecord r -> [r.name]
      | Ast.DEntity e -> [e.name]
      | Ast.DFact f -> [f.name]
      | Ast.DCapture c -> [c.name]
      | Ast.DType (Ast.TypeNewtype { name; _ }) -> [name]
      | Ast.DType (Ast.TypeAdt { name; variants; _ }) ->
        name :: List.map (fun (v : Ast.adt_variant) -> v.ctor) variants
      | _ -> []) m.decls
  in
  let owners = Hashtbl.create 16 in
  List.iter (fun (m : Ast.module_form) -> List.iter (fun name ->
    let prior = Option.value (Hashtbl.find_opt owners name) ~default:[] in
    if not (List.mem m.module_name prior) then
      Hashtbl.replace owners name (m.module_name :: prior)) (symbols m)) members;
  let renamed = Hashtbl.create 16 in
  List.iter (fun (m : Ast.module_form) -> List.iter (fun name ->
    if List.length (Option.value (Hashtbl.find_opt owners name) ~default:[]) > 1 then
      Hashtbl.replace renamed (m.module_name, name)
        (Printf.sprintf "Scc$%s$%s" m.module_name name)) (symbols m)) members;
  let adt_constructors (m : Ast.module_form) type_name =
    List.find_map (function
      | Ast.DType (Ast.TypeAdt { name; variants; _ }) when name = type_name ->
        Some (List.map (fun (v : Ast.adt_variant) -> v.ctor) variants)
      | _ -> None) m.decls
    |> Option.value ~default:[]
  in
  let imported_ctor_owner module_name exposed_type ctor =
    List.find_opt (fun (owner : Ast.module_form) -> owner.module_name = module_name)
      members
    |> Option.map (fun owner -> List.mem ctor (adt_constructors owner exposed_type))
    |> Option.value ~default:false
  in
  let local_owner (m : Ast.module_form) name =
    if List.mem name (symbols m) then Some m.module_name
    else List.find_map (fun (imp : Ast.import_decl) ->
      match imp.names with
      | Ast.ImportAll -> None
      | Ast.ImportExposing names ->
        let exposes item =
          item = name || item = name ^ "(..)"
          || (String.length item >= 4
              && String.sub item (String.length item - 4) 4 = "(..)"
              && imported_ctor_owner imp.module_name
                   (String.sub item 0 (String.length item - 4)) name)
        in
        if List.exists exposes names then Some imp.module_name else None) m.imports
  in
  let split_qualified name =
    match String.rindex_opt name '.' with
    | None -> None
    | Some i -> Some (String.sub name 0 i,
                       String.sub name (i + 1) (String.length name - i - 1))
  in
  let rename m name =
    let owner, bare = match split_qualified name with
      | Some pair -> pair
      | None -> Option.value (local_owner m name) ~default:m.Ast.module_name, name
    in
    match Hashtbl.find_opt renamed (owner, bare) with
    | Some generated -> generated
    | None when List.mem owner member_names -> bare
    | None -> name
  in
  let rec ty m = function
    | Ast.TName ({ name; _ } as n) -> Ast.TName { n with name = rename m name }
    | Ast.TVar _ as t -> t
    | Ast.TApp ({ head; arg; _ } as t) -> Ast.TApp { t with head = ty m head; arg = ty m arg }
    | Ast.TFun ({ dom; cod; _ } as t) -> Ast.TFun { t with dom = ty m dom; cod = ty m cod }
    | Ast.TTuple ({ elems; _ } as t) -> Ast.TTuple { t with elems = List.map (ty m) elems }
  in
  let proof m =
    let rec go = function
      | Ast.PredApp ({ pred; _ } as p) -> Ast.PredApp { p with pred = rename m pred }
      | Ast.PredAnd ({ left; right; _ } as p) ->
        Ast.PredAnd { p with left = go left; right = go right }
    in go
  in
  let binding m (b : Ast.binding) =
    { b with type_expr = ty m b.type_expr; proof_ann = Option.map (proof m) b.proof_ann }
  in
  let field m (f : Ast.field_def) =
    { f with type_expr = ty m f.type_expr; proof_ann = Option.map (proof m) f.proof_ann }
  in
  let rec ret m = function
    | Ast.RetPlain ({ ty = t; _ } as r) -> Ast.RetPlain { r with ty = ty m t }
    | Ast.RetAttached ({ binding = b; _ } as r) -> Ast.RetAttached { r with binding = binding m b }
    | Ast.RetNamedPack ({ ty = t; entity_proof; other_proof; _ } as r) ->
      Ast.RetNamedPack { r with ty = ty m t; entity_proof = Option.map (proof m) entity_proof;
                               other_proof = Option.map (proof m) other_proof }
    | Ast.RetForAll ({ elem_ty; proof = p; _ } as r) -> Ast.RetForAll { r with elem_ty = ty m elem_ty; proof = proof m p }
    | Ast.RetMaybeForAll ({ elem_ty; proof = p; _ } as r) -> Ast.RetMaybeForAll { r with elem_ty = ty m elem_ty; proof = proof m p }
    | Ast.RetSetForAll ({ elem_ty; proof = p; _ } as r) -> Ast.RetSetForAll { r with elem_ty = ty m elem_ty; proof = proof m p }
    | Ast.RetMaybeSetForAll ({ elem_ty; proof = p; _ } as r) -> Ast.RetMaybeSetForAll { r with elem_ty = ty m elem_ty; proof = proof m p }
    | Ast.RetForAllDictValues ({ key_ty; val_ty; proof = p; _ } as r) -> Ast.RetForAllDictValues { r with key_ty = ty m key_ty; val_ty = ty m val_ty; proof = proof m p }
    | Ast.RetForAllDictKeys ({ key_ty; val_ty; proof = p; _ } as r) -> Ast.RetForAllDictKeys { r with key_ty = ty m key_ty; val_ty = ty m val_ty; proof = proof m p }
    | Ast.RetMaybeAttached ({ outer_ty; binding = b; _ } as r) -> Ast.RetMaybeAttached { r with outer_ty = Option.map (ty m) outer_ty; binding = binding m b }
    | Ast.RetExists ({ binding = b; body; _ } as r) -> Ast.RetExists { r with binding = binding m b; body = ret m body }
  in
  let rec pattern m = function
    | Ast.PCon ({ ctor; fields; _ } as p) -> Ast.PCon { p with ctor = rename m ctor; fields = List.map (fun (n, p) -> n, pattern m p) fields }
    | Ast.PNullary ({ ctor; _ } as p) -> Ast.PNullary { p with ctor = rename m ctor }
    | (Ast.PVar _ | Ast.PWild | Ast.PLit _) as p -> p
  in
  let rec expr m e =
    let original = Option.value (Exprs.find_opt origins e) ~default:e in
    let e = Ast_visitor.map_children (expr m) e in
    let result = match e with
    | Ast.EVar ({ name; _ } as v) -> Ast.EVar { v with name = rename m name }
    | Ast.EField { obj = Ast.EConstructor { name = owner; args = []; _ }; field = name; loc }
      when Hashtbl.mem renamed (owner, name) ->
        Ast.EVar { name = Hashtbl.find renamed (owner, name); loc }
    | Ast.EField { obj = Ast.EConstructor c; field; loc }
      when c.args = [] && List.mem c.name member_names ->
        Ast.EVar { name = field; loc }
    | Ast.EConstructor ({ name; _ } as c) -> Ast.EConstructor { c with name = rename m name }
    | Ast.EEnqueue ({ job_type; _ } as q) ->
      Ast.EEnqueue { q with job_type = rename m job_type }
    | Ast.EPublish ({ event_ctor; _ } as p) ->
      Ast.EPublish { p with event_ctor = rename m event_ctor }
    | Ast.ERecord ({ type_hint; _ } as r) -> Ast.ERecord { r with type_hint = Option.map (rename m) type_hint }
    | Ast.ELet ({ declared_type; declared_proof; _ } as l) ->
      Ast.ELet { l with declared_type = Option.map (ty m) declared_type;
                        declared_proof = Option.map (proof m) declared_proof }
    | Ast.EOk ({ proof = p; _ } as ok) -> Ast.EOk { ok with proof = proof m p }
    | Ast.ELambda ({ params; _ } as l) ->
      Ast.ELambda { l with params = List.map (binding m) params }
    | Ast.ECase ({ arms; _ } as c) -> Ast.ECase { c with arms = List.map (fun (a : Ast.case_arm) -> { a with pattern = pattern m a.pattern }) arms }
    | other -> other in
    Exprs.replace origins result original; result
  in
  let rec test_stmts m stmts = List.map (function
    | Ast.TsLet ({ declared_type; value; declared_proof; _ } as s) -> Ast.TsLet { s with declared_type = Option.map (ty m) declared_type; value = expr m value; declared_proof = Option.map (proof m) declared_proof }
    | Ast.TsLetProof ({ value; _ } as s) -> Ast.TsLetProof { s with value = expr m value }
    | Ast.TsExpect ({ left; right; _ } as s) -> Ast.TsExpect { s with left = expr m left; right = Option.map (expr m) right }
    | Ast.TsExpectFail ({ fn; arg; _ } as s) -> Ast.TsExpectFail { s with fn = expr m fn; arg = expr m arg }
    | Ast.TsExpectHasProof ({ fn; arg; _ } as s) -> Ast.TsExpectHasProof { s with fn = expr m fn; arg = expr m arg }
    | Ast.TsProperty ({ params; body; _ } as s) -> Ast.TsProperty { s with params = List.map (fun (p : Ast.property_param) -> { p with binding = binding m p.binding; where_clause = Option.map (expr m) p.where_clause; generator = Option.map (rename m) p.generator }) params; body = expr m body }
    | Ast.TsIf ({ cond; then_stmts; else_stmts; _ } as s) -> Ast.TsIf { s with cond = expr m cond; then_stmts = test_stmts m then_stmts; else_stmts = test_stmts m else_stmts }
    | Ast.TsCase ({ scrut; arms; _ } as s) -> Ast.TsCase { s with scrut = expr m scrut; arms = List.map (fun (a : Ast.ts_case_arm) -> { a with ts_pattern = pattern m a.ts_pattern; ts_guard = Option.map (expr m) a.ts_guard; ts_body = test_stmts m a.ts_body }) arms }
    | Ast.TsExpr ({ e; _ } as s) -> Ast.TsExpr { s with e = expr m e }) stmts
  in
  let decl m = function
    | Ast.DFunc f -> Ast.DFunc { f with name = rename m f.name; params = List.map (binding m) f.params; return_spec = ret m f.return_spec; body = expr m f.body }
    | Ast.DConst c -> Ast.DConst { c with name = rename m c.name; value = expr m c.value }
    | Ast.DRecord r -> Ast.DRecord { r with name = rename m r.name; fields = List.map (field m) r.fields;
      invariant = Option.map (fun (i : Ast.record_invariant) -> { i with proof_text = proof m i.proof_text;
        checker_name = Option.map (rename m) i.checker_name }) r.invariant }
    | Ast.DEntity e -> Ast.DEntity { e with name = rename m e.name; fields = List.map (field m) e.fields }
    | Ast.DDatabase d ->
      let merged = List.hd (List.sort String.compare member_names) in
      let entity name = match split_qualified name with
        | Some (owner, _) when List.mem owner member_names -> merged ^ "." ^ rename m name
        | _ -> rename m name in
      Ast.DDatabase { d with entities = List.map entity d.entities;
        config_expr = Option.map (expr m) d.config_expr }
    | Ast.DFact f -> Ast.DFact { f with name = rename m f.name; params = List.map (binding m) f.params }
    | Ast.DCapture c -> Ast.DCapture { c with name = rename m c.name;
      binding = binding m c.binding; parser = rename m c.parser;
      checker = Option.map (rename m) c.checker }
    | Ast.DType (Ast.TypeNewtype t) -> Ast.DType (Ast.TypeNewtype { t with name = rename m t.name; base_type = ty m t.base_type })
    | Ast.DType (Ast.TypeAdt t) -> Ast.DType (Ast.TypeAdt { t with name = rename m t.name; variants = List.map (fun (v : Ast.adt_variant) -> { v with ctor = rename m v.ctor; fields = List.map (field m) v.fields }) t.variants })
    | Ast.DTest t -> Ast.DTest { t with stmts = test_stmts m t.stmts }
    | Ast.DApiTest t -> Ast.DApiTest { t with seed_stmts = List.map (expr m) t.seed_stmts; stmts = test_stmts m t.stmts }
    | Ast.DLoadTest t -> Ast.DLoadTest { t with seed_stmts = List.map (expr m) t.seed_stmts; request_stmts = test_stmts m t.request_stmts }
    | d -> d
  in
  let result = List.map (fun (m : Ast.module_form) ->
    let import (i : Ast.import_decl) = match i.names with
      | Ast.ImportAll -> i
      | Ast.ImportExposing names -> { i with names = Ast.ImportExposing (List.map (fun name ->
          let suffix = if String.length name >= 4 && String.sub name (String.length name - 4) 4 = "(..)" then "(..)" else "" in
          let bare = if suffix = "" then name else String.sub name 0 (String.length name - 4) in
          Option.value (Hashtbl.find_opt renamed (i.module_name, bare)) ~default:bare ^ suffix) names) }
    in
    { m with decls = List.map (decl m) m.decls; imports = List.map import m.imports;
             exports = List.map (function Ast.ExportName n -> Ast.ExportName (rename m n) | Ast.ExportAdt n -> Ast.ExportAdt (rename m n)) m.exports }) targets in
  result, Hashtbl.to_seq renamed |> List.of_seq

let merge_cycle_members (members : Ast.module_form list) =
  match List.sort (fun (left : Ast.module_form) (right : Ast.module_form) ->
          String.compare left.module_name right.module_name) members with
  | [] -> Error "Go backend found an empty import cycle"
  | [single] -> Ok single
  | first :: _ as sorted ->
    let names = List.map (fun (m : Ast.module_form) -> m.module_name) sorted in
    Ok { first with
            (* Deliberately keeps the first member's name and source_file: the package is
               named after it, and the file is only used for whole-module diagnostics. *)
            decls = List.concat_map (fun (m : Ast.module_form) -> m.decls) sorted;
            exports = List.concat_map (fun (m : Ast.module_form) -> m.exports) sorted;
            imports =
              (* An import of a fellow member disappears with the boundary; everything
                 else is kept once. *)
               List.fold_left (fun acc (m : Ast.module_form) ->
                List.fold_left (fun acc (imp : Ast.import_decl) ->
                  if List.mem imp.module_name names then acc
                   else add_merged_import acc imp) acc m.imports) [] sorted }

let tarjan_sccs (graph : (string, string list) Hashtbl.t) =
  let index = ref 0 in
  let stack : string Stack.t = Stack.create () in
  let indices : (string, int) Hashtbl.t = Hashtbl.create 16 in
  let lowlinks : (string, int) Hashtbl.t = Hashtbl.create 16 in
  let on_stack : (string, unit) Hashtbl.t = Hashtbl.create 16 in
  let sccs = ref [] in
  let rec strongconnect v =
    Hashtbl.replace indices v !index;
    Hashtbl.replace lowlinks v !index;
    incr index;
    Stack.push v stack;
    Hashtbl.replace on_stack v ();
    let neighbors = match Hashtbl.find_opt graph v with Some xs -> xs | None -> [] in
    List.iter (fun w ->
      if not (Hashtbl.mem indices w) then begin
        strongconnect w;
        let low_v = Hashtbl.find lowlinks v in
        let low_w = Hashtbl.find lowlinks w in
        Hashtbl.replace lowlinks v (min low_v low_w)
      end else if Hashtbl.mem on_stack w then begin
        let low_v = Hashtbl.find lowlinks v in
        let idx_w = Hashtbl.find indices w in
        Hashtbl.replace lowlinks v (min low_v idx_w)
      end
    ) neighbors;
    if Hashtbl.find lowlinks v = Hashtbl.find indices v then begin
      let component = ref [] in
      let continue = ref true in
      while !continue do
        let w = Stack.pop stack in
        Hashtbl.remove on_stack w;
        component := w :: !component;
        if w = v then continue := false
      done;
      sccs := !component :: !sccs
    end
  in
  Hashtbl.to_seq_keys graph |> List.of_seq |> List.sort String.compare |> List.iter (fun v ->
    if not (Hashtbl.mem indices v) then strongconnect v);
  !sccs


let lower ~(entry:Ast.module_form) originals =
 let duplicate=List.exists(fun(m:Ast.module_form)->
  List.length(List.filter(fun(n:Ast.module_form)->n.module_name=m.module_name)originals)<>1)originals in
 if duplicate then Error "Go graph contains duplicate original module owners" else
 if not(List.exists(fun(m:Ast.module_form)->m=entry)originals) then Error "Go graph lost its exact original entry" else
 let names=List.map(fun(m:Ast.module_form)->m.module_name)originals in
 let local_name name = if List.mem name names then Some name else
  if name="Tesl.CivilTime" && List.mem "CivilTime" names then Some "CivilTime" else None in
 let graph=Hashtbl.create 16 in
 List.iter(fun(m:Ast.module_form)->Hashtbl.add graph m.module_name
  (List.filter_map(fun(i:Ast.import_decl)->local_name i.module_name)m.imports |> List.sort_uniq compare))originals;
 let components=tarjan_sccs graph |> List.map(fun names -> List.filter(fun(m:Ast.module_form)->List.mem m.module_name names) originals) in
 let lowered=List.map(Migration_schema.lower_module ~modules:originals)originals in
 let errors=List.concat_map(function Ok _ -> [] | Error errors -> List.map(fun(e:Validation_common.validation_error)->e.message)errors)lowered in
 if errors<>[] then Error(String.concat "\n" errors) else
 let ownership=List.filter_map(function Ok m -> Some(Migration_form.erase m) | Error _ ->None)lowered in
 let origins=Exprs.create 64 in
 let emitted,renamed=List.fold_left(fun(targets,renamed)members ->
  if List.length members<=1 then targets,renamed else
  let targets,next=alpha_rename_cycle_members origins ~targets members in targets,next@renamed)(ownership,[])components in
 let collapsed=List.map(fun members ->
  let names=List.map(fun(m:Ast.module_form)->m.module_name)members in
  match merge_cycle_members(List.filter(fun(m:Ast.module_form)->List.mem m.module_name names)emitted) with
  | Ok m -> m,names | Error message -> failwith message)components in
 let owners=List.concat_map(fun(m,names)->List.map(fun name->name,m.Ast.module_name)names)collapsed in
 let rewrite(m:Ast.module_form) =
  {m with imports=List.fold_left(fun acc(i:Ast.import_decl)->
    let target=Option.value(List.assoc_opt i.module_name owners)~default:i.module_name in
    if target=m.module_name then acc else add_merged_import acc {i with module_name=target})[]m.imports} in
 let modules=List.map(fun(m,_)->rewrite m)collapsed in
 let entry_owner=List.assoc entry.module_name owners in
 let entry=List.find(fun(m:Ast.module_form)->m.module_name=entry_owner)modules in
 Ok {originals;modules;entry;owners;renamed;origins}
