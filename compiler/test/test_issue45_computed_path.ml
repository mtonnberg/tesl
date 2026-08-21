(** GitHub issue #45 — an api-test request path must accept any expression.

    Literal and computed request paths must both reach Go's API-test dispatcher
    with the intended value. Nested response fields remain dynamic JSON reads,
    and concatenation renders those values as path fragments.

    Two things had to change, and this test pins both at the EMIT layer (the
    runtime behaviour — routing, query parsing, 404s, subscribe — is covered
    end-to-end by tests/api-test-computed-path-tests.tesl):

    The runtime behavior is covered end-to-end by
    tests/api-test-computed-path-tests.tesl; these tests pin the Go lowering. *)

open Alcotest

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
    let result = Compile.compile_go_file path in
    (try Sys.remove path with _ -> ());
    (try Unix.rmdir dir with _ -> ());
    match result with
    | Compile.GoFailure diagnostics ->
      failf "the probe app must compile:\n%s"
        (String.concat "\n"
           (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
    | Compile.GoSuccess artifacts ->
      match List.find_opt (fun (a : Emit_go.artifact) ->
        Filename.basename a.path = "module_test.go") artifacts with
      | Some artifact -> artifact.contents
      | None -> failf "Go emit did not produce module_test.go")

(* A literal path reaches the dispatcher unchanged. *)
let t_literal_path_is_unchanged () =
  let out = Lazy.force emitted in
  if not (contains out "\"/things/7\"") then
    failf
      "a literal path must reach the Go API-test dispatcher unchanged.\n%s"
      out

(* A let-bound path is passed through as the value; the runtime splits it. *)
let t_let_bound_path_is_passed_through () =
  let out = Lazy.force emitted in
  if not (contains out "p") then
    failf "a let-bound path must be passed to the dispatch as the value `p`.\n%s" out

(* Nested response fields use dynamic JSON access. *)
let t_response_field_in_a_path_lowers_to_field_access () =
  let out = Lazy.force emitted in
  if not (contains out "teslrt.JsonFieldOf(created.Body, \"id\")")
  then
    failf
      "a nested response-field read in a path must lower through \
       Go's dynamic API-test field access.\n%s" out

(* `++` inside an api-test coerces its operands: a JSON id is often a number,
   and string-append on a number is a crash, not a routing failure. *)
let t_concat_operands_are_coerced () =
  let out = Lazy.force emitted in
  if not (contains out "teslrt.JsonAsString(teslrt.JsonFieldOf(created.Body, \"id\"))") then
    failf
      "`++` inside an api-test must wrap each operand in api-test-string-fragment \
       so a numeric response field concatenates.\n%s" out

let () =
  run "Issue45-Computed-Path" [
    "emit", [
      test_case "a literal path is unchanged" `Quick t_literal_path_is_unchanged;
      test_case "a let-bound path is passed through" `Quick
        t_let_bound_path_is_passed_through;
      test_case "a response field in a path lowers to field-access" `Quick
        t_response_field_in_a_path_lowers_to_field_access;
      test_case "++ operands are coerced to strings" `Quick
        t_concat_operands_are_coerced;
    ];
  ]
