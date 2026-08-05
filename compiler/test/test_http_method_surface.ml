(** The HTTP-method surface of `api` endpoints and `handler` declarations.

    Tesl supports exactly five verbs — get / post / put / delete / patch — plus
    `sse` on an endpoint.  Two failure modes are pinned here:

      1. An unrecognised leading word in an `api` block used to be SILENTLY
         SWALLOWED (`| _ -> advance s; None`): `head "/ping"` produced no
         endpoint, no error and no warning, and the only downstream symptom was
         an unrelated "server is missing N binding(s)".  It is now a parse
         error naming the supported verbs.

      2. The verbs stay CONTEXTUAL identifiers, so the positive cases must keep
         compiling: every verb as an endpoint, every verb on a handler, and a
         handler still NAMED `get`. *)

open Alcotest

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
  let tmp = Filename.temp_file "tesl-httpverb" ".tesl" in
  let oc = open_out tmp in output_string oc src; close_out oc;
  let cmd = Printf.sprintf "%s %s %s 2>&1" tesl check_subcmd tmp in
  let ic = Unix.open_process_in cmd in
  let out = In_channel.input_all ic in
  let _ = Unix.close_process_in ic in
  (try Sys.remove tmp with _ -> ());
  out

let has_error out =
  try ignore (Str.search_forward (Str.regexp "error\\[") out 0); true
  with Not_found -> false

let should_pass name src =
  let out = compile_string src in
  if has_error out then Printf.eprintf "[%s] unexpected error:\n%s\n" name out;
  check bool name false (has_error out)

let should_fail name pattern src =
  let out = compile_string src in
  let matched =
    has_error out
    && (try ignore (Str.search_forward (Str.regexp_string pattern) out 0); true
        with Not_found -> false)
  in
  if not matched then Printf.eprintf "[%s] expected %S, got:\n%s\n" name pattern out;
  check bool name true matched

(* ── Negative: an unsupported verb is named, not dropped ─────────────────── *)

let unsupported name verb =
  should_fail name "is not an HTTP method Tesl supports"
    (Printf.sprintf
       {|module M%s exposing [Srv]
import Tesl.Prelude exposing [String]
api Api {
  %s "/ping"
    -> String
  get "/pong"
    -> String
}
handler get pong() -> String = "pong"
server Srv for Api {
  pong
}
|} name verb)

let head_verb ()    = unsupported "Head" "head"
let options_verb () = unsupported "Options" "options"
let upper_verb ()   = unsupported "Upper" "GET"

let non_verb_word () =
  should_fail "a non-verb word is reported as a missing method"
    "expected an HTTP method at the start of an endpoint"
    {|module MWord exposing []
import Tesl.Prelude exposing [String]
api Api {
  fetch "/ping"
    -> String
}
|}

(* ── Positive: every supported verb, on both sides ───────────────────────── *)

let all_verbs () =
  should_pass "all five verbs as endpoints and handlers"
    {|module MAll exposing [Srv]
import Tesl.Prelude exposing [String]
api Api {
  get "/r"
    -> String
  post "/r"
    -> String
  put "/r"
    -> String
  patch "/r"
    -> String
  delete "/r"
    -> String
}
handler get readIt() -> String = "get"
handler post createIt() -> String = "post"
handler put replaceIt() -> String = "put"
handler patch amendIt() -> String = "patch"
handler delete removeIt() -> String = "delete"
server Srv for Api {
  readIt
  createIt
  replaceIt
  amendIt
  removeIt
}
|}

(* The verbs are contextual identifiers, never keywords: a handler may still be
   NAMED `get`, and `parse_handler_methods`' one-token lookahead is what tells
   the two shapes apart. *)
let handler_named_get () =
  should_pass "a handler may still be named `get`"
    {|module MNamed exposing [Srv]
import Tesl.Prelude exposing [String]
api Api {
  get "/r"
    -> String
}
handler get get() -> String = "named get"
server Srv for Api {
  get
}
|}

(* `handler get(…)` — verb prefix absent, `get` IS the name — parses, and is
   rejected only by the method cross-check once it is bound to an endpoint.
   That error, not a parse failure, is what the user must see. *)
let handler_named_get_unstated_method () =
  should_fail "a handler named `get` with no stated method → method error"
    "does not declare an HTTP method"
    {|module MNamed2 exposing [Srv]
import Tesl.Prelude exposing [String]
api Api {
  get "/r"
    -> String
}
handler get() -> String = "named get"
server Srv for Api {
  get
}
|}

let () =
  run "HttpMethodSurface"
    [ ("unsupported verbs are rejected, not dropped",
       [ test_case "head → parse error" `Quick head_verb;
         test_case "options → parse error" `Quick options_verb;
         test_case "uppercase GET → parse error" `Quick upper_verb;
         test_case "arbitrary word → parse error" `Quick non_verb_word ]);
      ("supported surface keeps compiling",
       [ test_case "all five verbs" `Quick all_verbs;
         test_case "handler named `get`" `Quick handler_named_get;
         test_case "handler named `get`, method unstated → method error" `Quick
           handler_named_get_unstated_method ]) ]
