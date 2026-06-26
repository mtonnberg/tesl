(** Integration tests — compile real Tesl lesson files and compare output
    against the Python compiler's reference output.

    These tests are organized in tiers:
    1. EXACT: output must match Python byte-for-byte (modulo trailing newline)
    2. CLOSE: only cosmetic differences allowed (Unicode escaping, whitespace)
    3. PARSE_OK: file must parse without error (full match in later phases)
*)

open Parser
open Emit_racket

let repo_root_default () =
  let rec find dir =
    let candidate = Filename.concat dir "compiler" in
    if (try Sys.file_exists candidate && Sys.is_directory candidate with _ -> false)
    then dir
    else
      let parent = Filename.dirname dir in
      if parent = dir then Filename.current_dir_name
      else find parent
  in
  find (Filename.dirname Sys.executable_name)

let root =
  match Sys.getenv_opt "TESL_REPO_ROOT" with
  | Some p when p <> "" -> p
  | _ -> repo_root_default ()
let lessons = root ^ "/example/learn"

(* ── Helpers ─────────────────────────────────────────────────────────────── *)

let compile_file path =
  match Compile.compile_file ~root_path:root path with
  | Compile.Success racket -> Result.ok racket
  | Compile.Failure diags ->
    Result.error (String.concat "\n" (List.map (fun (d : Compile.diagnostic) -> d.source ^ ": " ^ d.message) diags))

let read_file path =
  try In_channel.with_open_text path In_channel.input_all
  with Sys_error _ -> ""

(* B5: the emitter now bakes the *input* .tesl path into each (thsl-src! "PATH" …)
   checkpoint.  Committed snapshots use a repo-relative path (stable across
   machines); these tests compile with an absolute path, so the baked string
   differs only in its directory prefix.  Canonicalise the thsl-src! file string
   to its basename on both sides before comparing — this keeps the exact-match
   asserting the full emission structure while tolerating the path prefix. *)
let canonicalize_thsl_paths s =
  let re = Str.regexp "(thsl-src! \"\\([^\"]*\\)\"" in
  Str.global_substitute re
    (fun whole ->
       let path = Str.matched_group 1 whole in
       Printf.sprintf "(thsl-src! \"%s\"" (Filename.basename path))
    s

let normalize s =
  let s = canonicalize_thsl_paths s in
  let rec trim_trailing_newlines i =
    if i >= 0 && (s.[i] = '\n' || s.[i] = '\r') then trim_trailing_newlines (i - 1)
    else i
  in
  let last = trim_trailing_newlines (String.length s - 1) in
  if last < 0 then "" else String.sub s 0 (last + 1)

let assert_compiles name path =
  match compile_file path with
  | Ok _ -> ()
  | Error msg -> Alcotest.failf "%s: compile error: %s" name msg

let first_diff_line left right =
  let rec loop line xs ys =
    match xs, ys with
    | [], [] -> None
    | x :: xs', y :: ys' when x = y -> loop (line + 1) xs' ys'
    | x :: _, y :: _ -> Some (line, x, y)
    | [], y :: _ -> Some (line, "<missing>", y)
    | x :: _, [] -> Some (line, x, "<missing>")
  in
  loop 1 (String.split_on_char '\n' left) (String.split_on_char '\n' right)

let assert_matches_python name tesl_path rkt_path =
  match compile_file tesl_path with
  | Error msg -> Alcotest.failf "%s: compile error: %s" name msg
  | Ok ocaml_out ->
    let py_out = read_file rkt_path in
    if py_out = "" then ()  (* skip if no reference file *)
    else begin
      let normalized_ocaml = normalize ocaml_out in
      let normalized_py = normalize py_out in
      if normalized_ocaml <> normalized_py then
        match first_diff_line normalized_ocaml normalized_py with
        | Some (line, ocaml_line, py_line) ->
          Alcotest.failf
            "%s: exact output mismatch at line %d\nOCaml:  %s\nRef:    %s"
            name line ocaml_line py_line
        | None ->
          Alcotest.failf "%s: exact output mismatch" name
    end

let test_all_lessons_exact_match () =
  Sys.readdir lessons
  |> Array.to_list
  |> List.filter (fun file -> Filename.check_suffix file ".tesl")
  |> List.sort String.compare
  |> List.iter (fun file ->
       let stem = Filename.chop_suffix file ".tesl" in
       let tesl = lessons ^ "/" ^ file in
       let rkt = lessons ^ "/" ^ stem ^ ".rkt" in
       assert_matches_python stem tesl rkt)

(* ── Exact match tests ───────────────────────────────────────────────────── *)

let test_lesson00 () =
  let tesl = lessons ^ "/lesson00-hello-world.tesl" in
  let rkt  = lessons ^ "/lesson00-hello-world.rkt" in
  if Sys.file_exists tesl then
    assert_matches_python "lesson00" tesl rkt

let test_lesson04 () =
  let tesl = lessons ^ "/lesson04-newtypes.tesl" in
  let rkt  = lessons ^ "/lesson04-newtypes.rkt" in
  if Sys.file_exists tesl then
    assert_matches_python "lesson04" tesl rkt

let test_lesson05 () =
  let tesl = lessons ^ "/lesson05-intro-to-proofs.tesl" in
  let rkt  = lessons ^ "/lesson05-intro-to-proofs.rkt" in
  if Sys.file_exists tesl then
    assert_matches_python "lesson05" tesl rkt

let test_lesson06 () =
  let tesl = lessons ^ "/lesson06-proof-check-proof-auth.tesl" in
  if Sys.file_exists tesl then assert_compiles "lesson06" tesl

let test_lesson07 () =
  let tesl = lessons ^ "/lesson07-consumer.tesl" in
  if Sys.file_exists tesl then assert_compiles "lesson07" tesl

let test_lesson08 () =
  let tesl = lessons ^ "/lesson08-proof-transport.tesl" in
  if Sys.file_exists tesl then assert_compiles "lesson08" tesl

let test_lesson09 () =
  let tesl = lessons ^ "/lesson09-proof-composition.tesl" in
  if Sys.file_exists tesl then assert_compiles "lesson09" tesl

