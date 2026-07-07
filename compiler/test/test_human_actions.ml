(** humanActions — endpoints the agent may NOT perform, surfaced to the human.

    `humanActions MyServer user : List Tool` is the COMPLEMENT of `serverTools`
    at the same call site: one INERT tool per endpoint whose auth predicates the
    user variable's declared proof does NOT cover.  These tests pin:

    - the complement is exactly `endpoints \ serverTools-included` (a plain user
      surfaces the admin-gated endpoint; an admin user surfaces nothing);
    - the lowering is INERT — it passes only the server NAME (a string), never
      the user or the server value, so the runtime has no path to the handler;
    - serverTools (included) and humanActions (excluded) are disjoint;
    - humanActions charges NO capability (the opposite of serverTools): the
      agent never runs these endpoints, so their `requires` is not charged;
    - the same fail-closed static surface as serverTools (bare server ref, bare
      user variable, full application only).

    Harness modeled on compiler/test/test_server_tools.ml. *)

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

let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-humanactions" "" in
  let path = Filename.concat dir "human-actions.tesl" in
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

let contains needle haystack = count_occurrences needle haystack > 0

(* ── Fixture ──────────────────────────────────────────────────────────────
   greet is Authenticated-only; adminWipe is Authenticated && Admin.  [admin_reqs]
   lets a test give the admin handler a capability (to prove humanActions does
   NOT charge it).  [imports] appends extra import lines. *)
let fixture ?(admin_reqs = "") ?(imports = "") ?(body = "\"wiped\"") tail =
  Printf.sprintf {|#lang tesl
module HumanActions exposing []

import Tesl.Prelude exposing [String, Bool, List]
import Tesl.Http exposing [HttpRequest]
import Tesl.Dict exposing [Dict.lookup]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.String exposing [String.concat]
import Tesl.List exposing [List.append]
import Tesl.Agent exposing [Tool, serverTools, humanActions]%s

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
handler greet(u: User ::: Authenticated u) -> String =
  String.concat "hello " u.id

# Wipe everything. Admin only.
handler adminWipe(u: User ::: Authenticated u && Admin u) -> String%s =
  %s

api HaApi {
  get "/greet"
    auth u: User ::: Authenticated u via cookieAuth
    -> String
  post "/admin/wipe"
    auth u: User ::: Authenticated u && Admin u via adminAuth
    -> String
}

server HaServer for HaApi {
  greet = greet
  adminWipe = adminWipe
}

%s
|} imports admin_reqs body tail

let valid_tail = {|
fn plainHuman(u: User ::: Authenticated u) -> List Tool =
  humanActions HaServer u

fn adminHuman(u: User ::: Authenticated u && Admin u) -> List Tool =
  humanActions HaServer u
|}

(* ── Positive controls ───────────────────────────────────────────────────── *)

let test_valid_compiles () = should_pass (fixture valid_tail)

