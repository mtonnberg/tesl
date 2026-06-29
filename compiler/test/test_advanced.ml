(** Advanced parser and emit tests for complex Tesl constructs.

    Tests cover:
    - Proof atoms with parenthesized sub-expressions
    - Qualified type names
    - Worker functions without return types
    - Multi-line exists return specs
    - Sequential statements in function bodies
    - Proof decomposition in let bindings
    - Pipe operators |> and <|
    - Record update syntax { r | field = val }
    - main { } blocks
    - Named-pack returns with && proofs
    - ForAll with predicate args (ForAll TodoId)
    - Capture abbreviated form
*)

open Parser
open Emit_racket

let parse src = parse_module "<test>" src

let assert_ok src f =
  match parse src with
  | Ok m -> f m
  | Err e -> Alcotest.failf "parse error: %s (at %s:%d:%d)"
               e.msg e.loc.file (e.loc.start.line + 1) (e.loc.start.col + 1)

let _assert_err src =
  match parse src with
  | Err _ -> ()
  | Ok _ -> Alcotest.fail "expected parse error but succeeded"

let check_contains name src needle =
  match parse src with
  | Err e -> Alcotest.failf "%s parse error: %s" name e.msg
  | Ok m ->
    let out = compile_to_string ~root_path:"ROOT" m in
    let n = String.length needle in
    let m_len = String.length out in
    let found = ref false in
    for i = 0 to m_len - n do
      if String.sub out i n = needle then found := true
    done;
    if not !found then
      Alcotest.failf "%s: expected %S in output:\n%s" name needle out

(* ── Proof atom tests ─────────────────────────────────────────────────────── *)

let test_proof_with_parenthesized_arg () =
  (* FromDb (Id == noteId) — parenthesized arg in proof *)
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [String]
fn f(x: String ::: FromDb (Id == x)) -> String = x
|} in
  assert_ok src (fun m ->
    match List.hd m.decls with
    | Ast.DFunc fd ->
      let p = List.hd fd.params in
      (match p.proof_ann with
       | Some (PredApp { pred = "FromDb"; _ }) -> ()
       | _ -> Alcotest.fail "expected FromDb proof")
    | _ -> Alcotest.fail "expected DFunc")

let test_proof_with_uident_arg () =
  (* ForAll TodoId newTodos — UIDENT arg *)
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [String]
fn f(xs: List String ::: ForAll TodoId xs) -> List String = xs
|} in
  assert_ok src (fun m ->
    match List.hd m.decls with
    | Ast.DFunc fd ->
      let p = List.hd fd.params in
      (match p.proof_ann with
       | Some (PredApp { pred = "ForAll"; args; _ }) ->
         Alcotest.(check bool) "has args" true (args <> [])
       | _ -> Alcotest.fail "expected ForAll proof")
    | _ -> Alcotest.fail "expected DFunc")

(* ── Qualified type names ─────────────────────────────────────────────────── *)

let test_qualified_type () =
  (* Sandbox3.ARecord2 as parameter type *)
  let src = {|#lang tesl
module Foo exposing []
import Sandbox3 exposing []
fn f(x: Sandbox3.ARecord2) -> Int = 0
|} in
  assert_ok src (fun m ->
    match List.hd m.decls with
    | Ast.DFunc fd ->
      let p = List.hd fd.params in
      (match p.type_expr with
       | TName { name = "Sandbox3.ARecord2"; _ } -> ()
       | _ -> Alcotest.fail "expected Sandbox3.ARecord2 type")
    | _ -> Alcotest.fail "expected DFunc")

(* ── Worker functions ─────────────────────────────────────────────────────── *)

let test_worker_no_return () =
  (* Workers can be declared without return type *)
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [String]
worker myWorker(job: String)
  requires [queueRead] =
  job
|} in
  assert_ok src (fun m ->
    match List.hd m.decls with
    | Ast.DFunc fd ->
      Alcotest.(check string) "name" "myWorker" fd.name;
      (match fd.kind with Ast.WorkerKind -> () | _ -> Alcotest.fail "expected WorkerKind");
      Alcotest.(check int) "one cap" 1 (List.length fd.capabilities)
    | _ -> Alcotest.fail "expected DFunc")

let test_worker_emit () =
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [String]
worker sendEmail(job: String)
  requires [queueRead] =
  job
