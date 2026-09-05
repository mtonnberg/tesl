open Alcotest

let rec mkdir path =
  if not (Sys.file_exists path) then begin mkdir (Filename.dirname path); Unix.mkdir path 0o700 end
let rec remove path =
  if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  end else Sys.remove path
let with_project f =
  let root = Filename.temp_file "tesl-migration-fact-owner-" ".dir" in
  Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let write relative source =
      let path = Filename.concat root relative in mkdir (Filename.dirname path);
      Out_channel.with_open_bin path (fun channel -> output_string channel source); path in
    ignore (write "tesl.toml" ""); f root write)
let contains needle haystack =
  try ignore (Str.search_forward (Str.regexp_string needle) haystack 0); true with Not_found -> false
let parse path source = match Parser.parse_module path source with
  | Ok m -> m | Err e -> fail e.msg
let imports = {|import Tesl.Prelude exposing [Bool(..), Int, String, Fact]
import Tesl.Maybe exposing [Maybe(..)]
|}
let owner revision = "module NotesSchema." ^ revision ^ " exposing [InBounds, accept, Note]\n" ^ imports ^ {|
fact InBounds (lo: Int) (hi: Int) (n: Int)
establish accept(n: Int) -> Maybe (Fact (InBounds 1 100 n)) =
  if n >= 1 && n <= 100 then
    Something (InBounds 1 100 n)
  else
    Nothing
entity Note table "notes" primaryKey id { id: String, amount: Int ::: InBounds 1 100 amount }
|}
let setup write =
  ignore (write "schema/notes/v-current.tesl" (owner "VCurrent"));
  ignore (write "schema/notes/v1.tesl" (owner "V1"))
let importer module_name revision body = "module " ^ module_name ^ " exposing []\n" ^ imports ^
  "import NotesSchema." ^ revision ^ " exposing [InBounds]\n" ^ body
let ownership_error path =
  let source = In_channel.with_open_bin path In_channel.input_all in
  let m = parse path source in
  check bool "core checker reports fact ownership, independently of other gates" true
    (List.exists (fun (e : Type_system.type_error) -> contains "fact ownership violation" e.message) (Checker.check_module m));
  let errors = Compile.check_file path in
  check bool "public diagnostics retain the ownership error" true
    (List.exists (fun (e : Compile.diagnostic) -> e.severity = "error" && contains "fact ownership violation" e.message) errors)
let accepted path =
  let errors = Compile.check_file path |> List.filter (fun (d : Compile.diagnostic) -> d.severity = "error") in
  if errors <> [] then fail (String.concat "\n" (List.map (fun (d : Compile.diagnostic) -> d.message) errors))

let reject_direct_fact () = with_project (fun _ write ->
  setup write;
  let path = write "app.tesl" (importer "App" "VCurrent" {|
establish forge(n: Int) -> Fact (InBounds 1 100 n) =
  InBounds 1 100 n
|}) in
  ownership_error path)

let reject_optional_fact () = with_project (fun _ write ->
  setup write;
  let path = write "app.tesl" (importer "App" "VCurrent" {|
establish forge(n: Int) -> Maybe (Fact (InBounds 1 100 n)) =
  Something (InBounds 1 100 n)
|}) in
  ownership_error path)

let migration_is_not_a_producer () = with_project (fun _ write ->
  setup write;
  List.iter (fun revision ->
    let path = write "migrations/notes/v2.tesl" (importer "NotesSchema.Migrate.V2" revision {|
establish forge(n: Int) -> Fact (InBounds 1 100 n) =
  InBounds 1 100 n
|}) in
    ownership_error path) ["V1"; "VCurrent"])

let schema_child_is_not_owner () = with_project (fun _ write ->
  setup write;
  let path = write "schema/notes/v-current/child.tesl"
    (importer "NotesSchema.VCurrent.Child" "VCurrent" {|
establish forge(n: Int) -> Maybe (Fact (InBounds 1 100 n)) =
  Something (InBounds 1 100 n)
|}) in
  ownership_error path)

let arity_matrix () = with_project (fun _ write ->
  List.iter (fun arity ->
    let params = List.init arity (fun i -> Printf.sprintf "(a%d: Int)" i) |> String.concat " " in
    let args = List.init arity (fun i -> if i = arity - 1 then "n" else string_of_int (i + 1)) |> String.concat " " in
    ignore (write "schema/notes/v-current.tesl" ("module NotesSchema.VCurrent exposing [Owned]\n" ^ imports ^
      "fact Owned " ^ params ^ "\n"));
    List.iter (fun optional ->
      let proof = "Fact (Owned " ^ args ^ ")" in
      let ret = if optional then "Maybe (" ^ proof ^ ")" else proof in
      let value = "Owned " ^ args in
      let body = if optional then "Something (" ^ value ^ ")" else value in
      let path = write "app.tesl" ("module App exposing []\n" ^ imports ^
        "import NotesSchema.VCurrent exposing [Owned]\nestablish forge(n: Int) -> " ^ ret ^ " =\n  " ^ body ^ "\n") in
      ownership_error path) [false; true]) [1; 2; 3; 6])

let owner_and_forwarding () = with_project (fun _ write ->
  setup write;
  accepted (write "schema/notes/v-current.tesl" (owner "VCurrent"));
  let path = write "app.tesl" ("module App exposing []\n" ^ imports ^ {|
import NotesSchema.VCurrent exposing [InBounds, accept]
fn forward(n: Int) -> Bool =
  case accept n of
    Something _ -> True
    Nothing -> False
fn retain(n: Int ::: InBounds 1 100 n) -> n: Int ::: InBounds 1 100 n =
  n
|}) in
  accepted path)