let test_lesson10 () =
  let tesl = lessons ^ "/lesson10-cross-parameter-proofs.tesl" in
  if Sys.file_exists tesl then assert_compiles "lesson10" tesl

let test_lesson11 () =
  let tesl = lessons ^ "/lesson11-capabilities.tesl" in
  if Sys.file_exists tesl then assert_compiles "lesson11" tesl

let test_lesson12 () =
  let tesl = lessons ^ "/lesson12-records-with-proofs.tesl" in
  if Sys.file_exists tesl then assert_compiles "lesson12" tesl

let test_lesson13 () =
  let tesl = lessons ^ "/lesson13-partial-application-and-pipelines.tesl" in
  if Sys.file_exists tesl then assert_compiles "lesson13" tesl

let test_lesson14 () =
  let tesl = lessons ^ "/lesson14-test-blocks.tesl" in
  if Sys.file_exists tesl then assert_compiles "lesson14" tesl

let test_lesson15 () =
  let tesl = lessons ^ "/lesson15-api-handlers-server.tesl" in
  if Sys.file_exists tesl then assert_compiles "lesson15" tesl

let test_lesson16 () =
  let tesl = lessons ^ "/lesson16-complete-notes-api.tesl" in
  if Sys.file_exists tesl then assert_compiles "lesson16" tesl

let test_lesson17 () =
  let tesl = lessons ^ "/lesson17-telemetry.tesl" in
  if Sys.file_exists tesl then assert_compiles "lesson17" tesl

let test_lesson18 () =
  let tesl = lessons ^ "/lesson18-database-sql-and-proofs.tesl" in
  if Sys.file_exists tesl then assert_compiles "lesson18" tesl

let test_lesson19 () =
  let tesl = lessons ^ "/lesson19-existential-witnesses.tesl" in
  if Sys.file_exists tesl then assert_compiles "lesson19" tesl

let test_lesson20 () =
  let tesl = lessons ^ "/lesson20-named-db-results.tesl" in
  if Sys.file_exists tesl then assert_compiles "lesson20" tesl

let test_lesson21 () =
  let tesl = lessons ^ "/lesson21-sql-reference.tesl" in
  if Sys.file_exists tesl then assert_compiles "lesson21" tesl

let test_lesson22 () =
  let tesl = lessons ^ "/lesson22-compound-named-pack.tesl" in
  let rkt  = lessons ^ "/lesson22-compound-named-pack.rkt" in
  if Sys.file_exists tesl then
    assert_matches_python "lesson22" tesl rkt

let test_lesson25 () =
  let tesl = lessons ^ "/lesson25-standard-library-strings-lists-ints.tesl" in
  if Sys.file_exists tesl then assert_compiles "lesson25" tesl

let test_lesson26 () =
  let tesl = lessons ^ "/lesson26-time-and-posix.tesl" in
  let rkt  = lessons ^ "/lesson26-time-and-posix.rkt" in
  if Sys.file_exists tesl then
    assert_matches_python "lesson26" tesl rkt

let test_lesson27 () =
  let tesl = lessons ^ "/lesson27-either-dict-set.tesl" in
  let rkt  = lessons ^ "/lesson27-either-dict-set.rkt" in
  if Sys.file_exists tesl then
    assert_matches_python "lesson27" tesl rkt

let test_lesson28 () =
  let tesl = lessons ^ "/lesson28-dead-letter-queue.tesl" in
  let rkt  = lessons ^ "/lesson28-dead-letter-queue.rkt" in
  if Sys.file_exists tesl then
    assert_matches_python "lesson28" tesl rkt

let test_lesson29 () =
  let tesl = lessons ^ "/lesson29-forall-list-proofs.tesl" in
  let rkt  = lessons ^ "/lesson29-forall-list-proofs.rkt" in
  if Sys.file_exists tesl then
    assert_matches_python "lesson29" tesl rkt

let test_lesson30 () =
  let tesl = lessons ^ "/lesson30-forall-set-proofs.tesl" in
  let rkt  = lessons ^ "/lesson30-forall-set-proofs.rkt" in
  if Sys.file_exists tesl then
    assert_matches_python "lesson30" tesl rkt

let test_lesson31 () =
  let tesl = lessons ^ "/lesson31-worker-concurrency.tesl" in
  let rkt  = lessons ^ "/lesson31-worker-concurrency.rkt" in
  if Sys.file_exists tesl then
    assert_matches_python "lesson31" tesl rkt

let test_lesson32 () =
  let tesl = lessons ^ "/lesson32-api-tests.tesl" in
  let rkt  = lessons ^ "/lesson32-api-tests.rkt" in
  if Sys.file_exists tesl then
    assert_matches_python "lesson32" tesl rkt

let test_lesson33 () =
  let tesl = lessons ^ "/lesson33-sse-and-queue-tests.tesl" in
  let rkt  = lessons ^ "/lesson33-sse-and-queue-tests.rkt" in
  if Sys.file_exists tesl then
    assert_matches_python "lesson33" tesl rkt

let test_all_examples () =
  (* All example files must compile *)
  List.iter (fun fname ->
    let path = root ^ "/example/" ^ fname in
    if Sys.file_exists path then assert_compiles fname path
  ) ["admin-task-api.tesl"; "queue-api.tesl"; "sandbox.tesl";
     "sandbox2.tesl"; "sandbox2.test.tesl"; "sandbox3.tesl"; "todo-api.tesl"]

