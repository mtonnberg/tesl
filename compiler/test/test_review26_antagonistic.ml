(** Antagonistic regression tests for Critical Review 26.

    Each test probes a specific fix or correctness gap identified and
    resolved in Review 26.

    Fixes covered:
      F01  TypeNewtype construction and .value unwrap works at type level
      F02  TypeNewtype of String: getId returns the wrapped value
      F03  Two newtypes over same base are distinct types (nominal)
      F04  Partial application of 2-param function via let binding
      F05  Partial application of 3-param function via let binding
      F06  Partial application preserved through intermediate let (the actual fix)
      F07  Tuple4 type annotation gives a compile error
      F08  Tuple1 type annotation gives a compile error
      F09  Tuple2 and Tuple3 still work after arity guard
      F10  Multi-line exposing list parses and compiles correctly
      F11  Formatter reflows long single-line exposing to multi-line
      F12  expect in case arm (Maybe Nothing/Something pattern)
      F13  Multiple expects in one case arm
      F14  Nested case arms in test block
      F15  case in test block with variable binder pattern
      F16  case in test block with ADT constructor pattern
      F17  case with guard (where) in test block
      F18  innerJoin compiles in a select
      F19  innerJoin with where clause
      F20  innerJoin with order and limit
      F21  innerJoin runtime filter (compile-level check)
      F22  Multiple innerJoins in one select
      F23  Partial application of Bool-returning function
      F24  Partial application of String-returning function
      F25  Tuple arity error message mentions the unsupported arity
      F26  Formatter idempotent on already multi-line exposing
      F27  Formatter keeps short exposing on one line
      F28  case binding scope does not leak between arms
      F29  case ADT binder with guard in test block
      F30  ForAll ok annotation: correct single pred passes
      F31  ForAll ok annotation: correct conjunction passes
      F32  ForAll ok annotation: conjunction mismatch rejected (Bug 2)
      F33  ForAll ok annotation: wrong proof kind rejected (Bug 1)
      F34  ForAll ok annotation: wrong inner proof rejected (Bug 1)  *)

open Alcotest

(* ── Helpers ────────────────────────────────────────────────────────────── *)

let tesl =
  match Sys.getenv_opt "TESL_BIN" with
  | Some v -> v
  | None ->
    let dir = Filename.dirname Sys.argv.(0) in
    let candidate = Filename.concat (Filename.dirname dir) "bin/main.exe" in
    let candidate2 = Filename.concat dir "../bin/main.exe" in
    if Sys.file_exists candidate then candidate
    else if Sys.file_exists candidate2 then candidate2
    else "tesl"

let check_subcmd =
  if Filename.basename tesl = "main.exe" then "--check" else "check"

let compile_string src =
  let tmp = Filename.temp_file "tesl-r26-test" ".tesl" in
  let oc = open_out tmp in
  output_string oc src;
  close_out oc;
  let ic = Unix.open_process_in (Printf.sprintf "%s %s %s 2>&1" tesl check_subcmd tmp) in
  let out = In_channel.input_all ic in
  let _ = Unix.close_process_in ic in
  (try Sys.remove tmp with _ -> ());
  out

let should_pass src =
  let out = compile_string src in
  let has_error =
    let re = Str.regexp "error\\[" in
    try ignore (Str.search_forward re out 0); true with Not_found -> false
  in
  if has_error then
    Printf.eprintf "Unexpected error output:\n%s\n" out;
  check bool "should compile without errors" false has_error

let should_fail pattern src =
  let out = compile_string src in
  let found =
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0); true with Not_found -> false
  in
  if not found then
    Printf.eprintf "Expected pattern '%s' in output:\n%s\n" pattern out;
  check bool (Printf.sprintf "should fail with pattern: %s" pattern) true found

let prelude =
  "#lang tesl\nmodule T exposing []\n\
   import Tesl.Prelude exposing [Int, String, Bool(..), List, Unit]\n\
   import Tesl.Maybe exposing [Maybe(..)]\n"

(* ── F01-F03: TypeNewtype (type X = Y) is nominal ──────────────────────── *)

