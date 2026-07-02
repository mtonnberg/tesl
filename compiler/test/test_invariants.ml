(** §7 soundness-invariant registry cross-check (S11 / C14 / G6 "prose-cannot-fail").

    LANGUAGE-SPEC.md §7 lists ~13 soundness invariants, each tagged
    "Implemented". This test keeps that prose honest in two ways:

      (1) ANTI-DRIFT (hard gate): every registry row's "7.N" section must
          resolve to a real `### 7.N ...` heading in LANGUAGE-SPEC.md. If a
          heading is renamed, renumbered, or deleted out from under the
          registry, this fails the build (exit 1).

      (2) SEMANTIC COVERAGE (hard gate — C14): each invariant is bound to the
          SEMANTIC OBJECT it guards, NOT to a substring that might live in a
          comment. Coverage is a real red→green exercise: for the invariant we
          embed a tiny antagonistic `.tesl` program that VIOLATES it, compile it
          via `main.exe --check`, and assert (a) a NON-ZERO exit and (b) an
          invariant-specific diagnostic. If the guard is renamed/deleted/weakened
          the program stops being rejected (exit 0 or the diagnostic disappears)
          and THIS TEST FAILS. Where no surface program can express a violation
          (the guarantee holds by ABSENCE of syntax, or is an architectural
          property), the row is an explicit `KnownGap` with a one-line reason,
          and the KnownGap set is asserted to be EXACTLY the expected set — so a
          new gap, or a guard silently downgraded to a gap, breaks the build.

    This replaces the previous cosmetic credit (a `test_hint` substring counted
    as "TESTED" if it appeared ANYWHERE in the test corpus — including in a
    comment or on a KNOWN-GAP line — and a shortfall was PRINTED, not fatal).

    Load-bearing check: changing any invariant's `program` to a NON-violating
    variant makes `main.exe --check` exit 0, so the exercise (and the build)
    FAILS. Verified manually at authoring time.

    Pure OCaml (str + unix + stdlib only; no alcotest) so it registers as a
    plain (test). Shells out to ../bin/main.exe (a dune dep), locating it by the
    same discipline as compiler/test/test_proof_negatives.ml. Run:
      dune exec test/test_invariants.exe
*)

(* ── Coverage kind ──────────────────────────────────────────────────────────
   A §7 invariant is covered EITHER by a real red→green [Exercise] (a program
   that violates it + the invariant-specific rejection the compiler must emit),
   OR — only when no surface program can express the violation — by a
   [KnownGap reason]. There is no third, cosmetic option. *)

type coverage =
  | Exercise of { program : string; expect : string }
    (* [program]: an antagonistic .tesl source that MUST be rejected at
       `--check`. [expect]: a case-insensitive regexp that MUST match the
       compiler's stderr/stdout — the invariant-specific diagnostic (the
       semantic object). *)
  | KnownGap of string [@warning "-37"]
    (* No enforceable surface exercise; [string] is the one-line reason. The
       constructor is intentionally retained even when the gap set is EMPTY
       (all invariants exercised today): it is the sanctioned home for a future
       genuinely un-exercisable invariant, reconciled against
       [expected_known_gaps]. Warning 37 (unused-constructor) is silenced so an
       empty-gap tree still builds. *)

type row = { section : string; title : string; coverage : coverage }

(* Every row cites LANGUAGE-SPEC §7.N and binds the invariant to the concrete
   guard it protects. Programs are minimal and antagonistic: each isolates ONE
   mechanism so flipping it to a non-violating form (which compiles cleanly)
   breaks exactly that row. *)