let test_cyclic_local_imports_inline_scc_modules () =
  let tesl = root ^ "/example/sandbox.tesl" in
  match compile_file tesl with
  | Error msg -> Alcotest.failf "sandbox cyclic import compile error: %s" msg
  | Ok racket ->
    if String.length racket = 0 then Alcotest.fail "sandbox output unexpectedly empty";
    let contains needle =
      let n = String.length needle in
      let m = String.length racket in
      let rec loop i =
        i + n <= m && ((String.sub racket i n = needle) || loop (i + 1))
      in
      if n = 0 then true else loop 0
    in
    if contains "dynamic-require" then
      Alcotest.failf "sandbox should inline cyclic SCC modules instead of using dynamic-require:\n%s" racket;
    if contains "(only-in tesl/example/sandbox2 " then
      Alcotest.failf "sandbox still eagerly requires sandbox2.rkt:\n%s" racket;
    if not (contains "Inlined from cyclic module Sandbox2") then
      Alcotest.failf "expected inline marker for Sandbox2 in sandbox output, got:\n%s" racket;
    if not (contains "Inlined from cyclic module Sandbox3") then
      Alcotest.failf "expected inline marker for Sandbox3 in sandbox output, got:\n%s" racket

(* ── Parse-OK tests (no exact match required yet) ───────────────────────── *)
(* ── Parse-OK tests (no exact match required yet) ───────────────────────── *)

let test_lesson02_parses () =
  let tesl = lessons ^ "/lesson02-adts-and-pattern-matching.tesl" in
  if Sys.file_exists tesl then assert_compiles "lesson02" tesl

let test_lesson03_records () =
  (* Record update syntax — should parse (even if output differs) *)
  let src = {|#lang tesl
module Records exposing []
import Tesl.Prelude exposing [Int]

record Point {
  x: Int
  y: Int
}
record Rectangle {
  origin: Point
  width: Int
  height: Int
}

fn scale(r: Rectangle, factor: Int) -> Rectangle =
  { r | width = r.width * factor, height = r.height * factor }
|} in
  match parse_module "<test>" src with
  | Ok m ->
    Alcotest.(check int) "one declaration" 1 (List.length (List.filter (function
      | Ast.DFunc _ -> true | _ -> false) m.decls))
  | Err e -> Alcotest.failf "parse error: %s" e.msg


(* ── Additional emit correctness tests ──────────────────────────────────── *)

let check_contains name src expected_fragment =
  match parse_module "<test>" src with
  | Err e -> Alcotest.failf "%s parse error: %s" name e.msg
  | Ok m ->
    let out = compile_to_string ~root_path:"ROOT" m in
    if not (let n = String.length expected_fragment in
            let m = String.length out in
            let found = ref false in
            for i = 0 to m - n do
              if String.sub out i n = expected_fragment then found := true
            done;
            !found) then
      Alcotest.failf "%s: expected to find %S in output:\n%s" name expected_fragment out

let test_case_scrut_uses_star () =
  (* Case scrutinees should use *var notation, not (raw-value var) *)
  let src = {|#lang tesl
module Foo exposing [f]
import Tesl.Prelude exposing [String]
type Color =
  | Red
  | Blue
fn f(c: Color) -> String =
  case c of
    Red -> "red"
    Blue -> "blue"
|} in
  check_contains "case_scrut" src "*c"

let test_proof_sym_no_double_parens () =
  (* Proof annotations should NOT have double parens: (ValidPort port) not ((ValidPort port)) *)
  let src = {|#lang tesl
module Foo exposing [isValid]
import Tesl.Prelude exposing [Int]
check isValid(x: Int) -> x: Int ::: Valid x =
  ok x ::: Valid x
|} in
  check_contains "no_double_parens" src "(Valid x)";
  let out = match parse_module "<test>" src with
    | Ok m -> compile_to_string ~root_path:"ROOT" m
    | Err e -> Alcotest.failf "parse error: %s" e.msg
  in
  (* Should NOT have double parens *)
  if let needle = "((Valid x))" in
     let n = String.length needle in
     let m = String.length out in
     let found = ref false in
     for i = 0 to m - n do
       if String.sub out i n = needle then found := true
     done; !found then
    Alcotest.failf "found double parens ((Valid x)) in output:\n%s" out

let test_constructor_arg_no_raw_value () =
  (* Constructors as function args should NOT be wrapped in raw-value *)
  let src = {|#lang tesl
module Foo exposing [area]
import Tesl.Prelude exposing [Int]
type Shape =
  | Circle radius:Int
  | Point
fn area(s: Shape) -> Int =
  case s of
    Circle radius -> radius * radius
    Point -> 0
test "area" {
  expect area (Circle 5) == 25
}
|} in
  let out = match parse_module "<test>" src with
    | Ok m -> compile_to_string ~root_path:"ROOT" m
    | Err e -> Alcotest.failf "parse error: %s" e.msg
  in
  (* In test, arg (Circle 5) should NOT be (raw-value (Circle 5)) *)
  let bad = "(area (raw-value (Circle 5)))" in
  let good = "(area (Circle 5))" in
  let has_bad = let n = String.length bad in let m = String.length out in
    let found = ref false in
    for i = 0 to m - n do
      if String.sub out i n = bad then found := true
    done; !found in
  let has_good = let n = String.length good in let m = String.length out in
    let found = ref false in
    for i = 0 to m - n do
      if String.sub out i n = good then found := true
    done; !found in
  if has_bad then Alcotest.failf "found unwanted raw-value wrapping: %s in:\n%s" bad out;
  Alcotest.(check bool) "correct (area (Circle 5)) form" true has_good

let test_dot_field_access () =
  (* obj.field uses tesl-dot/runtime in plain fn bodies *)
  let src = {|#lang tesl
module Foo exposing [getTitle]
import Tesl.Prelude exposing [String]
record Task {
  title: String
}
fn getTitle(t: Task) -> String =
  t.title
|} in
  check_contains "tesl-dot/runtime used for field access in fn" src "tesl-dot/runtime"

let test_negative_int_literal () =
  (* -3 should parse as a negative integer literal in arg position *)
  let src = {|#lang tesl
module Foo exposing [add]
import Tesl.Prelude exposing [Int]
fn add(x: Int, y: Int) -> Int = x + y
test "neg" {
  expect add 10 -3 == 7
}
|} in
  check_contains "negative_int" src "(add 10 -3)"

let test_interp_string_format () =
  (* Interpolated strings should use format with ~a *)
  let src = {|#lang tesl
module Foo exposing [greet]
import Tesl.Prelude exposing [String]
fn greet(name: String) -> String =
  "Hello, ${name}!"
|} in
  check_contains "interp_format" src "(format \"Hello, ~a!\"";
  check_contains "interp_tesl_display_val" src "(tesl-display-val *name)"

