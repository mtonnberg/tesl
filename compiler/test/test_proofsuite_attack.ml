(** ProofSuite — adversarial "gap-hunter" negative tests (NEG-ATTACK).

    These are the highest-value negative tests for TESL's GDP proof system.
    Each one constructs an UNSOUND program and asserts that the *compile-time*
    static checker (`tesl --check`) rejects it — WITHOUT relying on the alpha
    runtime safety net.  They are the evidence that lets us eventually erase
    that net (plan: "i-would-like-to-mellow-sky" → Item A → Top gap-hunters).

    Hardening: `should_fail` additionally asserts the rejection did NOT leak to
    runtime — `tesl --check` must not execute, so a Racket-level proof failure
    (`raise-user-error`, `check-fail`, a Racket stack trace) appearing in the
    output is itself a test failure.  The whole point is *static* rejection.

    Gap-hunter families (see the plan):
      1.  ForAll element leak (runtime net already OFF here → static-only today)
      2.  Laundering (partial-app / alias / lambda / HOF callback)
      3.  Subject confusion (2-arg proof: wrong subject in a leading position)
      4.  Conjunction split-and-reassemble swap
      5.  attachFact retarget (§7.7 — proof about a different subject)
      6.  Cross-module forgery (re-export a fact then try to mint it)
      7.  Skolem escape (§7.9 — currently runtime-only → KNOWN-GAP, separate grp)
      8.  `:::` fabrication in disguise (§7.12 — fn/let/if/case-arm/record field)
      9.  Shadowing to blur subjects (§7.4); forget-then-stale-reattach
      10. Positive counterparts — rejection is specificity, not blanket refusal. *)

open Alcotest

(* ── Compiler-path resolution ─────────────────────────────────────────────── *)
(* env TESL_OCAML_COMPILER / TESL_BIN first, then Sys.argv.(0) → ../bin/main.exe *)

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

let run_command cmd =
  let ic = Unix.open_process_in cmd in
  let out = In_channel.input_all ic in
  let status = Unix.close_process_in ic in
  let code = match status with
    | Unix.WEXITED c -> c | Unix.WSIGNALED n -> 128 + n | Unix.WSTOPPED n -> 128 + n
  in (code, out)

let run_compiler args =
  let quoted = Filename.quote compiler :: List.map Filename.quote args in
  run_command (String.concat " " quoted ^ " 2>&1")

let failf fmt = Printf.ksprintf failwith fmt

(* Derive a kebab/Pascal file name from the `module <Name>`/`library <Name>`
   header so the compiler's file-name↔module resolution is satisfied. *)
let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-neg-attack" "" in
  let name =
    let re = Str.regexp "\\(module\\|library\\)[ \t\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
    try
      ignore (Str.search_forward re content 0);
      let mname = Str.matched_group 2 content in
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

let with_two_files a_name a_src b_name b_src f =
  let dir = Filename.temp_dir "tesl-neg-attack2" "" in
  let path_a = Filename.concat dir (a_name ^ ".tesl") in
  let path_b = Filename.concat dir (b_name ^ ".tesl") in
  let oc_a = open_out path_a in output_string oc_a a_src; close_out oc_a;
  let oc_b = open_out path_b in output_string oc_b b_src; close_out oc_b;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path_a with _ -> ());
      (try Sys.remove path_b with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path_b)

(* ── Runtime-leak guard ───────────────────────────────────────────────────── *)
(* A negative test FAILS if the rejection leaked to the *runtime* instead of the
   static checker.  `tesl --check` must never execute the program, so any of
   these markers in the output means the static gate was bypassed. *)

let runtime_leak_markers =
  [ "raise-user-error"; "check-fail"; "context...:"; "context ...:";
    ".rkt:"; "/racket/"; "raco "; "expander" ]

let assert_no_runtime_leak ~who out =
  List.iter (fun marker ->
    let re = Str.regexp_string marker in
    match Str.search_forward re out 0 with
    | _ ->
      failf
        "%s: rejection LEAKED TO RUNTIME (found %S) — the static checker must \
         reject this WITHOUT executing the program.\nFull output:\n%s"
        who marker out
    | exception Not_found -> ()
  ) runtime_leak_markers

(* Assert: non-zero exit AND output matches case-insensitive regex `pat`,
   AND the rejection did not leak to runtime. *)
let should_fail ?(who = "should_fail") pat src =
  with_temp_file src (fun path ->
    let code, out = run_compiler [check_subcmd; path] in
    assert_no_runtime_leak ~who out;
    if code = 0 then failf "%s: expected failure matching %S, but compiled cleanly.\nOutput:\n%s" who pat out;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "%s: expected failure matching %S, got:\n%s" who pat out)

let two_files_should_fail ?(who = "two_files_should_fail") pat a_name a_src b_name b_src =
  with_two_files a_name a_src b_name b_src (fun path_b ->
    let code, out = run_compiler [check_subcmd; path_b] in
    assert_no_runtime_leak ~who out;
    if code = 0 then failf "%s: expected failure matching %S for %s, but compiled cleanly.\nOutput:\n%s" who pat b_name out;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "%s: expected failure matching %S, got:\n%s" who pat out)

(* Assert: compiles with no `error[`. *)
let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler [check_subcmd; path] in
    let has_error =
      let re = Str.regexp "error\\[" in
      try ignore (Str.search_forward re out 0); true with Not_found -> false
    in
    if has_error || code <> 0 then
      failf "expected clean compile, got (exit %d):\n%s" code out)

(* ── Shared prelude + reusable proof declarations ─────────────────────────── *)
(* NOTE: `Maybe` is NOT exported by Tesl.Prelude in this codebase — it lives in
   Tesl.Maybe — so the prelude imports it from there. *)

let prelude =
  "#lang tesl\n\
   module ProofAttack exposing []\n\
   import Tesl.Prelude exposing [Int, String, Bool(..), List, Fact, forgetFact, attachFact, detachFact, introAnd, andLeft, andRight]\n\
   import Tesl.Maybe exposing [Maybe(..)]\n"

(* Header for a freshly-named module (so file-name resolution is happy). The
   `with_temp_file` helper derives the file name from this header. *)
let mod_header name =
  Printf.sprintf
    "#lang tesl\n\
     module %s exposing []\n\
     import Tesl.Prelude exposing [Int, String, Bool(..), List, Fact, forgetFact, attachFact, detachFact, introAnd, andLeft, andRight]\n\
     import Tesl.Maybe exposing [Maybe(..)]\n"
    name

