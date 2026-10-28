open Alcotest
let replace a b = Str.global_replace (Str.regexp_string a) b
let rec mkdir p = if not(Sys.file_exists p) then (mkdir(Filename.dirname p);Unix.mkdir p 0o700)
let write p s = mkdir(Filename.dirname p);Out_channel.with_open_bin p(fun o->output_string o s)
let rec remove p = if (Unix.lstat p).Unix.st_kind=Unix.S_DIR then
 (Array.iter(fun n->remove(Filename.concat p n))(Sys.readdir p);Unix.rmdir p) else Sys.remove p
let schema owner extra = Printf.sprintf {|module %s exposing [Note, ValidTitle, tryTitle]
import Tesl.Prelude exposing [String, Int]
import Tesl.String exposing [String.length]
import Tesl.Maybe exposing [Maybe(..)]
fact ValidTitle(title: String)
establish tryTitle(value: String) -> Maybe (title: String ::: ValidTitle title) =
  if String.length value > 0 then
    Something (value ::: ValidTitle value)
  else
    Nothing
entity Note table "notes" primaryKey id {
  id: String
  title: String ::: ValidTitle title
%s}
|} owner extra
let source = {|module Schema.Notes.Migrate.V2 exposing [migration]
import Tesl.Prelude exposing [Int]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Same(..), Migrated(..)]
import Schema.Notes.V1
import Schema.Notes.VCurrent
migration = Migration {
  from: Schema.Notes.V1
  to: Schema.Notes.VCurrent
  same: [Same Schema.Notes.V1.ValidTitle Schema.Notes.VCurrent.ValidTitle]
  fixtures: [oldNote]
  entities: { Note: Migrate convert [] }
}
fn oldNote() -> Maybe Schema.Notes.V1.Note =
  case Schema.Notes.V1.tryTitle "retained" of
    Nothing -> Nothing
    Something title -> Something (Schema.Notes.V1.Note { id: "one", title: title })
fn convert(old: Schema.Notes.V1.Note) -> Migrated Schema.Notes.VCurrent.Note =
  Row (Schema.Notes.VCurrent.Note { id: old.id, title: old.title, count: 7 })
|}
let project run =
 let root=Filename.temp_file "tesl-fixtures-" ".dir" in Sys.remove root;Unix.mkdir root 0o700;
 Fun.protect ~finally:(fun()->remove root)(fun()->
  let save p s=let p=Filename.concat root p in write p s;p in
  ignore(save "tesl.toml" "");
  ignore(save "schema/notes/v1.tesl" (schema "Schema.Notes.V1" ""));
  ignore(save "schema/notes/v-current.tesl" (schema "Schema.Notes.VCurrent" "  count: Int\n"));
  let path=save "migrations/notes/v2.tesl" source in run root save path)
let diagnostic ds=String.concat "\n" (List.map(fun(d:Compile.diagnostic)->d.code ^ ": " ^ d.message)ds)
let accepts path s = let context=Compile.agent_context_result_source path s in
 let errors=List.filter(fun(d:Compile.diagnostic)->d.severity="error")context.diagnostics in
 if errors<>[] then fail(diagnostic errors)
let refuses code path s = let context=Compile.agent_context_result_source path s in
 check bool ("expected " ^ code ^ ": " ^ diagnostic context.diagnostics) true (List.exists(fun(d:Compile.diagnostic)->d.severity="error" && d.code=code)context.diagnostics)
let source_signatures ()=project(fun _ _ path ->
 accepts path source;
 List.iter(fun(a,b)->refuses "MIG021" path (replace a b source))[
  "fn oldNote()", "fn oldNote(extra: Int)";
  "Maybe Schema.Notes.V1.Note", "Maybe Schema.Notes.VCurrent.Note";
  "Maybe Schema.Notes.V1.Note", "Maybe (Maybe Schema.Notes.V1.Note)";
  "fixtures: [oldNote]", "fixtures: [convert]"];
 refuses "MIG023" path(replace "fixtures: [oldNote]" "fixtures: [oldNote, oldNote]" source);
 refuses "MIG021" path(replace "Nothing -> Nothing" "Nothing -> fail 400 \"fixture failed\"" source))
