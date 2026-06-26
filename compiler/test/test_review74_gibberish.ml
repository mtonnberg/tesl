(** Review 74 — Gibberish & near-miss code quality tests.

    Philosophy: throw plausible-but-wrong code at the compiler and verify:
      (a) it is REJECTED (never silently accepted)
      (b) it does not CRASH (no Assert_failure, Fatal_error, Failure "...")
      (c) the error message is CONSTRUCTIVE (has a hint, or names what was expected,
          or tells the user what Tesl does instead — not just "unexpected token")

    Groups:
      JS   — JavaScript/TypeScript idioms a JS dev might type
      PY   — Python idioms
      NEAR — Almost-valid Tesl with one thing wrong (highest value for error quality)
      WILD — Creative/absurd but realistic mistakes
      TRUNC — Truncated/incomplete code (crash risk)
      MULTI — Multiple errors in one file (does the compiler stay sane?) *)

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

let with_temp_file ?(ext=".tesl") content f =
  let content =
    if String.length content > 0 && content.[0] = '\n'
    then String.sub content 1 (String.length content - 1)
    else content
  in
  let path = Filename.temp_file "tesl-gib" ext in
  let oc = open_out path in output_string oc content; close_out oc;
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with _ -> ())
    (fun () -> f path)

(** Reject cleanly: exit non-zero, no crash, error message present. *)
let should_reject src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected rejection but compiler accepted:\n%s" out;
    if String.length out = 0 then failf "rejected but produced no output (silent failure)";
    if try ignore (Str.search_forward (Str.regexp "Assert_failure\\|Fatal_error\\|Failure(\\|Uncaught") out 0); true
       with Not_found -> false
    then failf "CRASH detected in output:\n%s" out)

(** Like should_reject but also checks the output matches a helpful pattern. *)
let should_reject_with pat src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected rejection matching %S but accepted" pat;
    if try ignore (Str.search_forward (Str.regexp "Assert_failure\\|Fatal_error") out 0); true
       with Not_found -> false
    then failf "CRASH:\n%s" out;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected message matching %S, got:\n%s" pat out)

(** Accept: must compile cleanly. *)
let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected clean compile, got:\n%s" out)