let registry : row list = [
  (* 7.1 — every ordinary value gets a FRESH hidden subject. Two independently
     written identical literals (`42` at two source locations) receive DISTINCT
     per-occurrence subjects (`lit#file:line:col`), so a proof about one cannot
     be replayed onto the other. The diagnostic naming two different `lit#…`
     subjects IS the fresh-subject guarantee made visible. *)
  { section = "7.1";
    title = "Fresh hidden subjects for ordinary values";
    coverage = Exercise {
      program = {|#lang tesl
module Inv71FreshSubject exposing [attack]
import Tesl.Prelude exposing [Int, Fact, attachFact]
fact Sanitized (n: Int)
establish san(n: Int) -> Fact (Sanitized n) = Sanitized n
fn need42(n: Int ::: Sanitized 42) -> Int = n
fn attack() -> Int =
  let pf = san 42
  need42 (attachFact 42 pf)
|};
      (* two distinct occurrence-keyed hidden subjects: `lit#…:L:C` ≠ `lit#…:L:C` *)
      expect = "proof subject mismatch.*lit#\\|lit#.*being attached to a value derived from.*lit#" } };

  (* 7.2 — the user NEVER writes the hidden name; subjects are minted internally.
     Same program as 7.1, but here we pin that the subject the diagnostic reports
     is a compiler-minted `lit#…` token — a form the source never spells and
     therefore cannot fabricate or replay by hand. *)
  { section = "7.2";
    title = "Users may not fabricate or replay hidden subjects directly";
    coverage = Exercise {
      program = {|#lang tesl
module Inv72HiddenName exposing [attack]
import Tesl.Prelude exposing [Int, Fact, attachFact]
fact Sanitized (n: Int)
establish san(n: Int) -> Fact (Sanitized n) = Sanitized n
fn need42(n: Int ::: Sanitized 42) -> Int = n
fn attack() -> Int =
  let pf = san 42
  need42 (attachFact 42 pf)
|};
      (* the reported subject is the internal `lit#…` name, unspellable in source *)
      expect = "the fact describes `lit#" } };

  (* 7.3 — facts attach to SUBJECTS, not surface spellings. A consumer requiring
     `IsTok x` cannot be satisfied by passing a raw `x` that never earned the
     proof; the spelling `x` is not a fungible carrier. *)
  { section = "7.3";
    title = "Facts attach to subjects, not to surface spellings";
    coverage = Exercise {
      program = {|module Inv73Spelling exposing [bad]
import Tesl.Prelude exposing [String]
import Tesl.String exposing [String.length]
fact IsTok (s: String)
check checkTok(s: String) -> s: String ::: IsTok s =
  if String.length s > 8 then
    ok s ::: IsTok s
  else
    fail 400 "bad"
fn consume(s: String ::: IsTok s) -> String = s
fn bad(x: String) -> String =
  consume x
|};
      expect = "does not statically satisfy declared proof `IsTok x" } };

  (* 7.4 — name shadowing is illegal for proof-relevant binders. *)
  { section = "7.4";
    title = "Name shadowing is illegal";
    coverage = Exercise {
      program = {|module Inv74Shadow exposing [f]
import Tesl.Prelude exposing [Int]
fn f(x: Int) -> Int =
  let x = x + 1
  x
|};
      expect = "shadows existing name" } };

  (* 7.5 — `forgetFact` DROPS the proof (keeping the subject). The forgotten
     value can no longer satisfy a proof-requiring consumer: forgetFact really
     erased the evidence rather than being a no-op. *)
  { section = "7.5";
    title = "`forgetFact` drops proofs but preserves the subject";
    coverage = Exercise {
      program = {|module Inv75Forget exposing [bad]
import Tesl.Prelude exposing [String, forgetFact]
import Tesl.String exposing [String.length]
fact IsTok (s: String)
check checkTok(s: String) -> s: String ::: IsTok s =
  if String.length s > 8 then
    ok s ::: IsTok s
  else
    fail 400 "bad"
fn consume(s: String ::: IsTok s) -> String = s
fn bad(raw: String) -> String =
  let v = check checkTok raw
  let stripped = forgetFact v
  consume stripped
|};
      expect = "does not statically satisfy declared proof `IsTok raw" } };

  (* 7.6 — a `detachFact`ed proof continues to refer to its ORIGINAL subject.
     Detaching a proof about `a` yields a token the compiler still reports as
     describing `a`, even when we try to reattach it elsewhere. *)
  { section = "7.6";
    title = "`detachFact` preserve the original subject identity";
    coverage = Exercise {
      program = {|module Inv76Detach exposing [bad]
import Tesl.Prelude exposing [String, detachFact, attachFact]
import Tesl.String exposing [String.length]
fact IsTok (s: String)
check checkTok(s: String) -> s: String ::: IsTok s =
  if String.length s > 8 then
    ok s ::: IsTok s
  else
    fail 400 "bad"
fn consume(s: String ::: IsTok s) -> String = s
fn bad(a: String, b: String) -> String =
  let va = check checkTok a
  let tok = detachFact va
  let rb = attachFact b tok
  consume rb
|};
      expect = "the fact describes `a`" } };

  (* 7.7 — `attachFact` does NOT retarget a proof to a new subject. Attaching a
     proof-about-`a` onto `b` is rejected: the proof stays about `a`, so `b`
     gains nothing. (Same program as 7.6, asserting the retarget half.) *)
  { section = "7.7";
    title = "`attachFact` does not retarget a proof to a new subject";
    coverage = Exercise {
      program = {|module Inv77Reattach exposing [bad]
import Tesl.Prelude exposing [String, detachFact, attachFact]
import Tesl.String exposing [String.length]
fact IsTok (s: String)
check checkTok(s: String) -> s: String ::: IsTok s =
  if String.length s > 8 then
    ok s ::: IsTok s
  else
    fail 400 "bad"
fn consume(s: String ::: IsTok s) -> String = s
fn bad(a: String, b: String) -> String =
  let va = check checkTok a
  let tok = detachFact va
  let rb = attachFact b tok
  consume rb
|};
      expect = "being attached to a value derived from `b`" } };

  (* 7.8 — unbound GDP names in proof templates are rejected: a return proof
     whose subject (`m`) is not a bound parameter is refused. *)
  { section = "7.8";
    title = "Unbound GDP names in proof templates are rejected";
    coverage = Exercise {
      program = {|module Inv78UnboundGdp exposing [f]
import Tesl.Prelude exposing [Int]
fact P (n: Int)
check f(n: Int) -> n: Int ::: P m =
  ok n ::: P m
|};
      expect = "'m' is not a parameter name\\|not a parameter name\\|unbound" } };

  (* 7.9 — an existential witness may not escape: the hidden witness of an
     `exists w => …` result cannot instantiate a downstream proof site, so
     feeding the existential result to a proof-requiring consumer is rejected. *)
  { section = "7.9";
    title = "Existential witnesses may not escape";
    coverage = Exercise {
      program = {|module Inv79Skolem exposing [bad]
import Tesl.Prelude exposing [String]
import Tesl.String exposing [String.length]
import Tesl.Id exposing [generatePrefixedId]
import Tesl.Random exposing [random]
fact IsTok (s: String)
check checkTok(s: String) -> s: String ::: IsTok s =
  if String.length s > 8 then
    ok s ::: IsTok s
  else
    fail 400 "invalid token"
fn gen() -> exists t: String => String ::: IsTok t requires [random] =
  let raw = generatePrefixedId "tok"
  let validated = check checkTok raw
  exists raw =>
    validated
fn consume(s: String ::: IsTok s) -> String = s
fn bad() -> String requires [random] =
  let tok = gen()
  consume tok
|};
      expect = "does not statically satisfy declared proof `IsTok tok" } };

  (* 7.10 — proof verification is COMPILE-TIME (proofs are erased; the checker is
     the sole contract). Semantic object: an unsafe program is rejected as a
     STATIC `error[…]` at `--check`, and the rejection does NOT leak to the
     Racket runtime (no `.rkt:` / `raise-user-error` markers). The exercise
     below is checked specially (see [assert_no_runtime_leak]); the [expect]
     regex pins the static `error[` marker. *)
  { section = "7.10";
    title = "Proof verification is compile-time; some runtime semantics remain";
    coverage = Exercise {
      program = {|module Inv710CompileTime exposing [bad]
import Tesl.Prelude exposing [String]
fact IsTok (s: String)
fn consume(s: String ::: IsTok s) -> String = s
fn bad(x: String) -> String =
  consume x
|};
      expect = "error\\[" } };

  (* 7.11 — newtype nominal identity: `UserId` and `ProjectId` (both over String)
     are distinct types and may not be interchanged. *)
  { section = "7.11";
    title = "Newtype nominal identity is enforced at runtime";
    coverage = Exercise {
      program = {|module Inv711Newtype exposing [f]
import Tesl.Prelude exposing [String]
type UserId = String
type ProjectId = String
fn f(u: UserId) -> ProjectId =
  u
|};
      expect = "cannot unify UserId with ProjectId\\|cannot unify ProjectId with UserId" } };

  (* 7.12 — `:::` proof fabrication is restricted to trusted kinds: a plain `fn`
     may not mint `ok … ::: P` evidence. *)
  { section = "7.12";
    title = "Proof fabrication via `:::` is restricted to trusted function kinds";
    coverage = Exercise {
      program = {|module Inv712TripleColon exposing [f]
import Tesl.Prelude exposing [Int]
fact P (n: Int)
fn f(n: Int) -> Int ::: P n =
  ok n ::: P n
|};
      expect = "proof construction is not allowed in `fn`\\|only `check` and `auth`" } };

  (* 7.13 — the `?` named-pack return: a `-> Todo ? FromDb (Id == todoId)` grant
     must be established by the body's SELECT WHERE. Filtering by the wrong
     column forges the provenance and is rejected. *)
  { section = "7.13";
    title = "The `?` pack operator for named return values";
    coverage = Exercise {
      program = {|module Inv713NamedPack exposing []
import Tesl.Prelude exposing [String, List]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.DB exposing [dbRead, dbWrite]
fact TodoId (id: String)
check checkTodoId(id: String) -> id: String ::: TodoId id = ok id ::: TodoId id
entity Todo table "todos" primaryKey id {
  id: String
  ownerId: String @db(text)
  title: String
}
fn getTodo(todoId: String ::: TodoId todoId) -> Todo ? FromDb (Id == todoId)
  requires [dbRead] =
  let e = selectOne t from Todo where t.ownerId == todoId
  case e of
    Nothing -> fail 404 "x"
    Something t -> t
|};
      expect = "not established by this WHERE\\|does not constrain\\|OwnerId.*Id\\|Id.*OwnerId" } };
]

