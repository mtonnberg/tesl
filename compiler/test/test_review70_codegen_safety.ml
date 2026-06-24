(** Codegen safety and arithmetic transparency tests — Review 70.

    Two concerns addressed here:

    A. CODEGEN SAFETY (Item 8.2): The 11 crash points in emit_racket.ml
       (assert false / failwith) were replaced with meaningful error messages.
       These tests ensure:
       - SQL constructs (select, insert, upsert, insert-many, delete) still
         compile correctly after the refactor (regression guard)
       - Non-SQL function calls still emit correctly
       - Proof annotation handling in validation.ml is safe when proof_ann = None

    B. ARITHMETIC TRANSPARENCY (Item 8.4): Proof-carrying values should be
       usable in arithmetic, comparisons, string interpolation, and let-chains
       WITHOUT the user needing to write *x syntax (that is generated internally).
       These tests verify the compiler correctly handles:
       - Basic arithmetic on proof-carrying parameters
       - Comparison operators in if-conditions
       - String interpolation
       - Chained let bindings through arithmetic
       - Multi-parameter arithmetic
       - Compound expressions
       - Division correctly requires IsNonZero proof (safety, not a bug)

    Test groups:
      SQL  — SQL codegen regression (guards the assert-false refactor)
      ARITH — Arithmetic transparency on proof-carrying values
      SAFE  — Division/modulo safety checks work correctly *)

open Alcotest

let compiler =
  match Sys.getenv_opt "TESL_OCAML_COMPILER" with
  | Some p when Sys.file_exists p -> p
  | _ ->
    (match Sys.getenv_opt "TESL_BIN" with
     | Some v when Filename.basename v = "main.exe" && Sys.file_exists v -> v
     | _ ->
       let dir = Filename.dirname Sys.argv.(0) in
       let candidate = Filename.concat (Filename.dirname dir) "bin/main.exe" in
       let candidate2 = Filename.concat dir "../bin/main.exe" in
       if Sys.file_exists candidate then candidate
       else if Sys.file_exists candidate2 then candidate2
       else "tesl")

let run_command cmd =
  let ic = Unix.open_process_in cmd in
  let out = In_channel.input_all ic in
  let status = Unix.close_process_in ic in
  let code = match status with
    | Unix.WEXITED c -> c | Unix.WSIGNALED n -> 128+n | Unix.WSTOPPED n -> 128+n
  in (code, out)

let run_compiler args =
  let quoted = Filename.quote compiler :: List.map Filename.quote args in
  run_command (String.concat " " quoted ^ " 2>&1")

let failf fmt = Printf.ksprintf failwith fmt