let test_multi_arg_application () =
  (* Multi-arg function application should be flattened in Racket *)
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
fn f(x: Int, y: Int, z: Int) -> Int = x
test "app" {
  expect f 1 2 3 == 1
}
|} in
  check_contains "multi_arg" src "(f 1 2 3)"

let test_adt_define_adt () =
  (* ADT types should use define-adt *)
  let src = {|#lang tesl
module Foo exposing [Color(..)]
type Color =
  | Red
  | Green
  | Blue
|} in
  check_contains "define_adt" src "(define-adt Color";
  check_contains "red_variant" src "[Red]"

let test_newtype_inline () =
  (* Newtypes should use inline format: (define-newtype Name BaseType) *)
  let src = {|#lang tesl
module Foo exposing [UserId]
type UserId = String
|} in
  check_contains "newtype_inline" src "(define-newtype UserId String)"

let test_record_define () =
  (* Records should use define-record *)
  let src = {|#lang tesl
module Foo exposing [Task]
record Task {
  id: String
  title: String
}
|} in
  check_contains "define_record" src "(define-record Task";
  check_contains "id_field" src "[id : String]"

let test_checker_accept_raw () =
  (* check functions should use accept with *name (raw value) *)
  let src = {|#lang tesl
module Foo exposing [isPos]
import Tesl.Prelude exposing [Int]
check isPos(n: Int) -> n: Int ::: Positive n =
  if n > 0 then
    ok n ::: Positive n
  else
    fail 400 "must be positive"
|} in
  check_contains "accept_raw" src "(accept (Positive n) #:value *n)"

let test_reject_http_code () =
  (* fail N "msg" should emit reject with http-code *)
  let src = {|#lang tesl
module Foo exposing [f]
import Tesl.Prelude exposing [Int]
fn f(x: Int) -> Int =
  fail 404 "not found"
|} in
  check_contains "reject" src "(reject \"not found\" #:http-code 404)"

let test_provide_includes_signatures () =
  (* provide should include name-signature for each function *)
  let src = {|#lang tesl
module Foo exposing [add]
import Tesl.Prelude exposing [Int]
fn add(x: Int, y: Int) -> Int = x + y
|} in
  check_contains "sig_in_provide" src "add-signature"

let test_bool_literals () =
  (* true/false → #t/#f in Racket *)
  let src = {|#lang tesl
module Foo exposing [isTrue]
import Tesl.Prelude exposing [Bool]
fn isTrue(b: Bool) -> Bool =
  if b then
    true
  else
    false
|} in
  check_contains "true_literal" src "#t";
  check_contains "false_literal" src "#f"

let test_qualified_stdlib_imports () =
  (* Qualified imports like Dict.lookup should be renamed *)
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Dict exposing [Dict.lookup]
|} in
  check_contains "dict_renamed" src "tesl_import_Dict_lookup"

let test_maybe_constructors_in_import () =
  (* Maybe(..) should expand to Maybe Something Nothing *)
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Maybe exposing [Maybe(..)]
|} in
  check_contains "nothing_in_import" src "Nothing";
  check_contains "something_in_import" src "Something"

let test_capability_implies () =
  (* capability X implies Y should emit define-capability with implies *)
  let src = {|#lang tesl
module Foo exposing []
capability myRead implies dbRead
|} in
  check_contains "capability_implies" src "(define-capability myRead (implies dbRead"

