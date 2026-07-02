(** B6 — structural proof equality.

    The pre-B6 [proof_key] rendered a proof to a single space-joined string, so
    two structurally DISTINCT proofs that render to the same flattened text —
    e.g. `PredApp("P",["a b";"c"])` and `PredApp("P",["a";"b c"])` — collided and
    were treated as equal by [proof_matches]/dedup.  Those space-containing args
    are reachable, not hypothetical: the parser captures a parenthesised proof
    arg as one opaque space-joined string, and [normalize_carried_forall] renders
    a ForAll's inner predicate via pp_proof (`"HasMin 10"`).

    The fix replaces the string key with an injective structural key
    (`KApp of string * string list | KAnd of proof_key_t list`), compared with
    polymorphic structural `=`.  Conjunctions are sorted (order-insensitive).
    The `ForAll` `strip_outer_parens` special case is preserved so the required
    (parenthesised) and carried (bare) inner renderings still equate.

    Also fixes the `IsNonZero` division-safety check: it was a rendered-string
    PREFIX match (`String.sub key 0 9 = "IsNonZero"`) that wrongly accepted any
    predicate whose NAME starts with "IsNonZero" (e.g. `IsNonZeroish`) and only
    looked at the top node of a conjunction.  It is now an exact structural pred
    match over the flattened proof against the nonzero family (IsNonZero,
    FloatNonZero).

    Split into (1) pure unit tests over [proof_key]/[proof_matches] — the most
    faithful test of the injective-key seam — and (2) end-to-end `--check` tests
    for the IsNonZeroish behavioral fix and the positive-preservation cases. *)

open Alcotest

(* ── Part 1: unit tests over the structural key ───────────────────────────── *)

let loc = Location.dummy_loc "<b6-test>"
let app pred args : Ast.proof_expr = Ast.PredApp { pred; args; loc }
let conj l r : Ast.proof_expr = Ast.PredAnd { left = l; right = r; loc }

let pk = Validation_common.proof_key
let matches = Validation_common.proof_matches

(* NEG — the reachable collision: `P a b c` split two ways is now distinct, so
   the carried proof does NOT satisfy the required one.  Under the old string key
   both rendered "P a b c" and proof_matches returned true (the soundness bug). *)
let test_structural_collision_distinct () =
  let required = app "P" ["a b"; "c"] in
  let carried  = app "P" ["a"; "b c"] in
  check bool "keys distinct" false (pk required = pk carried);
  check bool "does not match" false (matches required [carried])

(* Second collision shape: `Foo bar x` as (pred="Foo bar") vs (pred="Foo"). *)
let test_structural_collision_pred_boundary () =
  let a = app "Foo bar" ["x"] in
  let b = app "Foo" ["bar"; "x"] in
  check bool "pred/arg boundary distinct" false (pk a = pk b);
  check bool "does not match" false (matches a [b])

(* POS — identical structure still matches (rejection is specificity). *)
let test_identical_structure_matches () =
  let a = app "HasMin" ["10"; "xs"] in
  check bool "self key equal" true (pk a = pk a);
  check bool "self matches" true (matches a [a])

(* POS — order-insensitive conjunction: `P && Q` key equals `Q && P` key, and
   proof_matches accepts either order (KAnd sorts conjuncts). *)
let test_conjunction_order_insensitive_key () =
  let pq = conj (app "HasMin" ["10"; "n"]) (app "HasMax" ["100"; "n"]) in
  let qp = conj (app "HasMax" ["100"; "n"]) (app "HasMin" ["10"; "n"]) in
  check bool "conj keys order-insensitive" true (pk pq = pk qp);
  (* required in one order, carried atoms present in the other order → matches *)
  check bool "conj matches across order" true
    (matches qp [app "HasMin" ["10"; "n"]; app "HasMax" ["100"; "n"]])

(* POS — ForAll strip_outer_parens preserved: required `(HasMin 10)` (parens) vs
   carried `HasMin 10` (bare) still equate. *)