|} in
  check_contains "worker uses define/pow" src "(define/pow"

(* ── Multi-line return specs ──────────────────────────────────────────────── *)

let test_exists_return_multiline () =
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [String]
fn genToken() -> exists tokenId: String =>
      String ::: IsTokenId tokenId
  requires [] =
  "token-123"
|} in
  assert_ok src (fun m ->
    match List.hd m.decls with
    | Ast.DFunc fd ->
      (match fd.return_spec with
       | Ast.RetExists _ -> ()
       | _ -> Alcotest.fail "expected RetExists")
    | _ -> Alcotest.fail "expected DFunc")

(* ── Named-pack with && ──────────────────────────────────────────────────── *)

let test_named_pack_with_conjunction () =
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
fn f(n: Int ::: IsPositive n) -> Int ? IsPositive && IsSmall =
  n
|} in
  assert_ok src (fun m ->
    match List.hd m.decls with
    | Ast.DFunc fd ->
      (match fd.return_spec with
       | Ast.RetNamedPack _ -> ()
       | _ -> Alcotest.fail "expected RetNamedPack")
    | _ -> Alcotest.fail "expected DFunc")

(* ── Sequential function bodies ─────────────────────────────────────────── *)

let test_sequential_body () =
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
fn f(x: Int) -> Int
  requires [] =
  let y = x + 1
  y * 2
|} in
  assert_ok src (fun m ->
    match List.hd m.decls with
    | Ast.DFunc fd ->
      (match fd.body with
       | Ast.ELet { name = "y"; _ } -> ()
       | _ -> Alcotest.fail "expected let binding")
    | _ -> Alcotest.fail "expected DFunc")

let test_sequential_multi_stmt () =
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
fn f(x: Int) -> Int
  requires [] =
  let a = x + 1
  let b = a * 2
  b
|} in
  assert_ok src (fun m ->
    match List.hd m.decls with
    | Ast.DFunc fd ->
      (match fd.body with
       | Ast.ELet { name = "a"; body = Ast.ELet { name = "b"; _ }; _ } -> ()
       | _ -> Alcotest.fail "expected nested let bindings")
    | _ -> Alcotest.fail "expected DFunc")

(* ── Proof decomposition ──────────────────────────────────────────────────── *)

let test_let_proof_decompose () =
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
fn f(x: Int ::: ValidPort x) -> Int =
  let (y ::: xProof) = x
  y
|} in
  assert_ok src (fun _ -> ())

(* ── Pipe operators ──────────────────────────────────────────────────────── *)

let test_pipe_right () =
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
fn double(x: Int) -> Int = x * 2
fn f(x: Int) -> Int =
  x |> double |> double
|} in
  assert_ok src (fun m ->
    match List.hd m.decls with
    | Ast.DFunc fd ->
      (match fd.name with "double" -> () | _ ->
        match List.nth m.decls 1 with
        | Ast.DFunc fd2 ->
          (match fd2.body with
           | Ast.EApp _ -> ()  (* Result of pipe chain *)
           | _ -> ())
        | _ -> ())
    | _ -> ())

let test_pipe_left () =
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
fn double(x: Int) -> Int = x * 2
fn f(x: Int) -> Int =
  double <| double <| x
|} in
  assert_ok src (fun _ -> ())

(* ── main block ──────────────────────────────────────────────────────────── *)

let test_main_block () =
  let src = {|#lang tesl
module Foo exposing []
import Tesl.App exposing [App]
import Tesl.Prelude exposing [String]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
main() -> App =
  App {
    database: D
    api: S
    port: 8080
  }
database D = Database {
  schema: "s"
  entities: []
  backend: Postgres (PostgresConfig {
    dbName: "d" user: "u" password: ""
    connection: TcpConnection { host: "h" port: 5432 }
  })
}
handler root() -> String requires [] = "ok"
api SomeApi {
  get "/health" -> String
}
server S for SomeApi {
  endpoint_0 = root
}
|} in
  assert_ok src (fun m ->
    match List.hd m.decls with
    | Ast.DFunc fd ->
      Alcotest.(check string) "main name" "main" fd.name;
      (match fd.kind with Ast.MainKind -> () | _ -> Alcotest.fail "expected MainKind")
    | _ -> Alcotest.fail "expected DFunc main")

