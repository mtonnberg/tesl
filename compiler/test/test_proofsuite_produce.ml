(** ProofSuite Family A — proof PRODUCTION (`check` / `establish` / `auth`).

    NEG-CORE: compile-time rejection of every "forged / wrong / forgotten"
    proof-PRODUCTION mistake, proven WITHOUT the runtime net. Modeled on
    [test_library_negative.ml] / [test_review20_antagonistic.ml].

    Every negative is STATIC: [should_fail] asserts non-zero exit AND that the
    rejection never leaked to runtime (no `raise-user-error` / `check-fail` /
    Racket trace in the output). A negative that compiles is a real static-checker
    gap.

    Anchors: LANGUAGE-SPEC §7.12 (fabrication restricted to trusted kinds),
    §7.8 (unbound GDP names), fact-ownership (P001/T001). *)

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

(* Derive a kebab-case file name from the `module X` header so the compiler's
   "module header must match file name" rule is satisfied. *)
let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-psA" "" in
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

(* A rejection that leaked to runtime is NOT a static rejection. *)
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

(* Helper that pins a source the checker currently ACCEPTS but which SHOULD be
   rejected statically (it forges or mis-produces a proof).  It asserts the
   current (accepting) behavior so that if the checker is later fixed to reject
   this, the assertion flips and tells us to promote it to a real negative.
   [what] is a human description of what SHOULD be rejected.
   (All produce-suite gaps are now closed → flipped to should_fail; kept here,
   warning-suppressed, for re-pinning if a future regression reopens one.) *)
let[@warning "-32"] known_gap ~what src =
  ignore what;
  with_temp_file src (fun path ->
    let code, _ = run_compiler ["--check"; path] in
    (* Currently compiles clean (exit 0). When the gap is closed this becomes
       non-zero and the test fails, prompting promotion to should_fail. *)
    if code <> 0 then
      failf "KNOWN-GAP CLOSED: %s is now rejected — promote this case to should_fail" what)

(* Shared module header. NOTE: `Maybe` lives in `Tesl.Maybe`, NOT `Tesl.Prelude`. *)
let prelude name =
  Printf.sprintf
    "#lang tesl\nmodule %s exposing []\n\
     import Tesl.Prelude exposing [Int, String, Bool(..), List, Fact]\n\
     import Tesl.Maybe exposing [Maybe(..)]\n" name

(* ── A. Hand-written PRODUCTION negatives ────────────────────────────────── *)

(* §7.12 — `:::` fabrication in a `fn` body. *)
let test_A_fabricate_in_fn () =
  should_fail "proof construction is not allowed in" (prelude "AFabFn" ^ {|
fact IsPositive (n: Int)
fn forge(n: Int) -> Int =
  let v = n ::: IsPositive n
  v
|})

(* §7.12 — `:::` fabrication in a `handler` body. *)
let test_A_fabricate_in_handler () =
  should_fail "proof construction is not allowed in" (prelude "AFabHandler" ^ {|
import Tesl.Http exposing [HttpRequest]
fact IsPositive (n: Int)
handler h(n: Int) -> Int requires [] =
  let v = n ::: IsPositive n
  v
|})

(* §7.12 — `:::` fabrication in a `worker` body. *)
let test_A_fabricate_in_worker () =
  should_fail "proof construction is not allowed in" (prelude "AFabWorker" ^ {|
record Job { n: Int }
fact JobOk (j: Job)
worker w(j: Job) requires [] =
  let v = j ::: JobOk j
  v
|})