(* ── The EXPECTED KnownGap set (C14) ─────────────────────────────────────────
   Currently EMPTY: every §7 invariant has a real red→green exercise. If a guard
   is ever legitimately un-exercisable it must be moved to `KnownGap` in the
   registry AND its section added here (with the reason living on the row). Any
   drift between the actual gaps and this set is a HARD failure — so a guard
   quietly downgraded to a gap, or a stale expected-gap, breaks the build. *)
let expected_known_gaps : string list = []

(* ── Locate the repo root (has LANGUAGE-SPEC.md + compiler/test/) ──────────── *)
let is_repo_root d =
  Sys.file_exists (Filename.concat d "LANGUAGE-SPEC.md")
  && Sys.file_exists
       (Filename.concat d (Filename.concat "compiler" "test"))

let rec up_to_root dir n =
  if n > 12 then None
  else if is_repo_root dir then Some dir
  else
    let parent = Filename.dirname dir in
    if parent = dir then None else up_to_root parent (n + 1)

let repo_root =
  let starts =
    [ (try Sys.getenv "TESL_REPO_ROOT" with Not_found -> "");
      Sys.getcwd ();
      (try Filename.dirname (Unix.realpath Sys.executable_name)
       with _ -> Filename.dirname Sys.executable_name) ]
  in
  let rec pick = function
    | [] -> None
    | s :: rest ->
      if s <> "" && is_repo_root s then Some s
      else match up_to_root (if s = "" then Sys.getcwd () else s) 0 with
        | Some d -> Some d
        | None -> pick rest
  in
  match pick starts with
  | Some d -> d
  | None ->
    prerr_endline
      "FATAL: could not locate repo root (LANGUAGE-SPEC.md + compiler/test); \
       set TESL_REPO_ROOT";
    exit 2

