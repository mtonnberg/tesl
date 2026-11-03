open Alcotest

let rec mkdir path = if not (Sys.file_exists path) then begin mkdir (Filename.dirname path); Unix.mkdir path 0o700 end
let rec remove path = if Sys.is_directory path then begin
  Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
end else Sys.remove path
let with_project f =
  let root = Filename.temp_dir "tesl-optional-transport-" "" in
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let write relative source = let path = Filename.concat root relative in mkdir (Filename.dirname path);
      Out_channel.with_open_bin path (fun out -> output_string out source); path in
    ignore (write "tesl.toml" ""); f root write)
let imports = {|import Tesl.Prelude exposing [String, Int, Bool(..), Fact, attachFact, detachFact]
import Tesl.Maybe exposing [Maybe(..)]
|}
let producer name same = "module " ^ name ^ " exposing [NonEmpty, Note, tryTitle, need]\n" ^ imports ^
  "fact NonEmpty (value: String)\nrecord Note { title: String ::: NonEmpty title }\nfn need(value: String ::: NonEmpty value) -> String = value\n" ^
  "establish tryTitle(" ^ (if same then "value" else "raw") ^ ": String) -> Maybe (value: String ::: NonEmpty value) =\n" ^
  "  if " ^ (if same then "value" else "raw") ^ " != \"\" then\n    Something (" ^ (if same then "value" else "raw") ^ " ::: NonEmpty " ^ (if same then "value" else "raw") ^ ")\n  else\n    Nothing\n"
let diagnostics path = Compile.check_file path |> List.filter (fun (d : Compile.diagnostic) -> d.severity = "error")
let accepted path = match diagnostics path with [] -> () | ds -> fail (String.concat "\n" (List.map (fun (d : Compile.diagnostic) -> d.message) ds))
let rejected path =
  let source = In_channel.with_open_bin path In_channel.input_all in
  (match Parser.parse_module path source with Ok _ -> () | Err e -> fail ("fixture must parse: " ^ e.msg));
  let ds = diagnostics path in
  check bool "proof obligation refuses bad payload" true
    (List.exists (fun (d : Compile.diagnostic) -> d.code = "V001" &&
      (try ignore (Str.search_forward (Str.regexp_case_fold "proof") d.message 0); true with Not_found -> false)) ds)
let setup write same = ignore (write "titles.tesl" (producer "Titles" same)); ignore (write "other.tesl" (producer "Other" same))
let app body = "module App exposing []\n" ^ imports ^ "import Titles\nimport Other\n" ^ body
let conversion call payload =
  "fn convert(raw: String) -> Maybe Titles.Note =\n" ^ call ^
  "    Nothing -> Nothing\n    Something title ->\n" ^ payload ^ "\n"
let record = "      Something (Titles.Note { title: title })"

let direct same () = with_project (fun _ write -> setup write same;
  accepted (write "app.tesl" (app (conversion "  case Titles.tryTitle raw of\n" record))))
let bound same () = with_project (fun _ write -> setup write same;
  accepted (write "app.tesl" (app (conversion "  let result = Titles.tryTitle raw\n  let alias = result\n  case alias of\n" record))))
let unpacked () = with_project (fun _ write -> setup write false;
  accepted (write "app.tesl" (app (conversion "  case Titles.tryTitle raw of\n"
    "      let (value ::: proof) = title\n      Something (Titles.Note { title: value })"))))
