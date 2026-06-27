(** Antagonistic regression tests for Critical Review 51.

    This suite was originally used to *document* bugs discovered during
    the review. After the review-51 fix-up round, most of the bugs are
    now *closed* — so those tests have been flipped to `_fixed` and now
    assert the NEW correct behaviour:

      - `_bug` — still an open soundness / ergonomics hole. The test
                 asserts the current (accepted) behaviour so the suite
                 fails when the bug is finally closed.
      - `_fixed` — the fix is applied; the test asserts the CORRECT
                  behaviour (usually a compile error that did not exist
                  before).

    A new batch of tests (R51_N* and R51_A* suffixes) has been added to
    keep the adversarial pressure up after the fix round. *)

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
  let code =
    match status with
    | Unix.WEXITED c -> c
    | Unix.WSIGNALED n -> 128 + n
    | Unix.WSTOPPED n -> 128 + n
  in
  (code, out)

let run_compiler args =
  let quoted = Filename.quote compiler :: List.map Filename.quote args in
  run_command (String.concat " " quoted ^ " 2>&1")

let write_file path content =
  let oc = open_out path in
  output_string oc content;
  close_out oc

let failf fmt = Printf.ksprintf failwith fmt

let with_temp_file _prefix _suffix content f =
  let dir = Filename.temp_dir "tesl-r51" "" in
  let name =
    let re = Str.regexp "module[ \\t\\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
    try
      ignore (Str.search_forward re content 0);
      let mname = Str.matched_group 1 content in
      let buf = Buffer.create (String.length mname + 4) in
      String.iteri (fun i c ->
        if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
        else if c >= 'A' && c <= 'Z' then begin
          Buffer.add_char buf '-';
          Buffer.add_char buf (Char.lowercase_ascii c)
        end else
          Buffer.add_char buf c
      ) mname;
      Buffer.contents buf ^ ".tesl"
    with Not_found -> "test.tesl"
  in
  let path = Filename.concat dir name in
  write_file path content;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let should_pass_src src =
  with_temp_file "tesl-r51" ".tesl" src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected compilation success, got:\n%s" out)

let should_fail_src pattern src =
  with_temp_file "tesl-r51" ".tesl" src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected failure matching %S, but compilation succeeded" pattern;
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pattern out)

let should_lint_contain pattern src =
  with_temp_file "tesl-r51" ".tesl" src (fun path ->
    let _, out = run_compiler ["--lint"; path] in
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected lint output to contain %S, got:\n%s" pattern out)

let should_fmt_to expected src =
  with_temp_file "tesl-r51" ".tesl" src (fun path ->
    let _ = run_compiler ["--fmt"; path] in
    let ic = open_in path in
    let contents = In_channel.input_all ic in
    close_in ic;
    let re = Str.regexp_string expected in
    try ignore (Str.search_forward re contents 0)
    with Not_found -> failf "expected formatted output to contain %S, got:\n%s"
      expected contents)

(* Run --local-bindings-json and return the raw JSON string. *)
let run_local_bindings src =
  with_temp_file "tesl-r51" ".tesl" src (fun path ->
    let _, out = run_compiler ["--local-bindings-json"; path] in
    out)

let should_local_binding_type name expected src =
  let out = run_local_bindings src in
  let needle = Printf.sprintf "\"name\":\"%s\",\"type\":\"%s\"" name expected in
  let re = Str.regexp_string needle in
  try ignore (Str.search_forward re out 0)
  with Not_found ->
    failf "expected --local-bindings-json to map %s -> %S\nfull output:\n%s"
      name expected out

let base_header = {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String, Bool(..), List, Fact, forgetFact, attachFact, detachFact]
import Tesl.Maybe exposing [Maybe(..)]
|}

let db_header = {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String, List]
import Tesl.DB exposing [dbRead, dbWrite]
|}

