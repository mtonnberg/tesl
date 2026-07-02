(** A2 — capability-check auth/check/establish bodies (effect-laundering hole).

    Regression guard for the CAP-A2 PART 1 static fix: before it,
    [validation_capabilities.cap_check_kind_info] returned [None] for
    CheckKind/AuthKind/EstablishKind, so their bodies were NOT walked for
    privileged operations.  A read-only GET handler declaring only [dbRead]
    could route through a `check`/`auth`/`establish` whose body performed a
    dbWrite (insert/delete/update) with NO covering `requires`; the effect then
    laundered through to runtime, satisfied only by the ambient whole-app union.

    After the fix, [cap_check_kind_info] is an EXHAUSTIVE match: check/auth/
    establish each get their own transitive-closure capability check (identical
    to `fn`), so an undeclared effect in their body is a STATIC compile error
    (error[V001] "... uses privileged operations and callees requiring [..] but
    does not declare them").

    We compile IN-PROCESS via [Compile.compile_source] (same approach as
    test_integration.ml) rather than shelling out to a `tesl` binary: under
    `dune test` each test runs in a per-test sandbox where a sibling
    `../bin/main.exe` is NOT reachable and a stale `tesl` on PATH would silently
    mask a regression.  In-process compilation always exercises the freshly
    linked validation layer.

    Negatives assert:
      - compilation FAILS (Compile.Failure);
      - a diagnostic carries the exact V001 wording for the offending kind.
    Positives assert a check/auth/establish that HONESTLY declares its covering
    capability (or is effect-free) still compiles clean — the fix must not
    over-reject the corpus, which already declares honest caps. *)

open Alcotest

(* Read-only compilation: imports (Tesl.DB / Tesl.Http / …) resolve against the
   repo root, discovered exactly like test_integration.ml.  TESL_REPO_ROOT (if
   set) wins; otherwise walk up from the test exe to the dir containing
   `compiler/`.  Compilation is read-only, so honoring an externally-set
   TESL_REPO_ROOT does not mutate anything. *)
let root =
  match Sys.getenv_opt "TESL_REPO_ROOT" with
  | Some p when p <> "" -> p
  | _ ->
    let rec find dir =
      let candidate = Filename.concat dir "compiler" in
      if (try Sys.file_exists candidate && Sys.is_directory candidate with _ -> false)
      then dir
      else
        let parent = Filename.dirname dir in
        if parent = dir then Filename.current_dir_name
        else find parent
    in
    find (Filename.dirname Sys.executable_name)

let failf fmt = Printf.ksprintf failwith fmt

(* Derive a kebab-case file name from the module header so the compiler's
   "module header does not match file name" check stays quiet (it resolves
   imports by file name). *)
let file_name_of_src content =
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

let compile src =
  let fname = file_name_of_src src in
  Compile.compile_source ~root_path:root ~type_check:true fname src

let diags_text diags =
  String.concat "\n"
    (List.map (fun (d : Compile.diagnostic) ->
       Printf.sprintf "error[%s]: %s" d.code d.message) diags)

(* A negative: compilation must FAIL and some diagnostic must match [pat]. *)
let should_fail pat src =
  match compile src with
  | Compile.Success _ ->
    failf "expected static failure matching %S, but compiled cleanly" pat
  | Compile.Failure diags ->
    let text = diags_text diags in
    let re = Str.regexp_case_fold pat in
    (try ignore (Str.search_forward re text 0)
     with Not_found ->
       failf "expected failure matching %S, got:\n%s" pat text)

(* A positive: compilation must SUCCEED (no diagnostics). *)
let should_pass src =
  match compile src with
  | Compile.Success _ -> ()
  | Compile.Failure diags ->
    failf "expected clean compile, got:\n%s" (diags_text diags)

(* ── Shared fragments ──────────────────────────────────────────────────────── *)

(* An entity to insert into (dbWrite) / select from (dbRead). *)
let audit_entity = {|
entity AuditLog table "audit_log" primaryKey id {
  id: String @db(text)
  msg: String @db(text)
}
|}

(* ── check laundering ──────────────────────────────────────────────────────── *)

(* A `check` body performs an insert (dbWrite) with NO `requires`.  Before the
   fix this compiled clean (the ambient union satisfied the dbWrite at runtime);
   it must now be a STATIC compile error. *)
let test_check_launders_dbwrite () =
  should_fail
    "check 'isPositive' uses privileged operations and callees requiring .*dbWrite.* but does not declare them"
    (Printf.sprintf {|
#lang tesl
module CheckLaunder exposing []
import Tesl.Prelude exposing [Bool(..), Int, String, Unit]
import Tesl.DB exposing [dbRead, dbWrite]
%s
fact Positive (taskId: Int)
check isPositive(taskId: Int) -> taskId: Int ::: Positive taskId =
  let _ = insert AuditLog { id: "audit-1", msg: "checked" }
  if taskId > 0 then
    ok taskId ::: Positive taskId
  else
    fail 400 "must be positive"
|} audit_entity)

(* Honest declaration: the same check DECLARING `requires [dbWrite]` compiles
   clean.  Proves the fix does not over-reject a truthful check. *)
let test_check_honest_dbwrite_positive () =
  should_pass
    (Printf.sprintf {|
#lang tesl
module CheckHonest exposing []
import Tesl.Prelude exposing [Bool(..), Int, String, Unit]
import Tesl.DB exposing [dbRead, dbWrite]
%s
fact Positive (taskId: Int)
check isPositive(taskId: Int) -> taskId: Int ::: Positive taskId
  requires [dbWrite] =
  let _ = insert AuditLog { id: "audit-1", msg: "checked" }
  if taskId > 0 then
    ok taskId ::: Positive taskId
  else
    fail 400 "must be positive"
|} audit_entity)

(* Effect-free check still needs no `requires` (must not be over-rejected). *)
let test_check_effect_free_positive () =
  should_pass
    {|
#lang tesl
module CheckPure exposing []
import Tesl.Prelude exposing [Bool(..), Int, String]
fact Positive (taskId: Int)
check isPositive(taskId: Int) -> taskId: Int ::: Positive taskId =
  if taskId > 0 then
    ok taskId ::: Positive taskId
  else
    fail 400 "must be positive"
|}

(* ── auth laundering ───────────────────────────────────────────────────────── *)

(* An `auth` body that performs a selectOne (dbRead) but declares NO `requires`
   is rejected for the auth kind specifically. *)
let test_auth_launders_dbread () =
  should_fail
    "auth 'cookieAuth' uses privileged operations and callees requiring .*dbRead.* but does not declare them"
    (Printf.sprintf {|
#lang tesl
module AuthLaunder exposing []
import Tesl.Prelude exposing [String]
import Tesl.Http exposing [HttpRequest]
import Tesl.Dict exposing [Dict.lookup]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.DB exposing [dbRead]
%s
fact Authenticated (user: String)
auth cookieAuth(request: HttpRequest) -> user: String ::: Authenticated user =
  case Dict.lookup "user" request.cookies of
    Nothing -> fail 401 "no user"
    Something userId ->
      let found = selectOne a from AuditLog where a.id == userId
      case found of
        Nothing -> fail 401 "session invalid"
        Something _ -> ok userId ::: Authenticated user
|} audit_entity)

(* Honest auth: declares a capability that implies dbRead; compiles clean. *)
let test_auth_honest_dbread_positive () =
  should_pass
    (Printf.sprintf {|
#lang tesl
module AuthHonest exposing []
import Tesl.Prelude exposing [String]
import Tesl.Http exposing [HttpRequest]
import Tesl.Dict exposing [Dict.lookup]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.DB exposing [dbRead]
capability sessionRead implies dbRead
%s
fact Authenticated (user: String)
auth cookieAuth(request: HttpRequest) -> user: String ::: Authenticated user
  requires [sessionRead] =
  case Dict.lookup "user" request.cookies of
    Nothing -> fail 401 "no user"
    Something userId ->
      let found = selectOne a from AuditLog where a.id == userId
      case found of
        Nothing -> fail 401 "session invalid"
        Something _ -> ok userId ::: Authenticated user
|} audit_entity)

(* Effect-free auth (only Dict.lookup) needs no `requires`. *)
let test_auth_effect_free_positive () =
  should_pass
    {|
#lang tesl
module AuthPure exposing []
import Tesl.Prelude exposing [String]
import Tesl.Http exposing [HttpRequest]
import Tesl.Dict exposing [Dict.lookup]
import Tesl.Maybe exposing [Maybe(..)]
fact Authenticated (user: String)
auth cookieAuth(request: HttpRequest) -> user: String ::: Authenticated user =
  case Dict.lookup "user" request.cookies of
    Nothing -> fail 401 "no user"
    Something userId -> ok userId ::: Authenticated user
|}

(* ── establish laundering ──────────────────────────────────────────────────── *)

(* An `establish` body that performs an insert (dbWrite) but declares NO
   `requires` is rejected for the establish kind specifically.  (establish
   bodies return the proof constructor directly — no ok/fail.) *)
let test_establish_launders_dbwrite () =
  should_fail
    "establish 'trustAudit' uses privileged operations and callees requiring .*dbWrite.* but does not declare them"
    (Printf.sprintf {|
#lang tesl
module EstablishLaunder exposing []
import Tesl.Prelude exposing [Bool(..), Int, String, Unit]
import Tesl.DB exposing [dbRead, dbWrite]
%s
fact Trusted (taskId: Int)
establish trustAudit(taskId: Int) -> Fact (Trusted taskId) =
  let _ = insert AuditLog { id: "audit-1", msg: "trusted" }
  Trusted taskId
|} audit_entity)

(* Effect-free establish (pure proof constructor) needs no `requires`. *)
let test_establish_effect_free_positive () =
  should_pass
    {|
#lang tesl
module EstablishPure exposing []
import Tesl.Prelude exposing [Int]
fact Trusted (taskId: Int)
establish trustAudit(taskId: Int) -> Fact (Trusted taskId) =
  Trusted taskId
|}

(* ── Runner ────────────────────────────────────────────────────────────────── *)

let () =
  run "A2-Capability-Launder" [
    "check", [
      test_case "check laundering dbWrite -> STATIC reject" `Quick test_check_launders_dbwrite;
      test_case "check honest requires [dbWrite] -> accepted" `Quick test_check_honest_dbwrite_positive;
      test_case "effect-free check -> accepted" `Quick test_check_effect_free_positive;
    ];
    "auth", [
      test_case "auth laundering dbRead -> STATIC reject" `Quick test_auth_launders_dbread;
      test_case "auth honest requires [sessionRead] -> accepted" `Quick test_auth_honest_dbread_positive;
      test_case "effect-free auth -> accepted" `Quick test_auth_effect_free_positive;
    ];
    "establish", [
      test_case "establish laundering dbWrite -> STATIC reject" `Quick test_establish_launders_dbwrite;
      test_case "effect-free establish -> accepted" `Quick test_establish_effect_free_positive;
    ];
  ]
