(** Antagonistic regression tests for Critical Review 66: API declaration validation.

    Previously the API parser accepted many structurally-invalid declarations and
    silently compiled them to broken Racket — clauses placed after the `->` return
    type were ignored, missing `->` defaulted to Unit with no error, auth without
    a proof annotation compiled to code that couldn't enforce identity, empty paths
    and paths without leading slashes were not flagged, captures referencing
    non-existent path parameters were silently accepted, and duplicate endpoints
    within the same api block were not detected.

    Test groups:
      AR — Arrow / return type ordering
      RT — Return type presence
      PH — Path format
      AU — Auth clause integrity
      CA — Capture clause integrity
      DU — Duplicate endpoints
      OK — Valid syntax (regression: must still compile) *)

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
  let dir = Filename.temp_dir "tesl-r66" "" in
  let name =
    let re = Str.regexp "module[ \\t\\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
    try
      ignore (Str.search_forward re content 0);
      let mname = Str.matched_group 1 content in
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

let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected success, got:\n%s" out)

let should_fail pat src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected failure matching %S, but succeeded" pat;
    let re = Str.regexp_case_fold pat in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pat out)

(* ── Shared prelude ─────────────────────────────────────────────────────── *)


(* ── R66_AR — Arrow / clause ordering ───────────────────────────────────── *)

let test_R66_AR01_auth_after_arrow_rejected () =
  (* Auth clause placed AFTER `->` is silently eaten; now caught *)
  should_fail "clauses.*before.*return\\|after.*return" {|
#lang tesl
module R66Ar01 exposing []
import Tesl.Prelude exposing [String]
fact AuthedUser (u: String)
auth authFun(u: String) -> u: String ::: AuthedUser u = ok u ::: AuthedUser u
api R66Ar01 {
  get "/health"
    -> String
    auth requestedUser : String ::: AuthedUser requestedUser via authFun
}
|}

let test_R66_AR02_body_after_arrow_rejected () =
  should_fail "clauses.*before.*return\\|after.*return" {|
#lang tesl
module R66Ar02 exposing []
import Tesl.Prelude exposing [String]
api R66Ar02 {
  post "/items"
    -> String
    body req: String
}
|}

let test_R66_AR03_double_arrow_rejected () =
  (* Two `->` in same endpoint — second one is a clause after return *)
  should_fail "clauses.*before.*return\\|after.*return" {|
#lang tesl
module R66Ar03 exposing []
import Tesl.Prelude exposing [String]
api R66Ar03 {
  get "/health"
    -> String
    -> String
}
|}

let test_R66_AR04_handler_name_after_arrow_rejected () =
  (* User confuses `-> handlerFn` with connecting a handler to an endpoint *)
  should_fail "clauses.*before.*return\\|after.*return" {|
#lang tesl
module R66Ar04 exposing []
import Tesl.Prelude exposing [String]
api R66Ar04 {
  get "/items"
    -> String
    -> myHandlerFunction
}
|}

let test_R66_AR05_capture_after_arrow_rejected () =
  should_fail "clauses.*before.*return\\|after.*return" {|
#lang tesl
module R66Ar05 exposing []
import Tesl.Prelude exposing [String]
api R66Ar05 {
  get "/items/:id"
    -> String
    capture id : String via stringCodec
}
|}

let test_R66_AR06_response_after_arrow_rejected () =
  should_fail "clauses.*before.*return\\|after.*return" {|
#lang tesl
module R66Ar06 exposing []
import Tesl.Prelude exposing [String]
api R66Ar06 {
  get "/items"
    -> String
    response WireString via enc
}
|}

let test_R66_AR07_auth_before_arrow_accepted () =
  (* Valid: auth BEFORE `->` — the correct ordering *)
  should_pass {|
#lang tesl
module R66Ar07 exposing []
import Tesl.Prelude exposing [String]
fact AuthedUser (u: String)
auth authFun(u: String) -> u: String ::: AuthedUser u = ok u ::: AuthedUser u
api R66Ar07 {
  get "/health"
    auth requestedUser : String ::: AuthedUser requestedUser via authFun
    -> String
}
|}

