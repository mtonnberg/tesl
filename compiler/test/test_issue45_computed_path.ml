(** GitHub issue #45 — an api-test request path must accept any expression.

    The emitter pre-splits a STRING-LITERAL path into segments
    (`get "/todos/1"` → `(list "todos" "1")`) and lifts its `?query` to
    #:query.  A non-literal path cannot be split at compile time, so it was
    emitted as the bare expression and reached the HTTP layer as a whole
    string, where `map` raised a contract violation: `tesl check` passed and
    the crash surfaced as "assertion did not hold" for the whole test body.

    Two things had to change, and this test pins both at the EMIT layer (the
    runtime behaviour — routing, query parsing, 404s, subscribe — is covered
    end-to-end by tests/api-test-computed-path-tests.tesl):

    1. a computed path is emitted api-test-AWARE, so a nested response-field
       read (`created.body.id`) still lowers through api-test-field-access-ref
       instead of becoming a bare Racket identifier ("unbound identifier"), and
       a `++` coerces its operands (a JSON id is as often a number as a string);
    2. the literal form is UNCHANGED — it still pre-splits, so the fix cannot
       regress routing or the committed .rkt snapshots. *)

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

let run_compiler args =
  let quoted = Filename.quote compiler :: List.map Filename.quote args in
  let ic = Unix.open_process_in (String.concat " " quoted ^ " 2>&1") in
  let out = In_channel.input_all ic in
  let code = match Unix.close_process_in ic with
    | Unix.WEXITED c -> c | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + n in
  (code, out)

let failf fmt = Printf.ksprintf failwith fmt

let contains hay needle =
  let n = String.length needle and h = String.length hay in
  let rec go i = i + n <= h && (String.sub hay i n = needle || go (i + 1)) in
  n = 0 || go 0

(* One app, every path shape, so a single emit run covers them all. *)
let app_src = {|module Probe exposing [ThingServer]
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
import Tesl.ApiTest exposing [statusOk]

record Created {
  id: String
}

capturer idCapture: id: String using stringCodec

handler get getThing(id: String) -> String =
  "thing-" ++ id

handler post createThing() -> Created =
  Created { id: "generated-1" }

api ThingApi {
  get "/things/:id"
    capture id: String via idCapture
    -> String

  post "/things"
    -> Created
}

server ThingServer for ThingApi {
  getThing
  createThing
}

api-test "literal" for ThingServer requires [] {
  let r = get "/things/7"
  expect statusOk r.status
}

api-test "let bound" for ThingServer requires [] {
  let p = "/things/7"
  let r = get p
  expect statusOk r.status
}

api-test "concatenated with a response field" for ThingServer requires [] {
  let created = post "/things"
  let r = get ("/things/" ++ created.body.id)
  expect statusOk r.status
}
|}

let emitted =
  lazy (
    let dir = Filename.temp_dir "tesl-i45" "" in
    let path = Filename.concat dir "probe.tesl" in
    let oc = open_out path in output_string oc app_src; close_out oc;
    let code, out = run_compiler [ path ] in
    (try Sys.remove path with _ -> ());
    (try Unix.rmdir dir with _ -> ());
    if code <> 0 then failf "the probe app must compile; got (exit %d):\n%s" code out;
    out)

(* The literal form is untouched: still pre-split into segments. *)
let t_literal_path_is_still_pre_split () =
  let out = Lazy.force emitted in
  if not (contains out "(dispatch-api-test-request ThingServer 'get (list \"things\" \"7\")") then
    failf
      "a literal path must still be emitted as pre-split segments \
       `(list \"things\" \"7\")` — the runtime normalization is additive.\n%s"
      out

(* A let-bound path is passed through as the value; the runtime splits it. *)
let t_let_bound_path_is_passed_through () =
  let out = Lazy.force emitted in
  if not (contains out "(dispatch-api-test-request ThingServer 'get p ") then
    failf "a let-bound path must be passed to the dispatch as the value `p`.\n%s" out

(* The regression that made the flagship create-then-read case fail to compile
   at the RACKET level: `created.body` emitted as a bare identifier. *)
let t_response_field_in_a_path_lowers_to_field_access () =
  let out = Lazy.force emitted in
  if contains out "(string-append \"/things/\" created.body" then
    failf
      "a response field inside a path must NOT be emitted as the bare Racket \
       identifier `created.body` (unbound identifier at load).\n%s" out;
  if not (contains out "(api-test-field-access-ref (api-test-field-access-ref created 'body) 'id)")
  then
    failf
      "a nested response-field read in a path must lower through \
       api-test-field-access-ref twice (body, then id).\n%s" out

(* `++` inside an api-test coerces its operands: a JSON id is often a number,
   and string-append on a number is a crash, not a routing failure. *)
let t_concat_operands_are_coerced () =
  let out = Lazy.force emitted in
  if not (contains out "(string-append (api-test-string-fragment") then
    failf
      "`++` inside an api-test must wrap each operand in api-test-string-fragment \
       so a numeric response field concatenates.\n%s" out

let () =
  run "Issue45-Computed-Path" [
    "emit", [
      test_case "a literal path is still pre-split" `Quick
        t_literal_path_is_still_pre_split;
      test_case "a let-bound path is passed through" `Quick
        t_let_bound_path_is_passed_through;
      test_case "a response field in a path lowers to field-access" `Quick
        t_response_field_in_a_path_lowers_to_field_access;
      test_case "++ operands are coerced to strings" `Quick
        t_concat_operands_are_coerced;
    ];
  ]
