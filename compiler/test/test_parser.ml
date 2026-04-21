(** Parser tests — comprehensive coverage of all Tesl constructs.

    Each test parses a snippet and verifies the resulting AST shape.
    Adversarial tests check that parse errors are reported correctly. *)

open Ast
open Parser

(* ── Helpers ─────────────────────────────────────────────────────────────── *)

let parse src = parse_module "<test>" src

let assert_ok src f =
  match parse src with
  | Ok m -> f m
  | Err e -> Alcotest.failf "parse error: %s (at %s:%d:%d)"
               e.msg e.loc.file (e.loc.start.line + 1) (e.loc.start.col + 1)

let assert_err src =
  match parse src with
  | Err _ -> ()
  | Ok _ -> Alcotest.fail "expected parse error but succeeded"

let decl_count m = List.length m.decls
let first_decl m = List.hd m.decls
let _nth_decl n m = List.nth m.decls n

(* ── Module header tests ─────────────────────────────────────────────────── *)

let test_module_header () =
  let src = "#lang tesl\nmodule Hello exposing [foo, bar]\nimport Tesl.Prelude exposing [Int]\n" in
  assert_ok src (fun m ->
    Alcotest.(check string) "module name" "Hello" m.module_name;
    Alcotest.(check int) "export count" 2 (List.length m.exports);
    Alcotest.(check int) "import count" 1 (List.length m.imports);
    Alcotest.(check string) "first import" "Tesl.Prelude" (List.hd m.imports).module_name
  )

let test_module_adt_exports () =
  let src = "#lang tesl\nmodule Foo exposing [Color(..), Weekday(..)]\n" in
  assert_ok src (fun m ->
    let exports = m.exports in
    Alcotest.(check int) "two exports" 2 (List.length exports);
    match exports with
    | [ExportAdt "Color"; ExportAdt "Weekday"] -> ()
    | _ -> Alcotest.fail "expected ADT exports"
  )

let test_module_import_qualified () =
  let src = "#lang tesl\nmodule Foo exposing []\nimport Tesl.Dict\n" in
  assert_ok src (fun m ->
    let imp = List.hd m.imports in
    Alcotest.(check string) "module name" "Tesl.Dict" imp.module_name;
    match imp.names with
    | ImportAll -> ()
    | _ -> Alcotest.fail "expected qualified-only import"
  )

(* ── Function declaration tests ─────────────────────────────────────────── *)

let test_fn_simple () =
  let src = {|#lang tesl
module Foo exposing [add]
import Tesl.Prelude exposing [Int]
fn add(x: Int, y: Int) -> Int =
  x + y
|} in
  assert_ok src (fun m ->
    match first_decl m with
    | DFunc fd ->
      Alcotest.(check string) "fn name" "add" fd.name;
      Alcotest.(check int) "param count" 2 (List.length fd.params);
      Alcotest.(check string) "first param" "x" (List.hd fd.params).name;
      (match fd.return_spec with
       | RetPlain { ty = TName { name = "Int"; _ }; _ } -> ()
       | _ -> Alcotest.fail "expected plain Int return")
    | _ -> Alcotest.fail "expected DFunc"
  )

let test_fn_string_interpolation () =
  let src = {|#lang tesl
module Foo exposing [greet]
import Tesl.Prelude exposing [String]
fn greet(name: String) -> String =
  "Hello, ${name}!"
|} in
  assert_ok src (fun m ->
    match first_decl m with
    | DFunc fd ->
      (match fd.body with
       | ELit { lit = LInterp segs; _ } ->
         Alcotest.(check bool) "has interpolation" true (segs <> [])
       | _ -> Alcotest.fail "expected interpolated string body")
    | _ -> Alcotest.fail "expected DFunc"
  )

let test_fn_case_expression () =
  let src = {|#lang tesl
module Foo exposing [colorName]
import Tesl.Prelude exposing [String]
fn colorName(c: Color) -> String =
  case c of
    Red -> "red"
    Green -> "green"
    Blue -> "blue"
|} in
  assert_ok src (fun m ->
    match first_decl m with
    | DFunc fd ->
      (match fd.body with
       | ECase { arms; _ } ->
         Alcotest.(check int) "three arms" 3 (List.length arms);
         (match (List.hd arms).pattern with
          | PNullary { ctor = "Red"; _ } -> ()
          | _ -> Alcotest.fail "first arm should be Red")
       | _ -> Alcotest.fail "expected case expression")
    | _ -> Alcotest.fail "expected DFunc"
  )

