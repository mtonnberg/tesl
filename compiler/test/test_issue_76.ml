(** GitHub issue #76 — an `auth` function declared with a second parameter
    (beyond the conventional `request: HttpRequest`) type-checked cleanly and
    passed `tesl check`, but trapped at RUNTIME with an arity mismatch once the
    route fired: the compiled server (dsl/web.rkt `run-auth`) only ever calls
    the `via` function with the request value alone, so any extra declared
    parameter was silently dropped, not rejected.

    That single-argument call site is also the documented soundness invariant
    the auth/capture proof-subject reconciliation relies on (see the comment
    above `check_auth_proof_via` in validation_structural.ml), so option (a)
    from the issue — thread captures into the auth call — would touch a
    load-bearing proof rule.  This pins option (b): reject the extra
    parameter at the declaration site with a clear diagnostic, before it ever
    reaches a live route. *)

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
  let st = Unix.close_process_in ic in
  let code = match st with Unix.WEXITED c -> c | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + n in
  (code, out)

let with_source src f =
  let dir = Filename.temp_dir "tesl-issue76" "" in
  let path = Filename.concat dir "issue76.tesl" in
  Out_channel.with_open_text path (fun oc -> Out_channel.output_string oc src);
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let contains hay needle =
  try ignore (Str.search_forward (Str.regexp_string needle) hay 0); true
  with Not_found -> false

(* The file is named issue76.tesl, so the module header must match. *)
let prelude = {|module Issue76 exposing []
import Tesl.Prelude exposing [Bool(..), String]
import Tesl.Http exposing [HttpRequest]
import Tesl.Json exposing [stringCodec]

fact Widened (c: String)
fact Authenticated (c: String)

capturer appIdCapture: appId: String using stringCodec
|}

let check src =
  with_source (prelude ^ src) (fun p -> run_cc ["--check"; p])

let should_pass label src =
  let code, out = check src in
  if code <> 0 then failf "%s: expected a clean check, got exit %d:\n%s" label code out

let should_fail label ~expect src =
  let code, out = check src in
  if code = 0 then failf "%s: expected REJECTION, but the check passed" label;
  if not (contains out expect) then
    failf "%s: rejected, but not for the expected reason (wanted %S):\n%s" label expect out

(* ── The reported shape ──────────────────────────────────────────────────── *)

let test_second_param_rejected () =
  should_fail "auth with a second declared parameter"
    ~expect:"declares 2 parameters, but the compiled route calls it with exactly one"
    {|
auth widen(request: HttpRequest, appId: String) -> c: String ::: Widened c =
  ok appId ::: Widened appId

api ProbeApi {
  get "/probe/:appId"
    auth c: String ::: Widened c via widen
    capture appId: String via appIdCapture
    -> String
}
|}

let test_zero_params_rejected () =
  should_fail "auth with zero declared parameters"
    ~expect:"declares 0 parameters, but the compiled route calls it with exactly one"
    {|
auth noArgs() -> c: String ::: Widened c =
  ok "x" ::: Widened "x"
|}

let test_conventional_single_param_accepted () =
  should_pass "the conventional single request parameter"
    {|
auth cookieAuth(request: HttpRequest) -> user: String ::: Authenticated user =
  ok "u" ::: Authenticated user

api ProbeApi {
  get "/probe"
    auth user: String ::: Authenticated user via cookieAuth
    -> String
}
|}

let test_renamed_single_param_accepted () =
  (* The convention is the parameter's role, not its name — any single param
     type-checks the same as `request: HttpRequest`. *)
  should_pass "a renamed but still single request parameter"
    {|
auth reqAuth(req: HttpRequest) -> user: String ::: Authenticated user =
  ok "u" ::: Authenticated user
|}

let () =
  run "issue-76 auth function arity" [
    "surface", [
      test_case "second parameter rejected at check time" `Quick test_second_param_rejected;
      test_case "zero parameters rejected"                `Quick test_zero_params_rejected;
      test_case "single conventional parameter accepted"  `Quick test_conventional_single_param_accepted;
      test_case "single renamed parameter accepted"       `Quick test_renamed_single_param_accepted;
    ];
  ]
