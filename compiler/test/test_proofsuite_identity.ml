(** ProofSuite family J — Subject identity / name shadowing / `:::` fabrication
    / cross-module proof forgery (§7.1–7.4, §7.12).

    NEGATIVE proof tests: code that must NOT compile.  Three threads:

    J-FAB  — `:::` proof fabrication outside trusted function kinds (§7.12).
             The `:::` operator in expression context inside a `fn`, `handler`,
             `worker`, or `main` body may only attach an existing proof value;
             using a raw GDP predicate (`value ::: Pred x`) is rejected with
             `error[P001]: ok ::: proof construction is not allowed in <kind>`.
             We sweep every function kind × every syntactic nook (let, if-arm,
             case-arm, direct argument, record-field construction).
    J-SHADOW — name shadowing is illegal for proof-relevant binders (§7.4):
             a `let`/case-binder/parameter that shadows an in-scope name.
    J-FORGE — cross-module forgery (§7.3): only the module that declares
             `fact F` may produce `F`-carrying values.  A module that merely
             re-exports / imports `F` cannot mint it via `check`/`establish`/
             `auth`, even through a re-export chain.  Error: `fact ownership
             violation … can only be produced` (`error[T001]`/`P001`).

    Hardening: a static rejection must never leak a runtime token
    (`raise-user-error`, `check-fail`, `.rkt` trace).  `should_fail` asserts
    this.

    Companion to NEG-ATTACK (fabrication ×8, shadowing ×4, cross-module ×5);
    this file supplies the systematic breadth (every kind × nook) plus the
    positive companions. *)

open Alcotest

(* ── Compiler discovery ──────────────────────────────────────────────────── *)

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
  let dir = Filename.temp_dir "tesl-psJ" "" in
  let name =
    let re = Str.regexp "\\(module\\|library\\)[ \\t\\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
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

(* Two-file form for cross-module forgery: filenames derive from module names. *)
let modname_of src =
  let re = Str.regexp "module[ \t\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
  ignore (Str.search_forward re src 0);
  Str.matched_group 1 src

let with_two_files a_src b_src f =
  let dir = Filename.temp_dir "tesl-psJ2" "" in
  let path_a = Filename.concat dir (modname_of a_src ^ ".tesl") in
  let path_b = Filename.concat dir (modname_of b_src ^ ".tesl") in
  let oc_a = open_out path_a in output_string oc_a a_src; close_out oc_a;
  let oc_b = open_out path_b in output_string oc_b b_src; close_out oc_b;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path_a with _ -> ());
      (try Sys.remove path_b with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path_b)

let with_three_files a_src b_src c_src f =
  let dir = Filename.temp_dir "tesl-psJ3" "" in
  let path_a = Filename.concat dir (modname_of a_src ^ ".tesl") in
  let path_b = Filename.concat dir (modname_of b_src ^ ".tesl") in
  let path_c = Filename.concat dir (modname_of c_src ^ ".tesl") in
  List.iter (fun (p, s) -> let oc = open_out p in output_string oc s; close_out oc)
    [ (path_a, a_src); (path_b, b_src); (path_c, c_src) ];
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun p -> try Sys.remove p with _ -> ()) [path_a; path_b; path_c];
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path_c)

(* Hardening *)
let runtime_leak_re =
  Str.regexp_case_fold "raise-user-error\\|check-fail\\|\\.rkt:[0-9]\\|context\\.\\.\\.:\\|raco "

let assert_no_runtime_leak ~ctx out =
  try
    ignore (Str.search_forward runtime_leak_re out 0);
    failf "%s: rejection LEAKED to runtime, output:\n%s" ctx out
  with Not_found -> ()

let should_fail ?(label = "") pat src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    let ctx = if label = "" then "should_fail" else label in
    assert_no_runtime_leak ~ctx out;
    if code = 0 then failf "%s: expected static failure matching %S, but COMPILED.\nsrc:\n%s" ctx pat src;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "%s: expected failure matching %S, got:\n%s" ctx pat out)

let should_pass ?(label = "") src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    let ctx = if label = "" then "should_pass" else label in
    if code <> 0 then failf "%s: expected COMPILE, but failed:\n%s" ctx out)

let two_files_should_fail ?(label = "") pat a_src b_src =
  with_two_files a_src b_src (fun path_b ->
    let code, out = run_compiler ["--check"; path_b] in
    let ctx = if label = "" then "two_files_should_fail" else label in
    assert_no_runtime_leak ~ctx out;
    if code = 0 then failf "%s: expected static failure matching %S, but COMPILED" ctx pat;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "%s: expected failure matching %S, got:\n%s" ctx pat out)

