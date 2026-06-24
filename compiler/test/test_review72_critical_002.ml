(** Critical review 002 — adversarial and creative tests.

    Tests derived from the second critical review of the Tesl language.
    These probe previously-untested corners:

    Fixed in this review:
      - Codec toJson with non-existent record fields now errors
      - Negative integer literals in case patterns now work
      - Empty case expression gives a helpful error message
      - KanelBackend.tesl missing List import fixed

    New test groups:
      CODEC  — codec field name validation (was silent bug)
      NEGPAT — negative literal patterns (was broken, now works)
      CASE   — case expression edge cases
      HOF    — higher-order functions and type inference
      RECUR  — recursion and mutual recursion
      PROOF2 — advanced proof system edge cases
      SQL2   — SQL layer edge cases
      ERR2   — error message quality (second pass)
      SCOPE  — module and scoping edge cases *)

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
  let dir = Filename.temp_dir "tesl-r72" "" in
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

(* ── CODEC — codec field name validation ─────────────────────────────────── *)

let test_CODEC01_toJson_nonexistent_field_rejected () =
  (* BUG FIX: codec toJson with non-existent field was silently accepted *)
  should_fail "does not exist\\|ghostField\\|valid fields" {|
#lang tesl
module Codec01 exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Json exposing [stringCodec, intCodec]
record Item { name: String price: Int }
codec Item {
  toJson {
    name      -> "name"  with_codec stringCodec
    ghostField -> "ghost" with_codec intCodec
  }
  fromJson [ { name <- "name" with_codec stringCodec price <- "price" with_codec intCodec } ]
}
|}

let test_CODEC02_fromJson_nonexistent_field_rejected () =
  should_fail "does not exist\\|ghostField\\|valid fields" {|
#lang tesl
module Codec02 exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Json exposing [stringCodec, intCodec]
record Item { name: String price: Int }
codec Item {
  toJson { name -> "name" with_codec stringCodec price -> "price" with_codec intCodec }
  fromJson [
    {
      name      <- "name"  with_codec stringCodec
      ghostField <- "ghost" with_codec intCodec
    }
  ]
}
|}

let test_CODEC03_valid_codec_all_fields_accepted () =
  should_pass {|
#lang tesl
module Codec03 exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Json exposing [stringCodec, intCodec]
record User { name: String age: Int }
codec User {
  toJson {
    name -> "name" with_codec stringCodec
    age  -> "age"  with_codec intCodec
  }
  fromJson [ { name <- "name" with_codec stringCodec age <- "age" with_codec intCodec } ]
}
|}

let test_CODEC04_partial_toJson_valid_fields_accepted () =
  (* Partial toJson (not all fields) is valid — you can choose what to serialize *)
  should_pass {|
#lang tesl
module Codec04 exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Json exposing [stringCodec, intCodec]
record User { name: String age: Int }
codec User {
  toJson { name -> "name" with_codec stringCodec }
  fromJson [
    {
      name <- "name" with_codec stringCodec
      age  <- "age"  with_codec intCodec
    }
  ]
}
|}

let test_CODEC05_toJson_wrong_codec_type_rejected () =
  should_fail "type.*mismatch\\|codec.*type\\|intCodec.*String\\|String.*intCodec" {|
#lang tesl
module Codec05 exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Json exposing [intCodec]
record Item { name: String }
codec Item {
  toJson { name -> "name" with_codec intCodec }
  fromJson_forbidden
}
|}

(* ── NEGPAT — negative literal patterns ────────────────────────────────── *)

let test_NEGPAT01_negative_int_in_case_accepted () =
  (* BUG FIX: negative literals in patterns were broken *)
  should_pass {|
#lang tesl
module NegPat01 exposing []
import Tesl.Prelude exposing [Int, String]
fn classify(n: Int) -> String =
  case n of
    0  -> "zero"
    -1 -> "minus one"
    1  -> "one"
    _  -> "other"
|}

let test_NEGPAT02_multiple_negative_patterns_accepted () =
  should_pass {|
#lang tesl
module NegPat02 exposing []
import Tesl.Prelude exposing [Int, String]
fn sign(n: Int) -> String =
  case n of
    0    -> "zero"
    -100 -> "very negative"
    _    -> "other"
|}

