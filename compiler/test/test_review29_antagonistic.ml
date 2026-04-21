(** Antagonistic regression tests for Critical Review 29.

    Each test probes a specific correctness gap, ergonomic limitation, or
    soundness boundary identified during Review 29.

    Findings covered:
      F01  Record field proof annotations NOT enforced at construction (soundness gap)
      F02  Record field proof annotations NOT propagated on field-access reads
      F03  Ghost witness accepts wrong proof predicate (soundness gap)
      F04  Ghost witness accepts completely unrelated proof (soundness gap)
      F05  Minimum Int literal (-2^62) is inexpressible (off-by-one in literal parser)
      F06  ADT variant fields reject ::: proof annotations (parse error)
      F07  Proof accumulation: check-of-check chains correctly (positive regression)
      F08  % operator requires IsNonZero proof (safety enforcement confirmed)
      F09  / operator requires IsNonZero proof (safety enforcement confirmed)
      F10  Bool requires explicit Bool(..) import for type annotations
      F11  ForAll on non-List/Set type gives clear error
      F12  Inline single-line constructor pattern `Some (Active)` compiles
      F13  Lambda functions support proof-annotated parameters
      F14  establish can always fabricate proofs (by design; audit boundary)
      F15  Call syntax error f(x,y) is unhelpful (no ML-style suggestion)
      F16  Record field proof annotation: field read carries no proof (soundness consequence)
      F17  Newtype constructor and raw string are distinct (nominal typing)
      F18  Capability propagation: callee cap requirements propagate to caller
      F19  ForAll requires explicit subject variable in parameter annotations
      F20  Formatter does not space arithmetic operators (documented limitation)
      F21  Cross-field record invariant via ghost witness compiles correctly
      F22  Record update syntax { r | field = val } is supported and compiles
      F23  tesl wrapper exposes check/lint/fmt but NOT --check-json/--type-at-json
      F24  check-of-check accumulates proofs from both steps (positive)
      F25  Unreachable: combining proofs from separate same-subject checks fails
      F26  Circular module import compiles without error (no cycle detection) *)

open Alcotest

(* ── Helpers ────────────────────────────────────────────────────────────── *)

let tesl =
  match Sys.getenv_opt "TESL_BIN" with
  | Some v -> v
  | None ->
    let dir = Filename.dirname Sys.argv.(0) in
    let candidate = Filename.concat (Filename.dirname dir) "bin/main.exe" in
    let candidate2 = Filename.concat dir "../bin/main.exe" in
    if Sys.file_exists candidate then candidate
    else if Sys.file_exists candidate2 then candidate2
    else "tesl"

let check_subcmd =
  if Filename.basename tesl = "main.exe" then "--check" else "check"

let compile_string src =
  let tmp = Filename.temp_file "tesl-r29-test" ".tesl" in
  let oc = open_out tmp in
  output_string oc src;
  close_out oc;
  let ic = Unix.open_process_in (Printf.sprintf "%s %s %s 2>&1" tesl check_subcmd tmp) in
  let out = In_channel.input_all ic in
  let _ = Unix.close_process_in ic in
  (try Sys.remove tmp with _ -> ());
  out

let should_pass src =
  let out = compile_string src in
  let has_error =
    let re = Str.regexp "error\\[" in
    try ignore (Str.search_forward re out 0); true with Not_found -> false
  in
  if has_error then
    Printf.eprintf "Unexpected error output:\n%s\n" out;
  check bool "should compile without errors" false has_error

let should_fail pattern src =
  let out = compile_string src in
  let found =
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0); true with Not_found -> false
  in
  if not found then
    Printf.eprintf "Expected pattern '%s' in output:\n%s\n" pattern out;
  check bool (Printf.sprintf "should fail with pattern: %s" pattern) true found

let prelude =
  "#lang tesl\nmodule T exposing []\n\
   import Tesl.Prelude exposing [Int, String, Bool(..), List, Unit, Fact]\n\
   import Tesl.Maybe exposing [Maybe(..)]\n"

let proof_prelude =
  prelude ^
  "fact IsPositive (n: Int)\n" ^
  "fact IsSmall (n: Int)\n" ^
  "check checkPos(n: Int) -> n: Int ::: IsPositive n =\n" ^
  "  if n > 0 then\n" ^
  "    ok n ::: IsPositive n\n" ^
  "  else\n" ^
  "    fail 400 \"neg\"\n" ^
  "check checkSmall(n: Int) -> n: Int ::: IsSmall n =\n" ^
  "  if n < 100 then\n" ^
  "    ok n ::: IsSmall n\n" ^
  "  else\n" ^
  "    fail 400 \"big\"\n" ^
  "fn needsBoth(n: Int ::: IsPositive n && IsSmall n) -> String = \"ok\"\n"

