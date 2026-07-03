(** ProofSuite Family D — conjunctions `P && Q`, composition `check (f && g)`,
    decomposition `let (a ::: pa && qa) = v`.

    NEG-CORE: compile-time rejection of every "have some conjuncts but not all"
    / "decomposed and mis-used a conjunct" mistake, proven WITHOUT the runtime
    net. Modeled on [test_library_negative.ml] / [test_review20_antagonistic.ml].

    Every negative is STATIC: [should_fail] asserts non-zero exit AND no runtime
    leak. A negative that compiles is a real static-checker gap.

    Anchors: combined-check proof propagation (Review20 §1.1), decomposition via
    `let (x ::: p && q)`, `validation_proof.ml` V001/P001. *)

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
  let dir = Filename.temp_dir "tesl-psD" "" in
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
let spec_mismatch = "does not match declared return spec"

(* Three single-predicate checks P, Q, R over Int (multi-line `if` mandatory). *)
let pqr_checks =
  {|
fact P (n: Int)
fact Q (n: Int)
fact R (n: Int)
check cp(n: Int) -> n: Int ::: P n =
  if n > 0 then
    ok n ::: P n
  else
    fail 400 "p"
check cq(n: Int) -> n: Int ::: Q n =
  if n < 100 then
    ok n ::: Q n
  else
    fail 400 "q"
check cr(n: Int) -> n: Int ::: R n =
  if n > 5 then
    ok n ::: R n
  else
    fail 400 "r"
|}

(* ── D. Conjunction at CONSUMPTION (have subset, need more) ──────────────── *)

(* have P (single check) but consumer requires P && Q. *)
let test_D_have_P_need_PQ () =
  should_fail unsat (prelude "DHavePNeedPQ" ^ pqr_checks ^ {|
fn needsBoth(n: Int ::: P n && Q n) -> Int = n
fn caller(raw: Int) -> Int =
  let v = check cp raw
  needsBoth v
|})

(* have P && Q (combined check) but consumer requires P && Q && R. *)
let test_D_have_PQ_need_PQR () =
  should_fail unsat (prelude "DHavePQNeedPQR" ^ pqr_checks ^ {|
fn needsAll(n: Int ::: P n && Q n && R n) -> Int = n
fn caller(raw: Int) -> Int =
  let v = check (cp && cq) raw
  needsAll v
|})

(* have only the last conjunct, need all three. *)
let test_D_have_R_need_PQR () =
  should_fail unsat (prelude "DHaveRNeedPQR" ^ pqr_checks ^ {|
fn needsAll(n: Int ::: P n && Q n && R n) -> Int = n
fn caller(raw: Int) -> Int =
  let v = check cr raw
  needsAll v
|})

(* compose `check (cp && cq)` then require a predicate NEITHER produces. *)
let test_D_compose_require_unrelated () =
  should_fail unsat (prelude "DComposeUnrel" ^ pqr_checks ^ {|
fn needsR(n: Int ::: R n) -> Int = n
fn caller(raw: Int) -> Int =
  let v = check (cp && cq) raw
  needsR v
|})

(* swapped order should still satisfy — but here we require an extra one. *)
let test_D_have_QP_need_PQR () =
  should_fail unsat (prelude "DHaveQPNeedPQR" ^ pqr_checks ^ {|
fn needsAll(n: Int ::: P n && Q n && R n) -> Int = n
fn caller(raw: Int) -> Int =
  let v = check (cq && cp) raw
  needsAll v
|})

(* ── D. Conjunction at PRODUCTION ────────────────────────────────────────── *)

(* check declares P && Q but produces only P. *)
let test_D_produce_P_declare_PQ () =
  should_fail spec_mismatch (prelude "DProdP" ^ {|
fact P (n: Int)
fact Q (n: Int)
check c(n: Int) -> n: Int ::: P n && Q n =
  if n > 0 then
    ok n ::: P n
  else
    fail 400 "bad"
|})

(* check declares P x && Q x but produces P x && Q y (wrong subject in one conjunct). *)
let test_D_produce_wrong_subject_in_conjunct () =
  should_fail spec_mismatch (prelude "DProdSubjMix" ^ {|
fact P (n: Int)
fact Q (n: Int)
check c(x: Int, y: Int) -> x: Int ::: P x && Q x =
  if x > 0 then
    ok x ::: P x && Q y
  else
    fail 400 "bad"
|})

(* check declares P but produces P && Q (over-produces). *)
let test_D_produce_PQ_declare_P () =
  should_fail spec_mismatch (prelude "DProdPQ" ^ {|
fact P (n: Int)
fact Q (n: Int)
check c(n: Int) -> n: Int ::: P n =
  if n > 0 then
    ok n ::: P n && Q n
  else
    fail 400 "bad"
|})