(* Standard fact/check/sink declarations reused across many cases. *)
let proof_decls = {|
fact IsPositive (n: Int)
fact IsSmall    (n: Int)
fact IsEven     (n: Int)

check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "not positive"

check checkSmall(n: Int) -> n: Int ::: IsSmall n =
  if n < 1000 then
    ok n ::: IsSmall n
  else
    fail 400 "too large"

check checkEven(n: Int) -> n: Int ::: IsEven n =
  if n % 2 == 0 then
    ok n ::: IsEven n
  else
    fail 400 "not even"

fn needPos(n: Int ::: IsPositive n) -> Int = n
fn needSmall(n: Int ::: IsSmall n) -> Int = n
fn needEven(n: Int ::: IsEven n) -> Int = n
fn needBoth(n: Int ::: IsPositive n && IsSmall n) -> Int = n
fn needAll3(n: Int ::: IsPositive n && IsSmall n && IsEven n) -> Int = n
|}

(* Regex fragments matching the static proof-failure family.  The workhorse is
   "does not statically satisfy declared proof". *)
let no_satisfy = "does not statically satisfy\\|requires proof\\|has no tracked .?ForAll"

(* ════════════════════════════════════════════════════════════════════════ *)
(* 1. ForAll element leak                                                     *)
(*    The runtime net is already OFF for ForAll elements                      *)
(*    (check-runtime.rkt:764) → these are static-only TODAY.                  *)
(* ════════════════════════════════════════════════════════════════════════ *)

let forall_imports = "import Tesl.List exposing [List.filterCheck, List.allCheck, List.length, List.map]\n"

(* FA01 — claim ForAll (P && Q) on a list filtered only by P. *)
let test_FA01_forall_conjunction_leak () =
  should_fail ~who:"FA01" no_satisfy
    (prelude ^ forall_imports ^ proof_decls ^ {|
fn needsBoth(xs: List Int ::: ForAll (IsPositive && IsSmall) xs) -> Int = List.length xs
fn leak(raw: List Int) -> Int =
  let xs = List.filterCheck checkPos raw
  needsBoth xs
|})

(* FA02 — feed a `ForAll IsPositive` list to a fn requiring `ForAll IsSmall`. *)
let test_FA02_forall_wrong_predicate () =
  should_fail ~who:"FA02" no_satisfy
    (prelude ^ forall_imports ^ proof_decls ^ {|
fn needsSmall(xs: List Int ::: ForAll (IsSmall) xs) -> Int = List.length xs
fn wrong(raw: List Int) -> Int =
  let xs = List.filterCheck checkPos raw
  needsSmall xs
|})

(* FA03 — pass an UNFILTERED raw list where ForAll is required. *)
let test_FA03_forall_unfiltered_raw () =
  should_fail ~who:"FA03" no_satisfy
    (prelude ^ forall_imports ^ proof_decls ^ {|
fn needsPosList(xs: List Int ::: ForAll (IsPositive) xs) -> Int = List.length xs
fn raw_through(raw: List Int) -> Int = needsPosList raw
|})

(* FA04 — filter by P but require Q only (single-predicate mismatch). *)
let test_FA04_forall_single_predicate_mismatch () =
  should_fail ~who:"FA04" no_satisfy
    (prelude ^ forall_imports ^ proof_decls ^ {|
fn needsEven(xs: List Int ::: ForAll (IsEven) xs) -> Int = List.length xs
fn mism(raw: List Int) -> Int =
  let xs = List.filterCheck checkPos raw
  needsEven xs
|})

(* FA05 — empty list literal does NOT vacuously satisfy ForAll. *)
let test_FA05_forall_empty_literal () =
  should_fail ~who:"FA05" (no_satisfy ^ "\\|ForAll\\|proof")
    (prelude ^ forall_imports ^ proof_decls ^ {|
fn needsPosList(xs: List Int ::: ForAll (IsPositive) xs) -> Int = List.length xs
fn emptyLeak() -> Int = needsPosList []
|})

(* FA06 — filter by P, require (P && Q): partial conjunction is not enough. *)
let test_FA06_forall_partial_conjunction () =
  should_fail ~who:"FA06" no_satisfy
    (prelude ^ forall_imports ^ proof_decls ^ {|
fn needsAll(xs: List Int ::: ForAll (IsPositive && IsSmall && IsEven) xs) -> Int = List.length xs
fn partial(raw: List Int) -> Int =
  let a = List.filterCheck checkPos raw
  let b = List.filterCheck checkSmall a
  needsAll b
|})

(* FA07 — element proof on a mapped list is lost; mapping does not preserve ForAll. *)
let test_FA07_forall_lost_through_map () =
  should_fail ~who:"FA07" no_satisfy
    (prelude ^ forall_imports ^ proof_decls ^ {|
fn bump(n: Int) -> Int = n + 1
fn needsPosList(xs: List Int ::: ForAll (IsPositive) xs) -> Int = List.length xs
fn mapped(raw: List Int) -> Int =
  let xs = List.filterCheck checkPos raw
  let ys = List.map bump xs
  needsPosList ys
|})

(* ════════════════════════════════════════════════════════════════════════ *)
(* 2. Laundering — proof obligation bypassed via indirection.                 *)
(* ════════════════════════════════════════════════════════════════════════ *)

(* LA01 — alias `let g = needsPos`, then `g raw` (direct call w/ raw arg). *)
let test_LA01_alias_direct_call () =
  should_fail ~who:"LA01" no_satisfy
    (prelude ^ proof_decls ^ {|
fn launder(raw: Int) -> Int =
  let g = needPos
  g raw
|})

(* LA02 — alias passed to a HOF: bypasses the proof check on remaining params. *)
let test_LA02_alias_passed_around () =
  should_fail ~who:"LA02" "cannot be passed around"
    (prelude ^ proof_decls ^ {|
fn applyFn(f: Int -> Int, x: Int) -> Int = f x
fn launder(raw: Int) -> Int =
  let g = needPos
  applyFn g raw
|})

(* LA03 — proof-requiring fn passed DIRECTLY as a List.map callback. *)
let test_LA03_named_fn_as_callback () =
  should_fail ~who:"LA03" "cannot be passed as a plain callback\\|plain callback"
    (prelude ^ "import Tesl.List exposing [List.map]\n" ^ proof_decls ^ {|
fn launder(raw: List Int) -> List Int = List.map needPos raw
|})

(* LA04 — lambda alias with proof param passed around. *)
let test_LA04_lambda_alias_passed_around () =
  should_fail ~who:"LA04" "cannot be passed around"
    (prelude ^ "import Tesl.List exposing [List.map]\n" ^ proof_decls ^ {|
fn launder(raw: List Int) -> List Int =
  let g = fn(n: Int ::: IsPositive n) -> needPos n
  List.map g raw
|})