let test_fn_if_else () =
  let src = {|#lang tesl
module Foo exposing [f]
import Tesl.Prelude exposing [Bool, Int]
fn f(b: Bool, n: Int) -> Int =
  if b then
    n
  else
    0
|} in
  assert_ok src (fun m ->
    match first_decl m with
    | DFunc fd ->
      (match fd.body with
       | EIf _ -> ()
       | _ -> Alcotest.fail "expected if expression")
    | _ -> Alcotest.fail "expected DFunc"
  )

let test_fn_let_bindings () =
  let src = {|#lang tesl
module Foo exposing [f]
import Tesl.Prelude exposing [Int]
fn f(x: Int) -> Int =
  let y = x + 1
  y * 2
|} in
  assert_ok src (fun m ->
    match first_decl m with
    | DFunc fd ->
      (match fd.body with
       | ELet { name = "y"; _ } -> ()
       | _ -> Alcotest.fail "expected let binding")
    | _ -> Alcotest.fail "expected DFunc"
  )

let test_fn_typed_let_binding () =
  let src = {|#lang tesl
module Foo exposing [f]
import Tesl.Prelude exposing [Int]
fn f(x: Int) -> Int =
  let y: Int = x + 1
  y * 2
|} in
  assert_ok src (fun m ->
    match first_decl m with
    | DFunc fd ->
      (match fd.body with
       | ELet { name = "y"; declared_type = Some (TName { name = "Int"; _ }); declared_proof = None; _ } -> ()
       | _ -> Alcotest.fail "expected typed let binding")
    | _ -> Alcotest.fail "expected DFunc"
  )

(* ── Check / auth tests ──────────────────────────────────────────────────── *)

let test_check_function () =
  let src = {|#lang tesl
module Foo exposing [isValidPort]
import Tesl.Prelude exposing [Int]
check isValidPort(port: Int) -> port: Int::: ValidPort port =
  if 1 <= port && port <= 65535 then
    ok port::: ValidPort port
  else
    fail 400 "port must be between 1 and 65535"
|} in
  assert_ok src (fun m ->
    match first_decl m with
    | DFunc fd ->
      Alcotest.(check string) "name" "isValidPort" fd.name;
      (match fd.kind with CheckKind -> () | _ -> Alcotest.fail "expected CheckKind");
      (match fd.return_spec with
       | RetAttached { binding = b; _ } ->
         Alcotest.(check string) "return binding name" "port" b.name;
         (match b.proof_ann with
          | Some (PredApp { pred = "ValidPort"; _ }) -> ()
          | _ -> Alcotest.fail "expected ValidPort proof")
       | _ -> Alcotest.fail "expected RetAttached")
    | _ -> Alcotest.fail "expected DFunc"
  )

let test_auth_function () =
  let src = {|#lang tesl
module Foo exposing [cookieAuth]
import Tesl.Http exposing [HttpRequest]
import Tesl.Prelude exposing [String]
auth cookieAuth(request: HttpRequest) -> user: String::: Authenticated user =
  fail 401 "not authenticated"
|} in
  assert_ok src (fun m ->
    match first_decl m with
    | DFunc fd ->
      Alcotest.(check string) "name" "cookieAuth" fd.name;
      (match fd.kind with AuthKind -> () | _ -> Alcotest.fail "expected AuthKind")
    | _ -> Alcotest.fail "expected DFunc"
  )

let test_handler_with_capabilities () =
  let src = {|#lang tesl
module Foo exposing [createTask]
import Tesl.Prelude exposing [String]
handler createTask(user: String) -> String
  requires [taskDbWrite] =
  "ok"
|} in
  assert_ok src (fun m ->
    match first_decl m with
    | DFunc fd ->
      (match fd.kind with HandlerKind -> () | _ -> Alcotest.fail "expected HandlerKind");
      Alcotest.(check int) "one capability" 1 (List.length fd.capabilities);
      Alcotest.(check string) "capability" "taskDbWrite" (List.hd fd.capabilities)
    | _ -> Alcotest.fail "expected DFunc"
  )

(* ── Type declaration tests ──────────────────────────────────────────────── *)

let test_newtype () =
  let src = {|#lang tesl
module Foo exposing [UserId]
type UserId = String
|} in
  assert_ok src (fun m ->
    match first_decl m with
    | DType (TypeNewtype { name = "UserId"; base_type = TName { name = "String"; _ }; _ }) -> ()
    | _ -> Alcotest.fail "expected TypeNewtype UserId"
  )

