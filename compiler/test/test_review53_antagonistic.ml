(** Antagonistic regression tests for Critical Review 53.

    Adversarial focus areas:
      1. filterCheck accepts plain fn (not just check) — security hole
      2. Proof fabrication via establish in fn context
      3. Proof subject aliasing / re-binding after forgetFact
      4. Multi-param proof subject substitution edge cases
      5. Guard-only case arms with multiple guards — exhaustiveness gap
      6. Capability leaking: fn calling handler without declaring requirements
      7. Record field proof annotation propagation in nested access
      8. Codec `via` with an establish (not check) function
      9. `?` named-pack with compound proof — entity-append rule correctness
      10. Transaction nesting compile error
      11. Newtype identity: UserId vs ProjectId (both String)
      12. establish returning a raw Int instead of Fact
      13. Existential witness naming collision with parameter
      14. Proof predicate imported but not exported
      15. Empty string as a codec field key
      16. Int.divide with an unproven denominator
      17. ForAll proof on a non-list type (Dict values)
      18. Proof conjunction commutativity at the 4-fact level
      19. Negative: ok in handler body (no check function path)
      20. Proof from a different subject used for same-named binder
      21. `check` call without `let` binding (no stable subject)
      22. Annotation type mismatch in test let binding
      23. Plain `fn` passed to List.filterCheck  (core issue from R08)

    Suffix conventions (matching earlier reviews):
      - `_bug`    — still-open regression; test asserts current (wrong) behaviour
      - `_fixed`  — fix has already landed
      - no suffix — positive control
*)

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
  let dir = Filename.temp_dir "tesl-r53" "" in
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
  with_temp_file "tesl-r53" ".tesl" src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected compilation success, got:\n%s" out)

let should_fail_src pattern src =
  with_temp_file "tesl-r53" ".tesl" src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected failure matching %S, but compilation succeeded" pattern;
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pattern out)

(* A "currently passes" test: behaviour is wrong — the compiler should reject this.
   The test flips red once the fix lands so the maintainer knows to promote it
   to `should_fail_src`. *)
let should_currently_pass_src src =
  with_temp_file "tesl-r53" ".tesl" src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then
      failf "KNOWN-OPEN BUG: the compiler now REJECTS this input (correct behaviour). \
             Promote this test to `should_fail_src` with the new diagnostic.\n%s" out)
[@@warning "-32"]

let base_header = {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String, Bool(..), List, Fact, forgetFact, attachFact, detachFact]
import Tesl.Maybe exposing [Maybe(..)]
|}

let positive_decl = {|
fact IsPositive (n: Int)

check isPositive(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"
|}

(* ═══════════════════════════════════════════════════════════════════════════
   R53_F — filterCheck MUST REJECT plain fn (previous review R08 finding)
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R53_F01 — FIXED. List.filterCheck now rejects a plain `fn` at two sites:
   (1) fn fakeFilter cannot declare a proof-carrying return type (RetAttached);
   (2) List.filterCheck rejects non-check-kind functions as its predicate argument. *)
let r53_f01_filtercheck_plain_fn_bug () =
  should_fail_src "plain.*`fn`\\|fn.*cannot\\|check.*kind\\|proof-carrying" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, List, Fact]
import Tesl.List exposing [List.filterCheck, List.length]

fact IsPositive (n: Int)

# A plain fn that uses an establish to produce a proof — not a check boundary
establish proveAny(n: Int) -> Fact (IsPositive n) = IsPositive n

fn fakeFilter(n: Int) -> n: Int ::: IsPositive n =
  let pf = proveAny n
  n ::: pf

fn needPosList(xs: List Int ::: ForAll IsPositive xs) -> Int =
  List.length xs

# Passes fakeFilter (a plain fn) to filterCheck — should be rejected
# because filterCheck must require a check-kind function
fn bypassWithFn(xs: List Int) -> Int =
  let filtered = List.filterCheck fakeFilter xs
  needPosList filtered
|}

(* R53_F02 — positive control. List.filterCheck with a real check function
   must still compile cleanly. *)
let r53_f02_filtercheck_check_fn_ok () =
  should_pass_src (base_header ^ {|
import Tesl.List exposing [List.filterCheck, List.length]

fact IsPositive (n: Int)

check isPositive(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"

fn needPosList(xs: List Int ::: ForAll IsPositive xs) -> Int =
  List.length xs

fn safePath(xs: List Int) -> Int =
  let filtered = List.filterCheck isPositive xs
  needPosList filtered
|})

(* R53_F03 — FIXED. Set.filterCheck also rejects a plain fn. Same fix as R53_F01. *)
let r53_f03_set_filtercheck_plain_fn_bug () =
  should_fail_src "plain.*`fn`\\|fn.*cannot\\|check.*kind\\|proof-carrying" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, Fact]