let test_forall_paren_bare_equate () =
  let required = app "ForAll" ["(HasMin 10)"; "xs"] in
  let carried  = app "ForAll" ["HasMin 10"; "xs"] in
  check bool "ForAll paren/bare keys equal" true (pk required = pk carried);
  check bool "ForAll paren/bare matches" true (matches required [carried])

(* NEG — ForAll with a different inner literal stays distinct. *)
let test_forall_wrong_literal_distinct () =
  let required = app "ForAll" ["(HasMin 20)"; "xs"] in
  let carried  = app "ForAll" ["HasMin 10"; "xs"] in
  check bool "ForAll 10 vs 20 distinct" false (pk required = pk carried);
  check bool "ForAll wrong-lit no match" false (matches required [carried])

(* ── Part 2: end-to-end `--check` (IsNonZeroish behavioral fix + positives) ─── *)

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

let check_subcmd =
  if Filename.basename compiler = "main.exe" then "--check" else "check"

let run_compiler args =
  let quoted = Filename.quote compiler :: List.map Filename.quote args in
  let ic = Unix.open_process_in (String.concat " " quoted ^ " 2>&1") in
  let out = In_channel.input_all ic in
  let status = Unix.close_process_in ic in
  let code = match status with
    | Unix.WEXITED c -> c | Unix.WSIGNALED n -> 128 + n | Unix.WSTOPPED n -> 128 + n
  in (code, out)

let failf fmt = Printf.ksprintf failwith fmt