let field_subject () = with_project (fun _ write -> setup write true;
  accepted (write "app.tesl" (app {|
record Input { text: String }
fn convert(input: Input) -> Maybe Titles.Note =
  case Titles.tryTitle input.text of
    Nothing -> Nothing
    Something title -> Something (Titles.Note { title: title })
|})))
let direct_consumer () = with_project (fun _ write -> setup write false;
  accepted (write "app.tesl" (app {|
fn convert(raw: String) -> Maybe String =
  let result = Titles.tryTitle raw
  case result of
    Nothing -> Nothing
    Something title -> Something (Titles.need title)
|})))
let wrong_success mode () = with_project (fun _ write -> setup write false;
  accepted (write "app.tesl" (app (conversion "  case Titles.tryTitle raw of\n" record)));
  let body = match mode with
    | "foreign" -> conversion "  case Other.tryTitle raw of\n" record
    | "subject" -> conversion "  case Titles.tryTitle raw of\n" "      Something (Titles.Note { title: raw })"
    | "changed" -> conversion "  case Titles.tryTitle raw of\n" "      let changed = title ++ \"!\"\n      Something (Titles.Note { title: changed })"
    | _ -> "fn convert(raw: String) -> Maybe Titles.Note =\n  case Titles.tryTitle raw of\n    Nothing -> Something (Titles.Note { title: raw })\n    Something title -> Nothing\n" in
  rejected (write "app.tesl" (app body)))
let transforming_producer same second =
  "module Titles exposing [NonEmpty, Note, tryTitle, need]\n" ^ imports ^
  "fact NonEmpty (value: String)\nrecord Note { title: String ::: NonEmpty title }\nfn need(value: String ::: NonEmpty value) -> String = value\n" ^
  "establish tryTitle(" ^ (if second then "unused: String, " else "") ^
  (if same then "value" else "raw") ^ ": String) -> Maybe (value: String ::: NonEmpty value) =\n" ^
  "  let changed = " ^ (if same then "value" else "raw") ^ " ++ \"!\"\n" ^
  "  Something (changed ::: NonEmpty changed)\n"
let transformed_result same second bound wrong () = with_project (fun _ write ->
  ignore (write "titles.tesl" (transforming_producer same second));
  ignore (write "other.tesl" (producer "Other" false));
  let call = "Titles.tryTitle " ^ (if second then "other " else "") ^ "raw" in
  let prefix = if bound then "  let result = " ^ call ^ "\n  let alias = result\n  case alias of\n"
    else "  case " ^ call ^ " of\n" in
  let body payload = "fn convert(raw: String, other: String) -> Maybe Titles.Note =\n" ^ prefix ^
    "    Nothing -> Nothing\n    Something title -> Something (Titles.Note { title: " ^ payload ^ " })\n" in
  accepted (write "app.tesl" (app (body "title")));
  Option.iter (fun payload -> rejected (write "app.tesl" (app (body payload)))) wrong)
let transformed_alias mode () = with_project (fun _ write ->
  ignore (write "titles.tesl" (transforming_producer true false));
  ignore (write "other.tesl" (producer "Other" false));
  let before, payload, invalid = match mode with
    | "unpack" -> "  let result = Titles.tryTitle raw\n  case result of\n", "value", "raw"
    | "witness" -> "  let result = Titles.tryTitle raw\n  let alias = result\n  case alias of\n", "value ::: proof", "raw ::: proof"
    | _ -> "  case forward raw of\n", "title", "raw" in
  let forward = if mode = "forward" then
    "fn forward(raw: String) -> Maybe (raw: String ::: Titles.NonEmpty raw) = Titles.tryTitle raw\n" else "" in
  let body field = app (forward ^ "fn convert(raw: String) -> Maybe Titles.Note =\n" ^ before ^
    "    Nothing -> Nothing\n    Something title ->\n" ^
    (if mode = "unpack" || mode = "witness" then "      let (value ::: proof) = title\n" else "") ^
    "      Something (Titles.Note { title: " ^ field ^ " })\n") in
  accepted (write "app.tesl" (body payload));
  rejected (write "app.tesl" (body invalid)))

let shadowed_subject () = with_project (fun _ write ->
  ignore (write "titles.tesl" (transforming_producer false false));
  ignore (write "other.tesl" (producer "Other" false));
  let path = write "app.tesl" (app {|
fn convert(raw: String, other: String) -> Maybe Titles.Note =
  let title = other
  case Titles.tryTitle raw of
    Nothing -> Nothing
    Something title -> Something (Titles.Note { title: title })
|}) in
  check bool "source does not permit case binder shadowing" true
    (List.exists (fun (d : Compile.diagnostic) ->
      try ignore (Str.search_forward (Str.regexp_string "case pattern binder `title` shadows") d.message 0); true
      with Not_found -> false) (diagnostics path)))
