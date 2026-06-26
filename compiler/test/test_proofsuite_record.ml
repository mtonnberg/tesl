(** ProofSuite family O — RECORD field proofs + GHOST-WITNESS.

    Proves the STATIC checker enforces, with no runtime net:
      - a record field annotated `f: T ::: P f` cannot be constructed from a RAW
        value (the construction site is checked exactly like a proof-requiring
        function call);
      - a record-level invariant `} ::: Pred a b` requires a ghost witness
        (`{...} ::: proofVar`), and the witness's predicate must match the
        invariant (mismatch is rejected; a non-`detachFact` witness is rejected).

    IMPORTANT — paths that are NOT statically enforced on this substrate (so we
    do NOT write negatives that would wrongly expect rejection):
      - ENTITY field proofs at construction (only DRecord is wired) — entity
        construction from a raw value COMPILES.  We assert that as a positive +
        a TODO marker, so a future tightening (ZC-FINALIZE) flips it to a should_fail.
      - missing ghost witness entirely (compiles).
      - ghost-witness SUBJECT mismatch (compiles).
      - detachFact of a local-let check result carrying the wrong predicate
        (compiles).

    Hardening: [should_fail] additionally fails on any runtime-leak marker.

    Verified error strings:
      - error[V001]: "call to `Box` argument `count` does not statically satisfy declared proof `P raw`"
      - error[V001]: "ghost witness predicate mismatch on `OrderLine` construction: invariant requires `PriceExceedsQty` but witness carries `IsPositive`"
      - error[P001]: "ghost witness for record `OrderLine` must use `(detachFact proof)` …"
      - error[P001]: "ghost witness: proof predicate `IsPositive price` does not match record `OrderLine` invariant `…`; wrong proof"
      - error[P001]: "proof predicate 'IsPositive' in record field `count` is not in scope …" *)

open Alcotest

(* ── Harness (self-contained, kebab-case filenames, runtime-leak hardening) ── *)

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

let file_name_of_src content =
  let re = Str.regexp "\\(module\\|library\\)[ \t\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
  try
    ignore (Str.search_forward re content 0);
    let mname = Str.matched_group 2 content in
    let buf = Buffer.create (String.length mname + 4) in
    String.iteri (fun i c ->
      if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
      else if c >= 'A' && c <= 'Z' then
        (Buffer.add_char buf '-'; Buffer.add_char buf (Char.lowercase_ascii c))
      else Buffer.add_char buf c) mname;
    Buffer.contents buf ^ ".tesl"
  with Not_found -> "test.tesl"

let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-psO" "" in
  let path = Filename.concat dir (file_name_of_src content) in
  let oc = open_out path in output_string oc content; close_out oc;
  Fun.protect
    ~finally:(fun () -> (try Sys.remove path with _ -> ()); (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let leak_markers = [
  "raise-user-error"; "check-fail"; "context...:"; "context ...:";
  ".rkt:"; "racket/"; "/collects/"; "errortrace"; "uncaught exception";
]

let assert_no_runtime_leak pat out =
  List.iter (fun m ->
    let re = Str.regexp_string m in
    if (try ignore (Str.search_forward re out 0); true with Not_found -> false)
    then failf "STATIC-REJECTION VIOLATED for %S: output contains runtime-leak \
                marker %S:\n%s" pat m out)
    leak_markers

let should_fail pat src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected static failure matching %S, but compiled \
                            cleanly:\n%s" pat out;
    assert_no_runtime_leak pat out;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pat out)

let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    let has_err =
      let re = Str.regexp "error\\[" in
      try ignore (Str.search_forward re out 0); true with Not_found -> false in
    if code <> 0 || has_err then
      failf "expected clean compile, got (exit %d):\n%s" code out)

(* ── Shared proof preamble ────────────────────────────────────────────────── *)

