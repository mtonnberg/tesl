open Alcotest

let check ?message source =
  let errors = Compile.check_source "<security-remediation>" source
    |> List.filter (fun (d : Compile.diagnostic) -> d.severity = "error") in
  match message with
  | None -> if errors <> [] then fail (String.concat "\n" (List.map (fun (d : Compile.diagnostic) -> d.message) errors))
  | Some text ->
    if not (List.exists (fun (d : Compile.diagnostic) ->
      try ignore (Str.search_forward (Str.regexp_string text) d.message 0); true
      with Not_found -> false) errors) then
      fail ("missing rejection: " ^ text ^ "\n" ^ String.concat "\n" (List.map (fun (d : Compile.diagnostic) -> d.message) errors))

let inline via = Printf.sprintf {|module InlineProof exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
fact Owns(id: String)
fact Other(id: String)
check owner(id: String) -> id: String ::: Owns id = fail 400 "denied"
check other(id: String) -> id: String ::: Other id = fail 400 "denied"
fn passthrough(id: String) -> String = id
handler get sensitive(id: String ::: Owns id) -> String = id
api Vulnerable { get "/sensitive/:id" capture id: String ::: Owns id using stringCodec %s -> String }
server S for Vulnerable { sensitive }
|} via

let folded kind proof dead = Printf.sprintf {|module FoldedProof exposing []
import Tesl.Prelude exposing [String]
import Tesl.Database exposing [Database, Memory]
import Tesl.Queue exposing [Queue, Job, FromQueue, FromDeadQueue]
import Tesl.Maybe exposing [Maybe(..)]
database Db = Database { schema: "x" entities: [] backend: Memory }
record Payload { msg: String }
fact Authorized(p: Payload)
%s sensitive(p: Payload %s) -> String = p.msg
deadWorker dead(p: Payload) -> String = p.msg
queue Q = Queue { database: Db jobs: [Job Payload sensitive %s] }
|} kind proof dead

let tools user_type = Printf.sprintf {|module ToolProof exposing []
import Tesl.Prelude exposing [String, List]
import Tesl.Http exposing [HttpRequest]
import Tesl.Agent exposing [Tool, serverTools]
record Admin { id: String }
record Customer { id: String }
type Principal a = MkPrincipal value: a
fact Authenticated(u: a)
auth authenticate(request: HttpRequest) -> u: Principal Admin ::: Authenticated u = fail 401 "denied"
handler get sensitive(u: Principal Admin ::: Authenticated u) -> String = "admin"
api A { get "/admin" auth u: Principal Admin ::: Authenticated u via authenticate -> String }
server S for A { sensitive }
fn expose(u: Principal %s ::: Authenticated u) -> List Tool = serverTools S u
|} user_type

let replace old replacement source =
  Str.global_replace (Str.regexp_string old) replacement source

let heterogeneous_tools () =
  tools "Admin"
  |> replace "api A {" "auth customer(request: HttpRequest) -> u: Principal Customer ::: Authenticated u = fail 401 \"denied\"\nhandler get other(u: Principal Customer ::: Authenticated u) -> String = \"customer\"\napi A { get \"/customer\" auth u: Principal Customer ::: Authenticated u via customer -> String\n"
  |> replace "server S for A { sensitive }" "server S for A { other, sensitive }"

let () = run "security-remediation" [
  "inline captures", [
    test_case "missing check" `Quick (fun () -> check ~message:"has no `via` validation" (inline ""));
    test_case "ordinary function" `Quick (fun () -> check ~message:"not a check/auth" (inline "via passthrough"));
    test_case "wrong proof" `Quick (fun () -> check ~message:"not established" (inline "via other"));
    test_case "valid check" `Quick (fun () -> check (inline "via owner"));
  ];
  "folded queue", [
    test_case "HTTP handler" `Quick (fun () -> check ~message:"not declared as a `worker`" (folded "handler post" "::: Authorized p" "Nothing"));
    test_case "ordinary function" `Quick (fun () -> check ~message:"not declared as a `worker`" (folded "fn" "" "Nothing"));
    test_case "extra domain proof" `Quick (fun () -> check ~message:"proofs not supplied" (folded "worker" "::: Authorized p" "Nothing"));
    test_case "wrong provenance" `Quick (fun () -> check ~message:"proofs not supplied" (folded "worker" "::: FromDeadQueue (Id == jobId) p" "Nothing"));
    test_case "provenance expression" `Quick (fun () -> check ~message:"proofs not supplied" (folded "worker" "::: FromQueue (Id == jobId + 1) p" "Nothing"));
    test_case "malformed dead slot" `Quick (fun () -> check ~message:"Nothing or" (folded "worker" "" "sensitive"));
    test_case "wrong dead worker" `Quick (fun () -> check ~message:"not declared as a `deadWorker`" (folded "worker" "" "(Something sensitive)"));
    test_case "valid plain workers" `Quick (fun () -> check (folded "worker" "" "(Something dead)"));
    test_case "valid provenance" `Quick (fun () -> check (folded "worker" "::: FromQueue (Id == jobId) p" "Nothing"));
  ];
  "applied principal", [
    test_case "different principal" `Quick (fun () -> check ~message:"type mismatch" (tools "Customer"));
    test_case "humanActions different principal" `Quick (fun () -> check ~message:"type mismatch" (tools "Customer" |> replace "serverTools" "humanActions"));
    test_case "humanActions matching principal" `Quick (fun () -> check (tools "Admin" |> replace "serverTools" "humanActions"));
    test_case "heterogeneous principal types" `Quick (fun () -> check ~message:"same user type" (heterogeneous_tools ()));
    test_case "humanActions heterogeneous principal types" `Quick (fun () -> check ~message:"same user type" (heterogeneous_tools () |> replace "serverTools" "humanActions"));
    test_case "matching principal" `Quick (fun () -> check (tools "Admin"));
  ];
]