let test_adt_nullary () =
  let src = {|#lang tesl
module Foo exposing [Color(..)]
type Color
  = Red
  | Green
  | Blue
|} in
  assert_ok src (fun m ->
    match first_decl m with
    | DType (TypeAdt { name = "Color"; variants; _ }) ->
      Alcotest.(check int) "three variants" 3 (List.length variants);
      Alcotest.(check string) "first variant" "Red" (List.hd variants).ctor
    | _ -> Alcotest.fail "expected TypeAdt Color"
  )

let test_adt_with_fields () =
  let src = {|#lang tesl
module Foo exposing [Shape(..)]
type Shape
  = Circle radius:Int
  | Rectangle width:Int height:Int
  | Point
|} in
  assert_ok src (fun m ->
    match first_decl m with
    | DType (TypeAdt { name = "Shape"; variants; _ }) ->
      Alcotest.(check int) "three variants" 3 (List.length variants);
      let circle = List.hd variants in
      Alcotest.(check string) "circle ctor" "Circle" circle.ctor;
      Alcotest.(check int) "circle has 1 field" 1 (List.length circle.fields)
    | _ -> Alcotest.fail "expected TypeAdt Shape"
  )

(* ── Record declaration tests ────────────────────────────────────────────── *)

let test_record_simple () =
  let src = {|#lang tesl
module Foo exposing [Task]
record Task {
  id: String
  title: String
  priority: Int
  done: Bool
}
|} in
  assert_ok src (fun m ->
    match first_decl m with
    | DRecord r ->
      Alcotest.(check string) "record name" "Task" r.name;
      Alcotest.(check int) "field count" 4 (List.length r.fields);
      Alcotest.(check string) "first field" "id" (List.hd r.fields).name
    | _ -> Alcotest.fail "expected DRecord"
  )

let test_record_with_proof_fields () =
  let src = {|#lang tesl
module Foo exposing [NewNote]
record NewNote {
  title: String::: SafeTitle title
  content: String::: SafeContent content
}
|} in
  assert_ok src (fun m ->
    match first_decl m with
    | DRecord r ->
      let title_field = List.hd r.fields in
      (match title_field.proof_ann with
       | Some (PredApp { pred = "SafeTitle"; _ }) -> ()
       | _ -> Alcotest.fail "expected SafeTitle proof on title field")
    | _ -> Alcotest.fail "expected DRecord"
  )

(* ── Entity tests ────────────────────────────────────────────────────────── *)

let test_entity () =
  let src = {|#lang tesl
module Foo exposing [Todo]
entity Todo table "todos" primaryKey id {
  id: String
  title: String
  done: Bool
}
|} in
  assert_ok src (fun m ->
    match first_decl m with
    | DEntity e ->
      Alcotest.(check string) "entity name" "Todo" e.name;
      Alcotest.(check string) "table name" "todos" e.table;
      Alcotest.(check string) "primary key" "id" e.primary_key;
      Alcotest.(check int) "field count" 3 (List.length e.fields)
    | _ -> Alcotest.fail "expected DEntity"
  )

(* ── Capability tests ────────────────────────────────────────────────────── *)

let test_capability () =
  let src = {|#lang tesl
module Foo exposing []
capability taskDbRead implies dbRead
|} in
  assert_ok src (fun m ->
    match first_decl m with
    | DCapability c ->
      Alcotest.(check string) "name" "taskDbRead" c.name;
      Alcotest.(check int) "one implication" 1 (List.length c.implies);
      Alcotest.(check string) "implies dbRead" "dbRead" (List.hd c.implies)
    | _ -> Alcotest.fail "expected DCapability"
  )

let test_capability_no_implies () =
  let src = {|#lang tesl
module Foo exposing []
capability noteAuth
|} in
  assert_ok src (fun m ->
    match first_decl m with
    | DCapability c ->
      Alcotest.(check string) "name" "noteAuth" c.name;
      Alcotest.(check int) "no implications" 0 (List.length c.implies)
    | _ -> Alcotest.fail "expected DCapability"
  )

(* ── Fact declaration tests ───────────────────────────────────────────────── *)

let test_fact_with_params () =
  let src = {|#lang tesl
module Foo exposing [ValidPort]
fact ValidPort (port: Int)
|} in
  assert_ok src (fun m ->
    match first_decl m with
    | DFact f ->
      Alcotest.(check string) "name" "ValidPort" f.name;
      Alcotest.(check int) "one param" 1 (List.length f.params);
      Alcotest.(check string) "param name" "port" (List.hd f.params).name
    | _ -> Alcotest.fail "expected DFact"
  )

