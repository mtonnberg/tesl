open Alcotest
module V = Validation_common
module G = Migration_generate
module M = Migration_manifest
module C = Migration_canonical

let replace before after = Str.global_substitute (Str.regexp_string before) (fun _ -> after)
let get = function Ok value -> value | Error message -> fail message
let rec mkdir path = if not (Sys.file_exists path) then (mkdir (Filename.dirname path); Unix.mkdir path 0o700)
let rec remove path = if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then
  (Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path)
  else Sys.remove path
let read path = In_channel.with_open_bin path In_channel.input_all
let save path source =
  mkdir (Filename.dirname path);
  Out_channel.with_open_bin path (fun out -> output_string out source);
  ignore (Compile.agent_context_result_source path source)
let diagnostics ds = String.concat "\n" (List.map (fun (d:Compile.diagnostic) -> d.code ^ ": " ^ d.message) ds)
let checked path =
  let errors = Compile.check_file path |> List.filter (fun (d:Compile.diagnostic) -> d.severity = "error") in
  check string "application passes the normal checker" "" (diagnostics errors)
let emitted path = match Compile.compile_go_file path with
  | Compile.GoSuccess artifacts -> artifacts
  | Compile.GoFailure ds -> fail (diagnostics ds)
let contents name artifacts = (List.find (fun (a:Emit_go.artifact) -> a.path = name) artifacts).contents

let paths () =
  List.iter (fun (name,path) -> check (option string) name (Some path) (V.schema_module_relative_path name)) [
    "Schema.Todo.VCurrent", "schema/todo/v-current.tesl";
    "Schema.Todo.VCurrent.Todos", "schema/todo/v-current/todos.tesl";
    "Schema.Todo.V12.Todos", "schema/todo/v12/todos.tesl";
    "Schema.Todo.Migrate.V12", "migrations/todo/v12.tesl";
    "Schema.Todo.Migrate.V12.Helpers", "migrations/todo/v12/helpers.tesl";
    "TodoSchema.VCurrent", "schema/todo/v-current.tesl";
    "TodoSchema.Migrate.V12.Helpers", "migrations/todo/v12/helpers.tesl";
    "Schema.MyTodos.V2147483646", "schema/my-todos/v2147483646.tesl";
  ];
  List.iter (fun name -> check (option string) ("refuse " ^ name) None (V.schema_module_relative_path name)) [
    "Schema.VCurrent"; "Schema.todo.VCurrent"; "schema.Todo.VCurrent"; "Schema.Todo.V0";
    "Schema.Todo.V01"; "Schema.Todo.V2147483647"; "Schema.Todo.V99999999999999999999";
    "Schema.Todo.V1../Outside"; "Schema.Todo.VCurrent.lower"; "Schema.Todo.VCurrent..Todos";
    "Schema.Todo/Outside.VCurrent"; "Schema.Todo.VCurrent.Todos\000"; "Schema.Todo.Other.VCurrent";
  ];
  List.iter (fun family -> check bool family true (Migration_source.valid_family family))
    ["Schema.Todo"; "TodoSchema"; "Schema.MyTodos"; "Schema.Todo_2"];
  List.iter (fun family -> check bool family false (Migration_source.valid_family family))
    ["Schema"; "Schema."; "Schema.Todo.Other"; "Todo"; "Schema.Todo.VCurrent"; "Schema.todo"; "Schema../Todo"]