let test_NEGPAT03_negative_in_top_level_pattern_accepted () =
  (* Negative literals work at the top level of a case arm *)
  should_pass {|
#lang tesl
module NegPat03 exposing []
import Tesl.Prelude exposing [Int, String]
fn describeNeg(n: Int) -> String =
  case n of
    -10 -> "minus ten"
    -1  -> "minus one"
    0   -> "zero"
    _   -> "other"
|}

(* ── CASE — case expression edge cases ────────────────────────────────────── *)

let test_CASE01_empty_case_gives_helpful_error () =
  (* BUG FIX: empty case was giving "expected INDENT but got DEDENT" *)
  should_fail "at least one arm\\|case.*arm\\|Pattern -> expression" {|
#lang tesl
module Case01 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
fn bad(m: Maybe Int) -> Int =
  case m of
|}

let test_CASE02_full_coverage_wildcard_accepted () =
  should_pass {|
#lang tesl
module Case02 exposing []
import Tesl.Prelude exposing [Int, String]
type Color
  = Red
  | Green
  | Blue
fn colorName(c: Color) -> String =
  case c of
    Red   -> "red"
    Green -> "green"
    Blue  -> "blue"
|}

let test_CASE03_duplicate_case_arm_rejected () =
  should_fail "duplicate.*arm\\|already.*covered\\|already.*matched" {|
#lang tesl
module Case03 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
fn bad(m: Maybe Int) -> Int =
  case m of
    Nothing -> 0
    Nothing -> 1
    Something n -> n
|}

let test_CASE04_case_with_guard_accepted () =
  should_pass {|
#lang tesl
module Case04 exposing []
import Tesl.Prelude exposing [Int, String]
fn classify(n: Int) -> String =
  case n of
    x where x < 0 -> "negative"
    0 -> "zero"
    _ -> "positive"
|}

let test_CASE05_literal_patterns_accepted () =
  should_pass {|
#lang tesl
module Case05 exposing []
import Tesl.Prelude exposing [Int, String]
fn respond(s: String) -> String =
  case s of
    "hello" -> "greeting"
    "bye"   -> "farewell"
    _       -> "unknown"
|}

(* ── HOF — Higher-order functions and type inference ────────────────────── *)

let test_HOF01_returning_function_type_accepted () =
  should_pass {|
#lang tesl
module Hof01 exposing []
import Tesl.Prelude exposing [Int]
fn makeAdder(x: Int) -> (Int -> Int) = fn(y: Int) -> x + y
fn apply(f: Int -> Int, n: Int) -> Int = f n
fn test() -> Int = apply (makeAdder 5) 3
|}

let test_HOF02_generic_type_variable_accepted () =
  should_pass {|
#lang tesl
module Hof02 exposing []
import Tesl.Prelude exposing [List]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.List exposing [List.head]
fn headOrDefault(xs: List a, default: a) -> a =
  case List.head xs of
    Nothing   -> default
    Something x -> x
|}

let test_HOF03_function_passed_as_argument_accepted () =
  should_pass {|
#lang tesl
module Hof03 exposing []
import Tesl.Prelude exposing [Int, List, Bool(..)]
import Tesl.List exposing [List.map, List.filter]
fn double(n: Int) -> Int = n * 2
fn isPositive(n: Int) -> Bool = n > 0
fn processAll(xs: List Int) -> List Int = List.map double (List.filter isPositive xs)
|}

(* ── RECUR — Recursion ────────────────────────────────────────────────────── *)

let test_RECUR01_simple_recursion_accepted () =
  should_pass {|
#lang tesl
module Recur01 exposing []
import Tesl.Prelude exposing [Int, Bool(..)]
fn countdown(n: Int) -> Int =
  if n <= 0 then
    0
  else
    countdown (n - 1)
|}

let test_RECUR02_mutual_recursion_accepted () =
  should_pass {|
#lang tesl
module Recur02 exposing []
import Tesl.Prelude exposing [Int, Bool(..)]
fn isEven(n: Int) -> Bool =
  if n == 0 then
    True
  else
    isOdd (n - 1)
fn isOdd(n: Int) -> Bool =
  if n == 0 then
    False
  else
    isEven (n - 1)
|}

(* ── PROOF2 — Advanced proof system edge cases ────────────────────────────── *)