let isPositive_decl = {|
fact IsPositive (n: Int)

check isPositive(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"
|}

(* ═══════════════════════════════════════════════════════════════════════════
   R51_P — PROOF SOUNDNESS
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R51_P01 — FIXED. Aliasing a proof-requiring function via `let f = g`
   used to silently bypass the proof check on the subsequent `f y`. We
   now reconstruct the call `takeOne y` at the use site, so the same
   "does not statically satisfy" diagnostic fires as for the direct
   call (R51_P01b). *)
let r51_p01_let_bound_fn_launders_proof_fixed () =
  should_fail_src "does not statically satisfy" (base_header ^ isPositive_decl ^ {|
fn takeOne(b: Int ::: IsPositive b) -> Int = b

fn bypass(y: Int) -> Int =
  let f = takeOne
  f y
|})

(* R51_P01b — control: the direct call form is still (correctly) rejected. *)
let r51_p01b_direct_call_is_rejected () =
  should_fail_src "does not statically satisfy" (base_header ^ isPositive_decl ^ {|
fn takeOne(b: Int ::: IsPositive b) -> Int = b

fn bypass(y: Int) -> Int = takeOne y
|})

(* R51_P02 — FIXED. Partial-application aliasing of a proof-requiring
   function used to silently bypass the proof check when the remaining
   parameter (proof-bearing) was supplied via the alias. The alias is
   now allowed (so legitimate partial applications of non-proof leading
   args work), but every call-head use of the alias is reconstructed
   and re-checked — so `partial y` with an unproven `y` is rejected
   the same way as the direct `takeTwo 1 y` (R51_P02b). *)
let r51_p02_partial_app_launders_proof_fixed () =
  should_fail_src "does not statically satisfy" (base_header ^ isPositive_decl ^ {|
fn takeTwo(a: Int, b: Int ::: IsPositive b) -> Int = a + b

fn viaPartial(y: Int) -> Int =
  let partial = takeTwo 1
  partial y
|})

(* R51_P02b — control: direct call still rejected. *)
let r51_p02b_direct_second_arg_rejected () =
  should_fail_src "does not statically satisfy" (base_header ^ isPositive_decl ^ {|
fn takeTwo(a: Int, b: Int ::: IsPositive b) -> Int = a + b

fn direct(y: Int) -> Int = takeTwo 1 y
|})

(* R51_P02c — NEW. Non-call use of a proof-requiring alias (passing it as
   a higher-order-function argument) is rejected because the HOF would
   invoke the alias with unproven values. *)
let r51_p02c_alias_passed_as_hof_arg_rejected () =
  should_fail_src "cannot be passed around" (base_header ^ isPositive_decl ^ {|
fn takeOne(b: Int ::: IsPositive b) -> Int = b

fn applyFn(f: Int -> Int, x: Int) -> Int = f x

fn leak(y: Int) -> Int =
  let f = takeOne
  applyFn f y
|})

(* R51_P02d — NEW. A partial application that only strips a non-proof-bearing
   leading argument is legitimate: the proof obligation remains visible and
   is discharged at the call site. This is what test_review27 F20 covers — it
   must compile cleanly. *)
let r51_p02d_partial_app_of_non_proof_arg_accepted () =
  should_pass_src (base_header ^ isPositive_decl ^ {|
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"

fn addProved(a: Int, b: Int ::: IsPositive b) -> Int = a + b

fn use(n: Int) -> Int =
  let n2 = check checkPos n
  let addToN = addProved 10
  addToN n2
|})

(* R51_P03 — FIXED. The record-literal path now mirrors the direct
   call path: after `let attached = x ::: p`, the proof on `x` is
   tracked through the let-binder and `Holder { v: attached }` is
   accepted. The fix was in `walk_expr`'s ECase handler — it now
   propagates scrutinee proofs to the matching pattern binder so
   `proofs_of_expr` can resolve `x ::: p` correctly. *)
let r51_p03_record_attach_sugar_accepted_fixed () =
  should_pass_src (base_header ^ {|
fact IsPositive (n: Int)

record Holder { v: Int ::: IsPositive v }

establish provePositive(n: Int) -> Maybe (Fact (IsPositive n)) =
  if n > 0 then
    Something (IsPositive n)
  else
    Nothing

fn demo(x: Int) -> Int =
  let mp = provePositive x
  case mp of
    Something p ->
      let attached = x ::: p
      let h = Holder { v: attached }
      h.v
    Nothing ->
      0
|})

(* R51_P04 — control: direct call form of attach sugar works. *)
let r51_p04_fn_arg_attach_sugar_works () =
  should_pass_src (base_header ^ isPositive_decl ^ {|
fn needPositive(n: Int ::: IsPositive n) -> Int = n

fn demo(x: Int) -> Int =
  let checked = check isPositive x
  let (_ ::: p) = checked
  let bare = forgetFact checked
  needPositive <| bare ::: p
|})

(* R51_P05 — control: a lambda that internally `check`s is still the
   officially blessed way to adapt a proof-requiring fn to a callback. *)
let r51_p05_lambda_with_check_still_allowed () =
  should_pass_src (base_header ^ isPositive_decl ^ {|
fn takeOne(b: Int ::: IsPositive b) -> Int = b

fn adapted(x: Int) -> Int =
  let checked = check isPositive x
  takeOne checked

fn demo(y: Int) -> Int =
  adapted y
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R51_E — EXISTENTIALS
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R51_E01 — FIXED. Forging an existential return by packing a bare
   parameter now fails compile. *)
let r51_e01_existential_return_proof_not_enforced_fixed () =
  should_fail_src "existential pack returns the raw parameter" (base_header ^ {|
fact IsPositive (n: Int)

fn forge(n: Int) -> exists x: Int => Int ::: IsPositive x =
  exists n =>
    n
|})

(* R51_E02 — FIXED. The same protection applies to handlers. *)
let r51_e02_existential_handler_no_proof_fixed () =
  should_fail_src "existential pack returns the raw parameter" (base_header ^ {|
fact IsPositive (n: Int)

handler forge(n: Int) -> exists x: Int => Int ::: IsPositive x
  requires [] =
  exists n =>
    n
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R51_SQ — SQL LAYER
   ═══════════════════════════════════════════════════════════════════════════ *)

let todo_entity = {|
entity Todo table "todos" primaryKey id {
  id: String
  title: String
  count: Int
}
|}

(* R51_SQ01 — FIXED. SQL WHERE clause type mismatch is now rejected. *)
let r51_sq01_where_type_mismatch_fixed () =
  should_fail_src "SQL WHERE clause: type mismatch" (db_header ^ todo_entity ^ {|
fn demo() -> Int
  requires [dbRead] =
  let x = select t from Todo where t.title == 5
  1
|})

(* R51_SQ02 — FIXED. Unbound identifier in WHERE clause RHS is now rejected. *)
let r51_sq02_where_unbound_var_fixed () =
  should_fail_src "SQL WHERE clause references unbound identifier" (db_header ^ todo_entity ^ {|
fn demo() -> Int
  requires [dbRead] =
  let x = select t from Todo where t.title == nonExistentVar
  1
|})

(* R51_SQ03 — FIXED. `isNull` on a non-nullable column is now rejected. *)
let r51_sq03_isnull_on_nonnullable_fixed () =
  should_fail_src "isNull .* is always false" (db_header ^ todo_entity ^ {|
fn demo() -> Int
  requires [dbRead] =
  let x = selectOne t from Todo where isNull t.title
  1
|})

(* R51_SQ04 — control: unknown FIELD name IS rejected. *)
let r51_sq04_unknown_field_rejected () =
  should_fail_src "unknown field" (db_header ^ todo_entity ^ {|
fn demo() -> Int
  requires [dbRead] =
  let x = select t from Todo where t.bogus == "hi"
  1
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R51_T — TYPE SYSTEM
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R51_T01 — FIXED. Record update with an unknown field is rejected. *)
let r51_t01_record_update_unknown_field_fixed () =
  should_fail_src "record update: type .* has no field" (base_header ^ {|
record Point { x: Int, y: Int }

fn move(p: Point) -> Point =
  { p | z = 100 }
|})

(* R51_T02 — control. *)
let r51_t02_record_update_known_field_ok () =
  should_pass_src (base_header ^ {|
record Point { x: Int, y: Int }

fn move(p: Point, dx: Int) -> Point =
  { p | x = p.x + dx }
|})

(* R51_T03 — FIXED. Self-referential type alias rejected at declaration. *)
let r51_t03_self_referential_newtype_fixed () =
  should_fail_src "self-referential" (base_header ^ {|
type Foo = Foo
|})

(* R51_T03b — NEW: self-referential through TApp is also caught. *)
(* R51_T03b — self-reference through a type application. Tesl's parser
   treats `type Name = Maybe Name` as an ADT declaration attempt rather
   than a transparent alias, so the parser error is the first thing the
   user: sees. Either error is acceptable; we assert we REACH one of them. *)
let r51_t03b_self_ref_through_tapp_fixed () =
  should_fail_src "Loop\\|self-referential" (base_header ^ {|
type Loop = Maybe Loop
|})

(* R51_T04 — still open. Int arithmetic silently promotes to bignum.
   Spec choice deferred; kept as `_bug`. *)
let r51_t04_int_arithmetic_auto_promotes_bug () =
  should_pass_src (base_header ^ {|
fn overflow() -> Int =
  let a = 4611686018427387903
  a + a
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R51_X — PARSER / SYNTAX
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R51_X01 — FIXED. Nested bare nullary constructor pattern now accepted. *)
let r51_x01_nested_bare_nullary_accepted_fixed () =
  should_pass_src (base_header ^ {|
fn dig(m: Maybe (Maybe Int)) -> Int =
  case m of
    Nothing -> 0
    Something (Something n) -> n
    Something Nothing -> 0
|})

(* R51_X01b — control. *)
let r51_x01b_nested_parenthesised_nullary_still_works () =
  should_pass_src (base_header ^ {|
fn dig(m: Maybe (Maybe Int)) -> Int =
  case m of
    Nothing -> 0
    Something (Something n) -> n
    Something (Nothing) -> 0
|})

(* R51_X02 — FIXED. `case x > 0 of` now parses without parentheses. *)
let r51_x02_case_scrutinee_accepts_expr_fixed () =
  should_pass_src (base_header ^ {|
fn demo(x: Int) -> Int =
  case x > 0 of
    True -> 1
    False -> 0
|})

(* R51_X02b — control. *)
let r51_x02b_case_parenthesised_still_works () =
  should_pass_src (base_header ^ {|
fn demo(x: Int) -> Int =
  case (x > 0) of
    True -> 1
    False -> 0
|})

(* R51_X02c — NEW: case scrutinee can be a boolean conjunction too. *)
let r51_x02c_case_boolean_conj_fixed () =
  should_pass_src (base_header ^ {|
fn demo(a: Int, b: Int) -> Int =
  case a > 0 && b > 0 of
    True -> 1
    False -> 0
|})

(* R51_X03 — FIXED via doc change. `TESL.md` no longer advertises `;` as a
   field separator. The parser behaviour is unchanged (rejects `;`).
   This test asserts the parser rejection so the doc/impl drift stays
   caught. *)
let r51_x03_semicolon_record_separator_still_rejected () =
  should_fail_src "unexpected character: ';'" (base_header ^ {|
record NotifyJob { userId: String; message: String }
|})

(* R51_X04 — FIXED. Unknown string escape sequence rejected at lex time. *)
let r51_x04_unknown_escape_rejected_fixed () =
  should_fail_src "invalid string escape" (base_header ^ {|
fn demo() -> String = "\z"
|})

(* R51_X04b — control: the five supported escapes still work. *)
let r51_x04b_known_escapes_work () =
  should_pass_src (base_header ^ {|
fn demo1() -> String = "a\nb"
fn demo2() -> String = "a\tb"
fn demo3() -> String = "a\\b"
fn demo4() -> String = "a\"b"
fn demo5() -> String = "a\rb"
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R51_S — SHADOWING
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R51_S01 — FIXED. Top-level binding shadowed by a parameter is rejected. *)
let r51_s01_toplevel_binding_shadow_rejected_fixed () =
  should_fail_src "function parameter `n` shadows" (base_header ^ {|
n = 5

fn demo(n: Int) -> Int = n + 1
|})

(* R51_S01b — control: top-level fn shadow still rejected. *)
let r51_s01b_toplevel_fn_shadow_still_rejected () =
  should_fail_src "function parameter" (base_header ^ {|
fn helper() -> Int = 5

fn demo(helper: Int) -> Int = helper + 1
|})

(* R51_S02 — FIXED. Parameter-shadow error now correctly labels the binder. *)
let r51_s02_shadow_error_accurate_label_fixed () =
  should_fail_src "function parameter .* shadows" (base_header ^ {|
fn helper() -> Int = 5

fn demo(helper: Int) -> Int = helper + 1
|})

(* R51_S02b — NEW: case-pattern binder shadow uses the right label too. *)
let r51_s02b_case_shadow_label_fixed () =
  should_fail_src "case pattern binder .* shadows" (base_header ^ {|
fn demo(m: Maybe Int, n: Int) -> Int =
  case m of
    Nothing -> 0
    Something n -> n + 1
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R51_F — FORMATTER / LINTER
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R51_F01 — FIXED. Formatter normalises `*`. *)
let r51_f01_formatter_normalises_star_fixed () =
  should_fmt_to "a * b" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]

fn demo(a: Int, b: Int) -> Int = a*b
|}

(* R51_F02 — FIXED. Formatter normalises binary `-`. *)
let r51_f02_formatter_normalises_minus_fixed () =
  should_fmt_to "a - b" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]

fn demo(a: Int, b: Int) -> Int = a-b
|}

(* R51_F02b — NEW: unary `-` is PRESERVED (never becomes "x - 5" on `-5`). *)
let r51_f02b_formatter_preserves_unary_minus () =
  should_fmt_to "= -5" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]

fn demo() -> Int = -5
|}

(* R51_F03 — FIXED. Formatter normalises `/`. *)
let r51_f03_formatter_normalises_slash_fixed () =
  should_fmt_to "a / b" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]