let three_files_should_fail ?(label = "") pat a_src b_src c_src =
  with_three_files a_src b_src c_src (fun path_c ->
    let code, out = run_compiler ["--check"; path_c] in
    let ctx = if label = "" then "three_files_should_fail" else label in
    assert_no_runtime_leak ~ctx out;
    if code = 0 then failf "%s: expected static failure matching %S, but COMPILED" ctx pat;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "%s: expected failure matching %S, got:\n%s" ctx pat out)

let with_two_files_pass ?(label = "") a_src b_src =
  with_two_files a_src b_src (fun path_b ->
    let code, out = run_compiler ["--check"; path_b] in
    let ctx = if label = "" then "with_two_files_pass" else label in
    if code <> 0 then failf "%s: expected COMPILE, but failed:\n%s" ctx out)

(* ════════════════════════════════════════════════════════════════════════
   J-FAB — `:::` fabrication outside trusted kinds (§7.12)
   Matrix: function-kind × syntactic-nook.  Each body fabricates `Pos n`
   without going through check/establish/auth.  Expected: P001.
   ════════════════════════════════════════════════════════════════════════ *)

let fab_pat = "ok ::: proof construction is not allowed\\|P001\\|proof construction"

(* The proof scaffolding common to every fabrication case. *)
let fab_scaffold = {|
fact Pos (n: Int)
fn needsPos(n: Int ::: Pos n) -> Int = n
|}

(* Body snippets that fabricate inside a function whose param is `n: Int`. *)
let fab_nooks = [
  ("let",
   "  let p = n ::: Pos n\n  needsPos p\n");
  ("direct-arg",
   "  needsPos (n ::: Pos n)\n");
  ("if-arm",
   "  if n > 0 then\n    needsPos (n ::: Pos n)\n  else\n    0\n");
  ("if-let-arm",
   "  if n > 0 then\n    let p = n ::: Pos n\n    needsPos p\n  else\n    0\n");
  ("else-arm",
   "  if n > 0 then\n    0\n  else\n    needsPos (n ::: Pos n)\n");
  ("nested-let",
   "  let m = n + 1\n  let p = m ::: Pos m\n  needsPos p\n");
  ("binary-arg",
   "  needsPos ((n + 0) ::: Pos (n + 0))\n");
]

let fab_fn nook_body =
  Printf.sprintf
    "#lang tesl\nmodule FabFn exposing []\nimport Tesl.Prelude exposing [Int, Bool(..)]\n%sfn f(n: Int) -> Int =\n%s"
    fab_scaffold nook_body

let fab_handler nook_body =
  Printf.sprintf
    "#lang tesl\nmodule FabH exposing []\nimport Tesl.Prelude exposing [Int, Bool(..)]\nimport Tesl.Http exposing [HttpRequest]\n%shandler f(req: HttpRequest, n: Int) -> Int requires [] =\n%s"
    fab_scaffold nook_body

(* worker kind — fabrication in a preceding let, then return the job. *)
let fab_worker () =
  Printf.sprintf
    "#lang tesl\nmodule FabW exposing []\nimport Tesl.Prelude exposing [Int]\nimport Tesl.Queue exposing [queueRead]\n%srecord Job { n: Int }\nworker doJob(j: Job) requires [queueRead] =\n  let p = j.n ::: Pos j.n\n  let used = needsPos p\n  j\n"
    fab_scaffold

(* main kind *)
let fab_main () =
  Printf.sprintf
    "#lang tesl\nmodule FabMain exposing []\nimport Tesl.Prelude exposing [Int]\n%smain {\n  with capabilities [] {\n    let p = 5 ::: Pos 5\n    needsPos p\n  }\n}\n"
    fab_scaffold

let j_fab_fn_matrix () =
  List.map (fun (nook_name, body) ->
    let label = Printf.sprintf "J-FAB fn/%s" nook_name in
    test_case label `Quick (fun () -> should_fail ~label fab_pat (fab_fn body))
  ) fab_nooks

let j_fab_handler_matrix () =
  List.map (fun (nook_name, body) ->
    let label = Printf.sprintf "J-FAB handler/%s" nook_name in
    test_case label `Quick (fun () -> should_fail ~label fab_pat (fab_handler body))
  ) fab_nooks

