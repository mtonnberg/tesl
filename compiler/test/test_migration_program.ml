open Alcotest
module P = Migration_program
module G = Migration_generate
module M = Migration_manifest
let rec mkdir p = if not (Sys.file_exists p) then (mkdir (Filename.dirname p);Unix.mkdir p 0o700)
let rec remove p = if (Unix.lstat p).Unix.st_kind=Unix.S_DIR then
 (Array.iter (fun n -> remove (Filename.concat p n)) (Sys.readdir p);Unix.rmdir p) else Sys.remove p
let read p = In_channel.with_open_bin p In_channel.input_all
let write p source = mkdir (Filename.dirname p);Out_channel.with_open_bin p (fun out -> output_string out source)
let save p source = write p source;ignore (Compile.agent_context_result_source p source)
let replace a b = Str.global_substitute (Str.regexp_string a) (fun _ -> b)
let describe es = String.concat "\n" (List.map (fun (e:Migration_sparse.error) -> e.code ^ ": " ^ e.message) es)
let get = function Ok x -> x | Error es -> fail (describe es)
let refuse code = function
 | Ok _ -> fail ("expected " ^ code)
 | Error es -> check bool (describe es) true (List.exists (fun (e:Migration_sparse.error) -> e.code=code) es)
let schema = {|module NotesSchema.VCurrent exposing [Note]
import Tesl.Prelude exposing [String, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
entity Note table "notes" primaryKey id { id: String }
|}
let app = {|module App exposing []
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import NotesSchema.VCurrent
database Main = Database { schema: NotesSchema.VCurrent, migrations: NotesSchema.Migrate,
 backend: Postgres (PostgresConfig { dbName: "deployment-database", user: "deployment-user", password: "secret-sentinel", namespace: "notes_app",
 connection: TcpConnection { host: "127.0.0.1", port: 5432 } }) }
|}
let with_project f =
 let root = Filename.temp_file "tesl-program-" ".dir" in Sys.remove root;Unix.mkdir root 0o700;
 Fun.protect ~finally:(fun () -> remove root) (fun () ->
  let path=Filename.concat root in
  write (path "tesl.toml") "";save (path "schema/notes/v-current.tesl") schema;save (path "app.tesl") app;
  f root path)
let parsed path source = match Parser.parse_module path source with Ok m -> m | Err e -> fail e.msg
let capture path f = let file=path "app.tesl" in P.with_history ~entry:(parsed file (read file)) ~source:(read file) f
let bundle path = get (capture path (function Some p -> p | None -> fail "missing PostgreSQL history"))
let emit path source = match Compile.compile_go_source (path "app.tesl") source with
 | Compile.GoSuccess xs -> xs
 | Compile.GoFailure ds -> fail (String.concat "\n" (List.map (fun (d:Compile.diagnostic) -> d.code ^ ": " ^ d.message) ds))
let artifact xs = List.find_opt (fun (a:Emit_go.artifact) -> a.path="migration-history.json") xs
let generate root version =
 let context = Result.get_ok (Migration_abi.current ()) in
 let preview = match G.start_with_compatibility ~stored_value_compatibility:(Some (Migration_abi.stored_value_compatibility context))
   ~compiler_abi:(Migration_abi.id context) ~project_root:root ~family:"NotesSchema" ~version ~documents:[] with
  | Ok x -> x | Error es -> fail (String.concat "\n" (List.map (fun (e:G.error) -> e.message) es)) in
 List.iter (fun (e:M.edit) -> save e.path e.after) (M.edits preview.manifest)
let edit_schema path f = let file=path "schema/notes/v-current.tesl" in save file (f (read file))
let refresh ?(version=2) root =
 let context = Result.get_ok (Migration_abi.current ()) in
 let preview = match G.refresh_with_compatibility ~stored_value_compatibility:(Some (Migration_abi.stored_value_compatibility context))
   ~compiler_abi:(Migration_abi.id context) ~project_root:root ~family:"NotesSchema" ~version ~documents:[] with
  | Ok x -> x | Error es -> fail (String.concat "\n" (List.map (fun (e:G.error) -> e.message) es)) in
 List.iter (fun (e:M.edit) -> save e.path e.after) (M.edits preview.manifest)
let current p = List.hd (P.databases p)
let json p = P.to_json ~quote:Compile.json_encode_string p
let baseline () = with_project (fun _ path ->
 let p=bundle path in
 check string "real ABI" (Migration_abi.id (Result.get_ok (Migration_abi.current ()))) (P.compiler_abi p);
 check string "connection identity" "App.Main" (current p).identity;
 let artifacts=emit path app in
 check bool "lowered connection retains its checked family binding" true
  (List.exists (fun (a:Emit_go.artifact) -> a.path="internal/teslmodapp/module.go" &&
    Compile.string_contains a.contents "teslrt.RegisterDatabaseMigrationHistory(MainDatabase, \"NotesSchema\")") artifacts);
 check bool "standalone runtime carries its history" true
  (List.exists (fun (a:Emit_go.artifact) -> a.path="internal/teslrt/migration_history_generated.go" &&
    Compile.string_contains a.contents "registerCompiledMigrationHistory(\"App.Main\", \"NotesSchema\"") artifacts);
 let output = match artifact artifacts with Some a -> a.contents | None -> fail "build omitted history artifact" in
 check string "actual build uses guarded history" (json p ^ "\n") output;
 check bool "compact history uses its own versioned envelope" true
  (Compile.string_contains output "\"version\":3,\"kind\":\"compiled-migration-history\"");
 check string "compiled stored-value contract comes from actual context"
  (Migration_abi.stored_value_compatibility (Result.get_ok (Migration_abi.current ())))
  (P.stored_value_compatibility p);
 check bool "wire carries explicit compatibility" true
  (Compile.string_contains output ("\"storedValueCompatibility\":" ^ Compile.json_encode_string (P.stored_value_compatibility p)));
 check bool "catalogs are reconstructed from operations at runtime" false
  (Compile.string_contains output "\"catalog\":");
 List.iter (fun secret -> check bool "history contains no connection credentials or source paths" false (Compile.string_contains output secret))
  ["secret-sentinel";"deployment-database";"deployment-user";path ""];
 check bool "baseline has storage" true (match get (List.hd (current p).origins).steps with
  | [{Migration_expansion.operations=[Create_table t];_}] -> t.name="notes" | _ -> false))
let ordinary () = with_project (fun _ path ->
 let plain="module App exposing []\n" in
 check bool "legacy output has no migration artifact" true (artifact (emit path plain)=None);
 let memory=replace "Postgres, PostgresConfig, TcpConnection" "Memory" app in
 let start=String.index memory '(' in
 let memory=String.sub memory 0 start |> replace "backend: Postgres " "backend: Memory }\n" in
 check bool "Memory does not pretend to carry PostgreSQL history" true (artifact (emit path memory)=None))
let control_owner () = with_project (fun _ path ->
 let configured=replace "namespace: \"notes_app\"," "namespace: \"notes_app\", controlOwner: \"deployment-control\"," app in
 let artifacts=emit path configured in
 check bool "application configuration lowers the control owner" true
  (List.exists (fun (a:Emit_go.artifact) -> a.path="internal/teslmodapp/module.go" &&
    Compile.string_contains a.contents "ControlOwner:" && Compile.string_contains a.contents "deployment-control") artifacts);
 check bool "control role is not part of schema source history" false
  (Compile.string_contains (Option.get (artifact artifacts)).contents "deployment-control");
 let dynamic=configured |> replace "import Tesl.Database" "import Tesl.Env exposing [env]\nimport Tesl.Database"
   |> replace "controlOwner: \"deployment-control\"" "controlOwner: env \"TESL_CONTROL_OWNER\"" in
 ignore (emit path dynamic);
 List.iter (fun source ->
  let errors=Compile.check_source (path "app.tesl") source |> List.filter (fun (d:Compile.diagnostic) -> d.severity="error") in
  check bool "invalid or legacy control owner is rejected" true
    (List.exists (fun (d:Compile.diagnostic) -> Compile.string_contains d.message "controlOwner") errors))
  [replace "controlOwner: \"deployment-control\"" "controlOwner: 17" configured;
   configured |> replace "schema: NotesSchema.VCurrent, migrations: NotesSchema.Migrate," "schema: \"notes_app\", entities: [Note],"
    |> replace "import NotesSchema.VCurrent" "import NotesSchema.VCurrent exposing [Note]"
    |> replace "namespace: \"notes_app\", " ""])
let command_entrypoints () = with_project (fun _ path ->
 let imports="import Tesl.Prelude exposing [String]\nimport Tesl.App exposing [App]\n" in
 let main={|
api ProbeApi { get "/probe" -> String }
handler get probe() -> String = "ok"
server ProbeServer for ProbeApi { probe }
database ProbeDb = Database { entities: [], backend: Memory }
main() -> App = App { database: ProbeDb, api: ProbeServer, port: 8093 }
|} in
 let source=(app |> replace "import Tesl.Database" (imports ^ "import Tesl.Database") |> replace "Database, Postgres" "Database, Memory, Postgres") ^ main in
 let entry artifacts = (List.find (fun (a:Emit_go.artifact) -> a.path="cmd/app/main.go") artifacts).contents in
 let release=entry (emit path source) in
 check bool "schema command precedes application execution" true
  (Str.search_forward (Str.regexp_string "RunSchemaCommand") release 0 < Str.search_forward (Str.regexp_string "teslmodapp.Main()") release 0);
 let debug=match Compile.compile_go_source ~debug:true (path "app.tesl") source with
  | Compile.GoSuccess xs -> entry xs | Compile.GoFailure _ -> fail "debug entry did not compile" in
 check bool "operator command does not start debug services" true
  (Str.search_forward (Str.regexp_string "RunSchemaCommand") debug 0 < Str.search_forward (Str.regexp_string "StartDebugControlFromEnvironment") debug 0);
 save (path "connection.tesl") (replace "module App" "module Connection" app);
 let thin="module App exposing []\nimport Connection\nimport Tesl.Database exposing [Database, Memory]\n" ^ imports ^ main in
 let artifacts=emit path thin in
 check bool "imported owner still enables command dispatch" true (Compile.string_contains (entry artifacts) "RunSchemaCommand");
 check bool "thin entry includes the PostgreSQL command implementation" true
  (List.exists (fun (a:Emit_go.artifact) -> a.path="internal/teslrt/migration_command.go") artifacts);
 let plain="module App exposing []\nimport Tesl.Database exposing [Database, Memory]\n" ^ imports ^ main in
 check bool "ordinary main remains inert" false (Compile.string_contains (entry (emit path plain)) "RunSchemaCommand"))
let caller_bytes () = with_project (fun _ path ->
 let modified=replace "notes_app" "unsaved_namespace" app in
 let output=Option.get (artifact (emit path modified)) in
 check bool "explicit entry source wins over disk" true (Compile.string_contains output.contents "unsaved_namespace");
 check bool "old namespace is absent" false (Compile.string_contains output.contents "notes_app");
 check string "compile did not save the buffer" app (read (path "app.tesl")))
let virtual_entry () = with_project (fun _ path ->
 Sys.remove (path "app.tesl");
 let output=Option.get (artifact (emit path app)) in
 check bool "a new editor entry receives its checked history" true (Compile.string_contains output.contents "App.Main");
 check bool "compilation leaves the entry virtual" false (Sys.file_exists (path "app.tesl")))
let origins () = with_project (fun root path ->
 generate root 1;
 edit_schema path (replace "id: String" "id: String, caption: Maybe String");refresh root;
 let before=get (List.hd (current (bundle path)).origins).steps |> List.map Migration_expansion.step_node in
 generate root 2;
 let p=bundle path in
 check (list int) "every installation origin is represented" [1;2;3]
  (List.map (fun (o:P.origin) -> o.initial_version) (current p).origins);
 let prior=get (List.hd (current p).origins).steps |> List.filter (fun (s:Migration_expansion.step) -> s.version<=2) in
 check bool "freezing keeps earlier step identity" true (before=List.map Migration_expansion.step_node prior);
 List.iter (fun (origin:P.origin) ->
  let steps=get origin.steps in
  check int "origin-specific baseline" origin.initial_version (List.hd steps).version;
  check int "history extends through current" 3 (List.hd (List.rev steps)).version;
  check bool "first step creates its own baseline" true (match (List.hd steps).operations with [Create_table _] -> true | _ -> false)) (current p).origins;
 ignore (emit path app))
let invalid_history () = with_project (fun root path ->
 generate root 1;
 let file=path "schema/notes/v1.tesl" in save file (read file ^ "# tampered\n");
 refuse "MIG013" (capture path (fun _ -> fail "invalid frozen history reached emission"));
 match Compile.compile_go_source (path "app.tesl") app with
 | Compile.GoFailure ds -> check bool "build refuses frozen edit" true (List.exists (fun (d:Compile.diagnostic) -> d.code="MIG013") ds)
 | _ -> fail "edited history produced build artifacts")
let changed_inputs () = with_project (fun _ path ->
 let file=path "schema/notes/v-current.tesl" in
 let old=read file in
 refuse "MIG013" (capture path (fun _ -> write file (old ^ "# racing save\n")));
 write file old;
 ignore (get (capture path (fun _ ->
  write file (replace "notes\"" "other\"" old);
  check string "a temporary disk change cannot alter compilation reads" old (Source_input.read file);
  write file old)));
 check string "pinned scope restores normal reads" old (Source_input.read file))
let binding_guard () = with_project (fun _ path ->
 let m=parsed (path "app.tesl") app in
 refuse "MIG013" (P.verify_bindings None [m]);
 let p=bundle path in
 refuse "MIG013" (P.verify_bindings (Some p) []);
 let changed=parsed (path "app.tesl") (replace "notes_app" "other" app) in
 refuse "MIG013" (P.verify_bindings (Some p) [changed]);
 let extra=parsed (path "new.tesl") "module New exposing []\n" in
 refuse "MIG013" (P.verify_bindings (Some p) [m;extra]))
let private_overlay () = with_project (fun root path ->
 let file=path "schema/notes/v-current.tesl" in
 Source_input.with_overlays ~project_root:root [file,replace "id: String" "id: String, caption: Maybe String" schema] (fun () ->
  let p=bundle path in
  check bool "unsaved schema feeds captured storage" true (Compile.string_contains (json p) "caption");
  ignore (emit path app));
 check string "schema stays unsaved" schema (read file))
let failed_app () = with_project (fun _ path ->
 let broken=app ^ "fn broken() -> String = 7\n" in
 match Compile.compile_go_source (path "app.tesl") broken with
 | Compile.GoFailure _ -> () | _ -> fail "invalid whole application yielded a history artifact")
let imported_connections () = with_project (fun _ path ->
 let owner=replace "module App exposing []" "module Config exposing [Main]" app in
 let other=replace "module App exposing []" "module Extra exposing [Other]"
  (replace "NotesSchema" "OtherSchema" (replace "notes_app" "other_app" (replace "database Main" "database Other" app))) in
 save (path "config.tesl") owner;
 save (path "extra.tesl") other;
 save (path "schema/other/v-current.tesl") (replace "NotesSchema" "OtherSchema" schema);
 let source="module App exposing []\nimport Config\nimport Extra\n" in save (path "app.tesl") source;
 let p=bundle path in
 check (list string) "all imported connection owners" ["Config.Main";"Extra.Other"] (List.map (fun (d:P.database) -> d.identity) (P.databases p));
 let a=Option.get (artifact (emit path source)) in
 check string "complete multi-database build transport" (json p ^ "\n") a.contents)
let origin_collision () = with_project (fun root path ->
 edit_schema path (replace "id: String }" "id: String, active: Bool\n index [active] as \"later\"\n}");
 generate root 1;
 edit_schema path (fun s -> replace "index [active] as \"later\"" "" s ^
  "entity Tag table \"tags\" primaryKey id { id: String, label: String\n index [label] as \"later__v3\"\n}\n");refresh root;
 generate root 2;
 edit_schema path (replace "active: Bool\n" "active: Bool\n index [active] as \"later\"\n");refresh ~version:3 root;
 let p=bundle path in
 check (list bool) "only the incompatible installation origin refuses" [true;false;true]
  (List.map (fun (o:P.origin) -> Result.is_ok o.steps) (current p).origins);
 refuse "MIG016" (List.nth (current p).origins 1).steps;
 let a=Option.get (artifact (emit path app)) in
 check bool "refused origin cannot appear as an empty executable plan" true
  (Compile.string_contains a.contents "\"initialVersion\":2,\"steps\":null,\"errors\":[");
 check string "whole build still carries the two supported origins" (json p ^ "\n") a.contents)
let () = run "Compiled migration history" ["build boundary",List.map (fun (n,f) -> test_case n `Quick f)
 ["actual build artifact and no credentials",baseline;"ordinary and Memory builds",ordinary;"control owner belongs to application configuration",control_owner;"schema commands precede main and debug startup",command_entrypoints;
  "explicit caller bytes",caller_bytes;"virtual application entry",virtual_entry;
  "every origin and stable frozen steps",origins;
  "frozen history refusal",invalid_history;"saved races and pinned bytes",changed_inputs;
  "exact binding and source coverage",binding_guard;"unsaved schema overlay",private_overlay;
  "whole application must compile",failed_app;"imported multiple connection owners",imported_connections;
  "origin-specific refusal remains explicit",origin_collision]]