let test_handler_capabilities () =
  (* handler with requires should emit #:capabilities *)
  let src = {|#lang tesl
module Foo exposing [create]
import Tesl.Prelude exposing [String]
handler create(x: String) -> String
  requires [dbWrite] =
  x
|} in
  check_contains "capabilities" src "#:capabilities [dbWrite]"

let test_let_binding_in_test () =
  (* let bindings in tests should emit as (define ...).  B5: the value is now
     wrapped in a (thsl-src! … (lambda () 42)) checkpoint that erases in release;
     assert the binding shape and the inner value rather than the exact text. *)
  let src = {|#lang tesl
module Foo exposing []
test "demo" {
  let x = 42
  expect x == 42
}
|} in
  check_contains "define_x" src "(define x (thsl-src!";
  check_contains "define_x_value" src "(lambda () 42))"

let test_expect_fail_test () =
  (* expectFail should emit with-handlers pattern *)
  let src = {|#lang tesl
module Foo exposing []
test "fail" {
  expectFail isValidPort 0
}
|} in
  check_contains "with_handlers" src "with-handlers";
  check_contains "tesl_exception" src "'tesl-exception"

let test_expect_has_proof () =
  (* expectHasProof should emit facts-of pattern *)
  let src = {|#lang tesl
module Foo exposing []
test "proof" {
  expectHasProof isValidPort 80 ValidPort
}
|} in
  check_contains "facts_of" src "facts-of";
  check_contains "proof_name" src "'ValidPort"

let test_no_t_any_ever () =
  (* The compiler should NEVER emit __Any__ *)
  let src = {|#lang tesl
module Foo exposing [f]
import Tesl.Prelude exposing [Int]
fn f(x: Int) -> Int = x
|} in
  let out = match parse_module "<test>" src with
    | Ok m -> compile_to_string ~root_path:"ROOT" m
    | Err e -> Alcotest.failf "parse error: %s" e.msg
  in
  if String.length out > 0 then begin
    let needle = "__Any__" in
    let n = String.length needle in let m = String.length out in
    let found = ref false in
    for i = 0 to m - n do
      if String.sub out i n = needle then found := true
    done;
    if !found then Alcotest.failf "found __Any__ in output!"
  end

(* ── Adversarial integration tests ──────────────────────────────────────── *)

let test_empty_module_compiles () =
  let src = {|#lang tesl
module Empty exposing []
|} in
  check_contains "provides empty" src "(provide "

let test_deeply_nested_case () =
  let src = {|#lang tesl
module Foo exposing [f]
import Tesl.Prelude exposing [Int]
type AB =
  | A
  | B
type CD =
  | C
  | D
fn f(ab: AB, cd: CD) -> Int =
  case ab of
    A ->
      case cd of
        C -> 1
        D -> 2
    B ->
      case cd of
        C -> 3
        D -> 4
|} in
  check_contains "nested_case" src "(cond"

let test_boolean_and_expr () =
  let src = {|#lang tesl
module Foo exposing [check]
import Tesl.Prelude exposing [Bool, Int]
fn validate(x: Int, y: Int) -> Bool =
  x > 0 && y > 0
|} in
  check_contains "and_expr" src "(and"

let test_multiple_proof_conjunction () =
  let src = {|#lang tesl
module Foo exposing [both]
import Tesl.Prelude exposing [Int]
fn both(x: Int ::: PA x && PB x) -> Int = x
|} in
  check_contains "conjunctive_param" src "PA x"

let test_forall_return_spec () =
  let src = {|#lang tesl
module Foo exposing [filter]
import Tesl.Prelude exposing [Int, List]
fn filter(xs: List Int) -> List Int ::: ForAll Positive =
  xs
|} in
  match parse_module "<test>" src with
  | Err e -> Alcotest.failf "forall_return parse error: %s" e.msg
  | Ok m ->
    let out = compile_to_string ~root_path:"ROOT" m in
    let has needle =
      let n = String.length needle in
      let m = String.length out in
      let found = ref false in
      for i = 0 to m - n do
        if String.sub out i n = needle then found := true
      done;
      !found
    in
    if not (has "#:returns (List Integer)") then
      Alcotest.failf "forall_return: expected plain list return in output:\n%s" out;
    if has "#:returns (List (List Integer))" then
      Alcotest.failf "forall_return: ForAll ::: regression still emits nested list return:\n%s" out

let test_record_with_proof_fields () =
  let src = {|#lang tesl
module Foo exposing [NewNote]
import Tesl.Prelude exposing [String]
record NewNote {
  title: String ::: SafeTitle title
  content: String ::: SafeContent content
}
|} in
  check_contains "proof_field" src "define-record NewNote"

let test_entity_table () =
  let src = {|#lang tesl
module Foo exposing [Todo]
import Tesl.Prelude exposing [String, Bool]
entity Todo table "todos" primaryKey id {
  id: String
  title: String
  done: Bool
}
|} in
  check_contains "entity" src "define-entity Todo"

let test_codec_with_via () =
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Json exposing [stringCodec]
import Tesl.Prelude exposing [String]
record NewNote { title: String }
codec NewNote {
  toJson_forbidden
  fromJson [
    {
      title <- "title" with_codec stringCodec via checkTitle
    }
  ]
}
|} in
  check_contains "via_check" src "checkTitle"

let test_property_custom_generator_emit () =
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
fn genSmallPositive(seed: Int) -> Int =
  1 + seed % 100

test "property: via custom generator" with 20 runs {
  property "custom gen" (n: Int via genSmallPositive) { n > 0 && n <= 100 }
}
|} in
  check_contains "property custom generator binding" src "[n (genSmallPositive tesl-prop-i)]";
  check_contains "property custom generator body" src "(check-true (and (> (raw-value n) 0) (<= (raw-value n) 100)) \"custom gen\")"

let test_modulo_emits_remainder () =
  let src = {|#lang tesl
module Foo exposing [mod100]
fn mod100(n: Int) -> Int =
  n % 100
|} in
  check_contains "modulo emits remainder" src "(remainder *n 100)"

let test_property_stdlib_call_uses_raw_value () =
  let src = {|#lang tesl
module Foo exposing []
import Tesl.String exposing [String.length]
import Tesl.Prelude exposing [String]

test "property: string length is non-negative" with 30 runs {
  property "length >= 0" (s: String) { String.length(s) >= 0 }
}
|} in
  check_contains "property stdlib raw value" src "(tesl_import_String_length (raw-value s))"

let test_expect_comparisons_emit_boolean_checks () =
  let src = {|#lang tesl
module Foo exposing []
test "comparisons" {
  expect 5 > 3
  expect 5 != 3
}
|} in
  (* B5: the compared expression is wrapped in a (thsl-src! … (lambda () …))
     checkpoint (erased in release).  Assert the boolean check shape and the
     inner comparison rather than the pre-B5 unwrapped text. *)
  check_contains "expect greater-than" src "(check-true (thsl-src!";
  check_contains "expect greater-than inner" src "(lambda () (> 5 3))";
  check_contains "expect not-equal" src "(check-not-equal? (thsl-src!";
  check_contains "expect not-equal inner" src "(lambda () 5)) 3)"

let test_property_record_generator_uses_constructor () =
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
record AnIntRecord {
  someProp: Int
}

test "property: record" with 20 runs {
  property "field available" (n: AnIntRecord) { n.someProp >= -1000000 }
}
|} in
  check_contains "property record generator" src "[n (AnIntRecord #:someProp (- (random 2000001) 1000000))]"

let test_stdlib_check_binding_uses_let_check () =
  let src = {|#lang tesl
module Foo exposing [f]
import Tesl.Int exposing [Int.nonNegative]
import Tesl.Prelude exposing [Int]
fn f() -> Int =
  let count = check Int.nonNegative 2
  count
|} in
  check_contains "stdlib let/check" src "(let/check ([tesl_checked_0";
  check_contains "stdlib let/check target" src "tesl_import_Int_nonNegative 2"

let test_stdlib_empty_list_is_not_zero_arg () =
  let src = {|#lang tesl
module Foo exposing [f]
import Tesl.List exposing [List.length]
import Tesl.Prelude exposing [Int]
fn f() -> Int =
  List.length []
|} in
  check_contains "stdlib empty list arg" src "(tesl_import_List_length (list))"