let shadowed_helper () =
  let source = app (conversion "  case Titles.tryTitle raw of\n" record) in
  let parsed = match Parser.parse_module "app.tesl" source with Ok value -> value | Err e -> fail e.msg in
  let scrut, pattern = match List.find_map (function
    | Ast.DFunc { body = Ast.ECase { scrut; arms = _ :: arm :: _; _ }; _ } -> Some (scrut, arm.Ast.pattern)
    | _ -> None) parsed.Ast.decls with Some pair -> pair | None -> fail "expected converter case" in
  let _, subjects = Validation_structural.case_payload_proof_environments []
    [("title", "other")] [] scrut pattern in
  check (option string) "branch binder cannot retain old alias" (Some "title") (List.assoc_opt "title" subjects)

let run_go_test root write path =
  let artifacts = match Compile.compile_go_file path with
    | Compile.GoSuccess xs -> xs | Compile.GoFailure ds -> fail (Compile.diagnostics_to_json ds) in
  List.iter (fun (a : Emit_go.artifact) -> ignore (write ("out/" ^ a.path) a.contents)) artifacts;
  (* Execution uses only emitted release sources; no source file can be rechecked
     or interpreted by the generated application. *)
  let rec remove_tesl dir = Array.iter (fun name -> let path = Filename.concat dir name in
    if Sys.is_directory path then remove_tesl path
    else if Filename.check_suffix name ".tesl" then Sys.remove path) (Sys.readdir dir) in
  remove_tesl root;
  let log = Filename.concat root "go-test.log" in
  let command = Printf.sprintf "cd %s && timeout 90s go test -race -count=1 -timeout=60s -v ./... > %s 2>&1"
    (Filename.quote (Filename.concat root "out")) (Filename.quote log) in
  let result = Sys.command command in
  let output = In_channel.with_open_bin log In_channel.input_all in
  if result <> 0 then fail output;
  check bool "actual generated test ran" true
    (try ignore (Str.search_forward (Str.regexp_string "--- PASS:") output 0); true with Not_found -> false)

let execution () = with_project (fun root write -> setup write false;
  ignore (write "changed.tesl" (Str.global_replace (Str.regexp_string "Titles") "Changed" (transforming_producer true true)));
  let body = conversion "  let result = Titles.tryTitle raw\n  case result of\n" record ^ {|
fn render(raw: String) -> String =
  case convert raw of
    Nothing -> "missing"
    Something note -> note.title
test "optional proof payload is retained only on success" {
  expect render "title" == "title"
  expect render "" == "missing"
}
test "case statement transports optional proof" {
  let result = Titles.tryTitle "retained"
  case result of
    Nothing -> expect False
    Something title -> expect Titles.need title == "retained"
}
|} in
  let body = body ^ {|
fn transformed(raw: String) -> String =
  case Changed.tryTitle "unused" raw of
    Nothing -> "missing"
    Something title ->
      let note = Changed.Note { title: title }
      note.title
test "success proof follows transformed payload not original input" {
  expect transformed "" == "!"
  expect transformed "retained" == "retained!"
}
|} in
  let path = write "app.tesl" (app ("import Changed\n" ^ body)) in accepted path;
  run_go_test root write path)