(* check declares P && Q && R but produces P && Q. *)
let test_D_produce_PQ_declare_PQR () =
  should_fail spec_mismatch (prelude "DProdPQR" ^ {|
fact P (n: Int)
fact Q (n: Int)
fact R (n: Int)
check c(n: Int) -> n: Int ::: P n && Q n && R n =
  if n > 0 then
    ok n ::: P n && Q n
  else
    fail 400 "bad"
|})

(* ── D. Decomposition (`let (a ::: pa && qa) = v`) ───────────────────────── *)

(* after decomposition, the decomposed value `val` no longer carries proofs;
   passing it where P is required must fail. *)
let test_D_decomp_value_loses_proof () =
  should_fail unsat (prelude "DDecompVal" ^ pqr_checks ^ {|
fn needsP(n: Int ::: P n) -> Int = n
fn caller(raw: Int) -> Int =
  let (val ::: pa && qa) = check (cp && cq) raw
  needsP val
|})

(* re-attach only one conjunct (pa) but require both P && Q. *)
let test_D_decomp_reattach_one_need_both () =
  should_fail unsat (prelude "DDecompOne" ^ pqr_checks ^ {|
fn needsBoth(n: Int ::: P n && Q n) -> Int = n
fn caller(raw: Int) -> Int =
  let (val ::: pa && qa) = check (cp && cq) raw
  needsBoth (attachFact val pa)
|})

(* decompose then use the wrong single conjunct where the other is required. *)
let test_D_decomp_wrong_conjunct () =
  should_fail unsat (prelude "DDecompWrong" ^ pqr_checks ^ {|
fn needsQ(n: Int ::: Q n) -> Int = n
fn caller(raw: Int) -> Int =
  let (val ::: pa && qa) = check (cp && cq) raw
  needsQ (attachFact val pa)
|})

(* destructuring a value that carries NO proof at all. *)
let test_D_destructure_no_proof () =
  should_fail "proof destructuring.*requires at least one attached proof\\|carries none"
    (prelude "DDestrNone" ^ {|
fact P (n: Int)
fn caller(raw: Int) -> Int =
  let (val ::: pa) = raw
  val
|})

(* ── D. Positive sanity — conjunctions used correctly ────────────────────── *)

let test_D_pos_combined_check_both () =
  should_pass (prelude "DPosBoth" ^ pqr_checks ^ {|
fn needsBoth(n: Int ::: P n && Q n) -> Int = n
fn caller(raw: Int) -> Int =
  let v = check (cp && cq) raw
  needsBoth v
|})

let test_D_pos_combined_check_swapped () =
  (* order of checks in the combined-check should not matter for the AND. *)
  should_pass (prelude "DPosSwap" ^ pqr_checks ^ {|
fn needsBoth(n: Int ::: P n && Q n) -> Int = n
fn caller(raw: Int) -> Int =
  let v = check (cq && cp) raw
  needsBoth v
|})

let test_D_pos_three_way_combined () =
  should_pass (prelude "DPosThree" ^ pqr_checks ^ {|
fn needsAll(n: Int ::: P n && Q n && R n) -> Int = n
fn caller(raw: Int) -> Int =
  let v = check (cp && cq && cr) raw
  needsAll v
|})

let test_D_pos_combined_subset_consumer () =
  (* having P && Q, a consumer needing only P is satisfied. *)
  should_pass (prelude "DPosSubset" ^ pqr_checks ^ {|
fn needsP(n: Int ::: P n) -> Int = n
fn caller(raw: Int) -> Int =
  let v = check (cp && cq) raw
  needsP v
|})

let test_D_pos_produce_conjunction () =
  should_pass (prelude "DPosProd" ^ {|
fact P (n: Int)
fact Q (n: Int)
check c(n: Int) -> n: Int ::: P n && Q n =
  if n > 0 && n < 100 then
    ok n ::: P n && Q n
  else
    fail 400 "bad"
|})

let test_D_pos_decomp_single_reattach () =
  (* decompose a single-predicate value, re-attach, consume. *)
  should_pass (prelude "DPosDecomp" ^ pqr_checks ^ {|
fn needsP(n: Int ::: P n) -> Int = n
fn caller(raw: Int) -> Int =
  let v = check (cp && cq) raw
  let (val ::: pa && qa) = v
  needsP (attachFact val pa)
|})

let test_D_pos_three_way_subset_consumer () =
  (* validate three, then a consumer needing only a 2-conjunct subset (P && R). *)
  should_pass (prelude "DPosThreeSub" ^ pqr_checks ^ {|
fn needsTwo(n: Int ::: P n && R n) -> Int = n
fn caller(raw: Int) -> Int =
  let v = check (cp && cq && cr) raw
  needsTwo v
|})