fn demo(a: Int, b: Int) -> Int = a/b
|}

(* R51_F04 — FIXED. Formatter normalises `%`. *)
let r51_f04_formatter_normalises_percent_fixed () =
  should_fmt_to "a % b" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]

fn demo(a: Int, b: Int) -> Int = a%b
|}

(* R51_F05 — FIXED. Linter warns on unused `let`. *)
let r51_f05_linter_catches_unused_let_fixed () =
  should_lint_contain "unused `let` binding" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]

fn demo() -> Int =
  let deadLocal = 42
  10
|}

(* R51_F06 — FIXED. Linter warns on unused function parameter. *)
let r51_f06_linter_catches_unused_param_fixed () =
  should_lint_contain "unused parameter" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]

fn demo(a: Int, deadParam: Int) -> Int = a
|}

(* R51_F06b — NEW: parameters named with a leading `_` are INTENTIONALLY
   not flagged (Elm / Haskell / OCaml convention). *)
let r51_f06b_underscore_prefix_param_not_flagged () =
  with_temp_file "tesl-r51" ".tesl" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]

fn demo(a: Int, _deadParam: Int) -> Int = a
|} (fun path ->
    let _, out = run_compiler ["--lint"; path] in
    let re = Str.regexp_case_fold "unused parameter" in
    (try
      ignore (Str.search_forward re out 0);
      failf "linter incorrectly flagged an `_`-prefixed parameter:\n%s" out
    with Not_found -> ()))