let test_complement_in_emitted_metadata () =
  let out = emit_output (fixture valid_tail) in
  (* plainHuman's complement is exactly adminWipe (the endpoint the plain user's
     proof does NOT cover); adminHuman's complement is empty.  So the adminWipe
     human-action row appears exactly once, and greet — always covered, never a
     human action — appears zero times. *)
  let admin_rows = count_occurrences {|(list "adminWipe"|} out in
  if admin_rows <> 1 then
    failf "expected the adminWipe human-action row exactly once (plain fn only), got %d:\n%s"
      admin_rows out;
  let greet_rows = count_occurrences {|(list "greet"|} out in
  if greet_rows <> 0 then
    failf "greet is always covered and must never be a human action, got %d rows:\n%s"
      greet_rows out;
  (* Two humanActions call sites both lower (adminHuman emits an empty list). *)
  let sites = count_occurrences "__tht_human-actions" out in
  if sites <> 2 then
    failf "expected 2 humanActions lowering sites, got %d:\n%s" sites out

let test_lowering_is_inert () =
  let out = emit_output (fixture valid_tail) in
  (* Inert: the lowering passes the server NAME as a string literal, never the
     user value or the server value.  `(__tht_human-actions "HaServer" (list …)`
     is the tell — a quoted server name and no user argument. *)
  if not (contains {|(__tht_human-actions "HaServer" (list|} out) then
    failf "expected inert lowering `(__tht_human-actions \"HaServer\" (list …`:\n%s" out;
  (* It must NOT reuse the executing serverTools runtime entry. *)
  if contains "__tst_server-tools" out then
    failf "humanActions must not lower to the executing serverTools runtime:\n%s" out

let test_disjoint_from_server_tools () =
  (* One fn exposes serverTools (agent CAN do) and humanActions (agent CANNOT) to
     the same plain user: greet goes to serverTools, adminWipe to humanActions,
     with no overlap. *)
  let tail = {|
fn both(u: User ::: Authenticated u) -> List Tool =
  List.append (serverTools HaServer u) (humanActions HaServer u)
|} in
  let out = emit_output (fixture tail) in
  (* greet is an executing serverTools row; adminWipe is an inert humanActions
     row.  Neither crosses over. *)
  if count_occurrences {|(list "greet"|} out <> 1 then
    failf "greet must be exactly one serverTools row:\n%s" out;
  if count_occurrences {|(list "adminWipe"|} out <> 1 then
    failf "adminWipe must be exactly one humanActions row:\n%s" out;
  if not (contains "__tst_server-tools" out) then
    failf "expected a serverTools lowering:\n%s" out;
  if not (contains "__tht_human-actions" out) then
    failf "expected a humanActions lowering:\n%s" out

(* The capability OPPOSITE of serverTools: humanActions charges NOTHING, even
   when the surfaced (excluded) endpoint's handler `requires` a capability — the
   inert tool never runs it. *)
let test_charges_no_capabilities () =
  should_pass
    (fixture
       ~imports:"\nimport Tesl.Time exposing [nowMillis, PosixMillis, time]"
       ~admin_reqs:"\n  requires [time]"
       ~body:"let _t = nowMillis\n  \"wiped\""
       {|
fn held(u: User ::: Authenticated u) -> List Tool =
  humanActions HaServer u
|})

(* ── Negative space (all static rejections, mirroring serverTools) ─────────── *)

let test_rejects_unknown_server () =
  should_fail "is not a server declared in this module"
    (fixture {|
fn bad(u: User ::: Authenticated u) -> List Tool =
  humanActions NoSuchServer u
|})

let test_rejects_expression_user () =
  should_fail "bare variable"
    (fixture {|
fn bad(u: User ::: Authenticated u) -> List Tool =
  humanActions HaServer (User { id: "x" })
|})

let test_rejects_partial_application () =
  should_fail "must be fully applied"
    (fixture {|
fn bad(u: User ::: Authenticated u) -> String =
  let t = humanActions HaServer
  "x"
|})

let test_rejects_bare_reference () =
  should_fail "cannot be passed around"
    (fixture {|
fn bad(u: User ::: Authenticated u) -> String =
  let f = humanActions
  "x"
|})

let () =
  run "human-actions"
    [
      ( "positive",
        [
          test_case "valid module compiles" `Quick test_valid_compiles;
          test_case "complement (excluded set) in emitted metadata" `Quick
            test_complement_in_emitted_metadata;
          test_case "lowering is inert (server name only, no user)" `Quick
            test_lowering_is_inert;
          test_case "disjoint from serverTools at the same site" `Quick
            test_disjoint_from_server_tools;
          test_case "charges no capabilities (opposite of serverTools)" `Quick
            test_charges_no_capabilities;
        ] );
      ( "negative",
        [
          test_case "unknown server rejected" `Quick test_rejects_unknown_server;
          test_case "expression user rejected" `Quick test_rejects_expression_user;
          test_case "partial application rejected" `Quick
            test_rejects_partial_application;
          test_case "bare reference rejected" `Quick test_rejects_bare_reference;
        ] );
    ]