let test_R66_AR08_body_then_arrow_then_auth_rejected () =
  (* body before arrow is fine, but then auth AFTER arrow is wrong *)
  should_fail "clauses.*before.*return\\|after.*return" {|
#lang tesl
module R66Ar08 exposing []
import Tesl.Prelude exposing [String]
fact AuthedUser (u: String)
auth authFun(u: String) -> u: String ::: AuthedUser u = ok u ::: AuthedUser u
api R66Ar08 {
  post "/items"
    body req: String
    -> String
    auth requestedUser : String ::: AuthedUser requestedUser via authFun
}
|}

(* ── R66_RT — Return type presence ──────────────────────────────────────── *)

let test_R66_RT01_missing_return_type_rejected () =
  should_fail "missing return type\\|explicit.*TypeName\\|->.*TypeName" {|
#lang tesl
module R66Rt01 exposing []
import Tesl.Prelude exposing [String]
api R66Rt01 {
  get "/health"
}
|}

let test_R66_RT02_auth_only_no_return_rejected () =
  should_fail "missing return type\\|explicit.*TypeName" {|
#lang tesl
module R66Rt02 exposing []
import Tesl.Prelude exposing [String]
fact AuthedUser (u: String)
auth authFun(u: String) -> u: String ::: AuthedUser u = ok u ::: AuthedUser u
api R66Rt02 {
  get "/whoami"
    auth user : String ::: AuthedUser user via authFun
}
|}

let test_R66_RT03_multiple_endpoints_one_missing_return_rejected () =
  should_fail "missing return type\\|explicit.*TypeName" {|
#lang tesl
module R66Rt03 exposing []
import Tesl.Prelude exposing [String]
api R66Rt03 {
  get "/a"
    -> String
  get "/b"
}
|}

let test_R66_RT04_sse_without_return_accepted () =
  (* SSE endpoints are event streams — no return type is required *)
  should_pass {|
#lang tesl
module R66Rt04 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
database EventDb { backend postgres schema "e" entities []
  postgres { database "d" user "u" password "" host "localhost" port 5432 socket "" } }
type Ev = EvA msg: String
channel Events(userId: String) { database EventDb payload Ev }
fn parseId(s: String) -> String = s
capture userCapture: String using stringCodec via parseId
api R66Rt04 {
  sse "/events/:userId"
    capture userId: String via userCapture
    subscribe Events(userId)
}
|}

let test_R66_RT05_explicit_return_accepted () =
  should_pass {|
#lang tesl
module R66Rt05 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
capture idCapture: id: String using stringCodec
api R66Rt05 {
  get "/health"
    -> String
  post "/items"
    -> String
  put "/items/:id"
    capture id : String via idCapture
    -> String
}
|}

let test_R66_RT06_undefined_return_type_caught () =
  (* Return type referencing an unknown type should be a compile error *)
  should_fail "unknown type\\|not in scope\\|UnknownResponseType" {|
#lang tesl
module R66Rt06 exposing []
import Tesl.Prelude exposing [String]
api R66Rt06 {
  get "/items"
    -> UnknownResponseType
}
|}

(* ── R66_PH — Path format ────────────────────────────────────────────────── *)

let test_R66_PH01_empty_path_rejected () =
  should_fail "empty.*path\\|path.*empty\\|must not be empty" {|
#lang tesl
module R66Ph01 exposing []
import Tesl.Prelude exposing [String]
api R66Ph01 {
  get ""
    -> String
}
|}

let test_R66_PH02_path_without_slash_rejected () =
  should_fail "must start with.*`/`\\|path.*start.*/" {|
#lang tesl
module R66Ph02 exposing []
import Tesl.Prelude exposing [String]
api R66Ph02 {
  get "health"
    -> String
}
|}

let test_R66_PH03_path_without_slash_all_methods_rejected () =
  should_fail "must start with.*`/`\\|path.*start.*/" {|
#lang tesl
module R66Ph03 exposing []
import Tesl.Prelude exposing [String]
api R66Ph03 {
  post "items"
    -> String
}
|}