(* `check` body returns `ok n` with NO `::: P n` stamp — parser rejects. *)
let test_A_check_ok_without_stamp () =
  should_fail "expected :::\\|does not match declared return spec\\|P001" (prelude "ANoStamp" ^ {|
fact IsPositive (n: Int)
check c(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n
  else
    fail 400 "bad"
|})

(* `ok n ::: P m` — wrong subject in the produced proof. *)
let test_A_check_wrong_subject () =
  should_fail "does not match declared return spec" (prelude "AWrongSubj" ^ {|
fact IsPositive (n: Int)
check c(n: Int, m: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive m
  else
    fail 400 "bad"
|})

(* `ok n ::: Q n` — wrong predicate. *)
let test_A_check_wrong_predicate () =
  should_fail "does not match declared return spec" (prelude "AWrongPred" ^ {|
fact IsPositive (n: Int)
fact IsNegative (n: Int)
check c(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsNegative n
  else
    fail 400 "bad"
|})

(* `establish` using `ok` instead of returning a proof constructor directly. *)
let test_A_establish_uses_ok () =
  should_fail "establish functions must return proof constructors directly\\|cannot unify Int with Fact"
    (prelude "AEstOk" ^ {|
fact IsPositive (n: Int)
establish e(n: Int) -> Fact (IsPositive n) =
  ok n ::: IsPositive n
|})

(* `establish` returning a plain non-Fact value. *)
let test_A_establish_returns_nonfact () =
  should_fail "cannot unify\\|Fact\\|return" (prelude "AEstPlain" ^ {|
fact IsPositive (n: Int)
establish e(n: Int) -> Fact (IsPositive n) =
  n
|})

(* `establish` cannot use `fail` (must be total). *)
let test_A_establish_uses_fail () =
  should_fail "establish functions\\|fail\\|return proof constructors" (prelude "AEstFail" ^ {|
fact IsPositive (n: Int)
establish e(n: Int) -> Fact (IsPositive n) =
  if n > 0 then
    IsPositive n
  else
    fail 400 "bad"
|})

(* `establish` building the WRONG proof constructor. *)
let test_A_establish_wrong_constructor () =
  should_fail "cannot unify\\|does not match\\|IsNegative\\|Fact" (prelude "AEstWrong" ^ {|
fact IsPositive (n: Int)
fact IsNegative (n: Int)
establish e(n: Int) -> Fact (IsPositive n) =
  IsNegative n
|})

(* establish + literal-param fact: `establish` declaring a 3-arg literal-param
   fact `Clamped 1 100 n` with a body returning a DIFFERENT constructor entirely
   is rejected ("must return the declared fact constructor"), matching the 1-arg
   fact and `check` paths. *)
let test_A_establish_literal_param_wrong_constructor () =
  should_fail "must return the declared fact constructor"
    (prelude "AGapEstCtor" ^ {|
fact Clamped (lo: Int) (hi: Int) (n: Int)
fact Decoy (n: Int)
establish e(n: Int) -> Fact (Clamped 1 100 n) =
  Decoy n
|})

(* establish + literal-param fact: same constructor with WRONG literal args
   (`Clamped 2 200 n` vs declared `Clamped 1 100 n`) is rejected. *)
let test_A_establish_literal_param_wrong_args () =
  should_fail "wrong arguments"
    (prelude "AGapEstArgs" ^ {|
fact Clamped (lo: Int) (hi: Int) (n: Int)
establish e(n: Int) -> Fact (Clamped 1 100 n) =
  Clamped 2 200 n
|})

(* 2026-07 review §3.1 (GDP-EST-SUBJECT): `establish` must mint its fact about the
   DECLARED subject, exactly like `check`/`auth`.  An establish that declares
   `-> Fact (IsPositive n)` but mints `IsPositive m` (a different param) is now
   rejected — previously it forged a proof about the wrong value with no runtime
   backstop (proofs are erased). *)
let test_A_establish_wrong_subject () =
  should_fail "wrong arguments\\|does not match" (prelude "AEstSubj" ^ {|
fact IsPositive (n: Int)
establish e(n: Int, m: Int) -> Maybe (Fact (IsPositive n)) =
  if m > 0 then
    Something (IsPositive m)
  else
    Nothing
|})

(* 2026-07 review §3.3 (GDP-FROMDB-NAMEDPACK): a plain `fn` may not forge `FromDb`
   provenance via the `?` named-pack return on a fabricated entity — the `?` path now
   applies the same producing-site gate the `:::` path uses.  With no query in the
   body, the FromDb claim is rejected. *)
let test_A_fromdb_namedpack_forgery () =
  should_fail "returns a named pack claiming\\|does not carry\\|FromDb" ({|#lang tesl
module AFromDbForge exposing []
import Tesl.Prelude exposing [String]
entity Todo table "todos" primaryKey id {
  id: String
  title: String
}
fn forge(pk: String) -> Todo ? FromDb (Id == pk) =
  Todo { id: "fabricated-not-pk", title: "never queried" }
|})

(* 2026-07 review §P1: inline attach `x ::: fn args` is sound ONLY when `fn` returns
   a CLEAN `Fact (...)` (total establish).  A `Maybe (Fact ...)` (or Either/List/…)
   result cannot be attached inline — the wrapper must be eliminated first — so it is
   a compile error (previously it compiled and trapped at runtime). *)
let test_A_inline_maybe_establish_rejected () =
  should_fail "cannot be attached inline\\|does not return a clean" (prelude "AInlineMaybe" ^ {|
fact IsPositive (n: Int)
establish isPositive(n: Int) -> Maybe (Fact (IsPositive n)) =
  if n > 0 then
    Something (IsPositive n)
  else
    Nothing
fn usePos(n: Int ::: IsPositive n) -> Int = n
fn run_it(n: Int) -> Int =
  usePos (n ::: isPositive n)
|})

(* Counterpart: a CLEAN total-`Fact` establish CAN be attached inline (still sound). *)
let test_A_inline_total_establish_ok () =
  should_pass (prelude "AInlineTotal" ^ {|
fact IsPositive (n: Int)
establish provePos(n: Int) -> Fact (IsPositive n) =
  IsPositive n
fn usePos(n: Int ::: IsPositive n) -> Int = n
fn run_it(n: Int) -> Int =
  usePos (n ::: provePos n)
|})

(* `auth` not producing its declared proof — wrong subject. *)
let test_A_auth_wrong_subject () =
  should_fail "does not match declared return spec" (prelude "AAuthSubj" ^ {|
import Tesl.Http exposing [HttpRequest]
record User { id: String }
fact Authed (u: User)
auth a(req: HttpRequest) -> user: User ::: Authed user =
  ok User { id: "x" } ::: Authed req
|})

(* `auth` returning `ok` without the `:::` stamp — parser rejects. *)
let test_A_auth_no_stamp () =
  should_fail "expected :::\\|does not match declared return spec" (prelude "AAuthNoStamp" ^ {|
import Tesl.Http exposing [HttpRequest]
record User { id: String }
fact Authed (u: User)
auth a(req: HttpRequest) -> user: User ::: Authed user =
  ok User { id: "x" }
|})

let test_A_auth_literal_value_ok () =
  (* NOT a gap: `auth` PRODUCES the identity (a trusted minter), so — unlike `check`,
     which validates an input and must return it (LANGUAGE-SPEC scopes the
     ok-binding-name rule to check only) — auth may return a literal as the named-pack
     value. `ok 999 ::: AuthedN user` is valid. *)
  should_pass
    (prelude "AGapAuthLit" ^ {|
import Tesl.Http exposing [HttpRequest]
fact AuthedN (u: Int)
auth a(req: HttpRequest) -> user: Int ::: AuthedN user =
  ok 999 ::: AuthedN user
|})

(* `auth` producing the wrong predicate entirely. *)
let test_A_auth_wrong_predicate () =
  should_fail "does not match declared return spec\\|not in scope\\|ownership" (prelude "AAuthPred" ^ {|
import Tesl.Http exposing [HttpRequest]
record User { id: String }
fact Authed (u: User)
fact Banned (u: User)
auth a(req: HttpRequest) -> user: User ::: Authed user =
  ok User { id: "x" } ::: Banned user
|})

(* Producing a fact that is never declared (single-module ownership). *)
let test_A_undeclared_fact () =
  should_fail "fact ownership violation\\|not in scope\\|can only be produced" (prelude "AUndecl" ^ {|
check c(n: Int) -> n: Int ::: Ghost n =
  if n > 0 then
    ok n ::: Ghost n
  else
    fail 400 "bad"
|})

(* A `fn` (not check/establish/auth) cannot declare a proof return type. *)
let test_A_fn_declares_proof_return () =
  should_fail "proof construction is not allowed\\|proof return\\|only.*check\\|cannot"
    (prelude "AFnReturn" ^ {|
fact IsPositive (n: Int)
fn bad(n: Int) -> n: Int ::: IsPositive n =
  n
|})

(* `ok n ::: P n && Q n` but only declared `P n` (over-produces conjunct). *)
let test_A_check_overproduces_conjunct () =
  should_fail "does not match declared return spec" (prelude "AOverProd" ^ {|
fact IsPositive (n: Int)
fact IsSmall (n: Int)
check c(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n && IsSmall n
  else
    fail 400 "bad"
|})

(* Declared `P n && Q n` but only produced `P n` (under-produces conjunct). *)
let test_A_check_underproduces_conjunct () =
  should_fail "does not match declared return spec" (prelude "AUnderProd" ^ {|
fact IsPositive (n: Int)
fact IsSmall (n: Int)
check c(n: Int) -> n: Int ::: IsPositive n && IsSmall n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
|})

(* §7.8 — proof template references an unbound GDP name. *)
let test_A_unbound_subject_in_return () =
  should_fail "not in scope\\|unbound\\|does not match\\|undefined" (prelude "AUnbound" ^ {|
fact IsPositive (n: Int)
check c(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive ghost
  else
    fail 400 "bad"
|})

(* ── A. Positive sanity — correct PRODUCTION compiles ────────────────────── *)

let test_A_pos_check_basic () =
  should_pass (prelude "APosCheck" ^ {|
fact IsPositive (n: Int)
check c(n: Int) -> n: Int ::: IsPositive n =
  if n > 0 then
    ok n ::: IsPositive n
  else
    fail 400 "bad"
|})

let test_A_pos_check_conjunction () =
  should_pass (prelude "APosConj" ^ {|
fact IsPositive (n: Int)
fact IsSmall (n: Int)
check c(n: Int) -> n: Int ::: IsPositive n && IsSmall n =
  if n > 0 && n < 100 then
    ok n ::: IsPositive n && IsSmall n
  else
    fail 400 "bad"
|})

let test_A_pos_check_two_arg_subject () =
  should_pass (prelude "APosTwoArg" ^ {|
fact Linked (owner: Int) (item: Int)
check c(o: Int, i: Int) -> i: Int ::: Linked o i =
  if i > 0 then
    ok i ::: Linked o i
  else
    fail 400 "bad"
|})

let test_A_pos_auth_conjunction () =
  should_pass (prelude "APosAuthConj" ^ {|
import Tesl.Http exposing [HttpRequest]
record User { id: String }
fact Authed (u: User)
fact IsAdmin (u: User)
auth a(req: HttpRequest) -> user: User ::: Authed user && IsAdmin user =
  ok User { id: "x" } ::: Authed user && IsAdmin user
|})

let test_A_pos_establish_two_arg () =
  should_pass (prelude "APosEstTwo" ^ {|
fact Linked (owner: Int) (item: Int)
establish e(o: Int, i: Int) -> Fact (Linked o i) =
  Linked o i
|})

let test_A_pos_establish_simple () =
  should_pass (prelude "APosEst" ^ {|
fact IsPositive (n: Int)
establish e(n: Int) -> Fact (IsPositive n) =
  IsPositive n
|})

let test_A_pos_establish_maybe () =
  should_pass (prelude "APosEstMaybe" ^ {|
fact IsEven (n: Int)
establish e(n: Int) -> Maybe (Fact (IsEven n)) =
  if n > 0 then
    Something (IsEven n)
  else
    Nothing
|})

let test_A_pos_auth_record () =
  should_pass (prelude "APosAuth" ^ {|
import Tesl.Http exposing [HttpRequest]
record User { id: String }
fact Authed (u: User)
auth a(req: HttpRequest) -> user: User ::: Authed user =
  ok User { id: "x" } ::: Authed user
|})

let test_A_pos_check_string_subject () =
  should_pass (prelude "APosStr" ^ {|
import Tesl.String exposing [String.length]
fact IsNonEmpty (s: String)
check c(s: String) -> s: String ::: IsNonEmpty s =
  if String.length s > 0 then
    ok s ::: IsNonEmpty s
  else
    fail 400 "empty"
|})

let test_A_pos_check_literal_params () =
  should_pass (prelude "APosClamp" ^ {|
fact Clamped (lo: Int) (hi: Int) (n: Int)
check c(n: Int) -> n: Int ::: Clamped 1 100 n =
  if n >= 1 && n <= 100 then
    ok n ::: Clamped 1 100 n
  else
    fail 400 "oob"
|})

(* ── A. Parameterized PRODUCTION negatives (Tier 2) ──────────────────────── *)
(* predicate axis × producer-kind × production-mistake-shape, generated from data. *)

type pred = {
  pid : string;          (* fact base name, e.g. "IsPositiveA" *)
  decl : string;         (* fact declaration line(s) *)
  ty : string;           (* subject type, e.g. "Int" / "String" *)
  app : string;          (* applied predicate on subject `x`, e.g. "IsPositiveA x" *)
  app_other : string;    (* applied on a different subject `y` (wrong-subject) *)
  cond : string;         (* a boolean condition over `x` for the ok branch *)
  extra_imports : string;
}

(* axis of predicates, each instantiated fresh per producer to avoid name clashes *)
let predicates suffix = [
  { pid = "PaPos" ^ suffix;
    decl = Printf.sprintf "fact PaPos%s (n: Int)" suffix;
    ty = "Int"; app = Printf.sprintf "PaPos%s x" suffix;
    app_other = Printf.sprintf "PaPos%s y" suffix;
    cond = "x > 0"; extra_imports = "" };
  { pid = "PaNE" ^ suffix;
    decl = Printf.sprintf "fact PaNE%s (s: String)" suffix;
    ty = "String"; app = Printf.sprintf "PaNE%s x" suffix;
    app_other = Printf.sprintf "PaNE%s y" suffix;
    cond = "String.length x > 0";
    extra_imports = "import Tesl.String exposing [String.length]\n" };
  { pid = "PaClamp" ^ suffix;
    decl = Printf.sprintf "fact PaClamp%s (lo: Int) (hi: Int) (n: Int)" suffix;
    ty = "Int"; app = Printf.sprintf "PaClamp%s 1 100 x" suffix;
    app_other = Printf.sprintf "PaClamp%s 1 100 y" suffix;
    cond = "x >= 1 && x <= 100"; extra_imports = "" };
  { pid = "PaEven" ^ suffix;
    decl = Printf.sprintf "fact PaEven%s (n: Int)" suffix;
    ty = "Int"; app = Printf.sprintf "PaEven%s x" suffix;
    app_other = Printf.sprintf "PaEven%s y" suffix;
    cond = "x > 0"; extra_imports = "" };
  { pid = "PaTrim" ^ suffix;
    decl = Printf.sprintf "fact PaTrim%s (s: String)" suffix;
    ty = "String"; app = Printf.sprintf "PaTrim%s x" suffix;
    app_other = Printf.sprintf "PaTrim%s y" suffix;
    cond = "String.length x > 0";
    extra_imports = "import Tesl.String exposing [String.length]\n" };
]

(* a decoy fact of the same subject type, for wrong-predicate mistakes *)
let decoy_decl ty suffix =
  if ty = "String" then Printf.sprintf "fact PaDecoy%s (s: String)" suffix
  else Printf.sprintf "fact PaDecoy%s (n: Int)" suffix
let decoy_app ty suffix =
  ignore ty; Printf.sprintf "PaDecoy%s x" suffix

(* Each (producer_kind, mistake) yields one negative per predicate. *)
let produce_param_cases () =
  let kinds = [ "check"; "establish"; "auth" ] in
  let mistakes = [ `WrongSubject; `WrongPredicate; `MissingStamp ] in
  List.concat_map (fun kind ->
    List.concat_map (fun mistake ->
      let osuffix = Printf.sprintf "%s%s"
          (String.sub kind 0 1)
          (match mistake with `WrongSubject -> "S" | `WrongPredicate -> "P" | `MissingStamp -> "M") in
      List.mapi (fun i p ->
        let suffix = Printf.sprintf "%s%d" osuffix i in
        let modname = Printf.sprintf "APar%s" suffix in
        (* build the producer body per kind/mistake *)
        let body =
          match kind, mistake with
          | "check", `WrongSubject ->
            Printf.sprintf
              "check c(x: %s, y: %s) -> x: %s ::: %s =\n  if %s then\n    ok x ::: %s\n  else\n    fail 400 \"bad\"\n"
              p.ty p.ty p.ty p.app p.cond p.app_other
          | "check", `WrongPredicate ->
            Printf.sprintf
              "%scheck c(x: %s) -> x: %s ::: %s =\n  if %s then\n    ok x ::: %s\n  else\n    fail 400 \"bad\"\n"
              (decoy_decl p.ty suffix ^ "\n") p.ty p.ty p.app p.cond (decoy_app p.ty suffix)
          | "check", `MissingStamp ->
            Printf.sprintf
              "check c(x: %s) -> x: %s ::: %s =\n  if %s then\n    ok x\n  else\n    fail 400 \"bad\"\n"
              p.ty p.ty p.app p.cond
          | "establish", `WrongSubject ->
            (* establish has no second subject; reuse wrong-predicate decoy as the
               establish analogue of "wrong proof produced" *)
            Printf.sprintf
              "%sestablish e(x: %s) -> Fact (%s) =\n  %s\n"
              (decoy_decl p.ty suffix ^ "\n") p.ty p.app (decoy_app p.ty suffix)
          | "establish", `WrongPredicate ->
            Printf.sprintf
              "%sestablish e(x: %s) -> Fact (%s) =\n  %s\n"
              (decoy_decl p.ty suffix ^ "\n") p.ty p.app (decoy_app p.ty suffix)
          | "establish", `MissingStamp ->
            (* establish using `ok` (the "forgot to return a constructor" shape) *)
            Printf.sprintf
              "establish e(x: %s) -> Fact (%s) =\n  ok x ::: %s\n"
              p.ty p.app p.app
          | "auth", `WrongSubject ->
            Printf.sprintf
              "auth a(req: HttpRequest, y: %s) -> x: %s ::: %s =\n  ok x ::: %s\n"
              p.ty p.ty p.app p.app_other
          | "auth", `WrongPredicate ->
            Printf.sprintf
              "%sauth a(req: HttpRequest) -> x: %s ::: %s =\n  ok x ::: %s\n"
              (decoy_decl p.ty suffix ^ "\n") p.ty p.app (decoy_app p.ty suffix)
          | "auth", `MissingStamp ->
            (* auth returning ok with no stamp *)
            Printf.sprintf
              "auth a(req: HttpRequest) -> x: %s ::: %s =\n  ok x\n"
              p.ty p.app
          | _ -> assert false
        in
        let needs_http = (kind = "auth") in
        let src =
          prelude modname
          ^ p.extra_imports
          ^ (if needs_http then "import Tesl.Http exposing [HttpRequest]\n" else "")
          ^ p.decl ^ "\n"
          ^ body
        in
        (* CLOSED (was a KNOWN GAP): `establish` whose declared return spec is a
           literal-param / multi-arg fact (Clamped) now validates the body's fact
           constructor — a wrong constructor / wrong literal args is rejected
           ("must return the declared fact constructor"), matching the 1-arg/2-arg
           establish facts and the analogous `check` path. *)
        let is_clamped =
          try ignore (Str.search_forward (Str.regexp_string "Clamp") p.pid 0); true
          with Not_found -> false
        in
        let was_establish_gap =
          kind = "establish" && is_clamped
          && (match mistake with `WrongSubject | `WrongPredicate -> true | `MissingStamp -> false)
        in
        let label =
          Printf.sprintf "A-PAR %s%s/%s/%s"
            (if was_establish_gap then "GAP-CLOSED " else "")
            kind
            (match mistake with `WrongSubject -> "wrong-subject" | `WrongPredicate -> "wrong-predicate" | `MissingStamp -> "missing-stamp")
            p.pid
        in
        (* all production mistakes are P001/E000 static rejections; match broadly *)
        let pat =
          "does not match declared return spec\
           \\|expected :::\
           \\|establish functions must return proof constructors\
           \\|must return the declared fact constructor\
           \\|cannot unify\
           \\|proof construction is not allowed\
           \\|not in scope\
           \\|ownership"
        in
        let run_case () = should_fail pat src in
        test_case label `Quick run_case)
        (predicates osuffix))
      mistakes)
    kinds

(* §7.12 fabrication axis: `:::` in a non-trusted kind (fn/handler/worker) body,
   across the predicate axis. Each must be rejected with the fabrication error. *)
let fabricate_param_cases () =
  let kinds = [ "fn"; "handler"; "worker" ] in
  List.concat_map (fun kind ->
    let osuffix = Printf.sprintf "F%s" (String.sub kind 0 1) in
    List.mapi (fun i p ->
      let suffix = Printf.sprintf "%s%d" osuffix i in
      let modname = Printf.sprintf "AFab%s" suffix in
      (* body fabricates a proof via `:::` then returns the raw value *)
      let kind_src =
        match kind with
        | "fn" ->
          Printf.sprintf "fn forge(x: %s) -> %s =\n  let v = x ::: %s\n  v\n" p.ty p.ty p.app
        | "handler" ->
          Printf.sprintf "handler forge(x: %s) -> %s requires [] =\n  let v = x ::: %s\n  v\n" p.ty p.ty p.app
        | "worker" ->
          Printf.sprintf "worker forge(x: %s) requires [] =\n  let v = x ::: %s\n  v\n" p.ty p.app
        | _ -> assert false
      in
      let src = prelude modname ^ p.extra_imports ^ p.decl ^ "\n" ^ kind_src in
      let label = Printf.sprintf "A-FAB %s/%s" kind p.pid in
      test_case label `Quick (fun () ->
        should_fail "proof construction is not allowed in" src))
      (predicates osuffix))
    kinds

(* ── Runner ──────────────────────────────────────────────────────────────── *)

let () =
  run "ProofSuite-A-Produce" [
    "fabrication-7.12", [
      test_case "A fabricate ::: in fn body" `Quick test_A_fabricate_in_fn;
      test_case "A fabricate ::: in handler body" `Quick test_A_fabricate_in_handler;
      test_case "A fabricate ::: in worker body" `Quick test_A_fabricate_in_worker;
      test_case "A fn cannot declare proof return type" `Quick test_A_fn_declares_proof_return;
    ];
    "check-production", [
      test_case "A check ok without ::: stamp" `Quick test_A_check_ok_without_stamp;
      test_case "A check wrong subject" `Quick test_A_check_wrong_subject;
      test_case "A check wrong predicate" `Quick test_A_check_wrong_predicate;
      test_case "A check over-produces conjunct" `Quick test_A_check_overproduces_conjunct;
      test_case "A check under-produces conjunct" `Quick test_A_check_underproduces_conjunct;
      test_case "A check unbound subject in return" `Quick test_A_unbound_subject_in_return;
    ];
    "establish-production", [
      test_case "A establish uses ok" `Quick test_A_establish_uses_ok;
      test_case "A establish returns non-Fact" `Quick test_A_establish_returns_nonfact;
      test_case "A establish uses fail" `Quick test_A_establish_uses_fail;
      test_case "A establish wrong constructor" `Quick test_A_establish_wrong_constructor;
    ];
    "establish-negatives", [
      test_case "A establish literal-param wrong constructor" `Quick test_A_establish_literal_param_wrong_constructor;
      test_case "A establish literal-param wrong args" `Quick test_A_establish_literal_param_wrong_args;
      test_case "A establish wrong subject (GDP-EST-SUBJECT)" `Quick test_A_establish_wrong_subject;
      test_case "A FromDb named-pack forgery (GDP-FROMDB-NAMEDPACK)" `Quick test_A_fromdb_namedpack_forgery;
      test_case "A inline Maybe-establish rejected (§P1)" `Quick test_A_inline_maybe_establish_rejected;
      test_case "A inline total-establish ok (§P1)" `Quick test_A_inline_total_establish_ok;
    ];
    "auth-production", [
      test_case "A auth wrong subject" `Quick test_A_auth_wrong_subject;
      test_case "A auth wrong predicate" `Quick test_A_auth_wrong_predicate;
      test_case "A auth no stamp" `Quick test_A_auth_no_stamp;
      test_case "A auth literal named-pack value ok" `Quick test_A_auth_literal_value_ok;
    ];
    "ownership", [
      test_case "A produce undeclared fact" `Quick test_A_undeclared_fact;
    ];
    "production-parameterized", produce_param_cases ();
    "fabrication-parameterized", fabricate_param_cases ();
    "production-positive-sanity", [
      test_case "A+ check basic" `Quick test_A_pos_check_basic;
      test_case "A+ check conjunction" `Quick test_A_pos_check_conjunction;
      test_case "A+ check two-arg subject" `Quick test_A_pos_check_two_arg_subject;
      test_case "A+ auth conjunction" `Quick test_A_pos_auth_conjunction;
      test_case "A+ establish two-arg" `Quick test_A_pos_establish_two_arg;
      test_case "A+ establish simple" `Quick test_A_pos_establish_simple;
      test_case "A+ establish maybe" `Quick test_A_pos_establish_maybe;
      test_case "A+ auth record" `Quick test_A_pos_auth_record;
      test_case "A+ check string subject" `Quick test_A_pos_check_string_subject;
      test_case "A+ check literal params" `Quick test_A_pos_check_literal_params;
    ];
  ]