let positive_check = {|
fact IsPositive (n: Int)
check checkPositiveInt(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "must be positive"
|}

(* ── O1 — record field proof from a RAW value ─────────────────────────────── *)

let test_O1_field_from_raw_variable () =
  should_fail "does not statically satisfy declared proof.*IsPositive"
    (Printf.sprintf {|
#lang tesl
module ORecRaw exposing []
import Tesl.Prelude exposing [Int]
%s
record Box {
  count: Int ::: IsPositive count
}
fn mk(raw: Int) -> Box =
  Box { count: raw }
|} positive_check)

let test_O1_field_from_raw_literal () =
  should_fail "does not statically satisfy declared proof.*IsPositive\\|requires proof.*IsPositive"
    (Printf.sprintf {|
#lang tesl
module ORecLit exposing []
import Tesl.Prelude exposing [Int]
%s
record Box {
  count: Int ::: IsPositive count
}
fn mk() -> Box =
  Box { count: 5 }
|} positive_check)

let test_O1_field_from_checked_positive () =
  should_pass
    (Printf.sprintf {|
#lang tesl
module ORecOk exposing []
import Tesl.Prelude exposing [Int]
%s
record Box {
  count: Int ::: IsPositive count
}
fn mk(raw: Int) -> Box =
  let c = check checkPositiveInt raw
  Box { count: c }
|} positive_check)

let test_O1_field_from_proof_param_positive () =
  should_pass
    (Printf.sprintf {|
#lang tesl
module ORecParamOk exposing []
import Tesl.Prelude exposing [Int]
%s
record Box {
  count: Int ::: IsPositive count
}
fn mk(c: Int ::: IsPositive c) -> Box =
  Box { count: c }
|} positive_check)

(* ── O2 — multi-field record, one field proven, one raw ───────────────────── *)

let two_field_setup = {|
fact IsPositive (n: Int)
fact NonEmpty (s: String)
check checkPositiveInt(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "p"
check checkNonEmpty(s: String) -> s: String ::: NonEmpty s =
  if s != "" then
    ok s ::: NonEmpty s
  else
    fail 400 "e"
record Tagged {
  count: Int ::: IsPositive count
  label: String ::: NonEmpty label
}
|}

let test_O2_one_raw_field_rejected () =
  should_fail "does not statically satisfy declared proof"
    (Printf.sprintf {|
#lang tesl
module OTwoRaw exposing []
import Tesl.Prelude exposing [Int, String, Bool(..)]
%s
fn mk(c: Int ::: IsPositive c, rawLabel: String) -> Tagged =
  Tagged { count: c, label: rawLabel }
|} two_field_setup)

let test_O2_both_proven_positive () =
  should_pass
    (Printf.sprintf {|
#lang tesl
module OTwoOk exposing []
import Tesl.Prelude exposing [Int, String, Bool(..)]
%s
fn mk(c: Int ::: IsPositive c, l: String ::: NonEmpty l) -> Tagged =
  Tagged { count: c, label: l }
|} two_field_setup)

(* ── O3 — field-proof predicate not in scope ──────────────────────────────── *)

let test_O3_field_predicate_not_in_scope () =
  should_fail "is not in scope\\|not in scope"
    {|
#lang tesl
module OScope exposing []
import Tesl.Prelude exposing [Int]
record Box {
  count: Int ::: UndeclaredPredicate count
}
|}

(* ── O4 — ghost witness: predicate mismatch via Fact-typed parameter ──────── *)
(* The record-level invariant requires PriceExceedsQty; the witness param
   carries a DIFFERENT predicate. *)

let order_setup = {|
fact IsPositive (n: Int)
check checkPositiveInt(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "p"
fact PriceExceedsQty (price: Int, quantity: Int)
check checkPEQ(price: Int, quantity: Int) -> price: Int ::: PriceExceedsQty price quantity =
  if price > quantity then
    ok price ::: PriceExceedsQty price quantity
  else
    fail 422 "x"
record OrderLine {
  price: Int ::: IsPositive price
  quantity: Int ::: IsPositive quantity
} ::: PriceExceedsQty price quantity
|}

let test_O4_witness_wrong_predicate_fact_param () =
  should_fail "ghost witness predicate mismatch\\|does not match record .OrderLine. invariant"
    (Printf.sprintf {|
#lang tesl
module OGhostFactWrong exposing []
import Tesl.Prelude exposing [Int, Fact]
%s
fn mk(price: Int ::: IsPositive price, quantity: Int ::: IsPositive quantity, wrongProof: Fact (IsPositive price)) -> OrderLine =
  OrderLine { price: price, quantity: quantity } ::: wrongProof
|} order_setup)

let test_O4_witness_correct_fact_param_positive () =
  should_pass
    (Printf.sprintf {|
#lang tesl
module OGhostFactOk exposing []
import Tesl.Prelude exposing [Int, Fact]
%s
fn mk(price: Int ::: IsPositive price, quantity: Int ::: IsPositive quantity, recordProof: Fact (PriceExceedsQty price quantity)) -> OrderLine =
  OrderLine { price: price, quantity: quantity } ::: recordProof
|} order_setup)

(* ── O5 — ghost witness: predicate mismatch via detachFact of a proof param ── *)
(* detachFact of a proof-annotated PARAMETER whose predicate differs from the
   invariant is rejected by the proof checker (P001). *)

let test_O5_detach_param_wrong_predicate () =
  should_fail "does not match record .OrderLine. invariant\\|wrong proof\\|ghost witness"
    (Printf.sprintf {|
#lang tesl
module OGhostDetachWrong exposing []
import Tesl.Prelude exposing [Int, Fact, detachFact]
%s
fn mk(price: Int ::: IsPositive price, quantity: Int ::: IsPositive quantity) -> OrderLine =
  OrderLine { price: price, quantity: quantity } ::: (detachFact price)
|} order_setup)

(* ── O6 — ghost witness: non-detachFact value rejected ────────────────────── *)
(* Using a `check`-result local directly (not via detachFact) as the witness. *)

let test_O6_non_detachfact_witness () =
  should_fail "must use .(detachFact proof).\\|ghost witness for record"
    (Printf.sprintf {|
#lang tesl
module OGhostNonDetach exposing []
import Tesl.Prelude exposing [Int]
%s
fn mk(price: Int ::: IsPositive price, quantity: Int ::: IsPositive quantity) -> OrderLine =
  let pq = check checkPEQ price quantity
  OrderLine { price: price, quantity: quantity } ::: pq
|} order_setup)

let test_O6_detachfact_local_positive () =
  should_pass
    (Printf.sprintf {|
#lang tesl
module OGhostDetachOk exposing []
import Tesl.Prelude exposing [Int, Fact, detachFact]
%s
fn mk(price: Int ::: IsPositive price, quantity: Int ::: IsPositive quantity) -> OrderLine =
  let pq = check checkPEQ price quantity
  OrderLine { price: price, quantity: quantity } ::: (detachFact pq)
|} order_setup)

(* ── O7 — entity field proofs: documented NON-ENFORCEMENT (positives) ─────── *)
(* On this substrate, build_record_field_bindings matches only DRecord, so an
   entity field's `::: P` is NOT enforced at construction.  These COMPILE today.
   They are pinned as positives with a TODO so ZC-FINALIZE can flip them to
   should_fail once entity construction is wired into the proof obligation.

   GAP (entity-field-proof-not-enforced): a raw value into an entity field with
   a `:::` proof annotation compiles cleanly — the construction-site obligation
   is never checked for DEntity. *)

let test_O7_entity_field_raw_compiles_TODO () =
  (* CLOSED: entity construction is now proof-checked — a raw value into an
     entity field carrying a `:::` proof is rejected at the construction site. *)
  should_fail "does not statically satisfy declared proof.*IsPositive"
    (Printf.sprintf {|
#lang tesl
module OEntityRaw exposing []
import Tesl.Prelude exposing [Int, String]
%s
entity Account table "accounts" primaryKey id {
  id: String @db(text)
  balance: Int ::: IsPositive balance
}
fn mk(raw: Int) -> Account =
  Account { id: "a1", balance: raw }
|} positive_check)

let test_O7_entity_proven_field_positive () =
  (* The well-behaved counterpart still compiles. *)
  should_pass
    (Printf.sprintf {|
#lang tesl
module OEntityOk exposing []
import Tesl.Prelude exposing [Int, String]
%s
entity Account table "accounts" primaryKey id {
  id: String @db(text)
  balance: Int ::: IsPositive balance
}
fn mk(b: Int ::: IsPositive b) -> Account =
  Account { id: "a1", balance: b }
|} positive_check)

(* ── O1b — field-proof predicate sweep × raw construction ─────────────────── *)
(* Several distinct field predicates, each rejected when the field is built from
   a raw value, each accepted when built from a checked value. *)

type field_pred = { fp_id : string; fp_fact : string; fp_check : string; fp_decls : string }

let mk_fp id fact check cond = {
  fp_id = id; fp_fact = fact; fp_check = check;
  fp_decls = Printf.sprintf {|
fact %s (n: Int)
check %s(n: Int) -> n: Int ::: %s n =
  if %s then
    ok n ::: %s n
  else
    fail 400 "%s"
|} fact check fact cond fact (String.lowercase_ascii fact);
}

let field_preds = [
  mk_fp "Pos" "Positive" "checkPositive" "n > 0";
  mk_fp "Nat" "Natural"  "checkNatural"  "n >= 0";
  mk_fp "Sml" "Smallish" "checkSmallish" "n < 100";
  mk_fp "Nz"  "Nonzeroish" "checkNonzeroish" "n != 0";
]

let o1b_field_raw_sweep =
  List.map (fun fp ->
    Printf.sprintf "O1b %s field from raw" fp.fp_fact,
    (fun () ->
       should_fail "does not statically satisfy declared proof"
         (Printf.sprintf {|
#lang tesl
module ORecSweep%s exposing []
import Tesl.Prelude exposing [Int, Bool(..)]
%s
record Box {
  v: Int ::: %s v
}
fn mk(raw: Int) -> Box =
  Box { v: raw }
|} fp.fp_id fp.fp_decls fp.fp_fact)))
    field_preds

let o1b_field_checked_sweep =
  List.map (fun fp ->
    Printf.sprintf "O1b %s field from checked (positive)" fp.fp_fact,
    (fun () ->
       should_pass
         (Printf.sprintf {|
#lang tesl
module ORecSweepOk%s exposing []
import Tesl.Prelude exposing [Int, Bool(..)]
%s
record Box {
  v: Int ::: %s v
}
fn mk(raw: Int) -> Box =
  let c = check %s raw
  Box { v: c }
|} fp.fp_id fp.fp_decls fp.fp_fact fp.fp_check)))
    field_preds

(* String-typed field proof (NonEmpty). *)
let test_O1b_string_field_from_raw () =
  should_fail "does not statically satisfy declared proof.*NonEmpty"
    {|
#lang tesl
module ORecStr exposing []
import Tesl.Prelude exposing [String, Bool(..)]
fact NonEmpty (s: String)
check checkNE(s: String) -> s: String ::: NonEmpty s =
  if s != "" then
    ok s ::: NonEmpty s
  else
    fail 400 "e"
record Named {
  label: String ::: NonEmpty label
}
fn mk(raw: String) -> Named =
  Named { label: raw }
|}

let test_O1b_string_field_checked_positive () =
  should_pass
    {|
#lang tesl
module ORecStrOk exposing []
import Tesl.Prelude exposing [String, Bool(..)]
fact NonEmpty (s: String)
check checkNE(s: String) -> s: String ::: NonEmpty s =
  if s != "" then
    ok s ::: NonEmpty s
  else
    fail 400 "e"
record Named {
  label: String ::: NonEmpty label
}
fn mk(raw: String) -> Named =
  let c = check checkNE raw
  Named { label: c }
|}

(* ── O4b — ghost-witness mismatch matrix (Fact param, varied wrong pred) ──── *)
(* The invariant requires SumExceeds; sweep several WRONG witness predicates. *)

let order2_setup = {|
fact IsPositive (n: Int)
check checkPositiveInt(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "p"
fact SumExceeds (a: Int, b: Int)
fact ProdExceeds (a: Int, b: Int)
fact DiffExceeds (a: Int, b: Int)
record Pair {
  a: Int ::: IsPositive a
  b: Int ::: IsPositive b
} ::: SumExceeds a b
|}

let wrong_witness_preds = [
  "ProdExceeds", "ProdExceeds a b";
  "DiffExceeds", "DiffExceeds a b";
  "IsPositive",  "IsPositive a";
]

let o4b_ghost_mismatch_matrix =
  List.map (fun (tag, fact_app) ->
    Printf.sprintf "O4b ghost mismatch witness=%s" tag,
    (fun () ->
       should_fail "ghost witness predicate mismatch on .Pair. construction: invariant requires .SumExceeds."
         (Printf.sprintf {|
#lang tesl
module OGhost2%s exposing []
import Tesl.Prelude exposing [Int, Fact]
%s
fn mk(a: Int ::: IsPositive a, b: Int ::: IsPositive b, w: Fact (%s)) -> Pair =
  Pair { a: a, b: b } ::: w
|} tag order2_setup fact_app)))
    wrong_witness_preds

let test_O4b_correct_2arg_witness_positive () =
  should_pass
    (Printf.sprintf {|
#lang tesl
module OGhost2Ok exposing []
import Tesl.Prelude exposing [Int, Fact]
%s
fn mk(a: Int ::: IsPositive a, b: Int ::: IsPositive b, w: Fact (SumExceeds a b)) -> Pair =
  Pair { a: a, b: b } ::: w
|} order2_setup)

(* ── O8 — record with no proof obligations is unaffected (positive) ───────── *)

let test_O8_plain_record_positive () =
  should_pass
    {|
#lang tesl
module OPlain exposing []
import Tesl.Prelude exposing [Int, String]
record Point {
  x: Int
  y: Int
}
fn origin() -> Point =
  Point { x: 0, y: 0 }
|}

(* ── Runner ──────────────────────────────────────────────────────────────── *)

let to_cases lst = List.map (fun (n, f) -> test_case n `Quick f) lst

let () =
  run "ProofSuite-O-Record" [
    "O1-field-from-raw", to_cases [
      "O1 field from raw variable", test_O1_field_from_raw_variable;
      "O1 field from raw literal", test_O1_field_from_raw_literal;
      "O1 field from checked (positive)", test_O1_field_from_checked_positive;
      "O1 field from proof-param (positive)", test_O1_field_from_proof_param_positive;
    ];
    "O1b-field-predicate-sweep", to_cases (o1b_field_raw_sweep @ o1b_field_checked_sweep @ [
      "O1b String field from raw", test_O1b_string_field_from_raw;
      "O1b String field checked (positive)", test_O1b_string_field_checked_positive;
    ]);
    "O2-multi-field", to_cases [
      "O2 one raw field rejected", test_O2_one_raw_field_rejected;
      "O2 both proven (positive)", test_O2_both_proven_positive;
    ];
    "O3-field-predicate-scope", to_cases [
      "O3 field predicate not in scope", test_O3_field_predicate_not_in_scope;
    ];
    "O4-ghost-witness-fact-param", to_cases [
      "O4 wrong predicate (Fact param)", test_O4_witness_wrong_predicate_fact_param;
      "O4 correct predicate (positive)", test_O4_witness_correct_fact_param_positive;
    ];
    "O4b-ghost-mismatch-matrix", to_cases (o4b_ghost_mismatch_matrix @ [
      "O4b correct 2-arg witness (positive)", test_O4b_correct_2arg_witness_positive;
    ]);
    "O5-ghost-witness-detach-param", to_cases [
      "O5 detachFact param wrong predicate", test_O5_detach_param_wrong_predicate;
    ];
    "O6-ghost-witness-non-detach", to_cases [
      "O6 non-detachFact witness", test_O6_non_detachfact_witness;
      "O6 detachFact local (positive)", test_O6_detachfact_local_positive;
    ];
    "O7-entity-field-nonenforcement", to_cases [
      "O7 entity raw field compiles (TODO: should_fail)", test_O7_entity_field_raw_compiles_TODO;
      "O7 entity proven field (positive)", test_O7_entity_proven_field_positive;
    ];
    "O8-plain-record", to_cases [
      "O8 plain record (positive)", test_O8_plain_record_positive;
    ];
  ]