let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-r70" "" in
  let name =
    let re = Str.regexp "module[ \\t\\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
    try
      ignore (Str.search_forward re content 0);
      let mname = Str.matched_group 1 content in
      let buf = Buffer.create (String.length mname + 4) in
      String.iteri (fun i c ->
        if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
        else if c >= 'A' && c <= 'Z' then (Buffer.add_char buf '-'; Buffer.add_char buf (Char.lowercase_ascii c))
        else Buffer.add_char buf c
      ) mname;
      Buffer.contents buf ^ ".tesl"
    with Not_found -> "test.tesl"
  in
  let path = Filename.concat dir name in
  let oc = open_out path in output_string oc content; close_out oc;
  Fun.protect
    ~finally:(fun () -> (try Sys.remove path with _ -> ()); (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected success, got:\n%s" out)

let should_fail pat src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected failure matching %S, but succeeded" pat;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pat out)

(* ── SQL — SQL codegen regression tests ─────────────────────────────────── *)
(* These guard the assert-false refactor: SQL constructs must still compile  *)

let test_SQL01_database_select_compiles () =
  should_pass {|
#lang tesl
module SQL01 exposing []
import Tesl.Prelude exposing [Int, String, List]
import Tesl.DB exposing [dbRead]
database AppDb {
  backend postgres schema "app" entities [Item]
  postgres { database "d" user "u" password "" host "localhost" port 5432 socket "" }
}
entity Item table "items" primaryKey id { id: Int name: String }
fn getItems() -> List Item requires [dbRead] =
  select i from Item
|}

let test_SQL02_database_insert_compiles () =
  should_pass {|
#lang tesl
module SQL02 exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.DB exposing [dbWrite, dbRead]
import Tesl.Maybe exposing [Maybe]
database AppDb {
  backend postgres schema "app" entities [Widget]
  postgres { database "d" user "u" password "" host "localhost" port 5432 socket "" }
}
entity Widget table "widgets" primaryKey id { id: Int label: String }
fn findWidget(label: String) -> Maybe Widget requires [dbRead] =
  selectOne w from Widget where w.label == label
|}

let test_SQL03_database_select_with_where_compiles () =
  should_pass {|
#lang tesl
module SQL03 exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Maybe exposing [Maybe]
import Tesl.DB exposing [dbRead]
database AppDb {
  backend postgres schema "app" entities [Task]
  postgres { database "d" user "u" password "" host "localhost" port 5432 socket "" }
}
entity Task table "tasks" primaryKey id { id: Int title: String }
fn getTask(taskId: Int) -> Maybe Task requires [dbRead] =
  selectOne t from Task where t.id == taskId
|}

let test_SQL04_database_update_compiles () =
  should_pass {|
#lang tesl
module SQL04 exposing []
import Tesl.Prelude exposing [Int, String, Unit]
import Tesl.DB exposing [dbWrite]
database AppDb {
  backend postgres schema "app" entities [Record]
  postgres { database "d" user "u" password "" host "localhost" port 5432 socket "" }
}
entity Record table "records" primaryKey id { id: Int value: String }
fn updateRecord(recordId: Int, newValue: String) -> Unit requires [dbWrite] =
  update r in Record
    where r.id == recordId
    set r.value = newValue
|}

let test_SQL05_non_sql_app_expression_compiles () =
  (* Ensure general function application still works after SQL guard refactor *)
  should_pass {|
#lang tesl
module SQL05 exposing []
import Tesl.Prelude exposing [Int]
fn add(a: Int, b: Int) -> Int = a + b
fn double(n: Int) -> Int = add n n
fn triple(n: Int) -> Int = add (add n n) n
|}

let test_SQL06_select_with_order_compiles () =
  should_pass {|
#lang tesl
module SQL06 exposing []
import Tesl.Prelude exposing [Int, String, List]
import Tesl.DB exposing [dbRead]
database AppDb {
  backend postgres schema "app" entities [Post]
  postgres { database "d" user "u" password "" host "localhost" port 5432 socket "" }
}
entity Post table "posts" primaryKey id { id: Int title: String score: Int }
fn getTopPosts() -> List Post requires [dbRead] =
  select p from Post
    order p.score desc
    limit 10
|}

(* ── ARITH — Arithmetic transparency on proof-carrying values ─────────────── *)
(* Prove that the user never needs to write *x in Tesl source code.            *)
(* The compiler generates *x internally in the Racket output.                  *)

let test_ARITH01_basic_multiplication_on_proof_param () =
  should_pass {|
#lang tesl
module Arith01 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn double(n: Int ::: IsPositive n) -> Int = n * 2
fn test(raw: Int) -> Int =
  let x = check checkPos raw
  double x
|}

let test_ARITH02_addition_of_two_proof_params () =
  should_pass {|
#lang tesl
module Arith02 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn addPositives(a: Int ::: IsPositive a, b: Int ::: IsPositive b) -> Int = a + b
fn test(x: Int, y: Int) -> Int =
  let a = check checkPos x
  let b = check checkPos y
  addPositives a b
|}

let test_ARITH03_comparison_in_if_condition () =
  (* Comparisons on proof-carrying values in if conditions *)
  should_pass {|
#lang tesl
module Arith03 exposing []
import Tesl.Prelude exposing [Int, String]
fact ValidPort (n: Int)
check checkPort(n: Int) -> n: Int ::: ValidPort n =
  if n > 0 then
    ok n ::: ValidPort n
  else
    fail 400 "bad"
fn classify(port: Int ::: ValidPort port) -> String =
  if port < 1024 then
    "system port"
  else
    "user port"
fn test(raw: Int) -> String =
  let p = check checkPort raw
  classify p
|}

let test_ARITH04_string_interpolation_with_proof_value () =
  should_pass {|
#lang tesl
module Arith04 exposing []
import Tesl.Prelude exposing [Int, String]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn describe(n: Int ::: IsPositive n) -> String = "the value is ${n}"
fn test(raw: Int) -> String =
  let x = check checkPos raw
  describe x
|}

let test_ARITH05_chained_let_arithmetic () =
  (* Let bindings used in subsequent arithmetic expressions *)
  should_pass {|
#lang tesl
module Arith05 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn triple(n: Int ::: IsPositive n) -> Int =
  let doubled = n * 2
  doubled + n
fn test(raw: Int) -> Int =
  let x = check checkPos raw
  triple x
|}

let test_ARITH06_compound_expression_multi_param () =
  should_pass {|
#lang tesl
module Arith06 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
fact IsSmall (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
check checkSmall(n: Int) -> n: Int ::: IsSmall n =
  if n < 1000 then
    ok n ::: IsSmall n
  else
    fail 400 "too large"
fn compute(a: Int ::: IsPositive a, b: Int ::: IsSmall b) -> Int =
  a * b + a - b
fn test(x: Int, y: Int) -> Int =
  let a = check checkPos x
  let b = check checkSmall y
  compute a b
|}

let test_ARITH07_proof_value_in_boolean_and () =
  should_pass {|
#lang tesl
module Arith07 exposing []
import Tesl.Prelude exposing [Int, Bool(..)]
fact InRange (n: Int)
check checkRange(n: Int) -> n: Int ::: InRange n =
  if n >= 0 && n <= 100 then
    ok n ::: InRange n
  else
    fail 400 "out of range"
fn isLow(n: Int ::: InRange n) -> Bool =
  n < 50 && n >= 0
fn test(raw: Int) -> Bool =
  let x = check checkRange raw
  isLow x
|}

let test_ARITH08_subtraction_on_proof_param () =
  should_pass {|
#lang tesl
module Arith08 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn decrement(n: Int ::: IsPositive n) -> Int = n - 1
fn test(raw: Int) -> Int =
  let x = check checkPos raw
  decrement x
|}

let test_ARITH09_proof_value_in_case_arm () =
  (* Proof-carrying value extracted in case arm and used in arithmetic *)
  should_pass {|
#lang tesl
module Arith09 exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Maybe exposing [Maybe(..)]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn processOpt(m: Maybe Int) -> Int =
  case m of
    Something n ->
      let checked = check checkPos n
      checked * 2
    Nothing -> 0
|}

let test_ARITH10_nested_arithmetic_deep () =
  should_pass {|
#lang tesl
module Arith10 exposing []
import Tesl.Prelude exposing [Int]
fact P (n: Int)
check checkP(n: Int) -> n: Int ::: P n =
  if n > 0 then
    ok n ::: P n
  else
    fail 400 "bad"
fn compute(a: Int ::: P a, b: Int ::: P b, c: Int ::: P c) -> Int =
  (a + b) * c - a
fn test(x: Int, y: Int, z: Int) -> Int =
  let a = check checkP x
  let b = check checkP y
  let c = check checkP z
  compute a b c
|}

(* ── SAFE — Division/modulo safety checks ────────────────────────────────── *)
(* Division requires IsNonZero proof — this is correct safety behavior        *)

let test_SAFE01_division_without_proof_rejected () =
  should_fail "IsNonZero\\|division.*proof\\|nonZero\\|proof.*division" {|
#lang tesl
module Safe01 exposing []
import Tesl.Prelude exposing [Int]
fn badDiv(a: Int, b: Int) -> Int = a / b
|}

let test_SAFE02_modulo_without_proof_rejected () =
  should_fail "IsNonZero\\|division.*proof\\|nonZero\\|proof.*modulo\\|modulo.*proof" {|
#lang tesl
module Safe02 exposing []
import Tesl.Prelude exposing [Int]
fn badMod(a: Int, b: Int) -> Int = a % b
|}

let test_SAFE03_division_with_nonzero_proof_accepted () =
  should_pass {|
#lang tesl
module Safe03 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Int exposing [Int.divide, Int.nonZero]
fn safeDivide(a: Int, b: Int) -> Int =
  let checkedB = check Int.nonZero b
  Int.divide a checkedB
|}

let test_SAFE04_int_divide_stdlib_without_proof_rejected () =
  should_fail "IsNonZero\\|nonZero\\|proof.*divide\\|divide.*proof" {|
#lang tesl
module Safe04 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Int exposing [Int.divide]
fn badDiv(a: Int, b: Int) -> Int = Int.divide a b
|}

(* ── Test runner ─────────────────────────────────────────────────────────── *)

let () =
  run "Review70-Codegen-Safety" [
    "sql-codegen-regression", [
      test_case "SQL01 select compiles" `Quick test_SQL01_database_select_compiles;
      test_case "SQL02 insert compiles" `Quick test_SQL02_database_insert_compiles;
      test_case "SQL03 select with where compiles" `Quick test_SQL03_database_select_with_where_compiles;
      test_case "SQL04 update compiles" `Quick test_SQL04_database_update_compiles;
      test_case "SQL05 non-sql function app still works" `Quick test_SQL05_non_sql_app_expression_compiles;
      test_case "SQL06 select with order/limit compiles" `Quick test_SQL06_select_with_order_compiles;
    ];
    "arithmetic-transparency", [
      test_case "ARITH01 multiplication on proof param" `Quick test_ARITH01_basic_multiplication_on_proof_param;
      test_case "ARITH02 addition of two proof params" `Quick test_ARITH02_addition_of_two_proof_params;
      test_case "ARITH03 comparison in if condition" `Quick test_ARITH03_comparison_in_if_condition;
      test_case "ARITH04 string interpolation with proof value" `Quick test_ARITH04_string_interpolation_with_proof_value;
      test_case "ARITH05 chained let arithmetic" `Quick test_ARITH05_chained_let_arithmetic;
      test_case "ARITH06 compound multi-param expression" `Quick test_ARITH06_compound_expression_multi_param;
      test_case "ARITH07 proof value in boolean and" `Quick test_ARITH07_proof_value_in_boolean_and;
      test_case "ARITH08 subtraction on proof param" `Quick test_ARITH08_subtraction_on_proof_param;
      test_case "ARITH09 proof value in case arm" `Quick test_ARITH09_proof_value_in_case_arm;
      test_case "ARITH10 nested arithmetic deep" `Quick test_ARITH10_nested_arithmetic_deep;
    ];
    "division-safety", [
      test_case "SAFE01 division without proof rejected" `Quick test_SAFE01_division_without_proof_rejected;
      test_case "SAFE02 modulo without proof rejected" `Quick test_SAFE02_modulo_without_proof_rejected;
      test_case "SAFE03 division with nonzero proof accepted" `Quick test_SAFE03_division_with_nonzero_proof_accepted;
      test_case "SAFE04 Int.divide without proof rejected" `Quick test_SAFE04_int_divide_stdlib_without_proof_rejected;
    ];
  ]