let custom_maybe ()=project(fun _ save path ->
 ignore(save "migrations/notes/carrier.tesl" {|module Schema.Notes.Migrate.Carrier exposing [Maybe(..)]
type Maybe a =
  | Missing
  | Present value: a
|});
 let s=source |> replace "import Tesl.Maybe exposing [Maybe(..)]" "import Schema.Notes.Migrate.Carrier exposing [Maybe(..)]\nimport Tesl.Maybe exposing [Nothing, Something]" in
 refuses "MIG021" path s)
let run_native ?(setup=(fun _ -> ())) ?(captured=false) ?(app_module="App") ~expected s = project(fun root save path ->
 setup save;
 accepts path s;ignore(save "migrations/notes/v2.tesl" s);
 let compilation=if not captured then Compile.compile_go_file path else (
  let abi=Result.get_ok(Migration_abi.current()) in
  let seal file=
   let inventory=match Migration_inventory.load_with_compatibility
     ~stored_value_compatibility:(Some(Migration_abi.stored_value_compatibility abi))
     ~compiler_abi:(Migration_abi.id abi) ~root_file:file with Ok i->i | Error e->fail e.message in
   match Migration_seal.create ~project_root:root inventory with Ok x->x | Error e->fail e.message in
  let header=match Migration_header.create
    ~previous:(seal(Filename.concat root "schema/notes/v1.tesl"))
    ~current:(seal(Filename.concat root "schema/notes/v-current.tesl")) with
   | Ok h->h | Error _->fail "could not generate captured fixture header" in
  write path (Migration_header.encode header ^ s);
  let app={|module App exposing []
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import Schema.Notes.VCurrent
database Main = Database {
 schema: Schema.Notes.VCurrent
 migrations: Schema.Notes.Migrate
 backend: Postgres (PostgresConfig {
  namespace: "notes"
  dbName: "unused"
  user: "unused"
  password: "unused"
  connection: TcpConnection { host: "127.0.0.1", port: 5432 }
 })
}
|} in
  let app=replace "module App exposing []" ("module " ^ app_module ^ " exposing []") app in
  let file=save (app_module ^ ".tesl") app in
  Compile.compile_row_source_artifacts file app) in
 let artifacts=match compilation with
  | Compile.GoFailure ds->fail(diagnostic ds) | GoSuccess a->a in
 check bool "automatic fixture file exists without user test" true
  (List.exists(fun(a:Emit_go.artifact)->a.path="internal/teslmigrationfixtures/fixtures_test.go")artifacts);
 List.iter(fun(a:Emit_go.artifact)->ignore(save ("out/" ^ a.path) a.contents))artifacts;
 List.iter(fun p->remove(Filename.concat root p))["schema";"migrations";"tesl.toml"];
 if captured then remove(Filename.concat root (app_module ^ ".tesl"));
 let command=Printf.sprintf "cd %s && GOMAXPROCS=2 go test -race -p 1 -count=1 -timeout=60s -v ./... 2>&1" (Filename.quote(Filename.concat root "out")) in
 let channel=Unix.open_process_in command in let log=In_channel.input_all channel in
 let status=Unix.close_process_in channel in
 if expected then (match status with Unix.WEXITED 0 ->
  check bool "generated fixture actually ran" true(Compile.string_contains log "--- PASS: TestTeslMigrationFixture")
  | _->fail log)
 else (
  check bool "Nothing fails the test process" true(status<>Unix.WEXITED 0);
  check bool "failure names actual fixture" true(Compile.string_contains log "migration fixture Schema.Notes.Migrate.V2.oldNote: fixture returned Nothing")))