let rewrite () =
  let rewrite before after source = get (Migration_source.rewrite_version ~family:"Schema.Todo" ~before ~after source) in
  let source = {|# Schema.Todo.VCurrent is prose.
module Schema.Todo.VCurrent.Todos exposing [label]
import Schema.Todo.VCurrent.Helpers
fn label() -> String = "Schema.Todo.VCurrent ${Schema.Todo.VCurrent.Helpers.value} ${TodoSchema.VCurrent.value}"
|} in
  let expected = {|# Schema.Todo.VCurrent is prose.
module Schema.Todo.V12.Todos exposing [label]
import Schema.Todo.V12.Helpers
fn label() -> String = "Schema.Todo.VCurrent ${Schema.Todo.V12.Helpers.value} ${TodoSchema.VCurrent.value}"
|} in
  check string "source-preserving qualified freeze" expected (rewrite "VCurrent" "V12" source);
  check string "inverse retains all original bytes" source (rewrite "V12" "VCurrent" expected);
  let spaced = "\tSchema . Todo . VCurrent.value + Wrapper.Schema.Todo.VCurrent.value + Schema.Other.VCurrent.value\r\n\t\tSchema.Todo.VCurrentExtra.value\r\n" in
  check string "tabs, CRLF and complete prefix boundaries"
    (replace "Todo . VCurrent.value" "Todo . V12.value" spaced) (rewrite "VCurrent" "V12" spaced);
  check bool "ambiguous interpolation refuses atomically" true
    (Result.is_error (Migration_source.rewrite_version ~family:"Schema.Todo" ~before:"VCurrent" ~after:"V12"
      {|module Schema.Todo.VCurrent exposing []
label = "${Schema.Todo.VCurrent.value"
|}))

let canonical () =
  let ref family revision name =
    get (C.reference [{family; revision; role=C.Snapshot_role}] (family ^ "." ^ revision ^ "." ^ name)) |> C.encode in
  List.iter (fun name -> check string ("freeze " ^ name)
    (ref "Schema.Todo" "VCurrent" name) (ref "Schema.Todo" "V12" name))
    ["Todo"; "Todos.Todo"; "Todos.tryTitle"; "tryTitle"; "_private"];
  check bool "family rename is not identity-preserving" true
    (ref "Schema.Todo" "V1" "Todos.tryTitle" <> ref "TodoSchema" "V1" "Todos.tryTitle");
  let scopes = [{C.family="Schema.Todo"; revision="V1"; role=C.From_role};
                {C.family="Schema.Todo"; revision="VCurrent"; role=C.To_role}] in
  List.iter (fun name -> check bool name true (Result.is_error (C.reference scopes name)))
    ["Schema.Todo.V2.Todos.tryTitle"; "Schema.Other.V1.Todo"; "TodoSchema.V1.Todo"];
  let helper = "Schema.Todo.Migrate.V2.helper" in
  check string "migration helpers retain global identity"
    (C.encode (C.Seq [C.Bytes "global"; C.Seq (List.map C.bytes (String.split_on_char '.' helper))]))
    (C.encode (get (C.reference scopes helper)))

let schema = {|module Schema.Todo.VCurrent exposing []
import Schema.Todo.VCurrent.Todos
|}
let child = {|module Schema.Todo.VCurrent.Todos exposing [Todo, ValidTitle, tryTitle]
import Tesl.Prelude exposing [String, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.String exposing [String.length]
fact ValidTitle (title: String)
establish tryTitle(title: String) -> Maybe (title: String ::: ValidTitle title) =
  if String.length title > 0 then
    Something (title ::: ValidTitle title)
  else
    Nothing
entity Todo table "todos" primaryKey id {
  id: String
  title: String ::: ValidTitle title
  completed: Bool
}
|}
let app = {|module App exposing []
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import Schema.Todo.VCurrent exposing []
database Main = Database { schema: Schema.Todo.VCurrent, migrations: Schema.Todo.Migrate,
  backend: Postgres (PostgresConfig { dbName: "todo", user: "request", password: "",
    namespace: "todo", connection: TcpConnection { host: "localhost", port: 5432 } }) }
|}
let with_project ?(flat=false) f =
  let root = Filename.temp_file "tesl-qualified-schema-" ".dir" in Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let path name = Filename.concat root name in
    save (path "tesl.toml") "";
    if flat then save (path "schema/todo/v-current.tesl") (replace "VCurrent.Todos" "VCurrent" child)
    else begin
      save (path "schema/todo/v-current/todos.tesl") child;
      save (path "schema/todo/v-current.tesl") schema
    end;
    save (path "app.tesl") app;
    f root path)
