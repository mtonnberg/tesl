(** ProofSuite Family C — proof FLOW through `let` / `case` / `if`.

    NEG-CORE: compile-time rejection of every "proof did not actually reach the
    consumer through control flow" mistake, proven WITHOUT the runtime net.
    Modeled on [test_library_negative.ml] / [test_review20_antagonistic.ml].

    Every negative is STATIC: [should_fail] asserts non-zero exit AND no runtime
    leak. A negative that compiles is a real static-checker gap.

    Anchors: `check_expr_call_proofs` / `validation_proof.ml`. §7.4 (shadowing
    illegal). Proof-carrying `Maybe` + proof-through-`case` (TESL.md). *)

open Alcotest

(* ── Inlined harness (self-contained per NEG-CORE brief) ─────────────────── *)

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

let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-psC" "" in
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

let runtime_leak_re =
  Str.regexp_case_fold "raise-user-error\\|check-fail\\|context\\.\\.\\.:\\|/racket/\\|collects/racket"

let should_fail pat src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then
      failf "expected STATIC failure matching %S, but compiled cleanly:\n%s" pat out;
    (try ignore (Str.search_forward runtime_leak_re out 0);
       failf "rejection leaked to RUNTIME (not static) for %S, got:\n%s" pat out
     with Not_found -> ());
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pat out)

let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected clean compile, got exit %d:\n%s" code out)

let prelude name =
  Printf.sprintf
    "#lang tesl\nmodule %s exposing []\n\
     import Tesl.Prelude exposing [Int, String, Bool(..), List, Fact]\n\
     import Tesl.Maybe exposing [Maybe(..)]\n" name

let unsat = "does not statically satisfy declared proof"