let native_direct ()=
 let first=Str.search_forward(Str.regexp_string "fn oldNote()")source 0 in
 let last=Str.search_forward(Str.regexp_string "fn convert(")source first in
 let original=String.sub source first (last-first) in
 let direct={|fn oldNote() -> Schema.Notes.V1.Note =
  Schema.Notes.V1.Note { id: "one", title: "retained" }
|} in
 let setup save=
  let unproven owner extra=schema owner extra |> replace "  title: String ::: ValidTitle title\n" "  title: String\n" in
  ignore(save "schema/notes/v1.tesl" (unproven "Schema.Notes.V1" ""));
  ignore(save "schema/notes/v-current.tesl" (unproven "Schema.Notes.VCurrent" "  count: Int\n")) in
 run_native ~setup ~expected:true (replace original direct source)
let native_some ()=run_native ~expected:true source
let native_none ()=run_native ~expected:false(replace "tryTitle \"retained\"" "tryTitle \"\"" source)
let native_reject ()=run_native ~expected:true(replace "  Row (Schema.Notes.VCurrent.Note { id: old.id, title: old.title, count: 7 })" "  Reject \"intentional migration rejection\"" source)
let helper_fixture () =
 let fixture_start=String.index_from source (Str.search_forward(Str.regexp_string "fn oldNote()")source 0) 'f' in
 let callback_start=Str.search_forward(Str.regexp_string "fn convert(")source fixture_start in
 let fixture=String.sub source fixture_start (callback_start-fixture_start) in
 let helper="module Schema.Notes.Migrate.Helpers exposing [oldNote]\nimport Tesl.Maybe exposing [Maybe(..)]\nimport Schema.Notes.V1\n" ^ fixture in
 let s=source |> replace fixture "" |> replace "import Schema.Notes.V1" "import Schema.Notes.Migrate.Helpers exposing [oldNote]\nimport Schema.Notes.V1" in
 run_native ~setup:(fun save->ignore(save "migrations/notes/helpers.tesl" helper)) ~expected:true s
let checked_fixture_identity ()=project(fun _ _ path ->
 let m=match Parser.parse_module path source with Ok m->m | Err e->fail e.msg in
 let checked=match Migration_declaration.check ~compiler_abi:"fixture-test" ~source m with
  | Ok(Some d)->Option.get(Migration_declaration.transforms d)
  | _->fail "missing checked fixture" in
 let row=List.hd(Migration_transform.rows checked) in
 let fixture=List.hd row.fixtures in
 check bool "exact checked fixture is optional" true(Migration_transform.fixture_optional checked row fixture);
 let rejects run=try ignore(run());false with _->true in
 check bool "equal-looking row has no fixture binding" true(rejects(fun()->Migration_transform.fixture_optional checked {row with fixtures=row.fixtures} fixture));
 check bool "equal-looking function has no fixture binding" true(rejects(fun()->Migration_transform.fixture_optional checked row {fixture with identity=fixture.identity}));
 write path (source ^ "\n# edited after capture\n");
 check bool "source edit invalidates fixture classifier" true(rejects(fun()->Migration_transform.fixture_optional checked row fixture)))
let checked path s =
 write path s;
 let m=match Parser.parse_module path s with Ok m->m | Err e->fail e.msg in
 match Migration_declaration.check ~compiler_abi:(Migration_abi.id(Result.get_ok(Migration_abi.current()))) ~source:s m with
 | Ok(Some d)->Option.get(Migration_declaration.transforms d)
 | _->fail "missing checked transformation"