let test_PROOF2_01_establish_preserves_proof_through_arithmetic () =
  (* Correct pattern: proof owner provides domain operation via establish *)
  should_pass {|
#lang tesl
module Proof201 exposing []
import Tesl.Prelude exposing [Int, Fact]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
establish addOnePreservesPositive(n: Int) -> Fact (IsPositive (n + 1)) =
  IsPositive (n + 1)
fn addOne(x: Int ::: IsPositive x) -> Int ? IsPositive =
  let result = x + 1
  let pf = addOnePreservesPositive x
  result ::: pf
fn triple(x: Int ::: IsPositive x) -> Int ? IsPositive =
  let a = addOne x
  let b = addOne a
  addOne b
test "triple preserves proof" {
  let n = 1
  let pos = check checkPos n
  let result = triple pos
  expect result == 4
}
|}

let test_PROOF2_02_proof_not_transferable_to_arithmetic_result () =
  (* Proof is correctly dropped after arithmetic — use establish pattern instead *)
  should_fail "does not.*statically\\|proof\\|IsPositive" {|
#lang tesl
module Proof202 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then ok n ::: IsPositive n else fail 400 "bad"
fn requiresPos(n: Int ::: IsPositive n) -> Int = n
fn antipattern(raw: Int) -> Int =
  let validated = check checkPos raw
  requiresPos (validated + 1)
|}

let test_PROOF2_03_forall_list_filterCheck_accepted () =
  should_pass {|
#lang tesl
module Proof203 exposing []
import Tesl.Prelude exposing [Int, List]
import Tesl.List exposing [List.filterCheck, List.length]
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn countValid(xs: List Int) -> Int =
  List.length (List.filterCheck checkPos xs)
|}

let test_PROOF2_04_duplicate_fact_rejected () =
  should_fail "duplicate.*fact\\|fact.*duplicate" {|
#lang tesl
module Proof204 exposing []
import Tesl.Prelude exposing [Int]
fact IsValid (n: Int)
fact IsValid (n: Int)
|}

let test_PROOF2_05_proof_with_conjunction_and_then_both_required () =
  should_pass {|
#lang tesl
module Proof205 exposing []
import Tesl.Prelude exposing [Int]
fact P (n: Int)
fact Q (n: Int)
check makeP(n: Int) -> n: Int ::: P n =
  if n > 0 then
    ok n ::: P n
  else
    fail 400 "bad"
check makeQ(n: Int) -> n: Int ::: Q n =
  if n < 100 then
    ok n ::: Q n
  else
    fail 400 "bad"
fn requiresBoth(n: Int ::: P n && Q n) -> Int = n
fn doTest(raw: Int) -> Int =
  let withP = check makeP raw
  let withPQ = check makeQ withP
  requiresBoth withPQ
|}

(* ── SQL2 — SQL edge cases ────────────────────────────────────────────────── *)

let test_SQL2_01_complex_boolean_where_accepted () =
  should_pass {|
#lang tesl
module Sql201 exposing []
import Tesl.Prelude exposing [Int, String, List, Bool(..)]
import Tesl.DB exposing [dbRead]
database Db { backend postgres schema "s" entities [Task]
  postgres { database "d" user "u" password "" host "localhost" port 5432 socket "" } }
entity Task table "tasks" primaryKey id { id: Int priority: Int done: Bool }
fn highPriorityPending(minPriority: Int) -> List Task requires [dbRead] =
  select t from Task
    where t.priority >= minPriority && t.done == False
|}

let test_SQL2_02_select_with_order_and_limit_accepted () =
  should_pass {|
#lang tesl
module Sql202 exposing []
import Tesl.Prelude exposing [Int, String, List]
import Tesl.DB exposing [dbRead]
database Db { backend postgres schema "s" entities [Post]
  postgres { database "d" user "u" password "" host "localhost" port 5432 socket "" } }
entity Post table "posts" primaryKey id { id: Int score: Int title: String }
fn topPosts() -> List Post requires [dbRead] =
  select p from Post
    order p.score desc
    limit 10
|}

let test_SQL2_03_select_nonexistent_field_rejected () =
  should_fail "unknown field\\|ghostField\\|valid fields" {|
#lang tesl
module Sql203 exposing []
import Tesl.Prelude exposing [Int, String, List]
import Tesl.DB exposing [dbRead]
database Db { backend postgres schema "s" entities [Item]
  postgres { database "d" user "u" password "" host "localhost" port 5432 socket "" } }
entity Item table "items" primaryKey id { id: Int name: String }
fn bad() -> List Item requires [dbRead] =
  select i from Item where i.ghostField == 42
|}

(* ── ERR2 — Error message quality (second pass) ──────────────────────────── *)