let test_fact_no_params () =
  let src = {|#lang tesl
module Foo exposing [IsReady]
fact IsReady
|} in
  assert_ok src (fun m ->
    match first_decl m with
    | DFact f ->
      Alcotest.(check string) "name" "IsReady" f.name;
      Alcotest.(check int) "no params" 0 (List.length f.params)
    | _ -> Alcotest.fail "expected DFact"
  )



let test_codec_to_json () =
  let src = {|#lang tesl
module Foo exposing []
codec Task {
  toJson {
    id -> "id" with_codec stringCodec
    title -> "title" with_codec stringCodec
  }
  fromJson_forbidden
}
|} in
  assert_ok src (fun m ->
    match first_decl m with
    | DCodec cf ->
      Alcotest.(check string) "codec name" "Task" cf.name;
      (match cf.to_json with
       | ToJsonFields entries ->
         Alcotest.(check int) "two entries" 2 (List.length entries)
       | _ -> Alcotest.fail "expected ToJsonFields");
      (match cf.from_json with
       | FromJsonForbidden -> ()
       | _ -> Alcotest.fail "expected FromJsonForbidden")
    | _ -> Alcotest.fail "expected DCodec"
  )

let test_codec_from_json () =
  let src = {|#lang tesl
module Foo exposing []
codec NewTask {
  toJson_forbidden
  fromJson [
    {
      title <- "title" with_codec stringCodec
      priority <- "priority" with_codec intCodec
    }
  ]
}
|} in
  assert_ok src (fun m ->
    match first_decl m with
    | DCodec cf ->
      (match cf.to_json with
       | ToJsonForbidden -> ()
       | _ -> Alcotest.fail "expected ToJsonForbidden");
      (match cf.from_json with
       | FromJsonAlts [alt] ->
         Alcotest.(check int) "two decode fields" 2 (List.length alt)
       | _ -> Alcotest.fail "expected FromJsonAlts with one alternative")
    | _ -> Alcotest.fail "expected DCodec"
  )

(* ── API and server tests ────────────────────────────────────────────────── *)

let test_api_declaration () =
  let src = {|#lang tesl
module Foo exposing [TaskServer]
api TaskApi {
  post "/tasks"
    auth user: String::: Authenticated user via cookieAuth
    body body: NewTask
    -> Task
}
|} in
  assert_ok src (fun m ->
    match first_decl m with
    | DApi api ->
      Alcotest.(check string) "api name" "TaskApi" api.name;
      Alcotest.(check int) "one endpoint" 1 (List.length api.endpoints)
    | _ -> Alcotest.fail "expected DApi"
  )

let test_server_declaration () =
  let src = {|#lang tesl
module Foo exposing [TaskServer]
server TaskServer for TaskApi {
  createTask = createTask
  getTask = getTask
}
|} in
  assert_ok src (fun m ->
    match first_decl m with
    | DServer sv ->
      Alcotest.(check string) "server name" "TaskServer" sv.name;
      Alcotest.(check string) "api name" "TaskApi" sv.api_name;
      Alcotest.(check int) "two bindings" 2 (List.length sv.bindings)
    | _ -> Alcotest.fail "expected DServer"
  )

(* ── Test block tests ────────────────────────────────────────────────────── *)

let test_test_block () =
  let src = {|#lang tesl
module Foo exposing []
test "greet" {
  expect greet "World" == "Hello, World!"
  expect greet "Tesl" == "Hello, Tesl!"
}
|} in
  assert_ok src (fun m ->
    match first_decl m with
    | DTest t ->
      Alcotest.(check string) "test description" "greet" t.description;
      Alcotest.(check int) "two expects" 2 (List.length t.stmts)
    | _ -> Alcotest.fail "expected DTest"
  )

let test_test_with_let () =
  let src = {|#lang tesl
module Foo exposing []
test "proofs" {
  let x = isValidPort 80
  expect 1 == 1
}
|} in
  assert_ok src (fun m ->
    match first_decl m with
    | DTest t ->
      Alcotest.(check int) "two stmts" 2 (List.length t.stmts);
      (match List.hd t.stmts with
       | TsLet { name = "x"; _ } -> ()
       | _ -> Alcotest.fail "expected let binding")
    | _ -> Alcotest.fail "expected DTest"
  )

