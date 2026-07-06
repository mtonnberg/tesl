(** FAIL-CLOSED CHECKER HARDENING — antagonistic red→green cases.

    Pins the 2026-07-06 fail-closed hardening of the non-discharge judgments in
    {!Proof_checker} (roadmap: fail_closed_checker_hardening umbrella).  Each
    REJECT case here was silently ACCEPTED by the judgment under test before the
    hardening, because a `| _ ->` wildcard (or a deliberate non-descent) skipped
    the shape:

    1. [validate_param_proof_subjects] only validated return-proof subjects for
       [RetAttached]; a bogus subject in a [RetMaybeAttached] return was skipped
       (the one ACTIVE fail-open of the audit).  Subject validation is OWNED
       here only for signature-scoped forms (RetAttached / RetMaybeAttached /
       the RetExists binder); pack/quantifier forms may name body locals and are
       deferred to the discharge judgment — pinned end-to-end below.
    2. [validate_no_ok_in_fn] did not descend into constructor arguments or case
       guards, so `Something (ok v ::: P v)` inside a plain `fn` escaped.
    3. [check_gw] (secondary ghost-witness walk) ended in `| _ -> ()` and missed
       a witnessed record construction nested in a list / application argument.
    4. [check_capabilities] skipped every non-DFunc declaration, so an
       undeclared capability in a `test` (or queue/agent/apiTest/loadTest)
       `requires [...]` was silently accepted — reproduced empirically before
       the fix.

    All assertions run {!Proof_checker.check_module} directly, so the verdict is
    attributable to pipeline 2 (the judgment that was fail-open), not to a
    pipeline-1 backstop that happens to also reject the program. *)

open Proof_checker

let parse src = Parser.parse_module "<test>" src

let contains haystack needle =
  let n = String.length haystack and m = String.length needle in
  let found = ref false in
  for i = 0 to n - m do
    if String.sub haystack i m = needle then found := true
  done;
  !found

let check_errors src =
  match parse src with
  | Err e -> Alcotest.failf "parse error: %s" e.msg
  | Ok m -> Proof_checker.check_module m

let assert_proof_error src substr =
  let errs = check_errors src in
  if not (List.exists (fun e -> contains e.message substr) errs) then
    Alcotest.failf "expected proof error containing %S but got:\n%s"
      substr
      (if errs = [] then "(no errors)"
       else String.concat "\n" (List.map (fun e -> e.message) errs))

(* Absence of one SPECIFIC diagnostic (the judgment under test must stay quiet
   on the sound variant), without requiring the whole module to be error-free. *)
let assert_no_error_containing src substr =
  let errs = check_errors src in
  match List.find_opt (fun e -> contains e.message substr) errs with
  | None -> ()
  | Some e ->
    Alcotest.failf "expected NO proof error containing %S but got: %s"
      substr e.message

(* ── 1. Return-proof subjects: every proof-bearing return form ───────────── *)

let subj_preamble = {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int, Bool(..), List]
import Tesl.Maybe exposing [Maybe(..)]
fact Positive (n: Int)
|}

(* RetNamedPack subjects are DEFERRED to the discharge judgment (they may be
   implicit/structural) — pin that the backstop actually rejects a bogus one
   end-to-end, so the deferral is never a silent accept. *)
let t_subject_named_pack_bogus_backstopped () =
  let src =
    subj_preamble ^ {|fn f(p: Int ::: Positive p) -> Int ? Positive zz =
  p
|}
  in
  match parse src with
  | Err e -> Alcotest.failf "parse error: %s" e.msg
  | Ok m ->
    let errs =
      List.filter (fun (d : Compile.diagnostic) -> d.severity = "error")
        (Compile.check_module src m)
    in
    if not (List.exists (fun (d : Compile.diagnostic) ->
        contains d.message "claiming entity proof") errs)
    then
      Alcotest.failf
        "expected the discharge backstop to reject the bogus named-pack \
         subject, got:\n%s"
        (String.concat "\n"
           (List.map (fun (d : Compile.diagnostic) -> d.message) errs))

let t_subject_maybe_attached_bogus () =
  assert_proof_error
    (subj_preamble ^ {|fn f(x: Int ::: Positive x) -> Maybe (r: Int ::: Positive ww) =
  Something x
|})
    "return proof subject 'ww' is not a parameter name"

let t_subject_maybe_attached_binder_valid () =
  (* The RetMaybeAttached binder `r` must be a VALID subject (it was not even
     in [valid_names] before the hardening). *)
  assert_no_error_containing
    (subj_preamble ^ {|fn f(x: Int ::: Positive x) -> Maybe (r: Int ::: Positive r) =
  Something x
|})
    "return proof subject"