(* case-arm fabrication (fn + handler). *)
let fab_fn_case = {|
#lang tesl
module FabFnCase exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
fact Pos (n: Int)
fn needsPos(n: Int ::: Pos n) -> Int = n
fn f(m: Maybe Int) -> Int =
  case m of
    Something v ->
      let p = v ::: Pos v
      needsPos p
    Nothing -> 0
|}

let fab_handler_case = {|
#lang tesl
module FabHCase exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Http exposing [HttpRequest]
fact Pos (n: Int)
fn needsPos(n: Int ::: Pos n) -> Int = n
handler f(req: HttpRequest, m: Maybe Int) -> Int requires [] =
  case m of
    Something v ->
      needsPos (v ::: Pos v)
    Nothing -> 0
|}

(* record-field-construction fabrication. *)
let fab_record_field = {|
#lang tesl
module FabRecField exposing []
import Tesl.Prelude exposing [String]
fact Safe (s: String)
record Msg { body: String ::: Safe body }
fn bad(raw: String) -> Msg = Msg { body: raw ::: Safe raw }
|}

(* top-level return-position fabrication. *)
let fab_toplevel_return = {|
#lang tesl
module FabTopReturn exposing []
import Tesl.Prelude exposing [Int]
fact Pos (n: Int)
fn needsPos(n: Int ::: Pos n) -> Int = n
fn bad(n: Int) -> Int = needsPos (n ::: Pos n)
|}

(* ════════════════════════════════════════════════════════════════════════
   J-RET — plain `fn`/`handler` cannot declare a proof return type (§7.12).
   ════════════════════════════════════════════════════════════════════════ *)

let ret_pat = "cannot declare a proof.*return\\|proof return type\\|only.*check.*auth\\|P001\\|proof-carrying return"

let test_fn_proof_return () =
  should_fail ~label:"J-RET fn proof return" ret_pat {|
#lang tesl
module RetFn exposing []
import Tesl.Prelude exposing [Int]
fact Pos (n: Int)
fn bad(n: Int) -> n: Int ::: Pos n = n
|}

(* CLOSED (was a static-checker gap reported to ZC-FINALIZE).
   §7.12 says "only check/establish/auth may introduce new proof-carrying
   return types".  The proof-return restriction was previously gated on `FnKind`
   only — a `handler` declaring a proof-carrying return its parameters do NOT
   carry was accepted.  The kind gate now extends to {fn, handler, worker}, so
   this is correctly rejected. *)
let test_handler_proof_return_KNOWN_GAP () =
  should_fail ~label:"J-RET handler proof return" ret_pat {|
#lang tesl
module RetH exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Http exposing [HttpRequest]
fact Pos (n: Int)
handler bad(req: HttpRequest, n: Int) -> n: Int ::: Pos n requires [] = n
|}

(* CLOSED (same root cause as the handler case): a `worker` declaring a
   proof-carrying return its params do not carry is now correctly rejected. *)
let test_worker_proof_return_KNOWN_GAP () =
  should_fail ~label:"J-RET worker proof return" ret_pat {|
#lang tesl
module RetW exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Queue exposing [queueRead]
fact Pos (n: Int)
record Job { n: Int }
worker bad(j: Job) -> n: Int ::: Pos n requires [queueRead] = j.n
|}

(* ════════════════════════════════════════════════════════════════════════
   J-SHADOW — illegal shadowing of proof-relevant binders (§7.4)
   ════════════════════════════════════════════════════════════════════════ *)

let shadow_pat = "shadow\\|duplicate parameter\\|already.*scope\\|V001"

let test_shadow_let_over_param () =
  should_fail ~label:"J-SHADOW let over param" shadow_pat {|
#lang tesl
module ShLetParam exposing []
import Tesl.Prelude exposing [Int]
fn f(x: Int) -> Int =
  let x = x + 1
  x
|}

let test_shadow_let_over_let () =
  should_fail ~label:"J-SHADOW let over let" shadow_pat {|
#lang tesl
module ShLetLet exposing []
import Tesl.Prelude exposing [Int]
fn f(n: Int) -> Int =
  let y = n + 1
  let y = y + 1
  y
|}

let test_shadow_case_binder_over_param () =
  should_fail ~label:"J-SHADOW case binder over param" shadow_pat {|
#lang tesl
module ShCaseParam exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
fn f(x: Int, m: Maybe Int) -> Int =
  case m of
    Something x -> x
    Nothing -> 0
|}