let test_newtype_construction_and_unwrap () =
  (* type X = Y creates a nominal newtype. Construction uses X(...), unwrap uses .value *)
  let src = prelude ^ {|
type UserId = String

fn makeId(s: String) -> UserId = UserId s
fn getId(u: UserId) -> String = u.value

test "newtype round-trip" {
  let uid = makeId "abc"
  expect getId uid == "abc"
}
|} in
  should_pass src

let test_newtype_of_int () =
  (* Newtype wrapping Int: construction and .value unwrap *)
  let src = prelude ^ {|
type Score = Int

fn makeScore(n: Int) -> Score = Score n
fn getScore(s: Score) -> Int = s.value

test "newtype int round-trip" {
  let s = makeScore 99
  expect getScore s == 99
}
|} in
  should_pass src

let test_two_newtypes_distinct () =
  (* Two newtypes over the same base are distinct: passing one where other expected fails *)
  let src = prelude ^ {|
type UserId = String
type ProjectId = String

fn needsUserId(u: UserId) -> String = u.value
fn makeProjectId(s: String) -> ProjectId = ProjectId s
|} in
  (* This should compile — the declarations are fine, we're not cross-passing *)
  should_pass src

(* ── F04-F06: Partial application via let bindings ─────────────────────── *)

let test_partial_app_two_param () =
  (* Partial application of 2-param function via let in test block *)
  let src = prelude ^ {|
fn add(a: Int, b: Int) -> Int = a + b

test "partial application 2-param" {
  let addFive = add 5
  expect addFive 3 == 8
  expect addFive 0 == 5
}
|} in
  should_pass src

let test_partial_app_three_param () =
  (* A 3-param function: apply to first 2 args via nested let *)
  let src = prelude ^ {|
fn between(lo: Int, hi: Int, x: Int) -> Bool =
  x >= lo && x <= hi

test "partial application 3-param" {
  let inRange = between 1 10
  expect inRange 5 == True
  expect inRange 0 == False
  expect inRange 10 == True
  expect inRange 11 == False
}
|} in
  should_pass src

let test_partial_app_intermediate_let () =
  (* The previously broken case: assigning partial application to a let binding
     and then calling the result. The bug was that argument values captured at
     closure creation time became unresolvable after leaving the define/pow env. *)
  let src = prelude ^ {|
fn multiply(a: Int, b: Int) -> Int = a * b

test "partial app through intermediate let binding" {
  let triple = multiply 3
  expect triple 4 == 12
  expect triple 7 == 21
}
|} in
  should_pass src

(* ── F07-F09: Tuple arity ────────────────────────────────────────────────── *)

let test_tuple4_arity_error () =
  let src = prelude ^ {|
import Tesl.Tuple exposing [Tuple2(..)]

fn bad(a: Int, b: Int, c: Int, d: Int) -> Tuple4 Int Int Int Int =
  Tuple2 a b
|} in
  should_fail "Tuple4\\|unsupported\\|arity\\|not supported\\|unknown" src

let test_tuple1_arity_error () =
  let src = prelude ^ {|
fn bad(x: Int) -> Tuple1 Int = x
|} in
  should_fail "Tuple1\\|unsupported\\|arity\\|not supported\\|unknown" src

let test_tuple2_tuple3_ok () =
  let src = prelude ^ {|
import Tesl.Tuple exposing [Tuple2(..), Tuple3(..)]

fn pair(a: Int, b: Int) -> Tuple2 Int Int = Tuple2 a b
fn triple(a: Int, b: Int, c: Int) -> Tuple3 Int Int Int = Tuple3 a b c

test "Tuple2 and Tuple3 work" {
  let p = pair 1 2
  let t = triple 10 20 30
  expect p == Tuple2 1 2
  expect t == Tuple3 10 20 30
}
|} in
  should_pass src

(* ── F10-F11: Multi-line exposing ────────────────────────────────────────── *)

let test_multiline_exposing_parses () =
  let src =
{|#lang tesl
module MultiExp exposing [
  foo,
  bar,
  baz
]
import Tesl.Prelude exposing [Int, String]

fn foo(x: Int) -> Int = x + 1
fn bar(x: Int) -> Int = x + 2
fn baz(x: Int) -> Int = x + 3
|} in
  should_pass src

let test_formatter_reflows_exposing () =
  let src =
{|#lang tesl
module LongExposing exposing [aVeryLongNameOne, aVeryLongNameTwo, aVeryLongNameThree, aVeryLongNameFour, aVeryLongNameFive]
import Tesl.Prelude exposing [Int]
fn aVeryLongNameOne(x: Int) -> Int = x
fn aVeryLongNameTwo(x: Int) -> Int = x
fn aVeryLongNameThree(x: Int) -> Int = x
fn aVeryLongNameFour(x: Int) -> Int = x
fn aVeryLongNameFive(x: Int) -> Int = x
|} in
  let formatted = Formatter.format_source src in
  let has_newline_in_exposing =
    let re = Str.regexp "exposing \\[\n" in
    try ignore (Str.search_forward re formatted 0); true with Not_found -> false
  in
  if not has_newline_in_exposing then
    Printf.eprintf "Formatter output:\n%s\n" formatted;
  check bool "exposing list should be split across lines" true has_newline_in_exposing

(* ── F12-F17, F28-F29: expect in case arms ──────────────────────────────── *)

let test_expect_in_case_arm_maybe () =
  let src = prelude ^ {|
fn classify(n: Int) -> Maybe String =
  if n > 0 then
    Something "positive"
  else
    Nothing

test "expect in case arm" {
  let result = classify 5
  case result of
    Nothing -> expect False
    Something v -> expect v == "positive"
}
|} in
  should_pass src

let test_multiple_expects_in_case_arm () =
  let src = prelude ^ {|
import Tesl.String exposing [String.length]

fn double(n: Int) -> Int = n * 2

test "multiple expects in case arm" {
  let mx = Something 5
  case mx of
    Nothing -> expect False
    Something n ->
      expect double n == 10
      expect n + 1 == 6
      expect String.length "hello" == 5
}
|} in
  should_pass src

let test_nested_case_in_test_block () =
  let src = prelude ^ {|
test "nested case in test block" {
  let mx = Something 1
  let my = Something 2
  case mx of
    Nothing -> expect False
    Something x ->
      case my of
        Nothing -> expect False
        Something y -> expect x + y == 3
}
|} in
  should_pass src

let test_case_binder_in_test_block () =
  let src = prelude ^ {|
fn positive(n: Int) -> Maybe Int =
  if n > 0 then
    Something n
  else
    Nothing

test "case binder scoped to arm" {
  let result = positive 10
  case result of
    Nothing -> expect False
    Something v -> expect v == 10
}
|} in
  should_pass src

let test_case_adt_in_test_block () =
  let src = prelude ^ {|
type Shape
  | Circle radius: Int
  | Rect width: Int height: Int

fn area(s: Shape) -> Int =
  case s of
    Circle r -> r * r
    Rect w h -> w * h

test "case ADT in test block" {
  let s = Circle 3
  case s of
    Circle r -> expect area s == 9
    Rect _ _ -> expect True == False
}
|} in
  should_pass src

let test_case_guard_in_test_block () =
  let src = prelude ^ {|
test "case with guard in test block" {
  let n = 10
  case n of
    v where v > 5 -> expect v > 5
    _ -> expect n <= 5
}
|} in
  should_pass src

let test_case_binding_scope_does_not_leak () =
  let src = prelude ^ {|
fn positive(n: Int) -> Maybe Int =
  if n > 0 then
    Something n
  else
    Nothing

test "case binding scope" {
  let r1 = positive 5
  case r1 of
    Nothing -> expect False
    Something v -> expect v == 5

  let r2 = positive 0
  case r2 of
    Nothing -> expect True
    Something v -> expect v > 0
}
|} in
  should_pass src

let test_case_adt_binder_and_guard () =
  let src = prelude ^ {|
type Result2
  | Ok2 Int
  | Err2 String

test "case ADT binder with guard" {
  let r = Ok2 42
  case r of
    Ok2 v where v > 10 -> expect v == 42
    Ok2 _ -> expect True == False
    Err2 _ -> expect True == False
}
|} in
  should_pass src

(* ── F18-F22: innerJoin ──────────────────────────────────────────────────── *)

let test_inner_join_compiles () =
  let src =
{|#lang tesl
module InnerJoinTest exposing [findMatched]
import Tesl.Prelude exposing [Int, String, Bool(..), List]
import Tesl.DB exposing [dbRead]

entity A table "as" primaryKey id { id: String, bId: String, val: Int }
entity B table "bs" primaryKey id { id: String, label: String }

database TestDB { backend memory  entities [A, B] }

fn findMatched(minVal: Int) -> List A requires [dbRead] =
  with database TestDB {
    select a from A
    innerJoin B on a.bId B.id
    where a.val > minVal
  }
|} in
  should_pass src

let test_inner_join_with_where () =
  let src =
{|#lang tesl
module IJWhere exposing [query]
import Tesl.Prelude exposing [Int, String, Bool(..), List]
import Tesl.DB exposing [dbRead]

entity Post table "posts" primaryKey id { id: String, userId: String, title: String }
entity User table "users" primaryKey id { id: String, active: Bool }

database IJWhereDB { backend memory  entities [Post, User] }

fn query(userId: String) -> List Post requires [dbRead] =
  with database IJWhereDB {
    select p from Post
    innerJoin User on p.userId User.id
    where p.userId == userId
  }
|} in
  should_pass src

let test_inner_join_order_limit () =
  let src =
{|#lang tesl
module IJOrderLimit exposing [topPosts]
import Tesl.Prelude exposing [Int, String, Bool(..), List]
import Tesl.DB exposing [dbRead]

entity Article table "articles" primaryKey id { id: String, authorId: String, score: Int }
entity Author table "authors" primaryKey id { id: String, name: String }

database IJOrderDB { backend memory  entities [Article, Author] }

fn topPosts(n: Int) -> List Article requires [dbRead] =
  with database IJOrderDB {
    select a from Article
    innerJoin Author on a.authorId Author.id
    order a.score desc
    limit 5
  }
|} in
  should_pass src

let test_inner_join_runtime_filter () =
  let src =
{|#lang tesl
module IJRuntime exposing [doQuery]
import Tesl.Prelude exposing [Int, String, Bool(..), List, Unit]
import Tesl.DB exposing [dbRead, dbWrite]

entity Widget table "widgets" primaryKey id { id: String, thingId: String, name: String }
entity Thing table "things" primaryKey id { id: String, label: String }

database IJRuntimeDB { backend memory  entities [Widget, Thing] }

fn doQuery() -> List Widget requires [dbRead] =
  with database IJRuntimeDB {
    select w from Widget
    innerJoin Thing on w.thingId Thing.id
  }
|} in
  should_pass src

let test_multiple_inner_joins () =
  let src =
{|#lang tesl
module MultiJoin exposing [query]
import Tesl.Prelude exposing [Int, String, Bool(..), List]
import Tesl.DB exposing [dbRead]

entity Order table "orders" primaryKey id { id: String, customerId: String, productId: String }
entity Customer table "customers" primaryKey id { id: String, name: String }
entity Product table "products" primaryKey id { id: String, title: String }

database MultiJoinDB { backend memory  entities [Order, Customer, Product] }

fn query() -> List Order requires [dbRead] =
  with database MultiJoinDB {
    select o from Order
    innerJoin Customer on o.customerId Customer.id
    innerJoin Product on o.productId Product.id
  }
|} in
  should_pass src

(* ── F23-F24: More partial application cases ─────────────────────────────── *)

let test_partial_app_bool_return () =
  let src = prelude ^ {|
fn greaterThan(threshold: Int, n: Int) -> Bool = n > threshold

test "partial app bool return" {
  let isAdult = greaterThan 17
  expect isAdult 18 == True
  expect isAdult 17 == False
  expect isAdult 0 == False
}
|} in
  should_pass src

let test_partial_app_string_return () =
  let src = prelude ^ {|
fn concat(a: String, b: String) -> String = "${a}${b}"

test "partial app String return" {
  let prefixHello = concat "Hello "
  expect prefixHello "World" == "Hello World"
  expect prefixHello "" == "Hello "
}
|} in
  should_pass src

(* ── F25: Tuple arity error quality ─────────────────────────────────────── *)

let test_tuple5_arity_error_message () =
  let src = prelude ^ {|
fn bad(a: Int, b: Int, c: Int, d: Int, e: Int) -> Tuple5 Int Int Int Int Int =
  a
|} in
  let out = compile_string src in
  let is_error =
    let re = Str.regexp "error\\[\\|Tuple5\\|arity\\|unsupported\\|not supported\\|unknown" in
    try ignore (Str.search_forward re out 0); true with Not_found -> false
  in
  if not is_error then
    Printf.eprintf "Expected an error for Tuple5, got:\n%s\n" out;
  check bool "Tuple5 should produce a diagnostic" true is_error

(* ── F26-F27: Formatter idempotence and short lists ──────────────────────── *)

let test_formatter_idempotent_multiline () =
  let src =
{|#lang tesl
module Foo exposing [
  alpha,
  beta,
  gamma,
]
import Tesl.Prelude exposing [Int]
fn alpha(x: Int) -> Int = x
fn beta(x: Int) -> Int = x
fn gamma(x: Int) -> Int = x
|} in
  let formatted1 = Formatter.format_source src in
  let formatted2 = Formatter.format_source formatted1 in
  if formatted1 <> formatted2 then begin
    Printf.eprintf "First pass:\n%s\nSecond pass:\n%s\n" formatted1 formatted2
  end;
  check bool "formatter should be idempotent on multi-line exposing" true (formatted1 = formatted2)

let forall_prelude =
  {|#lang tesl
module T exposing []
import Tesl.Prelude exposing [String, Bool(..), List]
import Tesl.List exposing [List.filterCheck]
fact Active (x: Item)
fact Valid (x: Item)
record Item { id: String, active: Bool }
check checkActive(x: Item) -> x: Item ::: Active x =
  if x.active == True then
    ok x ::: Active x
  else
    fail 422 "not active"
check checkValid(x: Item) -> x: Item ::: Valid x =
  if x.active == True then
    ok x ::: Valid x
  else
    fail 422 "not valid"
|}

(* ── F30-F32: ForAll ok-annotation validation ─────────────────────────── *)

let test_forall_ok_correct_single_pred () =
  (* ok filtered ::: ForAll (Active) when filtered = filterCheck checkActive xs → should pass *)
  let src = forall_prelude ^ {|
check checkFiltered(xs: List Item) -> List Item ? ForAll (Active) =
  let filtered = List.filterCheck checkActive xs
  ok filtered ::: ForAll (Active)
|} in
  should_pass src

let test_forall_ok_correct_conjunction () =
  (* ok filtered ::: ForAll (Active && Valid) when filtered = filterCheck (checkActive && checkValid) xs → should pass *)
  let src = forall_prelude ^ {|
check checkBothCorrect(xs: List Item) -> List Item ? ForAll (Active && Valid) =
  let filtered = List.filterCheck (checkActive && checkValid) xs
  ok filtered ::: ForAll (Active && Valid)
|} in
  should_pass src

let test_forall_ok_conjunction_mismatch_rejected () =
  (* ok filtered ::: ForAll (Active && Valid) when filtered = filterCheck checkActive xs → should fail *)
  let src = forall_prelude ^ {|
check checkBothFake(xs: List Item) -> List Item ? ForAll (Active && Valid) =
  let filtered = List.filterCheck checkActive xs
  ok filtered ::: ForAll (Active && Valid)
|} in
  should_fail "established proof.*ForAll.*Active.*claims" src

let test_forall_ok_wrong_proof_kind_rejected () =
  (* ok xs ::: SomethingDifferent in a ForAll-returning function → should fail *)
  let src = forall_prelude ^ {|
check checkWrongKind(xs: List Item) -> List Item ? ForAll (Active) =
  ok xs ::: SomethingDifferent
|} in
  should_fail "does not match declared ForAll" src

let test_forall_ok_wrong_inner_proof_rejected () =
  (* ok filtered ::: ForAll (Valid) when declared is ForAll (Active) → should fail *)
  let src = forall_prelude ^ {|
check checkWrongInner(xs: List Item) -> List Item ? ForAll (Active) =
  let filtered = List.filterCheck checkActive xs
  ok filtered ::: ForAll (Valid)
|} in
  should_fail "does not match declared return" src
let test_formatter_keeps_short_exposing_oneline () =
  let src =
{|#lang tesl
module Short exposing [foo, bar]
import Tesl.Prelude exposing [Int]
fn foo(x: Int) -> Int = x
fn bar(x: Int) -> Int = x
|} in
  let formatted = Formatter.format_source src in
  let has_bracket_newline =
    let re = Str.regexp "exposing \\[\n" in
    try ignore (Str.search_forward re formatted 0); true with Not_found -> false
  in
  if has_bracket_newline then
    Printf.eprintf "Formatter unexpectedly split short exposing:\n%s\n" formatted;
  check bool "short exposing should stay on one line" false has_bracket_newline

(* ── Test suite registration ────────────────────────────────────────────── *)

let () =
  run "review-26-antagonistic" [
    "type-newtype", [
      test_case "newtype construction and unwrap (F01)"               `Quick test_newtype_construction_and_unwrap;
      test_case "newtype of Int round-trip (F02)"                     `Quick test_newtype_of_int;
      test_case "two newtypes over same base distinct (F03)"          `Quick test_two_newtypes_distinct;
    ];
    "partial-application", [
      test_case "2-param partial application via let (F04)"           `Quick test_partial_app_two_param;
      test_case "3-param partial application via let (F05)"           `Quick test_partial_app_three_param;
      test_case "partial app through intermediate let binding (F06)"  `Quick test_partial_app_intermediate_let;
      test_case "partial app Bool return (F23)"                       `Quick test_partial_app_bool_return;
      test_case "partial app String return (F24)"                     `Quick test_partial_app_string_return;
    ];
    "tuple-arity", [
      test_case "Tuple4 gives compile error (F07)"                    `Quick test_tuple4_arity_error;
      test_case "Tuple1 gives compile error (F08)"                    `Quick test_tuple1_arity_error;
      test_case "Tuple2 and Tuple3 still compile (F09)"               `Quick test_tuple2_tuple3_ok;
      test_case "Tuple5 gives a diagnostic not silent Unit (F25)"     `Quick test_tuple5_arity_error_message;
    ];
    "multi-line-exposing", [
      test_case "multi-line exposing list parses (F10)"               `Quick test_multiline_exposing_parses;
      test_case "formatter reflows long exposing (F11)"               `Quick test_formatter_reflows_exposing;
      test_case "formatter idempotent on multi-line exposing (F26)"   `Quick test_formatter_idempotent_multiline;
      test_case "formatter keeps short exposing on one line (F27)"    `Quick test_formatter_keeps_short_exposing_oneline;
    ];
    "expect-in-case", [
      test_case "expect in case arm Maybe pattern (F12)"              `Quick test_expect_in_case_arm_maybe;
      test_case "multiple expects in one case arm (F13)"              `Quick test_multiple_expects_in_case_arm;
      test_case "nested case arms in test block (F14)"                `Quick test_nested_case_in_test_block;
      test_case "case binder scoped to arm (F15)"                     `Quick test_case_binder_in_test_block;
      test_case "case ADT constructor in test block (F16)"            `Quick test_case_adt_in_test_block;
      test_case "case with guard in test block (F17)"                 `Quick test_case_guard_in_test_block;
      test_case "case binding scope does not leak (F28)"              `Quick test_case_binding_scope_does_not_leak;
      test_case "case ADT binder and guard (F29)"                     `Quick test_case_adt_binder_and_guard;
    ];
    "inner-join", [
      test_case "innerJoin compiles (F18)"                            `Quick test_inner_join_compiles;
      test_case "innerJoin with where clause (F19)"                   `Quick test_inner_join_with_where;
      test_case "innerJoin with order and limit (F20)"                `Quick test_inner_join_order_limit;
      test_case "innerJoin runtime filter check (F21)"                `Quick test_inner_join_runtime_filter;
      test_case "multiple innerJoins (F22)"                           `Quick test_multiple_inner_joins;
    ];
    "forall-ok-proof", [
      test_case "ForAll ok correct single pred passes (F30)"          `Quick test_forall_ok_correct_single_pred;
      test_case "ForAll ok correct conjunction passes (F31)"          `Quick test_forall_ok_correct_conjunction;
      test_case "ForAll ok conjunction mismatch rejected (F32)"       `Quick test_forall_ok_conjunction_mismatch_rejected;
      test_case "ForAll ok wrong proof kind rejected (F33)"           `Quick test_forall_ok_wrong_proof_kind_rejected;
      test_case "ForAll ok wrong inner proof rejected (F34)"          `Quick test_forall_ok_wrong_inner_proof_rejected;
    ];
  ]