let spec_path = Filename.concat repo_root "LANGUAGE-SPEC.md"

let read_lines path =
  try In_channel.with_open_text path In_channel.input_all
      |> String.split_on_char '\n'
  with Sys_error _ ->
    Printf.eprintf "FATAL: could not read %s\n" path; exit 2

(* ── Part (1) support: does `### 7.N ...` exist as a heading? ──────────────── *)
let spec_lines = read_lines spec_path

(* A `### 7.N` heading, where 7.N is followed by a space or end-of-token so
   "7.1" does not spuriously match "7.10". *)
let heading_exists section =
  let re =
    Str.regexp
      ("^### " ^ Str.quote section ^ "\\([ \t]\\|$\\)")
  in
  List.exists
    (fun line -> Str.string_match re line 0)
    spec_lines

(* ── Part (2) support: locate + drive main.exe ─────────────────────────────
   Same resolution discipline as compiler/test/test_proof_negatives.ml. *)
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
       (* also try repo_root/compiler/_build for a bare `dune exec` invocation *)
       let candidate3 =
         Filename.concat repo_root "compiler/_build/default/bin/main.exe" in
       if Sys.file_exists candidate then candidate
       else if Sys.file_exists candidate2 then candidate2
       else if Sys.file_exists candidate3 then candidate3
       else "tesl")

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