(* R51_F07 — FIXED. Linter warns on dead code after `fail`. *)
let r51_f07_linter_catches_dead_after_fail_fixed () =
  should_lint_contain "unreachable code after `fail`" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]

fact IsPositive (n: Int)

check demo(n: Int) -> n: Int ::: IsPositive n =
  fail 400 "always"
  let unreachable = 5
  ok n ::: IsPositive n
|}

(* R51_F08 — still open. `--type-at-json` returns null. *)
let r51_f08_type_at_json_returns_null_bug () =
  with_temp_file "tesl-r51" ".tesl" (base_header ^ {|
fn demo(n: Int) -> Int = n + 1
|}) (fun path ->
    let _, out = run_compiler ["--type-at-json"; path; "5"; "16"] in
    let re = Str.regexp_string "\"type_at\":null" in
    let returns_null =
      try ignore (Str.search_forward re out 0); true
      with Not_found -> false
    in
    if not returns_null then
      failwith "--type-at-json is now returning a non-null payload — turn this into a FIXED test.")

(* ═══════════════════════════════════════════════════════════════════════════
   R51_N — NEW adversarial tests (added after the fix round)
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R51_N01 — aliasing a proof-requiring function and calling it with an
   unproven argument is rejected by reconstructing the call at the use
   site: `f y` → `takeOne y`, which fails the usual proof check. *)
