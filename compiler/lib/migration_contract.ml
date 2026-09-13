open Ast
module C = Migration_canonical
module R = Migration_retained_storage
module H = Migration_row_history
module K = Migration_retained_storage_canonical
module S = Migration_sparse
module I = Migration_inventory

type selector = Column of string * string | Storage of string * string
 | Index of string * string | Trigger of string | Not_null of string * string

type operation = { selector:selector option; node:C.node }
type description = { family:string; version:int; window:R.version; settled:R.version;
 snapshot:string; behavior:string; final_generations:(string * int) list; operations:operation list }
type t = { description:description; namespace:string; plan:R.t;
 source_file:string; source_digest:string; canonical:C.node;settled_encoded:string;settled_hash:string }
exception Invalid of S.error list
let reject loc message = raise (Invalid [{S.code="MIG022";loc;message;related=[]}])
let checked = function Ok x -> x | Error e -> raise (Invalid e)
let protect f = try Ok (f ()) with
 | Invalid e -> Error e
 | Sys_error message | Invalid_argument message -> Error [{S.code="MIG013";loc=Location.dummy_loc "<contract>";message;related=[]}]
 | Unix.Unix_error(error,operation,path) -> Error [{S.code="MIG013";loc=Location.dummy_loc path;message=operation ^ ": " ^ Unix.error_message error;related=[]}]
let at = Checker.expr_loc
let atom x = C.Bytes x
let seq x = C.Seq x
let integer x = atom (string_of_int x)
let family_of history =
 match H.versions history with
 | [] -> reject (Location.dummy_loc "<contract>") "contract requires complete source history"
 | first::_ -> match Validation_common.schema_module_parts (I.root_module first.schema) with
   | Some (family,_,_) -> family
   | None -> reject (Location.dummy_loc "<contract>") "contract requires a schema family"
let find_version plan version =
 match List.find_opt (fun (v:R.version) -> v.version=version) (R.versions plan) with
 | Some v -> v
 | None -> reject (Location.dummy_loc "<contract>") "contract target is outside its checked history"
let describe plan version =
 ignore (checked (H.revalidate (R.history plan)));
 let window=find_version plan version in
 if window.windows=[] then reject (Location.dummy_loc "<contract>")
  "this version has no transforming window; an empty additive contract is unnecessary";
 let settled=checked (R.settled_version plan ~version) in
 let previous=find_version plan (version-1) in
 let family=family_of (R.history plan) in
 let schema=List.find (fun (v:H.version) -> v.version=version) (H.versions (R.history plan)) in
 let snapshot=C.digest C.Snapshot (I.snapshot schema.schema) in
 let behaviors=List.map (fun (w:R.window) -> Migration_transform_link.behavior_digest (H.link w.binding)) window.windows |> List.sort_uniq compare in
 let behavior=match behaviors with [hash] -> hash | _ -> reject (Location.dummy_loc "<contract>") "contract windows do not share one exact checked migration" in
 let per_entity=List.map (fun (before:R.entity) ->
  let after=match List.find_opt (fun (e:R.entity) -> e.source.identity=before.source.identity) settled.entities with
   | Some e -> e | None -> reject before.source.table.entity.entity_loc "contract cannot silently omit an entity" in
  let identity=before.source.identity in
  let old=List.find_opt (fun (e:R.entity) -> e.source.identity=identity) previous.entities in
  let columns=List.filter_map (fun (column:R.column) ->
   if List.exists (fun (c:R.column) -> c.name=column.name) after.columns then None else
   let logical=Option.bind old (fun old -> List.find_opt (fun (f:R.field) ->
     f.physical.name=column.name && not (List.exists (fun (current:R.field) -> current.logical.field.name=f.logical.field.name) after.projection)) old.projection) in
   let selector=match logical with Some f -> Column(identity,f.logical.field.name) | None -> Storage(identity,column.name) in
   if column.primary_key then reject before.source.table.entity.entity_loc "contract cannot retire primary-key storage";
   let prepared={column with nullable=true} in
   Some {selector=Some selector;node=seq [atom "drop-column";atom identity;K.column prepared]}) before.columns in
  let preparation=List.filter_map (fun (column:R.column) ->
   if column.nullable || List.exists (fun (c:R.column) -> c.name=column.name) after.columns then None else
   Some {selector=None;node=seq [atom "relax-retired-nullability";atom identity;
      K.column column;K.column {column with nullable=true}]}) before.columns in
  let indexes=List.filter_map (fun (index:Migration_storage.index) ->
   match List.find_opt (fun (i:Migration_storage.index) -> i.name=index.name) after.indexes with
   | Some same when same=index -> None
   | Some _ -> reject before.source.table.entity.entity_loc "contract cannot replace an index definition"
   | None -> Some {selector=Some(Index(identity,index.name));node=seq [atom "drop-index";atom identity;K.index index]}) before.indexes in
  let tighten=List.filter_map (fun (column:R.column) ->
   let prior=List.find_opt (fun (c:R.column) -> c.name=column.name) before.columns in
   match prior with
   | Some prior when prior=column -> None
   | Some prior when prior.nullable && not column.nullable && {prior with nullable=false}=column ->
     let logical=List.find (fun (f:R.field) -> f.physical.name=column.name) after.projection in
     Some {selector=Some(Not_null(identity,logical.logical.field.name));node=seq [atom "set-not-null";atom identity;K.column prior;K.column column]}
   | _ -> reject before.source.table.entity.entity_loc "settled column differs beyond checked nullability tightening") after.columns in
  let triggers=List.filter_map (fun (w:R.window) -> if w.after.source.identity<>identity then None else
   Some {selector=Some(Trigger identity);node=seq [atom "drop-invalidation";atom identity;
    integer w.before.source.generation;integer w.after.source.generation;
    seq (List.map (fun (c:R.column) -> atom c.name) w.invalidation_columns)]}) window.windows in
  let marker=if before.marker_default_generation=after.marker_default_generation then [] else
   [{selector=None;node=seq [atom "set-insert-generation";atom identity;
     integer before.marker_default_generation;integer after.marker_default_generation]}] in
  preparation,(indexes @ triggers @ columns @ tighten @ marker)) window.entities in
 (* Every obsolete NOT NULL column is prepared before a receipt can select
    settled inserts. The reviewed drop authorizes this prerequisite; no extra
    source selector grants an independent nullability relaxation. *)
 let operations=List.concat_map fst per_entity @ List.concat_map snd per_entity in
 let final_generations=List.map (fun (w:R.window) -> w.after.source.identity,w.after.source.generation) window.windows |> List.sort compare in
 {family;version;window;settled;snapshot;behavior;final_generations;operations}
