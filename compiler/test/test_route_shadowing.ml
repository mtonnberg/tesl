(** Route shadowing is a compile error (language review 2026-09-02, M4).

    The router matches routes in declaration order and takes the first pattern that fits, so
    `get "/tasks/:id"` declared before `get "/tasks/new"` made `/tasks/new` unreachable: the
    request ran the `:id` handler (and its `auth`) instead, with no diagnostic anywhere.
    {!Validation_advanced.check_route_shadowing} reports the later, unreachable endpoint. *)

open Alcotest

let compiler =
  match Sys.getenv_opt "TESL_OCAML_COMPILER" with
  | Some p when Sys.file_exists p -> p
  | _ ->
    let dir = Filename.dirname Sys.argv.(0) in
    let candidate = Filename.concat (Filename.dirname dir) "bin/main.exe" in
    let candidate2 = Filename.concat dir "../bin/main.exe" in
    if Sys.file_exists candidate then candidate
    else if Sys.file_exists candidate2 then candidate2
    else "tesl"

let run_command cmd =
  let ic = Unix.open_process_in cmd in
  let out = In_channel.input_all ic in
  let status = Unix.close_process_in ic in
  ((match status with Unix.WEXITED c -> c | _ -> 255), out)

let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-routes" "" in
  let path = Filename.concat dir "Routes.tesl" in
  let oc = open_out path in output_string oc content; close_out oc;
  Fun.protect
    ~finally:(fun () -> (try Sys.remove path with _ -> ()); (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let check src =
  with_temp_file src (fun path ->
    run_command (Printf.sprintf "%s --check %s 2>&1" (Filename.quote compiler) (Filename.quote path)))

let should_fail pat src =
  let code, out = check src in
  if code = 0 then failf "expected a static failure matching %S, but compiled cleanly:\n%s" pat out;
  let re = Str.regexp_case_fold pat in
  (try ignore (Str.search_forward re out 0)
   with Not_found -> failf "expected a failure matching %S, got:\n%s" pat out)

let should_pass src =
  let code, out = check src in
  if code <> 0 then failf "expected a clean compile, got (exit %d):\n%s" code out

let fixture api = Printf.sprintf {|module Routes exposing []

import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]

record Msg {
  text: String
}

codec Msg {
  toJson {
    text -> "text" with_codec stringCodec
  }
  fromJson_forbidden
}

capturer idCapture: id: String using stringCodec

handler get byId(id: String) -> Msg =
  Msg { text: id }

handler get newForm() -> Msg =
  Msg { text: "new" }

handler post create() -> Msg =
  Msg { text: "created" }

api A {
%s
}
|} api

let test_param_before_literal_refused () =
  should_fail "route `get \"/tasks/new\"` is unreachable"
    (fixture {|  get "/tasks/:id"
    capture id: String via idCapture
    -> Msg
  get "/tasks/new"
    -> Msg|})

let test_literal_before_param_ok () =
  should_pass
    (fixture {|  get "/tasks/new"
    -> Msg
  get "/tasks/:id"
    capture id: String via idCapture
    -> Msg|})

let test_different_methods_do_not_shadow () =
  should_pass
    (fixture {|  get "/tasks/:id"
    capture id: String via idCapture
    -> Msg
  post "/tasks/new"
    -> Msg|})

let test_different_length_does_not_shadow () =
  should_pass
    (fixture {|  get "/tasks/:id"
    capture id: String via idCapture
    -> Msg
  get "/tasks/new/form"
    -> Msg|})

let test_hint_says_reorder () =
  should_fail "declare `get \"/tasks/new\"` BEFORE `get \"/tasks/:id\"`"
    (fixture {|  get "/tasks/:id"
    capture id: String via idCapture
    -> Msg
  get "/tasks/new"
    -> Msg|})

let () =
  run "route-shadowing"
    [
      ( "shadowing",
        [ test_case "param before literal is refused" `Quick test_param_before_literal_refused;
          test_case "hint says to reorder" `Quick test_hint_says_reorder ] );
      ( "not shadowing",
        [ test_case "literal before param" `Quick test_literal_before_param_ok;
          test_case "different methods" `Quick test_different_methods_do_not_shadow;
          test_case "different segment counts" `Quick test_different_length_does_not_shadow ] );
    ]