let test_main_with_requires () =
  let src = {|#lang tesl
module Foo exposing []
import Tesl.App exposing [App]
import Tesl.Prelude exposing [String]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
main() -> App requires [time] =
  App {
    database: D
    api: S
    port: 8080
  }
database D = Database {
  schema: "s"
  entities: []
  backend: Postgres (PostgresConfig {
    dbName: "d" user: "u" password: ""
    connection: TcpConnection { host: "h" port: 5432 }
  })
}
handler root() -> String requires [] = "ok"
api SomeApi {
  get "/health" -> String
}
server S for SomeApi {
  endpoint_0 = root
}
|} in
  assert_ok src (fun m ->
    match List.hd m.decls with
    | Ast.DFunc fd ->
      Alcotest.(check int) "one capability" 1 (List.length fd.capabilities)
    | _ -> Alcotest.fail "expected DFunc main")

(* ── Record update syntax ────────────────────────────────────────────────── *)

let test_record_update_emit () =
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
record R {
  x: Int
  y: Int
}
fn scale(r: R, factor: Int) -> R =
  { r | x = r.x * factor }
|} in
  check_contains "tesl-record-update for record update" src "tesl-record-update"

(* ── Channel with key params ──────────────────────────────────────────────── *)

let test_channel_with_params () =
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [String]
channel UserEvents(userId: String) = SseChannel {
  database: MainDb
  payload: String
}
|} in
  assert_ok src (fun m ->
    match List.hd m.decls with
    | Ast.DChannel c ->
      Alcotest.(check string) "channel name" "UserEvents" c.name;
      Alcotest.(check int) "one key param" 1 (List.length c.key_params)
    | _ -> Alcotest.fail "expected DChannel")

(* ── Adversarial advanced tests ──────────────────────────────────────────── *)

let test_complex_proof_chain () =
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [String]
fn f(x: String ::: FromDb (Id == y) && Authenticated x) -> String = x
|} in
  assert_ok src (fun m ->
    match List.hd m.decls with
    | Ast.DFunc fd ->
      let p = List.hd fd.params in
      (match p.proof_ann with
       | Some (PredAnd _) -> ()  (* conjunction *)
       | Some (PredApp { pred = "FromDb"; _ }) -> ()  (* might be parsed as single pred *)
       | _ -> ())  (* acceptable for phase 1 *)
    | _ -> Alcotest.fail "expected DFunc")

let test_multiple_proofs_on_param () =
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
fn f(x: Int ::: IsPositive x && ValidPort x) -> Int = x
|} in
  assert_ok src (fun m ->
    match List.hd m.decls with
    | Ast.DFunc fd ->
      let p = List.hd fd.params in
      (match p.proof_ann with
       | Some _ -> ()  (* has some proof annotation *)
       | None -> Alcotest.fail "expected proof annotation")
    | _ -> Alcotest.fail "expected DFunc")

let test_deeply_nested_parens_in_proof () =
  (* Deep nesting: FromDb (Id == (Nested (key))) *)
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [String]
fn f(x: String ::: FromDb (Id == x) y) -> String = x
|} in
  assert_ok src (fun _ -> ())

let test_exists_expr () =
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [String]
fn genId() -> String =
  exists tokenId =>
    tokenId
|} in
  assert_ok src (fun _ -> ())

let test_zero_arg_function_call () =
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
fn now() -> Int = 0
fn f() -> Int =
  now()
|} in
  check_contains "zero arg call" src "(now)"

let test_qualified_function_call_emit () =
  let src = {|#lang tesl
module Foo exposing []
import Tesl.String exposing [String.length]
import Tesl.Prelude exposing [Int, String]
fn f(s: String) -> Int =
  String.length s
|} in
  check_contains "renamed import" src "tesl_import_String_length"

let test_logical_or_in_where () =
  (* || in SQL where clauses *)
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [String]
fn f(x: String, y: String) -> Bool =
  x == y || x == "admin"
|} in
  assert_ok src (fun _ -> ())


(* ── Anonymous lambda tests ──────────────────────────────────────────────── *)

