(** Regression tests for the three P0 soundness holes closed after the formal
    review (see REVIEW-TECHNICAL.md). Each negative case is a minimal program
    that was wrongly ACCEPTED before the fix and must now be REJECTED; each
    positive case is the closest legitimate program that must keep compiling.

    Holes:
      P0-1  FromDb/FromQueue provenance forgeable in a plain `fn`
            (checker.ml is_infrastructure_proof + validation_advanced.ml
             is_stdlib_auto whitelisted the predicate by NAME, with no DB site).
      P0-2  `requires []` capability suppression via a binder (e.g. a case-arm
            `delete`) in a DISJOINT scope poisoning the function-wide bound-name
            set (validation_capabilities.ml fn_bound_names → now lexical).
      P0-3  auth privilege escalation: an endpoint over-declaring an auth
            predicate its `via` fn does not produce, and the named-pack
            `? Authenticated` form skipping the auth-wiring check
            (validation_structural.ml). *)

open Alcotest

(* ── Helpers (same shape as the other antagonistic suites) ──────────────── *)

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
  let tmp = Filename.temp_file "tesl-p0-test" ".tesl" in
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
  if has_error then Printf.eprintf "Unexpected error output:\n%s\n" out;
  check bool "should compile without errors" false has_error

let should_fail pattern src =
  let out = compile_string src in
  let found =
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0); true with Not_found -> false
  in
  if not found then Printf.eprintf "Expected pattern '%s' in output:\n%s\n" pattern out;
  check bool (Printf.sprintf "should fail with pattern: %s" pattern) true found

(* ── P0-1: FromDb provenance forgery ─────────────────────────────────────── *)

let entity_task =
  "#lang tesl\nmodule T exposing []\n\
   import Tesl.Prelude exposing [String]\n\
   import Tesl.DB exposing [dbRead]\n\
   import Tesl.Maybe exposing [Maybe(..)]\n\
   entity Task table \"tasks\" primaryKey id {\n\
   \  id: String\n\
   \  title: String\n\
   \  status: String\n\
   }\n"

(* A plain fn with NO select/insert that declares a :::-attached FromDb return. *)
let test_p0_1_fromdb_forge_rejected () =
  should_fail "cannot declare a proof.*return\\|cannot introduce new proofs\\|FromDb"
    (entity_task ^
     "fn forgeTask(id: String) -> t: Task ::: FromDb (Id == id) t =\n\
      \  Task { id: id, title: \"fabricated\", status: \"fake\" }\n")

(* The SAME :::-attached FromDb return, but with a real selectOne body: legit. *)
let test_p0_1_fromdb_with_select_accepted () =
  should_pass
    (entity_task ^
     "fn getItem(id: String) -> t: Task ::: FromDb (Id == id) t\n\
      \  requires [dbRead] =\n\
      \  let r = selectOne t from Task where t.id == id\n\
      \  case r of\n\
      \    Nothing -> fail 404 \"task not found\"\n\
      \    Something t -> t\n")

(* The named-pack `?` FromDb form with a real select must keep compiling. *)
let test_p0_1_fromdb_named_pack_accepted () =
  should_pass
    (entity_task ^
     "fn fetchTask(id: String) -> Task ? FromDb (Id == id)\n\
      \  requires [dbRead] =\n\
      \  let r = selectOne t from Task where t.id == id\n\
      \  case r of\n\
      \    Nothing -> fail 404 \"task not found\"\n\
      \    Something t -> t\n")

(* ── P0-2: requires [] capability suppression ────────────────────────────── *)

let entity_order =
  "#lang tesl\nmodule T exposing []\n\
   import Tesl.Prelude exposing [String]\n\
   import Tesl.Maybe exposing [Maybe(..)]\n\
   entity Order table \"orders\" primaryKey id {\n\
   \  id: String\n\
   \  status: String\n\
   }\n"

(* `requires []` but performs a real `delete` (dbWrite); `delete` is bound as a
   case-arm var in a disjoint scope to suppress the capability function-wide. *)
let test_p0_2_cap_suppression_rejected () =
  should_fail "dbWrite\\|does not declare\\|privileged operations"
    (entity_order ^
     "fn evict(m: Maybe String) -> String\n\
      \  requires [] =\n\
      \  delete o from Order\n\
      \    where o.status == \"expired\"\n\
      \  case m of\n\
      \    Nothing -> \"none\"\n\
      \    Something delete -> \"got\"\n")