let test_shadow_case_binder_over_let () =
  should_fail ~label:"J-SHADOW case binder over let" shadow_pat {|
#lang tesl
module ShCaseLet exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
fn f(m: Maybe Int) -> Int =
  let v = 1
  case m of
    Something v -> v
    Nothing -> 0
|}

let test_shadow_duplicate_param () =
  should_fail ~label:"J-SHADOW duplicate param" shadow_pat {|
#lang tesl
module ShDupParam exposing []
import Tesl.Prelude exposing [Int]
fn f(x: Int, x: Int) -> Int = x
|}

let test_shadow_let_over_param_in_check () =
  should_fail ~label:"J-SHADOW let over param in check" shadow_pat {|
#lang tesl
module ShCheck exposing []
import Tesl.Prelude exposing [Int]
fact Pos (n: Int)
check checkPos(n: Int) -> n: Int ::: Pos n =
  let n = n + 1
  if n > 0 then
    ok n ::: Pos n
  else
    fail 400 "no"
|}

let test_shadow_param_over_toplevel_fn () =
  should_fail ~label:"J-SHADOW param over toplevel fn" shadow_pat {|
#lang tesl
module ShParamTop exposing []
import Tesl.Prelude exposing [Int]
fn helper(n: Int) -> Int = n
fn f(helper: Int) -> Int = helper
|}

(* ════════════════════════════════════════════════════════════════════════
   J-FORGE — cross-module proof forgery (§7.3)
   ════════════════════════════════════════════════════════════════════════ *)

let forge_pat = "fact ownership\\|can only be produced\\|declaring module\\|P001"

let fact_owner = {|
#lang tesl
module FactOwner exposing [ValidEmail, checkEmail]
import Tesl.Prelude exposing [String]
import Tesl.String exposing [String.contains, String.length]
fact ValidEmail (s: String)
check checkEmail(s: String) -> s: String ::: ValidEmail s =
  if String.contains s "@" && String.length s >= 5 then
    ok s ::: ValidEmail s
  else
    fail 400 "invalid email"
|}

(* A re-export bridge: re-exports the fact + its check, mints nothing. *)
let reexport_bridge = {|
#lang tesl
module Bridge exposing [ValidEmail, checkEmail]
import FactOwner exposing [ValidEmail, checkEmail]
|}

let test_forge_via_check () =
  two_files_should_fail ~label:"J-FORGE check" forge_pat fact_owner {|
#lang tesl
module ForgeCheck exposing [ValidEmail, badForge]
import Tesl.Prelude exposing [String]
import FactOwner exposing [ValidEmail, checkEmail]
check badForge(s: String) -> s: String ::: ValidEmail s =
  ok s ::: ValidEmail s
|}

let test_forge_via_establish () =
  two_files_should_fail ~label:"J-FORGE establish" forge_pat fact_owner {|
#lang tesl
module ForgeEstablish exposing [ValidEmail, alwaysValid]
import Tesl.Prelude exposing [String, Fact]
import FactOwner exposing [ValidEmail, checkEmail]
establish alwaysValid(s: String) -> Fact (ValidEmail s) =
  ValidEmail s
|}

let test_forge_via_auth () =
  two_files_should_fail ~label:"J-FORGE auth" forge_pat fact_owner {|
#lang tesl
module ForgeAuth exposing [ValidEmail, fakeAuth]
import Tesl.Prelude exposing [String]
import Tesl.Http exposing [HttpRequest]
import FactOwner exposing [ValidEmail, checkEmail]
auth fakeAuth(req: HttpRequest) -> email: String ::: ValidEmail email =
  ok "forged@example.com" ::: ValidEmail email
|}

let test_forge_through_reexport_chain () =
  three_files_should_fail ~label:"J-FORGE chain check" forge_pat fact_owner reexport_bridge {|
#lang tesl
module ForgeChain exposing []
import Tesl.Prelude exposing [String]
import Bridge exposing [ValidEmail, checkEmail]
check forgeViaChain(s: String) -> s: String ::: ValidEmail s =
  ok s ::: ValidEmail s
|}

let test_forge_through_chain_establish () =
  three_files_should_fail ~label:"J-FORGE chain establish" forge_pat fact_owner reexport_bridge {|
#lang tesl
module ForgeChainEst exposing []
import Tesl.Prelude exposing [String, Fact]
import Bridge exposing [ValidEmail, checkEmail]
establish forgeEst(s: String) -> Fact (ValidEmail s) = ValidEmail s
|}