(* A reusable IsPositive check producer (multi-line `if` is mandatory). *)
let with_pos_check body =
  {|
fact IsPositive (n: Int)
check c(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn needs(n: Int ::: IsPositive n) -> Int = n
|} ^ body

(* ── C. let-flow negatives ───────────────────────────────────────────────── *)

(* a `let`-bound non-checked value used at a proof site. *)
let test_C_let_unchecked () =
  should_fail unsat (prelude "CLetUnchk" ^ with_pos_check {|
fn caller(raw: Int) -> Int =
  let v = raw
  needs v
|})

(* `let` re-binds the raw value (a copy), dropping the proof. *)
let test_C_let_rebinds_raw () =
  should_fail unsat (prelude "CLetRebind" ^ with_pos_check {|
fn passthru(x: Int) -> Int = x
fn caller(raw: Int) -> Int =
  let v = check c raw
  let w = passthru v
  needs w
|})

(* proof established for one `let` binding, a different one consumed. *)
let test_C_let_wrong_binding () =
  should_fail unsat (prelude "CLetWrong" ^ with_pos_check {|
fn caller(a: Int, b: Int) -> Int =
  let v = check c a
  let w = b
  needs w
|})

(* arithmetic on a proven value drops the proof. *)
let test_C_let_arith_drops () =
  should_fail (unsat ^ "\\|expression with no trackable subject") (prelude "CLetArith" ^ with_pos_check {|
fn caller(raw: Int) -> Int =
  let v = check c raw
  let w = v + 1
  needs w
|})

(* ── C. if-flow negatives ────────────────────────────────────────────────── *)

(* proof established only in the `then` branch, required after the join. *)
let test_C_if_then_only () =
  should_fail unsat (prelude "CIfThen" ^ with_pos_check {|
fn caller(raw: Int, flag: Bool) -> Int =
  let v = if flag then
      check c raw
    else
      raw
  needs v
|})

(* proof established only in the `else` branch, required after the join. *)
let test_C_if_else_only () =
  should_fail unsat (prelude "CIfElse" ^ with_pos_check {|
fn caller(raw: Int, flag: Bool) -> Int =
  let v = if flag then
      raw
    else
      check c raw
  needs v
|})

(* both branches validate DIFFERENT subjects → joined value tracks neither. *)
let test_C_if_both_branches_diff_subject () =
  should_fail unsat (prelude "CIfDiff" ^ with_pos_check {|
fn caller(a: Int, b: Int, flag: Bool) -> Int =
  let v = if flag then
      check c a
    else
      check c b
  needs a
|})

(* ── C. case-flow negatives ──────────────────────────────────────────────── *)

(* `case` binds from a non-proof scrutinee, then calls a proof-requiring fn. *)
let test_C_case_nonproof_scrutinee () =
  should_fail unsat (prelude "CCaseRaw" ^ with_pos_check {|
fn caller(mx: Maybe Int) -> Int =
  case mx of
    Nothing -> 0
    Something v -> needs v
|})

(* `case` over a plain ADT, arm payload is unproven. *)
let test_C_case_adt_unproven () =
  should_fail unsat (prelude "CCaseAdt" ^ {|
fact IsPositive (n: Int)
fn needs(n: Int ::: IsPositive n) -> Int = n
type Box = Box value:Int
fn caller(b: Box) -> Int =
  case b of
    Box v -> needs v
|})

(* `case` where only one arm validates; the other passes raw. *)
let test_C_case_one_arm_validates () =
  should_fail unsat (prelude "CCaseOneArm" ^ with_pos_check {|
fn caller(mx: Maybe Int) -> Int =
  case mx of
    Nothing -> 0
    Something v ->
      let checked = check c v
      needs v
|})

(* ── C. shadowing (§7.4) ─────────────────────────────────────────────────── *)

let test_C_shadowing_rejected () =
  should_fail "shadows existing name\\|shadow" (prelude "CShadow" ^ {|
fact IsPositive (n: Int)
fn caller(raw: Int) -> Int =
  let x = raw
  let x = raw
  x
|})

(* shadowing a proven binding with a raw one. *)
let test_C_shadow_proven_with_raw () =
  should_fail "shadows existing name\\|shadow" (prelude "CShadowProven" ^ with_pos_check {|
fn caller(raw: Int) -> Int =
  let v = check c raw
  let v = raw
  needs v
|})

(* ── C. Positive sanity — proof flows correctly ──────────────────────────── *)

let test_C_pos_let_flows () =
  should_pass (prelude "CPosLet" ^ with_pos_check {|
fn caller(raw: Int) -> Int =
  let v = check c raw
  needs v
|})

let test_C_pos_let_chain () =
  should_pass (prelude "CPosChain" ^ with_pos_check {|
fn caller(raw: Int) -> Int =
  let v = check c raw
  let w = v
  needs w
|})

(* CONSERVATIVE-JOIN: even when BOTH `if` branches validate the SAME proof, the
   joined `let v = if ...` value does NOT carry the proof — the static checker
   does not merge proof environments across an `if`-join. This is a sound
   (conservative) rejection; the supported idiom is `check c v` AFTER the join. *)
let test_C_if_both_branches_no_merge () =
  should_fail unsat (prelude "CIfBoth" ^ with_pos_check {|
fn caller(raw: Int, flag: Bool) -> Int =
  let v = if flag then
      check c raw
    else
      check c raw
  needs v
|})

let test_C_pos_case_proof_through_something () =
  (* proof-carrying Maybe: the proof flows through `case ... Something v`. *)
  should_pass (prelude "CPosCase" ^ {|
fact AllPos (t: Int)
check c(t: Int) -> t: Int ::: AllPos t =
  if t > 0 then
    ok t ::: AllPos t
  else
    fail 400 "bad"
fn needs(t: Int ::: AllPos t) -> Int = t
fn maybeValid(t: Int) -> Maybe (v: Int ::: AllPos v) =
  let checked = check c t
  Something checked
fn consume(t: Int) -> Int =
  case maybeValid t of
    Nothing -> 0
    Something v -> needs v
|})

let test_C_pos_let_then_case_arm_validates () =
  should_pass (prelude "CPosLetCase" ^ with_pos_check {|
fn caller(raw: Int) -> Int =
  let mx = Something raw
  case mx of
    Nothing -> 0
    Something v ->
      let checked = check c v
      needs checked
|})

let test_C_pos_proof_param_through_let () =
  should_pass (prelude "CPosParamLet" ^ {|
fact IsPositive (n: Int)
fn needs(n: Int ::: IsPositive n) -> Int = n
fn forward(p: Int ::: IsPositive p) -> Int =
  let v = p
  needs v
|})

let test_C_pos_case_conjunction_maybe () =
  should_pass (prelude "CPosCaseConj" ^ {|
fact P (n: Int)
fact Q (n: Int)
check c(n: Int) -> n: Int ::: P n && Q n =
  if n > 0 && n < 100 then
    ok n ::: P n && Q n
  else
    fail 400 "x"
fn needs(n: Int ::: P n && Q n) -> Int = n
fn maybeBoth(n: Int) -> Maybe (v: Int ::: P v && Q v) =
  let checked = check c n
  Something checked
fn consume(n: Int) -> Int =
  case maybeBoth n of
    Nothing -> 0
    Something v -> needs v
|})

let test_C_pos_handler_nested_let () =
  should_pass (prelude "CPosHandlerLet" ^ {|
import Tesl.Http exposing [HttpRequest]
fact IsPositive (n: Int)
check c(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "x"
fn needs(n: Int ::: IsPositive n) -> Int = n
handler h(raw: Int) -> Int requires [] =
  let v = check c raw
  let w = v
  needs w
|})

(* CONSERVATIVE-JOIN (nested): same as above with a prior `let` binding; the
   if-join still drops the proof. *)
let test_C_nested_let_if_no_merge () =
  should_fail unsat (prelude "CNested" ^ with_pos_check {|
fn caller(raw: Int, flag: Bool) -> Int =
  let base = raw
  let v = if flag then
      check c base
    else
      check c base
  needs v
|})

(* ── C. Parameterized FLOW negatives (Tier 2) ────────────────────────────── *)
(* predicate axis × flow-construct × flow-mistake. *)

type pred = {
  pname : string;
  decl : string;
  ty : string;
  papp : string;     (* applied predicate on subject `x` *)
  imports : string;
  cond : string;     (* boolean over `x` for the check producer *)
  zero : string;     (* a default value of type ty (for Nothing arms) *)
}

let predicates suffix = [
  { pname = "Int";
    decl = Printf.sprintf "fact PcPos%s (n: Int)" suffix;
    ty = "Int"; papp = Printf.sprintf "PcPos%s x" suffix; imports = "";
    cond = "x > 0"; zero = "0" };
  { pname = "String";
    decl = Printf.sprintf "fact PcNE%s (s: String)" suffix;
    ty = "String"; papp = Printf.sprintf "PcNE%s x" suffix;
    imports = "import Tesl.String exposing [String.length]\n";
    cond = "String.length x > 0"; zero = "\"\"" };
  { pname = "Clamped";
    decl = Printf.sprintf "fact PcClamp%s (lo: Int) (hi: Int) (n: Int)" suffix;
    ty = "Int"; papp = Printf.sprintf "PcClamp%s 1 100 x" suffix; imports = "";
    cond = "x >= 1 && x <= 100"; zero = "0" };
  { pname = "Even";
    decl = Printf.sprintf "fact PcEven%s (n: Int)" suffix;
    ty = "Int"; papp = Printf.sprintf "PcEven%s x" suffix; imports = "";
    cond = "x > 0"; zero = "0" };
  { pname = "Trimmed";
    decl = Printf.sprintf "fact PcTrim%s (s: String)" suffix;
    ty = "String"; papp = Printf.sprintf "PcTrim%s x" suffix;
    imports = "import Tesl.String exposing [String.length]\n";
    cond = "String.length x > 0"; zero = "\"\"" };
  { pname = "Bounded";
    decl = Printf.sprintf "fact PcBound%s (n: Int)" suffix;
    ty = "Int"; papp = Printf.sprintf "PcBound%s x" suffix; imports = "";
    cond = "x < 1000"; zero = "0" };
]

(* producer + needs declarations for predicate p *)
let pred_decls p =
  Printf.sprintf
    "%s\ncheck c(x: %s) -> x: %s ::: %s =\n  if %s then\n    ok x ::: %s\n  else\n    fail 400 \"bad\"\nfn needs(x: %s ::: %s) -> %s = x\n"
    p.decl p.ty p.ty p.papp p.cond p.papp p.ty p.papp p.ty

(* (construct, mistake) → the `caller` source for predicate p *)
let flow_caller mistake p =
  match mistake with
  | `LetUnchecked ->
    Printf.sprintf "fn caller(raw: %s) -> %s =\n  let v = raw\n  needs v\n" p.ty p.ty
  | `LetPassthrough ->
    Printf.sprintf
      "fn id(x: %s) -> %s = x\nfn caller(raw: %s) -> %s =\n  let v = check c raw\n  let w = id v\n  needs w\n"
      p.ty p.ty p.ty p.ty
  | `LetWrongBinding ->
    Printf.sprintf
      "fn caller(raw: %s, other: %s) -> %s =\n  let v = check c raw\n  let w = other\n  needs w\n"
      p.ty p.ty p.ty
  | `IfThenOnly ->
    Printf.sprintf
      "fn caller(raw: %s, flag: Bool) -> %s =\n  let v = if flag then\n      check c raw\n    else\n      raw\n  needs v\n"
      p.ty p.ty
  | `IfElseOnly ->
    Printf.sprintf
      "fn caller(raw: %s, flag: Bool) -> %s =\n  let v = if flag then\n      raw\n    else\n      check c raw\n  needs v\n"
      p.ty p.ty
  | `IfBothNoMerge ->
    (* both branches validate the SAME proof; the join still drops it *)
    Printf.sprintf
      "fn caller(raw: %s, flag: Bool) -> %s =\n  let v = if flag then\n      check c raw\n    else\n      check c raw\n  needs v\n"
      p.ty p.ty
  | `CaseRawPayload ->
    Printf.sprintf
      "fn caller(mx: Maybe %s) -> %s =\n  case mx of\n    Nothing -> %s\n    Something v -> needs v\n"
      p.ty p.ty p.zero
  | `CaseOneArmValidates ->
    Printf.sprintf
      "fn caller(mx: Maybe %s) -> %s =\n  case mx of\n    Nothing -> %s\n    Something v ->\n      let checked = check c v\n      needs v\n"
      p.ty p.ty p.zero

let flow_param_cases () =
  let mistakes =
    [ `LetUnchecked; `LetPassthrough; `LetWrongBinding;
      `IfThenOnly; `IfElseOnly; `IfBothNoMerge;
      `CaseRawPayload; `CaseOneArmValidates ] in
  let mtag = function
    | `LetUnchecked -> "LU" | `LetPassthrough -> "LP" | `LetWrongBinding -> "LW"
    | `IfThenOnly -> "IT" | `IfElseOnly -> "IE" | `IfBothNoMerge -> "IB"
    | `CaseRawPayload -> "CR" | `CaseOneArmValidates -> "CO" in
  let mlabel = function
    | `LetUnchecked -> "let-unchecked" | `LetPassthrough -> "let-passthrough-drops"
    | `LetWrongBinding -> "let-wrong-binding"
    | `IfThenOnly -> "if-then-only" | `IfElseOnly -> "if-else-only"
    | `IfBothNoMerge -> "if-both-no-merge"
    | `CaseRawPayload -> "case-raw-payload" | `CaseOneArmValidates -> "case-one-arm" in
  List.concat_map (fun mistake ->
    let osuffix = mtag mistake in
    List.mapi (fun i p ->
      let suffix = Printf.sprintf "%s%d" osuffix i in
      let modname = Printf.sprintf "CPar%s" suffix in
      let src = prelude modname ^ p.imports ^ pred_decls p ^ flow_caller mistake p in
      let label = Printf.sprintf "C-PAR %s/%s" (mlabel mistake) p.pname in
      test_case label `Quick (fun () -> should_fail unsat src))
      (predicates osuffix))
    mistakes

(* ── Runner ──────────────────────────────────────────────────────────────── *)

let () =
  run "ProofSuite-C-Flow" [
    "flow-let", [
      test_case "C let-bound unchecked value" `Quick test_C_let_unchecked;
      test_case "C let rebinds via passthru drops proof" `Quick test_C_let_rebinds_raw;
      test_case "C let wrong binding consumed" `Quick test_C_let_wrong_binding;
      test_case "C let arithmetic drops proof" `Quick test_C_let_arith_drops;
    ];
    "flow-if", [
      test_case "C if then-branch only" `Quick test_C_if_then_only;
      test_case "C if else-branch only" `Quick test_C_if_else_only;
      test_case "C if both branches different subject" `Quick test_C_if_both_branches_diff_subject;
      test_case "C if both branches no proof merge (conservative join)" `Quick test_C_if_both_branches_no_merge;
      test_case "C nested let+if no proof merge (conservative join)" `Quick test_C_nested_let_if_no_merge;
    ];
    "flow-case", [
      test_case "C case non-proof scrutinee" `Quick test_C_case_nonproof_scrutinee;
      test_case "C case ADT unproven payload" `Quick test_C_case_adt_unproven;
      test_case "C case one arm validates" `Quick test_C_case_one_arm_validates;
    ];
    "flow-shadowing-7.4", [
      test_case "C shadowing rejected" `Quick test_C_shadowing_rejected;
      test_case "C shadow proven with raw" `Quick test_C_shadow_proven_with_raw;
    ];
    "flow-parameterized", flow_param_cases ();
    "flow-positive-sanity", [
      test_case "C+ let flows" `Quick test_C_pos_let_flows;
      test_case "C+ let chain" `Quick test_C_pos_let_chain;
      test_case "C+ case proof through Something" `Quick test_C_pos_case_proof_through_something;
      test_case "C+ let then case arm validates" `Quick test_C_pos_let_then_case_arm_validates;
      test_case "C+ proof param through let" `Quick test_C_pos_proof_param_through_let;
      test_case "C+ case conjunction Maybe" `Quick test_C_pos_case_conjunction_maybe;
      test_case "C+ handler nested let" `Quick test_C_pos_handler_nested_let;
    ];
  ]
