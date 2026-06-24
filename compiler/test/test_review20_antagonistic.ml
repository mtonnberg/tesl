(** Antagonistic regression tests for Critical Review 20.
    Each test probes a specific flaw, limitation, or correctness gap
    identified during the review. Tests are ordered by finding ID. *)

open Alcotest

(* ── Helpers ─────────────────────────────────────────────────────────────── *)

let tesl =
  match Sys.getenv_opt "TESL_BIN" with
  | Some b -> b
  | None ->
    let dir = Filename.dirname Sys.argv.(0) in
    let candidate = Filename.concat (Filename.dirname dir) "bin/main.exe" in
    let candidate2 = Filename.concat dir "../bin/main.exe" in
    if Sys.file_exists candidate then candidate
    else if Sys.file_exists candidate2 then candidate2
    else "tesl"

let check_subcmd =
  if Filename.basename tesl = "main.exe" then "--check" else "check"

let fmt_subcmd =
  if Filename.basename tesl = "main.exe" then "--fmt" else "fmt"

let compile_string src =
  let tmp = Filename.temp_file "tesl-r20-test" ".tesl" in
  let oc = open_out tmp in
  output_string oc src;
  close_out oc;
  let ic = Unix.open_process_in (Printf.sprintf "%s %s %s 2>&1" tesl check_subcmd tmp) in
  let out = In_channel.input_all ic in
  let _ = Unix.close_process_in ic in
  (try Sys.remove tmp with _ -> ());
  out

let exit_code_of src =
  let tmp = Filename.temp_file "tesl-r20-test" ".tesl" in
  let oc = open_out tmp in
  output_string oc src;
  close_out oc;
  let status = Sys.command (Printf.sprintf "%s %s %s >/dev/null 2>&1" tesl check_subcmd tmp) in
  (try Sys.remove tmp with _ -> ());
  status

let fmt_string src =
  let tmp = Filename.temp_file "tesl-r20-fmt" ".tesl" in
  let oc = open_out tmp in
  output_string oc src;
  close_out oc;
  let _ = Sys.command (Printf.sprintf "%s %s %s 2>/dev/null" tesl fmt_subcmd tmp) in
  let ic = open_in tmp in
  let result = In_channel.input_all ic in
  close_in ic;
  (try Sys.remove tmp with _ -> ());
  result

let should_pass src =
  let out = compile_string src in
  let has_error =
    let re = Str.regexp "error\\[" in
    try ignore (Str.search_forward re out 0); true with Not_found -> false
  in
  check bool "should compile without errors" false has_error

let should_fail pattern src =
  let out = compile_string src in
  check bool (Printf.sprintf "should fail with pattern: %s" pattern) true
    (let re = Str.regexp pattern in
     try ignore (Str.search_forward re out 0); true with Not_found -> false)

let prelude = "#lang tesl\nmodule T exposing []\nimport Tesl.Prelude exposing [Int, String, Bool(..), List, Unit, Fact]\n"

(* ── 1.1 FIXED: Combined check (&&) proof propagation for named variables ── *)