(* LA05 — proof-annotated lambda applied inline to a raw value. *)
let test_LA05_inline_lambda_raw_arg () =
  should_fail ~who:"LA05" no_satisfy
    (prelude ^ proof_decls ^ {|
fn launder(raw: Int) -> Int =
  let f = fn(x: Int ::: IsPositive x) -> needPos x
  f raw
|})

(* LA06 — partial application then call with raw remaining arg. *)
let test_LA06_partial_application_then_raw () =
  should_fail ~who:"LA06" (no_satisfy ^ "\\|cannot be passed around")
    (prelude ^ proof_decls ^ {|
fn takeTwo(a: Int, n: Int ::: IsPositive n) -> Int = a + n
fn launder(raw: Int) -> Int =
  let partial = takeTwo 1
  partial raw
|})

(* LA07 — alias chained through a second alias, then called with raw. *)
let test_LA07_alias_chain () =
  should_fail ~who:"LA07" (no_satisfy ^ "\\|cannot be passed around")
    (prelude ^ proof_decls ^ {|
fn launder(raw: Int) -> Int =
  let g = needPos
  let h = g
  h raw
|})

(* ════════════════════════════════════════════════════════════════════════ *)
(* 3. Subject confusion — multi-argument (2-arg) proofs.                      *)
(* ════════════════════════════════════════════════════════════════════════ *)

(* SC01 — InBounds proven a/b, call requires b/a (swapped leading args). *)
let test_SC01_multiarg_swapped_order () =
  should_fail ~who:"SC01" (no_satisfy ^ "\\|InBounds b a")
    (prelude ^ {|
fact InBounds (lo: Int) (hi: Int) (n: Int)
check inBounds(lo: Int, hi: Int, n: Int) -> n: Int ::: InBounds lo hi n =
  if lo <= n && n <= hi then
    ok n ::: InBounds lo hi n
  else
    fail 400 "b"
fn needInBounds(lo: Int, hi: Int, n: Int ::: InBounds lo hi n) -> Int = n
fn confuse(a: Int, b: Int, x: Int) -> Int =
  let v = check inBounds a b x
  needInBounds b a v
|})

(* SC02 — OwnedBy u1 t proven, deleteTask requires OwnedBy u2 t. *)
let test_SC02_ownedby_wrong_subject () =
  should_fail ~who:"SC02" (no_satisfy ^ "\\|OwnedBy u2")
    (prelude ^ {|
fact OwnedBy (u: String) (t: Int)
check checkOwner(u: String, t: Int) -> t: Int ::: OwnedBy u t =
  if t > 0 then
    ok t ::: OwnedBy u t
  else
    fail 403 "no"
fn deleteTask(u: String, t: Int ::: OwnedBy u t) -> Int = t
fn confuse(u1: String, u2: String, task: Int) -> Int =
  let owned = check checkOwner u1 task
  deleteTask u2 owned
|})

(* SC03 — OwnedBy: a SECOND user's proof cannot satisfy the first user's call. *)
let test_SC03_ownedby_other_user_proof () =
  should_fail ~who:"SC03" (no_satisfy ^ "\\|OwnedBy u1")
    (prelude ^ {|
fact OwnedBy (u: String) (t: Int)
check checkOwner(u: String, t: Int) -> t: Int ::: OwnedBy u t =
  if t > 0 then
    ok t ::: OwnedBy u t
  else
    fail 403 "no"
fn viewTask(u: String, t: Int ::: OwnedBy u t) -> Int = t
fn confuse(u1: String, u2: String, task: Int) -> Int =
  let ownedByU2 = check checkOwner u2 task
  viewTask u1 ownedByU2
|})

(* SC04 — multi-arg: correct subject but wrong VALUE subject (different task). *)
let test_SC04_multiarg_wrong_value_subject () =
  should_fail ~who:"SC04" no_satisfy
    (prelude ^ {|
fact OwnedBy (u: String) (t: Int)
check checkOwner(u: String, t: Int) -> t: Int ::: OwnedBy u t =
  if t > 0 then
    ok t ::: OwnedBy u t
  else
    fail 403 "no"
fn deleteTask(u: String, t: Int ::: OwnedBy u t) -> Int = t
fn confuse(u: String, task1: Int, task2: Int) -> Int =
  let owned1 = check checkOwner u task1
  deleteTask u task2
|})

(* ════════════════════════════════════════════════════════════════════════ *)
(* 4. Conjunction split-and-reassemble swap.                                  *)
(* ════════════════════════════════════════════════════════════════════════ *)

(* CJ01 — decompose (P && Q), bind pp (proves P), use where Q required. *)
let test_CJ01_decompose_use_P_for_Q () =
  should_fail ~who:"CJ01" no_satisfy
    (prelude ^ proof_decls ^ {|
fn swap(raw: Int) -> Int =
  let a = check checkPos raw
  let b = check checkSmall a
  let (v ::: pp && ps) = b
  needSmall <| v ::: pp
|})

(* CJ02 — bind only the P half via `_ && q` discard then mis-use. *)
let test_CJ02_decompose_discard_left () =
  should_fail ~who:"CJ02" no_satisfy
    (prelude ^ proof_decls ^ {|
fn swap(raw: Int) -> Int =
  let a = check checkPos raw
  let b = check checkSmall a
  let (v ::: _ && ps) = b
  needPos <| v ::: ps
|})

(* CJ03 — introAnd across DIFFERENT subjects then attach. *)
let test_CJ03_introand_cross_subject () =
  should_fail ~who:"CJ03" (no_satisfy ^ "\\|IsPositive a && IsSmall a\\|different")
    (prelude ^ proof_decls ^ {|
fn cross(a: Int, b: Int) -> Int =
  let pa = check checkPos a
  let pb = check checkSmall b
  let (_ ::: ppa) = pa
  let (_ ::: ppb) = pb
  let combined = introAnd ppa ppb
  let reat = a ::: combined
  needBoth reat
|})

(* CJ04 — control: a genuine P-only proof reattached where Q is required is
   CORRECTLY rejected.  (Contrast with the andLeft/andRight KNOWN-GAP below:
   this confirms the static checker DOES track single-conjunct subjects — it is
   specifically the projection functions it fails to honor.) *)
let test_CJ04_single_conjunct_misuse_rejected () =
  should_fail ~who:"CJ04" no_satisfy
    (prelude ^ proof_decls ^ {|
fn project(raw: Int) -> Int =
  let pos = check checkPos raw
  let (v ::: pp) = pos
  needSmall <| v ::: pp
|})

