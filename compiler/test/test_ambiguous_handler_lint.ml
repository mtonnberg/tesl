(** W095 — two api endpoints share one handler signature.

    Issue #65: server blocks bind handlers to endpoints by POSITION, never by
    name. Two endpoints whose handler signature (positional param types, return
    type) is identical are exactly the case where reordering the handlers in a
    server block compiles clean and silently misroutes — nothing about the
    types differs, so nothing catches it. This lint reports that ambiguity
    against the `api` block itself (not a `server`), since it is a property of
    the endpoint shapes and holds regardless of whether a server exists yet. *)

open Alcotest

let compiler =
  match Sys.getenv_opt "TESL_OCAML_COMPILER" with
  | Some p when Sys.file_exists p -> p
  | _ ->
    (match Sys.getenv_opt "TESL_BIN" with
     | Some v when Filename.basename v = "main.exe" && Sys.file_exists v -> v
     | _ ->
       let dir = Filename.dirname Sys.argv.(0) in
       let c1 = Filename.concat (Filename.dirname dir) "bin/main.exe" in
       let c2 = Filename.concat dir "../bin/main.exe" in
       if Sys.file_exists c1 then c1 else if Sys.file_exists c2 then c2 else "tesl")

let failf fmt = Printf.ksprintf failwith fmt

let run_cc args =
  let q = Filename.quote compiler :: List.map Filename.quote args in
  let ic = Unix.open_process_in (String.concat " " q ^ " 2>&1") in
  let out = In_channel.input_all ic in
  ignore (Unix.close_process_in ic);
  out

let with_source src f =
  let dir = Filename.temp_dir "tesl-w095" "" in
  let path = Filename.concat dir "Amb.tesl" in
  Out_channel.with_open_text path (fun oc -> Out_channel.output_string oc src);
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let contains hay needle =
  try ignore (Str.search_forward (Str.regexp_string needle) hay 0); true
  with Not_found -> false

let count_w095 out =
  let re = Str.regexp "^warning\\[W095\\]" in
  String.split_on_char '\n' out
  |> List.filter (fun line ->
         try ignore (Str.search_forward re line 0); true with Not_found -> false)
  |> List.length

let lint src = with_source src (fun p -> run_cc [ "--lint"; p ])

let expect label src ~w095 =
  let out = lint src in
  let got = count_w095 out in
  if got <> w095 then
    failf "%s: expected %d W095, got %d:\n%s" label w095 got out

(* ── Reports ──────────────────────────────────────────────────────────────── *)

let test_two_captures_same_type () =
  let src = {|module Amb exposing [S]
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
capture idCapture: id: String using stringCodec

handler get getProject(projectId: String) -> String requires [] = projectId
handler get getOrg(orgId: String) -> String requires [] = orgId

api TestApi {
  get "/projects/:projectId"
    capture projectId: String via idCapture
    -> String
  get "/orgs/:orgId"
    capture orgId: String via idCapture
    -> String
}

server S for TestApi {
  getProject
  getOrg
}
|} in
  expect "two String-capture endpoints, same return" src ~w095:1;
  let out = lint src in
  if not (contains out "share one handler signature") then
    failf "should name the collision:\n%s" out;
  if not (contains out "type ProjectId = Int") then
    failf "should suggest a newtype:\n%s" out

let test_three_way_collision_is_one_group () =
  let src = {|module Amb exposing [S]
import Tesl.Prelude exposing [String]

handler post a(x: String) -> String requires [] = x
handler post b(x: String) -> String requires [] = x
handler post c(x: String) -> String requires [] = x

api TestApi {
  post "/a" body x: String -> String
  post "/b" body x: String -> String
  post "/c" body x: String -> String
}

server S for TestApi {
  a
  b
  c
}
|} in
  (* One finding per collision GROUP, not per pair — pairwise would be C(3,2)=3
     here and six for four routes, which is more noise than signal. *)
  expect "three endpoints sharing one signature" src ~w095:1;
  let out = lint src in
  (* the single finding must name every member of the group *)
  List.iter (fun p ->
    if not (contains out p) then failf "finding should name %s:\n%s" p out)
    [ "POST /a"; "POST /b"; "POST /c" ]