let test_forge_fn_return_foreign_proof () =
  (* A plain fn annotating its return with a foreign proof: blocked. *)
  two_files_should_fail ~label:"J-FORGE fn foreign return"
    "cannot declare a proof.*return\\|proof return type\\|fact ownership\\|only.*check.*auth\\|P001"
    fact_owner {|
#lang tesl
module FnForeignProof exposing []
import Tesl.Prelude exposing [String]
import FactOwner exposing [ValidEmail, checkEmail]
fn badAnnotation(s: String) -> s: String ::: ValidEmail s = s
|}

let test_forge_undeclared_fact () =
  (* Single module: produce a fact that is never declared at all. *)
  should_fail ~label:"J-FORGE undeclared fact"
    "fact ownership\\|can only be produced\\|declaring module\\|not in scope\\|unknown\\|P001" {|
#lang tesl
module UndeclaredFact exposing []
import Tesl.Prelude exposing [String]
fact GhostFact (s: String)
check tryProduce(s: String) -> s: String ::: PhantomFact s =
  ok s ::: PhantomFact s
|}

(* ════════════════════════════════════════════════════════════════════════
   J-POS — positive companions (must compile)
   ════════════════════════════════════════════════════════════════════════ *)

let pos_check_produces_own_fact () =
  should_pass ~label:"J-POS check own fact" {|
#lang tesl
module PosJ_Check exposing []
import Tesl.Prelude exposing [Int]
fact Pos (n: Int)
check checkPos(n: Int) -> n: Int ::: Pos n =
  if n > 0 then
    ok n ::: Pos n
  else
    fail 400 "no"
fn needsPos(n: Int ::: Pos n) -> Int = n
fn good(raw: Int) -> Int =
  let v = check checkPos raw
  needsPos v
|}

let pos_establish_uses_colon3 () =
  should_pass ~label:"J-POS establish ::: ok" {|
#lang tesl
module PosJ_Est exposing []
import Tesl.Prelude exposing [Int, Fact]
fact Pos (n: Int)
establish provePos(n: Int) -> Fact (Pos n) = Pos n
fn needsPos(n: Int ::: Pos n) -> Int = n
|}

let pos_auth_uses_colon3 () =
  should_pass ~label:"J-POS auth ::: ok" {|
#lang tesl
module PosJ_Auth exposing []
import Tesl.Prelude exposing [String]
import Tesl.Http exposing [HttpRequest]
import Tesl.Dict exposing [Dict.lookup]
import Tesl.Maybe exposing [Maybe(..)]
fact Authed (s: String)
auth myAuth(req: HttpRequest) -> user: String ::: Authed user =
  case Dict.lookup "user" req.cookies of
    Nothing -> fail 401 "no"
    Something u -> ok u ::: Authed user
|}

let pos_fn_attaches_existing_proof () =
  (* §7.12: attaching an EXISTING proof value inside a fn is allowed. *)
  should_pass ~label:"J-POS fn attaches existing proof" {|
#lang tesl
module PosJ_Attach exposing []
import Tesl.Prelude exposing [Int, Fact, attachFact, detachFact]
fact Pos (n: Int)
fn needsPos(n: Int ::: Pos n) -> Int = n
fn relay(n: Int ::: Pos n) -> Int =
  let (x ::: p) = n
  needsPos (attachFact x p)
|}

let pos_legit_reexport_and_use () =
  with_two_files_pass ~label:"J-POS legit re-export use" fact_owner {|
#lang tesl
module LegitUse exposing []
import Tesl.Prelude exposing [String]
import FactOwner exposing [ValidEmail, checkEmail]
fn requiresValid(s: String ::: ValidEmail s) -> String = s
fn process(raw: String) -> String =
  let e = check checkEmail raw
  requiresValid e
|}

let pos_no_shadow_distinct_names () =
  should_pass ~label:"J-POS distinct names compile" {|
#lang tesl
module PosJ_Distinct exposing []
import Tesl.Prelude exposing [Int]
fn f(x: Int) -> Int =
  let y = x + 1
  let z = y + 1
  z
|}

let pos_disjoint_case_binders () =
  should_pass ~label:"J-POS disjoint case binders" {|
#lang tesl
module PosJ_CaseOk exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
fn f(x: Int, m: Maybe Int) -> Int =
  case m of
    Something v -> x + v
    Nothing -> x
|}

let pos_chain_legit_use () =
  with_two_files_pass ~label:"J-POS chain legit" fact_owner reexport_bridge