let abi () = Result.get_ok (Migration_abi.current ())
let generated = function Ok p -> p | Error errors -> fail (String.concat "\n" (List.map (fun (e:G.error) -> e.message) errors))
let apply manifest = List.iter (fun (e:M.edit) -> save e.path e.after) (M.edits manifest)
let start root version =
  let p = generated (G.start_with_compatibility ~stored_value_compatibility:(Some (Migration_abi.stored_value_compatibility (abi ())))
    ~compiler_abi:(Migration_abi.id (abi ())) ~project_root:root ~family:"Schema.Todo" ~version ~documents:[]) in
  apply p.manifest
let refresh root version =
  let p = generated (G.refresh_with_compatibility ~stored_value_compatibility:(Some (Migration_abi.stored_value_compatibility (abi ())))
    ~compiler_abi:(Migration_abi.id (abi ())) ~project_root:root ~family:"Schema.Todo" ~version ~documents:[]) in
  check string "refresh has no error diagnostics" ""
    (diagnostics (List.filter (fun (d:Compile.diagnostic) -> d.severity="error") p.diagnostics));
  apply p.manifest
let select root path =
  match Migration_selection.resolve ~compiler_abi:(Migration_abi.id (abi ())) ~project_root:root
    ~entry_file:(path "app.tesl") ~database:None ~documents:[] with
  | Ok selected -> Migration_selection.selection selected
  | Error errors -> fail (String.concat "\n" (List.map (fun (e:Migration_selection.error) -> e.message) errors))

let workflow ?(flat=false) () = with_project ~flat (fun root path ->
  let current_file = if flat then "schema/todo/v-current.tesl" else "schema/todo/v-current/todos.tesl" in
  let current_source = read (path current_file) in
  checked (path "app.tesl");
  let selected = select root path in
  check string "CLI selects the entire family" "Schema.Todo" selected.family;
  check string "CLI selects source-owned migration directory" (path "migrations/todo") selected.migration_directory;
  start root 1;
  let frozen_names = if flat then ["schema/todo/v1.tesl"] else ["schema/todo/v1.tesl";"schema/todo/v1/todos.tesl"] in
  let frozen1 = List.map (fun name -> name, read (path name)) frozen_names in
  save (path current_file) (replace "completed: Bool" "completed: Bool\n  details: Maybe String" current_source);
  refresh root 2;
  checked (path "app.tesl");
  let edge2 = read (path "migrations/todo/v2.tesl") in
  check bool "generated edge uses correct roots" true (Compile.string_contains edge2 "to: Schema.Todo.VCurrent");
  let predicate = if flat then "Schema.Todo.V1.ValidTitle" else "Schema.Todo.V1.Todos.ValidTitle" in
  check bool "proof Same includes the qualified owner" true (Compile.string_contains edge2 predicate);
  check bool "root facts remain qualified to their own revisions" true
    (Compile.string_contains edge2 "import Schema.Todo.V1\n" &&
     Compile.string_contains edge2 "import Schema.Todo.VCurrent\n");
  if flat then begin
    let edge = replace "import Tesl.Migration" "import Tesl.Prelude exposing [String]\nimport Tesl.Maybe exposing [Maybe]\nimport Tesl.Migration" edge2 ^ {|

# Ordinary helpers may inspect both versions without merging their proofs.
fn previousTitle(note: Schema.Todo.V1.Todo) -> String = note.title
fn currentTitle(note: Schema.Todo.VCurrent.Todo) -> String = note.title
fn validatePrevious(title: String) -> Maybe (title: String ::: Schema.Todo.V1.ValidTitle title) =
  Schema.Todo.V1.tryTitle title
fn validateCurrent(title: String) -> Maybe (title: String ::: Schema.Todo.VCurrent.ValidTitle title) =
  Schema.Todo.VCurrent.tryTitle title
|} in
    save (path "migrations/todo/v2.tesl") edge;
    checked (path "migrations/todo/v2.tesl")
  end;
  let before = contents "migration-history.json" (emitted (path "app.tesl")) in
  start root 2;
  List.iter (fun (name,source) -> check string "prior snapshot bytes stay sealed" source (read (path name))) frozen1;
  check bool "finished edge targets its frozen revision" true
    (Compile.string_contains (read (path "migrations/todo/v2.tesl")) "to: Schema.Todo.V2");
  let frozen_edge = read (path "migrations/todo/v2.tesl") in
  save (path current_file)
    (replace "completed: Bool" "completed: Bool\n  index [completed] as \"by_completed\"" (read (path current_file)));
  refresh root 3;
  checked (path "app.tesl");
  let artifacts = emitted (path "app.tesl") in
  let history = contents "migration-history.json" artifacts in
  check bool "runtime receives qualified family" true (Compile.string_contains history "\"family\":\"Schema.Todo\"");
  check bool "runtime receives concurrent index step" true (Compile.string_contains history "build-index-concurrently");
  check bool "history advanced" true (history <> before);
  check bool "compiled connection has matching full family" true
    (Compile.string_contains (contents "internal/teslmodapp/module.go" artifacts) "RegisterDatabaseMigrationHistory(MainDatabase, \"Schema.Todo\")");
  check string "completed migration source remains immutable" frozen_edge (read (path "migrations/todo/v2.tesl"));
  check string "application source stays byte-identical" app (read (path "app.tesl"));
  let frozen_entity = if flat then "schema/todo/v1.tesl" else "schema/todo/v1/todos.tesl" in
  save (path frozen_entity) (read (path frozen_entity) ^ "# changed frozen bytes\n");
  match Compile.compile_go_file (path "app.tesl") with
  | Compile.GoFailure ds -> check bool (diagnostics ds) true (List.exists (fun (d:Compile.diagnostic) -> d.code="MIG013") ds)
  | _ -> fail "tampered qualified history compiled")

