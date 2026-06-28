(** Safety-net negative tests — the compile-time proof/capability guarantees.

    The Racket runtime carries a *gated* safety net (proof/validation evidence
    that survives only under [TESL_ZERO_COST_PROOFS=0]); the production default
    erases it.  The roadmap (remove_old_safety_net / zero_cost_capabilities)
    wants the compiler to BE the guarantee, so that even with the runtime net
    fully erased no unsafe program slips through.

    These tests pin that down: each asserts the OCaml compiler rejects an unsafe
    program at `--check` time, independent of any runtime mode.  If someone later
    weakens a compile-time check (reasoning "the runtime net will catch it"), the
    corresponding test fails — surfacing the loss of the static guarantee before
    the net is removed.

    Group PN — proofs:    proof construction / decomposition / subject / matching.
    Group CN — caps:      capability declaration is mandatory and complete.
    Group PC — positive:  the *safe* forms still compile (no false rejection).

    Companion: test_capability_polymorphism.ml (row-variable specifics). *)

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
  let code = match status with
    | Unix.WEXITED c -> c | Unix.WSIGNALED n -> 128+n | Unix.WSTOPPED n -> 128+n
  in (code, out)

let run_compiler args =
  let quoted = Filename.quote compiler :: List.map Filename.quote args in
  run_command (String.concat " " quoted ^ " 2>&1")

let failf fmt = Printf.ksprintf failwith fmt

(* The compiler resolves a module by its file name, so the temp file must be
   named after the `module X` header (kebab-cased) or a spurious V001
   name-mismatch error masks the property under test. *)