let test_test_with_typed_let () =
  let src = {|#lang tesl
module Foo exposing []
test "proofs" {
  let x: Int ::: ValidPort x = isValidPort 80
  expect 1 == 1
}
|} in
  assert_ok src (fun m ->
    match first_decl m with
    | DTest t ->
      Alcotest.(check int) "two stmts" 2 (List.length t.stmts);
      (match List.hd t.stmts with
       | TsLet {
           name = "x";
           declared_type = Some (TName { name = "Int"; _ });
           declared_proof = Some (PredApp { pred = "ValidPort"; _ });
           _;
         } -> ()
       | _ -> Alcotest.fail "expected typed let binding")
    | _ -> Alcotest.fail "expected DTest"
  )

let test_test_expect_fail () =
  let src = {|#lang tesl
module Foo exposing []
test "invalid ports" {
  expectFail isValidPort 0
  expectFail isValidPort 65536
}
|} in
  assert_ok src (fun m ->
    match first_decl m with
    | DTest t ->
      (match List.hd t.stmts with
       | TsExpectFail _ -> ()
       | _ -> Alcotest.fail "expected TsExpectFail")
    | _ -> Alcotest.fail "expected DTest"
  )

let test_api_test_multiline_request_continuation () =
  let src = {|#lang tesl
module Foo exposing []
api-test "multiline request" for ChatServer {
  let createdRoom = post "/rooms"
                   cookie "chatUserId={userId}"
                   body { "name": "General" }
  expect statusOk createdRoom.status
}
|} in
  let rec flatten_app acc = function
    | EApp { fn; arg; _ } -> flatten_app (arg :: acc) fn
    | fn -> (fn, acc)
  in
  assert_ok src (fun m ->
    match first_decl m with
    | DApiTest t ->
      Alcotest.(check int) "two stmts" 2 (List.length t.stmts);
      (match List.hd t.stmts with
       | TsLet { name = "createdRoom"; value; _ } ->
         let fn, args = flatten_app [] value in
         (match fn with
          | EVar { name = "post"; _ } -> ()
          | _ -> Alcotest.fail "expected post application");
         Alcotest.(check int) "five args" 5 (List.length args);
         (match List.nth args 1 with
          | EVar { name = "cookie"; _ } -> ()
          | _ -> Alcotest.fail "expected cookie continuation arg");
         (match List.nth args 3 with
          | EVar { name = "body"; _ } -> ()
          | _ -> Alcotest.fail "expected body continuation arg")
       | _ -> Alcotest.fail "expected let binding")
    | _ -> Alcotest.fail "expected DApiTest"
  )

let test_property_with_custom_generator () =
  let src = {|#lang tesl
module Foo exposing []
test "custom generator" {
  property "x" (n: Int via genSmallPositive) { n > 0 }
}
|} in
  assert_ok src (fun m ->
    match first_decl m with
    | DTest t ->
      (match List.hd t.stmts with
       | TsProperty { params = [p]; _ } ->
         (match p.generator with
          | Some "genSmallPositive" -> ()
          | Some other -> Alcotest.failf "unexpected generator %s" other
          | None -> Alcotest.fail "expected custom generator")
       | _ -> Alcotest.fail "expected TsProperty")
    | _ -> Alcotest.fail "expected DTest"
  )

(* ── Capture tests ───────────────────────────────────────────────────────── *)

let test_capture () =
  let src = {|#lang tesl
module Foo exposing []
capture taskIdCapture: id: String using stringCodec
|} in
  assert_ok src (fun m ->
    match first_decl m with
    | DCapture c ->
      Alcotest.(check string) "capture name" "taskIdCapture" c.name;
      Alcotest.(check string) "binding name" "id" c.binding.name;
      Alcotest.(check string) "parser" "stringCodec" c.parser
    | _ -> Alcotest.fail "expected DCapture"
  )

(* ── Expression tests ────────────────────────────────────────────────────── *)

let parse_expr_src src =
  let full = Printf.sprintf {|#lang tesl
module Foo exposing [f]
import Tesl.Prelude exposing [Int]
fn f(x: Int) -> Int =
  %s
|} src in
  match parse full with
  | Ok m ->
    (match List.hd m.decls with
     | DFunc fd -> Result.ok fd.body
     | _ -> Result.error "not a function")
  | Err e -> Result.error e.msg

let test_expr_arithmetic () =
  (match parse_expr_src "x + y" with
   | Ok (EBinop { op = BAdd; _ }) -> ()
   | Ok e -> Alcotest.failf "expected BAdd, got %s" (match e with EBinop _ -> "EBinop" | _ -> "other")
   | Error msg -> Alcotest.fail msg);
  (match parse_expr_src "x * y" with
   | Ok (EBinop { op = BMul; _ }) -> ()
   | Ok _ -> Alcotest.fail "expected BMul"
   | Error msg -> Alcotest.fail msg)