let boundaries () = with_project (fun root path ->
  start root 1;
  let historical = replace "import Schema.Todo.VCurrent exposing []" "import Schema.Todo.V1 exposing []" app in
  let ds = Compile.check_source (path "app.tesl") historical in
  let d = List.find_opt (fun (d:Compile.diagnostic) -> d.code="MIG015") ds in
  check bool "historical app imports are forbidden" true (d <> None);
  check string "fix preserves full family and every other byte" app
    (match d with Some {fix=Some fix;_} -> Diag_fix.apply historical fix | _ -> fail "historical import has no machine fix");
  let alias = replace "Schema.Todo" "TodoSchema" app in
  (match Compile.compile_go_source (path "app.tesl") alias with
   | Compile.GoFailure ds -> check bool (diagnostics ds) true
       (List.exists (fun (d:Compile.diagnostic) -> d.code="MIG020" &&
         Compile.string_contains d.message "target import TodoSchema.VCurrent resolves to a module declaring Schema.Todo.VCurrent") ds)
   | _ -> fail "legacy spelling was accepted as an alias for the qualified source");
  let schema_file=path "schema/todo/v-current.tesl" in
  save schema_file (schema ^ "import Tesl.Database exposing [Database, Memory]\ndatabase Illegal = Database { entities: [], backend: Memory }\n");
  let ds = Compile.check_file (path "app.tesl") in
  check bool ("connection blocks remain outside the pure schema: " ^ diagnostics ds) true
    (List.exists (fun (d:Compile.diagnostic) -> d.severity="error" &&
      Compile.string_contains d.message "schema modules cannot contain database declarations") ds))

let () = run "Qualified migration families" ["source and runtime boundary", List.map (fun (name,test) -> test_case name `Quick test)
  ["canonical paths and rejected names",paths; "exact source rewriting",rewrite;
   "role normalization and separate family identities",canonical; "generated three-version application",workflow ~flat:false;
   "single-file schema exports its proof across three revisions",workflow ~flat:true;
   "pure and frozen module boundaries",boundaries]]