let ordinary_library_ownership () = with_project (fun _ write ->
  ignore (write "bounds.tesl" ("module Bounds exposing [InBounds]\n" ^ imports ^
    "fact InBounds (lo: Int) (hi: Int) (n: Int)\n"));
  let path = write "app.tesl" ("module App exposing []\n" ^ imports ^ {|
import Bounds exposing [InBounds]
establish forge(n: Int) -> Fact (InBounds 1 100 n) =
  InBounds 1 100 n
|}) in
  ownership_error path)

let qualified_lowered_predicate () = with_project (fun root write ->
  setup write;
  let source = importer "App" "VCurrent" {|
establish forge(n: Int) -> Fact (InBounds 1 100 n) =
  InBounds 1 100 n
|} in
  let m = parse (Filename.concat root "app.tesl") source in
  (* Qualification also occurs inside compiler-produced ASTs. Surface proof
     annotations do not yet parse dotted predicate names in every position. *)
  let rec qualify = function
    | Ast.TName n when n.name = "InBounds" -> Ast.TName {n with name="NotesSchema.VCurrent.InBounds"}
    | Ast.TApp t -> Ast.TApp {t with head=qualify t.head; arg=qualify t.arg}
    | other -> other in
  let decls = List.map (function
    | Ast.DFunc fd -> (match fd.return_spec with
        | Ast.RetPlain r -> Ast.DFunc {fd with return_spec=Ast.RetPlain {r with ty=qualify r.ty}}
        | _ -> fail "expected a plain Fact return in fixture")
    | other -> other) m.decls in
  let errors = Checker.check_module {m with decls} in
  check bool "qualification is not ownership authority" true
    (List.exists (fun (e : Type_system.type_error) -> contains "fact ownership violation" e.message &&
      contains "NotesSchema.VCurrent.InBounds" e.message) errors))

let detached_fact_forwarding () = with_project (fun _ write ->
  setup write;
  let path = write "app.tesl" (importer "App" "VCurrent" {|
fn retain(n: Int, proof: Fact (InBounds 1 100 n)) -> Fact (InBounds 1 100 n) =
  proof
fn alias(n: Int, proof: Fact (InBounds 1 100 n)) -> Fact (InBounds 1 100 n) =
  let kept = proof
  kept
fn choose(n: Int, first: Fact (InBounds 1 100 n), second: Fact (InBounds 1 100 n), preferFirst: Bool)
  -> Fact (InBounds 1 100 n) =
  if preferFirst then
    first
  else
    second
fn relay(n: Int, proof: Fact (InBounds 1 100 n)) -> Fact (InBounds 1 100 n) =
  retain n proof
|}) in
  accepted path)

let detached_fact_refusals () = with_project (fun _ write ->
  setup write;
  List.iter (fun (label, body) ->
    let path = write "app.tesl" (importer "App" "VCurrent" body) in
    let errors = Compile.check_file path |> List.filter (fun (d : Compile.diagnostic) -> d.severity = "error") in
    check bool ("cannot reuse a Fact by " ^ label) true (errors <> [])) [
    "changing its subject", {|
fn swap(n: Int, m: Int, proof: Fact (InBounds 1 100 n)) -> Fact (InBounds 1 100 m) =
  proof
|};
    "changing its lower bound", {|
fn strengthen(n: Int, proof: Fact (InBounds 1 100 n)) -> Fact (InBounds 2 100 n) =
  proof
|};
    "changing its upper bound", {|
fn strengthen(n: Int, proof: Fact (InBounds 1 100 n)) -> Fact (InBounds 1 99 n) =
  proof
|};
    "implicitly attaching it to a raw value", {|
fn unattached(n: Int, proof: Fact (InBounds 1 100 n)) -> n: Int ::: InBounds 1 100 n =
  n
|};
    "returning a fresh constructor", {|
fn fabricate(n: Int, proof: Fact (InBounds 1 100 n)) -> Fact (InBounds 1 100 n) =
  InBounds 1 100 n
|};
    "treating an optional proof as present", {|
fn unwrap(n: Int, proof: Maybe (Fact (InBounds 1 100 n))) -> Fact (InBounds 1 100 n) =
  proof
|};
    "using the wrong branch's proof", {|
fn choose(n: Int, m: Int, first: Fact (InBounds 1 100 n), second: Fact (InBounds 1 100 m), preferFirst: Bool)
  -> Fact (InBounds 1 100 n) =
  if preferFirst then
    first
  else
    second
|};
  ])

let retained_editor_checks () =
  let enabled = !Query_cache.enabled in
  Query_cache.set_enabled true;
  Fun.protect ~finally:(fun () -> Query_cache.set_enabled enabled) (fun () ->
    reject_direct_fact ();
    reject_optional_fact ();
    owner_and_forwarding ())

let () = run "migration-fact-ownership" ["sealed producers", [
  test_case "application cannot mint a schema's multi-argument fact" `Quick reject_direct_fact;
  test_case "optional Fact does not bypass ownership" `Quick reject_optional_fact;
  test_case "migration modules cannot mint old or current schema facts" `Quick migration_is_not_a_producer;
  test_case "schema membership does not grant another module's minting authority" `Quick schema_child_is_not_owner;
  test_case "all predicate arities under Fact and Maybe Fact" `Quick arity_matrix;
  test_case "declaring owner and ordinary proof forwarding remain valid" `Quick owner_and_forwarding;
  test_case "ordinary library facts retain the same ownership rule" `Quick ordinary_library_ownership;
  test_case "qualified compiler AST cannot bypass ownership" `Quick qualified_lowered_predicate;
  test_case "ordinary functions forward received detached facts" `Quick detached_fact_forwarding;
  test_case "detached facts retain their subjects, bounds and presence" `Quick detached_fact_refusals;
  test_case "retained editor query checks preserve ownership" `Quick retained_editor_checks;
]]