(* ─────────────────────────────────────────────────────────────────────────── *)
(* F01 — Record field proof annotations ARE enforced at construction sites.   *)
(*        (Fixed: was a soundness gap, now properly validated.)                *)
(*                                                                              *)
(*  A record field declared `count: Int ::: IsPositive count` requires the     *)
(*  caller to supply a validated value. Passing a raw literal (-5) or any      *)
(*  expression not carrying the required proof is now a compile-time error.    *)
(* ─────────────────────────────────────────────────────────────────────────── *)
let test_f01_record_field_proof_not_enforced () =
  let src = proof_prelude ^
    "record SafeReq {\n" ^
    "  count: Int ::: IsPositive count\n" ^
    "  name: String\n" ^
    "}\n" ^
    "fn buildBad() -> SafeReq =\n" ^
    "  SafeReq { count: -5, name: \"evil\" }\n" in
  (* Fixed: field proof annotation is now enforced — raw literal rejected. *)
  should_fail "V001\\|IsPositive\\|proof\\|does not statically satisfy" src

(* ─────────────────────────────────────────────────────────────────────────── *)
(* F02 — Record field proof annotations ARE propagated on field-access reads.  *)
(*        (FIXED: field_proof_registry in validation.ml propagates proof on     *)
(*        field access. Reading `w.value` from a Wrapper where                  *)
(*        `value: Int ::: IsPositive value` now carries the IsPositive proof.)  *)
(* ─────────────────────────────────────────────────────────────────────────── *)
let test_f02_field_read_no_proof_propagation () =
  let src = proof_prelude ^
    "record Wrapper {\n" ^
    "  value: Int ::: IsPositive value\n" ^
    "}\n" ^
    "fn needsPos(n: Int ::: IsPositive n) -> Int = n\n" ^
    "fn test(w: Wrapper) -> Int =\n" ^
    "  needsPos w.value\n" in
  (* Fixed: field proof propagation now works — field read carries proof. *)
  should_pass src