let quote_source text =
 let out=Buffer.create(String.length text+2) in
 Buffer.add_char out '"';
 String.iter(function
  | '"' -> Buffer.add_string out "\\\""
  | '\\' -> Buffer.add_string out "\\\\"
  | '\n' -> Buffer.add_string out "\\n"
  | '\r' -> Buffer.add_string out "\\r"
  | '\t' -> Buffer.add_string out "\\t"
  | c -> Buffer.add_char out c) text;
 Buffer.add_char out '"';Buffer.contents out
let name_source name = match Lexer.tokenize "<contract-name>" name |> List.filter(fun token ->
 match token.Lexer.tok with Token.NEWLINE | Token.EOF -> false | _ -> true) with
 | [{Lexer.tok=Token.IDENT value;_}] when value=name -> name
 | _ -> quote_source name
let selector_source = function
 | Column(e,f) -> "Column " ^ e ^ " " ^ name_source f
 | Storage(e,f) -> "Storage " ^ e ^ " " ^ quote_source f
 | Index(e,f) -> "Index " ^ e ^ " " ^ name_source f
 | Trigger e -> "Trigger " ^ e
 | Not_null(e,f) -> "NotNull " ^ e ^ " " ^ name_source f
let source ~plan ~version = protect (fun () ->
 let d=describe plan version in
 let selected=List.filter_map (fun o -> o.selector) d.operations in
 let drops=List.filter (function Not_null _ -> false | _ -> true) selected in
 let tighten=List.filter (function Not_null _ -> true | _ -> false) selected in
 let render xs="[" ^ String.concat ", " (List.map selector_source xs) ^ "]" in
 Printf.sprintf {|module %s.Migrate.V%dContract exposing [contract]
import Tesl.Migration exposing [Contract, Drop(..), Tighten(..)]
import %s.Migrate.V%d

# Reviewed source authority only; execute explicitly after the rolling update.
# Marker defaults are derived from this migration's checked generation transition.
contract = Contract {
  of: %s.Migrate.V%d
  drops: %s
  tighten: %s
  promote: []
}
|} d.family version d.family version d.family version (render drops) (render tighten))
let bare = function EVar {name;_} | EConstructor {name;args=[];_} -> name
 | e -> reject (at e) "contract objects require literal entity/field identifiers"
let fields = function ERecord {fields;type_hint=None;_} -> fields
 | e -> reject (at e) "Contract requires a literal record"
let elements = function EList {elems;_} -> elems
 | e -> reject (at e) "Contract object inventory must be a literal list"
let object_name = function ELit {lit=LString name;_} -> name | e -> bare e
let selector e = match Migration_form.application e with
 | "Column",[entity;field] -> Column(bare entity,object_name field)
 | "Storage",[entity;ELit {lit=LString physical;_}] -> Storage(bare entity,physical)
 | "Index",[entity;name] -> Index(bare entity,object_name name)
 | "Trigger",[entity] -> Trigger(bare entity)
 | "NotNull",[entity;field] -> Not_null(bare entity,object_name field)
 | _ -> reject (at e) "expected Column, Storage, Index, Trigger or NotNull with exact literal operands"