let fixture_graph_identity ()=project(fun _ save path ->
 let helper={|module Schema.Notes.Migrate.Weight exposing [seven]
import Tesl.Prelude exposing [Int]
fn seven() -> Int = 7
|} in
 let helper_path=save "migrations/notes/weight.tesl" helper in
 let source=source |> replace "import Schema.Notes.V1" "import Schema.Notes.Migrate.Weight\nimport Schema.Notes.V1" |> replace "count: 7" "count: Schema.Notes.Migrate.Weight.seven()" in
 let checked=checked path source in
 let root=Migration_transform.root checked in
 let originals=match Compile.local_dependency_modules ~entry_source:source path root with
  | Compile.GoDeps d -> d.originals | GoDepsError e -> fail e in
 let parse s=match Parser.parse_module helper_path s with Ok m->m | Err e->fail e.msg in
 let emit originals=let graph=match Go_graph_lowering.lower ~entry:root originals with Ok g->g | Error e->fail e in
  Emit_go.compile_project ~fixture_graph:graph ~migration_fixtures:[checked]
   ~entry:(Go_graph_lowering.entry graph)(Go_graph_lowering.modules graph) in
 (match emit originals with Ok _->() | Error errors->fail(String.concat "; " (List.map(fun(e:Emit_go.emit_error)->e.message)errors)));
 let altered=List.map(fun(m:Ast.module_form)->if m.source_file=helper_path then parse(replace "= 7" "= 8" helper) else m)originals in
 (match emit altered with
 | Error errors -> check bool "exact complete fixture graph refusal" true(List.exists(fun(e:Emit_go.emit_error)->Compile.string_contains e.message "fixture" && Compile.string_contains e.message "graph")errors)
 | Ok _ -> fail "altered transitive helper emitted under original checked fixture closure");
 (* A missing import may fail before the fixture guard; either path must refuse. *)
 let missing=List.filter(fun(m:Ast.module_form)->m.source_file<>helper_path)originals in
 match emit missing with
 | Error errors -> check bool "missing transitive helper refuses emission" true(errors<>[])
 | Ok _ -> fail "missing transitive helper emitted under original checked fixture closure")
let publication_guards ()=project(fun _ _ path ->
 let check_error = function
  | Error errors -> check bool "source guard reports MIG013" true(List.exists(fun(e:Migration_sparse.error)->e.code="MIG013")errors)
  | Ok _ -> fail "changed fixture sources reached publication" in
 let checked=checked path source in
 let calls=ref 0 in
 write path(source ^ "\n# before emission\n");
 check_error(Migration_transform.with_fixture_sources [checked](fun()->incr calls));
 check int "stale source never enters emitter" 0 !calls;
 write path source;
 check_error(Migration_transform.with_fixture_sources [checked](fun()->incr calls;write path(source ^ "\n# during emission\n")));
 check int "publication guard never replays emitter" 1 !calls)
let closure_identity ()=project(fun _ _ path ->
 let hash s=let checked=checked path s in match Migration_transform_link.link checked with
  | Ok linked -> Migration_transform_link.digest linked,Migration_transform_link.behavior_digest linked
  | Error e->fail e.message in
 let original=hash source in
 let changed=hash(replace "tryTitle \"retained\"" "tryTitle \"different\"" source) in
 check bool "optional fixture body changes descriptor" false(fst original=fst changed);
 check bool "optional fixture body changes checked behavior" false(snd original=snd changed))
let native_captured ()=run_native ~captured:true ~expected:true source
let native_package_collision ()=run_native ~captured:true ~app_module:"TeslMigrationFixtures" ~expected:true source
let native_captured_none ()=run_native ~captured:true ~expected:false(replace "tryTitle \"retained\"" "tryTitle \"\"" source)
let ()=run "Migration fixtures" ["fixtures",[
 test_case "exact optional entity and pure proof construction" `Quick source_signatures;
 test_case "user Maybe is not builtin fixture authority" `Quick custom_maybe;
 test_case "fixture selection retains exact row/source authority" `Quick checked_fixture_identity;
 test_case "emission scope checks sources before and after once" `Quick publication_guards;
 test_case "optional fixture closure remains in both canonical identities" `Quick closure_identity;
 test_case "helper fixture and callback retain distinct private owners" `Quick helper_fixture;
 test_case "automatic Some fixture runs without user tests or sources" `Quick native_some;
 test_case "Nothing is a named generated test failure" `Quick native_none;
 test_case "representative rejection remains a valid smoke result" `Quick native_reject;
 test_case "captured App shares optional fixture execution" `Quick native_captured;
 test_case "captured App Nothing fails without source or PG" `Quick native_captured_none;
 test_case "user TeslMigrationFixtures package cannot collide" `Quick native_package_collision;
 test_case "direct old entity fixture runs without source or user tests" `Quick native_direct;
 test_case "checked fixture requires exact transitive emission graph" `Quick fixture_graph_identity;
]]