let test_ERR2_01_empty_case_gives_helpful_message () =
  should_fail "at least one arm\\|Pattern -> expression\\|case.*arm" {|
#lang tesl
module Err201 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
fn f(m: Maybe Int) -> Int =
  case m of
|}

let test_ERR2_02_handler_kind_required_in_server () =
  (* Server bindings must point at `handler` declarations, not plain fn *)
  should_fail "not a handler\\|not.*handler\\|declared.*not.*handler" {|
#lang tesl
module Err202 exposing []
import Tesl.Prelude exposing [Int, String]
api Err202Api { get "/ping" -> String }
fn notAHandler() -> String requires [] = "pong"
server Err202Server for Err202Api { notAHandler = notAHandler }
|}

let test_ERR2_03_missing_import_gives_suggestion () =
  should_fail "Try: import\\|add it to an import\\|not in scope" {|
#lang tesl
module Err203 exposing []
fn bad(xs: List Int) -> Int = 0
|}

let test_ERR2_04_codec_nonexistent_field_gives_field_list () =
  (* Error message should show valid fields *)
  should_fail "valid fields.*name.*age\\|name.*age.*valid fields\\|does not exist" {|
#lang tesl
module Err204 exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Json exposing [intCodec]
record Rec { name: String age: Int }
codec Rec {
  toJson { notAField -> "x" with_codec intCodec }
  fromJson_forbidden
}
|}

let test_ERR2_05_undefined_capability_names_clearly () =
  should_fail "undeclared capability\\|unknown.*capability" {|
#lang tesl
module Err205 exposing []
import Tesl.Prelude exposing [Int]
fn bad() -> Int requires [totallyFakeCapability] = 42
|}

(* ── SCOPE — module and scoping edge cases ────────────────────────────────── *)

let test_SCOPE01_module_name_must_match_filename () =
  (* The module name in the header must match the filename.
     We use with_temp_file directly to control the filename. *)
  let dir = Filename.temp_dir "tesl-r72-scope01" "" in
  let path = Filename.concat dir "correct-name.tesl" in
  let oc = open_out path in
  output_string oc {|#lang tesl
module WrongName exposing []
import Tesl.Prelude exposing [Int]
fn foo() -> Int = 42
|};
  close_out oc;
  Fun.protect
    ~finally:(fun () -> (try Sys.remove path with _ -> ()); (try Unix.rmdir dir with _ -> ()))
    (fun () ->
      let code, out = run_compiler ["--check"; path] in
      if code = 0 then failf "expected failure, but succeeded";
      let re = Str.regexp_case_fold "does not match file name\\|module.*file" in
      try ignore (Str.search_forward re out 0)
      with Not_found -> failf "expected error about module/file mismatch, got:\n%s" out)

let test_SCOPE02_exporting_nonexistent_name_rejected () =
  should_fail "unknown.*non-local\\|module exposes unknown" {|
#lang tesl
module Scope02 exposing [thisDoesNotExist]
import Tesl.Prelude exposing [Int]
fn realFn() -> Int = 42
|}

let test_SCOPE03_importing_same_name_twice_rejected () =
  should_fail "duplicate import\\|already imported" {|
#lang tesl
module Scope03 exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Prelude exposing [Int, String]
fn foo() -> Int = 42
|}

