(** GitHub issue #74 — `List.filterCheck` with a PARTIALLY APPLIED check
    function: the manual's own documented idiom did not work in any spelling.

      * bare — `List.filterCheck (checkInBounds 0 100) xs` — was rejected with
        T001 "check function `checkInBounds` must be called with the `check`
        keyword", even though the manual names this exact expression as the way
        to hand over a check function;
      * with the keyword — `List.filterCheck (check checkInBounds 0 100) xs` —
        it checked CLEAN and then trapped at runtime: "checkInBounds: arity
        mismatch; expected: 3 given: 2".  A check-passes / test-fails trap;
      * combined — `List.filterCheck (checkA a && checkB b) xs` — the reported
        V001 came from the `check`-prefixed halves; the BARE combination
        compiled but was silently wrong (see the emit section below).

    The rule
    ------------------------------------------------------------------------
    Only a SATURATING application produces a check RESULT, and only that shape
    needs the `check` keyword.  An under-applied check is a FUNCTION, which is
    exactly what filterCheck/allCheck want.  Correspondingly, `check` must
    saturate — the partial form now fails at compile time with a message that
    names the working spelling, instead of at runtime with an arity error.

    Two consequences had to be handled, both of which this file pins:

    * EMIT.  `is_fn_ref` (the `&&` arm) recognised only a bare name, so an
      under-applied operand fell through to the boolean arm and emitted a
      boolean conjunction, which evaluates the wrong shape — the first check was
      SILENTLY DROPPED and the filter kept elements it should have rejected.
      Now both operands route through a generated sequential-check helper.

    * PROOF.  The ForAll layer keys on predicate NAMES, which was complete only
      while a check callback's sole subject was the element.  A partial
      application closes over the fact's OTHER subjects, so two new holes opened
      the moment the shape became expressible: [preds_from_check_expr] returned
      [] for an application (making the "produces X, requires Y" gate accept
      anything), and a closed-over subject different from the declared one
      matched on the name alone.  Both are rejected below.

    Runtime companions: tests/filter-check-partial-tests.tesl. *)

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
  let dir = Filename.temp_dir "tesl-issue74" "" in
  let path = Filename.concat dir "issue74.tesl" in
  Out_channel.with_open_text path (fun oc -> Out_channel.output_string oc src);
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let contains hay needle =
  try ignore (Str.search_forward (Str.regexp_string needle) hay 0); true
  with Not_found -> false

(* The file is named issue74.tesl, so the module header must match. *)
let prelude = {|module Issue74 exposing []
import Tesl.Prelude exposing [Bool(..), Int, List]
import Tesl.List exposing [List.filterCheck, List.length]

fact InBounds (lo: Int) (hi: Int) (n: Int)
fact AtLeast (lo: Int) (n: Int)
fact AtMost (hi: Int) (n: Int)
fact Blessed (n: Int)

check checkInBounds(lo: Int, hi: Int, n: Int) -> n: Int ::: InBounds lo hi n =
  if lo <= n && n <= hi then
    ok n ::: InBounds lo hi n
  else
    fail 400 "out of bounds"

check checkAtLeast(lo: Int, n: Int) -> n: Int ::: AtLeast lo n =
  if n >= lo then
    ok n ::: AtLeast lo n
  else
    fail 400 "too small"

check checkAtMost(hi: Int, n: Int) -> n: Int ::: AtMost hi n =
  if n <= hi then
    ok n ::: AtMost hi n
  else
    fail 400 "too big"
|}

let check src =
  with_source (prelude ^ src) (fun p -> run_cc ["--check"; p])

