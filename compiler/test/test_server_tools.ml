(** serverTools — server endpoints as agent tools (static rules).

    `serverTools MyServer user : List Tool` exposes the server's non-SSE
    endpoints to an agent, partially applied with the proof-carrying
    authenticated user.  These tests pin the checker's fail-closed surface:

    - the server argument must be a bare reference to a local `server`;
    - the user argument must be a bare variable whose DECLARED proof
      annotation decides per-endpoint inclusion (an `Authenticated && Admin`
      user gets the admin-gated endpoints, a plain `Authenticated` user does
      not — verified on the emitted metadata);
    - a user value with no matching declared proof is rejected;
    - partial application / passing `serverTools` around is rejected;
    - every authed endpoint must bind the same user type;
    - the enclosing fn is charged the union of the bound handlers' declared
      capabilities (V001 with the standard hint).

    Harness modeled on compiler/test/test_aisuite_capability.ml. *)

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

let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-servertools" "" in
  let path = Filename.concat dir (file_name_of_src content) in
  let oc = open_out path in output_string oc content; close_out oc;
  Fun.protect
    ~finally:(fun () -> (try Sys.remove path with _ -> ()); (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let should_fail pat src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected static failure matching %S, but compiled \
                            cleanly:\n%s" pat out;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pat out)

let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    let has_err =
      let re = Str.regexp "error\\[" in
      try ignore (Str.search_forward re out 0); true with Not_found -> false in
    if code <> 0 || has_err then
      failf "expected clean compile, got (exit %d):\n%s" code out)

let emit_output src =
  with_temp_file src (fun path ->
    let code, out = run_compiler [path] in
    if code <> 0 then failf "expected clean emit, got (exit %d):\n%s" code out;
    out)

let count_occurrences needle haystack =
  let re = Str.regexp_string needle in
  let rec go pos acc =
    match (try Some (Str.search_forward re haystack pos) with Not_found -> None) with
    | Some i -> go (i + String.length needle) (acc + 1)
    | None -> acc
  in
  go 0 0

(* ── Fixture ──────────────────────────────────────────────────────────────
   [tail] is appended after the api/server declarations; [handler_reqs] lets a
   test give the note handler privileged capabilities. *)
let fixture ?(handler_reqs = "") tail = Printf.sprintf {|#lang tesl
module StNotes exposing []

import Tesl.Prelude exposing [String, Bool, List]
import Tesl.Json exposing [stringCodec]
import Tesl.Http exposing [HttpRequest]
import Tesl.Dict exposing [Dict.lookup]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.String exposing [String.concat]
import Tesl.Agent exposing [Tool, serverTools]

record User {
  id: String
}

fact Authenticated (u: User)
fact Admin (u: User)

auth cookieAuth(request: HttpRequest) -> u: User ::: Authenticated u =
  case Dict.lookup "user" request.cookies of
    Something userId -> ok (User { id: userId }) ::: Authenticated u
    Nothing -> fail 401 "Missing user cookie"

auth adminAuth(request: HttpRequest) -> u: User ::: Authenticated u && Admin u =
  case Dict.lookup "admin" request.cookies of
    Something userId -> ok (User { id: userId }) ::: Authenticated u && Admin u
    Nothing -> fail 401 "Missing admin cookie"

# Greet the authenticated user.
handler greet(u: User ::: Authenticated u) -> String%s =
  String.concat "hello " u.id

# Wipe everything. Admin only.
handler adminWipe(u: User ::: Authenticated u && Admin u) -> String =
  "wiped"

api StApi {
  get "/greet"
    auth u: User ::: Authenticated u via cookieAuth
    -> String
  post "/admin/wipe"
    auth u: User ::: Authenticated u && Admin u via adminAuth
    -> String
}

server StServer for StApi {
  greet = greet
  adminWipe = adminWipe
}

%s
|} handler_reqs tail

let valid_tail = {|
fn plainTools(u: User ::: Authenticated u) -> List Tool =
  serverTools StServer u

fn adminTools(u: User ::: Authenticated u && Admin u) -> List Tool =
  serverTools StServer u
|}

(* ── Positive controls ───────────────────────────────────────────────────── *)

let test_valid_compiles () = should_pass (fixture valid_tail)

let test_inclusion_in_emitted_metadata () =
  let out = emit_output (fixture valid_tail) in
  (* Tool metadata rows are (list "name" "description" "schema"): the plain fn
     must carry only greet; the admin fn additionally adminWipe — so the tool
     name appears exactly once as metadata across both fns. *)
  let admin_rows = count_occurrences {|(list "adminWipe"|} out in
  if admin_rows <> 1 then
    failf "expected the adminWipe tool row exactly once (admin fn only), got %d:\n%s"
      admin_rows out;
  let greet_rows = count_occurrences {|(list "greet"|} out in
  if greet_rows <> 2 then
    failf "expected the greet tool row twice (both fns), got %d:\n%s" greet_rows out

let test_letcheck_escalation_included () =
  let tail = {|
check requireAdmin(u: User) -> u: User ::: Authenticated u && Admin u =
  if u.id == "root" then
    ok u ::: Authenticated u && Admin u
  else
    fail 403 "not an admin"

fn escalated(u: User ::: Authenticated u) -> List Tool =
  let admin = check requireAdmin u
  serverTools StServer admin
|} in
  let out = emit_output (fixture tail) in
  let admin_rows = count_occurrences {|(list "adminWipe"|} out in
  if admin_rows <> 1 then
    failf "let-check-escalated user must include the admin endpoint once, got %d:\n%s"
      admin_rows out

(* ── Negative space (all static rejections) ──────────────────────────────── *)

let test_rejects_unauthenticated_user () =
  should_fail "carries no declared proof matching any endpoint"
    (fixture {|
fn bad(u: User) -> List Tool =
  serverTools StServer u
|})

let test_rejects_unknown_server () =
  should_fail "is not a server declared in this module"
    (fixture {|
fn bad(u: User ::: Authenticated u) -> List Tool =
  serverTools NoSuchServer u
|})

let test_rejects_expression_user () =
  should_fail "bare variable"
    (fixture {|
fn bad(u: User ::: Authenticated u) -> List Tool =
  serverTools StServer (User { id: "x" })
|})

let test_rejects_partial_application () =
  should_fail "must be fully applied"
    (fixture {|
fn bad(u: User ::: Authenticated u) -> String =
  let t = serverTools StServer
  "x"
|})

let test_rejects_bare_reference () =
  should_fail "cannot be passed around"
    (fixture {|
fn bad(u: User ::: Authenticated u) -> String =
  let f = serverTools
  "x"
|})

let test_rejects_heterogeneous_auth_types () =
  should_fail "must bind the same user type"
    {|#lang tesl
module StHetero exposing []

import Tesl.Prelude exposing [String, List]
import Tesl.Http exposing [HttpRequest]
import Tesl.Dict exposing [Dict.lookup]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Agent exposing [Tool, serverTools]

record User {
  id: String
}

record Robot {
  serial: String
}

fact Authenticated (u: User)
fact RobotAuth (r: Robot)

auth userAuth(request: HttpRequest) -> u: User ::: Authenticated u =
  case Dict.lookup "user" request.cookies of
    Something userId -> ok (User { id: userId }) ::: Authenticated u
    Nothing -> fail 401 "Missing user cookie"

auth robotAuth(request: HttpRequest) -> r: Robot ::: RobotAuth r =
  case Dict.lookup "robot" request.cookies of
    Something serial -> ok (Robot { serial: serial }) ::: RobotAuth r
    Nothing -> fail 401 "Missing robot cookie"

handler forUsers(u: User ::: Authenticated u) -> String =
  "user"

handler forRobots(r: Robot ::: RobotAuth r) -> String =
  "robot"

api MixedApi {
  get "/users"
    auth u: User ::: Authenticated u via userAuth
    -> String
  get "/robots"
    auth r: Robot ::: RobotAuth r via robotAuth
    -> String
}

server MixedServer for MixedApi {
  forUsers = forUsers
  forRobots = forRobots
}

fn bad(u: User ::: Authenticated u) -> List Tool =
  serverTools MixedServer u
|}

let test_charges_handler_capabilities () =
  should_fail "requiring \\[.*time.*\\]"
    ((fixture
        ~handler_reqs:"\n  requires [time]"
        {|
fn bad(u: User ::: Authenticated u) -> List Tool =
  serverTools StServer u
|})
     (* the fixture's greet handler now requires [time]; make its body use it *)
     |> Str.replace_first
          (Str.regexp_string {|import Tesl.String exposing [String.concat]|})
          {|import Tesl.String exposing [String.concat]
import Tesl.Time exposing [nowMillis, PosixMillis, time]|})

let test_capability_positive_control () =
  should_pass
    ((fixture
        ~handler_reqs:"\n  requires [time]"
        {|
fn good(u: User ::: Authenticated u) -> List Tool
  requires [time] =
  serverTools StServer u
|})
     |> Str.replace_first
          (Str.regexp_string {|import Tesl.String exposing [String.concat]|})
          {|import Tesl.String exposing [String.concat]
import Tesl.Time exposing [nowMillis, PosixMillis, time]|})

let () =
  run "server-tools"
    [
      ( "positive",
        [
          test_case "valid module compiles" `Quick test_valid_compiles;
          test_case "per-site inclusion in emitted metadata" `Quick
            test_inclusion_in_emitted_metadata;
          test_case "let-check escalation includes admin endpoint" `Quick
            test_letcheck_escalation_included;
          test_case "capability positive control" `Quick
            test_capability_positive_control;
        ] );
      ( "negative",
        [
          test_case "unauthenticated user rejected" `Quick
            test_rejects_unauthenticated_user;
          test_case "unknown server rejected" `Quick test_rejects_unknown_server;
          test_case "expression user rejected" `Quick test_rejects_expression_user;
          test_case "partial application rejected" `Quick
            test_rejects_partial_application;
          test_case "bare reference rejected" `Quick test_rejects_bare_reference;
          test_case "heterogeneous auth types rejected" `Quick
            test_rejects_heterogeneous_auth_types;
          test_case "handler capabilities charged at the serverTools site" `Quick
            test_charges_handler_capabilities;
        ] );
    ]