let test_D_pos_subset_single_from_conjunction () =
  (* having P && Q && R, a consumer needing just Q is satisfied. *)
  should_pass (prelude "DPosOneFromThree" ^ pqr_checks ^ {|
fn needsQ(n: Int ::: Q n) -> Int = n
fn caller(raw: Int) -> Int =
  let v = check (cp && cq && cr) raw
  needsQ v
|})

(* ── D. Parameterized CONJUNCTION negatives (Tier 2) ─────────────────────── *)
(* For each predicate-type axis, generate: have-1-need-2, have-2-need-3,
   compose-need-unrelated, produce-under, produce-over. *)

type pred = {
  pfx : string;     (* unique prefix for fact names *)
  ty : string;      (* subject type *)
  cond : string;    (* boolean over `x` *)
  imports : string;
}

let predicates suffix = [
  { pfx = "Dci" ^ suffix; ty = "Int"; cond = "x > 0"; imports = "" };
  { pfx = "Dcs" ^ suffix; ty = "String"; cond = "String.length x > 0";
    imports = "import Tesl.String exposing [String.length]\n" };
  { pfx = "Dcj" ^ suffix; ty = "Int"; cond = "x >= 1 && x <= 100"; imports = "" };
  { pfx = "Dck" ^ suffix; ty = "Int"; cond = "x > 10"; imports = "" };
  { pfx = "Dct" ^ suffix; ty = "String"; cond = "String.length x >= 2";
    imports = "import Tesl.String exposing [String.length]\n" };
]

(* label disambiguator keyed on the 3rd char of the prefix (i/s/j/k/t) *)
let pname p =
  if String.length p.pfx < 3 then p.ty
  else match p.pfx.[2] with
    | 'i' -> "Int" | 's' -> "String" | 'j' -> "Int2" | 'k' -> "Int3" | 't' -> "String2"
    | _ -> p.ty

(* declare three facts A,B,C of type p.ty with three checks ca,cb,cc *)
let abc_decls p =
  let mk nm = Printf.sprintf "fact %s%s (v: %s)" p.pfx nm p.ty in
  let chk cname fname =
    Printf.sprintf
      "check %s(x: %s) -> x: %s ::: %s%s x =\n  if %s then\n    ok x ::: %s%s x\n  else\n    fail 400 \"bad\"\n"
      cname p.ty p.ty p.pfx fname p.cond p.pfx fname
  in
  String.concat "\n" [ mk "A"; mk "B"; mk "C" ] ^ "\n"
  ^ chk "ca" "A" ^ chk "cb" "B" ^ chk "cc" "C"

