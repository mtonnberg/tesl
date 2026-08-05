(** A DISCARDED statement whose value is a function — an under-applied call.

    Found while implementing GitHub #78, in code that looked entirely ordinary:

      fn toIso(d: CivilDate) -> String =
        String.concat (pad (year d) 4)
                      (pad (month d) 2)

    Application arguments must be on the call's own line, so the second line is
    its own STATEMENT and the first line is `String.concat` applied to one of its
    two arguments.  The sequence's type comes from the last statement, so nothing
    downstream objected: `tesl check` reported zero errors and the generated
    module died on load with

      String.concat: arity mismatch; the expected number of arguments does not
      match the given number  expected: 2  given: 1

    Same compile-clean / runtime-dead shape as the single-line SQL clause bug
    (#77), reached through a different door — and not stdlib-specific: a
    user-defined function under-applied in statement position behaved identically.

    The rule now: a statement whose value is a FUNCTION cannot be an effect, so
    it is a compile error, decided on the INFERRED type (which is why it covers
    both callees).  What it must NOT do is fire on the many statement forms that
    legitimately discard a value — a query, an enqueue, a telemetry event, a
    `with database` block — or on an unresolved type variable, which is not
    evidence of anything. *)

open Alcotest

let compiler =
  match Sys.getenv_opt "TESL_OCAML_COMPILER" with
  | Some p when Sys.file_exists p -> p
  | _ ->
    (match Sys.getenv_opt "TESL_BIN" with
     | Some v when Filename.basename v = "main.exe" && Sys.file_exists v -> v
     | _ ->
       let dir = Filename.dirname Sys.argv.(0) in
       let c1 = Filename.concat (Filename.dirname dir) "bin/main.exe" in
       let c2 = Filename.concat dir "../bin/main.exe" in
       if Sys.file_exists c1 then c1 else if Sys.file_exists c2 then c2 else "tesl")

let failf fmt = Printf.ksprintf failwith fmt

let run_cc args =
  let q = Filename.quote compiler :: List.map Filename.quote args in
  let ic = Unix.open_process_in (String.concat " " q ^ " 2>&1") in
  let out = In_channel.input_all ic in
  let st = Unix.close_process_in ic in
  let code = match st with Unix.WEXITED c -> c | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + n in
  (code, out)

let with_source src f =
  let dir = Filename.temp_dir "tesl-partialstmt" "" in
  let path = Filename.concat dir "partialstmt.tesl" in
  Out_channel.with_open_text path (fun oc -> Out_channel.output_string oc src);
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let contains hay needle =
  try ignore (Str.search_forward (Str.regexp_string needle) hay 0); true
  with Not_found -> false

(* The file is named partialstmt.tesl, so the module header must match. *)
let prelude = {|module Partialstmt exposing []
import Tesl.Prelude exposing [Bool(..), Int, String, List, Unit]
import Tesl.String exposing [String.concat, String.length]
import Tesl.List exposing [List.length]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Database exposing [Database, Memory]

entity Row table "partialstmt_rows" primaryKey id {
  id: String
  qty: Int
}

database D = Database {
  entities: [Row]
  backend: Memory
}

fn add2(a: Int, b: Int) -> Int =
  a + b
|}

let check src = with_source (prelude ^ src) (fun p -> run_cc ["--check"; p])

let should_pass label src =
  let code, out = check src in
  if code <> 0 then failf "%s: expected a clean check, got exit %d:\n%s" label code out

let should_fail label ~expect src =
  let code, out = check src in
  if code = 0 then failf "%s: expected REJECTION, but the check passed" label;
  if not (contains out expect) then
    failf "%s: rejected, but not for the expected reason (wanted %S):\n%s" label expect out

(* ── The reported shape ──────────────────────────────────────────────────── *)

let test_stdlib_continuation_line () =
  should_fail "a stdlib call with its second argument on the next line"
    ~expect:"is applied to 1 argument but needs 2"
    {|
fn joinTwo(a: String, b: String) -> String =
  String.concat (a)
                (b)
|}

let test_user_fn_under_applied_statement () =
  should_fail "a user function under-applied in statement position"
    ~expect:"this statement's value is a function, not an effect"
    {|
fn stmtPos(a: String, b: String) -> String =
  let _ = add2 (1)
  String.concat a b
|}

(* The message has to say what to DO — the cause (an argument on a continuation
   line) is invisible from the failing line alone. *)
let test_message_names_the_cause () =
  let _, out = check {|
fn joinTwo(a: String, b: String) -> String =
  String.concat (a)
                (b)
|} in
  if not (contains out "CONTINUATION line is a separate statement") then
    failf "the rejection does not explain why the argument was not consumed:\n%s" out

(* Tail position was ALREADY correct — the ordinary return-type unification
   catches it there.  Pinned so a future change cannot regress the good case
   into the silent one. *)
let test_tail_position_still_reported_as_a_type_error () =
  should_fail "under-applied in tail position" ~expect:"cannot unify"
    {|
fn tailPos(a: String) -> String =
  String.concat (a)
|}

(* ── What must keep compiling ────────────────────────────────────────────── *)

let test_effect_statements_still_accepted () =
  should_pass "queries, inserts and a with-database block as statements"
    {|
fn seed() -> Int requires [dbRead, dbWrite] =
  with database D {
    let _ = insert Row { id: "a", qty: 1 }
    let _ = insert Row { id: "b", qty: 2 }
    let rows = select r from Row
    List.length rows
  }
|}

let test_saturated_call_statement_accepted () =
  should_pass "a fully applied call whose result is discarded"
    {|
fn discardSaturated(a: Int) -> Int =
  let _ = add2 a 1
  a
|}

(* A lambda BOUND to a name is a value, not a discarded statement — the rule is
   about the `_` position only, so higher-order code is untouched. *)
let test_bound_function_value_accepted () =
  should_pass "a function value bound to a name"
    {|
fn useHigherOrder(xs: List Int) -> Int =
  let f = fn(n: Int) -> n + 1
  List.length xs + f 1
|}

let () =
  run "under-applied call in statement position" [
    "rejected", [
      test_case "stdlib, argument on the next line" `Quick test_stdlib_continuation_line;
      test_case "user fn in statement position"     `Quick test_user_fn_under_applied_statement;
      test_case "message names the cause"           `Quick test_message_names_the_cause;
      test_case "tail position stays a type error"  `Quick test_tail_position_still_reported_as_a_type_error;
    ];
    "still accepted", [
      test_case "effect statements"      `Quick test_effect_statements_still_accepted;
      test_case "saturated call"         `Quick test_saturated_call_statement_accepted;
      test_case "bound function value"   `Quick test_bound_function_value_accepted;
    ];
  ]
