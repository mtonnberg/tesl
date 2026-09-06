open Alcotest

let contains = Compile.string_contains
let replace a b = Str.global_replace (Str.regexp_string a) b
let rec mkdir path =
  if not (Sys.file_exists path) then (mkdir (Filename.dirname path); Unix.mkdir path 0o700)
let rec remove path =
  if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  end else Sys.remove path
let write path source =
  mkdir (Filename.dirname path);
  Out_channel.with_open_bin path (fun out -> output_string out source)
let with_project f =
  let root = Filename.temp_file "tesl-migration-topology-" ".dir" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    write (Filename.concat root "tesl.toml") "";
    write (Filename.concat root "schema/notes/v-current.tesl") {|module NotesSchema.VCurrent exposing [Note]
import Tesl.Prelude exposing [String]
entity Note table "notes" primaryKey id { id: String }
|};
    f (Filename.concat root "app.tesl"))

let source ?(imports="Worker, Embedded") fields = Printf.sprintf {|module App exposing [Db]
import Tesl.Prelude exposing [Int, String]
import Tesl.Env exposing [env, envString]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection%s]
import NotesSchema.VCurrent exposing [Note]
database Db = Database {
  schema: NotesSchema.VCurrent
  migrations: NotesSchema.Migrate
  backend: Postgres (PostgresConfig {
    namespace: "notes"
    dbName: "unused"
    user: "unused"
    password: "unused"
    connection: TcpConnection { host: "localhost", port: 5432 }
%s
  })
}
|} (if imports="" then "" else ", " ^ imports) fields

let diagnostics path text =
  write path text;
  let context = Compile.agent_context_result_source path text in
  let errors = List.filter (fun (d : Compile.diagnostic) -> d.severity="error") (Compile.check_file path) in
  check bool "compact diagnostics agree with checking" (errors=[]) context.ok;
  errors
let accepts path text =
  let errors = diagnostics path text in
  if errors<>[] then fail (Compile.diagnostics_to_json errors)
let refuses path text fragment =
  let errors = diagnostics path text in
  if not (List.exists (fun (d : Compile.diagnostic) -> contains d.message fragment) errors) then
    failf "missing %S in %s" fragment (Compile.diagnostics_to_json errors);
  match Compile.compile_go_file path with
  | Compile.GoFailure _ -> ()
  | Compile.GoSuccess _ -> fail "invalid topology configuration emitted a program"
let emit path text =
  accepts path text;
  match Compile.compile_go_file path with
  | Compile.GoFailure errors -> fail (Compile.diagnostics_to_json errors)
  | Compile.GoSuccess artifacts ->
    match List.find_opt (fun (a : Emit_go.artifact) -> a.path="internal/teslmodapp/module.go") artifacts with
    | None -> fail "application artifact missing"
    | Some artifact -> artifact.contents
let explicit_topology () = with_project (fun path ->
  List.iter (fun topology ->
    let result = emit path (source ("    topology: " ^ topology)) in
    check bool "literal constructor reaches runtime unchanged" true
      (contains result ("MigrationTopology: \"" ^ topology ^ "\""));
    check bool "topology is not an environment lookup" false
      (contains result ("EnvString(\"" ^ topology))) ["Worker"; "Embedded"])

let constructor_group_emission () = with_project (fun path ->
  List.iter (fun topology ->
    let result = emit path (source ~imports:"MigrationTopology(..)" ("topology: " ^ topology)) in
    check bool "the lessons' ADT import reaches Go emission" true
      (contains result ("MigrationTopology: \"" ^ topology ^ "\""))) ["Worker"; "Embedded"])

let default_topology () = with_project (fun path ->
  let result = emit path (source ~imports:"" "") in
  List.iter (fun field ->
    check bool "omission preserves runtime deployment defaults" false (contains result (field ^ ":")))
    ["MigrationTopology"; "RequestRole"; "WorkerRole"; "DDLConnection"])

let literal_connections () = with_project (fun path ->
  let result = emit path (source {|    topology: Worker
    requestRole: "notes_app"
    workerRole: "notes_schema"
    ddlConnection: "host=direct.internal dbname=notes user=notes_schema"
|}) in
  List.iter (fun expected -> check bool expected true (contains result expected)) [
    {|RequestRole: "notes_app"|}; {|WorkerRole: "notes_schema"|};
    {|DDLConnection: "host=direct.internal dbname=notes user=notes_schema"|} ])

let environment_connections () = with_project (fun path ->
  let result = emit path (source {|    requestRole: envString "NOTES_REQUEST_ROLE" "tesl_app"
    workerRole: env "NOTES_WORKER_ROLE"
    ddlConnection: env "NOTES_DDL_DSN"
|}) in
  List.iter (fun expected -> check bool expected true (contains result expected)) [
    {|RequestRole: teslrt.EnvString("NOTES_REQUEST_ROLE", "tesl_app")|};
    {|WorkerRole: teslrt.EnvString("NOTES_WORKER_ROLE", "")|};
    {|DDLConnection: teslrt.EnvString("NOTES_DDL_DSN", "")|} ];
  check bool "dynamic credentials do not imply an explicit topology" false (contains result "MigrationTopology:"))