let test_expr_comparison () =
  (match parse_expr_src "x == 42" with
   | Ok (EBinop { op = BEq; _ }) -> ()
   | _ -> Alcotest.fail "expected BEq");
  (match parse_expr_src "x != 0" with
   | Ok (EBinop { op = BNeq; _ }) -> ()
   | _ -> Alcotest.fail "expected BNeq");
  (match parse_expr_src "x <= 100" with
   | Ok (EBinop { op = BLe; _ }) -> ()
   | _ -> Alcotest.fail "expected BLe")

let test_expr_application () =
  (match parse_expr_src "greet name" with
   | Ok (EApp _) -> ()
   | _ -> Alcotest.fail "expected EApp");
  (match parse_expr_src "f x y" with
   | Ok (EApp { fn = EApp _; _ }) -> ()
   | _ -> Alcotest.fail "expected nested EApp")

let test_expr_record_literal () =
  (match parse_expr_src "{ id: \"x\", done: false }" with
   | Ok (ERecord { fields; _ }) ->
     Alcotest.(check int) "two fields" 2 (List.length fields)
   | _ -> Alcotest.fail "expected ERecord")

let test_expr_constructor () =
  (match parse_expr_src "Nothing" with
   | Ok (EConstructor { name = "Nothing"; args = []; _ }) -> ()
   | _ -> Alcotest.fail "expected Nothing constructor");
  (match parse_expr_src "Something 42" with
   | Ok (EConstructor { name = "Something"; _ }) -> ()
   | _ -> Alcotest.fail "expected Something constructor")

let test_expr_raw_access () =
  (* The * prefix operator has been removed from the language.
     *port should now be a parse error (STAR in non-multiply position). *)
  (match parse_expr_src "*port" with
   | Error _ -> ()
   | Ok _ -> Alcotest.fail "expected parse error for *port")

(* ── Adversarial parser tests ────────────────────────────────────────────── *)