let emit src =
  with_source (prelude ^ src) (fun p ->
    match Compile.compile_go_file p with
    | Compile.GoFailure diagnostics ->
      failf "Go emit failed:\n%s"
        (String.concat "\n"
           (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
    | Compile.GoSuccess artifacts ->
      String.concat "\n"
        (List.map (fun (a : Emit_go.artifact) -> a.contents) artifacts))

let should_pass label src =
  let code, out = check src in
  if code <> 0 then failf "%s: expected a clean check, got exit %d:\n%s" label code out

let should_fail label ~expect src =
  let code, out = check src in
  if code = 0 then failf "%s: expected REJECTION, but the check passed" label;
  if not (contains out expect) then
    failf "%s: rejected, but not for the expected reason (wanted %S):\n%s" label expect out

(* ── The reported shapes ─────────────────────────────────────────────────── *)

let test_bare_partial_application () =
  should_pass "the manual's documented idiom"
    {|
test "partially applied" {
  let xs = [1, 50, 200, 99]
  let result = List.filterCheck (checkInBounds 0 100) xs
  expect List.length result == 3
}
|}

let test_check_keyword_must_saturate () =
  should_fail "`check` on a partial application"
    ~expect:"is applied to 2 of its 3 arguments"
    {|
test "check-prefixed partial" {
  let xs = [1, 50, 200, 99]
  let result = List.filterCheck (check checkInBounds 0 100) xs
  expect List.length result == 3
}
|}

let test_check_keyword_message_names_the_fix () =
  let _, out =
    check {|
test "check-prefixed partial" {
  let result = List.filterCheck (check checkAtMost 100) [1, 2]
  expect List.length result == 2
}
|}
  in
  if not (contains out "drop the `check` keyword") then
    failf "the rejection must name the working spelling:\n%s" out

let test_saturating_call_still_needs_check () =
  (* The original T001 rule is intact for a real call — relaxing it for partial
     applications must not relax it for a saturating one. *)
  should_fail "saturating call without `check`"
    ~expect:"must be called with the `check` keyword"
    {|
fn direct(n: Int) -> Int =
  let x = checkAtMost 100 n
  x
|}

let test_combination_of_partial_applications () =
  should_pass "combined partial applications"
    {|
test "combined" {
  let xs = [-7, 1, 50, 200, 99]
  let result = List.filterCheck (checkAtLeast 0 && checkAtMost 100) xs
  expect List.length result == 3
}
|}

(* ── Proof side: the ForAll layer must not fail open ─────────────────────── *)

let test_forall_through_partial_application () =
  should_pass "ForAll established by a partially applied check"
    {|
fn atMostAll(xs: List Int, hi: Int) -> List Int ::: ForAll (AtMost hi) =
  List.filterCheck (checkAtMost hi) xs
|}

let test_reject_forged_forall_predicate () =
  (* Filters on AtMost, claims ForAll Blessed.  Before, a partially applied
     callback produced NO predicates, so this gate accepted silently. *)
  should_fail "forged ForAll predicate"
    ~expect:"missing `[Blessed]`"
    {|
fn forged(xs: List Int, hi: Int) -> List Int ::: ForAll Blessed =
  List.filterCheck (checkAtMost hi) xs
|}

let test_reject_wrong_closed_over_subject () =
  (* Right predicate NAME, wrong subject: elements are only checked against
     `other`, but the return type promises the fact about `hi`. *)
  should_fail "closed-over subject differs from the declared one"
    ~expect:"a partially applied check closes over the fact's subjects"
    {|
fn wrongSubject(xs: List Int, hi: Int, other: Int) -> List Int ::: ForAll (AtMost hi) =
  List.filterCheck (checkAtMost other) xs
|}

let test_combination_subjects_checked_per_half () =
  (* Each half of a `&&` chain closes over its own subjects, so each is compared
     against the declared ForAll separately. *)
  should_fail "wrong subject in one half of a combination"
    ~expect:"a partially applied check closes over the fact's subjects"
    {|
fn combo(xs: List Int, hi: Int, other: Int) -> List Int ::: ForAll (AtMost hi) =
  List.filterCheck (checkAtLeast 0 && checkAtMost other) xs
|}

let test_combination_with_matching_subjects () =
  should_pass "a combination whose subjects match the declaration"
    {|
fn combo(xs: List Int, hi: Int) -> List Int ::: ForAll (AtMost hi) =
  List.filterCheck (checkAtLeast 0 && checkAtMost hi) xs
|}

let test_literal_closed_over_subject () =
  should_pass "a literal subject matches the declared literal"
    {|
fn atMost100(xs: List Int) -> List Int ::: ForAll (AtMost 100) =
  List.filterCheck (checkAtMost 100) xs
|}

let test_reject_wrong_literal_subject () =
  should_fail "a literal subject that differs from the declared one"
    ~expect:"a partially applied check closes over the fact's subjects"
    {|
fn atMost100(xs: List Int) -> List Int ::: ForAll (AtMost 100) =
  List.filterCheck (checkAtMost 50) xs
|}

(* ── Emit: the combination must use the generated sequential-check helper ── *)

let test_emit_uses_check_and () =
  let out =
    emit {|
test "combined" {
  let xs = [-7, 1, 50, 200, 99]
  let result = List.filterCheck (checkAtLeast 0 && checkAtMost 100) xs
  expect List.length result == 3
}
|}
  in
  if not (contains out "teslCheckAll") then
    failf "a combination of partial applications must lower to a generated \
           sequential-check helper, not a boolean conjunction (which drops \
           the first check):\n%s" out

let test_emit_eta_expands_partial_application () =
  let out =
    emit {|
test "partially applied" {
  let xs = [1, 50, 200, 99]
  let result = List.filterCheck (checkInBounds 0 100) xs
  expect List.length result == 3
}
|}
  in
  (* The generated callback invocation must retain both captured arguments and
     supply the list element as the final, saturating argument. *)
  if not (contains out
            "checkInBounds(teslrt.FromInt64(0), teslrt.FromInt64(100), Value") then
    failf "the partial check callback must be invoked with its captured bounds \
           and the list element:\n%s" out

let () =
  run "issue-74 partially applied check callbacks" [
    "surface", [
      test_case "bare partial application"      `Quick test_bare_partial_application;
      test_case "`check` must saturate"         `Quick test_check_keyword_must_saturate;
      test_case "rejection names the fix"       `Quick test_check_keyword_message_names_the_fix;
      test_case "saturating call still guarded" `Quick test_saturating_call_still_needs_check;
      test_case "combination accepted"          `Quick test_combination_of_partial_applications;
    ];
    "proof", [
      test_case "ForAll via partial application" `Quick test_forall_through_partial_application;
      test_case "forged predicate rejected"      `Quick test_reject_forged_forall_predicate;
      test_case "wrong subject rejected"         `Quick test_reject_wrong_closed_over_subject;
      test_case "combination half checked"       `Quick test_combination_subjects_checked_per_half;
      test_case "combination subjects match"     `Quick test_combination_with_matching_subjects;
      test_case "literal subject accepted"       `Quick test_literal_closed_over_subject;
      test_case "wrong literal rejected"         `Quick test_reject_wrong_literal_subject;
    ];
    "emit", [
      test_case "combination uses sequential helper" `Quick test_emit_uses_check_and;
      test_case "partial callback invocation saturates" `Quick test_emit_eta_expands_partial_application;
    ];
  ]