let test_different_return_types_silent () =
  let src = {|module Amb exposing [S]
import Tesl.Prelude exposing [String, Int]

handler post getName(x: String) -> String requires [] = x
handler post getCount(x: String) -> Int requires [] = 0

api TestApi {
  post "/name" body x: String -> String
  post "/count" body x: String -> Int
}

server S for TestApi {
  getName
  getCount
}
|} in
  expect "same param type, different return type" src ~w095:0

let test_param_less_endpoints_silent () =
  (* Nothing to newtype on a param-less endpoint — health-check-shaped routes
     collide on `() -> X` constantly and would otherwise be pure noise. *)
  let src = {|module Amb exposing [S]
import Tesl.Prelude exposing [String]

handler get health() -> String requires [] = "ok"
handler get version() -> String requires [] = "1.0"

api TestApi {
  get "/health" -> String
  get "/version" -> String
}

server S for TestApi {
  health
  version
}
|} in
  expect "two param-less endpoints" src ~w095:0

let test_distinct_newtypes_silent () =
  let src = {|module Amb exposing [S]
import Tesl.Prelude exposing [String]

type ProjectId = String
type OrgId = String

handler post getProject(projectId: ProjectId) -> String requires [] = "p"
handler post getOrg(orgId: OrgId) -> String requires [] = "o"

api TestApi {
  post "/projects" body projectId: ProjectId -> String
  post "/orgs" body orgId: OrgId -> String
}

server S for TestApi {
  getProject
  getOrg
}
|} in
  expect "distinct newtypes silence the collision" src ~w095:0

let test_differing_proofs_silent () =
  (* The false-positive class this key change fixed.  Two endpoints identical in
     type but differing in PROOF are not interchangeable: the handler's parameter
     carries the obligation and the auth-wiring check rejects a mismatch, so
     warning here would claim "nothing catches it" when something does. *)
  let src = {|module Amb exposing [S]
import Tesl.Prelude exposing [String, Bool(..)]

record User { id: String }
fact Authenticated (user: User)
fact Admin (user: User)

auth plainAuth(r: String) -> u: User ::: Authenticated u =
  fail 401 "no"
auth adminAuth(r: String) -> u: User ::: Authenticated u && Admin u =
  fail 401 "no"

handler get greet(u: User ::: Authenticated u) -> String requires [] = "hi"
handler get wipe(u: User ::: Authenticated u && Admin u) -> String requires [] = "wiped"

api TestApi {
  get "/greet"
    auth u: User ::: Authenticated u via plainAuth
    -> String
  get "/wipe"
    auth u: User ::: Authenticated u && Admin u via adminAuth
    -> String
}

server S for TestApi {
  greet
  wipe
}
|} in
  expect "same type, different proof obligation" src ~w095:0

let test_differing_methods_silent () =
  (* A handler declares the method(s) it serves and the server-block cross-check
     rejects a handler landing in a slot whose method it did not declare — so
     endpoints differing in method are structurally distinguishable. *)
  let src = {|module Amb exposing [S]
import Tesl.Prelude exposing [String]

handler get fetch(x: String) -> String requires [] = x
handler post store(x: String) -> String requires [] = x

api TestApi {
  get "/thing" body x: String -> String
  post "/thing" body x: String -> String
}

server S for TestApi {
  fetch
  store
}
|} in
  expect "same signature, different method" src ~w095:0

let test_differing_return_proofs_silent () =
  (* Response proofs are cross-checked too (a handler must establish everything
     its endpoint advertises), so two endpoints whose returns differ only in
     proof are distinguishable and must not be warned about. *)
  let src = {|module Amb exposing [S]
import Tesl.Prelude exposing [String]

fact Alpha (v: String)
fact Beta (v: String)

check mkAlpha(v: String) -> v: String ::: Alpha v =
  ok v ::: Alpha v

check mkBeta(v: String) -> v: String ::: Beta v =
  ok v ::: Beta v

handler get ha(x: String) -> String ? Alpha requires [] =
  mkAlpha x

handler get hb(x: String) -> String ? Beta requires [] =
  mkBeta x

api TestApi {
  get "/a" body x: String -> String ? Alpha
  get "/b" body x: String -> String ? Beta
}

server S for TestApi {
  ha
  hb
}
|} in
  expect "same value type, different response proof" src ~w095:0

