(** Linter rule tests (WS5 — linting improvements).

    These exercise {!Linter.lint_file} directly on temp files. The linter is
    pure static OCaml analysis — no Racket backend: is involved — so these tests
    run entirely in-process via the library.

    Coverage:
      - W060 false-positive fix: the proof half of a proof-decompose
        (`let (v ::: p) = x`) must NOT be reported as an unused binding, while
        the value half and ordinary `let` bindings still are.
      - W063 redundant re-check: re-validating a value already produced by the
        same checker.
      - W064 discarded validation result: `let _ = check …` / `_`-prefixed.
      - Negative cases proving idiomatic proof code stays quiet.

    The compiler library is built [(wrapped false)], so its modules ([Linter],
    [Compile], …) are referenced unqualified, matching the other test files.

    Note: every [.tesl] fixture below must actually parse — the linter's
    AST-based passes silently no-op on a parse error, which would make a
    "should fire" assertion vacuously fail. In particular `if … then … else …`
    must be multi-line, and identifiers must avoid keywords (`requires`, …). *)

let lint_src src =
  let path = Filename.temp_file "tesl_linter_test" ".tesl" in
  Fun.protect
    ~finally:(fun () -> if Sys.file_exists path then Sys.remove path)
    (fun () ->
      let oc = open_out_bin path in
      output_string oc src;
      close_out oc;
      Linter.lint_file path)

let diag_to_str (d : Compile.diagnostic) =
  Printf.sprintf "%s @%d:%d %s" d.code d.start_line d.start_col d.message

let dump diags =
  if diags = [] then "(no diagnostics)"
  else String.concat "\n" (List.map diag_to_str diags)

let str_contains s sub =
  let sl = String.length s and pl = String.length sub in
  let rec loop i =
    if i + pl > sl then false
    else if String.sub s i pl = sub then true
    else loop (i + 1)
  in
  pl = 0 || loop 0

let has_code (diags : Compile.diagnostic list) code =
  List.exists (fun (d : Compile.diagnostic) -> d.code = code) diags

let assert_has diags code =
  if not (has_code diags code) then
    Alcotest.failf "expected lint code %s but did not find it in:\n%s" code (dump diags)

let assert_absent diags code =
  if has_code diags code then
    Alcotest.failf "expected NO lint code %s but found it in:\n%s" code (dump diags)

let find diags code =
  match List.find_opt (fun (d : Compile.diagnostic) -> d.code = code) diags with
  | Some d -> d
  | None -> Alcotest.failf "expected lint code %s but did not find it in:\n%s" code (dump diags)

(* Shared check/fact preamble used by most fixtures. *)
let preamble = {|#lang tesl
module Lint exposing [f]
import Tesl.Prelude exposing [Int, String]
fact ValidScore (n: Int)
check checkScore(n: Int) -> n: Int ::: ValidScore n =
  if n >= 0 then
    ok n ::: ValidScore n
  else
    fail 400 "bad"
fn needsScore(n: Int ::: ValidScore n) -> String =
  "${n}"
|}

(* ── W060: proof-decompose half should not be flagged ───────────────────── *)

(* Mirrors lesson08 `showAge` and lesson09 `decomposeBoth`: the detached proof
   half of a decompose is intentionally left unconsumed. Used to wrongly fire
   W060 on `ageProof`. *)
let test_w060_decompose_proof_half_not_unused () =
  let src = preamble ^ {|
fn showScore(score: Int ::: ValidScore score) -> String =
  let (rawScore ::: scoreProof) = score
  "score is ${rawScore}"
|} in
  let diags = lint_src src in
  assert_absent diags "W060"

(* The VALUE half of a decompose is still checked: if the bare value is never
   used, W060 fires on it (only the proof half is exempt). *)
let test_w060_decompose_value_half_still_flagged () =
  let src = preamble ^ {|
fn dropAll(score: Int ::: ValidScore score) -> String =
  let (rawScore ::: scoreProof) = score
  "constant"
|} in
  let diags = lint_src src in
  let d = find diags "W060" in
  if not (str_contains d.message "rawScore") then
    Alcotest.failf "expected W060 to name `rawScore`, got: %s" d.message

(* An ordinary unused `let` is still flagged (regression guard). *)
let test_w060_plain_unused_let_still_flagged () =
  let src = preamble ^ {|
fn g(n: Int) -> Int =
  let unused = n + 1
  n
|} in
  let diags = lint_src src in
  assert_has diags "W060"

(* ── W063: redundant re-check ───────────────────────────────────────────── *)

let test_w063_redundant_recheck_fires () =
  let src = preamble ^ {|
fn f(raw: Int) -> String =
  let validated = check checkScore raw
  let again = check checkScore validated
  needsScore again
|} in
  let diags = lint_src src in
  let d = find diags "W063" in
  Alcotest.(check bool) "names validated"
    true (str_contains d.message "validated");
  Alcotest.(check bool) "names checkScore"
    true (str_contains d.message "checkScore")

(* Chaining DIFFERENT checkers (idiomatic proof accumulation, lesson51) must
   NOT fire W063. *)
let test_w063_distinct_checkers_no_warning () =
  let src = {|#lang tesl
module Lint exposing [f]
import Tesl.Prelude exposing [Int, String]
fact P (n: Int)
fact Q (n: Int)
check checkP(n: Int) -> n: Int ::: P n =
  if n > 0 then
    ok n ::: P n
  else
    fail 400 "bad"
check checkQ(n: Int) -> n: Int ::: Q n =
  if n < 100 then
    ok n ::: Q n
  else
    fail 400 "bad"
fn needsBoth(n: Int ::: P n && Q n) -> String =
  "${n}"
fn f(raw: Int) -> String =
  let withP = check checkP raw
  let withPQ = check checkQ withP
  needsBoth withPQ
|} in
  let diags = lint_src src in
  assert_absent diags "W063"