let test_proof_local_passes_named_value_to_stdlib () =
  let src = {|#lang tesl
module Foo exposing [f]
import Tesl.Int exposing [Int.nonZero, Int.divide]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Prelude exposing [Int]
fn f(numerator: Int, rawDenom: Int) -> Maybe Int =
  let denom = check Int.nonZero rawDenom
  Something (Int.divide numerator denom)
|} in
  check_contains "proof local named stdlib arg" src "(tesl_import_Int_divide *numerator denom)"

let test_sql_select_lowering () =
  let src = {|#lang tesl
module Foo exposing [findById, findFeatured, ordered]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Prelude exposing [Int, String]
entity Product table "products" primaryKey id {
  id: String
  category: String
  price: Int
}
fn findById(id: String) -> Maybe Product =
  selectOne p from Product where p.id == id
fn findFeatured(cat1: String, cat2: String) -> List Product =
  select p from Product where p.category == cat1 || p.category == cat2
fn ordered() -> List Product =
  select p from Product order p.price asc limit 5
|} in
  check_contains "sql selectOne lowering" src "(let ([tesl_match (select-one (from Product) (where (==. (entity-field-ref Product 'id) id)))]) (if tesl_match (Something tesl_match) Nothing))";
  check_contains "sql select or lowering" src "(select-many (from Product) (where (or. (==. (entity-field-ref Product 'category) cat1) (==. (entity-field-ref Product 'category) cat2))))";
  check_contains "sql select order limit lowering" src "(select-many (from Product) (order-by (entity-field-ref Product 'price) 'asc) (limit 5))"

let test_sql_insert_lowering () =
  let src = {|#lang tesl
module Foo exposing [createProduct]
import Tesl.Prelude exposing [Bool, Int, String]
entity Product table "products" primaryKey id {
  id: String
  category: String
  inStock: Bool
  price: Int
}
fn createProduct(id: String, category: String, price: Int) -> Product =
  insert Product { id: id, category: category, inStock: true, price: price }
|} in
  check_contains "sql insert lowering" src "(insert-one! Product (hash 'id id 'category category 'inStock #t 'price price))"

let test_sql_update_lowering () =
  let src = {|#lang tesl
module Foo exposing [setPrice]
import Tesl.Prelude exposing [Int, String]
entity Product table "products" primaryKey id {
  id: String
  price: Int
}
fn setPrice(id: String, newPrice: Int) -> Product ? FromDb (Id == id)
  requires [dbRead, dbWrite] =
  update p in Product
    where p.id == id
    set p.price = newPrice
    returning one
|} in
  check_contains "sql update lowering" src "(car (update-many! (from Product) (hash (entity-field-ref Product 'price) newPrice) (where (==. (entity-field-ref Product 'id) id))))"

let test_sql_delete_lowering () =
  let src = {|#lang tesl
module Foo exposing [removeProduct]
import Tesl.Prelude exposing [Int, String]
entity Product table "products" primaryKey id {
  id: String
}
fn removeProduct(id: String) -> Int =
  delete p from Product where p.id == id
|} in
  check_contains "sql delete lowering" src "(delete-many! (from Product) (where (==. (entity-field-ref Product 'id) id)))"

let test_api_exists_return_spec_lowering () =
  let src = {|#lang tesl
module Foo exposing [MyApi]
import Tesl.Prelude exposing [String]
entity Event table "events" primaryKey id {
  id: String
}
api MyApi {
  post "/events"
    body req: String
    -> exists eventId: String => Event ? FromDb (Id == eventId)
}
|} in
  check_contains "api exists return spec lowering" src ":> (Post JSON (Exists [eventId : String] (? Event _entity ::: (FromDb (Id == eventId) _entity))))"

let test_case_bound_value_raw_in_return () =
  let src = {|#lang tesl
module Foo exposing [unwrap]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Prelude exposing [Int]
fn unwrap(m: Maybe Int) -> Int =
  case m of
    Something value -> value
    Nothing -> 0
|} in
  check_contains "case bound value raw return" src "(let ([value (hash-ref (adt-value-fields *tesl_case_0) 'value)]) *value)"

let test_constructor_payload_unwraps_named_values () =
  let src = {|#lang tesl
module Foo exposing [wrapAge]
import Tesl.Either exposing [Either(..)]
import Tesl.Prelude exposing [Int, String]
fn wrapAge(age: Int) -> Either String Int =
  Right age
|} in
  check_contains "constructor payload unwraps named values" src "(raw-value (Right *age))"

let test_test_let_check_lowering () =
  let src = {|#lang tesl
module Foo exposing []
import Tesl.Dict exposing [Dict, Dict.fromList, Dict.requireKey, Dict.get]
import Tesl.Prelude exposing [Int, String]
test "dict proof local" {
  let d = Dict.fromList [["a", 1]]
  let key = "a"
  let checked = check Dict.requireKey key d
  expect Dict.get key checked == 1
}
|} in
  check_contains "test let/check temp binding" src "(define tesl_checked_0 (tesl_import_Dict_requireKey key d))";
  check_contains "test let/check direct binding" src "(define checked tesl_checked_0)";
  check_contains "test let/check proof local use" src "(tesl_import_Dict_get (raw-value key) checked)"

let test_stdlib_call_raw_unwraps_user_function_result () =
  let src = {|#lang tesl
module Foo exposing [parseAdultAge]
import Tesl.Either exposing [Either(..), Either.andThen]
import Tesl.Prelude exposing [Int, String]
fn parseAge(raw: String) -> Either String Int =
  Right 25
fn validateAdult(age: Int) -> Either String Int =
  Right age
fn parseAdultAge(raw: String) -> Either String Int =
  Either.andThen validateAdult (parseAge raw)
|} in
  check_contains "stdlib call raw unwraps user function result" src "(tesl_import_Either_andThen validateAdult (raw-value (parseAge raw)))"

let test_server_sse_routes () =
  (* SSE routes are defined per API, not per server *)
  let src = {|#lang tesl
module Foo exposing [MyServer]
api MyApi {
  get "/items"
    -> String
}
server MyServer for MyApi {
  endpoint_1 = handler1Impl
}
|} in
  check_contains "sse_routes" src "sse-routes"

(* ── Star-removal / implicit-unwrapping tests ──────────────────────────── *)