(* CJ05 — triple decompose, reassemble missing the middle conjunct. *)
let test_CJ05_triple_reassemble_missing_conjunct () =
  should_fail ~who:"CJ05" no_satisfy
    (prelude ^ proof_decls ^ {|
fn triple(raw: Int) -> Int =
  let a = check checkPos raw
  let b = check checkSmall a
  let c = check checkEven b
  let (v ::: pp && ps && pe) = c
  let reat = v ::: pp && pe
  needAll3 reat
|})

(* ════════════════════════════════════════════════════════════════════════ *)
(* 5. attachFact retarget (§7.7) — proof about a different subject.           *)
(* ════════════════════════════════════════════════════════════════════════ *)

(* AR01 — forget x's proof, attach an establish-proof about y, pass to needPos. *)
let test_AR01_forget_attach_other_subject () =
  should_fail ~who:"AR01" "different.*subject\\|about a different\\|describes a different\\|proof subject mismatch"
    (prelude ^ {|
fact IsPositive (n: Int)
establish provePos(n: Int) -> Fact (IsPositive n) = IsPositive n
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn needPos(n: Int ::: IsPositive n) -> Int = n
fn retarget(x: Int, y: Int) -> Int =
  let px = check checkPos x
  let bareX = forgetFact px
  let pyProof = provePos y
  needPos <| bareX ::: pyProof
|})

(* AR02 — attach a proof about y directly to a value derived from x. *)
let test_AR02_attachfact_unrelated_value () =
  should_fail ~who:"AR02" "different.*subject\\|about a different\\|describes a different\\|proof subject mismatch"
    (prelude ^ {|
fact IsPositive (n: Int)
establish provePos(n: Int) -> Fact (IsPositive n) = IsPositive n
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn needPos(n: Int ::: IsPositive n) -> Int = n
fn retarget(x: Int, y: Int) -> Int =
  let pyProof = provePos y
  let attached = attachFact x pyProof
  needPos attached
|})

(* AR03 — detach a proof from A, attach to unrelated B, pass to consumer. *)
let test_AR03_detach_from_A_attach_to_B () =
  should_fail ~who:"AR03" "different.*subject\\|about a different\\|describes a different\\|proof subject mismatch\\|does not statically satisfy"
    (prelude ^ {|
fact IsPositive (n: Int)
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn needPos(n: Int ::: IsPositive n) -> Int = n
fn retarget(a: Int, b: Int) -> Int =
  let pa = check checkPos a
  let detached = detachFact pa
  needPos <| b ::: detached
|})

(* ════════════════════════════════════════════════════════════════════════ *)
(* 6. Cross-module forgery — re-export a fact then try to mint it.            *)
(* ════════════════════════════════════════════════════════════════════════ *)

let fact_owner_lib = {|
#lang tesl
module FactOwnerLib exposing [ValidEmail, checkEmail]
import Tesl.Prelude exposing [String]
import Tesl.String exposing [String.contains, String.length]
fact ValidEmail (s: String)
check checkEmail(s: String) -> s: String ::: ValidEmail s =
  if String.contains s "@" && String.length s >= 5 then
    ok s ::: ValidEmail s
  else
    fail 400 "invalid email"
|}

let forge_pat = "fact ownership\\|P001\\|can only be produced\\|declaring module"

(* CM01 — re-export ValidEmail, mint it via a local `check`. *)
let test_CM01_forge_via_check () =
  two_files_should_fail ~who:"CM01" forge_pat
    "FactOwnerLib" fact_owner_lib
    "ForgeViaCheck" {|
#lang tesl
module ForgeViaCheck exposing [ValidEmail, badForge]
import Tesl.Prelude exposing [String]
import FactOwnerLib exposing [ValidEmail, checkEmail]
check badForge(s: String) -> s: String ::: ValidEmail s =
  ok s ::: ValidEmail s
|}

(* CM02 — re-export ValidEmail, mint it via a local `establish`. *)
let test_CM02_forge_via_establish () =
  two_files_should_fail ~who:"CM02" forge_pat
    "FactOwnerLib" fact_owner_lib
    "ForgeViaEstablish" {|
#lang tesl
module ForgeViaEstablish exposing [ValidEmail, alwaysValid]
import Tesl.Prelude exposing [String, Fact]
import FactOwnerLib exposing [ValidEmail, checkEmail]
establish alwaysValid(s: String) -> Fact (ValidEmail s) =
  ValidEmail s
|}

(* CM03 — re-export ValidEmail, mint it via a local `auth`. *)
let test_CM03_forge_via_auth () =
  two_files_should_fail ~who:"CM03" forge_pat
    "FactOwnerLib" fact_owner_lib
    "ForgeViaAuth" {|
#lang tesl
module ForgeViaAuth exposing [ValidEmail, fakeAuth]
import Tesl.Prelude exposing [String]
import Tesl.Http exposing [HttpRequest]
import FactOwnerLib exposing [ValidEmail, checkEmail]
auth fakeAuth(req: HttpRequest) -> email: String ::: ValidEmail email =
  ok "forged@example.com" ::: ValidEmail email
|}

(* CM04 — a THIRD module, importing through a re-export bridge, still cannot
   mint the fact (forgery chain A → B(bridge) → C). *)
let test_CM04_forge_through_chain () =
  let dir = Filename.temp_dir "tesl-neg-attack-chain" "" in
  let path_a = Filename.concat dir "FactOwnerLib.tesl" in
  let path_b = Filename.concat dir "ReexportBridge.tesl" in
  let path_c = Filename.concat dir "ForgeThroughChain.tesl" in
  let write p s = let oc = open_out p in output_string oc s; close_out oc in
  write path_a fact_owner_lib;
  write path_b {|
#lang tesl
module ReexportBridge exposing [ValidEmail, checkEmail]
import FactOwnerLib exposing [ValidEmail, checkEmail]
|};
  write path_c {|
#lang tesl
module ForgeThroughChain exposing []
import Tesl.Prelude exposing [String]
import ReexportBridge exposing [ValidEmail, checkEmail]
check forgeViaChain(s: String) -> s: String ::: ValidEmail s =
  ok s ::: ValidEmail s
|};
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun p -> try Sys.remove p with _ -> ()) [path_a; path_b; path_c];
      (try Unix.rmdir dir with _ -> ()))
    (fun () ->
      let code, out = run_compiler [check_subcmd; path_c] in
      assert_no_runtime_leak ~who:"CM04" out;
      if code = 0 then failf "CM04: expected ownership violation, but compiled cleanly.\nOutput:\n%s" out;
      let re = Str.regexp_case_fold forge_pat in
      try ignore (Str.search_forward re out 0)
      with Not_found -> failf "CM04: expected ownership error, got:\n%s" out)