let t_subject_exists_body_local_valid () =
  (* An existential pack's BODY proof may name a body LOCAL (`acc` below is
     `let`-bound, not a parameter) — the ProofSuite-H PosH11 pattern.  The
     subject check must stay quiet; discharge owns the body's validity. *)
  assert_no_error_containing
    {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int, String, Bool(..)]
import Tesl.Id exposing [generatePrefixedId]
import Tesl.Random exposing [random]
record Account { id: String balance: Int }
fact IsOpened (a: Account)
check checkOpened(a: Account) -> a: Account ::: IsOpened a =
  if a.balance >= 0 then
    ok a ::: IsOpened a
  else
    fail 400 "negative balance"
fn openAcc() -> exists accId: String => Account ::: IsOpened acc requires [random] =
  let accId = generatePrefixedId "acc"
  let acc = Account { id: accId, balance: 0 }
  let validated = check checkOpened acc
  exists accId =>
    validated
|}
    "return proof subject"

(* ── 2. no-ok-in-fn: constructor arguments and case guards ───────────────── *)

let t_ok_in_constructor_arg () =
  assert_proof_error
    (subj_preamble ^ {|fn forge(n: Int) -> Maybe Int =
  Something (ok n ::: Positive n)
|})
    "ok ::: proof construction is not allowed in `fn`"

let t_ok_in_case_guard () =
  assert_proof_error
    (subj_preamble ^ {|fn forge(n: Int) -> Int =
  case n of
    x where (ok x ::: Positive x) > 0 -> x
    _ -> 0
|})
    "ok ::: proof construction is not allowed in `fn`"

(* ── 3. check_gw: ghost witness nested in a non-explicit position ────────── *)

let gw_preamble = {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int, Bool(..), List, Fact, detachFact]
fact Pos (n: Int)
fact Cross (a: Int, b: Int)
check mkCross(a: Int, b: Int) -> a: Int ::: Cross a b =
  if a > b then
    ok a ::: Cross a b
  else
    fail 400 "no"
record RL {
  a: Int ::: Pos a
  b: Int ::: Pos b
} ::: Cross a b
|}

let t_ghost_witness_nested_in_list () =
  assert_proof_error
    (gw_preamble ^ {|fn nestBad(a: Int ::: Pos a, b: Int ::: Pos b) -> List RL =
  [ RL { a: a, b: b } ::: a ]
|})
    "ghost witness for record `RL` must use `(detachFact proof)`"

let t_ghost_witness_nested_in_list_valid () =
  assert_no_error_containing
    (gw_preamble ^ {|fn nestGood(a: Int ::: Pos a, b: Int ::: Pos b, w: Fact (Cross a b)) -> List RL =
  [ RL { a: a, b: b } ::: w ]
|})
    "ghost witness for record"

(* ── 4. Capability requires-lists beyond DFunc ───────────────────────────── *)

let t_test_requires_undeclared_cap () =
  assert_proof_error
    {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
fn double(n: Int) -> Int =
  n * 2
test "bogus cap" requires [totallyBogusCap] {
  expect double 2 == 4
}
|}
    "test 'bogus cap' requires undeclared capability 'totallyBogusCap'"

let t_test_requires_declared_cap_ok () =
  assert_no_error_containing
    {|#lang tesl
module Foo exposing []
import Tesl.Prelude exposing [Int]
capability myCap
fn double(n: Int) -> Int =
  n * 2
test "declared cap" requires [myCap] {
  expect double 2 == 4
}
|}
    "requires undeclared capability"

(* ── emailCap composability (email_capability_not_composable) ────────────── *)

(* A library fn can `requires [emailCap]` when Tesl.Email is imported — the
   capability composes like dbRead now that it has a stdlib provider row. *)
let t_emailcap_library_requires_ok () =
  assert_no_error_containing
    {|#lang tesl
module ELib exposing [helper]
import Tesl.Prelude exposing [Int, String]
import Tesl.Email exposing [emailCap]
fn helper(msg: String) -> Int requires [emailCap] =
  1
|}
    "undeclared capability"

(* A domain capability may `implies emailCap` when Tesl.Email is imported. *)
let t_emailcap_implies_ok () =
  assert_no_error_containing
    {|#lang tesl
module EImpl exposing [notify]
import Tesl.Prelude exposing [Int, String]
import Tesl.Email exposing [emailCap]
capability notifier implies emailCap
fn notify(msg: String) -> Int requires [notifier] =
  1
|}
    "unknown capability"