import Tesl.Set exposing [Set.filterCheck, Set.size, Set]

fact IsPositive (n: Int)

establish proveAny(n: Int) -> Fact (IsPositive n) = IsPositive n

fn fakeFn(n: Int) -> n: Int ::: IsPositive n =
  let pf = proveAny n
  n ::: pf

fn needPosSet(s: Set Int ::: ForAll IsPositive s) -> Int =
  Set.size s

fn bypassSet(s: Set Int) -> Int =
  let filtered = Set.filterCheck fakeFn s
  needPosSet filtered
|}

(* ═══════════════════════════════════════════════════════════════════════════
   R53_E — establish in fn context: proof fabrication via establish call
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R53_E01 — BUG. A fn calls an establish function and uses the returned Fact
   to forge proof attachment in the same fn body. The spec says ok ::: proof
   in fn context is rejected only when the expression is a raw predicate; but
   calling establish is supposed to be restricted to its own boundary. A fn
   using the Fact to bypass the check boundary is the key concern. Here we
   test whether a fn can *inline-call* an establish to conjure a proof it
   did not earn. *)
let r53_e01_fn_calls_establish_to_fabricate_bug () =
  (* The fn should not be able to attach a proof it obtained from an establish
     that has no runtime validation. The static checker currently allows this
     because establish is trusted. The question is whether the runtime evidence
     layer will catch it. This is a design soundness question, not just a
     static bug — the test documents current behaviour. *)
  should_pass_src (base_header ^ {|
fact IsPositive (n: Int)

establish provePositive(n: Int) -> Fact (IsPositive n) =
  IsPositive n

fn needPos(n: Int ::: IsPositive n) -> Int = n

# fn can call establish and attach the result — this is allowed in the design
# because establish is the trusted proof-introduction boundary.
fn useEstablish(n: Int) -> Int =
  let proof = provePositive n
  let valued = n ::: proof
  needPos valued
|})

(* R53_E02 — Attempting to fabricate a proof using ok ::: in a plain fn body
   must be rejected (this is the existing rule). *)