let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-b6" "" in
  let name =
    let re = Str.regexp "\\(module\\|library\\)[ \t\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
    try
      ignore (Str.search_forward re content 0);
      let mname = Str.matched_group 2 content in
      let buf = Buffer.create (String.length mname + 4) in
      String.iteri (fun i c ->
        if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
        else if c >= 'A' && c <= 'Z' then (Buffer.add_char buf '-'; Buffer.add_char buf (Char.lowercase_ascii c))
        else Buffer.add_char buf c) mname;
      Buffer.contents buf ^ ".tesl"
    with Not_found -> "test.tesl"
  in
  let path = Filename.concat dir name in
  let oc = open_out path in output_string oc content; close_out oc;
  Fun.protect
    ~finally:(fun () -> (try Sys.remove path with _ -> ()); (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let should_fail ?(who = "should_fail") pat src =
  with_temp_file src (fun path ->
    let code, out = run_compiler [check_subcmd; path] in
    if code = 0 then failf "%s: expected failure matching %S, but compiled cleanly.\nOutput:\n%s" who pat out;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "%s: expected failure matching %S, got:\n%s" who pat out)

let should_pass ?(who = "should_pass") src =
  with_temp_file src (fun path ->
    let code, out = run_compiler [check_subcmd; path] in
    let has_error =
      try ignore (Str.search_forward (Str.regexp "error\\[") out 0); true with Not_found -> false
    in
    if has_error || code <> 0 then failf "%s: expected clean compile, got (exit %d):\n%s" who code out)

(* BEHAVIORAL — a user predicate named `IsNonZeroish` must NOT be accepted as
   division-safe (the old prefix match wrongly accepted it). *)
let test_isnonzeroish_not_division_safe () =
  should_fail ~who:"IsNonZeroish" "has no .?IsNonZero.? proof\\|division may crash"
    {|
#lang tesl
module NonZeroish exposing [danger]
import Tesl.Prelude exposing [Int, Bool(..), Fact]
fact IsNonZeroish (n: Int)
check checkish(n: Int) -> n: Int ::: IsNonZeroish n =
  if n > 0 then
    ok n ::: IsNonZeroish n
  else
    fail 400 "no"
fn danger(a: Int, raw: Int) -> Int =
  let b = check checkish raw
  a / b
|}

(* POSITIVE control — a genuine `Int.nonZero` proof still permits division. *)
let test_int_nonzero_division_ok () =
  should_pass ~who:"IntNonZero" {|
#lang tesl
module NonZeroOk exposing [safe]
import Tesl.Prelude exposing [Int]
import Tesl.Int exposing [Int.nonZero]
fn safe(a: Int, raw: Int) -> Int =
  let b = check Int.nonZero raw
  a / b
|}

(* POSITIVE — ForAll producer/consumer still matches (strip_outer_parens
   preserved end-to-end): filterAbove10 (bare) satisfies needForAllAbove10
   (parenthesised). *)
let test_forall_producer_consumer_ok () =
  should_pass ~who:"ForAllPC" {|
#lang tesl
module B6ForAll exposing [test]
import Tesl.Prelude exposing [Int, Bool(..), List, Fact]
import Tesl.List exposing [List.filterCheck, List.foldr]
fact HasMin (lo: Int) (n: Int)
check checkMin10(n: Int) -> n: Int ::: HasMin 10 n =
  if n >= 10 then
    ok n ::: HasMin 10 n
  else
    fail 400 "no"
fn needOne(x: Int ::: HasMin 10 x) -> Int = x
fn needForAllAbove10(xs: List Int ::: ForAll (HasMin 10) xs) -> Int =
  List.foldr (fn (acc: Int, x: Int ::: HasMin 10 x) -> acc + needOne x) 0 xs
fn filterAbove10(raw: List Int) -> List Int ? ForAll (HasMin 10) =
  List.filterCheck checkMin10 raw
fn test(raw: List Int) -> Int =
  let xs = filterAbove10 raw
  needForAllAbove10 xs
|}

(* POSITIVE — plain proof passthrough with the SAME subject still matches. *)
let test_plain_passthrough_ok () =
  should_pass ~who:"Passthrough" {|
#lang tesl
module B6Passthrough exposing [good]
import Tesl.Prelude exposing [Int, Bool(..), Fact]
fact IsPositive (n: Int)
check isPositive(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "no"
fn requiresPositive(n: Int ::: IsPositive n) -> Int = n
fn good(raw: Int) -> Int =
  let v = check isPositive raw
  requiresPositive v
|}

(* POSITIVE (property, end-to-end) — order-insensitive conjunction match: provide
   HasMin then HasMax, require HasMax && HasMin (opposite textual order). *)
let test_conjunction_order_e2e_ok () =
  should_pass ~who:"ConjOrderE2E" {|
#lang tesl
module B6ConjOrder exposing [t]
import Tesl.Prelude exposing [Int, Bool(..), Fact]
fact HasMin (lo: Int) (n: Int)
fact HasMax (hi: Int) (n: Int)
check checkMin10(n: Int) -> n: Int ::: HasMin 10 n =
  if n >= 10 then
    ok n ::: HasMin 10 n
  else
    fail 400 "no"
check checkMax100(n: Int) -> n: Int ::: HasMax 100 n =
  if n <= 100 then
    ok n ::: HasMax 100 n
  else
    fail 400 "no"
fn needReversed(n: Int ::: HasMax 100 n && HasMin 10 n) -> Int = n
fn t(raw: Int) -> Int =
  let a = check checkMin10 raw
  let b = check checkMax100 a
  needReversed b
|}

let () =
  run "B6-StructuralProofEq" [
    "structural-key-unit", [
      test_case "reachable collision (P a b c split) is distinct" `Quick test_structural_collision_distinct;
      test_case "pred/arg-0 boundary collision is distinct" `Quick test_structural_collision_pred_boundary;
      test_case "identical structure still matches" `Quick test_identical_structure_matches;
      test_case "conjunction key order-insensitive" `Quick test_conjunction_order_insensitive_key;
      test_case "ForAll paren/bare inner equate (special case preserved)" `Quick test_forall_paren_bare_equate;
      test_case "ForAll wrong inner literal stays distinct" `Quick test_forall_wrong_literal_distinct;
    ];
    "end-to-end", [
      test_case "IsNonZeroish NOT division-safe (prefix bug fixed)" `Quick test_isnonzeroish_not_division_safe;
      test_case "Int.nonZero division ok (positive control)" `Quick test_int_nonzero_division_ok;
      test_case "ForAll producer/consumer ok" `Quick test_forall_producer_consumer_ok;
      test_case "plain proof passthrough ok" `Quick test_plain_passthrough_ok;
      test_case "order-insensitive conjunction ok (e2e)" `Quick test_conjunction_order_e2e_ok;
    ];
  ]