(* Same real delete, correctly declaring requires [dbWrite]: legit. *)
let test_p0_2_cap_declared_accepted () =
  should_pass
    "#lang tesl\nmodule T exposing []\n\
     import Tesl.Prelude exposing [String]\n\
     import Tesl.DB exposing [dbWrite]\n\
     entity Order table \"orders\" primaryKey id {\n\
     \  id: String\n\
     \  status: String\n\
     }\n\
     fn evictLegit() -> String\n\
     \  requires [dbWrite] =\n\
     \  delete o from Order\n\
     \    where o.status == \"expired\"\n\
     \  \"ok\"\n"

(* A genuine PARAMETER shadow of a stdlib effect builtin must still suppress its
   capability (this is the legitimate case the lexical fix must preserve). *)
let test_p0_2_param_shadow_still_accepted () =
  should_pass
    "#lang tesl\nmodule T exposing []\n\
     import Tesl.Prelude exposing [String]\n\
     fn pick(env: String) -> String requires [] = env\n"

(* ── P0-3: auth privilege escalation ─────────────────────────────────────── *)

let auth_header =
  "#lang tesl\nmodule T exposing []\n\
   import Tesl.Prelude exposing [Bool(..), Int, String, Unit]\n\
   import Tesl.Json exposing [intCodec, stringCodec]\n\
   import Tesl.Http exposing [HttpRequest]\n\
   import Tesl.Maybe exposing [Maybe(..)]\n\
   import Tesl.Dict exposing [Dict.lookup]\n\
   import Tesl.App exposing [App]\n\
   import Tesl.Database exposing [Database, DatabaseBackend, Memory]\n\
   capability readTaskCookie\n\
   record AdminUser { id: String  role: String }\n\
   record AdminTask { id: Int  title: String  ownerId: String }\n\
   codec AdminTask {\n\
   \  toJson {\n\
   \    id -> \"id\" with_codec intCodec\n\
   \    title -> \"title\" with_codec stringCodec\n\
   \    ownerId -> \"ownerId\" with_codec stringCodec\n\
   \  }\n\
   \  fromJson_forbidden\n\
   }\n\
   database TheDb = Database { entities: []  backend: Memory }\n\
   defaultExamplePort = 8092\n\
   fact Authenticated (req: AdminUser)\n\
   fact IsAdmin (req: AdminUser)\n\
   auth cookieUserAuth(request: HttpRequest) -> requestUser: AdminUser ::: Authenticated requestUser\n\
   \  requires [readTaskCookie] =\n\
   \  case Dict.lookup \"user\" request.cookies of\n\
   \    Nothing -> fail 401 \"Missing user cookie\"\n\
   \    Something userId -> ok AdminUser { id: userId, role: \"user\" } ::: Authenticated requestUser\n\
   auth adminAuth(request: HttpRequest) -> requestUser: AdminUser ::: IsAdmin requestUser\n\
   \  requires [readTaskCookie] =\n\
   \  case Dict.lookup \"role\" request.cookies of\n\
   \    Nothing -> fail 403 \"Missing role cookie\"\n\
   \    Something role -> ok AdminUser { id: \"admin\", role: role } ::: IsAdmin requestUser\n"

(* Endpoint authenticates `via cookieUserAuth` (produces Authenticated) but
   DECLARES IsAdmin, which the handler trusts. Privilege escalation. *)
let test_p0_3_auth_over_declared_rejected () =
  should_fail "not established by\\|privilege-escalation\\|unproven"
    (auth_header ^
     "handler getAdminTask(requestUser: AdminUser ::: IsAdmin requestUser) -> AdminTask =\n\
      \  AdminTask { id: 2, title: \"x\", ownerId: \"anna\" }\n\
      api TheApi {\n\
      \  get \"/tasks/admin\"\n\
      \    auth requestUser: AdminUser ::: IsAdmin requestUser via cookieUserAuth\n\
      \    -> AdminTask\n\
      }\n\
      server TheServer for TheApi { getAdminTask = getAdminTask }\n\
      main() -> App requires [readTaskCookie] =\n\
      \  App { database: TheDb  api: TheServer  port: defaultExamplePort }\n")