let root m = match Validation_common.schema_module_parts m.module_name with
 | Some(family,"Migrate",[name]) when Filename.check_suffix name "Contract" ->
   let revision=String.sub name 0 (String.length name-8) in
   if Migration_source.valid_revision revision && revision<>"VCurrent" then
    family,int_of_string (String.sub revision 1 (String.length revision-1))
   else reject (Location.dummy_loc m.source_file) "contract requires its family's Migrate.V<n>Contract module"
 | _ -> reject (Location.dummy_loc m.source_file) "contract requires its family's Migrate.V<n>Contract module"
let staged_nullability ~family ~namespace ~version ~window_hash operations =
 List.concat_map (fun operation -> match operation with
  | {selector=Some(Not_null(entity,_));node=C.Seq [C.Bytes "set-not-null";identity;prior;(C.Seq(C.Bytes physical::_) as current)]} ->
    (* Name identity uses the already checked window, avoiding a dependency on
       the Contract hash that will itself contain these operations. *)
    let digest=C.digest C.Contract (seq [atom "tesl-row-not-null-name-v1";
      atom family;atom namespace;integer version;atom window_hash;atom entity;atom physical]) in
    let name="tesl_nn_" ^ String.sub digest 0 48 in
    let absent=seq [atom "absent"] in
    let proof valid=seq [atom "not-null-check";atom name;atom physical;atom valid] in
    let derived tag before after={selector=None;node=seq [atom tag;identity;before;after]} in
    [derived "add-not-null-check" absent (proof "false");
     derived "validate-not-null-check" (proof "false") (proof "true");
     {operation with node=seq [atom "set-not-null";identity;prior;current]};
     derived "drop-not-null-check" (proof "true") absent]
  | _ -> [operation]) operations
let check ~plan ~namespace ~file ~source = protect (fun () ->
 let m=match Parser.parse_module file source with Ok m -> m | Err e -> reject e.loc e.msg in
 (match Frontend_check.module_complexity_diagnostics m with [] -> () | d::_ -> reject (Location.dummy_loc file) d.message);
 let family,version=root m in
 let d=describe plan version in
 if family<>d.family then reject (Location.dummy_loc file) "contract belongs to another checked schema family";
 let decl=match m.decls with [DConst c] when c.name="contract" -> c
 | _ -> reject (Location.dummy_loc file) "a contract module contains only its reviewed `contract` declaration" in
 if not (Migration_form.imported_name m "Contract") then reject decl.loc "import Contract from Tesl.Migration";
 let record=match Migration_form.application decl.value with "Contract",[record] -> fields record
 | _ -> reject decl.loc "expected `contract = Contract { of, drops, tighten, promote }`" in
 if List.sort compare (List.map fst record)<>["drops";"of";"promote";"tighten"] then
  reject decl.loc "Contract requires exactly of, drops, tighten and promote, without duplicates";
 let expected=Printf.sprintf "%s.Migrate.V%d" family version in
 let of_expr=List.assoc "of" record in
 if Migration_form.application of_expr<>(expected,[]) then reject (at of_expr) "Contract.of must name its exact checked migration root";
 if not (List.exists (fun (i:import_decl) -> i.module_name=expected) m.imports) then reject decl.loc "import the exact migration named by Contract.of";
 List.iter (fun (i:import_decl) -> if i.module_name<>"Tesl.Migration" && i.module_name<>expected then
   reject i.loc "contract modules import only Tesl.Migration and their exact migration root") m.imports;
 if elements (List.assoc "promote" record)<>[] then reject (at (List.assoc "promote" record)) "contract index promotion requires its checked promotion protocol";
 let read name expected_tighten=elements (List.assoc name record) |> List.map (fun e ->
  let value=selector e in
  let is_tighten=match value with Not_null _ -> true | _ -> false in
  if is_tighten<>expected_tighten then reject (at e) "contract operation is in the wrong object list";
  let ctor=fst (Migration_form.application e) in
  if not (Migration_form.imported_name m ctor) then reject (at e) ("import contract constructor " ^ ctor);
  value) in
 let selected=read "drops" false @ read "tighten" true in
 if List.sort_uniq compare selected<>List.sort compare selected then reject decl.loc "duplicate contract object authority";
 let expected=List.filter_map (fun o -> o.selector) d.operations |> List.sort compare in
 if List.sort compare selected<>expected then reject decl.loc
  ("contract must name exactly its checked storage difference; expected " ^ String.concat ", " (List.map selector_source expected));
 let window_hash=snd (H.contract C.Migration (K.version_node ~family ~namespace plan d.window)) in
 let d={d with operations=staged_nullability ~family ~namespace ~version ~window_hash d.operations} in
 let settled_encoded,settled_hash=H.contract C.Migration (K.settled_node ~family ~namespace plan d.settled) in
 let canonical=seq [atom "tesl-row-contract-v1";atom family;atom namespace;integer version;
  atom d.snapshot;atom d.behavior;atom window_hash;atom settled_hash;
  seq(List.map (fun (e,g) -> seq[atom e;integer g]) d.final_generations);
  seq(List.map (fun o -> o.node) d.operations)] in
 {description=d;namespace;plan;source_file=file;source_digest=Migration_hash.digest source;canonical;settled_encoded;settled_hash})