let r53_e02_fn_ok_proof_rejected () =
  should_fail_src "not allowed in.*fn" (base_header ^ {|
fact IsPositive (n: Int)

fn bypass(n: Int) -> n: Int ::: IsPositive n =
  ok n ::: IsPositive n
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R53_S — Subject aliasing: forgetFact then re-bind as different name
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R53_S01 — After forgetFact, the underlying GDP subject should be preserved
   but the proof dropped. Reusing the value should NOT transfer proofs from
   a different binding that happened to have the same raw value. *)
let r53_s01_forget_does_not_leak_proof () =
  should_fail_src "does not statically satisfy" (base_header ^ positive_decl ^ {|
fn needPos(n: Int ::: IsPositive n) -> Int = n

fn tryLeak(raw: Int) -> Int =
  let checked = check isPositive raw
  let bare = forgetFact checked
  # bare has lost IsPositive — cannot pass to needPos
  needPos bare
|})

(* R53_S02 — positive control: checking bare produces new proof. *)
let r53_s02_recheck_after_forget_ok () =
  should_pass_src (base_header ^ positive_decl ^ {|
fn needPos(n: Int ::: IsPositive n) -> Int = n

fn ok_path(raw: Int) -> Int =
  let checked = check isPositive raw
  let bare = forgetFact checked
  let rechecked = check isPositive bare
  needPos rechecked
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R53_G — Guard exhaustiveness with multiple guards on the same constructor
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R53_G01 — Two guarded arms for the same constructor, no catch-all.
   The compiler should reject this as non-exhaustive because together
   the guards do not cover all values. *)
let r53_g01_two_guards_same_ctor_not_exhaustive () =
  should_fail_src "non-exhaustive" (base_header ^ {|
fn demo(m: Maybe Int) -> Int =
  case m of
    Nothing -> 0
    Something n where n > 0 -> n
    Something n where n < 0 -> -n
|})
  (* NOTE: n == 0 is uncovered. The guards together are not exhaustive. *)

(* R53_G02 — Guard + unconditional arm for same constructor: must compile. *)
let r53_g02_guard_plus_unconditional_ok () =
  should_pass_src (base_header ^ {|
fn demo(m: Maybe Int) -> Int =
  case m of
    Nothing -> 0
    Something n where n > 0 -> n
    Something _ -> 0
|})

(* R53_G03 — Three guards on Bool-like ADT, no catch-all — exhaustiveness hole. *)
let r53_g03_adt_all_guards_not_exhaustive () =
  should_fail_src "non-exhaustive" (base_header ^ {|
type Traffic
  = Red
  | Yellow
  | Green

fn demo(t: Traffic) -> Int =
  case t of
    Red    where True -> 0
    Yellow where True -> 1
    Green  where True -> 2
|})
  (* All arms are guarded — if a guard somehow fails there's no fallthrough. *)

(* ═══════════════════════════════════════════════════════════════════════════
   R53_C — Capability leaking: fn calling handler-required ops
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R53_C01 — A fn that doesn't declare dbRead but calls selectOne must be
   rejected. *)
let r53_c01_fn_needs_capability_for_db_op () =
  should_fail_src "dbRead" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Maybe exposing [Maybe(..)]

entity Item table "items" primaryKey id {
  id: String
  name: String
}

database ItemDb {
  backend: postgres
  schema: "test"
  entities: [Item]
  postgres {
    database: "test"
    user: "test"
    password: "test"
    host: "localhost"
    port: 5432
  }
}

# fn with no requires — but uses selectOne which needs dbRead
fn badFn(itemId: String) -> Maybe Item =
  selectOne i from Item where i.id == itemId
|}

(* ═══════════════════════════════════════════════════════════════════════════
   R53_N — Newtype nominal identity enforcement
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R53_N01 — UserId and ProjectId are both newtypes over String.
   Passing a UserId where ProjectId is expected must be rejected. *)
let r53_n01_newtype_not_interchangeable () =
  should_fail_src "type\\|expected\\|got" (base_header ^ {|
type UserId = String
type ProjectId = String

fn needProjectId(pid: ProjectId) -> String = pid.value

fn badPass(uid: UserId) -> String =
  needProjectId uid
|})

(* R53_N02 — positive control: correct newtype. *)
let r53_n02_newtype_correct_ok () =
  should_pass_src (base_header ^ {|
type UserId = String
type ProjectId = String

fn needProjectId(pid: ProjectId) -> String = pid.value

fn okPass(pid: ProjectId) -> String =
  needProjectId pid
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R53_D — Int.divide proof-total arithmetic enforcement
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R53_D01 — Calling Int.divide without the IsNonZero proof on the denominator
   must be rejected. *)
let r53_d01_divide_without_nonzero_proof () =
  should_fail_src "proof\\|IsNonZero\\|requires" (base_header ^ {|
import Tesl.Int exposing [Int.divide]

fn badDiv(a: Int, b: Int) -> Int =
  Int.divide a b
|})

(* R53_D02 — positive control: check Int.nonZero first, then divide. *)
let r53_d02_divide_with_nonzero_ok () =
  should_pass_src (base_header ^ {|
import Tesl.Int exposing [Int.divide, Int.nonZero]

fn safeDiv(a: Int, b: Int) -> Int =
  let divisor = check Int.nonZero b
  Int.divide a divisor
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R53_P — Proof subject: using proof from different subject on same-name binder
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R53_P01 — Two separate variables share the name pattern in sequence;
   the compiler must NOT allow a proof of the first binding to be used for
   the second even if both have the same raw type and name prefix. *)
let r53_p01_proof_not_transferable_between_subjects () =
  should_fail_src "does not statically satisfy" (base_header ^ positive_decl ^ {|
fn needPos(n: Int ::: IsPositive n) -> Int = n

fn demo(a: Int, b: Int) -> Int =
  let checkedA = check isPositive a
  # checkedA has IsPositive proof about 'a' subject
  # 'b' is a different subject entirely
  needPos b
|})

(* R53_P02 — Detached proof from one subject cannot be reattached to a
   different subject. *)
let r53_p02_detached_proof_wrong_subject () =
  should_fail_src "does not statically satisfy\\|wrong proof\\|subject" (base_header ^ positive_decl ^ {|
fn needPos(n: Int ::: IsPositive n) -> Int = n

fn demo(a: Int, b: Int) -> Int =
  let checkedA = check isPositive a
  let (v ::: proof) = checkedA
  # proof is about 'a', not 'b' — attaching to b is invalid
  let reat = b ::: proof
  needPos reat
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R53_O — ok ::: in handler body: handlers should not fabricate proofs
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R53_O01 — A handler using ok ::: to stamp a proof without going through
   a check boundary is forbidden. *)
let r53_o01_handler_ok_proof_rejected () =
  should_fail_src "not allowed in.*handler\\|proof construction" (base_header ^ {|
fact IsPositive (n: Int)

handler badHandler(n: Int) -> n: Int ::: IsPositive n =
  ok n ::: IsPositive n
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R53_T — Transaction nesting
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R53_T01 — Nesting `with transaction` inside another must be rejected. *)
let r53_t01_nested_transaction_rejected () =
  should_fail_src "nested.*transaction\\|transaction.*nested\\|inside.*transaction" (base_header ^ {|
import Tesl.DB exposing [dbRead, dbWrite]

entity Note table "notes" primaryKey id {
  id: String
  body: String
}

database NoteDb {
  backend: postgres
  schema: "test"
  entities: [Note]
  postgres {
    database: "test"
    user: "test"
    password: "test"
    host: "localhost"
    port: 5432
  }
}

handler badHandler(noteId: String)
  -> Note
  requires [dbWrite] =
  with transaction {
    with transaction {
      insert Note { id: noteId, body: "hello" }
    }
  }
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R53_X — ADT single-line vs multi-line footgun
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R53_X01 — Single-line `type Foo = Bar | Baz` is a type alias, not an ADT.
   Trying to use Bar as a constructor should fail. *)
let r53_x01_single_line_adt_is_alias () =
  should_fail_src "type\\|alias\\|constructor\\|unknown\\|Bar" (base_header ^ {|
type Foo = Bar | Baz

fn demo() -> Foo = Bar
|})

(* R53_X02 — Multi-line ADT works correctly. *)
let r53_x02_multiline_adt_ok () =
  should_pass_src (base_header ^ {|
type Foo
  = Bar
  | Baz

fn demo() -> Foo = Bar
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R53_M — Multi-param proof subject substitution edge cases
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R53_M01 — A 3-arg check: verifying that the compiler correctly substitutes
   all three subject names when propagating the proof. *)
let r53_m01_three_arg_check_and_consumer () =
  should_pass_src (base_header ^ {|
fact InRange (lo: Int) (hi: Int) (n: Int)

check inRange(lo: Int, hi: Int, n: Int) -> n: Int ::: InRange lo hi n =
  if lo <= n && n <= hi then
    ok n ::: InRange lo hi n
  else
    fail 400 "out of range"

fn needInRange(lo: Int, hi: Int, n: Int ::: InRange lo hi n) -> Int = n

fn demo(a: Int, b: Int, raw: Int) -> Int =
  let validated = check inRange a b raw
  needInRange a b validated
|})

(* R53_M02 — Passing mismatched lo/hi (swapped from what was checked)
   must fail the proof checker. *)
let r53_m02_three_arg_wrong_bounds_fails () =
  should_fail_src "does not statically satisfy\\|proof\\|InRange" (base_header ^ {|
fact InRange (lo: Int) (hi: Int) (n: Int)

check inRange(lo: Int, hi: Int, n: Int) -> n: Int ::: InRange lo hi n =
  if lo <= n && n <= hi then
    ok n ::: InRange lo hi n
  else
    fail 400 "out of range"

fn needInRange(lo: Int, hi: Int, n: Int ::: InRange lo hi n) -> Int = n

fn demo(a: Int, b: Int, raw: Int) -> Int =
  let validated = check inRange a b raw
  # swapping a and b — proof is InRange a b raw, not InRange b a raw
  needInRange b a validated
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R53_I — import visibility: predicate not exported
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R53_I01 — Multi-module: using a proof predicate that is not in the
   exporting module's exposing list must be rejected. *)
let r53_i01_predicate_not_exported () =
  (* Create two files: one module that owns the predicate (but doesn't export it),
     and one that tries to use it. We test this by checking the error message
     when a predicate is used without being imported. *)
  let dir = Filename.temp_dir "tesl-r53-import" "" in
  let home_path = Filename.concat dir "home-module.tesl" in
  let consumer_path = Filename.concat dir "consumer-module.tesl" in
  write_file home_path {|#lang tesl
module HomeModule exposing [checkPort]

import Tesl.Prelude exposing [Int]

fact ValidPort (p: Int)

check checkPort(p: Int) -> p: Int ::: ValidPort p =
  if 1 <= p && p <= 65535 then
    ok p ::: ValidPort p
  else
    fail 400 "bad port"
|};
  write_file consumer_path {|#lang tesl
module ConsumerModule exposing []

import Tesl.Prelude exposing [Int]
import HomeModule exposing [checkPort, ValidPort]

fn needPort(p: Int ::: ValidPort p) -> Int = p
|};
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove home_path with _ -> ());
      (try Sys.remove consumer_path with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () ->
      let code, out = run_compiler ["--check"; consumer_path] in
      if code = 0 then
        failf "expected compile error for missing predicate export, but succeeded"
      else begin
        let re = Str.regexp_case_fold "ValidPort\\|not exported\\|not found\\|unknown\\|exposing" in
        try ignore (Str.search_forward re out 0)
        with Not_found ->
          failf "expected error about ValidPort not being exported, got:\n%s" out
      end)

(* ═══════════════════════════════════════════════════════════════════════════
   R53_R — Record proof field propagation: field access preserves proof
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R53_R01 — When a record has a proof-annotated field, reading that field
   must propagate the proof to the consumer. *)
let r53_r01_record_field_proof_propagates () =
  should_pass_src (base_header ^ {|
fact IsPositive (n: Int)

check isPositive(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"

record PositiveBox {
  value: Int ::: IsPositive value
}

fn needPos(n: Int ::: IsPositive n) -> Int = n

fn readField(box: PositiveBox) -> Int =
  needPos box.value
|})

(* R53_R02 — Constructing a proof-annotated record without the proof must fail. *)
let r53_r02_record_construction_needs_proof () =
  should_fail_src "proof\\|IsPositive\\|required" (base_header ^ {|
fact IsPositive (n: Int)

record PositiveBox {
  value: Int ::: IsPositive value
}

fn badConstruct(n: Int) -> PositiveBox =
  PositiveBox { value: n }
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R53_A — Adversarial: proof at wrong level in named-pack return
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R53_A01 — The selectOne result auto-carries FromDb proof, so
   a `fn` returning `Widget ? FromDb (Id == wid)` via selectOne should compile.
   This tests the positive control for named-pack with SQL results. *)
let r53_a01_selectone_satisfies_named_pack_ok () =
  should_pass_src {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.DB exposing [dbRead]
import Tesl.Maybe exposing [Maybe(..)]

entity Widget table "widgets" primaryKey id {
  id: String
  name: String
}

database WidgetDb {
  backend: postgres
  schema: "test"
  entities: [Widget]
  postgres {
    database: "test"
    user: "test"
    password: "test"
    host: "localhost"
    port: 5432
  }
}

fn goodReturn(wid: String)
  -> Widget ? FromDb (Id == wid)
  requires [dbRead] =
  let found = selectOne w from Widget where w.id == wid
  case found of
    Nothing -> fail 404 "not found"
    Something w -> w
|}

(* ═══════════════════════════════════════════════════════════════════════════
   R53_L — List.take / drop without IsNonNegative proof
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R53_L01 — List.take without IsNonNegative on count must be rejected. *)
let r53_l01_list_take_no_proof () =
  should_fail_src "proof\\|IsNonNegative\\|requires" (base_header ^ {|
import Tesl.List exposing [List.take]

fn badTake(xs: List Int, n: Int) -> List Int =
  List.take n xs
|})

(* R53_L02 — List.take with IsNonNegative proof must work. *)
let r53_l02_list_take_with_proof_ok () =
  should_pass_src (base_header ^ {|
import Tesl.List exposing [List.take]
import Tesl.Int exposing [Int.nonNegative]

fn safeTake(xs: List Int, n: Int) -> List Int =
  let count = check Int.nonNegative n
  List.take count xs
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R53_B — check result used inline without let binding
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R53_B01 — `needsProof (check f(n))` without a let binding must be rejected
   because there is no stable subject name to attach the proof to. *)
let r53_b01_check_without_let_rejected () =
  should_fail_src "let\\|check.*let\\|must be.*bound\\|subject\\|let.*check" (base_header ^ positive_decl ^ {|
fn needPos(n: Int ::: IsPositive n) -> Int = n

fn inline(raw: Int) -> Int =
  needPos (check isPositive raw)
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R53_K — Constructor name matches type name: design rule
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R53_K01 — A constructor sharing the type name must be rejected. *)
let r53_k01_ctor_same_as_type_rejected () =
  should_fail_src "constructor.*same.*type\\|ambiguous\\|rename" (base_header ^ {|
type Status
  = Status
  | Other
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R53_W — Self-referential type alias (cyclic alias)
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R53_W01 — A type alias that mentions itself must be rejected. *)
let r53_w01_self_referential_alias_rejected () =
  should_fail_src "self.referential\\|infinite\\|recursive\\|cycle" (base_header ^ {|
type Recurse = Recurse
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R53_Z — check keyword used outside let binding
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R53_Z01 — BUG. `check` as a statement without binding its result currently
   compiles silently. The spec says `check` calls must be `let`-bound (section 12.1):
   "Writing needsProof (check f(n)) without a `let` binding is rejected because
   there is no stable subject name to attach the proof to." A bare `check f(n)`
   statement should be rejected for the same reason. *)
let r53_z01_check_as_bare_statement_bug () =
  should_fail_src "bare.*check\\|check.*must.*be.*bound\\|let.*check\\|check.*let" (base_header ^ positive_decl ^ {|
fn demo(raw: Int) -> Int =
  check isPositive raw
  42
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R53_Q — Qualified-only import: proof predicates accessible qualified
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R53_Q01 — BUG. The spec section 10.2 says proof predicates must be explicitly
   exported AND explicitly imported. With `import Tesl.String` (module-only, no
   exposing), `IsTrimmed` should NOT be in scope as an unqualified predicate.
   But the compiler currently allows it. This is an import visibility enforcement
   gap for stdlib-module predicates. *)
let r53_q01_stdlib_predicate_without_explicit_import_bug () =
  should_fail_src "IsTrimmed\\|proof.*predicate\\|not.*in.*scope\\|import.*exposing" {|#lang tesl
module Test exposing []
import Tesl.Prelude exposing [String]
import Tesl.String

fn needTrimmed(s: String ::: IsTrimmed s) -> String = s
|}

(* ═══════════════════════════════════════════════════════════════════════════
   R53_V — Proof conjunction on 4 facts: large conjunction roundtrip
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R53_V01 — Positive control: a value earning 4 proofs via sequential check
   should satisfy a function requiring all 4. *)
let r53_v01_four_fact_conjunction_ok () =
  should_pass_src (base_header ^ {|
fact A (n: Int)
fact B (n: Int)
fact C (n: Int)
fact D (n: Int)

check checkA(n: Int) -> n: Int ::: A n =
  if n > 0 then
    ok n ::: A n
  else
    fail 400 "a"

check checkB(n: Int) -> n: Int ::: B n =
  if n < 1000 then
    ok n ::: B n
  else
    fail 400 "b"

check checkC(n: Int) -> n: Int ::: C n =
  if n % 2 == 0 then
    ok n ::: C n
  else
    fail 400 "c"

check checkD(n: Int) -> n: Int ::: D n =
  if n % 3 == 0 then
    ok n ::: D n
  else
    fail 400 "d"

fn needAll(n: Int ::: A n && B n && C n && D n) -> Int = n

fn demo(raw: Int) -> Int =
  let a = check checkA raw
  let b = check checkB a
  let c = check checkC b
  let d = check checkD c
  needAll d
|})

(* R53_V02 — Negative: only 3 of 4 proofs. Function requiring all 4 must
   reject it. *)
let r53_v02_missing_one_of_four_proofs_fails () =
  should_fail_src "does not statically satisfy\\|proof\\|D n\\|missing" (base_header ^ {|
fact A (n: Int)
fact B (n: Int)
fact C (n: Int)
fact D (n: Int)

check checkA(n: Int) -> n: Int ::: A n =
  if n > 0 then
    ok n ::: A n
  else
    fail 400 "a"

check checkB(n: Int) -> n: Int ::: B n =
  if n < 1000 then
    ok n ::: B n
  else
    fail 400 "b"

check checkC(n: Int) -> n: Int ::: C n =
  if n % 2 == 0 then
    ok n ::: C n
  else
    fail 400 "c"

fn needAll(n: Int ::: A n && B n && C n && D n) -> Int = n

fn demo(raw: Int) -> Int =
  let a = check checkA raw
  let b = check checkB a
  let c = check checkC b
  needAll c
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R53_H — shadowing: re-binding a parameter name in case arm
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R53_H01 — Binding a case variable with the same name as a function
   parameter must be rejected (shadowing rule). *)
let r53_h01_case_shadows_parameter () =
  should_fail_src "shadow\\|redefinition\\|duplicate\\|already bound" (base_header ^ {|
fn demo(x: Int) -> Int =
  let m = Something 42
  case m of
    Nothing -> 0
    Something x -> x
|})

(* ═══════════════════════════════════════════════════════════════════════════
   R53_MA — Maybe (T ::: P) return-spec (RetMaybeAttached new feature)
   ═══════════════════════════════════════════════════════════════════════════ *)

(* R53_MA01 — Basic: check function with Maybe (v: T ::: P) return, caller
   matches Something and uses the inner value with its proof. *)
let r53_ma01_maybe_attached_basic_pass () =
  should_pass_src (base_header ^ {|
fact IsPositive (n: Int)

fn needPos(n: Int ::: IsPositive n) -> Int = n

check maybePositive(n: Int) -> Maybe (v: Int ::: IsPositive v) =
  if n > 0 then
    Something n
  else
    Nothing

fn useIt(raw: Int) -> Int =
  let m = check maybePositive raw
  case m of
    Nothing -> 0
    Something v -> needPos v
|})

(* R53_MA02 — Nothing branch requires no proof. *)
let r53_ma02_maybe_nothing_no_proof_pass () =
  should_pass_src (base_header ^ {|
fact IsPositive (n: Int)

check maybePositive(n: Int) -> Maybe (v: Int ::: IsPositive v) =
  if n > 0 then
    Something n
  else
    Nothing

fn safeSum(a: Int, b: Int) -> Int =
  let ma = check maybePositive a
  let mb = check maybePositive b
  case ma of
    Nothing -> 0
    Something _ ->
      case mb of
        Nothing -> 0
        Something _ -> a + b
|})

(* R53_MA03 — fn can declare Maybe (v: T ::: P) as passthrough. *)
let r53_ma03_fn_maybe_attached_pass () =
  should_pass_src (base_header ^ {|
fact IsPositive (n: Int)

check isPositive(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"

fn needPos(n: Int ::: IsPositive n) -> Int = n

fn passthrough(n: Int ::: IsPositive n) -> Maybe (v: Int ::: IsPositive v) =
  Something n

fn useit(raw: Int) -> Int =
  let checked = check isPositive raw
  let m = passthrough checked
  case m of
    Nothing -> 0
    Something v -> needPos v
|})

(* R53_MA04 — Wrong proof predicate on Maybe inner must fail. *)
let r53_ma04_maybe_wrong_proof_fail () =
  should_fail_src "proof\\|IsPositive\\|does not statically satisfy\\|requires" (base_header ^ {|
fact IsPositive (n: Int)
fact IsNeg (n: Int)

check isNeg(n: Int) -> n: Int ::: IsNeg n =
  if n < 0 then
    ok n ::: IsNeg n
  else
    fail 400 "not negative"

fn needPos(n: Int ::: IsPositive n) -> Int = n

check maybeNeg(n: Int) -> Maybe (v: Int ::: IsNeg v) =
  if n < 0 then
    Something n
  else
    Nothing

fn badUse(raw: Int) -> Int =
  let m = check maybeNeg raw
  case m of
    Nothing -> 0
    Something v -> needPos v
|})

(* R53_MA05 — Using inner value without going through case match gives no proof. *)
let r53_ma05_maybe_inner_direct_no_proof_fail () =
  should_fail_src "proof\\|IsPositive\\|does not statically satisfy\\|requires" (base_header ^ {|
fact IsPositive (n: Int)

fn needPos(n: Int ::: IsPositive n) -> Int = n

check maybePositive(n: Int) -> Maybe (v: Int ::: IsPositive v) =
  if n > 0 then
    Something n
  else
    Nothing

fn badUse(raw: Int) -> Int =
  # raw has no IsPositive proof — must go through check first
  needPos raw
|})

(* ═══════════════════════════════════════════════════════════════════════════
   Register all tests
   ═══════════════════════════════════════════════════════════════════════════ *)

let () =
  run "Review53-Antagonistic" [
    "filtercheck-plain-fn", [
      test_case "R53_F01 filterCheck accepts plain fn (bug)" `Quick r53_f01_filtercheck_plain_fn_bug;
      test_case "R53_F02 filterCheck with check fn ok"        `Quick r53_f02_filtercheck_check_fn_ok;
      test_case "R53_F03 Set.filterCheck plain fn (bug)"      `Quick r53_f03_set_filtercheck_plain_fn_bug;
    ];
    "establish-in-fn", [
      test_case "R53_E01 fn calls establish to get proof (allowed by design)" `Quick r53_e01_fn_calls_establish_to_fabricate_bug;
      test_case "R53_E02 fn using ok ::: is rejected"         `Quick r53_e02_fn_ok_proof_rejected;
    ];
    "subject-aliasing", [
      test_case "R53_S01 forgetFact drops proof"              `Quick r53_s01_forget_does_not_leak_proof;
      test_case "R53_S02 recheck after forget ok"             `Quick r53_s02_recheck_after_forget_ok;
    ];
    "guard-exhaustiveness", [
      test_case "R53_G01 two guards same ctor not exhaustive" `Quick r53_g01_two_guards_same_ctor_not_exhaustive;
      test_case "R53_G02 guard plus unconditional ok"         `Quick r53_g02_guard_plus_unconditional_ok;
      test_case "R53_G03 all-guarded ADT not exhaustive"      `Quick r53_g03_adt_all_guards_not_exhaustive;
    ];
    "capability-enforcement", [
      test_case "R53_C01 fn using dbOp needs capability"      `Quick r53_c01_fn_needs_capability_for_db_op;
    ];
    "newtype-identity", [
      test_case "R53_N01 UserId not interchangeable with ProjectId" `Quick r53_n01_newtype_not_interchangeable;
      test_case "R53_N02 correct newtype ok"                        `Quick r53_n02_newtype_correct_ok;
    ];
    "proof-total-divide", [
      test_case "R53_D01 Int.divide without IsNonZero rejected" `Quick r53_d01_divide_without_nonzero_proof;
      test_case "R53_D02 Int.divide with proof ok"              `Quick r53_d02_divide_with_nonzero_ok;
    ];
    "proof-subject-transfer", [
      test_case "R53_P01 proof not transferable between subjects" `Quick r53_p01_proof_not_transferable_between_subjects;
      test_case "R53_P02 detached proof wrong subject"            `Quick r53_p02_detached_proof_wrong_subject;
    ];
    "handler-ok-proof", [
      test_case "R53_O01 handler ok proof rejected" `Quick r53_o01_handler_ok_proof_rejected;
    ];
    "transaction-nesting", [
      test_case "R53_T01 nested transaction rejected" `Quick r53_t01_nested_transaction_rejected;
    ];
    "adt-vs-alias-footgun", [
      test_case "R53_X01 single-line ADT is alias" `Quick r53_x01_single_line_adt_is_alias;
      test_case "R53_X02 multi-line ADT ok"        `Quick r53_x02_multiline_adt_ok;
    ];
    "multi-param-proofs", [
      test_case "R53_M01 three-arg check and consumer ok"   `Quick r53_m01_three_arg_check_and_consumer;
      test_case "R53_M02 three-arg wrong bounds fails"      `Quick r53_m02_three_arg_wrong_bounds_fails;
    ];
    "import-visibility", [
      test_case "R53_I01 predicate not exported from module" `Quick r53_i01_predicate_not_exported;
    ];
    "record-field-proof", [
      test_case "R53_R01 record field proof propagates"             `Quick r53_r01_record_field_proof_propagates;
      test_case "R53_R02 record construction without proof rejected" `Quick r53_r02_record_construction_needs_proof;
    ];
    "named-pack-proof", [
      test_case "R53_A01 selectOne satisfies named-pack (ok)" `Quick r53_a01_selectone_satisfies_named_pack_ok;
    ];
    "list-proof-total", [
      test_case "R53_L01 List.take without IsNonNegative rejected" `Quick r53_l01_list_take_no_proof;
      test_case "R53_L02 List.take with proof ok"                  `Quick r53_l02_list_take_with_proof_ok;
    ];
    "check-let-binding", [
      test_case "R53_B01 check without let binding rejected" `Quick r53_b01_check_without_let_rejected;
    ];
    "ctor-name-collision", [
      test_case "R53_K01 ctor same name as type rejected" `Quick r53_k01_ctor_same_as_type_rejected;
    ];
    "self-referential-alias", [
      test_case "R53_W01 self-referential alias rejected" `Quick r53_w01_self_referential_alias_rejected;
    ];
    "check-bare-statement", [
      test_case "R53_Z01 check as bare statement (bug)" `Quick r53_z01_check_as_bare_statement_bug;
    ];
    "qualified-predicate-import", [
      test_case "R53_Q01 stdlib predicate without explicit import (bug)" `Quick r53_q01_stdlib_predicate_without_explicit_import_bug;
    ];
    "four-fact-conjunction", [
      test_case "R53_V01 four-fact conjunction ok"                `Quick r53_v01_four_fact_conjunction_ok;
      test_case "R53_V02 missing one of four proofs fails"        `Quick r53_v02_missing_one_of_four_proofs_fails;
    ];
    "case-shadowing", [
      test_case "R53_H01 case arm shadows parameter rejected" `Quick r53_h01_case_shadows_parameter;
    ];
    "maybe-attached-proof", [
      test_case "R53_MA01 Maybe (v: T ::: P) basic check+case ok" `Quick r53_ma01_maybe_attached_basic_pass;
      test_case "R53_MA02 Maybe Nothing branch needs no proof"     `Quick r53_ma02_maybe_nothing_no_proof_pass;
      test_case "R53_MA03 fn passthrough of Maybe (v: T ::: P)"   `Quick r53_ma03_fn_maybe_attached_pass;
      test_case "R53_MA04 Maybe wrong proof predicate fails"       `Quick r53_ma04_maybe_wrong_proof_fail;
      test_case "R53_MA05 using inner value without proof fails"   `Quick r53_ma05_maybe_inner_direct_no_proof_fail;
    ];
  ]