(* Endpoint correctly declares only what `via cookieUserAuth` produces: legit. *)
let test_p0_3_auth_subset_accepted () =
  should_pass
    (auth_header ^
     "handler getAdminTask(requestUser: AdminUser ::: Authenticated requestUser) -> AdminTask =\n\
      \  AdminTask { id: 2, title: \"x\", ownerId: \"anna\" }\n\
      api TheApi {\n\
      \  get \"/tasks/admin\"\n\
      \    auth requestUser: AdminUser ::: Authenticated requestUser via cookieUserAuth\n\
      \    -> AdminTask\n\
      }\n\
      server TheServer for TheApi { getAdminTask = getAdminTask }\n\
      main() -> App requires [readTaskCookie] =\n\
      \  App { database: TheDb  api: TheServer  port: defaultExamplePort }\n")

(* Named-pack `? Authenticated` auth fn + a handler that DROPS its auth param.
   Must be rejected (the auth-wiring check must run for named-pack auth fns). *)
let test_p0_3_auth_named_pack_drop_rejected () =
  should_fail "no auth-proof parameter\\|requires auth"
    ("#lang tesl\nmodule T exposing []\n\
      import Tesl.Prelude exposing [Bool(..), Int, String, Unit]\n\
      import Tesl.Json exposing [intCodec, stringCodec]\n\
      import Tesl.Http exposing [HttpRequest]\n\
      import Tesl.Maybe exposing [Maybe(..)]\n\
      import Tesl.Dict exposing [Dict.lookup]\n\
      import Tesl.App exposing [App]\n\
      import Tesl.Database exposing [Database, DatabaseBackend, Memory]\n\
      capability readTaskCookie\n\
      record AdminTask { id: Int  title: String  ownerId: String }\n\
      codec AdminTask {\n\
      \  toJson {\n\
      \    id -> \"id\" with_codec intCodec\n\
      \    title -> \"title\" with_codec stringCodec\n\
      \    ownerId -> \"ownerId\" with_codec stringCodec\n\
      \  }\n\
      \  fromJson_forbidden\n\
      }\n\
      database TheDb = Database { entities: []  backend: Memory }\n\
      defaultExamplePort = 8093\n\
      fact Authenticated (userId: String)\n\
      auth cookieAuth(request: HttpRequest) -> String ? Authenticated\n\
      \  requires [readTaskCookie] =\n\
      \  case Dict.lookup \"user\" request.cookies of\n\
      \    Nothing -> fail 401 \"not logged in\"\n\
      \    Something userId -> ok userId ::: Authenticated userId\n\
      handler getAdminTask() -> AdminTask\n\
      \  requires [] =\n\
      \  AdminTask { id: 2, title: \"x\", ownerId: \"anna\" }\n\
      api TheApi {\n\
      \  get \"/tasks/admin\"\n\
      \    auth user: String ::: Authenticated user via cookieAuth\n\
      \    -> AdminTask\n\
      }\n\
      server TheServer for TheApi { getAdminTask = getAdminTask }\n\
      main() -> App requires [readTaskCookie] =\n\
      \  App { database: TheDb  api: TheServer  port: defaultExamplePort }\n")

let () =
  run "P0-Soundness-Fixes" [
    "fromdb-provenance", [
      test_case "forged FromDb (no DB site) rejected" `Quick test_p0_1_fromdb_forge_rejected;
      test_case "::: FromDb with real select accepted" `Quick test_p0_1_fromdb_with_select_accepted;
      test_case "? FromDb named-pack with select accepted" `Quick test_p0_1_fromdb_named_pack_accepted;
    ];
    "capability-suppression", [
      test_case "requires [] doing real dbWrite rejected" `Quick test_p0_2_cap_suppression_rejected;
      test_case "real dbWrite with requires [dbWrite] accepted" `Quick test_p0_2_cap_declared_accepted;
      test_case "legit param shadow of builtin accepted" `Quick test_p0_2_param_shadow_still_accepted;
    ];
    "auth-escalation", [
      test_case "over-declared auth predicate rejected" `Quick test_p0_3_auth_over_declared_rejected;
      test_case "declared-subset auth accepted" `Quick test_p0_3_auth_subset_accepted;
      test_case "named-pack auth with dropped param rejected" `Quick test_p0_3_auth_named_pack_drop_rejected;
    ];
  ]