let pos_fn_takes_proof_param_returns_plain () =
  should_pass ~label:"J-POS fn proof param plain return" {|
#lang tesl
module PosJ_PlainRet exposing []
import Tesl.Prelude exposing [Int]
fact Pos (n: Int)
fn unwrap(n: Int ::: Pos n) -> Int = n
|}

let pos_handler_consumes_auth_proof () =
  should_pass ~label:"J-POS handler consumes auth proof" {|
#lang tesl
module PosJ_HandlerAuth exposing []
import Tesl.Prelude exposing [String]
import Tesl.Http exposing [HttpRequest]
fact Authed (s: String)
fn forUser(s: String ::: Authed s) -> String = s
handler greet(user: String ::: Authed user) -> String requires [] =
  forUser user
|}

(* ── Runner ──────────────────────────────────────────────────────────────── *)

let () =
  run "ProofSuite-J-Identity" [
    "J-FAB fn × nook",      j_fab_fn_matrix ();
    "J-FAB handler × nook", j_fab_handler_matrix ();
    "J-FAB worker/main/case/record", [
      test_case "worker body fabrication" `Quick
        (fun () -> should_fail ~label:"J-FAB worker" fab_pat (fab_worker ()));
      test_case "main body fabrication" `Quick
        (fun () -> should_fail ~label:"J-FAB main" fab_pat (fab_main ()));
      test_case "fn case-arm fabrication" `Quick
        (fun () -> should_fail ~label:"J-FAB fn case" fab_pat fab_fn_case);
      test_case "handler case-arm fabrication" `Quick
        (fun () -> should_fail ~label:"J-FAB handler case" fab_pat fab_handler_case);
      test_case "record-field-construction fabrication" `Quick
        (fun () -> should_fail ~label:"J-FAB record field" fab_pat fab_record_field);
      test_case "top-level return fabrication" `Quick
        (fun () -> should_fail ~label:"J-FAB toplevel return" fab_pat fab_toplevel_return);
    ];
    "J-RET proof return on plain kinds", [
      test_case "fn cannot declare proof return" `Quick test_fn_proof_return;
      test_case "handler proof return (KNOWN GAP, pinned)" `Quick test_handler_proof_return_KNOWN_GAP;
      test_case "worker proof return (KNOWN GAP, pinned)" `Quick test_worker_proof_return_KNOWN_GAP;
    ];
    "J-SHADOW illegal shadowing", [
      test_case "let shadows param" `Quick test_shadow_let_over_param;
      test_case "let shadows let" `Quick test_shadow_let_over_let;
      test_case "case binder shadows param" `Quick test_shadow_case_binder_over_param;
      test_case "case binder shadows let" `Quick test_shadow_case_binder_over_let;
      test_case "duplicate parameter name" `Quick test_shadow_duplicate_param;
      test_case "let shadows param in check" `Quick test_shadow_let_over_param_in_check;
      test_case "param shadows top-level fn" `Quick test_shadow_param_over_toplevel_fn;
    ];
    "J-FORGE cross-module forgery", [
      test_case "forge via check (re-export)" `Quick test_forge_via_check;
      test_case "forge via establish (re-export)" `Quick test_forge_via_establish;
      test_case "forge via auth (re-export)" `Quick test_forge_via_auth;
      test_case "forge through re-export chain (check)" `Quick test_forge_through_reexport_chain;
      test_case "forge through re-export chain (establish)" `Quick test_forge_through_chain_establish;
      test_case "fn return annotated with foreign proof" `Quick test_forge_fn_return_foreign_proof;
      test_case "produce undeclared fact" `Quick test_forge_undeclared_fact;
    ];
    "J-POS positive companions", [
      test_case "check produces its own fact" `Quick pos_check_produces_own_fact;
      test_case "establish uses ::: legitimately" `Quick pos_establish_uses_colon3;
      test_case "auth uses ::: legitimately" `Quick pos_auth_uses_colon3;
      test_case "fn attaches an existing proof" `Quick pos_fn_attaches_existing_proof;
      test_case "legit re-export and use compiles" `Quick pos_legit_reexport_and_use;
      test_case "distinct binder names compile" `Quick pos_no_shadow_distinct_names;
      test_case "disjoint case binders compile" `Quick pos_disjoint_case_binders;
      test_case "re-export chain (legit) compiles" `Quick pos_chain_legit_use;
      test_case "fn proof param plain return compiles" `Quick pos_fn_takes_proof_param_returns_plain;
      test_case "handler consumes auth proof compiles" `Quick pos_handler_consumes_auth_proof;
    ];
  ]