(* CM05 — a module that never even imported the fact cannot produce it. *)
let test_CM05_forge_undeclared_fact () =
  should_fail ~who:"CM05" forge_pat
    {|
#lang tesl
module NoFactDeclared exposing []
import Tesl.Prelude exposing [String]
fact GhostFact (s: String)
check tryProduce(s: String) -> s: String ::: AnotherGhostFact s =
  ok s ::: AnotherGhostFact s
|}

(* ════════════════════════════════════════════════════════════════════════ *)
(* 8. `:::` fabrication in disguise (§7.12) — must reject in EVERY nook.      *)
(* ════════════════════════════════════════════════════════════════════════ *)

let fab_pat =
  "proof construction is not allowed in\\|cannot declare a proof\\|only .*check.*auth.*establish\\|proof.*fabricat"

(* FB01 — fabrication in a fn RETURN. *)
let test_FB01_fabricate_in_fn_return () =
  should_fail ~who:"FB01" fab_pat
    (prelude ^ {|
fact IsPositive (n: Int)
fn f(n: Int) -> Int ::: IsPositive n =
  n ::: IsPositive n
|})

(* FB02 — fabrication in a let binding. *)
let test_FB02_fabricate_in_let () =
  should_fail ~who:"FB02" fab_pat
    (prelude ^ {|
fact IsPositive (n: Int)
fn needPos(n: Int ::: IsPositive n) -> Int = n
fn f(n: Int) -> Int =
  let v = n ::: IsPositive n
  needPos v
|})

(* FB03 — fabrication inside an if-arm. *)
let test_FB03_fabricate_in_if_arm () =
  should_fail ~who:"FB03" fab_pat
    (prelude ^ {|
fact IsPositive (n: Int)
fn needPos(n: Int ::: IsPositive n) -> Int = n
fn f(n: Int, b: Bool) -> Int =
  if b then
    needPos (n ::: IsPositive n)
  else
    0
|})

(* FB04 — fabrication inside a case-arm. *)
let test_FB04_fabricate_in_case_arm () =
  should_fail ~who:"FB04" fab_pat
    (prelude ^ {|
fact IsPositive (n: Int)
fn needPos(n: Int ::: IsPositive n) -> Int = n
fn f(m: Maybe Int) -> Int =
  case m of
    Nothing -> 0
    Something n -> needPos (n ::: IsPositive n)
|})

(* FB05 — fabrication in a record field initializer. *)
let test_FB05_fabricate_in_record_field () =
  should_fail ~who:"FB05" fab_pat
    (prelude ^ {|
fact IsPositive (n: Int)
record R { v: Int ::: IsPositive v }
fn f(n: Int) -> R =
  R { v: n ::: IsPositive n }
|})

(* FB06 — fabrication inside a handler body. *)
let test_FB06_fabricate_in_handler () =
  should_fail ~who:"FB06" (fab_pat ^ "\\|handler")
    (prelude ^ {|
fact IsPositive (n: Int)
fn needPos(n: Int ::: IsPositive n) -> Int = n
handler sneaky(n: Int) -> Int requires [] =
  needPos (n ::: IsPositive n)
|})

(* FB07 — fabrication via a bare `<|` attach in a fn body. *)
let test_FB07_fabricate_via_pipe () =
  should_fail ~who:"FB07" fab_pat
    (prelude ^ {|
fact IsPositive (n: Int)
fn needPos(n: Int ::: IsPositive n) -> Int = n
fn f(n: Int) -> Int =
  needPos <| n ::: IsPositive n
|})

(* FB08 — fabrication of a conjunction in a fn body. *)
let test_FB08_fabricate_conjunction () =
  should_fail ~who:"FB08" fab_pat
    (prelude ^ {|
fact IsPositive (n: Int)
fact IsSmall    (n: Int)
fn needBoth(n: Int ::: IsPositive n && IsSmall n) -> Int = n
fn f(n: Int) -> Int =
  needBoth (n ::: IsPositive n && IsSmall n)
|})

(* ════════════════════════════════════════════════════════════════════════ *)
(* 9. Shadowing to blur subjects (§7.4); plain-fn proof-return abuse.         *)
(* ════════════════════════════════════════════════════════════════════════ *)

(* SH01 — shadow a proven binding with a raw value of the same name. *)
let test_SH01_shadow_proven_with_raw () =
  should_fail ~who:"SH01" (no_satisfy ^ "\\|shadow")
    (prelude ^ proof_decls ^ {|
fn blur(raw: Int, other: Int) -> Int =
  let x = check checkPos raw
  let x = other
  needPos x
|})

(* SH02 — shadow a proven param inside a nested let, then consume. *)
let test_SH02_shadow_param () =
  should_fail ~who:"SH02" (no_satisfy ^ "\\|shadow")
    (prelude ^ proof_decls ^ {|
fn blur(p: Int ::: IsPositive p, other: Int) -> Int =
  let p = other
  needPos p
|})

(* SH03 — plain `fn` declares a proof return without receiving/establishing it. *)
let test_SH03_plain_fn_proof_return () =
  should_fail ~who:"SH03"
    "cannot declare a proof\\|proof construction is not allowed\\|only .*check.*auth"
    (prelude ^ {|
fact IsPositive (n: Int)
fn bogus(n: Int) -> n: Int ::: IsPositive n = n
|})