let test_R66_PH04_nested_path_without_slash_rejected () =
  should_fail "must start with.*`/`\\|path.*start.*/" {|
#lang tesl
module R66Ph04 exposing []
import Tesl.Prelude exposing [String]
api R66Ph04 {
  get "api/v1/health"
    -> String
}
|}

let test_R66_PH05_valid_paths_accepted () =
  should_pass {|
#lang tesl
module R66Ph05 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
capture idCapture: id: String using stringCodec
api R66Ph05 {
  get "/"
    -> String
  get "/health"
    -> String
  get "/api/v1/users"
    -> String
  get "/items/:id"
    capture id : String via idCapture
    -> String
}
|}

let test_R66_PH06_multiple_path_params_valid () =
  should_pass {|
#lang tesl
module R66Ph06 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
capture userIdCapture: userId: String using stringCodec
capture postIdCapture: postId: String using stringCodec
api R66Ph06 {
  get "/users/:userId/posts/:postId"
    capture userId : String via userIdCapture
    capture postId : String via postIdCapture
    -> String
}
|}

(* ── R66_AU — Auth clause integrity ─────────────────────────────────────── *)

let test_R66_AU01_auth_without_proof_annotation_rejected () =
  (* auth binding without ::: ProofPred is structurally invalid *)
  should_fail "proof annotation\\|::: ProofPred\\|auth.*proof" {|
#lang tesl
module R66Au01 exposing []
import Tesl.Prelude exposing [String]
fact AuthedUser (u: String)
auth authFun(u: String) -> u: String ::: AuthedUser u = ok u ::: AuthedUser u
api R66Au01 {
  get "/whoami"
    auth requestedUser : String via authFun
    -> String
}
|}

let test_R66_AU02_auth_with_proof_annotation_accepted () =
  should_pass {|
#lang tesl
module R66Au02 exposing []
import Tesl.Prelude exposing [String]
fact AuthedUser (u: String)
auth authFun(u: String) -> u: String ::: AuthedUser u = ok u ::: AuthedUser u
api R66Au02 {
  get "/whoami"
    auth user : String ::: AuthedUser user via authFun
    -> String
}
|}

let test_R66_AU03_auth_conjunction_proof_accepted () =
  should_pass {|
#lang tesl
module R66Au03 exposing []
import Tesl.Prelude exposing [String]
fact IsAdmin (u: String)
fact AuthedUser (u: String)
auth adminAuth(u: String) -> u: String ::: IsAdmin u && AuthedUser u = ok u ::: IsAdmin u && AuthedUser u
api R66Au03 {
  get "/admin"
    auth user : String ::: IsAdmin user && AuthedUser user via adminAuth
    -> String
}
|}

let test_R66_AU04_no_auth_clause_accepted () =
  (* Public endpoint with no auth — perfectly valid *)
  should_pass {|
#lang tesl
module R66Au04 exposing []
import Tesl.Prelude exposing [String]
api R66Au04 {
  get "/public"
    -> String
}
|}

(* ── R66_CA — Capture clause integrity ──────────────────────────────────── *)

let test_R66_CA01_capture_not_in_path_rejected () =
  (* Capture clause references a param name not present in the path *)
  should_fail "capture.*does not match\\|path parameter\\|capture.*param" {|
#lang tesl
module R66Ca01 exposing []
import Tesl.Prelude exposing [String]
api R66Ca01 {
  get "/items"
    capture id : String via stringCodec
    -> String
}
|}

let test_R66_CA02_capture_wrong_name_rejected () =
  (* Path has :id but capture clause uses userId — mismatch *)
  should_fail "capture.*does not match\\|path parameter\\|capture.*param" {|
#lang tesl
module R66Ca02 exposing []
import Tesl.Prelude exposing [String]
api R66Ca02 {
  get "/items/:id"
    capture userId : String via stringCodec
    -> String
}
|}

let test_R66_CA03_correct_capture_name_accepted () =
  should_pass {|
#lang tesl
module R66Ca03 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
capture idCapture: id: String using stringCodec
api R66Ca03 {
  get "/items/:id"
    capture id : String via idCapture
    -> String
}
|}