(** params used in arithmetic should emit *name in Racket *)
let test_implicit_unwrap_arithmetic () =
  let src = {|#lang tesl
module Foo exposing [add]
import Tesl.Prelude exposing [Int]
fn add(x: Int, y: Int) -> Int =
  x + y
|} in
  check_contains "add emits *x *y" src "(+ *x *y)"

(** params used in comparison should emit *name in Racket *)
let test_implicit_unwrap_comparison () =
  let src = {|#lang tesl
module Foo exposing [isPositive]
import Tesl.Prelude exposing [Int, Bool]
fn isPositive(n: Int) -> Bool =
  n > 0
|} in
  check_contains "isPositive emits *n" src "(> *n 0)"

(** bool param used in if condition should emit *flag in Racket *)
let test_implicit_unwrap_if_condition () =
  let src = {|#lang tesl
module Foo exposing [choose]
import Tesl.Prelude exposing [Int, Bool]
fn choose(flag: Bool, a: Int, b: Int) -> Int =
  if flag then
    a
  else
    b
|} in
  check_contains "choose emits *flag" src "(if *flag *a *b)"

(** negation of param should emit (- *n) *)
let test_implicit_unwrap_unary_neg () =
  let src = {|#lang tesl
module Foo exposing [neg]
import Tesl.Prelude exposing [Int]
fn neg(n: Int) -> Int =
  -n
|} in
  check_contains "neg emits (- *n)" src "(- *n)"

(** param in string interpolation should emit (tesl-display-val *name) *)
let test_implicit_unwrap_string_interp () =
  let src = {|#lang tesl
module Foo exposing [greet]
import Tesl.Prelude exposing [String]
fn greet(name: String) -> String =
  "Hello, ${name}!"
|} in
  check_contains "greet emits tesl-display-val *name" src "(tesl-display-val *name)"

(* star (asterisk) in source is a parse error *)
let test_star_is_parse_error () =
  let src = {|#lang tesl
module Foo exposing [f]
import Tesl.Prelude exposing [Int]
fn f(x: Int) -> Int =
  *x
|} in
  (match parse_module "<test>" src with
   | Err _ -> ()
   | Ok _ -> Alcotest.fail "expected parse error for *x in function body")

(** param passed to constructor should emit *name *)
let test_implicit_unwrap_constructor_arg () =
  let src = {|#lang tesl
module Foo exposing [wrapJust]
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
fn wrapJust(n: Int) -> Maybe Int =
  Just n
|} in
  check_contains "Just *n" src "(Just *n)"

(** param returned from fn (named-pack) should use raw tail *)
let test_implicit_unwrap_fn_return_param () =
  let src = {|#lang tesl
module Foo exposing [identity]
import Tesl.Prelude exposing [Int]
fn identity(x: Int) -> Int =
  x
|} in
  check_contains "identity emits *x" src "*x"

(** params used in modulo should emit *name *)
let test_implicit_unwrap_modulo () =
  let src = {|#lang tesl
module Foo exposing [remainder]
import Tesl.Prelude exposing [Int]
fn remainder(a: Int, b: Int) -> Int =
  a % b
|} in
  check_contains "remainder emits *a *b" src "(remainder *a *b)"

(** case-bound variable should auto-unwrap in return *)
let test_implicit_unwrap_case_branch () =
  let src = {|#lang tesl
module Foo exposing [extract]
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
fn extract(m: Maybe Int, def: Int) -> Int =
  case m of
    Just n -> n
    Nothing -> def
|} in
  check_contains "extract Just branch emits *n" src "*n"