(* ─────────────────────────────────────────────────────────────────────────── *)
(* F03 — Ghost witness with wrong proof predicate is now rejected.            *)
(*        (Fixed: was a soundness gap, now properly validated.)                *)
(*                                                                              *)
(*  `{ price: p, quantity: q } ::: wrongProof` is rejected when wrongProof    *)
(*  carries a different predicate than the record's declared cross-field       *)
(*  invariant.                                                                  *)
(* ─────────────────────────────────────────────────────────────────────────── *)
let test_f03_ghost_witness_wrong_predicate () =
  let src = prelude ^
    "fact PriceExceedsQuantity (price: Int) (quantity: Int)\n" ^
    "fact TotallyUnrelated (x: Int)\n" ^
    "check dummyCheck(n: Int) -> n: Int ::: TotallyUnrelated n =\n" ^
    "  if n > 0 then\n" ^
    "    ok n ::: TotallyUnrelated n\n" ^
    "  else\n" ^
    "    fail 400 \"neg\"\n" ^
    "record SafeOrder {\n" ^
    "  price:    Int\n" ^
    "  quantity: Int\n" ^
    "} ::: PriceExceedsQuantity price quantity\n" ^
    "fn makeOrder(price: Int, quantity: Int, fakeFact: Fact (TotallyUnrelated price)) -> SafeOrder =\n" ^
    "  SafeOrder { price: price, quantity: quantity } ::: fakeFact\n" in
  (* Fixed: ghost witness predicate mismatch is now detected. *)
  should_fail "ghost witness\\|predicate mismatch\\|TotallyUnrelated\\|PriceExceedsQuantity" src

(* ─────────────────────────────────────────────────────────────────────────── *)
(* F04 — Ghost witness with unrelated proof predicate is now rejected.        *)
(*        (Fixed: was a soundness gap, now properly validated.)                *)
(*                                                                              *)
(*  Any Fact(P ...) as a ghost witness is validated: P must match the          *)
(*  record's declared invariant predicate.                                      *)
(* ─────────────────────────────────────────────────────────────────────────── *)
let test_f04_ghost_witness_unrelated_proof () =
  let src = prelude ^
    "fact RequiredInvariant (a: Int) (b: Int)\n" ^
    "fact WrongFact (x: Int)\n" ^
    "check getWrong(n: Int) -> n: Int ::: WrongFact n =\n" ^
    "  if n > 0 then\n" ^
    "    ok n ::: WrongFact n\n" ^
    "  else\n" ^
    "    fail 400 \"neg\"\n" ^
    "record TwoInts {\n" ^
    "  a: Int\n" ^
    "  b: Int\n" ^
    "} ::: RequiredInvariant a b\n" ^
    "fn makeTwoInts(a: Int, b: Int, w: Fact (WrongFact a)) -> TwoInts =\n" ^
    "  TwoInts { a: a, b: b } ::: w\n" in
  (* Fixed: ghost witness with wrong predicate is now rejected. *)
  should_fail "ghost witness\\|predicate mismatch\\|WrongFact\\|RequiredInvariant" src

(* ─────────────────────────────────────────────────────────────────────────── *)
(* F05 — Minimum Int literal (-2^62) is now expressible (R52-INT-NEG fixed).   *)
(*                                                                              *)
(*  The spec states the range is [-2^62, 2^62-1]. The minimum -4611686018427387904  *)
(*  is now valid: the lexer emits a sentinel token for 4611686018427387904 and   *)
(*  the parser folds it with the unary minus to produce the correct min value.   *)
(*  Positive 4611686018427387904 (without minus) is still rejected.              *)
(* ─────────────────────────────────────────────────────────────────────────── *)
let test_f05_min_int_inexpressible () =
  let src_valid     = prelude ^ "x = -4611686018427387903\n" in
  let src_min       = prelude ^ "x = -4611686018427387904\n" in
  let src_above_max = prelude ^ "x = 4611686018427387904\n" in
  should_pass src_valid;
  (* Fixed: -2^62 is now a valid Tesl Int literal *)
  should_pass src_min;
  (* Positive 2^62 is still out of range *)
  should_fail "out of range" src_above_max

(* ─────────────────────────────────────────────────────────────────────────── *)
(* F06 — ADT variant fields now support ::: proof annotations.                *)
(*        (Fixed: was a parse error, now correctly accepted.)                  *)
(*                                                                              *)
(*  `| MkSafeNum value: Int ::: IsPositive value` is now valid syntax.         *)
(* ─────────────────────────────────────────────────────────────────────────── *)
let test_f06_adt_variant_field_no_proof_annotation () =
  let src = proof_prelude ^
    "type SafeNum\n" ^
    "  = MkSafeNum value:Int ::: IsPositive value\n" in
  (* Fixed: ADT variant fields now accept ::: proof annotations. *)
  should_pass src

(* ─────────────────────────────────────────────────────────────────────────── *)
(* F07 — check-of-check correctly chains proof accumulation (positive).        *)
(*                                                                              *)
(*  Running `let p = check checkPos n` then `let pp = check checkSmall p` gives *)
(*  `pp` both IsPositive and IsSmall proofs. The combined checker `needsBoth`  *)
(*  accepts `pp` directly.                                                      *)
(* ─────────────────────────────────────────────────────────────────────────── *)
let test_f07_check_of_check_accumulates () =
  let src = proof_prelude ^
    "fn test(raw: Int) -> String =\n" ^
    "  let positive = check checkPos raw\n" ^
    "  let small = check checkSmall positive\n" ^
    "  needsBoth small\n" in
  should_pass src

(* ─────────────────────────────────────────────────────────────────────────── *)
(* F08 — % operator enforces IsNonZero on right operand (safety).              *)
(*                                                                              *)
(*  `a % b` where b has no IsNonZero proof is a compile-time error, preventing  *)
(*  modulo-by-zero crashes at runtime. Use `check Int.nonZero b` first.         *)
(* ─────────────────────────────────────────────────────────────────────────── *)
let test_f08_modulo_requires_nonzero () =
  let src = prelude ^
    "import Tesl.Int exposing [Int.nonZero, IsNonZero]\n" ^
    "fn badMod(a: Int, b: Int) -> Int = a % b\n" in
  should_fail "IsNonZero\\|nonzero\\|division\\|%\\|modulo" src

let test_f08b_modulo_safe_with_nonzero () =
  let src = prelude ^
    "import Tesl.Int exposing [Int.nonZero, IsNonZero]\n" ^
    "fn goodMod(a: Int, b: Int) -> Int =\n" ^
    "  let checked = check Int.nonZero b\n" ^
    "  a % checked\n" in
  should_pass src

(* ─────────────────────────────────────────────────────────────────────────── *)
(* F09 — / operator enforces IsNonZero on right operand (safety).              *)
(* ─────────────────────────────────────────────────────────────────────────── *)
let test_f09_division_requires_nonzero () =
  let src = prelude ^
    "import Tesl.Int exposing [Int.divide, Int.nonZero, IsNonZero]\n" ^
    "fn badDiv(a: Int, b: Int) -> Int = a / b\n" in
  should_fail "IsNonZero\\|nonzero\\|division\\|/\\|divide" src

(* ─────────────────────────────────────────────────────────────────────────── *)
(* F10 — Bool type requires explicit Bool(..) import for annotations.          *)
(*                                                                              *)
(*  Even though `n > 0` implicitly returns Bool, using `Bool` as a return type  *)
(*  annotation requires an explicit `import Tesl.Prelude exposing [Bool(..)]`. *)
(*  Comparison operators work without the import; type annotations don't.       *)
(* ─────────────────────────────────────────────────────────────────────────── *)
let test_f10_bool_requires_explicit_import () =
  let src = "#lang tesl\nmodule T exposing []\n" ^
    "import Tesl.Prelude exposing [Int, String]\n" ^
    "fn isPos(n: Int) -> Bool = n > 0\n" in
  should_fail "Bool\\|import" src

let test_f10b_bool_works_with_import () =
  let src = "#lang tesl\nmodule T exposing []\n" ^
    "import Tesl.Prelude exposing [Int, String, Bool(..)]\n" ^
    "fn isPos(n: Int) -> Bool = n > 0\n" in
  should_pass src

(* ─────────────────────────────────────────────────────────────────────────── *)
(* F11 — ForAll on non-List/Set return type gives a clear E000 error.           *)
(* ─────────────────────────────────────────────────────────────────────────── *)
let test_f11_forall_non_list_rejected () =
  let src = proof_prelude ^
    "fn bad() -> Int ? ForAll IsPositive = 42\n" in
  should_fail "ForAll.*only valid.*List\\|List.*ForAll\\|ForAll" src

(* ─────────────────────────────────────────────────────────────────────────── *)
(* F12 — Inline nested constructor pattern (Something (Active)) compiles.       *)
(*                                                                              *)
(*  The spec supports `Something (Constructor)` positional nested patterns.     *)
(*  This is the correct way to match nested constructors inline (not            *)
(*  `Something Active ->`  without parens).                                     *)
(* ─────────────────────────────────────────────────────────────────────────── *)
let test_f12_inline_constructor_pattern () =
  let src = prelude ^
    "type Status\n  = Active\n  | Inactive\n" ^
    "fn test(ms: Maybe Status) -> String =\n" ^
    "  case ms of\n" ^
    "    Nothing -> \"none\"\n" ^
    "    Something (Active) -> \"active\"\n" ^
    "    Something (Inactive) -> \"inactive\"\n" in
  should_pass src

(* ─────────────────────────────────────────────────────────────────────────── *)
(* F13 — Lambda functions support proof-annotated parameters.                   *)
(*                                                                              *)
(*  `fn(x: Int ::: IsPositive x) -> x * 2` is valid syntax for lambdas.        *)
(* ─────────────────────────────────────────────────────────────────────────── *)
let test_f13_lambda_proof_annotated_params () =
  (* Needs its own source with imports before definitions *)
  let src =
    "#lang tesl\nmodule T exposing []\n" ^
    "import Tesl.Prelude exposing [Int, String, Bool(..), List, Unit, Fact]\n" ^
    "import Tesl.List exposing [List.map]\n" ^
    "fact IsPositive (n: Int)\n" ^
    "check checkPos(n: Int) -> n: Int ::: IsPositive n =\n" ^
    "  if n > 0 then\n" ^
    "    ok n ::: IsPositive n\n" ^
    "  else\n" ^
    "    fail 400 \"neg\"\n" ^
    "fn test(xs: List Int) -> List Int =\n" ^
    "  List.map (fn(x: Int ::: IsPositive x) -> x * 2) xs\n" in
  should_pass src

(* ─────────────────────────────────────────────────────────────────────────── *)
(* F14 — establish can always produce a proof (design boundary / audit point). *)
(*                                                                              *)
(*  Unlike `check`, `establish` is total and cannot fail. The expression        *)
(*  `establish alwaysPos(n: Int) -> Fact (IsPositive n) = IsPositive n`         *)
(*  compiles; every value silently becomes "proven" positive. This is an        *)
(*  explicit design choice but forms the unsound escape hatch in the system.    *)
(* ─────────────────────────────────────────────────────────────────────────── *)
let test_f14_establish_always_fabricates () =
  let src = prelude ^
    "fact IsPositive (n: Int)\n" ^
    "establish alwaysPos(n: Int) -> Fact (IsPositive n) =\n" ^
    "  IsPositive n\n" ^
    "fn needsPos(n: Int ::: IsPositive n) -> Int = n\n" ^
    "fn test(x: Int) -> Int =\n" ^
    "  let proof = alwaysPos x\n" ^
    "  needsPos <| x ::: proof\n" in
  should_pass src

(* ─────────────────────────────────────────────────────────────────────────── *)
(* F15 — f(x, y) call syntax gives unhelpful parse error.                      *)
(*                                                                              *)
(*  Writing `add(3, 4)` (parenthesized call syntax) produces "expected ) but   *)
(*  got ,". A better message would say "use ML-style application: add 3 4".    *)
(* ─────────────────────────────────────────────────────────────────────────── *)
let test_f15_paren_call_syntax_error () =
  let src = prelude ^
    "fn add(x: Int, y: Int) -> Int = x + y\n" ^
    "fn test() -> Int = add(3, 4)\n" in
  should_fail "E000\\|expected\\|parse" src

(* ─────────────────────────────────────────────────────────────────────────── *)
(* F16 — Field read of proof-annotated field now carries proof (FIXED).         *)
(*        Accessing w.value from a Wrapper where `value: Int :::                *)
(*        IsPositive value` now provides the IsPositive proof to the caller     *)
(*        via field_proof_registry propagation.                                 *)
(* ─────────────────────────────────────────────────────────────────────────── *)
let test_f16_field_read_no_proof () =
  let src = proof_prelude ^
    "record Wrap { value: Int ::: IsPositive value }\n" ^
    "fn needsPos(n: Int ::: IsPositive n) -> Int = n\n" ^
    "fn test(w: Wrap) -> Int =\n" ^
    "  let v = w.value\n" ^
    "  needsPos v\n" in
  (* Fixed: field proof propagation now works — field read carries proof. *)
  should_pass src

(* ─────────────────────────────────────────────────────────────────────────── *)
(* F17 — Nominal newtypes: UserId and ProjectId are distinct despite same base *)
(*        type. Passing ProjectId where UserId is expected is a compile error.  *)
(* ─────────────────────────────────────────────────────────────────────────── *)
let test_f17_newtype_nominal_distinct () =
  let src = prelude ^
    "type UserId = String\n" ^
    "type ProjectId = String\n" ^
    "fn needsUser(id: UserId) -> String = id.value\n" ^
    "fn test() -> String =\n" ^
    "  let pid = ProjectId(\"proj-1\")\n" ^
    "  needsUser pid\n" in
  should_fail "cannot unify ProjectId with UserId\\|type mismatch" src

(* ─────────────────────────────────────────────────────────────────────────── *)
(* F18 — Capability propagation: fn calling a fn that requires [cap] must also *)
(*        declare [cap] in its own signature.                                    *)
(* ─────────────────────────────────────────────────────────────────────────── *)
let test_f18_capability_propagation () =
  let src = prelude ^
    "import Tesl.Time exposing [time, nowMillis, PosixMillis]\n" ^
    "capability myTime implies time\n" ^
    "fn getTs() -> PosixMillis requires [myTime] = nowMillis()\n" ^
    "fn badWrapper() -> Int =\n" ^
    "  let _ = getTs()\n" ^
    "  0\n" in
  should_fail "requires\\|capability\\|myTime\\|V001" src

(* ─────────────────────────────────────────────────────────────────────────── *)
(* F19 — ForAll in parameter binding requires explicit subject variable.        *)
(*                                                                              *)
(*  `xs: List Int ::: ForAll IsPositive` (no explicit subject) is rejected;    *)
(*  must write `xs: List Int ::: ForAll IsPositive xs`.                         *)
(* ─────────────────────────────────────────────────────────────────────────── *)
let test_f19_forall_param_needs_explicit_subject () =
  let src = proof_prelude ^
    "fn bad(xs: List Int ::: ForAll IsPositive) -> Int = 42\n" in
  should_fail "subject\\|ForAll.*subject\\|V001\\|explicit" src

let test_f19b_forall_param_with_explicit_subject () =
  let src = proof_prelude ^
    "fn good(xs: List Int ::: ForAll IsPositive xs) -> Int = 42\n" in
  should_pass src

(* ─────────────────────────────────────────────────────────────────────────── *)
(* F20 — Formatter leaves arithmetic operators unspaced (documented limit).     *)
(*                                                                              *)
(*  `a+b*2-c/1` is not reformatted to `a + b * 2 - c / 1`. This is a known    *)
(*  formatter limitation explicitly documented in formatter.ml.                  *)
(*  This test documents the gap (not a regression, but a feature absence).      *)
(* ─────────────────────────────────────────────────────────────────────────── *)
let test_f20_formatter_no_arith_spacing () =
  let src = "#lang tesl\nmodule T exposing []\nimport Tesl.Prelude exposing [Int, String]\nfn f(a: Int, b: Int) -> Int =\n  a+b*2\n" in
  let tmp = Filename.temp_file "tesl-r29-fmt" ".tesl" in
  let oc = open_out tmp in
  output_string oc src;
  close_out oc;
  let fmt_flag = if Filename.basename tesl = "main.exe" then "--fmt" else "fmt" in
  let _out = Unix.system (Printf.sprintf "%s %s %s 2>/dev/null" tesl fmt_flag tmp) in
  let ic = open_in tmp in
  let result = In_channel.input_all ic in
  close_in ic;
  (try Sys.remove tmp with _ -> ());
  (* Arithmetic operators should remain unspaced after formatting *)
  let has_spaced_arith =
    let re = Str.regexp "a + b \\* 2" in
    try ignore (Str.search_forward re result 0); true with Not_found -> false
  in
  check bool "F20: formatter leaves arithmetic operators unspaced" false has_spaced_arith

(* ─────────────────────────────────────────────────────────────────────────── *)
(* F21 — Cross-field record invariant with ghost witness compiles correctly.    *)
(*                                                                              *)
(*  A record `} ::: Pred a b via checker` with a ghost-witness construction    *)
(*  `Rec { a: pa, b: pb } ::: proofVar` compiles. (Positive regression.)        *)
(* ─────────────────────────────────────────────────────────────────────────── *)
let test_f21_record_invariant_ghost_witness_compiles () =
  let src = prelude ^
    "fact PriceAbove (p: Int)\n" ^
    "fact QtyAbove (q: Int)\n" ^
    "fact PriceGtQty (price: Int) (qty: Int)\n" ^
    "check checkPAb(n: Int) -> n: Int ::: PriceAbove n =\n" ^
    "  if n > 0 then\n" ^
    "    ok n ::: PriceAbove n\n" ^
    "  else\n" ^
    "    fail 400 \"neg\"\n" ^
    "check checkQAb(n: Int) -> n: Int ::: QtyAbove n =\n" ^
    "  if n > 0 then\n" ^
    "    ok n ::: QtyAbove n\n" ^
    "  else\n" ^
    "    fail 400 \"neg\"\n" ^
    "check checkPGQ(p: Int, q: Int) -> p: Int ::: PriceGtQty p q =\n" ^
    "  if p > q then\n" ^
    "    ok p ::: PriceGtQty p q\n" ^
    "  else\n" ^
    "    fail 400 \"price must exceed qty\"\n" ^
    "record OrderLine {\n" ^
    "  price:    Int ::: PriceAbove price\n" ^
    "  quantity: Int ::: QtyAbove quantity\n" ^
    "} ::: PriceGtQty price quantity via checkPGQ\n" ^
    "fn mkLine(p: Int ::: PriceAbove p,\n" ^
    "           q: Int ::: QtyAbove q,\n" ^
    "           proof: Fact (PriceGtQty p q)) -> OrderLine =\n" ^
    "  OrderLine { price: p, quantity: q } ::: proof\n" in
  should_pass src

(* ─────────────────────────────────────────────────────────────────────────── *)
(* F22 — Record update syntax { r | field = val } is supported.                *)
(* ─────────────────────────────────────────────────────────────────────────── *)
let test_f22_record_update_syntax () =
  let src = prelude ^
    "record User {\n  id: String\n  name: String\n  age: Int\n}\n" ^
    "fn bumpAge(u: User) -> User =\n" ^
    "  { u | age = u.age + 1 }\n" in
  should_pass src

(* ─────────────────────────────────────────────────────────────────────────── *)
(* F23 — The tesl wrapper script does NOT expose --check-json / --type-at-json. *)
(*        The underlying compiler binary does. The wrapper only exposes human-   *)
(*        readable subcommands. LSP must invoke the compiler binary directly.   *)
(* ─────────────────────────────────────────────────────────────────────────── *)
let test_f23_tesl_wrapper_no_json_flags () =
  let wrapped_tesl =
    match Sys.getenv_opt "TESL_BIN" with
    | Some v when Filename.basename v <> "main.exe" -> Some v
    | _ -> None
  in
  match wrapped_tesl with
  | None -> ()  (* Running against main.exe directly — skip *)
  | Some wrapped ->
    let tmp = Filename.temp_file "tesl-r29-json" ".tesl" in
    let oc = open_out tmp in
    output_string oc (prelude ^ "fn f() -> Int = 1\n");
    close_out oc;
    let ic = Unix.open_process_in
      (Printf.sprintf "%s --check-json %s 2>&1" wrapped tmp) in
    let out = In_channel.input_all ic in
    let _ = Unix.close_process_in ic in
    (try Sys.remove tmp with _ -> ());
    let is_unknown =
      let re = Str.regexp "unknown command" in
      try ignore (Str.search_forward re out 0); true with Not_found -> false
    in
    check bool "F23: tesl wrapper --check-json is not exposed (unknown command)" true is_unknown

(* ─────────────────────────────────────────────────────────────────────────── *)
(* F24 — check-of-check accumulates proofs from both validations (positive).   *)
(* ─────────────────────────────────────────────────────────────────────────── *)
let test_f24_check_of_check_accumulates_positive () =
  let src = proof_prelude ^
    "fn test(raw: Int) -> String =\n" ^
    "  let pos = check checkPos raw\n" ^
    "  let small = check checkSmall pos\n" ^
    "  needsBoth small\n" in
  should_pass src

(* ─────────────────────────────────────────────────────────────────────────── *)
(* F25 — Combining proofs from separate checks on the SAME raw value fails.    *)
(*                                                                              *)
(*  `let pos = check checkPos raw; let small = check checkSmall raw` produces   *)
(*  two distinct named values `pos` and `small`. Since `raw` was validated       *)
(*  separately each time, `pos` has IsPositive and `small` has IsSmall — but    *)
(*  neither has BOTH. `needsBoth` requires `IsPositive n && IsSmall n` so both   *)
(*  calls fail at the static proof-check step.                                   *)
(* ─────────────────────────────────────────────────────────────────────────── *)
let test_f25_separate_checks_same_raw_cannot_combine () =
  let src = proof_prelude ^
    "fn test(raw: Int) -> String =\n" ^
    "  let pos   = check checkPos raw\n" ^
    "  let small = check checkSmall raw\n" ^
    (* Neither pos nor small has the combined proof *)
    "  needsBoth pos\n" in
  should_fail "does not statically satisfy\\|V001" src

(* ─────────────────────────────────────────────────────────────────────────── *)
(* ─────────────────────────────────────────────────────────────────────────── *)
(* F26 — Circular module imports compile without error (by design).           *)
(*                                                                              *)
(*  A -> B -> A import cycle compiles successfully. Circular imports are an    *)
(*  integral part of the language — mutually recursive modules are supported.  *)
(* ─────────────────────────────────────────────────────────────────────────── *)
let test_f26_circular_import_no_error () =
  let dir = Filename.get_temp_dir_name () in
  let a_path = Filename.concat dir "circular-a-r29.tesl" in
  let b_path = Filename.concat dir "circular-b-r29.tesl" in
  let write p s = let oc = open_out p in output_string oc s; close_out oc in
  write a_path
    ("#lang tesl\nmodule CircularAR29 exposing [funcA]\n" ^
     "import CircularBR29 exposing [funcB]\n" ^
     "import Tesl.Prelude exposing [Int]\n" ^
     "fn funcA(n: Int) -> Int = funcB n\n");
  write b_path
    ("#lang tesl\nmodule CircularBR29 exposing [funcB]\n" ^
     "import CircularAR29 exposing [funcA]\n" ^
     "import Tesl.Prelude exposing [Int]\n" ^
     "fn funcB(n: Int) -> Int = funcA n\n");
  let ic = Unix.open_process_in
    (Printf.sprintf "%s %s %s 2>&1" tesl check_subcmd a_path) in
  let out = In_channel.input_all ic in
  let _ = Unix.close_process_in ic in
  (try Sys.remove a_path; Sys.remove b_path with _ -> ());
  let has_cycle_error =
    let re = Str.regexp_case_fold "cycle\\|circular\\|recursive import\\|E002" in
    try ignore (Str.search_forward re out 0); true with Not_found -> false
  in
  (* Circular imports are allowed by design — mutually recursive modules compile. *)
  check bool "F26: circular imports compile without error (by design)" false has_cycle_error

(* ── Test suite registration ──────────────────────────────────────────────── *)

let () =
  run "Review-29-Antagonistic" [
    "record-field-proof", [
      test_case "F01: field proof annotation not enforced at construction" `Quick test_f01_record_field_proof_not_enforced;
      test_case "F02: field read carries proof annotation (FIXED)" `Quick test_f02_field_read_no_proof_propagation;
    ];
    "ghost-witness-validation", [
      test_case "F03: ghost witness accepts wrong predicate" `Quick test_f03_ghost_witness_wrong_predicate;
      test_case "F04: ghost witness accepts unrelated proof" `Quick test_f04_ghost_witness_unrelated_proof;
      test_case "F21: correct ghost witness compiles" `Quick test_f21_record_invariant_ghost_witness_compiles;
    ];
    "integer-literal", [
      test_case "F05: min Int literal -2^62 is now expressible (R52-INT-NEG)" `Quick test_f05_min_int_inexpressible;
    ];
    "adt-variant-proofs", [
      test_case "F06: ADT variant field ::: rejected" `Quick test_f06_adt_variant_field_no_proof_annotation;
    ];
    "proof-chaining", [
      test_case "F07: check-of-check accumulates proofs" `Quick test_f07_check_of_check_accumulates;
      test_case "F24: check-of-check positive regression" `Quick test_f24_check_of_check_accumulates_positive;
      test_case "F25: separate checks on same value cannot combine" `Quick test_f25_separate_checks_same_raw_cannot_combine;
    ];
    "division-safety", [
      test_case "F08: % requires IsNonZero" `Quick test_f08_modulo_requires_nonzero;
      test_case "F08b: safe % with nonzero proof" `Quick test_f08b_modulo_safe_with_nonzero;
      test_case "F09: / requires IsNonZero" `Quick test_f09_division_requires_nonzero;
    ];
    "bool-import", [
      test_case "F10: Bool type needs Bool(..) import" `Quick test_f10_bool_requires_explicit_import;
      test_case "F10b: Bool works with import" `Quick test_f10b_bool_works_with_import;
    ];
    "forall-proofs", [
      test_case "F11: ForAll non-List rejected" `Quick test_f11_forall_non_list_rejected;
      test_case "F19: ForAll param needs explicit subject" `Quick test_f19_forall_param_needs_explicit_subject;
      test_case "F19b: ForAll param with explicit subject compiles" `Quick test_f19b_forall_param_with_explicit_subject;
    ];
    "pattern-matching", [
      test_case "F12: inline constructor pattern compiles" `Quick test_f12_inline_constructor_pattern;
    ];
    "lambda-proofs", [
      test_case "F13: lambda with proof-annotated params" `Quick test_f13_lambda_proof_annotated_params;
    ];
    "establish-boundary", [
      test_case "F14: establish can always fabricate proofs" `Quick test_f14_establish_always_fabricates;
    ];
    "ergonomics", [
      test_case "F15: f(x,y) gives parse error" `Quick test_f15_paren_call_syntax_error;
      test_case "F16: field read carries proof (FIXED)" `Quick test_f16_field_read_no_proof;
      test_case "F20: formatter no arith spacing" `Quick test_f20_formatter_no_arith_spacing;
      test_case "F22: record update syntax supported" `Quick test_f22_record_update_syntax;
    ];
    "type-system", [
      test_case "F17: newtype nominal distinction" `Quick test_f17_newtype_nominal_distinct;
    ];
    "capabilities", [
      test_case "F18: capability propagation to caller" `Quick test_f18_capability_propagation;
    ];
    "tooling", [
      test_case "F23: tesl wrapper no json flags" `Quick test_f23_tesl_wrapper_no_json_flags;
      test_case "F26: circular import no error" `Quick test_f26_circular_import_no_error;
    ];
  ]