(* Control: `requires [emailCap]` with NO import and no email block is still
   rejected — deny-by-default is intact, the fix only added a provider, not an
   ambient grant. *)
let t_emailcap_no_import_rejected () =
  assert_proof_error
    {|#lang tesl
module ENone exposing [helper]
import Tesl.Prelude exposing [Int, String]
fn helper(msg: String) -> Int requires [emailCap] =
  1
|}
    "requires undeclared capability 'emailCap'"

(* ── Capability-table drift seam (email_capability_not_composable) ───────────

   The email bug was a DRIFT: `email`/`emailCap` was a concrete builtin
   capability (Ast.builtin_capability_names) and exposable from Tesl.Email
   (Type_system import allowlist), but had NO provider row in
   Validation_common.tesl_stdlib_cap_map — so it typed as importable yet the
   capability silently vanished, uncomposable in a library `requires`/`implies`.

   This seam pins the invariant that would have caught it at build time: the set
   of concrete builtin capabilities is EXACTLY the set of capabilities provided
   by the stdlib cap-map.  A new builtin capability that forgets its provider
   row (or a provider row for a non-builtin) fails here. *)
let stdlib_provided_caps =
  List.concat_map (fun (_m, caps) -> List.map fst caps)
    Validation_common.tesl_stdlib_cap_map
  |> List.sort_uniq String.compare

let builtin_caps =
  List.sort_uniq String.compare Ast.builtin_capability_names

let t_builtin_caps_all_have_provider () =
  let missing =
    List.filter (fun b -> not (List.mem b stdlib_provided_caps)) builtin_caps in
  if missing <> [] then
    Alcotest.failf
      "builtin capability(ies) %s have no Tesl stdlib provider row in \
       tesl_stdlib_cap_map — they type as usable but cannot be imported/composed \
       (this is the email_capability_not_composable drift class)"
      (String.concat ", " missing)

let t_provided_caps_all_builtin () =
  let extra =
    List.filter (fun p -> not (List.mem p builtin_caps)) stdlib_provided_caps in
  if extra <> [] then
    Alcotest.failf
      "stdlib cap-map provides %s, which is not in Ast.builtin_capability_names \
       — the two capability tables have drifted"
      (String.concat ", " extra)

(* ── Runner ──────────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "fail_closed_hardening"
    [ ( "return-proof subjects (all forms)",
        [ Alcotest.test_case "RetNamedPack bogus subject backstopped by discharge"
            `Quick t_subject_named_pack_bogus_backstopped;
          Alcotest.test_case "RetMaybeAttached bogus subject rejected" `Quick
            t_subject_maybe_attached_bogus;
          Alcotest.test_case "RetMaybeAttached binder is a valid subject" `Quick
            t_subject_maybe_attached_binder_valid;
          Alcotest.test_case "exists-body local subject stays accepted" `Quick
            t_subject_exists_body_local_valid;
        ] );
      ( "no-ok-in-fn descents",
        [ Alcotest.test_case "ok inside constructor arg rejected" `Quick
            t_ok_in_constructor_arg;
          Alcotest.test_case "ok inside case guard rejected" `Quick
            t_ok_in_case_guard;
        ] );
      ( "ghost-witness walker totality",
        [ Alcotest.test_case "bad witness nested in list rejected" `Quick
            t_ghost_witness_nested_in_list;
          Alcotest.test_case "good witness nested in list accepted" `Quick
            t_ghost_witness_nested_in_list_valid;
        ] );
      ( "capability requires beyond DFunc",
        [ Alcotest.test_case "test requires undeclared cap rejected" `Quick
            t_test_requires_undeclared_cap;
          Alcotest.test_case "test requires declared cap accepted" `Quick
            t_test_requires_declared_cap_ok;
        ] );
      ( "emailCap composability + cap-table drift seam",
        [ Alcotest.test_case "library requires [emailCap] via import accepted" `Quick
            t_emailcap_library_requires_ok;
          Alcotest.test_case "capability implies emailCap accepted" `Quick
            t_emailcap_implies_ok;
          Alcotest.test_case "emailCap with no import still rejected" `Quick
            t_emailcap_no_import_rejected;
          Alcotest.test_case "every builtin capability has a stdlib provider" `Quick
            t_builtin_caps_all_have_provider;
          Alcotest.test_case "every stdlib-provided cap is a known builtin" `Quick
            t_provided_caps_all_builtin;
        ] );
    ]