let test_R66_CA04_duplicate_capture_rejected () =
  should_fail "duplicate capture\\|capture.*duplicate" {|
#lang tesl
module R66Ca04 exposing []
import Tesl.Prelude exposing [String]
api R66Ca04 {
  get "/items/:id"
    capture id : String via stringCodec
    capture id : Int via intCodec
    -> String
}
|}

let test_R66_CA05_multiple_path_params_all_captured_accepted () =
  should_pass {|
#lang tesl
module R66Ca05 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
capture uidCapture: uid: String using stringCodec
capture pidCapture: pid: String using stringCodec
api R66Ca05 {
  get "/users/:uid/posts/:pid"
    capture uid : String via uidCapture
    capture pid : String via pidCapture
    -> String
}
|}

let test_R66_CA06_partial_capture_missing_one_param_rejected () =
  (* Only captures one param, declares capture for non-existent param *)
  should_fail "capture.*does not match\\|path parameter" {|
#lang tesl
module R66Ca06 exposing []
import Tesl.Prelude exposing [String]
api R66Ca06 {
  get "/users/:uid/posts/:pid"
    capture wrongParam : String via stringCodec
    -> String
}
|}

let test_R66_CA07_no_capture_clause_path_param_rejected () =
  (* A `:param` path segment with NO `capture` clause must be a compile error.
     Previously the emitter invented a default capture named `<param>Capture`
     that was never defined, so the endpoint type-checked but crashed at
     `tesl run`. *)
  should_fail "path parameter\\|has no `capture`\\|no.*capture clause" {|
#lang tesl
module R66Ca07 exposing []
import Tesl.Prelude exposing [String]
api R66Ca07 {
  get "/items/:id"
    -> String
}
|}

let test_R66_CA08_bare_string_path_param_no_capture_rejected () =
  (* Bug fix_bugs: `get "/ping/:string" -> String` — the `:string` path param
     has no `capture` clause.  Compiled to broken Racket before, crashed at run. *)
  should_fail "path parameter\\|has no `capture`\\|no.*capture clause" {|
#lang tesl
module R66Ca08 exposing []
import Tesl.Prelude exposing [String]
api R66Ca08 {
  get "/ping/:string"
      -> String
}
|}

let test_R66_CA09_capture_via_codec_not_capture_form_rejected () =
  (* Bug fix_bugs: `capture s: String via stringCodec` — `stringCodec` is a JSON
     codec, not a top-level `capture` form, so the emitted route names a binding
     that is not a `define-capture` and crashes at `tesl run`. *)
  should_fail "not a declared `capture` form\\|via.*not.*declared.*capture\\|capture form" {|
#lang tesl
module R66Ca09 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
api R66Ca09 {
  get "/ping/:s"
    capture s : String via stringCodec
      -> String
}
|}

let test_R66_CA10_capture_using_keyword_rejected () =
  (* Bug fix_bugs: `capture s: String using stringCodec` inside an api block —
     `using` is not supported here; the parser silently dropped it, leaving the
     `:s` path param with no capture, which crashed at `tesl run`. *)
  should_fail "path parameter\\|has no `capture`\\|no.*capture clause" {|
#lang tesl
module R66Ca10 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
api R66Ca10 {
  get "/ping/:s"
    capture s : String using stringCodec
      -> String
}
|}

let test_R66_CA11_capture_via_undefined_name_rejected () =
  (* `via noSuchCapture` references an identifier that is neither a codec nor a
     declared capture form — must be rejected at compile time. *)
  should_fail "not a declared `capture` form\\|via.*not.*declared.*capture\\|capture form" {|
#lang tesl
module R66Ca11 exposing []
import Tesl.Prelude exposing [String]
api R66Ca11 {
  get "/ping/:s"
    capture s : String via noSuchCapture
      -> String
}
|}