let conj_param_cases () =
  let mistakes =
    [ `Have1Need2; `Have2Need3; `ComposeUnrelated; `ProduceUnder; `ProduceOver;
      `DecompLoseProof; `DecompReattachOne; `DecompWrongConjunct ] in
  let mtag = function
    | `Have1Need2 -> "H1" | `Have2Need3 -> "H2"
    | `ComposeUnrelated -> "CU" | `ProduceUnder -> "PU" | `ProduceOver -> "PO"
    | `DecompLoseProof -> "DL" | `DecompReattachOne -> "DR" | `DecompWrongConjunct -> "DW" in
  let mlabel = function
    | `Have1Need2 -> "have1-need2" | `Have2Need3 -> "have2-need3"
    | `ComposeUnrelated -> "compose-need-unrelated"
    | `ProduceUnder -> "produce-under" | `ProduceOver -> "produce-over"
    | `DecompLoseProof -> "decomp-loses-proof"
    | `DecompReattachOne -> "decomp-reattach-one-need-both"
    | `DecompWrongConjunct -> "decomp-wrong-conjunct" in
  List.concat_map (fun mistake ->
    let osuffix = mtag mistake in
    List.mapi (fun i p ->
      let suffix = Printf.sprintf "%s%d" osuffix i in
      let modname = Printf.sprintf "DPar%s" suffix in
      let body, pat =
        match mistake with
        | `Have1Need2 ->
          (Printf.sprintf
             "fn needsAB(x: %s ::: %sA x && %sB x) -> %s = x\nfn caller(raw: %s) -> %s =\n  let v = check ca raw\n  needsAB v\n"
             p.ty p.pfx p.pfx p.ty p.ty p.ty, unsat)
        | `Have2Need3 ->
          (Printf.sprintf
             "fn needsABC(x: %s ::: %sA x && %sB x && %sC x) -> %s = x\nfn caller(raw: %s) -> %s =\n  let v = check (ca && cb) raw\n  needsABC v\n"
             p.ty p.pfx p.pfx p.pfx p.ty p.ty p.ty, unsat)
        | `ComposeUnrelated ->
          (Printf.sprintf
             "fn needsC(x: %s ::: %sC x) -> %s = x\nfn caller(raw: %s) -> %s =\n  let v = check (ca && cb) raw\n  needsC v\n"
             p.ty p.pfx p.ty p.ty p.ty, unsat)
        | `ProduceUnder ->
          (Printf.sprintf
             "check cunder(x: %s) -> x: %s ::: %sA x && %sB x =\n  if %s then\n    ok x ::: %sA x\n  else\n    fail 400 \"bad\"\n"
             p.ty p.ty p.pfx p.pfx p.cond p.pfx, spec_mismatch)
        | `ProduceOver ->
          (Printf.sprintf
             "check cover(x: %s) -> x: %s ::: %sA x =\n  if %s then\n    ok x ::: %sA x && %sB x\n  else\n    fail 400 \"bad\"\n"
             p.ty p.ty p.pfx p.cond p.pfx p.pfx, spec_mismatch)
        | `DecompLoseProof ->
          (* after decomposition, the decomposed value carries no proof *)
          (Printf.sprintf
             "fn needsA(x: %s ::: %sA x) -> %s = x\nfn caller(raw: %s) -> %s =\n  let (val ::: pa && qa) = check (ca && cb) raw\n  needsA val\n"
             p.ty p.pfx p.ty p.ty p.ty, unsat)
        | `DecompReattachOne ->
          (* re-attach only the first conjunct but require both *)
          (Printf.sprintf
             "fn needsAB(x: %s ::: %sA x && %sB x) -> %s = x\nfn caller(raw: %s) -> %s =\n  let (val ::: pa && qa) = check (ca && cb) raw\n  needsAB (attachFact val pa)\n"
             p.ty p.pfx p.pfx p.ty p.ty p.ty, unsat)
        | `DecompWrongConjunct ->
          (* re-attach conjunct pa (A) but consumer requires B *)
          (Printf.sprintf
             "fn needsB(x: %s ::: %sB x) -> %s = x\nfn caller(raw: %s) -> %s =\n  let (val ::: pa && qa) = check (ca && cb) raw\n  needsB (attachFact val pa)\n"
             p.ty p.pfx p.ty p.ty p.ty, unsat)
      in
      let src = prelude modname ^ p.imports ^ abc_decls p ^ body in
      let label = Printf.sprintf "D-PAR %s/%s" (mlabel mistake) (pname p) in
      test_case label `Quick (fun () -> should_fail pat src))
      (predicates osuffix))
    mistakes

(* ── Runner ──────────────────────────────────────────────────────────────── *)

let () =
  run "ProofSuite-D-Conjunction" [
    "conjunction-consume", [
      test_case "D have P need P && Q" `Quick test_D_have_P_need_PQ;
      test_case "D have P && Q need P && Q && R" `Quick test_D_have_PQ_need_PQR;
      test_case "D have R need P && Q && R" `Quick test_D_have_R_need_PQR;
      test_case "D compose require unrelated R" `Quick test_D_compose_require_unrelated;
      test_case "D have Q && P need P && Q && R" `Quick test_D_have_QP_need_PQR;
    ];
    "conjunction-produce", [
      test_case "D produce P declare P && Q" `Quick test_D_produce_P_declare_PQ;
      test_case "D produce wrong subject in conjunct" `Quick test_D_produce_wrong_subject_in_conjunct;
      test_case "D produce P && Q declare P" `Quick test_D_produce_PQ_declare_P;
      test_case "D produce P && Q declare P && Q && R" `Quick test_D_produce_PQ_declare_PQR;
    ];
    "conjunction-decompose", [
      test_case "D decomp value loses proof" `Quick test_D_decomp_value_loses_proof;
      test_case "D decomp reattach one need both" `Quick test_D_decomp_reattach_one_need_both;
      test_case "D decomp wrong conjunct" `Quick test_D_decomp_wrong_conjunct;
      test_case "D destructure no proof" `Quick test_D_destructure_no_proof;
    ];
    "conjunction-parameterized", conj_param_cases ();
    "conjunction-positive-sanity", [
      test_case "D+ combined check both" `Quick test_D_pos_combined_check_both;
      test_case "D+ combined check swapped" `Quick test_D_pos_combined_check_swapped;
      test_case "D+ three-way combined" `Quick test_D_pos_three_way_combined;
      test_case "D+ combined subset consumer" `Quick test_D_pos_combined_subset_consumer;
      test_case "D+ produce conjunction" `Quick test_D_pos_produce_conjunction;
      test_case "D+ decompose single reattach" `Quick test_D_pos_decomp_single_reattach;
      test_case "D+ three-way then subset consumer" `Quick test_D_pos_three_way_subset_consumer;
      test_case "D+ single conjunct from three" `Quick test_D_pos_subset_single_from_conjunction;
    ];
  ]
