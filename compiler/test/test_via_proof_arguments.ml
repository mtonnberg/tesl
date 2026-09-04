(** `via` coverage compares proof ARGUMENTS, not just predicate names (whitebox campaign,
    2026-09-02). A check establishing `CanAccess u "guest"` used to satisfy a codec field,
    a route capture and a route auth declared `CanAccess user "admin"`; the boundary then
    credited the declared proof to the value and a guest-validated request reached an
    admin-gated handler. Three refusals and three exact-argument controls. *)

open Alcotest

let compiler =
  match Sys.getenv_opt "TESL_OCAML_COMPILER" with
  | Some p when Sys.file_exists p -> p
  | _ ->
    (match Sys.getenv_opt "TESL_BIN" with
     | Some v when Filename.basename v = "main.exe" && Sys.file_exists v -> v
     | _ ->
       (* Under `dune test` the executable runs from `_build/default/test`, so the compiler
          is `../bin/main.exe`; ci.sh deliberately UNSETS the env variables so the suite
          exercises exactly that path. *)
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
  ((match status with Unix.WEXITED c -> c | _ -> 255), out)

let check name src =
  let dir = Filename.temp_dir "tesl-via" "" in
  let path = Filename.concat dir (name ^ ".tesl") in
  let oc = open_out path in output_string oc src; close_out oc;
  Fun.protect
    ~finally:(fun () -> (try Sys.remove path with _ -> ()); (try Unix.rmdir dir with _ -> ()))
    (fun () -> run_command (Printf.sprintf "%s --check %s 2>&1" (Filename.quote compiler) (Filename.quote path)))

let should_fail name pat src =
  let code, out = check name src in
  if code = 0 then failf "expected a static failure matching %S, but compiled cleanly:\n%s" pat out;
  let re = Str.regexp_case_fold pat in
  (try ignore (Str.search_forward re out 0)
   with Not_found -> failf "expected a failure matching %S, got:\n%s" pat out)

let should_pass name src =
  let code, out = check name src in
  if code <> 0 then failf "expected a clean compile, got (exit %d):\n%s" code out

let codec role = Printf.sprintf {|module CodecVia exposing [AdminServer]
import Tesl.Prelude exposing [Bool(..), Int, String]
import Tesl.Json exposing [stringCodec]
import Tesl.String exposing [String.length]

fact CanAccess (u: String) (role: String)

check checkRole(u: String) -> u: String ::: CanAccess u "%s" =
  if String.length u >= 0 then
    ok u ::: CanAccess u "%s"
  else
    fail 400 "impossible"

record AdminReq {
  user: String ::: CanAccess user "admin"
}
codec AdminReq {
  toJson_forbidden
  fromJson [
    {
      user <- "user" with_codec stringCodec via checkRole
    }
  ]
}

fn adminOnly(u: String ::: CanAccess u "admin") -> String =
  "SECRET for ${u}"

handler post doAdmin(body: AdminReq) -> String =
  adminOnly body.user

api AdminApi {
  post "/admin"
    body body: AdminReq
    -> String
}

server AdminServer for AdminApi {
  doAdmin
}
|} role role

let capture role = Printf.sprintf {|module CaptureVia exposing [RoleServer]
import Tesl.Prelude exposing [Bool(..), Int, String]
import Tesl.Json exposing [stringCodec]
import Tesl.String exposing [String.length]

fact CanAccess (u: String) (role: String)

check checkRole(who: String) -> who: String ::: CanAccess who "%s" =
  if String.length who >= 0 then
    ok who ::: CanAccess who "%s"
  else
    fail 400 "impossible"

capturer roleCap: String ::: CanAccess who "admin" using stringCodec via checkRole

fn adminOnly(u: String ::: CanAccess u "admin") -> String =
  "SECRET for ${u}"

handler get doAdmin(who: String ::: CanAccess who "admin") -> String =
  adminOnly who

api RoleApi {
  get "/x/:who"
    capture who: String ::: CanAccess who "admin" via roleCap
    -> String
}

server RoleServer for RoleApi {
  doAdmin
}
|} role role

let auth role = Printf.sprintf {|module AuthVia exposing [ASrv]
import Tesl.Prelude exposing [Bool(..), Int, String]
import Tesl.Http exposing [HttpRequest]
import Tesl.Dict exposing [Dict.lookup]
import Tesl.Maybe exposing [Maybe(..)]

fact Role (u: String) (r: String)

auth roleAuth(request: HttpRequest) -> u: String ::: Role u "%s" =
  case Dict.lookup "user" request.cookies of
    Nothing -> fail 401 "no user"
    Something u -> ok u ::: Role u "%s"

fn adminOnly(u: String ::: Role u "admin") -> String =
  "SECRET for ${u}"

handler get whoami(u: String ::: Role u "admin") -> String =
  adminOnly u

api AApi {
  get "/me"
    auth u: String ::: Role u "admin" via roleAuth
    -> String
}

server ASrv for AApi {
  whoami
}
|} role role

let () =
  run "via-proof-arguments"
    [
      ( "argument mismatch refused",
        [ test_case "codec field" `Quick (fun () ->
            should_fail "CodecVia" "requires proof `CanAccess <value> \"admin\"` that is not established"
              (codec "guest"));
          test_case "route capture" `Quick (fun () ->
            should_fail "CaptureVia" "declares proof `CanAccess <value> \"admin\"` that is not established by `via checkRole`"
              (capture "guest"));
          test_case "route auth" `Quick (fun () ->
            should_fail "AuthVia" "declares auth proof `Role <value> \"admin\"` that is not established by `via roleAuth`"
              (auth "guest")) ] );
      ( "exact arguments accepted",
        [ test_case "codec field" `Quick (fun () -> should_pass "CodecVia" (codec "admin"));
          test_case "route capture" `Quick (fun () -> should_pass "CaptureVia" (capture "admin"));
          test_case "route auth" `Quick (fun () -> should_pass "AuthVia" (auth "admin")) ] );
    ]