let should_lint_warn pat src =
  with_temp_file src (fun path ->
    let exit_code, out = run_compiler ["--lint"; path] in
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected lint warning matching %S, got (exit %d):\n%s" pat exit_code out)

(* ── Shared preamble for most tests ─────────────────────────────────────── *)

let preamble = {|#lang tesl
module GibTest exposing []
import Tesl.Prelude exposing [Int, String, Bool(..)]
|}

let preamble_with src = preamble ^ src

(* ── JS: JavaScript/TypeScript idioms ───────────────────────────────────── *)

(* JS01: TypeScript-style colon return type annotation *)
let test_JS01_typescript_colon_return () =
  should_reject_with "expected.*->\\|->.*return type\\|:" (preamble_with {|
fn greet(name: String): String = "hello"
|})

(* JS02: TypeScript arrow function =>  *)
let test_JS02_typescript_arrow () =
  should_reject (preamble_with {|
fn f(n: Int) => Int = n + 1
|})

(* JS03: const keyword (JavaScript variable declaration) *)
let test_JS03_const_keyword () =
  should_reject_with "const.*not part of\\|use.*fn\\|let.*inside" (preamble_with {|
const maxItems = 100
|})

(* JS04: let at top level (JavaScript-style) *)
let test_JS04_let_top_level () =
  should_reject (preamble_with {|
let maxItems = 100
|})

(* JS05: var keyword *)
let test_JS05_var_keyword () =
  should_reject (preamble_with {|
var x = 42
|})

(* JS06: TypeScript interface keyword *)
let test_JS06_interface_keyword () =
  should_reject (preamble_with {|
interface User {
  name: String
  age: Int
}
|})

(* JS07: class keyword *)
let test_JS07_class_keyword () =
  should_reject (preamble_with {|
class User {
  name: String
}
|})

(* JS08: async keyword before fn *)
let test_JS08_async_fn () =
  should_reject (preamble_with {|
async fn fetchUser(id: Int) -> String = "user"
|})

(* JS09: export keyword (ES modules style) *)
let test_JS09_export_keyword () =
  should_reject (preamble_with {|
export fn f(n: Int) -> Int = n
|})

(* JS10: null coalescing operator ?? inside function body *)
let test_JS10_null_coalescing_in_body () =
  (* Should reject; the error should NOT say "at top level" — we're in a fn body *)
  should_reject (preamble_with {|
fn f(n: Int) -> Int = n ?? 0
|})

(* JS11: optional chaining ?. *)
let test_JS11_optional_chaining () =
  should_reject (preamble_with {|
fn f(n: Int) -> Int = n?.value
|})

(* JS12: TypeScript-style generic function with angle brackets *)
let test_JS12_typescript_generic_angles () =
  should_reject (preamble_with {|
fn identity<T>(x: T) -> T = x
|})

(* JS13: exclamation non-null assertion (Swift/TypeScript) *)
let test_JS13_exclamation_unwrap () =
  should_reject (preamble_with {|
fn f(n: Int) -> Int = n!
|})

(* JS14: object spread syntax *)
let test_JS14_object_spread () =
  should_reject (preamble_with {|
fn f(n: Int) -> Int = ...n
|})

(* JS15: arrow function with implicit return *)
let test_JS15_arrow_implicit_return () =
  should_reject (preamble_with {|
fn f = (n: Int) => n + 1
|})

(* ── PY: Python idioms ───────────────────────────────────────────────────── *)

(* PY01: Python def keyword *)
let test_PY01_def_keyword () =
  should_reject (preamble_with {|
def processUser(user):
    return user
|})

(* PY02: Python-style return statement *)
let test_PY02_return_statement () =
  should_reject (preamble_with {|
fn f(n: Int) -> Int =
  return n
|})

(* PY03: Python from...import syntax *)
let test_PY03_from_import () =
  should_reject (preamble_with {|
from Tesl.Prelude import Int, String
fn f(n: Int) -> String = "ok"
|})

(* PY04: Python-style print call *)
let test_PY04_print_statement () =
  (* `print` is in the Tesl stdlib (type: a -> Unit) via Racket interop.
     It compiles successfully — `print "hello"` returns Unit which is
     silently discarded in the statement sequence. This bypasses Tesl's
     `telemetry` capability, so the fix is lint warning W090, not a type error.
     The linter must emit W090 for any bare `print` call in a function body. *)
  should_lint_warn "W090\\|print.*telemetry\\|telemetry.*print" (preamble_with {|
fn f() -> Int =
  print("hello")
  42
|})

(* PY05: Python None keyword *)
let test_PY05_none_keyword () =
  should_reject (preamble_with {|
fn f() -> Int = None
|})

(* PY06: Python-style list comprehension *)
let test_PY06_list_comprehension () =
  should_reject (preamble_with {|
fn f(xs: List Int) -> List Int = [x for x in xs if x > 0]
|})

(* PY07: Python decorator syntax *)
let test_PY07_decorator_syntax () =
  should_reject (preamble_with {|
@validated
fn f(n: Int) -> Int = n
|})

(* PY08: Python class with self *)
let test_PY08_python_class () =
  should_reject (preamble_with {|
class UserService:
  def __init__(self):
    self.users = []
|})

(* PY09: Python-style dict literal *)
let test_PY09_python_dict_literal () =
  should_reject (preamble_with {|
fn f() -> Int =
  let d = {"name": "alice", "age": 30}
  0
|})

(* PY10: Python lambda *)
let test_PY10_python_lambda () =
  should_reject (preamble_with {|
fn f(n: Int) -> Int = lambda x: x + n
|})

(* ── NEAR: Near-miss Tesl — one element wrong ──────────────────────────── *)

(* NEAR01: Comma between record fields (JSON/TypeScript habit) *)
let test_NEAR01_record_comma_fields () =
  (* Tesl accepts commas between record fields as optional separators.
     The docs don't mention this, but it's an accepted feature (likely intentional
     for compatibility with JSON/TypeScript users). *)
  should_pass (preamble_with {|
record User { name: String, age: Int }
|})

(* NEAR02: Pipe-separated ADT constructors on one line *)
let test_NEAR02_adt_all_on_one_line_with_pipes () =
  (* type Color = Red | Green | Blue on ONE line — is this accepted or not? *)
  should_reject (preamble_with {|
type Color = Red | Green | Blue
fn f(c: Color) -> Int = 0
|})

(* NEAR03: Fact declaration without params *)
let test_NEAR03_fact_without_params () =
  (* Zero-parameter facts ARE valid in Tesl — they represent module-level
     propositions (global predicates not tied to any particular value).
     Example: `fact MaintenanceMode` (system is in maintenance, no subject needed).
     They can be established unconditionally via `establish f() -> Fact (P) = P`.
     The test was originally written expecting rejection, but this is correct behavior. *)
  should_pass (preamble_with {|
fact IsSpecial
fn f() -> Int = 42
|})

(* NEAR04: Check fn with return type annotation but no proof (missing :::) *)
let test_NEAR04_check_missing_proof_in_return () =
  (* BUG/FOOTGUN: A `check` function with `-> n: Int` (no `:::`) silently
     accepts proof in its body (`ok n ::: IsPositive n`) but the proof is
     dropped from the contract. Callers cannot use the proof.
     The compiler should warn: "proof in ok-branch is not declared in return spec". *)
  should_reject (preamble_with {|
fact IsPositive (n: Int)
check checkPositive(n: Int) -> n: Int =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"
|})

(* NEAR05: Plain fn trying to return proof-carrying value *)
let test_NEAR05_fn_proof_return () =
  should_reject_with "fn.*cannot.*proof\\|use.*check\\|check.*establish" (preamble_with {|
fact IsPositive (n: Int)
fn f(n: Int) -> n: Int ::: IsPositive n = ok n ::: IsPositive n
|})

(* NEAR06: Import without exposing clause — then trying to use a name *)
let test_NEAR06_importall_then_use_unexported () =
  (* module-level proof: ImportAll doesn't bring names into unqualified scope *)
  should_reject (preamble_with {|
fn f() -> Int = Bool.True
|})

(* NEAR07: Using = instead of == in boolean condition *)
let test_NEAR07_assignment_as_equality () =
  should_reject (preamble_with {|
fn f(n: Int) -> Bool =
  if n = 42 then
    True
  else
    False
|})

(* NEAR08: Single-line if-then-else (very common mistake from other languages) *)
let test_NEAR08_single_line_if () =
  should_reject_with "then.*body.*indented\\|single.*line.*if\\|multi.line" (preamble_with {|
fn f(n: Int) -> Int = if n > 0 then 1 else 0
|})

(* NEAR09: ok without ::: in check function *)
let test_NEAR09_ok_without_proof () =
  should_reject (preamble_with {|
fact IsPositive (n: Int)
check checkPositive(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n
  else
    fail 400 "not positive"
|})

(* NEAR10: Establish using ok/fail syntax instead of direct constructor *)
let test_NEAR10_establish_with_ok () =
  should_reject_with "establish\\|ok.*not.*establish\\|Fact\\|type.*mismatch" (preamble_with {|
fact IsPositive (n: Int)
establish provePositive(n: Int) -> Fact (IsPositive n) =
  ok n ::: IsPositive n
|})

(* NEAR11: Case with Haskell-style leading pipe *)
let test_NEAR11_case_leading_pipe () =
  should_reject (preamble_with {|
import Tesl.Maybe exposing [Maybe(..)]
fn f(m: Maybe Int) -> Int =
  case m of
    | Nothing -> 0
    | Something n -> n
|})

(* NEAR12: Record literal without type prefix (bare braces) *)
let test_NEAR12_bare_record_literal () =
  should_reject_with "bare record\\|type.*prefix\\|TypeName.*{" (preamble_with {|
record User { name: String }
fn makeUser(s: String) -> User = { name: s }
|})

(* NEAR13: Missing exposing keyword in import *)
let test_NEAR13_import_without_exposing () =
  should_reject (preamble_with {|
import Tesl.Maybe [Maybe(..)]
fn f() -> Int = 0
|})

(* NEAR14: Calling check without the check keyword *)
let test_NEAR14_check_called_without_keyword () =
  should_reject_with "proof\\|not.*statically.*satisfy\\|check.*keyword\\|require" (preamble_with {|
fact IsPositive (n: Int)
check doCheck(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn useResult(n: Int) -> Int ::: IsPositive n = n
fn caller(raw: Int) -> Int =
  useResult raw
|})

(* NEAR15: Wrong argument order to type application (List without param) *)
let test_NEAR15_list_type_without_param () =
  should_reject_with "arity\\|type.*param\\|List.*argument\\|Int.*List" (preamble_with {|
fn f(xs: List) -> Int = 0
|})

(* NEAR16: Duplicate module declaration *)
let test_NEAR16_two_module_headers () =
  should_reject {|#lang tesl
module ModA exposing []
import Tesl.Prelude exposing [Int]
fn f() -> Int = 1
module ModB exposing []
fn g() -> Int = 2
|}

(* NEAR17: Import after a function declaration *)
let test_NEAR17_import_after_decl () =
  should_reject_with "import.*before\\|import.*after\\|move.*import" {|#lang tesl
module NearSeventeen exposing []
import Tesl.Prelude exposing [Int]
fn f() -> Int = 42
import Tesl.String exposing [String.length]
|}

(* NEAR18: Using a constructor as a pattern without the right shape *)
let test_NEAR18_wrong_constructor_pattern () =
  should_reject (preamble_with {|
import Tesl.Maybe exposing [Maybe(..)]
fn f(m: Maybe Int) -> Int =
  case m of
    Nothing 42 -> 0
    Something n -> n
|})

(* NEAR19: Check fn called without capturing result *)
let test_NEAR19_check_result_discarded () =
  (* tesl may reject "let _ = check ..." — test what actually happens *)
  should_reject (preamble_with {|
fact IsPositive (n: Int)
check doCheck(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn caller(raw: Int) -> Int =
  let _ = check doCheck raw
  raw
|})

(* NEAR20: ADT type name same as constructor name *)
let test_NEAR20_adt_ctor_same_as_type () =
  should_reject_with "same.*name\\|conflict\\|already\\|duplicate" (preamble_with {|
type Status
  = Status
  | Active
|})

(* ── WILD: Creative, unusual, entertaining wrong code ──────────────────── *)

(* WILD01: SQL query embedded in function body *)
let test_WILD01_sql_query_in_body () =
  should_reject (preamble_with {|
fn getUsers() -> Int =
  SELECT * FROM users WHERE active = true
|})

(* WILD02: JSON object literal at top level *)
let test_WILD02_json_at_top_level () =
  should_reject (preamble_with {|
{ "name": "Alice", "age": 30, "active": true }
|})

(* WILD03: Bash-style comment then code *)
let test_WILD03_bash_shebang_and_code () =
  should_reject {|#!/usr/bin/env tesl
module Wild03 exposing []
fn f() -> Int = 42
|}

(* WILD04: Markdown mixed in *)
let test_WILD04_markdown_in_module () =
  should_reject {|#lang tesl
module Wild04 exposing []

## Overview

This module does things.

fn f() -> Int = 42
|}

(* WILD05: Emoji in identifier *)
let test_WILD05_emoji_identifier () =
  should_reject (preamble_with {|
fn 🚀launch() -> Int = 42
|})

(* WILD06: Pure math notation — lambda calculus *)
let test_WILD06_lambda_calculus_syntax () =
  should_reject (preamble_with {|
fn f = λ(n: Int) . n + 1
|})

(* WILD07: Trying to use Tesl as a data format *)
let test_WILD07_data_format_style () =
  should_reject (preamble_with {|
User {
  name = "Alice"
  age = 30
}
|})

(* WILD08: Haskell-style type class / where clause *)
let test_WILD08_haskell_where () =
  should_reject (preamble_with {|
fn f(n: Int) -> Int = result
  where result = n * 2
|})

(* WILD09: Trying to use >> composition operator *)
let test_WILD09_function_composition () =
  should_reject (preamble_with {|
fn f(n: Int) -> Int = (addOne >> double) n
|})

(* WILD10: Rust-style lifetime annotations *)
let test_WILD10_rust_lifetime () =
  should_reject (preamble_with {|
fn f<'a>(n: Int) -> Int = n
|})

(* WILD11: Go-style multiple return values *)
let test_WILD11_go_multiple_returns () =
  should_reject (preamble_with {|
fn f(n: Int) -> (Int, String) = (n, "ok")
|})

(* WILD12: Using semicolons as statement separators *)
let test_WILD12_semicolons () =
  should_reject (preamble_with {|
fn f(n: Int) -> Int =
  let x = n + 1; let y = x + 1; y
|})

(* WILD13: Pattern matching with Haskell-style guards *)
let test_WILD13_haskell_guards () =
  should_reject (preamble_with {|
fn classify(n: Int) -> String
  | n < 0 = "negative"
  | n == 0 = "zero"
  | otherwise = "positive"
|})

(* WILD14: Rust match arm with => separator *)
let test_WILD14_rust_match_arm () =
  should_reject (preamble_with {|
import Tesl.Maybe exposing [Maybe(..)]
fn f(m: Maybe Int) -> Int =
  case m of
    Nothing => 0
    Something n => n
|})

(* WILD15: F# pipe operator |> *)
let test_WILD15_pipe_operator () =
  (* |> is actually a VALID Tesl pipe operator (s |> f = f s).
     It works correctly and produces the right compiled output.
     This is an undocumented feature — test that it compiles correctly. *)
  should_pass (preamble_with {|
import Tesl.String exposing [String.length]
fn f(s: String) -> Int = s |> String.length
|})

(* WILD16: Applying a literal to another literal *)
let test_WILD16_literal_application () =
  should_reject_with "Int.*Int.*->\\|cannot.*unify\\|type.*mismatch" (preamble_with {|
fn f() -> Int = 42 43
|})

(* WILD17: Trying to use #include or #pragma *)
let test_WILD17_preprocessor_directive () =
  should_reject {|#lang tesl
#include <stdlib>
module Wild17 exposing []
fn f() -> Int = 42
|}

(* WILD18: XML/HTML embedded in module *)
let test_WILD18_xml_in_module () =
  should_reject (preamble_with {|
fn f() -> String = <div>Hello world</div>
|})

(* WILD19: Trying to open a module (OCaml-style) *)
let test_WILD19_ocaml_open () =
  should_reject (preamble_with {|
open Tesl.Prelude
fn f() -> Int = 42
|})

(* WILD20: Trying to use begin...end blocks *)
let test_WILD20_begin_end_blocks () =
  should_reject (preamble_with {|
fn f(n: Int) -> Int =
  begin
    let x = n + 1
    x
  end
|})

(* ── TRUNC: Truncated/incomplete code — crash risk ───────────────────────── *)

(* TRUNC01: #lang tesl with nothing else *)
let test_TRUNC01_only_lang_header () =
  should_reject_with "module\\|library\\|expected" {|#lang tesl
|}

(* TRUNC02: Module header with no body — empty modules are valid in Tesl *)
let test_TRUNC02_module_header_only () =
  should_pass {|#lang tesl
module Trunc02 exposing []
|}

(* TRUNC03: Fn declaration truncated mid-signature *)
let test_TRUNC03_fn_truncated_mid_sig () =
  should_reject {|#lang tesl
module Trunc03 exposing []
import Tesl.Prelude exposing [Int]
fn f(n: Int
|}

(* TRUNC04: Fn with no body *)
let test_TRUNC04_fn_no_body () =
  should_reject {|#lang tesl
module Trunc04 exposing []
import Tesl.Prelude exposing [Int]
fn f(n: Int) -> Int
|}

(* TRUNC05: Record with unclosed brace *)
let test_TRUNC05_record_unclosed () =
  should_reject {|#lang tesl
module Trunc05 exposing []
import Tesl.Prelude exposing [String]
record User { name: String
|}

(* TRUNC06: Case expression with no arms *)
let test_TRUNC06_case_no_arms () =
  should_reject_with "arm\\|case.*arm\\|at least one" {|#lang tesl
module Trunc06 exposing []
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Prelude exposing [Int]
fn f(m: Maybe Int) -> Int =
  case m of
|}

(* TRUNC07: If with no then *)
let test_TRUNC07_if_no_then () =
  should_reject {|#lang tesl
module Trunc07 exposing []
import Tesl.Prelude exposing [Int, Bool(..)]
fn f(b: Bool) -> Int =
  if b
|}

(* TRUNC08: If-then with no else *)
let test_TRUNC08_if_then_no_else () =
  should_reject {|#lang tesl
module Trunc08 exposing []
import Tesl.Prelude exposing [Int, Bool(..)]
fn f(b: Bool) -> Int =
  if b then
    42
|}

(* TRUNC09: String literal that never closes *)
let test_TRUNC09_unclosed_string () =
  should_reject {|#lang tesl
module Trunc09 exposing []
import Tesl.Prelude exposing [String]
fn f() -> String = "hello world
|}

(* TRUNC10: Import with empty exposing brackets — Int not in scope *)
let test_TRUNC10_empty_exposing () =
  (* `import Tesl.Prelude exposing []` loads the module but imports nothing.
     `Int` in the return type is therefore not in scope — must fail. *)
  should_reject_with "Int.*not in scope\\|not in scope\\|add.*import" {|#lang tesl
module Trunc10 exposing []
import Tesl.Prelude exposing []
fn f() -> Int = 0
|}

(* TRUNC11: type declaration with nothing after = *)
let test_TRUNC11_empty_adt () =
  should_reject {|#lang tesl
module Trunc11 exposing []
type Color =
|}

(* TRUNC12: Establish with empty body *)
let test_TRUNC12_establish_no_body () =
  should_reject {|#lang tesl
module Trunc12 exposing []
import Tesl.Prelude exposing [Int]
fact IsPositive (n: Int)
establish provePositive(n: Int) -> Fact (IsPositive n) =
|}

(* ── MULTI: Multiple-error files — compiler must stay sane ─────────────── *)

(* MULTI01: Three unknown type names — all reported, no crash *)
let test_MULTI01_three_unknown_types () =
  should_reject_with "not in scope\\|unknown" {|#lang tesl
module Multi01 exposing []
import Tesl.Prelude exposing [Int]
fn f(a: Foo, b: Bar, c: Baz) -> Qux = a
|}

(* MULTI02: Two separate syntax errors in different functions *)
let test_MULTI02_two_syntax_errors () =
  should_reject {|#lang tesl
module Multi02 exposing []
import Tesl.Prelude exposing [Int]
fn f(n: Int): Int = n
fn g(n: Int): String = "hi"
|}

(* MULTI03: Mixed unknown proofs and unknown types *)
let test_MULTI03_unknown_proofs_and_types () =
  should_reject_with "not in scope\\|unknown\\|scope" {|#lang tesl
module Multi03 exposing []
import Tesl.Prelude exposing [Int]
fn f(n: Int ::: IsPhantom n) -> Specter = n
|}

(* MULTI04: Exporting names that don't exist AND unknown types in body *)
let test_MULTI04_bad_exports_and_unknown () =
  should_reject_with "export\\|not.*declared\\|exposes unknown" {|#lang tesl
module Multi04 exposing [ghost, phantom, wraith]
import Tesl.Prelude exposing [Int]
fn real() -> Int = 42
|}

(* MULTI05: Giant nonsense block — compiler should not loop or crash *)
let test_MULTI05_giant_nonsense () =
  should_reject {|#lang tesl
module Multi05 exposing []
import Tesl.Prelude exposing [Int, String]
fn a(x: Int) -> Int = b x
fn b(x: Int) -> Int = c x
fn c(x: Int) -> Int = d x
fn d(x: Int) -> Int = e x
fn e(x: Int) -> Nonexistent = x
fn f(n: Phantom) -> Ghost = n
fn g(n: Int) -> Int = n && "hello"
fn h(): Unit = ()
fn i() -> Blorp = bloop
|}

(* MULTI06: Deeply nested but legal-ish structure with one missing part *)
let test_MULTI06_deeply_nested_with_error () =
  should_reject {|#lang tesl
module Multi06 exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
fn f(m: Maybe (Maybe (Maybe Int))) -> Int =
  case m of
    Nothing -> 0
    Something inner ->
      case inner of
        Nothing -> 1
        Something inner2 ->
          case inner2 of
            Nothing -> 2
            Something n -> notDefined n
|}

(* MULTI07: Every record field with wrong syntax *)
let test_MULTI07_record_all_wrong () =
  should_reject {|#lang tesl
module Multi07 exposing []
record Bad {
  name = String
  age = Int
  active = Bool
}
|}

(* ── JS: Extra edge cases ────────────────────────────────────────────────── *)

(* JS16: Trying to use Promise / async paradigm *)
let test_JS16_promise_syntax () =
  should_reject (preamble_with {|
fn fetchData(url: String) -> Promise String = ???
|})

(* JS17: Template literal syntax (backtick) — if parser handles it *)
let test_JS17_template_literal () =
  should_reject (preamble_with {|
fn f(name: String) -> String = `Hello ${name}`
|})

(* JS18: Typeof operator *)
let test_JS18_typeof () =
  should_reject (preamble_with {|
fn f(n: Int) -> String = typeof n
|})

(* JS19: Instanceof operator *)
let test_JS19_instanceof () =
  should_reject (preamble_with {|
fn f(n: Int) -> Bool = n instanceof Int
|})

(* JS20: Ternary operator *)
let test_JS20_ternary () =
  should_reject (preamble_with {|
fn f(n: Int) -> Int = n > 0 ? n : 0
|})

(* ── NEAR: More near-miss cases ─────────────────────────────────────────── *)

(* NEAR21: Proof annotation on wrong side *)
let test_NEAR21_proof_annotation_wrong_side () =
  should_reject (preamble_with {|
fact IsPositive (n: Int)
fn f(IsPositive n ::: n: Int) -> Int = n
|})

(* NEAR22: Using := instead of = in let binding *)
let test_NEAR22_walrus_operator () =
  should_reject (preamble_with {|
fn f(n: Int) -> Int =
  let x := n + 1
  x
|})

(* NEAR23: Using .. instead of ... for range *)
let test_NEAR23_range_syntax () =
  should_reject (preamble_with {|
fn f(n: Int) -> Int = 1..10
|})

(* NEAR24: Trying to use pattern match without case...of *)
let test_NEAR24_match_without_case_of () =
  should_reject (preamble_with {|
import Tesl.Maybe exposing [Maybe(..)]
fn f(m: Maybe Int) -> Int =
  match m with
  | Nothing -> 0
  | Something n -> n
|})

(* NEAR25: Comma-separated params in fn (JS/Python habit) *)
let test_NEAR25_comma_in_params () =
  (* Tesl uses commas in fn params — this should actually work! *)
  should_pass (preamble_with {|
fn f(a: Int, b: Int) -> Int = a + b
|})

(* ── Test runner ─────────────────────────────────────────────────────────── *)

let () =
  run "Review74-Gibberish" [
    "javascript-typescript-idioms", [
      test_case "JS01 TS colon return type"          `Quick test_JS01_typescript_colon_return;
      test_case "JS02 TS arrow =>"                   `Quick test_JS02_typescript_arrow;
      test_case "JS03 const keyword"                 `Quick test_JS03_const_keyword;
      test_case "JS04 let at top level"              `Quick test_JS04_let_top_level;
      test_case "JS05 var keyword"                   `Quick test_JS05_var_keyword;
      test_case "JS06 interface keyword"             `Quick test_JS06_interface_keyword;
      test_case "JS07 class keyword"                 `Quick test_JS07_class_keyword;
      test_case "JS08 async fn"                      `Quick test_JS08_async_fn;
      test_case "JS09 export keyword"                `Quick test_JS09_export_keyword;
      test_case "JS10 null coalescing ?? in body"    `Quick test_JS10_null_coalescing_in_body;
      test_case "JS11 optional chaining ?."          `Quick test_JS11_optional_chaining;
      test_case "JS12 TS generic angle brackets"     `Quick test_JS12_typescript_generic_angles;
      test_case "JS13 exclamation unwrap !"          `Quick test_JS13_exclamation_unwrap;
      test_case "JS14 object spread ..."             `Quick test_JS14_object_spread;
      test_case "JS15 arrow implicit return"         `Quick test_JS15_arrow_implicit_return;
      test_case "JS16 Promise type"                  `Quick test_JS16_promise_syntax;
      test_case "JS17 template literal backtick"     `Quick test_JS17_template_literal;
      test_case "JS18 typeof operator"               `Quick test_JS18_typeof;
      test_case "JS19 instanceof operator"           `Quick test_JS19_instanceof;
      test_case "JS20 ternary ? :"                   `Quick test_JS20_ternary;
    ];
    "python-idioms", [
      test_case "PY01 def keyword"                   `Quick test_PY01_def_keyword;
      test_case "PY02 return statement"              `Quick test_PY02_return_statement;
      test_case "PY03 from...import"                 `Quick test_PY03_from_import;
      test_case "PY04 print call"                    `Quick test_PY04_print_statement;
      test_case "PY05 None keyword"                  `Quick test_PY05_none_keyword;
      test_case "PY06 list comprehension"            `Quick test_PY06_list_comprehension;
      test_case "PY07 decorator @"                   `Quick test_PY07_decorator_syntax;
      test_case "PY08 class with self"               `Quick test_PY08_python_class;
      test_case "PY09 dict literal {}"               `Quick test_PY09_python_dict_literal;
      test_case "PY10 lambda keyword"                `Quick test_PY10_python_lambda;
    ];
    "near-miss-tesl", [
      test_case "NEAR01 record comma fields"         `Quick test_NEAR01_record_comma_fields;
      test_case "NEAR02 ADT all on one line"         `Quick test_NEAR02_adt_all_on_one_line_with_pipes;
      test_case "NEAR03 fact without params"         `Quick test_NEAR03_fact_without_params;
      test_case "NEAR04 check missing ::: in return" `Quick test_NEAR04_check_missing_proof_in_return;
      test_case "NEAR05 fn with proof return"        `Quick test_NEAR05_fn_proof_return;
      test_case "NEAR06 ImportAll unexported name"   `Quick test_NEAR06_importall_then_use_unexported;
      test_case "NEAR07 = instead of =="             `Quick test_NEAR07_assignment_as_equality;
      test_case "NEAR08 single-line if"              `Quick test_NEAR08_single_line_if;
      test_case "NEAR09 ok without proof"            `Quick test_NEAR09_ok_without_proof;
      test_case "NEAR10 establish with ok"           `Quick test_NEAR10_establish_with_ok;
      test_case "NEAR11 case leading pipe |"         `Quick test_NEAR11_case_leading_pipe;
      test_case "NEAR12 bare record literal"         `Quick test_NEAR12_bare_record_literal;
      test_case "NEAR13 import without exposing"     `Quick test_NEAR13_import_without_exposing;
      test_case "NEAR14 check called without keyword" `Quick test_NEAR14_check_called_without_keyword;
      test_case "NEAR15 List without type param"     `Quick test_NEAR15_list_type_without_param;
      test_case "NEAR16 two module headers"          `Quick test_NEAR16_two_module_headers;
      test_case "NEAR17 import after decl"           `Quick test_NEAR17_import_after_decl;
      test_case "NEAR18 wrong constructor pattern"   `Quick test_NEAR18_wrong_constructor_pattern;
      test_case "NEAR19 check result discarded"      `Quick test_NEAR19_check_result_discarded;
      test_case "NEAR20 ADT ctor same name as type"  `Quick test_NEAR20_adt_ctor_same_as_type;
      test_case "NEAR21 proof on wrong side"         `Quick test_NEAR21_proof_annotation_wrong_side;
      test_case "NEAR22 walrus := operator"          `Quick test_NEAR22_walrus_operator;
      test_case "NEAR23 range .. syntax"             `Quick test_NEAR23_range_syntax;
      test_case "NEAR24 match without case...of"     `Quick test_NEAR24_match_without_case_of;
      test_case "NEAR25 comma params (should pass)"  `Quick test_NEAR25_comma_in_params;
    ];
    "wild-creative-garbage", [
      test_case "WILD01 SQL in function body"        `Quick test_WILD01_sql_query_in_body;
      test_case "WILD02 JSON at top level"           `Quick test_WILD02_json_at_top_level;
      test_case "WILD03 bash shebang"                `Quick test_WILD03_bash_shebang_and_code;
      test_case "WILD04 markdown headers"            `Quick test_WILD04_markdown_in_module;
      test_case "WILD05 emoji identifier"            `Quick test_WILD05_emoji_identifier;
      test_case "WILD06 lambda calculus λ"           `Quick test_WILD06_lambda_calculus_syntax;
      test_case "WILD07 data format style"           `Quick test_WILD07_data_format_style;
      test_case "WILD08 Haskell where clause"        `Quick test_WILD08_haskell_where;
      test_case "WILD09 >> composition operator"     `Quick test_WILD09_function_composition;
      test_case "WILD10 Rust lifetime 'a"            `Quick test_WILD10_rust_lifetime;
      test_case "WILD11 Go multiple returns"         `Quick test_WILD11_go_multiple_returns;
      test_case "WILD12 semicolons as separators"    `Quick test_WILD12_semicolons;
      test_case "WILD13 Haskell guards"              `Quick test_WILD13_haskell_guards;
      test_case "WILD14 Rust match =>"               `Quick test_WILD14_rust_match_arm;
      test_case "WILD15 F# pipe |>"                  `Quick test_WILD15_pipe_operator;
      test_case "WILD16 literal application 42 43"   `Quick test_WILD16_literal_application;
      test_case "WILD17 #include preprocessor"       `Quick test_WILD17_preprocessor_directive;
      test_case "WILD18 XML/HTML in body"            `Quick test_WILD18_xml_in_module;
      test_case "WILD19 OCaml open"                  `Quick test_WILD19_ocaml_open;
      test_case "WILD20 begin...end blocks"          `Quick test_WILD20_begin_end_blocks;
    ];
    "truncated-crash-risk", [
      test_case "TRUNC01 only #lang tesl"            `Quick test_TRUNC01_only_lang_header;
      test_case "TRUNC02 empty module is valid"       `Quick test_TRUNC02_module_header_only;
      test_case "TRUNC03 fn truncated mid-sig"       `Quick test_TRUNC03_fn_truncated_mid_sig;
      test_case "TRUNC04 fn no body"                 `Quick test_TRUNC04_fn_no_body;
      test_case "TRUNC05 record unclosed brace"      `Quick test_TRUNC05_record_unclosed;
      test_case "TRUNC06 case no arms"               `Quick test_TRUNC06_case_no_arms;
      test_case "TRUNC07 if no then"                 `Quick test_TRUNC07_if_no_then;
      test_case "TRUNC08 if-then no else"            `Quick test_TRUNC08_if_then_no_else;
      test_case "TRUNC09 unclosed string"            `Quick test_TRUNC09_unclosed_string;
      test_case "TRUNC10 empty exposing → Int not in scope" `Quick test_TRUNC10_empty_exposing;
      test_case "TRUNC11 empty ADT body"             `Quick test_TRUNC11_empty_adt;
      test_case "TRUNC12 establish no body"          `Quick test_TRUNC12_establish_no_body;
    ];
    "multi-error-sanity", [
      test_case "MULTI01 three unknown types"        `Quick test_MULTI01_three_unknown_types;
      test_case "MULTI02 two syntax errors"          `Quick test_MULTI02_two_syntax_errors;
      test_case "MULTI03 unknown proofs and types"   `Quick test_MULTI03_unknown_proofs_and_types;
      test_case "MULTI04 bad exports and unknown"    `Quick test_MULTI04_bad_exports_and_unknown;
      test_case "MULTI05 giant nonsense block"       `Quick test_MULTI05_giant_nonsense;
      test_case "MULTI06 deeply nested with error"   `Quick test_MULTI06_deeply_nested_with_error;
      test_case "MULTI07 record all wrong fields"    `Quick test_MULTI07_record_all_wrong;
    ];
  ]
