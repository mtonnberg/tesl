(** Contextual checking of the initial additive Migration source form. The result
    describes logical values; it grants no persisted-proof, DDL or execution authority. *)
open Ast
module S = Migration_sparse
module I = Migration_inventory
module H = Migration_history_sources
module A = Migration_additive

type t = { coverage : S.t; additive : A.t; version : int; source_seals : Migration_header.checked option }
let coverage t = t.coverage
let additive t = t.additive
let version t = t.version
let source_seals t = t.source_seals
exception Invalid of S.error list
let reject code loc message = raise (Invalid [{S.code;loc;message;related=[]}])
let checked = function Ok value -> value | Error errors -> raise (Invalid errors)
let at = Checker.expr_loc
let application = Migration_form.application

let root_version (m : module_form) =
  match String.split_on_char '.' m.module_name with
  | [family;"Migrate";revision] when Migration_source.valid_family family &&
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
        | I.Newtype | I.Adt | I.Record | I.Fact | I.Codec_declaration -> true
        | I.Entity | I.Function -> false) in
      let old = eligible before previous and fresh = eligible after current in
      let namespaces declarations = List.map (fun (d : I.declaration) -> d.namespace) declarations |> List.sort_uniq compare in
      (* A record and its codec commonly share one spelling. The claim covers
         every eligible namespace with that spelling, never an arbitrary first
         lookup hit. Each namespace is still independently checked by Sparse. *)
      if old = [] || namespaces old <> namespaces fresh then
        reject "MIG024" (at expression)
          "Same must pair matching owned type/fact/codec declarations from the previous and current schemas";
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
      List.iter (fun (name,value) -> if not (List.mem name ["from";"to";"same";"entities";"fixtures"]) then
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

let check ~compiler_abi ~source (m : module_form) =
  try
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
      let previous,current = match H.adjacent_pair ~compiler_abi ~project_root ~family
          ~previous:previous_root ~current:current_root with
        | Ok pair -> pair
        | Error error -> raise (Invalid [{S.code="MIG020";loc=declaration.loc;message=error.message;
            related=[error.loc,"schema history"]}]) in
      if current.H.version <> target then reject "MIG020" (at current_expr)
        (Printf.sprintf "Migrate.V%d must target schema version %d" target target);
      let holes = entry_holes entities in
      if holes <> [] then raise (Invalid holes);
      (match List.assoc_opt "fixtures" fields with
       | None -> ()
       | Some expression when list "MIG020" expression = [] -> ()
       | Some expression -> reject "MIG020" (at expression) "nonempty compatibility fixtures require the transformation checker");
      let before = previous.H.inventory and after = current.H.inventory in
      let identities = identities before after (list "MIG024" same) in
      let definitions = record "MIG002" entities in
      let rules = ref [] in
      let entries = List.map (fun (entity,expression) ->
        let kind = match application expression with
          | "Additive", [rule_list] ->
            rules := (entity,list "MIG022" rule_list) :: !rules; S.Additive
          | "New", [] -> S.New
          | "Drop", [] -> S.Drop
          | _ -> reject "MIG016" (at expression)
            "expected Additive rules, New or Drop; row transformations require the transformation checker" in
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
      Option.iter (fun header -> ignore (checked (Migration_header.verify_unchanged header))) source_seals;
      Ok (Some {coverage;additive;version=target;source_seals})
  with Invalid errors -> Error errors

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