let version t=t.description.version
let family t=t.description.family
let namespace t=t.namespace
let source_file t=t.source_file
let source_digest t=t.source_digest
let window t=t.description.window
let settled t=t.description.settled
let final_generations t=t.description.final_generations
let operations t=List.map (fun o -> o.node) t.description.operations
let canonical t=t.canonical
let digest t=C.digest C.Contract t.canonical
let encoded t=fst(H.contract C.Contract t.canonical)
let settled_encoded t=t.settled_encoded
let settled_hash t=t.settled_hash
let revalidate t=protect(fun () ->
 ignore(checked(H.revalidate(R.history t.plan)));
 let current=try Source_input.without_pinned_files(fun () -> Source_input.read t.source_file) with Sys_error message -> reject (Location.dummy_loc t.source_file) message in
 if Migration_hash.digest current<>t.source_digest then reject (Location.dummy_loc t.source_file) "contract source changed after checking")

(* Resolve CLI-relative spelling without following a symlink or collapsing `..`
   across one. The overlay's canonical-directory checks still reject aliases. *)
let rec absolute_source_path file =
 if Filename.is_relative file then absolute_source_path (Filename.concat (Sys.getcwd ()) file)
 else let parent=Filename.dirname file in
 if parent=file then file else
 let parent=absolute_source_path parent in
 match Filename.basename file with "." -> parent | name -> Filename.concat parent name

let check_module ~compiler_abi ~source (m:module_form) = protect(fun () ->
 let present=List.exists(function DConst c -> Migration_form.is_contract m c | _ -> false) m.decls in
 let contract_root=match Validation_common.schema_module_parts m.module_name with
  | Some(_,"Migrate",[name]) -> Filename.check_suffix name "Contract" | _ -> false in
 if not present && not contract_root then None else
 let family,_=root m in
 let file=absolute_source_path m.source_file in
 let project_root=Filename.dirname(Filename.dirname(Filename.dirname file)) in
 let relative=Option.get(Validation_common.schema_module_relative_path m.module_name) in
 if Filename.concat project_root relative<>file then reject (Location.dummy_loc m.source_file) "contract source must use its canonical schema-family path";
 Source_input.with_overlays ~project_root:(Option.value(Source_input.project_root()) ~default:project_root) [file,source] (fun () ->
  let h=match Migration_history_sources.discover ~compiler_abi ~project_root ~family with
   | Ok h -> h | Error e -> reject e.loc e.message in
  let schemas=Migration_history_sources.frozen h @ [Migration_history_sources.current h] |> List.map(fun(s:Migration_history_sources.schema)->s.inventory) in
  let edges=Migration_history_sources.completed_migrations h @ Option.to_list(Migration_history_sources.current_migration h) |> List.map(fun(s:Migration_history_sources.migration_source)->
   let ast=match Parser.parse_module s.path s.contents with Ok m -> m | Err e -> reject e.loc e.msg in
   match checked(Migration_declaration.check ~compiler_abi ~source:s.contents ast) with Some d -> d | None -> reject (Location.dummy_loc s.path) "contract requires its checked migration declaration") in
  let history=checked(H.check ~schemas ~edges) in
  let plan=checked(R.plan history) in
  Some(checked(check ~plan ~namespace:"contract_validation" ~file ~source))))
let diagnostics source m =
 let relevant=List.exists(function DConst c -> Migration_form.is_contract m c | _ -> false) m.decls ||
   (match Validation_common.schema_module_parts m.module_name with Some(_,"Migrate",[name]) -> Filename.check_suffix name "Contract" | _ -> false) in
 if not relevant then [] else
 match Migration_abi.current () with
 | Error error -> Migration_declaration.diagnostics_of_errors [{S.code="MIG013";loc=Location.dummy_loc error.path;message=error.message;related=[]}]
 | Ok abi -> match check_module ~compiler_abi:(Migration_abi.id abi) ~source m with
   | Ok _ -> [] | Error errors -> Migration_declaration.diagnostics_of_errors errors