let migrated_execution () = with_project (fun root write ->
  ignore (write "schema/notes/v1.tesl" {|module Schema.Notes.V1 exposing [Note]
import Tesl.Prelude exposing [String]
entity Note table "notes" primaryKey id { id: String, authorId: String, title: String }
|});
  ignore (write "schema/notes/v-current.tesl" {|module Schema.Notes.VCurrent exposing [Note, NonEmpty, tryTitle]
import Tesl.Prelude exposing [String, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
fact NonEmpty (value: String)
establish tryTitle(value: String) -> Maybe (v: String ::: NonEmpty v) =
  if value != "" then
    Something (value ::: NonEmpty value)
  else
    Nothing
entity Note table "notes" primaryKey id { id: String, ownerId: String, title: String ::: NonEmpty title }
|});
  let converter = write "migrations/notes/converter.tesl" {|module Schema.Notes.Migrate.Converter exposing [convert, passthrough]
import Tesl.Prelude exposing [String]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Migration exposing [Migrated(..)]
import Schema.Notes.V1
import Schema.Notes.VCurrent
fn convert(old: Schema.Notes.V1.Note) -> Migrated Schema.Notes.VCurrent.Note =
  case Schema.Notes.VCurrent.tryTitle old.title of
    Nothing -> Reject "empty title"
    Something title -> Row (Schema.Notes.VCurrent.Note { id: old.id, ownerId: old.authorId, title: title })
fn passthrough(value: a) -> Migrated a = Row value
|} in
  accepted converter;
  let path = write "migrations/notes/probe.tesl" {|module Schema.Notes.Migrate.Probe exposing []
import Tesl.Prelude exposing [String]
import Tesl.Migration exposing [Migrated(..)]
import Schema.Notes.V1
import Schema.Notes.Migrate.Converter
fn inspect(title: String) -> String =
  let old = Schema.Notes.V1.Note { id: "retained", authorId: "author", title: title }
  case Schema.Notes.Migrate.Converter.convert old of
    Row value -> value.id ++ ":" ++ value.ownerId ++ ":" ++ value.title
    Reject reason -> "rejected:" ++ reason
test "optional success constructs typed migrated row" {
  expect inspect "title" == "retained:author:title"
  expect inspect "Göteborg" == "retained:author:Göteborg"
  expect inspect "" == "rejected:empty title"
}
|} in
  accepted path; run_go_test root write path)

let () = run "optional attached proof transport" ["Maybe", [
  test_case "fresh success binder reaches record construction" `Quick (direct false);
  test_case "same-parameter success binder reaches record construction" `Quick (direct true);
  test_case "bound and aliased optional fresh payload" `Quick (bound false);
  test_case "bound and aliased optional input payload" `Quick (bound true);
  test_case "success payload proof decomposition" `Quick unpacked;
  test_case "input field subject preserved" `Quick field_subject;
  test_case "direct consumer uses same branch subject" `Quick direct_consumer;
  test_case "foreign fact cannot satisfy record field" `Quick (wrong_success "foreign");
  test_case "unproven input is not the fresh result subject" `Quick (wrong_success "subject");
  test_case "transformed success value loses proof" `Quick (wrong_success "changed");
  test_case "Nothing branch has no payload proof" `Quick (wrong_success "nothing");
  test_case "fresh transformed payload reaches record" `Quick (transformed_result false false false None);
  test_case "same-spelled input is not transformed result" `Quick (transformed_result true false false (Some "raw"));
  test_case "bound result never proves transformed input" `Quick (transformed_result true false true (Some "raw"));
  test_case "second parameter result proves only actual payload" `Quick (transformed_result true true false (Some "raw"));
  test_case "second parameter result does not prove first input" `Quick (transformed_result true true true (Some "other"));
  test_case "decomposed success proof does not prove input" `Quick (transformed_alias "unpack");
  test_case "detached optional witness cannot validate original input" `Quick (transformed_alias "witness");
  test_case "forwarded optional result does not prove input" `Quick (transformed_alias "forward");
  test_case "source refuses shadowing a case subject" `Quick shadowed_subject;
  test_case "branch helper clears stale outer subject alias" `Quick shadowed_helper;
  test_case "optional record app compiles and executes" `Quick execution;
  test_case "authoritative optional Migrated row compiles and executes" `Quick migrated_execution;
]]