let test_R66_CA12_capture_via_real_capture_form_accepted () =
  (* The correct form: `via` names a top-level `capture` declaration. *)
  should_pass {|
#lang tesl
module R66Ca12 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
capture sCapture: s: String using stringCodec
api R66Ca12 {
  get "/ping/:s"
    capture s : String via sCapture
    -> String
}
|}

let test_R66_CA13_inline_capture_accepted () =
  (* Inline form: `capture x: T with <codec>` needs no top-level `capturer`. *)
  should_pass {|
#lang tesl
module R66Ca13 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
api R66Ca13 {
  get "/items/:id"
    capture id: String with stringCodec
    -> String
}
|}

let test_R66_CA14_inline_capture_with_check_accepted () =
  (* Inline form with a `via <check>` proof: `capture x: T with <codec> via <fn>`. *)
  should_pass {|
#lang tesl
module R66Ca14 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
fn parseId(id: String) -> String =
  id
api R66Ca14 {
  get "/items/:id"
    capture id: String with stringCodec via parseId
    -> String
}
|}

let test_R66_CA15_inline_sse_capture_accepted () =
  (* SSE endpoints accept the inline capture form too. *)
  should_pass {|
#lang tesl
module R66Ca15 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
api R66Ca15 {
  sse "/events/:userId"
    capture userId: String with stringCodec
    -> String
}
|}

(* ── R66_DU — Duplicate endpoints ───────────────────────────────────────── *)

let test_R66_DU01_duplicate_method_and_path_rejected () =
  should_fail "duplicate endpoint\\|duplicate.*endpoint" {|
#lang tesl
module R66Du01 exposing []
import Tesl.Prelude exposing [String]
api R66Du01 {
  get "/health"
    -> String
  get "/health"
    -> String
}
|}

let test_R66_DU02_same_path_different_methods_accepted () =
  (* GET /items and POST /items are different endpoints *)
  should_pass {|
#lang tesl
module R66Du02 exposing []
import Tesl.Prelude exposing [String]
api R66Du02 {
  get "/items"
    -> String
  post "/items"
    -> String
}
|}

let test_R66_DU03_different_paths_same_method_accepted () =
  should_pass {|
#lang tesl
module R66Du03 exposing []
import Tesl.Prelude exposing [String]
api R66Du03 {
  get "/a"
    -> String
  get "/b"
    -> String
}
|}

let test_R66_DU04_duplicate_post_rejected () =
  should_fail "duplicate endpoint" {|
#lang tesl
module R66Du04 exposing []
import Tesl.Prelude exposing [String]
api R66Du04 {
  post "/create"
    -> String
  post "/create"
    -> String
}
|}

(* ── R66_OK — Valid complete APIs (regression guard) ────────────────────── *)

let test_R66_OK01_minimal_api_accepted () =
  should_pass {|
#lang tesl
module R66Ok01 exposing []
import Tesl.Prelude exposing [String]
api R66Ok01 {
  get "/health"
    -> String
}
|}

let test_R66_OK02_full_api_with_all_clauses_accepted () =
  should_pass {|
#lang tesl
module R66Ok02 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
fact AuthedUser (u: String)
auth authFun(u: String) -> u: String ::: AuthedUser u = ok u ::: AuthedUser u
capture idCapture: id: String using stringCodec
api R66Ok02 {
  get "/health"
    -> String

  get "/users/:id"
    auth user : String ::: AuthedUser user via authFun
    capture id : String via idCapture
    -> String

  post "/users"
    auth user : String ::: AuthedUser user via authFun
    body req: String
    -> String
}
|}