(* ── Suite ───────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Integration" [
    "exact-match", [
      Alcotest.test_case "lesson00 hello-world" `Quick test_lesson00;
      Alcotest.test_case "lesson04 newtypes" `Quick test_lesson04;
      Alcotest.test_case "lesson05 proofs" `Quick test_lesson05;
      Alcotest.test_case "lesson22 compound named-pack" `Quick test_lesson22;
      Alcotest.test_case "lesson26 time and posix" `Quick test_lesson26;
      Alcotest.test_case "lesson27 either dict set" `Quick test_lesson27;
      Alcotest.test_case "lesson28 dead-letter queue" `Quick test_lesson28;
      Alcotest.test_case "lesson29 forall list proofs" `Quick test_lesson29;
      Alcotest.test_case "lesson30 forall set proofs" `Quick test_lesson30;
      Alcotest.test_case "lesson31 worker concurrency" `Quick test_lesson31;
      Alcotest.test_case "lesson32 api tests" `Quick test_lesson32;
      Alcotest.test_case "lesson33 sse and queue tests" `Quick test_lesson33;
      Alcotest.test_case "all checked-in lessons exact-match" `Quick test_all_lessons_exact_match;
    ];
    "compile-lessons", [
      Alcotest.test_case "lesson02 ADTs" `Quick test_lesson02_parses;
      Alcotest.test_case "lesson03 record update" `Quick test_lesson03_records;
      Alcotest.test_case "lesson06" `Quick test_lesson06;
      Alcotest.test_case "lesson07" `Quick test_lesson07;
      Alcotest.test_case "lesson08 proof transport" `Quick test_lesson08;
      Alcotest.test_case "lesson09 proof composition" `Quick test_lesson09;
      Alcotest.test_case "lesson10 cross-param proofs" `Quick test_lesson10;
      Alcotest.test_case "lesson11 capabilities" `Quick test_lesson11;
      Alcotest.test_case "lesson12 records with proofs" `Quick test_lesson12;
      Alcotest.test_case "lesson13 pipelines" `Quick test_lesson13;
      Alcotest.test_case "lesson14 test blocks" `Quick test_lesson14;
      Alcotest.test_case "lesson15 api handlers" `Quick test_lesson15;
      Alcotest.test_case "lesson16 notes api" `Quick test_lesson16;
      Alcotest.test_case "lesson17 telemetry" `Quick test_lesson17;
      Alcotest.test_case "lesson18 database sql" `Quick test_lesson18;
      Alcotest.test_case "lesson19 existential" `Quick test_lesson19;
      Alcotest.test_case "lesson20 named db" `Quick test_lesson20;
      Alcotest.test_case "lesson21 sql reference" `Quick test_lesson21;
      Alcotest.test_case "lesson25 stdlib strings lists ints" `Quick test_lesson25;
      Alcotest.test_case "all examples" `Quick test_all_examples;
      Alcotest.test_case "cyclic local imports inline SCC modules" `Quick test_cyclic_local_imports_inline_scc_modules;
    ];
    "emit-correctness", [
      Alcotest.test_case "case scrut uses *var" `Quick test_case_scrut_uses_star;
      Alcotest.test_case "no double parens on proofs" `Quick test_proof_sym_no_double_parens;
      Alcotest.test_case "constructor arg no raw-value" `Quick test_constructor_arg_no_raw_value;
      Alcotest.test_case "dot field access notation" `Quick test_dot_field_access;
      Alcotest.test_case "negative int literal" `Quick test_negative_int_literal;
      Alcotest.test_case "interpolated string format" `Quick test_interp_string_format;
      Alcotest.test_case "multi-arg application flat" `Quick test_multi_arg_application;
      Alcotest.test_case "ADT define-adt" `Quick test_adt_define_adt;
      Alcotest.test_case "newtype inline format" `Quick test_newtype_inline;
      Alcotest.test_case "record define-record" `Quick test_record_define;
      Alcotest.test_case "checker accept raw value" `Quick test_checker_accept_raw;
      Alcotest.test_case "reject http-code" `Quick test_reject_http_code;
      Alcotest.test_case "provide includes signatures" `Quick test_provide_includes_signatures;
      Alcotest.test_case "bool literals" `Quick test_bool_literals;
      Alcotest.test_case "qualified stdlib imports renamed" `Quick test_qualified_stdlib_imports;
      Alcotest.test_case "Maybe(..) expands constructors" `Quick test_maybe_constructors_in_import;
      Alcotest.test_case "capability with implies" `Quick test_capability_implies;
      Alcotest.test_case "handler capabilities" `Quick test_handler_capabilities;
      Alcotest.test_case "let in test" `Quick test_let_binding_in_test;
      Alcotest.test_case "expectFail emission" `Quick test_expect_fail_test;
      Alcotest.test_case "expectHasProof emission" `Quick test_expect_has_proof;
      Alcotest.test_case "no T_ANY ever emitted" `Quick test_no_t_any_ever;
      Alcotest.test_case "empty module" `Quick test_empty_module_compiles;
    ];
    "adversarial", [
      Alcotest.test_case "deeply nested case" `Quick test_deeply_nested_case;
      Alcotest.test_case "boolean && expr" `Quick test_boolean_and_expr;
      Alcotest.test_case "multiple proof conjunction" `Quick test_multiple_proof_conjunction;
      Alcotest.test_case "ForAll return spec" `Quick test_forall_return_spec;
      Alcotest.test_case "record with proof fields" `Quick test_record_with_proof_fields;
      Alcotest.test_case "entity table" `Quick test_entity_table;
      Alcotest.test_case "codec with via" `Quick test_codec_with_via;
      Alcotest.test_case "property custom generator" `Quick test_property_custom_generator_emit;
      Alcotest.test_case "modulo emits remainder" `Quick test_modulo_emits_remainder;
      Alcotest.test_case "property stdlib raw value" `Quick test_property_stdlib_call_uses_raw_value;
      Alcotest.test_case "expect comparisons" `Quick test_expect_comparisons_emit_boolean_checks;
      Alcotest.test_case "property record generator" `Quick test_property_record_generator_uses_constructor;
      Alcotest.test_case "stdlib let/check" `Quick test_stdlib_check_binding_uses_let_check;
      Alcotest.test_case "stdlib empty list arg" `Quick test_stdlib_empty_list_is_not_zero_arg;
      Alcotest.test_case "proof local stdlib arg" `Quick test_proof_local_passes_named_value_to_stdlib;
      Alcotest.test_case "sql select lowering" `Quick test_sql_select_lowering;
      Alcotest.test_case "sql insert lowering" `Quick test_sql_insert_lowering;
      Alcotest.test_case "sql update lowering" `Quick test_sql_update_lowering;
      Alcotest.test_case "sql delete lowering" `Quick test_sql_delete_lowering;
      Alcotest.test_case "api exists return spec lowering" `Quick test_api_exists_return_spec_lowering;
      Alcotest.test_case "case bound value raw return" `Quick test_case_bound_value_raw_in_return;
      Alcotest.test_case "constructor payload unwraps named values" `Quick test_constructor_payload_unwraps_named_values;
      Alcotest.test_case "test let/check lowering" `Quick test_test_let_check_lowering;
      Alcotest.test_case "stdlib call raw unwraps user function result" `Quick test_stdlib_call_raw_unwraps_user_function_result;
      Alcotest.test_case "server SSE routes" `Quick test_server_sse_routes;
      Alcotest.test_case "implicit unwrap arithmetic" `Quick test_implicit_unwrap_arithmetic;
      Alcotest.test_case "implicit unwrap comparison" `Quick test_implicit_unwrap_comparison;
      Alcotest.test_case "implicit unwrap if condition" `Quick test_implicit_unwrap_if_condition;
      Alcotest.test_case "implicit unwrap unary neg" `Quick test_implicit_unwrap_unary_neg;
      Alcotest.test_case "implicit unwrap string interpolation" `Quick test_implicit_unwrap_string_interp;
      Alcotest.test_case "star is parse error" `Quick test_star_is_parse_error;
      Alcotest.test_case "implicit unwrap constructor arg" `Quick test_implicit_unwrap_constructor_arg;
      Alcotest.test_case "implicit unwrap fn return param" `Quick test_implicit_unwrap_fn_return_param;
      Alcotest.test_case "implicit unwrap modulo" `Quick test_implicit_unwrap_modulo;
      Alcotest.test_case "implicit unwrap case branch" `Quick test_implicit_unwrap_case_branch;
    ];
  ]