let test_SCOPE04_using_all_stdlib_modules_together_accepted () =
  (* Regression: importing many modules together should work *)
  should_pass {|
#lang tesl
module Scope04 exposing []
import Tesl.Prelude exposing [Int, String, List, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.List exposing [List.length, List.head, List.filter, List.map]
import Tesl.String exposing [String.length, String.contains]
import Tesl.Int exposing [Int.abs, Int.toString]
import Tesl.Dict exposing [Dict, Dict.empty, Dict.insert, Dict.lookup]
fn test(xs: List Int, s: String) -> Int =
  let filtered = List.filter (fn(n: Int) -> n > 0) xs
  let mapped = List.map Int.toString filtered
  String.length s + List.length mapped
|}

(* ── Test runner ─────────────────────────────────────────────────────────── *)

let () =
  run "Review72-Critical-002" [
    "codec-field-validation", [
      test_case "CODEC01 toJson nonexistent field rejected" `Quick test_CODEC01_toJson_nonexistent_field_rejected;
      test_case "CODEC02 fromJson nonexistent field rejected" `Quick test_CODEC02_fromJson_nonexistent_field_rejected;
      test_case "CODEC03 valid codec accepted" `Quick test_CODEC03_valid_codec_all_fields_accepted;
      test_case "CODEC04 partial toJson valid accepted" `Quick test_CODEC04_partial_toJson_valid_fields_accepted;
      test_case "CODEC05 wrong codec type rejected" `Quick test_CODEC05_toJson_wrong_codec_type_rejected;
    ];
    "negative-literal-patterns", [
      test_case "NEGPAT01 negative int in case accepted" `Quick test_NEGPAT01_negative_int_in_case_accepted;
      test_case "NEGPAT02 multiple negative patterns accepted" `Quick test_NEGPAT02_multiple_negative_patterns_accepted;
      test_case "NEGPAT03 negative in top-level pattern accepted" `Quick test_NEGPAT03_negative_in_top_level_pattern_accepted;
    ];
    "case-edge-cases", [
      test_case "CASE01 empty case helpful error" `Quick test_CASE01_empty_case_gives_helpful_error;
      test_case "CASE02 full coverage wildcard accepted" `Quick test_CASE02_full_coverage_wildcard_accepted;
      test_case "CASE03 duplicate arm rejected" `Quick test_CASE03_duplicate_case_arm_rejected;
      test_case "CASE04 case with guard accepted" `Quick test_CASE04_case_with_guard_accepted;
      test_case "CASE05 literal string patterns accepted" `Quick test_CASE05_literal_patterns_accepted;
    ];
    "higher-order-functions", [
      test_case "HOF01 returning function type accepted" `Quick test_HOF01_returning_function_type_accepted;
      test_case "HOF02 generic type variable accepted" `Quick test_HOF02_generic_type_variable_accepted;
      test_case "HOF03 function as argument accepted" `Quick test_HOF03_function_passed_as_argument_accepted;
    ];
    "recursion", [
      test_case "RECUR01 simple recursion accepted" `Quick test_RECUR01_simple_recursion_accepted;
      test_case "RECUR02 mutual recursion accepted" `Quick test_RECUR02_mutual_recursion_accepted;
    ];
    "proof-system-advanced", [
      test_case "PROOF2_01 establish preserves proof" `Quick test_PROOF2_01_establish_preserves_proof_through_arithmetic;
      test_case "PROOF2_02 arithmetic result has no proof" `Quick test_PROOF2_02_proof_not_transferable_to_arithmetic_result;
      test_case "PROOF2_03 ForAll filterCheck accepted" `Quick test_PROOF2_03_forall_list_filterCheck_accepted;
      test_case "PROOF2_04 duplicate fact rejected" `Quick test_PROOF2_04_duplicate_fact_rejected;
      test_case "PROOF2_05 conjunction then requires both" `Quick test_PROOF2_05_proof_with_conjunction_and_then_both_required;
    ];
    "sql-edge-cases", [
      test_case "SQL2_01 complex boolean where accepted" `Quick test_SQL2_01_complex_boolean_where_accepted;
      test_case "SQL2_02 select order limit accepted" `Quick test_SQL2_02_select_with_order_and_limit_accepted;
      test_case "SQL2_03 nonexistent field in where rejected" `Quick test_SQL2_03_select_nonexistent_field_rejected;
    ];
    "error-message-quality", [
      test_case "ERR2_01 empty case helpful message" `Quick test_ERR2_01_empty_case_gives_helpful_message;
      test_case "ERR2_02 handler kind required in server binding" `Quick test_ERR2_02_handler_kind_required_in_server;
      test_case "ERR2_03 missing import gives suggestion" `Quick test_ERR2_03_missing_import_gives_suggestion;
      test_case "ERR2_04 codec bad field shows valid fields" `Quick test_ERR2_04_codec_nonexistent_field_gives_field_list;
      test_case "ERR2_05 undefined capability clear error" `Quick test_ERR2_05_undefined_capability_names_clearly;
    ];
    "scoping", [
      test_case "SCOPE01 module name must match file" `Quick test_SCOPE01_module_name_must_match_filename;
      test_case "SCOPE02 exporting nonexistent name rejected" `Quick test_SCOPE02_exporting_nonexistent_name_rejected;
      test_case "SCOPE03 duplicate module import rejected" `Quick test_SCOPE03_importing_same_name_twice_rejected;
      test_case "SCOPE04 many stdlib modules together accepted" `Quick test_SCOPE04_using_all_stdlib_modules_together_accepted;
    ];
  ]