let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-pneg" "" in
  let name =
    let re = Str.regexp "module[ \t\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
    try
      ignore (Str.search_forward re content 0);
      let mname = Str.matched_group 1 content in
      let buf = Buffer.create (String.length mname + 4) in
      String.iteri (fun i c ->
        if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
        else if c >= 'A' && c <= 'Z' then (Buffer.add_char buf '-'; Buffer.add_char buf (Char.lowercase_ascii c))
        else Buffer.add_char buf c
      ) mname;
      Buffer.contents buf ^ ".tesl"
    with Not_found -> "test.tesl"
  in
  let path = Filename.concat dir name in
  let oc = open_out path in output_string oc content; close_out oc;
  Fun.protect
    ~finally:(fun () -> (try Sys.remove path with _ -> ()); (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected success, got:\n%s" out)

(* [pat] is a (case-insensitive) regexp; keep patterns free of regexp specials so
   they read as the literal guarantee. *)
let should_fail pat src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected failure matching %S, but succeeded" pat;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pat out)

(* ── PN — proof guarantees ─────────────────────────────────────────────────── *)

(* Proof *construction* is confined to boundary functions (check/auth/establish).
   A plain `fn` may not mint `ok … ::: Proof` evidence out of thin air. *)
let test_PN01_proof_construction_in_fn () =
  should_fail "proof construction is not allowed" {|
module ProofNegConstruct exposing [f]
import Tesl.Prelude exposing [Int]
fact P (n: Int)
fn f(n: Int) -> Int ::: P n =
  ok n ::: P n
|}

(* A plain `fn` cannot DECLARE a proof-carrying return unless that proof arrived
   on an input parameter — it cannot fabricate a guarantee on a fresh value. *)
let test_PN02_fn_declares_unjustified_proof () =
  should_fail "cannot declare a proof-carrying return type" {|
module ProofNegDeclare exposing [f]
import Tesl.Prelude exposing [Int]
fact P (n: Int)
fn f(n: Int) -> Int ::: P n =
  n
|}

(* Proof *decomposition* (`let (x ::: p) = v`) requires the value to actually
   carry a proof; decomposing a bare value is rejected, so `p` can never be a
   forged witness. *)
let test_PN03_decompose_non_proof () =
  should_fail "requires at least one attached proof" {|
module ProofNegDecompose exposing [g]
import Tesl.Prelude exposing [Int]
fn g(y: Int) -> Int =
  let (stripped ::: proof) = y
  stripped
|}

(* The returned proof must match the declared return spec — a check cannot
   advertise `P` while proving `Q`. *)
let test_PN04_ok_proof_mismatch () =
  should_fail "does not match declared return spec" {|
module ProofNegMismatch exposing [f]
import Tesl.Prelude exposing [Int]
fact P (n: Int)
fact Q (n: Int)
check f(n: Int) -> n: Int ::: P n =
  ok n ::: Q n
|}

(* Proof subjects must be trackable local identifiers, never dotted paths — a
   path like `r.val` is not stable evidence (GDP subject rule). *)
let test_PN05_dotted_path_proof_subject () =
  should_fail "not a valid GDP subject\\|dotted path" {|
module ProofNegDotted exposing [Rec, f]
import Tesl.Prelude exposing [Int]
fact P (n: Int)
record Rec { val: Int }
check f(r: Rec) -> v: Int ::: P r.val =
  ok r.val ::: P r.val
|}

(* The `ok` expression must return the declared binding (or a constructor of it),
   not an arbitrary unrelated expression that wouldn't carry the binding's proof. *)
let test_PN06_ok_returns_non_identifier () =
  should_fail "non-identifier\\|must return the declared binding" {|
module ProofNegOkExpr exposing [f]
import Tesl.Prelude exposing [Int]
fact P (n: Int)
check f(n: Int) -> n: Int ::: P n =
  ok (n + 1) ::: P n
|}

(* A return binding may not reuse an input binder's name at a different type —
   that would silently re-tag a value the proof does not cover. *)
let test_PN07_binder_reuse_different_type () =
  should_fail "reuses input binder" {|
module ProofNegBinder exposing [parsePort]
import Tesl.Prelude exposing [Int, String]
fact ValidPort (port: Int)
check parsePort(port: String) -> port: Int ::: ValidPort port =
  fail 400 "nope"
|}

(* ── CN — capability guarantees ────────────────────────────────────────────── *)

(* A `requires []` function that transitively uses a capability-bearing callee is
   rejected — the capability set is a hard, complete declaration, not advisory. *)
let test_CN01_capability_leak () =
  should_fail "does not declare them\\|dbThing" {|
module CapNegLeak exposing [bad]
import Tesl.Prelude exposing [Int]
capability dbThing
fn helper(x: Int) -> Int requires [dbThing] =
  x
fn bad(x: Int) -> Int requires [] =
  helper x
|}

(* Capabilities must be declared before use; an undeclared name in `requires`
   is an error, not an implicitly-minted capability. *)
let test_CN02_undeclared_capability () =
  should_fail "undeclared capability" {|
module CapNegUndeclared exposing [f]
import Tesl.Prelude exposing [Int]
fn f(x: Int) -> Int requires [mystery] =
  x
|}

(* ── PC — positive controls (the safe forms still compile) ─────────────────── *)

(* A real boundary check constructs the proof — this is the *sanctioned* place,
   so it must compile (guards against the negatives over-rejecting). *)
let test_PC01_check_constructs_proof () =
  should_pass {|
module ProofPosCheck exposing [validate]
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
check validate(n: Int) -> n: Int ::: Positive n =
  if n > 0 then
    ok n ::: Positive n
  else
    fail 400 "must be positive"
|}

(* Propagating a proof that arrived on an input parameter is allowed in a plain
   `fn`: the proof is justified by the input, not fabricated.  The return must
   *name* the binding it forwards (`-> n: … ::: …`) — the identity-proof pattern —
   so the checker can see the returned value is the proof-bearing input. *)
let test_PC02_fn_propagates_input_proof () =
  should_pass {|
module ProofPosPropagate exposing [identityProof]
import Tesl.Prelude exposing [Int]
fact Positive (n: Int)
fn identityProof(n: Int ::: Positive n) -> n: Int ::: Positive n =
  n
|}

(* A function that declares the capabilities it (transitively) uses compiles —
   the complement of CN01. *)
let test_PC03_declared_capability_ok () =
  should_pass {|
module CapPosDeclared exposing [good]
import Tesl.Prelude exposing [Int]
capability dbThing
fn helper(x: Int) -> Int requires [dbThing] =
  x
fn good(x: Int) -> Int requires [dbThing] =
  helper x
|}

let () =
  run "proof-negatives" [
    "proofs", [
      test_case "PN01 proof construction confined to boundaries" `Quick test_PN01_proof_construction_in_fn;
      test_case "PN02 fn cannot declare unjustified proof"       `Quick test_PN02_fn_declares_unjustified_proof;
      test_case "PN03 cannot decompose a non-proof value"        `Quick test_PN03_decompose_non_proof;
      test_case "PN04 returned proof must match return spec"      `Quick test_PN04_ok_proof_mismatch;
      test_case "PN05 proof subject cannot be a dotted path"     `Quick test_PN05_dotted_path_proof_subject;
      test_case "PN06 ok must return the declared binding"        `Quick test_PN06_ok_returns_non_identifier;
      test_case "PN07 return binder cannot retype an input"       `Quick test_PN07_binder_reuse_different_type;
    ];
    "capabilities", [
      test_case "CN01 capability use must be declared (leak)"     `Quick test_CN01_capability_leak;
      test_case "CN02 undeclared capability rejected"             `Quick test_CN02_undeclared_capability;
    ];
    "positive", [
      test_case "PC01 boundary check constructs proof"            `Quick test_PC01_check_constructs_proof;
      test_case "PC02 fn propagates input proof"                  `Quick test_PC02_fn_propagates_input_proof;
      test_case "PC03 declared capability compiles"               `Quick test_PC03_declared_capability_ok;
    ];
  ]