let constructor_imports () = with_project (fun path ->
  ignore (emit path (source ~imports:"Worker" "topology: Worker"));
  ignore (emit path (source ~imports:"Embedded" "topology: Embedded"));
  ignore (emit path (source ~imports:"MigrationTopology(..)" "topology: Worker"));
  let all = source ~imports:"" "topology: Embedded" |>
    replace "import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]" "import Tesl.Database" in
  ignore (emit path all);
  refuses path (source ~imports:"" "topology: Worker") "requires importing `Worker`";
  refuses path (source ~imports:"MigrationTopology" "topology: Embedded") "requires importing `Embedded`";
  refuses path (source ~imports:"Embedded" "topology: Worker") "requires importing `Worker`")

let literal_enum_only () = with_project (fun path ->
  List.iter (fun value ->
    refuses path (source ("topology: " ^ value)) "literal constructor") [
    {|"Worker"|}; {|env "TOPOLOGY"|}; "Memory"; "Worker 1"; "Embedded {}"; "True"; "42" ])

let string_config_only () = with_project (fun path ->
  List.iter (fun field ->
    List.iter (fun value ->
      refuses path (source (field ^ ": " ^ value)) ("field `" ^ field ^ "` must be a String"))
      ["42"; "Worker"; "True"; "[\"x\"]"])
    ["requestRole"; "workerRole"; "ddlConnection"])

let legacy_refusal () = with_project (fun path ->
  let legacy text = text |>
    replace "schema: NotesSchema.VCurrent\n  migrations: NotesSchema.Migrate" "schema: \"legacy\"\n  entities: [Note]" |>
    replace "    namespace: \"notes\"\n" "" in
  accepts path (legacy (source ~imports:"" ""));
  List.iter (fun (field,value) ->
    refuses path (legacy (source (field ^ ": " ^ value)))
      ("`PostgresConfig." ^ field ^ "` requires a versioned schema module")) [
    "topology", "Worker"; "topology", "Embedded"; "requestRole", "\"app\"";
    "workerRole", "\"worker\""; "ddlConnection", {|env "DDL_DSN"|} ])

let expression_refusal () =
  List.iter (fun name ->
    let text = Printf.sprintf {|module ConfigValue exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Database exposing [%s]
fn value() -> Int =
  let config = %s
  1
|} name name in
    let errors = Compile.check_source "<topology-value>" text in
    check bool "topology cannot escape as a runtime value" true
      (List.exists (fun (d : Compile.diagnostic) -> contains d.message "cannot be used in an ordinary expression") errors))
    ["Worker"; "Embedded"]

let config_context () =
  let text = source "    topology: Worker" in
  let lines = String.split_on_char '\n' text in
  let line = List.find_index (fun line -> String.trim line="topology: Worker") lines |> Option.get in
  match Compile.config_context_source "<topology-context>" text line 6 with
  | None -> fail "missing PostgresConfig context"
  | Some context ->
    check string "configuration block" "PostgresConfig" context.cc_block;
    List.iter (fun (name,kind,doc) ->
      match List.find_opt (fun (f : Compile.config_field_info) -> f.cfi_name=name) context.cc_fields with
      | None -> fail ("missing configuration field " ^ name)
      | Some field ->
        check string "field type" kind field.cfi_type;
        check bool "optional field" false field.cfi_required;
        check bool "present flag" (name="topology") field.cfi_present;
        check bool "actionable documentation" true (contains field.cfi_doc doc)) [
      "topology", "Worker | Embedded", "TESL_DEPLOYED";
      "requestRole", "String", "tesl_app";
      "workerRole", "String", "tesl_schema";
      "ddlConnection", "String", "session-affine" ]

let config_docs () =
  let rendered = Result.get_ok (Stdlib_docs.render_config "PostgresConfig") in
  List.iter (fun field -> check bool "generated config documentation" true (contains rendered field))
    ["topology: Worker | Embedded"; "requestRole: String"; "workerRole: String"; "ddlConnection: String"];
  List.iter (fun name ->
    match Stdlib_docs.lookup name with
    | [entry] ->
      check string "constructor docs link to their config type" "MigrationTopology" entry.name;
      check bool "docs describe deployment default" true (contains entry.doc "TESL_DEPLOYED")
    | _ -> fail ("missing or ambiguous topology documentation for " ^ name))
    ["MigrationTopology"; "Worker"; "Embedded"]

let () =
  run "Migration topology configuration" [
    "emission", [
      test_case "explicit Worker and Embedded" `Quick explicit_topology;
      test_case "ADT export emits both lesson topology choices" `Quick constructor_group_emission;
      test_case "omission retains runtime defaults" `Quick default_topology;
      test_case "literal roles and direct DSN" `Quick literal_connections;
      test_case "environment roles and DSN remain runtime values" `Quick environment_connections;
    ];
    "checking", [
      test_case "constructor imports" `Quick constructor_imports;
      test_case "enum accepts only nullary literals" `Quick literal_enum_only;
      test_case "role and DSN values are strings" `Quick string_config_only;
      test_case "legacy configuration remains unchanged" `Quick legacy_refusal;
      test_case "constructors cannot escape config" `Quick expression_refusal;
    ];
    "tooling", [
      test_case "normal config field completion and hover" `Quick config_context;
      test_case "normal config and constructor documentation" `Quick config_docs;
    ];
  ]