let test_combined_check_with_named_variable () =
  (* REGRESSION: `let v = check (checkA && checkB) named_var` must propagate
     the proofs of both checks to `v` in the static proof environment. *)
  let src = prelude ^ {|
fact IsPositive (n: Int)
fact IsSmall    (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"

check checkSmall(n: Int) -> n: Int ::: IsSmall n =
  if n < 100 then
    ok n ::: IsSmall n
  else
    fail 400 "too big"

fn needsBoth(n: Int ::: IsPositive n && IsSmall n) -> String = "good"

fn callsite(raw: Int) -> String =
  let v = check (checkPos && checkSmall) raw
  needsBoth v
|} in
  should_pass src

let test_combined_check_three_way () =
  (* Three-way combined check must propagate all three proofs. *)
  let src = prelude ^ {|
fact A (n: Int)
fact B (n: Int)
fact C (n: Int)

check checkA(n: Int) -> n: Int ::: A n =
  if n > 0 then
    ok n ::: A n
  else
    fail 400 "a"

check checkB(n: Int) -> n: Int ::: B n =
  if n > 0 then
    ok n ::: B n
  else
    fail 400 "b"

check checkC(n: Int) -> n: Int ::: C n =
  if n > 0 then
    ok n ::: C n
  else
    fail 400 "c"

fn needsAll(n: Int ::: A n && B n && C n) -> String = "all"

fn callsite(raw: Int) -> String =
  let v = check (checkA && checkB && checkC) raw
  needsAll v
|} in
  should_pass src

let test_combined_check_literal_still_works () =
  (* Literal argument case must still work (regression guard). *)
  let src = prelude ^ {|
fact IsPositive (n: Int)
fact IsSmall    (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "p"

check checkSmall(n: Int) -> n: Int ::: IsSmall n =
  if n < 100 then
    ok n ::: IsSmall n
  else
    fail 400 "s"

fn needsBoth(n: Int ::: IsPositive n && IsSmall n) -> String = "good"

fn callsite() -> String =
  let v = check (checkPos && checkSmall) 42
  needsBoth v
|} in
  should_pass src

(* ── 1.2 HIGH: where guard requires parens around function application ────── *)

let test_where_guard_fn_app_without_parens_works () =
  (* FIXED: function application in where guards no longer requires explicit
     parentheses. `where gt5 n ->` now correctly parses `gt5 n` as a call. *)
  let src = prelude ^ {|
fn gt5(n: Int) -> Bool = n > 5

type Wrapper = Wrap value:Int

fn test(w: Wrapper) -> String =
  case w of
    Wrap n where gt5 n -> "big"
    Wrap _ -> "small"
|} in
  should_pass src

let test_where_guard_multiarg_fn_app_works () =
  (* Multi-argument function application in where guards must also work. *)
  let src = prelude ^ {|
import Tesl.String exposing [String.startsWith]

type Status
  = Active
  | Suspended reason:String

fn test(status: Status, userId: String) -> String =
  case status of
    Active -> "active"
    Suspended _ where String.startsWith userId "admin" -> "admin"
    Suspended _ -> "other"
|} in
  should_pass src

let test_where_guard_fn_app_with_parens_works () =
  (* Parenthesised function application in where guards must work. *)
  let src = prelude ^ {|
fn gt5(n: Int) -> Bool = n > 5

type Wrapper = Wrap value:Int

fn test(w: Wrapper) -> String =
  case w of
    Wrap n where (gt5 n) -> "big"
    Wrap _ -> "small"
|} in
  should_pass src

let test_where_guard_binary_op_works () =
  (* Binary operator guard is the documented example and must keep working. *)
  let src = prelude ^ {|
import Tesl.Maybe exposing [Maybe(..)]

fn classify(mx: Maybe Int) -> String =
  case mx of
    Nothing -> "nothing"
    Something x where x > 10 -> "big"
    Something _ -> "small"
|} in
  should_pass src

(* ── 1.3 FIXED: Integer overflow emits clean error (exit 1), not crash ────── *)

let test_overflow_exit_code_is_one () =
  let src = prelude ^ "fn bigNum() -> Int = 9999999999999999999999\n" in
  let code = exit_code_of src in
  check bool "overflow must exit 1, not crash (exit 2)" true (code = 1)

let test_overflow_error_message_is_informative () =
  let src = prelude ^ "fn bigNum() -> Int = 9999999999999999999999\n" in
  let out = compile_string src in
  let re = Str.regexp "out of range\\|integer literal" in
  check bool "overflow message must mention 'out of range' or 'integer literal'"
    true (try ignore (Str.search_forward re out 0); true with Not_found -> false)

let test_max_int_compiles () =
  (* max_int on 64-bit OCaml is 4611686018427387903 *)
  let src = prelude ^ "fn maxInt() -> Int = 4611686018427387903\n" in
  should_pass src

(* ── 2.1 MEDIUM: Sequential proof accumulation behaviour ─────────────────── *)

let test_sequential_checks_second_proof_works () =
  (* The second check's proof must be available on the result. *)
  let src = prelude ^ {|
fact IsSmall (n: Int)

check checkSmall(n: Int) -> n: Int ::: IsSmall n =
  if n < 100 then
    ok n ::: IsSmall n
  else
    fail 400 "s"

fn needsSmall(n: Int ::: IsSmall n) -> String = "ok"

fn callsite(raw: Int) -> String =
  let s = check checkSmall raw
  needsSmall s
|} in
  should_pass src

let test_sequential_checks_first_proof_accumulated () =
  (* The design was fixed: after two sequential checks, BOTH proofs accumulate.
     `check checkSmall pos` carries both IsPositive and IsSmall so needsBoth accepts it. *)
  let src = prelude ^ {|
fact IsPositive (n: Int)
fact IsSmall    (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "p"

check checkSmall(n: Int) -> n: Int ::: IsSmall n =
  if n < 100 then
    ok n ::: IsSmall n
  else
    fail 400 "s"

fn needsBoth(n: Int ::: IsPositive n && IsSmall n) -> String = "both"

fn works(raw: Int) -> String =
  let pos   = check checkPos   raw
  let small = check checkSmall pos
  needsBoth small
|} in
  (* Proof accumulation is now fixed: both IsPositive and IsSmall carry forward *)
  should_pass src

(* ── 2.3 MEDIUM: No structural list pattern matching ─────────────────────── *)

let test_list_isEmpty_idiom_works () =
  (* The workaround for missing list patterns must work. *)
  let src = prelude ^ {|
import Tesl.List exposing [List.isEmpty, List.head, List.foldl]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Int exposing [Int.toString]

fn safeHead(xs: List Int) -> String =
  if List.isEmpty xs then
    "empty"
  else
    case List.head xs of
      Nothing -> "empty"
      Something x -> Int.toString x
|} in
  should_pass src

let test_list_foldl_sum () =
  (* Without structural recursion, List.foldl with a named helper is the standard way. *)
  let src = prelude ^ {|
import Tesl.List exposing [List.foldl]

fn addInt(acc: Int, x: Int) -> Int =
  acc + x

fn sumList(xs: List Int) -> Int =
  List.foldl addInt 0 xs
|} in
  should_pass src

(* ── 2.4 LOW: Tuple2 not in Prelude ──────────────────────────────────────── *)

let test_tuple2_without_import_fails () =
  let src = prelude ^ {|
fn swap(t: Tuple2 String Int) -> String = "todo"
|} in
  should_fail "T001\\|not in scope" src

let test_tuple2_with_import_works () =
  (* Tuple2 with import compiles using constructor syntax. *)
  let src = prelude ^ {|
import Tesl.Tuple exposing [Tuple2, Tuple2.first, Tuple2.second]

fn makePair(a: String, b: Int) -> Tuple2 String Int =
  Tuple2 a b

fn getPairFirst(t: Tuple2 String Int) -> String =
  Tuple2.first t
|} in
  should_pass src

(* ── 3.3 FIXED: Formatter inserts space before = after proof spec ─────────── *)

let test_formatter_adds_space_before_eq_after_proof () =
  let src = "#lang tesl\nmodule T exposing []\nimport Tesl.Prelude exposing [Int]\nfact IsPositive (n: Int)\ncheck checkPos(n: Int) -> n: Int ::: IsPositive n=\n  if n > 0 then\n    ok n ::: IsPositive n\n  else\n    fail 400 \"bad\"\n" in
  let result = fmt_string src in
  let re = Str.regexp "IsPositive n =" in
  check bool "formatter must add space before = after proof spec" true
    (try ignore (Str.search_forward re result 0); true with Not_found -> false)

let test_formatter_adds_space_in_let_binding () =
  let src = "#lang tesl\nmodule T exposing []\nimport Tesl.Prelude exposing [Int]\nfn test(x: Int) -> Int=\n  let y=x + 1\n  y\n" in
  let result = fmt_string src in
  let has_y_eq = let re = Str.regexp "let y =" in
    try ignore (Str.search_forward re result 0); true with Not_found -> false in
  let has_sig_eq = let re = Str.regexp "-> Int =" in
    try ignore (Str.search_forward re result 0); true with Not_found -> false in
  check bool "formatter must add space around = in let binding" true has_y_eq;
  check bool "formatter must add space before = in function signature" true has_sig_eq

let test_formatter_leaves_eq_eq_alone () =
  (* == must NOT be reformatted as " = = " *)
  let src = "#lang tesl\nmodule T exposing []\nimport Tesl.Prelude exposing [Int, Bool(..)]\nfn eq(a: Int, b: Int) -> Bool = a == b\n" in
  let result = fmt_string src in
  let re = Str.regexp "a == b" in
  check bool "formatter must leave == intact" true
    (try ignore (Str.search_forward re result 0); true with Not_found -> false)

(* ── Suite registration ─────────────────────────────────────────────────── *)

let () = run "Review20-Antagonistic" [
    "combined-check-proof-propagation", [
      test_case "combined check with named variable propagates proofs"
        `Quick test_combined_check_with_named_variable;
      test_case "three-way combined check propagates all proofs"
        `Quick test_combined_check_three_way;
      test_case "combined check with literal still compiles"
        `Quick test_combined_check_literal_still_works;
    ];
    "where-guard-function-application", [
      test_case "fn app without parens in where guard compiles"
        `Quick test_where_guard_fn_app_without_parens_works;
      test_case "multi-arg fn app in where guard compiles"
        `Quick test_where_guard_multiarg_fn_app_works;
      test_case "fn app with parens in where guard compiles"
        `Quick test_where_guard_fn_app_with_parens_works;
      test_case "binary op in where guard compiles"
        `Quick test_where_guard_binary_op_works;
    ];
    "integer-overflow", [
      test_case "overflow exits with code 1 not 2"    `Quick test_overflow_exit_code_is_one;
      test_case "overflow emits informative message"  `Quick test_overflow_error_message_is_informative;
      test_case "max_int literal compiles"            `Quick test_max_int_compiles;
    ];
    "sequential-proof-accumulation", [
      test_case "single check proof is available"     `Quick test_sequential_checks_second_proof_works;
      test_case "sequential checks accumulate both proofs (fixed)"
        `Quick test_sequential_checks_first_proof_accumulated;
    ];
    "list-operations", [
      test_case "isEmpty idiom works without list patterns"
        `Quick test_list_isEmpty_idiom_works;
      test_case "foldl sum works"                     `Quick test_list_foldl_sum;
    ];
    "tuple2-import", [
      test_case "Tuple2 without import is an error"   `Quick test_tuple2_without_import_fails;
      test_case "Tuple2 with import compiles"         `Quick test_tuple2_with_import_works;
    ];
    "formatter-equals-spacing", [
      test_case "space inserted before = after proof spec"
        `Quick test_formatter_adds_space_before_eq_after_proof;
      test_case "space inserted around = in let binding"
        `Quick test_formatter_adds_space_in_let_binding;
      test_case "== operator left intact by formatter"
        `Quick test_formatter_leaves_eq_eq_alone;
    ];
  ]
