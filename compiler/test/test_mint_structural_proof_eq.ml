(** Mint-side structural proof equality (roadmap:
    fail_closed_mint_matching_structural).

    Sibling of {!Test_b6_structural_proof_eq}, which covers the CARRY side.  The
    carry side of discharge has matched proofs structurally since B6
    ([Validation_common.proof_key]); the MINT side
    ([Proof_checker.validate_check_return]) kept matching by canonical STRING
    ([normalize_conj], i.e. sort atoms by their `pp_proof` rendering) — and the
    RetMaybeAttached arm was weaker still, plain order-SENSITIVE `pp_proof`
    equality.  Two matchers for one relation is the divergent-copy class, and the
    string one is not injective.

    WHY THE UNIT TESTS BELOW ARE THE LOAD-BEARING ONES.  A rendering collision
    needs two structurally different proofs that render alike, which always means
    two different ARG COUNTS (a space hidden inside one argument merges two
    argument slots).  Arity is validated independently, in another file
    ([Validation_capabilities], for user-declared facts), and kernel facts cannot
    be minted from user code at all (fact-ownership).  So an end-to-end `.tesl`
    that exhibits the collision is rejected by the ARITY guard whether or not the
    mint matcher works — a test asserting only "this file fails to compile" would
    stay green through a total regression of the matcher.  These unit tests
    exercise the matcher directly, which is what turns that accidental
    two-guard conjunction into an intentional one.

    Collision routes are real, not hypothetical (both named by the B6 comment in
    validation_common.ml as the reason the carry side moved off strings):
      - the parser captures a parenthesised proof arg verbatim as ONE
        space-joined string ([parse_proof_atom]'s LPAREN arm);
      - the lexer decodes escapes inside a string literal, so a string proof arg
        may itself contain a quote and a space. *)

open Alcotest

let loc = Location.dummy_loc "<mint-test>"
let app pred args : Ast.proof_expr = Ast.PredApp { pred; args; loc }
let conj l r : Ast.proof_expr = Ast.PredAnd { left = l; right = r; loc }

let eq = Proof_checker.mint_proof_equal
let render = Proof_checker.pp_proof
let ncs = Proof_checker.normalize_conj_str

(* ── Part 1: the collisions the string matcher could not see ───────────────── *)

(* NEG — the escaped-quote collision.  Source `Tagged "a\" \"b" n` gives ONE
   string arg whose content contains a quote and a space; source
   `Tagged "a" "b" n` gives THREE args.  Both render byte-identically, so the old
   canonical-string mint comparison treated them as the same proof. *)
let test_escaped_quote_collision_distinct () =
  let one_arg   = app "Tagged" [{|"a" "b"|}; "n"] in
  let three_arg = app "Tagged" [{|"a"|}; {|"b"|}; "n"] in
  (* The collision is real: the renderings ARE equal ... *)
  check string "renderings collide" (render one_arg) (render three_arg);
  (* ... but the structural mint relation separates them. *)
  check bool "mint equality rejects the collision" false (eq one_arg three_arg)

(* NEG — the parenthesised-capture collision: `P a b c` split two ways. *)
let test_arg_split_collision_distinct () =
  let a = app "P" ["a b"; "c"] in
  let b = app "P" ["a"; "b c"] in
  check string "renderings collide" (render a) (render b);
  check bool "mint equality rejects the split collision" false (eq a b)

(* NEG — the pred/arg-0 boundary collision. *)
let test_pred_boundary_collision_distinct () =
  let a = app "Foo bar" ["x"] in
  let b = app "Foo" ["bar"; "x"] in
  check string "renderings collide" (render a) (render b);
  check bool "mint equality rejects the pred-boundary collision" false (eq a b)

(* ── Part 2: everything normalize_conj accepted must still be accepted ─────── *)

let test_identical_equal () =
  let a = conj (app "HasMin" ["10"; "n"]) (app "HasMax" ["100"; "n"]) in
  check bool "self equal" true (eq a a)

(* POS — order-insensitive, as normalize_conj was. *)
let test_conjunction_order_insensitive () =
  let ab = conj (app "HasMin" ["10"; "n"]) (app "HasMax" ["100"; "n"]) in
  let ba = conj (app "HasMax" ["100"; "n"]) (app "HasMin" ["10"; "n"]) in
  check bool "A && B equals B && A" true (eq ab ba)

(* POS — dedup, as normalize_conj's sort_uniq was: `A && A` equals `A`. *)
let test_duplicate_conjunct_dedups () =
  let a = app "IsPos" ["n"] in
  check bool "A && A equals A" true (eq (conj a a) a)

(* POS — deep nesting is flattened, so association does not matter. *)
let test_association_insensitive () =
  let a = app "A" ["n"] and b = app "B" ["n"] and c = app "C" ["n"] in
  check bool "(A && B) && C equals A && (B && C)" true
    (eq (conj (conj a b) c) (conj a (conj b c)))

(* NEG — a different subject is still a mismatch (equality, not entailment). *)
let test_different_subject_distinct () =
  check bool "different subject rejected" false
    (eq (app "IsPos" ["a"]) (app "IsPos" ["b"]))

(* NEG — a missing conjunct is a mismatch.  Mint demands EQUALITY: unlike the
   carry side's [proof_matches] entailment, minting a WEAKER proof than declared
   must fail, not pass. *)
let test_missing_conjunct_distinct () =
  let declared = conj (app "IsPos" ["n"]) (app "IsSmall" ["n"]) in
  check bool "minting only one of two conjuncts rejected" false
    (eq (app "IsPos" ["n"]) declared)

(* POS — the RetMaybeAttached outlier.  That arm compared `pp_proof` directly, so
   a reversed conjunction spuriously mismatched (an over-reject).  It now shares
   the structural relation: renderings differ, mint equality holds. *)
let test_maybe_attached_order_outlier_fixed () =
  let declared = conj (app "IsPos" ["v"]) (app "IsSmall" ["v"]) in
  let minted   = conj (app "IsSmall" ["v"]) (app "IsPos" ["v"]) in
  check bool "renderings differ (what the old arm compared)" false
    (render declared = render minted);
  check bool "mint equality accepts the reordering" true (eq declared minted)

(* ── Part 3: normalize_conj_str — the fallback, whose docstring used to lie ── *)

(* The old implementation scanned for `&&` with NO paren-depth tracking, so a
   nested conjunction split at the inner `&&` as well.  With depth tracking plus
   per-atom paren stripping, association no longer changes the canonical form. *)
let test_ncs_depth_aware_split () =
  check string "nested parens equate with flat" (ncs "A n && B n && C n")
    (ncs "A n && (B n && C n)");
  check string "left-nested equates with flat" (ncs "A n && B n && C n")
    (ncs "(A n && B n) && C n")

(* The old implementation never stripped parens despite its docstring. *)
let test_ncs_strips_outer_parens () =
  check string "parenthesised single atom equates with bare" (ncs "HasMin 10 n")
    (ncs "(HasMin 10 n)")

(* A conjunction operator inside a STRING argument is not a split point. *)
let test_ncs_string_literal_aware () =
  let with_op_in_string = {|Named "a && b" n|} in
  check string "string-internal operator is not a split"
    with_op_in_string (ncs with_op_in_string)

(* Order-insensitivity (SC-01) is preserved. *)
let test_ncs_order_insensitive () =
  check string "atom order does not matter" (ncs "A n && B n") (ncs "B n && A n")

(* ── Part 4: mint_proof_equal_rendered (the ForAll inner sites) ────────────── *)

let eqr = Proof_checker.mint_proof_equal_rendered

(* POS — a rendered inner that parses is compared STRUCTURALLY. *)
let test_rendered_structural_match () =
  check bool "rendered inner matches its proof_expr" true
    (eqr "HasMin 10 n" (app "HasMin" ["10"; "n"]));
  check bool "rendered inner order-insensitive" true
    (eqr "B n && A n" (conj (app "A" ["n"]) (app "B" ["n"])))

(* NEG — the collision, through the rendered path: the text renders like the
   THREE-arg proof but parses as ONE string arg plus a subject. *)
let test_rendered_collision_rejected () =
  let three_arg = app "Tagged" [{|"a"|}; {|"b"|}; "n"] in
  let collide_text = {|Tagged "a\" \"b" n|} in
  check bool "rendered collision rejected" false (eqr collide_text three_arg)

(* NEG — a genuinely different inner is rejected. *)
let test_rendered_mismatch_rejected () =
  check bool "different literal rejected" false
    (eqr "HasMin 20 n" (app "HasMin" ["10"; "n"]))

(* Fallback path — text that does not parse as a proof conjunction falls back to
   the string comparison and must not become MORE permissive. *)
let test_rendered_unparseable_falls_back () =
  check bool "unparseable text does not match" false
    (eqr "&& &&" (app "HasMin" ["10"; "n"]))

(* ── Part 5: end-to-end wiring guard ──────────────────────────────────────── *)

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
  let dir = Filename.temp_dir "tesl-mint" "" in
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

(* WIRING GUARD — the mint comparison is reached and its diagnostic is the one
   that fires (not some earlier guard).  Both spellings here pass the arity
   check, so this asserts the mint arm itself rejected the proof. *)
let test_mint_diagnostic_fires () =
  should_fail ~who:"MintDiagnostic" "ok proof does not match declared return spec"
    {|
module MintWiring exposing [Tagged, tagIt]
import Tesl.Prelude exposing [String, Int, Bool(..), Fact]
fact Tagged (x: String, n: Int)
check tagIt(n: Int) -> n: Int ::: Tagged "a" n =
  if n > 0 then
    ok n ::: Tagged "b" n
  else
    fail 400 "no"
|}

(* END-TO-END of the RetMaybeAttached order fix: a reversed conjunction in the
   `ok` of a `Maybe (v: T ::: A && B)` check now compiles.  Under the old
   order-sensitive `pp_proof` comparison this was rejected. *)
let test_maybe_reversed_order_compiles () =
  should_pass ~who:"MaybeReversedOrder" {|
module MintMaybeOrder exposing [IsPos, IsSmall, mk]
import Tesl.Prelude exposing [Int, Bool(..), Fact]
import Tesl.Maybe exposing [Maybe(..)]
fact IsPos (n: Int)
fact IsSmall (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPos n =
  if n > 0 then
    ok n ::: IsPos n
  else
    fail 400 "no"
check checkSmall(n: Int) -> n: Int ::: IsSmall n =
  if n < 100 then
    ok n ::: IsSmall n
  else
    fail 400 "no"
check mk(n: Int) -> Maybe (v: Int ::: IsPos v && IsSmall v) =
  let a = check checkPos n
  let v = check checkSmall a
  ok (Something v) ::: IsSmall v && IsPos v
|}

(* POSITIVE CONTROL — a plain check mint still compiles (the tightening must not
   reject honest code). *)
let test_plain_mint_still_compiles () =
  should_pass ~who:"PlainMint" {|
module MintPlain exposing [IsPositive, isPositive]
import Tesl.Prelude exposing [Int, Bool(..), Fact]
fact IsPositive (n: Int)
check isPositive(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "no"
|}

(* POSITIVE CONTROL — a ForAll `ok` inner still matches through the rendered
   path (the four normalize_conj_str sites now parse the inner). *)
let test_forall_inner_still_compiles () =
  should_pass ~who:"ForAllInner" {|
module MintForAll exposing [HasMin, checkMin10, allAbove]
import Tesl.Prelude exposing [Int, Bool(..), List, Fact]
import Tesl.List exposing [List.filterCheck]
fact HasMin (lo: Int) (n: Int)
check checkMin10(n: Int) -> n: Int ::: HasMin 10 n =
  if n >= 10 then
    ok n ::: HasMin 10 n
  else
    fail 400 "no"
fn allAbove(raw: List Int) -> List Int ? ForAll (HasMin 10) =
  List.filterCheck checkMin10 raw
|}

let () =
  run "Mint-StructuralProofEq" [
    "collisions-the-string-matcher-missed", [
      test_case "escaped-quote arg collision is distinct" `Quick test_escaped_quote_collision_distinct;
      test_case "parenthesised arg-split collision is distinct" `Quick test_arg_split_collision_distinct;
      test_case "pred/arg-0 boundary collision is distinct" `Quick test_pred_boundary_collision_distinct;
    ];
    "normalize_conj-behaviour-preserved", [
      test_case "identical proof equal" `Quick test_identical_equal;
      test_case "conjunction order-insensitive" `Quick test_conjunction_order_insensitive;
      test_case "duplicate conjunct dedups" `Quick test_duplicate_conjunct_dedups;
      test_case "association-insensitive" `Quick test_association_insensitive;
      test_case "different subject distinct" `Quick test_different_subject_distinct;
      test_case "missing conjunct distinct (equality, not entailment)" `Quick test_missing_conjunct_distinct;
      test_case "RetMaybeAttached order-sensitivity fixed" `Quick test_maybe_attached_order_outlier_fixed;
    ];
    "normalize_conj_str-fallback", [
      test_case "top-level-only split (paren depth aware)" `Quick test_ncs_depth_aware_split;
      test_case "strips outer parens per atom" `Quick test_ncs_strips_outer_parens;
      test_case "operator inside a string is not a split" `Quick test_ncs_string_literal_aware;
      test_case "order-insensitive (SC-01 preserved)" `Quick test_ncs_order_insensitive;
    ];
    "rendered-inner-forall-sites", [
      test_case "rendered inner matches structurally" `Quick test_rendered_structural_match;
      test_case "rendered collision rejected" `Quick test_rendered_collision_rejected;
      test_case "rendered mismatch rejected" `Quick test_rendered_mismatch_rejected;
      test_case "unparseable inner falls back, stays strict" `Quick test_rendered_unparseable_falls_back;
    ];
    "end-to-end", [
      test_case "mint diagnostic fires (wiring guard)" `Quick test_mint_diagnostic_fires;
      test_case "Maybe reversed-order conjunction compiles" `Quick test_maybe_reversed_order_compiles;
      test_case "plain mint still compiles" `Quick test_plain_mint_still_compiles;
      test_case "ForAll inner still compiles" `Quick test_forall_inner_still_compiles;
    ];
  ]