let test_R66_OK03_existing_kanel_style_api_accepted () =
  (* Guards against regression in the style used by the kanel example *)
  should_pass {|
#lang tesl
module R66Ok03 exposing []
import Tesl.Prelude exposing [String, Int]
import Tesl.Json exposing [stringCodec, intCodec]
import Tesl.Http exposing [HttpRequest]
import Tesl.Dict exposing [Dict.lookup]
import Tesl.Maybe exposing [Maybe(..)]
fact Authenticated (u: String)
auth sessionAuth(req: HttpRequest) -> user: String ::: Authenticated user =
  case Dict.lookup "session" req.cookies of
    Nothing -> fail 401 "not authenticated"
    Something s -> ok s ::: Authenticated user
capture itemIdCapture: itemId: String using stringCodec
api R66Ok03 {
  get "/whoami"
    auth user : String ::: Authenticated user via sessionAuth
    -> String

  post "/items"
    auth user : String ::: Authenticated user via sessionAuth
    body req: String
    -> Int

  get "/items/:itemId"
    auth user : String ::: Authenticated user via sessionAuth
    capture itemId : String via itemIdCapture
    -> String

  delete "/items/:itemId"
    auth user : String ::: Authenticated user via sessionAuth
    capture itemId : String via itemIdCapture
    -> String
}
|}

let test_R66_OK04_sse_with_http_endpoints_accepted () =
  (* Mixed SSE and HTTP endpoints *)
  should_pass {|
#lang tesl
module R66Ok04 exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
database Db { backend postgres schema "s" entities []
  postgres { database "d" user "u" password "" host "localhost" port 5432 socket "" } }
type Ev = EvMsg msg: String
channel Events(uid: String) { database Db payload Ev }
fn parseId(s: String) -> String = s
capture uidCapture: String using stringCodec via parseId
api R66Ok04 {
  get "/health"
    -> String

  post "/send"
    body req: String
    -> String

  sse "/events/:uid"
    capture uid : String via uidCapture
    subscribe Events(uid)
}
|}

let test_R66_OK05_multiple_apis_in_same_module_accepted () =
  should_pass {|
#lang tesl
module R66Ok05 exposing []
import Tesl.Prelude exposing [String]
api R66Ok05A {
  get "/a"
    -> String
}
api R66Ok05B {
  get "/b"
    -> String
}
|}

(* ── Test runner ─────────────────────────────────────────────────────────── *)