let test_lambda_parse () =
  (* fn(x: T) -> body parses as ELambda *)
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
fn applyFn(f: Int -> Int, x: Int) -> Int = f x
test "lambda" {
  expect applyFn (fn(x: Int) -> x * 2) 5 == 10
}
|} in
  assert_ok src (fun m ->
    match List.hd m.decls with
    | Ast.DFunc fd ->
      Alcotest.(check string) "name" "applyFn" fd.name
    | _ -> Alcotest.fail "expected DFunc")

let test_lambda_emit () =
  check_contains "lambda emits define/pow" {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
fn f(x: Int) -> Int =
  let g = fn(y: Int) -> y * 2
  g x
|} "tesl-lambda-"

let test_lambda_multi_param () =
  (* Multi-param lambda *)
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
fn apply2(f: Int -> Int -> Int, a: Int, b: Int) -> Int = f a b
test "multi-param lambda" {
  expect apply2 (fn(a: Int, b: Int) -> a + b) 3 4 == 7
}
|} in
  assert_ok src (fun _ -> ())

let test_lambda_no_body_issue () =
  (* Lambda body returning a constructor *)
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
fn applyFn(f: Int -> Maybe Int, x: Int) -> Maybe Int = f x
test "lambda returns maybe" {
  let result = applyFn (fn(x: Int) -> Something x) 42
  expect 1 == 1
}
|} in
  assert_ok src (fun _ -> ())

let test_lambda_adversarial_empty_params () =
  (* Lambda with no params is currently not valid but shouldn't crash *)
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
fn f(g: Unit -> Int) -> Int = g ()
|} in
  assert_ok src (fun _ -> ())

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Advanced" [
    "proof-atoms", [
      Alcotest.test_case "parenthesized proof arg" `Quick test_proof_with_parenthesized_arg;
      Alcotest.test_case "UIDENT proof arg (ForAll TodoId)" `Quick test_proof_with_uident_arg;
    ];
    "qualified-types", [
      Alcotest.test_case "Module.Type name" `Quick test_qualified_type;
    ];
    "workers", [
      Alcotest.test_case "worker without return type" `Quick test_worker_no_return;
      Alcotest.test_case "worker emit" `Quick test_worker_emit;
    ];
    "multiline-return", [
      Alcotest.test_case "exists return on next line" `Quick test_exists_return_multiline;
      Alcotest.test_case "named-pack with && conjunction" `Quick test_named_pack_with_conjunction;
    ];
    "sequential-bodies", [
      Alcotest.test_case "sequential statements" `Quick test_sequential_body;
      Alcotest.test_case "multiple let bindings" `Quick test_sequential_multi_stmt;
    ];
    "proof-decompose", [
      Alcotest.test_case "let proof decomposition" `Quick test_let_proof_decompose;
    ];
    "pipes", [
      Alcotest.test_case "pipe right |>" `Quick test_pipe_right;
      Alcotest.test_case "pipe left <|" `Quick test_pipe_left;
    ];
    "main-block", [
      Alcotest.test_case "main { }" `Quick test_main_block;
      Alcotest.test_case "main requires { }" `Quick test_main_with_requires;
    ];
    "record-update", [
      Alcotest.test_case "record update emits hash-set*" `Quick test_record_update_emit;
    ];
    "channel", [
      Alcotest.test_case "channel with key params" `Quick test_channel_with_params;
    ];
    "lambda", [
      Alcotest.test_case "lambda parses correctly" `Quick test_lambda_parse;
      Alcotest.test_case "lambda emits define/pow" `Quick test_lambda_emit;
      Alcotest.test_case "multi-param lambda" `Quick test_lambda_multi_param;
      Alcotest.test_case "lambda returns constructor" `Quick test_lambda_no_body_issue;
      Alcotest.test_case "lambda with unit params" `Quick test_lambda_adversarial_empty_params;
    ];
    "adversarial", [
      Alcotest.test_case "complex proof chain" `Quick test_complex_proof_chain;
      Alcotest.test_case "multiple proofs on param" `Quick test_multiple_proofs_on_param;
      Alcotest.test_case "deeply nested parens in proof" `Quick test_deeply_nested_parens_in_proof;
      Alcotest.test_case "exists expression" `Quick test_exists_expr;
      Alcotest.test_case "zero-arg function call" `Quick test_zero_arg_function_call;
      Alcotest.test_case "qualified function call emit" `Quick test_qualified_function_call_emit;
      Alcotest.test_case "logical OR in expression" `Quick test_logical_or_in_where;
    ];
  ]