(* SH04 — forget then reattach a STALE proof from a different subject. *)
let test_SH04_forget_stale_reattach () =
  should_fail ~who:"SH04" "different.*subject\\|about a different\\|describes a different\\|proof subject mismatch"
    (prelude ^ {|
fact IsPositive (n: Int)
establish provePos(n: Int) -> Fact (IsPositive n) = IsPositive n
check checkPos(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
fn needPos(n: Int ::: IsPositive n) -> Int = n
fn stale(x: Int, y: Int) -> Int =
  let px = check checkPos x
  let stalePxBare = forgetFact px
  let pyProof = provePos y
  needPos <| stalePxBare ::: pyProof
|})

(* ════════════════════════════════════════════════════════════════════════ *)
(* L. Capabilities — undeclared / forged authority.                           *)
(* ════════════════════════════════════════════════════════════════════════ *)

(* CP01 — requires names an undeclared capability. *)
let test_CP01_requires_undeclared_capability () =
  should_fail ~who:"CP01" "undeclared capability\\|unknown.*capability\\|not.*declared"
    (prelude ^ {|
fn f() -> Int requires [doesNotExist] = 42
|})

(* CP02 — capability `implies` an unknown (un-imported) capability. *)
let test_CP02_implies_unknown_capability () =
  should_fail ~who:"CP02" "implies unknown capability\\|unknown.*capability\\|undeclared"
    (prelude ^ {|
capability ghost implies notARealCapability
fn f() -> Int requires [ghost] = 42
|})

(* ════════════════════════════════════════════════════════════════════════ *)
(* 10. Positive counterparts — rejection is specificity, not blanket refusal. *)
(* ════════════════════════════════════════════════════════════════════════ *)

(* PC01 — ForAll satisfied by a real filterCheck. *)
let test_PC01_forall_ok () =
  should_pass
    ((mod_header "PcForall") ^ forall_imports ^ proof_decls ^ {|
fn needsPosList(xs: List Int ::: ForAll (IsPositive) xs) -> Int = List.length xs
fn good(raw: List Int) -> Int =
  let xs = List.filterCheck checkPos raw
  needsPosList xs
|})

(* PC02 — ForAll (P && Q) satisfied by chained filterCheck. *)
let test_PC02_forall_both_ok () =
  should_pass
    ((mod_header "PcForallBoth") ^ forall_imports ^ proof_decls ^ {|
fn needsBoth(xs: List Int ::: ForAll (IsPositive && IsSmall) xs) -> Int = List.length xs
fn good(raw: List Int) -> Int =
  let a = List.filterCheck checkPos raw
  let b = List.filterCheck checkSmall a
  needsBoth b
|})

(* PC03 — laundering done right: wrap the proof-requiring fn in a lambda. *)
let test_PC03_lambda_wrapper_ok () =
  should_pass
    ((mod_header "PcLambdaWrap") ^ "import Tesl.List exposing [List.map]\n" ^ proof_decls ^ {|
fn doublePos(n: Int ::: IsPositive n) -> Int = n + n
fn good(raw: List Int) -> List Int =
  List.map (fn(n: Int ::: IsPositive n) -> doublePos n) raw
|})

(* PC04 — multi-arg proof used in the CORRECT order. *)
let test_PC04_multiarg_correct_order () =
  should_pass
    ((mod_header "PcMultiArg") ^ {|
fact InBounds (lo: Int) (hi: Int) (n: Int)
check inBounds(lo: Int, hi: Int, n: Int) -> n: Int ::: InBounds lo hi n =
  if lo <= n && n <= hi then
    ok n ::: InBounds lo hi n
  else
    fail 400 "b"
fn needInBounds(lo: Int, hi: Int, n: Int ::: InBounds lo hi n) -> Int = n
fn good(a: Int, b: Int, x: Int) -> Int =
  let v = check inBounds a b x
  needInBounds a b v
|})

(* PC05 — conjunction decomposed and the P-half used where P is required. *)
let test_PC05_decompose_correct () =
  should_pass
    ((mod_header "PcDecompose") ^ proof_decls ^ {|
fn good(raw: Int) -> Int =
  let a = check checkPos raw
  let b = check checkSmall a
  let (v ::: pp && ps) = b
  needPos <| v ::: pp
|})

(* PC06 — introAnd from a SAME-subject chain, then consume as (P && Q). *)
let test_PC06_introand_same_subject_ok () =
  should_pass
    ((mod_header "PcIntroAnd") ^ proof_decls ^ {|
fn good(raw: Int) -> Int =
  let pos = check checkPos raw
  let sm  = check checkSmall pos
  let (v  ::: pp) = pos
  let (v2 ::: ps) = sm
  let combined = introAnd pp ps
  let reat = v ::: combined
  needBoth reat
|})

(* PC07 — forget then re-check on the SAME subject is valid. *)
let test_PC07_forget_recheck_ok () =
  should_pass
    ((mod_header "PcForgetRecheck") ^ proof_decls ^ {|
fn good(raw: Int) -> Int =
  let pos = check checkPos raw
  let bare = forgetFact pos
  let pos2 = check checkPos bare
  needPos pos2
|})

(* PC08 — re-export a fact and USE it in a type annotation (not forging). *)
let test_PC08_legitimate_reexport_use () =
  with_two_files "FactOwnerLib" fact_owner_lib "LegitReexportUse" {|
#lang tesl
module LegitReexportUse exposing []
import Tesl.Prelude exposing [String]
import FactOwnerLib exposing [ValidEmail, checkEmail]
fn requiresValidEmail(s: String ::: ValidEmail s) -> String = s
fn process(raw: String) -> String =
  let e = check checkEmail raw
  requiresValidEmail e
|} (fun path ->
    let code, out = run_compiler [check_subcmd; path] in
    if code <> 0 then failf "PC08: legitimate re-export use must compile, got:\n%s" out)

(* PC09 — capability declared then required is fine. *)
let test_PC09_capability_ok () =
  should_pass
    ((mod_header "PcCapability") ^
     "import Tesl.Time exposing [time]\nimport Tesl.Random exposing [random]\n" ^ {|
capability sessionCapability implies time, random
fn gen() -> String requires [sessionCapability] =
  "tok"
|})

(* PC10 — existential pack constructed correctly compiles. *)
let test_PC10_existential_pack_ok () =
  should_pass
    ((mod_header "PcExists") ^
     "import Tesl.Time exposing [time]\nimport Tesl.Random exposing [random]\n" ^ {|
fact IsTokenId (s: String)
establish proveTok(s: String) -> Fact (IsTokenId s) = IsTokenId s
capability sessionCapability implies time, random
fn gen() -> exists tokenId: String => tokenId: String ::: IsTokenId tokenId requires [sessionCapability] =
  let tokenId = "tok-abc"
  exists tokenId =>
    tokenId ::: proveTok tokenId
|})

(* ════════════════════════════════════════════════════════════════════════ *)
(* 7. Skolem escape (§7.9) — KNOWN-GAP (currently runtime-only).              *)
(*                                                                            *)
(*    FINDING (reported by NEG-ATTACK): the `.tesl` SURFACE has no            *)
(*    `pack`/`unpack` keyword — existentials are written `exists w => body`.  *)
(*    The genuine "witness name escapes its `unpack` scope" Skolem check      *)
(*    (`ensure-no-skolem-escape`, dsl/private/check-runtime.rkt) is           *)
(*    RUNTIME-ONLY; there is no OCaml static equivalent.  The surface cannot  *)
(*    even express the raw escape the runtime guards.                         *)
(*                                                                            *)
(*    The NEAREST expressible attempt is to take an existential RESULT and    *)
(*    feed it to a proof-requiring consumer (re-using the hidden witness as a *)
(*    proof subject).  Good news: that IS statically rejected today           *)
(*    ("does not statically satisfy declared proof") — verified below.        *)
(*                                                                            *)
(*    These cases run in a SEPARATE "known-gaps" group.  They use the same    *)
(*    `should_fail`/`should_pass`, so they pass TODAY; if a future change     *)
(*    makes the nearest-attempt compile, the suite turns red and flags that   *)
(*    net-deletion is blocked.  See the final report.                         *)
(* ════════════════════════════════════════════════════════════════════════ *)

let exists_caps = "import Tesl.Time exposing [time]\nimport Tesl.Random exposing [random]\n"

let exists_token_decls = {|
fact IsTokenId (s: String)
establish proveTok(s: String) -> Fact (IsTokenId s) = IsTokenId s
capability sessionCapability implies time, random
fn gen() -> exists tokenId: String => tokenId: String ::: IsTokenId tokenId requires [sessionCapability] =
  let tokenId = "tok-abc"
  exists tokenId =>
    tokenId ::: proveTok tokenId
|}

(* SK01 (KNOWN-GAP) — feed an existential result to a proof-requiring consumer.
   The hidden witness cannot be used as a proof subject downstream; this is the
   nearest surface-expressible analogue of a Skolem escape.  Statically rejected
   TODAY via the generic subject-mismatch error. *)
let test_SK01_existential_result_at_proof_site_KNOWN_GAP () =
  should_fail ~who:"SK01-KNOWN-GAP" no_satisfy
    ((mod_header "SkolemUse") ^ exists_caps ^ exists_token_decls ^ {|
fn needsTokSubject(s: String ::: IsTokenId s) -> String = s
fn escape() -> String requires [sessionCapability] =
  let t = gen()
  needsTokSubject t
|})

(* SK02 (KNOWN-GAP) — re-pack the existential result under a NEW existential and
   try to attach a fresh proof keyed to the leaked value.  Still rejected. *)
let test_SK02_existential_repack_KNOWN_GAP () =
  should_fail ~who:"SK02-KNOWN-GAP" no_satisfy
    ((mod_header "SkolemRepack") ^ exists_caps ^ exists_token_decls ^ {|
fn needsTokSubject(s: String ::: IsTokenId s) -> String = s
fn escape() -> String requires [sessionCapability] =
  let leaked = gen()
  let again = leaked
  needsTokSubject again
|})

(* PC-SK — POSITIVE: a correctly-constructed existential pack compiles (the
   witness stays hidden, never used downstream as a proof subject). *)
let test_PCSK_existential_pack_ok_KNOWN_GAP () =
  should_pass
    ((mod_header "SkolemOk") ^ exists_caps ^ exists_token_decls ^ {|
fn good() -> String requires [sessionCapability] =
  let t = gen()
  t
|})

(* ════════════════════════════════════════════════════════════════════════ *)
(* CRITICAL KNOWN-GAP — andLeft/andRight conjunction projection is NOT        *)
(* tracked by the static checker.                                            *)
(*                                                                            *)
(*    FINDING (NEG-ATTACK): when a value is decomposed via                    *)
(*    `let (v ::: conj) = b` (where `b : ... ::: P && Q`), the checker keeps  *)
(*    the FULL conjunction `P && Q` associated with `v`'s reattachable proof. *)
(*    Passing `conj` through `andLeft`/`andRight` does NOT narrow what the    *)
(*    checker believes: `v ::: andLeft conj` is still treated as carrying the *)
(*    whole `P && Q`.  So a SINGLE projected conjunct can masquerade as the   *)
(*    full conjunction — and, worse, as the OTHER conjunct.                   *)
(*                                                                            *)
(*    Soundness control (CJ04 above): a genuine single-conjunct proof from a  *)
(*    P-only check IS correctly rejected where Q is required.  The defect is  *)
(*    specifically that `andLeft`/`andRight` are no-ops in the proof tracker. *)
(*                                                                            *)
(*    The two cases below SHOULD be statically rejected; they COMPILE TODAY.  *)
(*    They are `should_pass` so the suite stays green while documenting the   *)
(*    gap — when the checker is fixed to honor projections, these turn red    *)
(*    and must be converted to `should_fail`.  Reported in the final message  *)
(*    as a CRITICAL finding that may block net deletion.                      *)
(* ════════════════════════════════════════════════════════════════════════ *)

(* GAP-ANDPROJ-01 (CLOSED) — `andLeft conj` (= IsPositive) used where IsSmall
   required is now correctly rejected: the projected proof is subject-precise. *)
let test_GAP_andleft_projection_unsound_KNOWN_GAP () =
  should_fail "does not statically satisfy"
    ((mod_header "GapAndLeft") ^ proof_decls ^ {|
fn unsound(raw: Int) -> Int =
  let a = check checkPos raw
  let b = check checkSmall a
  let (v ::: conj) = b
  let justP = andLeft conj
  needSmall <| v ::: justP
|})

(* GAP-ANDPROJ-02 (CLOSED) — `andRight conj` (= IsSmall) used where IsPositive
   required is now correctly rejected: the projected proof is subject-precise. *)
let test_GAP_andright_projection_unsound_KNOWN_GAP () =
  should_fail "does not statically satisfy"
    ((mod_header "GapAndRight") ^ proof_decls ^ {|
fn unsound(raw: Int) -> Int =
  let a = check checkPos raw
  let b = check checkSmall a
  let (v ::: conj) = b
  let justQ = andRight conj
  needPos <| v ::: justQ
|})

(* ── Suite registration ───────────────────────────────────────────────────── *)

let () =
  run "ProofSuite-Attack" [
    "group", [
      (* 1. ForAll element leak *)
      test_case "FA01 ForAll conjunction leak (filter P, claim P&&Q)" `Quick test_FA01_forall_conjunction_leak;
      test_case "FA02 ForAll wrong predicate (P-list -> needs Q-list)" `Quick test_FA02_forall_wrong_predicate;
      test_case "FA03 ForAll unfiltered raw list" `Quick test_FA03_forall_unfiltered_raw;
      test_case "FA04 ForAll single-predicate mismatch" `Quick test_FA04_forall_single_predicate_mismatch;
      test_case "FA05 ForAll empty literal not vacuous" `Quick test_FA05_forall_empty_literal;
      test_case "FA06 ForAll partial conjunction insufficient" `Quick test_FA06_forall_partial_conjunction;
      test_case "FA07 ForAll lost through map" `Quick test_FA07_forall_lost_through_map;

      (* 2. Laundering *)
      test_case "LA01 alias direct call with raw" `Quick test_LA01_alias_direct_call;
      test_case "LA02 alias passed around to HOF" `Quick test_LA02_alias_passed_around;
      test_case "LA03 named proof-fn as plain callback" `Quick test_LA03_named_fn_as_callback;
      test_case "LA04 lambda alias passed around" `Quick test_LA04_lambda_alias_passed_around;
      test_case "LA05 inline proof-lambda on raw arg" `Quick test_LA05_inline_lambda_raw_arg;
      test_case "LA06 partial application then raw" `Quick test_LA06_partial_application_then_raw;
      test_case "LA07 alias chain then raw" `Quick test_LA07_alias_chain;

      (* 3. Subject confusion (multi-arg) *)
      test_case "SC01 multi-arg swapped order" `Quick test_SC01_multiarg_swapped_order;
      test_case "SC02 OwnedBy wrong user subject" `Quick test_SC02_ownedby_wrong_subject;
      test_case "SC03 OwnedBy other-user proof" `Quick test_SC03_ownedby_other_user_proof;
      test_case "SC04 multi-arg wrong value subject" `Quick test_SC04_multiarg_wrong_value_subject;

      (* 4. Conjunction split-and-reassemble swap *)
      test_case "CJ01 decompose, use P where Q required" `Quick test_CJ01_decompose_use_P_for_Q;
      test_case "CJ02 decompose discard-left then misuse" `Quick test_CJ02_decompose_discard_left;
      test_case "CJ03 introAnd cross-subject" `Quick test_CJ03_introand_cross_subject;
      test_case "CJ04 single-conjunct misuse rejected (control)" `Quick test_CJ04_single_conjunct_misuse_rejected;
      test_case "CJ05 triple reassemble missing conjunct" `Quick test_CJ05_triple_reassemble_missing_conjunct;

      (* 5. attachFact retarget *)
      test_case "AR01 forget+attach other-subject proof" `Quick test_AR01_forget_attach_other_subject;
      test_case "AR02 attachFact to unrelated value" `Quick test_AR02_attachfact_unrelated_value;
      test_case "AR03 detach from A, attach to B" `Quick test_AR03_detach_from_A_attach_to_B;

      (* 6. Cross-module forgery *)
      test_case "CM01 forge via check (re-exported fact)" `Quick test_CM01_forge_via_check;
      test_case "CM02 forge via establish" `Quick test_CM02_forge_via_establish;
      test_case "CM03 forge via auth" `Quick test_CM03_forge_via_auth;
      test_case "CM04 forge through re-export chain" `Quick test_CM04_forge_through_chain;
      test_case "CM05 produce undeclared fact" `Quick test_CM05_forge_undeclared_fact;

      (* 8. ::: fabrication in disguise *)
      test_case "FB01 fabricate in fn return" `Quick test_FB01_fabricate_in_fn_return;
      test_case "FB02 fabricate in let" `Quick test_FB02_fabricate_in_let;
      test_case "FB03 fabricate in if-arm" `Quick test_FB03_fabricate_in_if_arm;
      test_case "FB04 fabricate in case-arm" `Quick test_FB04_fabricate_in_case_arm;
      test_case "FB05 fabricate in record field" `Quick test_FB05_fabricate_in_record_field;
      test_case "FB06 fabricate in handler" `Quick test_FB06_fabricate_in_handler;
      test_case "FB07 fabricate via pipe" `Quick test_FB07_fabricate_via_pipe;
      test_case "FB08 fabricate conjunction" `Quick test_FB08_fabricate_conjunction;

      (* 9. Shadowing to blur subjects *)
      test_case "SH01 shadow proven with raw" `Quick test_SH01_shadow_proven_with_raw;
      test_case "SH02 shadow proven param" `Quick test_SH02_shadow_param;
      test_case "SH03 plain fn proof-return abuse" `Quick test_SH03_plain_fn_proof_return;
      test_case "SH04 forget then stale reattach" `Quick test_SH04_forget_stale_reattach;

      (* L. Capabilities *)
      test_case "CP01 requires undeclared capability" `Quick test_CP01_requires_undeclared_capability;
      test_case "CP02 implies unknown capability" `Quick test_CP02_implies_unknown_capability;

      (* 10. Positive counterparts *)
      test_case "PC01 ForAll ok" `Quick test_PC01_forall_ok;
      test_case "PC02 ForAll both ok" `Quick test_PC02_forall_both_ok;
      test_case "PC03 lambda wrapper ok" `Quick test_PC03_lambda_wrapper_ok;
      test_case "PC04 multi-arg correct order ok" `Quick test_PC04_multiarg_correct_order;
      test_case "PC05 decompose correct ok" `Quick test_PC05_decompose_correct;
      test_case "PC06 introAnd same-subject ok" `Quick test_PC06_introand_same_subject_ok;
      test_case "PC07 forget+recheck ok" `Quick test_PC07_forget_recheck_ok;
      test_case "PC08 legitimate re-export use ok" `Quick test_PC08_legitimate_reexport_use;
      test_case "PC09 capability ok" `Quick test_PC09_capability_ok;
      test_case "PC10 existential pack ok" `Quick test_PC10_existential_pack_ok;
    ];

    (* 7. Skolem escape — documented KNOWN-GAP (runtime-only today).
       These pass today; if the nearest-attempt ever compiles, the suite goes
       red, flagging that net-deletion is blocked. *)
    "known-gaps", [
      test_case "SK01 KNOWN-GAP existential result at proof site (statically rejected today)"
        `Quick test_SK01_existential_result_at_proof_site_KNOWN_GAP;
      test_case "SK02 KNOWN-GAP existential repack (statically rejected today)"
        `Quick test_SK02_existential_repack_KNOWN_GAP;
      test_case "PC-SK existential pack ok (positive)"
        `Quick test_PCSK_existential_pack_ok_KNOWN_GAP;
      test_case "GAP-ANDPROJ-01 KNOWN-GAP andLeft projection unsound (COMPILES TODAY; should reject)"
        `Quick test_GAP_andleft_projection_unsound_KNOWN_GAP;
      test_case "GAP-ANDPROJ-02 KNOWN-GAP andRight projection unsound (COMPILES TODAY; should reject)"
        `Quick test_GAP_andright_projection_unsound_KNOWN_GAP;
    ];
  ]