(* The compiler resolves a module by its file name, so the temp file must be
   named after the `module X` (or `library X`) header (kebab-cased) or a spurious
   V001 name-mismatch error masks the property under test. *)
let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-inv" "" in
  let name =
    let re = Str.regexp "\\(module\\|library\\)[ \t\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
    try
      ignore (Str.search_forward re content 0);
      let mname = Str.matched_group 2 content in
      let buf = Buffer.create (String.length mname + 4) in
      String.iteri (fun i c ->
        if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
        else if c >= 'A' && c <= 'Z' then
          (Buffer.add_char buf '-'; Buffer.add_char buf (Char.lowercase_ascii c))
        else Buffer.add_char buf c) mname;
      Buffer.contents buf ^ ".tesl"
    with Not_found -> "test.tesl"
  in
  let path = Filename.concat dir name in
  let oc = open_out path in output_string oc content; close_out oc;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

(* A static rejection that leaks to the Racket runtime is NOT a compile-time
   guarantee (this is the semantic object of 7.10). *)
let runtime_leak_re =
  Str.regexp_case_fold
    "raise-user-error\\|raise-argument-error\\|application: not a procedure\\|\
     \\.rkt:[0-9]\\|contract violation"

(* Run one invariant's antagonistic [program], asserting NON-ZERO exit AND that
   the invariant-specific diagnostic [expect] matches. Returns [Ok ()] or
   [Error msg]. For 7.10 we additionally forbid a runtime leak. *)
let run_exercise ~section ~program ~expect =
  with_temp_file program (fun path ->
    let code, out = run_compiler ["--check"; path] in
    let leaked =
      try ignore (Str.search_forward runtime_leak_re out 0); true
      with Not_found -> false
    in
    if leaked then
      Error (Printf.sprintf
        "static rejection LEAKED TO RUNTIME (expected a compile-time error), got:\n%s"
        out)
    else if code = 0 then
      Error (Printf.sprintf
        "expected a NON-ZERO exit rejecting the invariant-%s violation, but \
         `--check` succeeded (exit 0). The guard may have been removed or the \
         program is no longer antagonistic.\nCompiler output:\n%s"
        section out)
    else begin
      let re = Str.regexp_case_fold expect in
      match Str.search_forward re out 0 with
      | _ -> Ok ()
      | exception Not_found ->
        Error (Printf.sprintf
          "rejected (exit %d) but the invariant-specific diagnostic %S did NOT \
           match — the semantic object this invariant guards may have moved.\n\
           Compiler output:\n%s"
          code expect out)
    end)