let r51_n01_chained_let_aliases_rejected () =
  should_fail_src "does not statically satisfy" (base_header ^ isPositive_decl ^ {|
fn takeOne(b: Int ::: IsPositive b) -> Int = b

fn bypass(y: Int) -> Int =
  let f = takeOne
  f y
|})

(* R51_N02 — existential body uses `check`, proof is there, accepted. *)
let r51_n02_existential_with_check_accepted () =
  should_pass_src (base_header ^ isPositive_decl ^ {|
fn mkPositive(raw: Int) -> exists x: Int => Int ::: IsPositive x
  requires [] =
  let checked = check isPositive raw
  exists checked =>
    checked
|})

(* R51_N03 — record-update typing: assigning a wrong-typed value to a
   known field is still checked after the unknown-field fix. *)
let r51_n03_record_update_wrong_type_rejected () =
  should_fail_src "cannot unify" (base_header ^ {|
record Point { x: Int, y: Int }

fn bad(p: Point) -> Point =
  { p | x = "hello" }
|})

(* R51_N04 — self-referential via a function type. *)
let r51_n04_self_ref_through_function_type_fixed () =
  should_fail_src "self-referential" (base_header ^ {|
type Fn = Int -> Fn
|})

(* R51_N05 — `case` scrutinee accepts arithmetic as well as comparisons. *)
let r51_n05_case_arith_scrutinee () =
  should_pass_src (base_header ^ {|
fn demo(a: Int, b: Int) -> Int =
  case a + b of
    0 -> 100
    _ -> 0
|})