let test_missing_module_header () =
  (* No #lang or module header *)
  assert_err "fn add(x: Int) -> Int = 42"

let test_empty_module () =
  let src = "#lang tesl\nmodule Empty exposing []\n" in
  assert_ok src (fun m ->
    Alcotest.(check string) "module name" "Empty" m.module_name;
    Alcotest.(check int) "no decls" 0 (decl_count m)
  )

let test_multiple_declarations () =
  let src = {|#lang tesl
module Foo exposing [f, g]
import Tesl.Prelude exposing [Int, String]
fn f(x: Int) -> Int =
  x + 1
fn g(s: String) -> String =
  s
|} in
  assert_ok src (fun m ->
    Alcotest.(check int) "two functions" 2 (decl_count m)
  )

let test_proof_conjunction () =
  let src = {|#lang tesl
module Foo exposing [f]
import Tesl.Prelude exposing [Int]
fn f(x: Int::: Positive x && ValidRange x) -> Int =
  x
|} in
  assert_ok src (fun m ->
    match first_decl m with
    | DFunc fd ->
      let x_param = List.hd fd.params in
      (match x_param.proof_ann with
       | Some (PredAnd _) -> ()
       | _ -> Alcotest.fail "expected conjunctive proof")
    | _ -> Alcotest.fail "expected DFunc"
  )

let test_forall_return () =
  let src = {|#lang tesl
module Foo exposing [filterPositive]
import Tesl.Prelude exposing [Int]
fn filterPositive(xs: List Int) -> List Int ::: ForAll Positive =
  xs
|} in
  assert_ok src (fun m ->
    match first_decl m with
    | DFunc fd ->
      (match fd.return_spec with
       | RetForAll { elem_ty = TName { name = "Int"; _ }; _ } -> ()
       | RetForAll _ -> Alcotest.fail "expected RetForAll with Int element type"
       | _ -> Alcotest.fail "expected RetForAll")
    | _ -> Alcotest.fail "expected DFunc"
  )

let test_named_pack_return () =
  let src = {|#lang tesl
module Foo exposing [getUser]
import Tesl.Prelude exposing [String]
fn getUser(id: String) -> User ? Authenticated =
  fail 404 "not found"
|} in
  assert_ok src (fun m ->
    match first_decl m with
    | DFunc fd ->
      (match fd.return_spec with
       | RetNamedPack _ -> ()
       | _ -> Alcotest.fail "expected RetNamedPack")
    | _ -> Alcotest.fail "expected DFunc"
  )

let test_adt_inline_style () =
  let src = {|#lang tesl
module Foo exposing [Color(..)]
type Color =
  | Red
  | Green
  | Blue
|} in
  assert_ok src (fun m ->
    match first_decl m with
    | DType (TypeAdt { variants; _ }) ->
      Alcotest.(check int) "three variants" 3 (List.length variants)
    | _ -> Alcotest.fail "expected TypeAdt"
  )

let test_parameterized_adt () =
  let src = {|#lang tesl
module Foo exposing [Either(..)]
type Either a b =
  | Left value:a
  | Right value:b
|} in
  assert_ok src (fun m ->
    match first_decl m with
    | DType (TypeAdt { name = "Either"; params; variants; _ }) ->
      Alcotest.(check int) "two params" 2 (List.length params);
      Alcotest.(check string) "first param" "a" (List.hd params);
      Alcotest.(check string) "second param" "b" (List.nth params 1);
      Alcotest.(check int) "two variants" 2 (List.length variants);
      Alcotest.(check string) "Left ctor" "Left" (List.hd variants).ctor;
      Alcotest.(check string) "Right ctor" "Right" (List.nth variants 1).ctor
    | _ -> Alcotest.fail "expected TypeAdt Either"
  )

let test_single_param_adt () =
  let src = {|#lang tesl
module Foo exposing [Box(..)]
type Box a = Box value:a
|} in
  assert_ok src (fun m ->
    match first_decl m with
    | DType (TypeAdt { name = "Box"; params; variants; _ }) ->
      Alcotest.(check int) "one param" 1 (List.length params);
      Alcotest.(check string) "param a" "a" (List.hd params);
      Alcotest.(check int) "one variant" 1 (List.length variants)
    | _ -> Alcotest.fail "expected TypeAdt Box"
  )

let test_non_parameterized_adt_no_params () =
  let src = {|#lang tesl
module Foo exposing [Status(..)]
type Status =
  | Active
  | Inactive
|} in
  assert_ok src (fun m ->
    match first_decl m with
    | DType (TypeAdt { name = "Status"; params; _ }) ->
      Alcotest.(check int) "no params" 0 (List.length params)
    | _ -> Alcotest.fail "expected TypeAdt Status"
  )

let test_adt_parameterized () =
  let src = {|#lang tesl
module Foo exposing [Either(..)]
type Either a b =
  | Left { value: a }
  | Right { value: b }
|} in
  assert_ok src (fun m ->
    match first_decl m with
    | DType (TypeAdt { name = "Either"; params; variants; _ }) ->
      Alcotest.(check int) "two params" 2 (List.length params);
      Alcotest.(check string) "first param" "a" (List.nth params 0);
      Alcotest.(check string) "second param" "b" (List.nth params 1);
      Alcotest.(check int) "two variants" 2 (List.length variants);
      let left = List.hd variants in
      Alcotest.(check string) "Left ctor" "Left" left.ctor;
      Alcotest.(check int) "Left has 1 field" 1 (List.length left.fields);
      Alcotest.(check string) "Left field name" "value" (List.hd left.fields).name
    | _ -> Alcotest.fail "expected parameterized TypeAdt Either"
  )

let test_brace_pattern_match () =
  (* Test brace-syntax pattern matching: Constructor { field = var } *)
  let src = {|#lang tesl
module Foo exposing [getLeft]
import Tesl.Prelude exposing [String, Int]
type Either a b =
  | Left { value: a }
  | Right { value: b }
fn getLeft(e: Either String Int) -> String =
  case e of
    Left { value = v } -> v
    Right _ -> "not a left"
|} in
  assert_ok src (fun m ->
    (* Find the function declaration (second decl after the type) *)
    let fn_decl = List.find_opt (function DFunc _ -> true | _ -> false) m.decls in
    match fn_decl with
    | Some (DFunc fd) ->
      (match fd.body with
       | ECase { arms; _ } ->
         Alcotest.(check int) "two arms" 2 (List.length arms);
         (match (List.hd arms).pattern with
          | PCon { ctor = "Left"; fields; _ } ->
            Alcotest.(check int) "one field" 1 (List.length fields);
            let (fname, vname_pat) = List.hd fields in
            Alcotest.(check string) "field name" "value" fname;
            (match vname_pat with
             | PVar vname -> Alcotest.(check string) "binding name" "v" vname
             | _ -> Alcotest.fail "field binding should be PVar")
          | _ -> Alcotest.fail "first arm should be Left { value = v }")
       | _ -> Alcotest.fail "expected case expression")
    | _ -> Alcotest.fail "expected DFunc getLeft"
  )

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Parser" [
    "module", [
      Alcotest.test_case "header" `Quick test_module_header;
      Alcotest.test_case "ADT exports" `Quick test_module_adt_exports;
      Alcotest.test_case "qualified import" `Quick test_module_import_qualified;
      Alcotest.test_case "empty module" `Quick test_empty_module;
    ];
    "functions", [
      Alcotest.test_case "simple fn" `Quick test_fn_simple;
      Alcotest.test_case "string interpolation" `Quick test_fn_string_interpolation;
      Alcotest.test_case "case expression" `Quick test_fn_case_expression;
      Alcotest.test_case "brace pattern match" `Quick test_brace_pattern_match;
      Alcotest.test_case "if-else" `Quick test_fn_if_else;
      Alcotest.test_case "let bindings" `Quick test_fn_let_bindings;
      Alcotest.test_case "typed let bindings" `Quick test_fn_typed_let_binding;
    ];
    "check-auth", [
      Alcotest.test_case "check function" `Quick test_check_function;
      Alcotest.test_case "auth function" `Quick test_auth_function;
      Alcotest.test_case "handler with capabilities" `Quick test_handler_with_capabilities;
    ];
    "types", [
      Alcotest.test_case "newtype" `Quick test_newtype;
      Alcotest.test_case "ADT nullary" `Quick test_adt_nullary;
      Alcotest.test_case "ADT with fields" `Quick test_adt_with_fields;
      Alcotest.test_case "ADT inline" `Quick test_adt_inline_style;
      Alcotest.test_case "parameterized ADT" `Quick test_parameterized_adt;
      Alcotest.test_case "single param ADT" `Quick test_single_param_adt;
      Alcotest.test_case "non-parameterized ADT has no params" `Quick test_non_parameterized_adt_no_params;
      Alcotest.test_case "ADT parameterized" `Quick test_adt_parameterized;
    ];
    "records", [
      Alcotest.test_case "simple record" `Quick test_record_simple;
      Alcotest.test_case "record with proof fields" `Quick test_record_with_proof_fields;
    ];
    "entities", [
      Alcotest.test_case "entity" `Quick test_entity;
    ];
    "capabilities", [
      Alcotest.test_case "capability with implies" `Quick test_capability;
      Alcotest.test_case "capability no implies" `Quick test_capability_no_implies;
    ];
    "facts", [
      Alcotest.test_case "fact with params" `Quick test_fact_with_params;
      Alcotest.test_case "fact no params" `Quick test_fact_no_params;
    ];
    "codecs", [
      Alcotest.test_case "toJson codec" `Quick test_codec_to_json;
      Alcotest.test_case "fromJson codec" `Quick test_codec_from_json;
    ];
    "api-server", [
      Alcotest.test_case "api declaration" `Quick test_api_declaration;
      Alcotest.test_case "server declaration" `Quick test_server_declaration;
    ];
    "tests", [
      Alcotest.test_case "test block" `Quick test_test_block;
      Alcotest.test_case "test with let" `Quick test_test_with_let;
      Alcotest.test_case "test with typed let" `Quick test_test_with_typed_let;
      Alcotest.test_case "expectFail" `Quick test_test_expect_fail;
      Alcotest.test_case "api-test multiline request continuation" `Quick test_api_test_multiline_request_continuation;
      Alcotest.test_case "property with via generator" `Quick test_property_with_custom_generator;
    ];
    "capture", [
      Alcotest.test_case "capture declaration" `Quick test_capture;
    ];
    "expressions", [
      Alcotest.test_case "arithmetic" `Quick test_expr_arithmetic;
      Alcotest.test_case "comparison" `Quick test_expr_comparison;
      Alcotest.test_case "application" `Quick test_expr_application;
      Alcotest.test_case "record literal" `Quick test_expr_record_literal;
      Alcotest.test_case "constructors" `Quick test_expr_constructor;
      Alcotest.test_case "raw access" `Quick test_expr_raw_access;
    ];
    "advanced", [
      Alcotest.test_case "multiple declarations" `Quick test_multiple_declarations;
      Alcotest.test_case "proof conjunction" `Quick test_proof_conjunction;
      Alcotest.test_case "ForAll return" `Quick test_forall_return;
      Alcotest.test_case "named-pack return" `Quick test_named_pack_return;
    ];
    "adversarial", [
      Alcotest.test_case "missing module header" `Quick test_missing_module_header;
    ];
  ]
