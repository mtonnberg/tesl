(** Safety-net negative tests — the compile-time proof/capability guarantees.

    Proofs are erased at run time (zero-cost is the only mode), so the OCaml
    compiler's static checker IS the guarantee: no unsafe program may slip
    through, because there is no runtime net behind it.

    These tests pin that down: each asserts the OCaml compiler rejects an unsafe
    program at `--check` time.  If someone later weakens a compile-time check
    (reasoning "something downstream will catch it"), the corresponding test
    fails — surfacing the loss of the static guarantee.

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
  (* A6: the return is UNNAMED (`-> Int ::: P n`), so after removing the T001
     spelling carve-out it is caught by the preserved well-formedness rule
     (a proof-carrying return must name its binding) — the sharper, T001-emitted
     diagnostic.  V001 also fires, but we pin the precise new rule. *)
  should_fail "proof-carrying return type must name its binding" {|
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

(* CAP-A1 (formal-review HIGH).  insertMany / updateAndReturnOne /
   deleteAndReturnResult are real DB-write emitters, but the capability
   write-set restated them inconsistently and omitted these three — so a handler
   whose only write was `insertMany` was statically inferred to need no
   [dbWrite].  Classification now flows from the single SQL registry; using
   insertMany under a dbRead-only declaration must require dbWrite. *)
let test_CN03_insertMany_requires_dbWrite () =
  should_fail "dbWrite" {|
module CapNegInsertMany exposing [f]
import Tesl.Prelude exposing [Int, String, List, Unit]
import Tesl.DB exposing [dbRead]
entity Product table "products" primaryKey id {
  id: String
  qty: Int
}
fn f(items: List Product) -> Unit requires [dbRead] =
  insertMany items in Product
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

(* GDP-FORGE-1 (formal-review CRITICAL).  A `fn` may legitimately introduce its
   declared return proof in the body via `attachFact` with an establish-produced
   Fact — but ONLY when the attached Fact carries the DECLARED predicate.  The
   previous gate accepted the body whenever it *syntactically mentioned*
   `attachFact`/`attach`/`ok` anywhere (decide-by-spelling), so a body attaching
   an UNRELATED predicate could still declare an arbitrary return proof; because
   proofs are erased at runtime, that forged value then satisfied every
   downstream obligation silently.  This pins that the rejection now decides by
   proof CONTENT: attaching `Whatever` cannot satisfy a declared `IsPositive`. *)
let test_PN08_attach_unrelated_fact_forgery () =
  should_fail "cannot declare a proof return type" {|
module ProofNegAttachForge exposing [forge]
import Tesl.Prelude exposing [Int, Fact, attachFact]
fact Whatever (n: Int)
fact IsPositive (n: Int)
establish makeWhatever(n: Int) -> Fact (Whatever n) =
  Whatever n
fn forge(x: Int) -> y: Int ::: IsPositive y =
  let w = makeWhatever x
  let y = attachFact x w
  y
|}

(* Positive companion to PN08: attaching the Fact that DOES carry the declared
   predicate is the legitimate manual-proof pattern and must still compile (the
   fix must not over-reject body-introduced proofs). *)
let test_PC04_attach_matching_fact_ok () =
  should_pass {|
module ProofPosAttachMatch exposing [good]
import Tesl.Prelude exposing [Int, Fact, attachFact]
fact IsPositive (n: Int)
establish makeIsPositive(n: Int) -> Fact (IsPositive n) =
  IsPositive n
fn good(x: Int) -> y: Int ::: IsPositive y =
  let p = makeIsPositive x
  let y = attachFact x p
  y
|}

(* Hole #2 (2026-07-04): an `establish` may not DELEGATE its declared fact to a
   prove-fn that establishes it about a DIFFERENT subject.  The direct-form swap
   `-> Fact (P n) = P m` was already rejected; this closes the delegation path
   `= proveConst()` where proveConst proves `IsPositive 7`, not `_n`. *)
let test_PN09_establish_delegate_wrong_subject () =
  should_fail "delegates to a function that establishes the fact about" {|
module EstDelegateForge exposing [factFor]
import Tesl.Prelude exposing [Int, Fact]
fact IsPositive (n: Int)
establish proveConst() -> Fact (IsPositive 7) =
  IsPositive 7
establish factFor(_n: Int) -> Fact (IsPositive _n) =
  proveConst()
|}

(* Positive companion to PN09: subject-PRESERVING delegation is legitimate —
   `factFor(n)` delegating to `prove(n)` (where `prove(m) -> Fact (IsPositive m)`)
   is about the same subject and must still compile. *)
let test_PC05_establish_delegate_same_subject () =
  should_pass {|
module EstDelegateOk exposing [factFor]
import Tesl.Prelude exposing [Int, Fact]
fact IsPositive (n: Int)
establish prove(m: Int) -> Fact (IsPositive m) =
  IsPositive m
establish factFor(n: Int) -> Fact (IsPositive n) =
  prove(n)
|}

(* Hole #6 (2026-07-04): a proof declared on one type's field must NOT be credited
   when reading a same-named field of an UNRELATED type.  `Public.token` (no proof)
   cannot satisfy an `Admin` requirement declared on `Privileged.token`. *)
let test_PN10_field_proof_cross_type_forge () =
  should_fail "does not statically satisfy declared proof" {|
module FieldProofForge exposing [forge]
import Tesl.Prelude exposing [String, Bool(..)]
import Tesl.String exposing [String.length]
fact Admin (s: String)
check checkAdmin(s: String) -> s: String ::: Admin s =
  if String.length s > 3 then
    ok s ::: Admin s
  else
    fail 403 "no"
record Privileged { token: String ::: Admin token }
record Public { token: String }
fn needAdmin(s: String ::: Admin s) -> String = "admin ${s}"
fn forge(evil: String) -> String =
  let p = Public { token: evil }
  needAdmin p.token
|}

(* Positive companion to PN10: reading the field of the type that ACTUALLY declares
   the proof still credits it. *)
let test_PC06_field_proof_same_type_ok () =
  should_pass {|
module FieldProofOk exposing [useReal]
import Tesl.Prelude exposing [String, Bool(..)]
import Tesl.String exposing [String.length]
fact Admin (s: String)
check checkAdmin(s: String) -> s: String ::: Admin s =
  if String.length s > 3 then
    ok s ::: Admin s
  else
    fail 403 "no"
record Privileged { token: String ::: Admin token }
fn needAdmin(s: String ::: Admin s) -> String = "admin ${s}"
fn useReal(pv: Privileged) -> String = needAdmin pv.token
|}

(* Hole #5-Fact-param (2026-07-04): a `Fact (A)` argument must NOT launder where a
   `Fact (B)` parameter is required (the checker unifies Fact heads, and the
   value-side evidence is opaque, so only the arg's declared Fact TYPE catches it). *)
let test_PN11_fact_typed_param_launder () =
  should_fail "proof mismatch" {|
module FactParamForge exposing [launder]
import Tesl.Prelude exposing [String, Fact]
fact FactA (s: String)
fact FactB (s: String)
fn needB(s: String, _pf: Fact (FactB s)) -> String = s
fn launder(s: String, evA: Fact (FactA s)) -> String = needB s evA
|}

(* Positive companion to PN11: forwarding a MATCHING Fact-typed param compiles. *)
let test_PC07_fact_typed_param_match_ok () =
  should_pass {|
module FactParamOk exposing [passthru]
import Tesl.Prelude exposing [String, Fact]
fact FactB (s: String)
fn needB(s: String, _pf: Fact (FactB s)) -> String = s
fn passthru(s: String, evB: Fact (FactB s)) -> String = needB s evB
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
      test_case "PN08 attaching unrelated fact cannot forge return proof" `Quick test_PN08_attach_unrelated_fact_forgery;
      test_case "PN09 establish cannot delegate to a wrong-subject prove-fn" `Quick test_PN09_establish_delegate_wrong_subject;
      test_case "PN10 field proof not credited across unrelated types" `Quick test_PN10_field_proof_cross_type_forge;
      test_case "PN11 Fact-typed param cannot launder a different fact" `Quick test_PN11_fact_typed_param_launder;
    ];
    "capabilities", [
      test_case "CN01 capability use must be declared (leak)"     `Quick test_CN01_capability_leak;
      test_case "CN02 undeclared capability rejected"             `Quick test_CN02_undeclared_capability;
      test_case "CN03 insertMany requires dbWrite (registry)"     `Quick test_CN03_insertMany_requires_dbWrite;
    ];
    "positive", [
      test_case "PC01 boundary check constructs proof"            `Quick test_PC01_check_constructs_proof;
      test_case "PC02 fn propagates input proof"                  `Quick test_PC02_fn_propagates_input_proof;
      test_case "PC03 declared capability compiles"               `Quick test_PC03_declared_capability_ok;
      test_case "PC04 attaching matching fact compiles"           `Quick test_PC04_attach_matching_fact_ok;
      test_case "PC05 subject-preserving establish delegation compiles" `Quick test_PC05_establish_delegate_same_subject;
      test_case "PC06 same-type field proof still credited" `Quick test_PC06_field_proof_same_type_ok;
      test_case "PC07 matching Fact-typed param forwards" `Quick test_PC07_fact_typed_param_match_ok;
    ];
  ]