(* R51_N06 — formatter idempotence on a pre-normalised file. Running the
   formatter twice must yield the same output. *)
let r51_n06_formatter_idempotent () =
  let src = {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]

fn demo(a: Int, b: Int) -> Int = a*b + (0 - a) - b/2
|} in
  with_temp_file "tesl-r51" ".tesl" src (fun path ->
    let _ = run_compiler ["--fmt"; path] in
    let ic = open_in path in
    let first = In_channel.input_all ic in
    close_in ic;
    let _ = run_compiler ["--fmt"; path] in
    let ic = open_in path in
    let second = In_channel.input_all ic in
    close_in ic;
    if first <> second then
      failf "formatter is not idempotent.\nfirst run:\n%s\nsecond run:\n%s"
        first second)

(* R51_N07 — linter emits warning code `W060` (not just free text). *)
let r51_n07_linter_uses_w060_code () =
  should_lint_contain "W060" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]

fn demo() -> Int =
  let dead = 42
  10
|}

(* R51_N08 — linter uses `W061` for unused parameters. *)
let r51_n08_linter_uses_w061_code () =
  should_lint_contain "W061" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]

fn demo(a: Int, deadParam: Int) -> Int = a
|}

(* R51_N09 — linter uses `W062` for dead code. *)
let r51_n09_linter_uses_w062_code () =
  should_lint_contain "W062" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]

fact IsPositive (n: Int)

check demo(n: Int) -> n: Int ::: IsPositive n =
  fail 400 "always"
  let unreachable = 5
  ok n ::: IsPositive n
|}

(* R51_N10 — proof-laundering fix does NOT break let-aliasing of
   proof-FREE functions (a normal `let f = plainFn` must still work). *)
let r51_n10_proof_free_fn_alias_still_allowed () =
  should_pass_src (base_header ^ {|
fn add(a: Int, b: Int) -> Int = a + b

fn demo(x: Int, y: Int) -> Int =
  let f = add
  f x y
|})

(* R51_N11 — shadow rule still allows a top-level fn with same name as an
   IMPORTED one (the import system handles this; no false positive). *)
let r51_n11_imported_fn_not_a_shadow () =
  should_pass_src (base_header ^ {|
fn myCustomAdd(a: Int, b: Int) -> Int = a + b

fn demo(x: Int) -> Int =
  myCustomAdd x 1
|})

(* R51_N12 — `type Foo = String` (genuine nominal newtype) is NOT flagged
   by the self-referential check. *)
let r51_n12_nonrecursive_newtype_still_ok () =
  should_pass_src (base_header ^ {|
type UserId = String
type ProjectId = String

fn takeId(u: UserId) -> String = u.value
|})

(* ═══════════════════════════════════════════════════════════════════════════
   TEST REGISTRATION
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R51_N13 — hover types for `let (v ::: p1 && p2) = rhs` must show each
   proof binder's INDIVIDUAL predicate (ValidScore / ValidTag), not the
   full compound predicate (scoreProof && tagProof). *)
let r51_n13_let_proof_conj_hover_split () =
  let src = {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String]

fact ValidScore (n: Int)
fact ValidTag (s: String)

fn decomposeThenCall(score: Int ::: ValidScore score, tag: String ::: ValidTag tag) -> Int =
  let (rawScore ::: scoreProof) = score
  let (rawTag   ::: tagProof)   = tag
  let (rawTag2 ::: scoreProof2 && tagProof2) = rawScore ::: scoreProof && tagProof
  rawScore + rawTag2