let () =
  run "Review66-API-Validation" [
    "arrow-ordering", [
      test_case "R66_AR01 auth after arrow rejected" `Quick test_R66_AR01_auth_after_arrow_rejected;
      test_case "R66_AR02 body after arrow rejected" `Quick test_R66_AR02_body_after_arrow_rejected;
      test_case "R66_AR03 double arrow rejected" `Quick test_R66_AR03_double_arrow_rejected;
      test_case "R66_AR04 handler-name-as-return rejected" `Quick test_R66_AR04_handler_name_after_arrow_rejected;
      test_case "R66_AR05 capture after arrow rejected" `Quick test_R66_AR05_capture_after_arrow_rejected;
      test_case "R66_AR06 response after arrow rejected" `Quick test_R66_AR06_response_after_arrow_rejected;
      test_case "R66_AR07 auth before arrow accepted" `Quick test_R66_AR07_auth_before_arrow_accepted;
      test_case "R66_AR08 body before arrow then auth after rejected" `Quick test_R66_AR08_body_then_arrow_then_auth_rejected;
    ];
    "return-type", [
      test_case "R66_RT01 missing return type rejected" `Quick test_R66_RT01_missing_return_type_rejected;
      test_case "R66_RT02 auth only no return rejected" `Quick test_R66_RT02_auth_only_no_return_rejected;
      test_case "R66_RT03 one of multiple endpoints missing return rejected" `Quick test_R66_RT03_multiple_endpoints_one_missing_return_rejected;
      test_case "R66_RT04 SSE without return accepted" `Quick test_R66_RT04_sse_without_return_accepted;
      test_case "R66_RT05 explicit return accepted" `Quick test_R66_RT05_explicit_return_accepted;
      test_case "R66_RT06 undefined return type caught" `Quick test_R66_RT06_undefined_return_type_caught;
    ];
    "path-format", [
      test_case "R66_PH01 empty path rejected" `Quick test_R66_PH01_empty_path_rejected;
      test_case "R66_PH02 path without leading slash rejected" `Quick test_R66_PH02_path_without_slash_rejected;
      test_case "R66_PH03 POST path without slash rejected" `Quick test_R66_PH03_path_without_slash_all_methods_rejected;
      test_case "R66_PH04 nested path without slash rejected" `Quick test_R66_PH04_nested_path_without_slash_rejected;
      test_case "R66_PH05 valid paths accepted" `Quick test_R66_PH05_valid_paths_accepted;
      test_case "R66_PH06 multiple path params accepted" `Quick test_R66_PH06_multiple_path_params_valid;
    ];
    "auth-integrity", [
      test_case "R66_AU01 auth without proof annotation rejected" `Quick test_R66_AU01_auth_without_proof_annotation_rejected;
      test_case "R66_AU02 auth with proof annotation accepted" `Quick test_R66_AU02_auth_with_proof_annotation_accepted;
      test_case "R66_AU03 auth with conjunction proof accepted" `Quick test_R66_AU03_auth_conjunction_proof_accepted;
      test_case "R66_AU04 no auth clause accepted" `Quick test_R66_AU04_no_auth_clause_accepted;
    ];
    "capture-integrity", [
      test_case "R66_CA01 capture not in path rejected" `Quick test_R66_CA01_capture_not_in_path_rejected;
      test_case "R66_CA02 capture wrong name rejected" `Quick test_R66_CA02_capture_wrong_name_rejected;
      test_case "R66_CA03 correct capture name accepted" `Quick test_R66_CA03_correct_capture_name_accepted;
      test_case "R66_CA04 duplicate capture rejected" `Quick test_R66_CA04_duplicate_capture_rejected;
      test_case "R66_CA05 multiple path params captured accepted" `Quick test_R66_CA05_multiple_path_params_all_captured_accepted;
      test_case "R66_CA06 partial capture wrong name rejected" `Quick test_R66_CA06_partial_capture_missing_one_param_rejected;
      test_case "R66_CA07 no capture clause path param rejected" `Quick test_R66_CA07_no_capture_clause_path_param_rejected;
      test_case "R66_CA08 bare :string path param no capture rejected" `Quick test_R66_CA08_bare_string_path_param_no_capture_rejected;
      test_case "R66_CA09 capture via codec not capture form rejected" `Quick test_R66_CA09_capture_via_codec_not_capture_form_rejected;
      test_case "R66_CA10 capture using keyword rejected" `Quick test_R66_CA10_capture_using_keyword_rejected;
      test_case "R66_CA11 capture via undefined name rejected" `Quick test_R66_CA11_capture_via_undefined_name_rejected;
      test_case "R66_CA12 capture via real capture form accepted" `Quick test_R66_CA12_capture_via_real_capture_form_accepted;
      test_case "R66_CA13 inline capture accepted" `Quick test_R66_CA13_inline_capture_accepted;
      test_case "R66_CA14 inline capture with check accepted" `Quick test_R66_CA14_inline_capture_with_check_accepted;
      test_case "R66_CA15 inline SSE capture accepted" `Quick test_R66_CA15_inline_sse_capture_accepted;
    ];
    "duplicate-endpoints", [
      test_case "R66_DU01 duplicate method+path rejected" `Quick test_R66_DU01_duplicate_method_and_path_rejected;
      test_case "R66_DU02 same path different methods accepted" `Quick test_R66_DU02_same_path_different_methods_accepted;
      test_case "R66_DU03 different paths same method accepted" `Quick test_R66_DU03_different_paths_same_method_accepted;
      test_case "R66_DU04 duplicate POST rejected" `Quick test_R66_DU04_duplicate_post_rejected;
    ];
    "valid-apis", [
      test_case "R66_OK01 minimal api accepted" `Quick test_R66_OK01_minimal_api_accepted;
      test_case "R66_OK02 full api all clauses accepted" `Quick test_R66_OK02_full_api_with_all_clauses_accepted;
      test_case "R66_OK03 kanel-style api accepted" `Quick test_R66_OK03_existing_kanel_style_api_accepted;
      test_case "R66_OK04 sse with http endpoints accepted" `Quick test_R66_OK04_sse_with_http_endpoints_accepted;
      test_case "R66_OK05 multiple apis in same module accepted" `Quick test_R66_OK05_multiple_apis_in_same_module_accepted;
    ];
  ]