(* ── W096: route already carries the App's mountPath prefix ────────────────── *)

let count_w096 out =
  let re = Str.regexp "^warning\\[W096\\]" in
  String.split_on_char '\n' out
  |> List.filter (fun line ->
         try ignore (Str.search_forward re line 0); true with Not_found -> false)
  |> List.length

let mount_src routes = Printf.sprintf {|module Amb exposing []
import Tesl.Prelude exposing [String]
import Tesl.Database exposing [Database, Memory]
import Tesl.App exposing [App]

database Db = Database { entities: [] backend: Memory }

handler get one() -> String requires [] = "1"

api A {
%s
}

server S for A {
  one
}

main() -> App requires [] =
  App {
    database: Db
    api: S
    port: 8080
    mountPath: "/api"
  }
|} routes

let test_double_prefix_reported () =
  let out = lint (mount_src {|  get "/api/widgets" -> String|}) in
  if count_w096 out <> 1 then
    failf "expected 1 W096, got %d:\n%s" (count_w096 out) out;
  (* The message must show the served path and the corrected route string. *)
  if not (contains out "/api/api/widgets") then
    failf "should show the doubly-prefixed served path:\n%s" out;
  if not (contains out "\"/widgets\"") then
    failf "should show the corrected route string:\n%s" out

let test_prefix_free_route_silent () =
  let out = lint (mount_src {|  get "/widgets" -> String|}) in
  if count_w096 out <> 0 then failf "a prefix-free route must be silent:\n%s" out

let test_segment_aware_no_false_positive () =
  (* `mountPath: "/api"` must not fire on a route beginning `/apiary`. *)
  let out = lint (mount_src {|  get "/apiary/bees" -> String|}) in
  if count_w096 out <> 0 then
    failf "matching must be segment-aware, not string-prefix:\n%s" out

let test_no_mount_path_silent () =
  let src = {|module Amb exposing []
import Tesl.Prelude exposing [String]
import Tesl.Database exposing [Database, Memory]
import Tesl.App exposing [App]

database Db = Database { entities: [] backend: Memory }

handler get one() -> String requires [] = "1"

api A {
  get "/api/widgets" -> String
}

server S for A {
  one
}

main() -> App requires [] =
  App {
    database: Db
    api: S
    port: 8080
  }
|} in
  let out = lint src in
  if count_w096 out <> 0 then
    failf "with no mountPath declared, an /api/... route is just a route:\n%s" out

let () =
  run "W095 ambiguous handler signature" [
    "reports", [
      test_case "two captures, same type"        `Quick test_two_captures_same_type;
      test_case "three-way collision is one group" `Quick test_three_way_collision_is_one_group;
    ];
    "silences", [
      test_case "different return types"   `Quick test_different_return_types_silent;
      test_case "param-less endpoints"     `Quick test_param_less_endpoints_silent;
      test_case "distinct newtypes"        `Quick test_distinct_newtypes_silent;
      test_case "differing proofs"         `Quick test_differing_proofs_silent;
      test_case "differing methods"        `Quick test_differing_methods_silent;
      test_case "differing return proofs"  `Quick test_differing_return_proofs_silent;
    ];
    "W096 mountPath double prefix", [
      test_case "double prefix reported"     `Quick test_double_prefix_reported;
      test_case "prefix-free route silent"   `Quick test_prefix_free_route_silent;
      test_case "segment-aware (/apiary)"    `Quick test_segment_aware_no_false_positive;
      test_case "no mountPath declared"      `Quick test_no_mount_path_silent;
    ];
  ]