(* Checking two independent inputs with the same checker is fine (different
   subjects, lesson54 "validate the correct variable"). *)
let test_w063_same_checker_different_values_no_warning () =
  let src = preamble ^ {|
fn f(a: Int, b: Int) -> String =
  let validA = check checkScore a
  let validB = check checkScore b
  needsScore validB
|} in
  let diags = lint_src src in
  assert_absent diags "W063"

(* ── W064: discarded validation result ──────────────────────────────────── *)

let test_w064_discarded_check_fires () =
  let src = preamble ^ {|
fn f(raw: Int) -> Int =
  let _ = check checkScore raw
  raw
|} in
  let diags = lint_src src in
  assert_has diags "W064"

(* Keeping the proof half of a decomposed check (`let (_ ::: p) = check …`)
   is the idiomatic edge-validation pattern (lesson52) — NOT discarding. *)
let test_w064_keep_proof_half_no_warning () =
  let src = preamble ^ {|
fn f(raw: Int) -> String =
  let (_ ::: p) = check checkScore raw
  let proven = raw ::: p
  needsScore proven
|} in
  let diags = lint_src src in
  assert_absent diags "W064";
  assert_absent diags "W063"

(* Binding a check result to a real name does not fire W064. *)
let test_w064_bound_check_no_warning () =
  let src = preamble ^ {|
fn f(raw: Int) -> String =
  let validated = check checkScore raw
  needsScore validated
|} in
  let diags = lint_src src in
  assert_absent diags "W064"

(* detach / forget / attach roundtrip (lesson54 `roundtripProof`) must stay
   quiet — these are not check/auth keywords. *)
let test_proof_roundtrip_no_footgun_warnings () =
  let src = {|#lang tesl
module Lint exposing [roundtrip]
import Tesl.Prelude exposing [Int, String, detachFact, attachFact, forgetFact]
fact ValidScore (n: Int)
check checkScore(n: Int) -> n: Int ::: ValidScore n =
  if n >= 0 then
    ok n ::: ValidScore n
  else
    fail 400 "bad"
fn needsScore(n: Int ::: ValidScore n) -> String =
  "${n}"
fn roundtrip(raw: Int) -> String =
  let validated = check checkScore raw
  let pf = detachFact validated
  let stripped = forgetFact validated
  let restored = attachFact stripped pf
  needsScore restored
|} in
  let diags = lint_src src in
  assert_absent diags "W063";
  assert_absent diags "W064"

(* ── W050 — config-block usage is credited ───────────────────────────────────
   Names used only inside a typed-config RHS (`database X = Database { … }`,
   `queue X = Queue { … }`, etc.) must be credited as referenced; otherwise they
   are falsely flagged W050-unused.  Plus a regression guard: a genuinely-unused
   import is still flagged. *)
let test_w050_config_block_credits_used_imports () =
  let diags = lint_src {|#lang tesl
module DbCfg exposing []
import Tesl.Prelude exposing [String]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
entity Note table "notes" primaryKey id { id: String }
database DB = Database {
  schema: "app"
  entities: [Note]
  backend: Postgres (PostgresConfig {
    dbName: "app"
    user: "u"
    password: ""
    connection: TcpConnection { host: "127.0.0.1" port: 5432 }
  })
}
|} in
  assert_absent diags "W050"

let test_w050_genuinely_unused_import_still_flagged () =
  let diags = lint_src {|#lang tesl
module UnusedImp exposing []
import Tesl.Prelude exposing [String]
import Tesl.Set exposing [Set.insert]
fn f(s: String) -> String = s
|} in
  assert_has diags "W050"

let () =
  Alcotest.run "Linter" [
    "W050-config-usage-credited", [
      Alcotest.test_case "config-block names credited (no spurious W050)" `Quick
        test_w050_config_block_credits_used_imports;
      Alcotest.test_case "genuinely-unused import still flagged" `Quick
        test_w050_genuinely_unused_import_still_flagged;
    ];
    "W060-proof-decompose", [
      Alcotest.test_case "proof half not flagged as unused" `Quick
        test_w060_decompose_proof_half_not_unused;
      Alcotest.test_case "value half still flagged" `Quick
        test_w060_decompose_value_half_still_flagged;
      Alcotest.test_case "plain unused let still flagged" `Quick
        test_w060_plain_unused_let_still_flagged;
    ];
    "W063-redundant-recheck", [
      Alcotest.test_case "fires on same-checker re-check" `Quick
        test_w063_redundant_recheck_fires;
      Alcotest.test_case "distinct checkers quiet" `Quick
        test_w063_distinct_checkers_no_warning;
      Alcotest.test_case "same checker different values quiet" `Quick
        test_w063_same_checker_different_values_no_warning;
    ];
    "W064-discarded-validation", [
      Alcotest.test_case "fires on discarded check" `Quick
        test_w064_discarded_check_fires;
      Alcotest.test_case "keep-proof-half quiet" `Quick
        test_w064_keep_proof_half_no_warning;
      Alcotest.test_case "bound check quiet" `Quick
        test_w064_bound_check_no_warning;
    ];
    "proof-idioms-quiet", [
      Alcotest.test_case "detach/forget/attach roundtrip quiet" `Quick
        test_proof_roundtrip_no_footgun_warnings;
    ];
  ]