(* ── Run ───────────────────────────────────────────────────────────────────── *)
let () =
  Printf.printf "# §7 soundness-invariant registry cross-check (C14: semantic-object coverage)\n";
  Printf.printf "#   spec      = %s\n" spec_path;
  Printf.printf "#   compiler  = %s\n" compiler;
  Printf.printf "#   registry  = %d invariant(s)\n\n" (List.length registry);

  (* Part (1): anti-drift — every section must resolve to a real heading. *)
  let unresolved =
    List.filter (fun r -> not (heading_exists r.section)) registry
  in
  List.iter
    (fun r ->
       if heading_exists r.section then
         Printf.printf "heading ok   - ### %s %s\n" r.section r.title
       else
         Printf.printf "heading MISS - ### %s (%s) has no matching heading\n"
           r.section r.title)
    registry;

  (* Part (2): semantic-object coverage — a real red→green exercise per
     invariant (HARD). KnownGaps are reconciled against [expected_known_gaps]. *)
  Printf.printf "\n";
  let failures = ref [] in
  let exercised = ref 0 and gaps = ref [] in
  List.iter
    (fun r ->
       match r.coverage with
       | KnownGap reason ->
         gaps := r.section :: !gaps;
         Printf.printf "invariant %s: KNOWN-GAP (%s)\n" r.section reason
       | Exercise { program; expect } ->
         (match run_exercise ~section:r.section ~program ~expect with
          | Ok () ->
            incr exercised;
            Printf.printf "invariant %s: EXERCISED (rejected; matched %S)\n"
              r.section expect
          | Error msg ->
            failures := (r.section, msg) :: !failures;
            Printf.printf "invariant %s: EXERCISE FAILED\n  %s\n" r.section msg))
    registry;

  let n = List.length registry in
  Printf.printf "\n%d/%d invariants exercised (red→green); %d known-gap(s)\n"
    !exercised n (List.length !gaps);

  (* Part (3): KnownGap-set reconciliation (HARD) — the actual gap set must be
     EXACTLY [expected_known_gaps]. A new gap, or a stale expectation, fails. *)
  let sort = List.sort_uniq compare in
  let actual_gaps = sort !gaps and expected_gaps = sort expected_known_gaps in
  let unexpected = List.filter (fun s -> not (List.mem s expected_gaps)) actual_gaps in
  let missing    = List.filter (fun s -> not (List.mem s actual_gaps)) expected_gaps in
  if unexpected <> [] then
    failures := ("known-gap",
      Printf.sprintf
        "UNEXPECTED KnownGap(s) %s — an invariant lost its real exercise. \
         Restore the guard/exercise, or (if genuinely un-exercisable) add the \
         section to expected_known_gaps with a reason."
        (String.concat ", " unexpected)) :: !failures;
  if missing <> [] then
    failures := ("known-gap",
      Printf.sprintf
        "STALE expected_known_gaps %s — no longer a gap (now exercised). \
         Remove it from expected_known_gaps."
        (String.concat ", " missing)) :: !failures;

  (* Part (4): PASS/FAIL + exit code from BOTH the anti-drift gate AND coverage. *)
  Printf.printf "\n";
  let ok = unresolved = [] && !failures = [] in
  if unresolved <> [] then begin
    Printf.printf "FAILURES: %d §7 section id(s) do not resolve to a heading:\n"
      (List.length unresolved);
    List.iter (fun r -> Printf.printf "  - %s (%s)\n" r.section r.title) unresolved
  end;
  if !failures <> [] then begin
    Printf.printf "FAILURES: %d §7 coverage exercise(s) failed:\n"
      (List.length !failures);
    List.iter (fun (sec, msg) -> Printf.printf "  - %s: %s\n" sec msg)
      (List.rev !failures)
  end;
  if ok then begin
    Printf.printf
      "PASS (all %d §7 headings resolve; all %d exercised; known-gaps = expected)\n"
      n !exercised;
    exit 0
  end else
    exit 1