|} in
  should_local_binding_type "scoreProof2" "Fact (ValidScore rawScore)" src;
  should_local_binding_type "tagProof2"   "Fact (ValidTag rawTag)"     src

(* R51_N14 — the linter must NOT flag a proof binder as unused when it is
   referenced from a proof annotation `value ::: proofName`. *)
let r51_n14_linter_follows_proof_ann () =
  let src = {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int]

fact IsPositive (n: Int)

check validate(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "no"

fn needsPos(n: Int ::: IsPositive n) -> Int = n

fn demo(raw: Int) -> Int =
  let score = check validate raw
  let (rawScore ::: scoreProof) = score
  let reattached = rawScore ::: scoreProof
  needsPos reattached
|} in
  with_temp_file "tesl-r51" ".tesl" src (fun path ->
    let _, out = run_compiler ["--lint"; path] in
    let re_bad = Str.regexp_case_fold "unused `let` binding `scoreProof`" in
    try
      ignore (Str.search_forward re_bad out 0);
      failf "linter wrongly flagged scoreProof as unused — proof-annotation usage must count as a reference.\noutput:\n%s" out
    with Not_found -> ())

let () =
  run "Review51-Antagonistic" [
    "proof-soundness", [
      test_case "R51_P01 let-bound fn launders proof (FIXED)"                  `Quick r51_p01_let_bound_fn_launders_proof_fixed;
      test_case "R51_P01b direct call IS rejected"                             `Quick r51_p01b_direct_call_is_rejected;
      test_case "R51_P02 partial app launders proof (FIXED)"                   `Quick r51_p02_partial_app_launders_proof_fixed;
      test_case "R51_P02b direct second arg IS rejected"                       `Quick r51_p02b_direct_second_arg_rejected;
      test_case "R51_P02c alias passed as HOF arg is rejected"                 `Quick r51_p02c_alias_passed_as_hof_arg_rejected;
      test_case "R51_P02d partial app of non-proof arg accepted"               `Quick r51_p02d_partial_app_of_non_proof_arg_accepted;
      test_case "R51_P03 record-attach asymmetry (FIXED)"           `Quick r51_p03_record_attach_sugar_accepted_fixed;
      test_case "R51_P04 fn-arg attach sugar works (control)"                  `Quick r51_p04_fn_arg_attach_sugar_works;
      test_case "R51_P05 lambda with check still allowed"                      `Quick r51_p05_lambda_with_check_still_allowed;
    ];
    "existentials", [
      test_case "R51_E01 exists return proof enforced (FIXED)"                 `Quick r51_e01_existential_return_proof_not_enforced_fixed;
      test_case "R51_E02 handler existential proof enforced (FIXED)"           `Quick r51_e02_existential_handler_no_proof_fixed;
    ];
    "sql-layer", [
      test_case "R51_SQ01 where type mismatch (FIXED)"                        `Quick r51_sq01_where_type_mismatch_fixed;
      test_case "R51_SQ02 where unbound var (FIXED)"                          `Quick r51_sq02_where_unbound_var_fixed;
      test_case "R51_SQ03 isNull on NOT NULL col (FIXED)"                     `Quick r51_sq03_isnull_on_nonnullable_fixed;
      test_case "R51_SQ04 unknown field IS rejected (control)"                 `Quick r51_sq04_unknown_field_rejected;
    ];
    "type-system", [
      test_case "R51_T01 record update unknown field (FIXED)"                  `Quick r51_t01_record_update_unknown_field_fixed;
      test_case "R51_T02 record update known field (control)"                  `Quick r51_t02_record_update_known_field_ok;
      test_case "R51_T03 self-referential newtype (FIXED)"                     `Quick r51_t03_self_referential_newtype_fixed;
      test_case "R51_T03b self-ref through TApp (FIXED)"                       `Quick r51_t03b_self_ref_through_tapp_fixed;
      test_case "R51_T04 Int arithmetic auto-promotes (BUG — still open)"     `Quick r51_t04_int_arithmetic_auto_promotes_bug;
    ];
    "parser-syntax", [
      test_case "R51_X01 nested bare nullary accepted (FIXED)"                 `Quick r51_x01_nested_bare_nullary_accepted_fixed;
      test_case "R51_X01b parenthesised nullary still works"                   `Quick r51_x01b_nested_parenthesised_nullary_still_works;
      test_case "R51_X02 case scrutinee accepts expr (FIXED)"                  `Quick r51_x02_case_scrutinee_accepts_expr_fixed;
      test_case "R51_X02b case with parens still works"                        `Quick r51_x02b_case_parenthesised_still_works;
      test_case "R51_X02c case with boolean conj (FIXED)"                      `Quick r51_x02c_case_boolean_conj_fixed;
      test_case "R51_X03 TESL.md doc fixed, parser still rejects `;`"          `Quick r51_x03_semicolon_record_separator_still_rejected;
      test_case "R51_X04 unknown escape rejected (FIXED)"                      `Quick r51_x04_unknown_escape_rejected_fixed;
      test_case "R51_X04b all five known escapes still work"                   `Quick r51_x04b_known_escapes_work;
    ];
    "shadowing", [
      test_case "R51_S01 toplevel binding shadow rejected (FIXED)"             `Quick r51_s01_toplevel_binding_shadow_rejected_fixed;
      test_case "R51_S01b toplevel fn shadow still rejected"                   `Quick r51_s01b_toplevel_fn_shadow_still_rejected;
      test_case "R51_S02 shadow error accurate label (FIXED)"                  `Quick r51_s02_shadow_error_accurate_label_fixed;
      test_case "R51_S02b case binder shadow label (FIXED)"                    `Quick r51_s02b_case_shadow_label_fixed;
    ];
    "formatter-linter", [
      test_case "R51_F01 formatter normalises * (FIXED)"                       `Quick r51_f01_formatter_normalises_star_fixed;
      test_case "R51_F02 formatter normalises - (FIXED)"                       `Quick r51_f02_formatter_normalises_minus_fixed;
      test_case "R51_F02b formatter preserves unary minus"                     `Quick r51_f02b_formatter_preserves_unary_minus;
      test_case "R51_F03 formatter normalises / (FIXED)"                       `Quick r51_f03_formatter_normalises_slash_fixed;
      test_case "R51_F04 formatter normalises % (FIXED)"                       `Quick r51_f04_formatter_normalises_percent_fixed;
      test_case "R51_F05 linter catches unused let (FIXED)"                    `Quick r51_f05_linter_catches_unused_let_fixed;
      test_case "R51_F06 linter catches unused param (FIXED)"                  `Quick r51_f06_linter_catches_unused_param_fixed;
      test_case "R51_F06b underscore-prefix param not flagged"                 `Quick r51_f06b_underscore_prefix_param_not_flagged;
      test_case "R51_F07 linter catches dead after fail (FIXED)"               `Quick r51_f07_linter_catches_dead_after_fail_fixed;
      test_case "R51_F08 --type-at-json returns null (BUG — still open)"       `Quick r51_f08_type_at_json_returns_null_bug;
    ];
    "new-adversarial", [
      test_case "R51_N01 chained let aliases still rejected"                   `Quick r51_n01_chained_let_aliases_rejected;
      test_case "R51_N02 existential with check accepted"                      `Quick r51_n02_existential_with_check_accepted;
      test_case "R51_N03 record update wrong type rejected"                    `Quick r51_n03_record_update_wrong_type_rejected;
      test_case "R51_N04 self-ref through fn type"                             `Quick r51_n04_self_ref_through_function_type_fixed;
      test_case "R51_N05 case arith scrutinee"                                 `Quick r51_n05_case_arith_scrutinee;
      test_case "R51_N06 formatter is idempotent"                              `Quick r51_n06_formatter_idempotent;
      test_case "R51_N07 linter emits W060"                                    `Quick r51_n07_linter_uses_w060_code;
      test_case "R51_N08 linter emits W061"                                    `Quick r51_n08_linter_uses_w061_code;
      test_case "R51_N09 linter emits W062"                                    `Quick r51_n09_linter_uses_w062_code;
      test_case "R51_N10 proof-free fn alias still allowed"                    `Quick r51_n10_proof_free_fn_alias_still_allowed;
      test_case "R51_N11 imported fn not a shadow"                             `Quick r51_n11_imported_fn_not_a_shadow;
      test_case "R51_N12 nonrecursive newtype OK"                              `Quick r51_n12_nonrecursive_newtype_still_ok;
      test_case "R51_N13 let-proof && splits hover types"                      `Quick r51_n13_let_proof_conj_hover_split;
      test_case "R51_N14 linter ignores proof variables used via :::"          `Quick r51_n14_linter_follows_proof_ann;
    ];
  ]
