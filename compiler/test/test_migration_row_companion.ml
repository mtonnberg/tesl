open Alcotest
module D = Migration_declaration
module T = Migration_transform
module R = Migration_transform_rules
module S = Migration_sparse
let old = {|module Schema.Notes.V1 exposing [Note]
import Tesl.Prelude exposing [String]
entity Note table "notes" primaryKey id { id: String, author: String, title: String }
|}
let fresh = {|module Schema.Notes.VCurrent exposing [Note]
import Tesl.Prelude exposing [String, Int]
entity Note table "notes" primaryKey id { id: String, owner: String, title: String, count: Int }
|}
let source = {|module Schema.Notes.Migrate.V2 exposing [migration, oldNote]
import Tesl.Prelude exposing [String, Int, Bool(..)]
import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Migrated(..)]
import Schema.Notes.V1
import Schema.Notes.VCurrent
migration = Migration {
  from: Schema.Notes.V1
  to: Schema.Notes.VCurrent
  same: []
  fixtures: [oldNote]
  entities: { Note: Migrate convert [Rename author owner] }
}
fn convert(old: Schema.Notes.V1.Note) -> Migrated Schema.Notes.VCurrent.Note =
  if old.id == "reject" then
    Reject "source rejected"
  else
    Row (Schema.Notes.VCurrent.Note { id: old.id, owner: old.author, title: old.title, count: amount() })
fn amount() -> Int = 7
fn oldNote() -> Schema.Notes.V1.Note =
  Schema.Notes.V1.Note { id: "retained", author: "writer", title: "hello" }
test "actual pure transformation helper" {
  case convert (oldNote()) of
    Row row -> expect row.owner == "writer"
    Reject reason -> expect False
}
|}
let rec mkdir p = if not (Sys.file_exists p) then (mkdir (Filename.dirname p); Unix.mkdir p 0o700)
let write p s = mkdir (Filename.dirname p); Out_channel.with_open_bin p (fun o -> output_string o s)
let rec remove p = if (Unix.lstat p).Unix.st_kind=Unix.S_DIR then (Array.iter (fun n -> remove (Filename.concat p n)) (Sys.readdir p); Unix.rmdir p) else Sys.remove p
let project ?(before=old) ?(after=fresh) f =
  let root=Filename.temp_file "tesl-transform-source-" ".dir" in Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let save p s = let file=Filename.concat root p in write file s; file in
    ignore (save "tesl.toml" ""); ignore (save "schema/notes/v1.tesl" before); ignore (save "schema/notes/v-current.tesl" after);
    let file=save "migrations/notes/v2.tesl" source in f root save file)
let describe ds = String.concat "\n" (List.map (fun (d:Compile.diagnostic) -> d.code ^ ": " ^ d.message) ds)
let errors path s = (Compile.agent_context_result_source path s).diagnostics |> List.filter (fun (d:Compile.diagnostic) -> d.severity="error")
let accepts path s = match errors path s with [] -> () | ds -> fail (describe ds)
let contains text needle = Compile.string_contains text needle

module RH=Migration_row_history
module P=Migration_program
let app = {|module App exposing []
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import Schema.Notes.VCurrent
database Main = Database {
 schema: Schema.Notes.VCurrent
 migrations: Schema.Notes.Migrate
 backend: Postgres (PostgresConfig {
  namespace: "notes"
  dbName: "unused"
  user: "unused"
  password: "secret-sentinel"
  connection: TcpConnection { host: "127.0.0.1", port: 5432 }
 })
}
|}
let load file =
 let abi=Result.get_ok (Migration_abi.current ()) in
 match Migration_inventory.load_with_compatibility
   ~stored_value_compatibility:(Some (Migration_abi.stored_value_compatibility abi))
   ~compiler_abi:(Migration_abi.id abi) ~root_file:file with
 | Ok i -> i | Error e -> fail e.message
let seal root file=match Migration_seal.create ~project_root:root (load file) with
 | Ok s -> s | Error e -> fail e.message
let seal_edge root path =
 let before=Filename.concat root "schema/notes/v1.tesl" and after=Filename.concat root "schema/notes/v-current.tesl" in
 let header=match Migration_header.create ~previous:(seal root before) ~current:(seal root after) with
  | Ok h -> h | Error errors -> fail (String.concat "\n" (List.map (fun (e:S.error) -> e.message) errors)) in
 write path (Migration_header.encode header ^ source)
let get = function Ok value -> value | Error errors -> fail (String.concat "\n" (List.map (fun (e:S.error) -> e.code ^ ": " ^ e.message) errors))
let capture root f =
 let file=Filename.concat root "app.tesl" in
 let source=Source_input.read file in
 let entry=match Parser.parse_module file source with Ok m -> m | Err e -> fail e.msg in
 P.with_source_history ~entry ~source (function Some h -> f h | None -> fail "missing source history")
let emit file = match Compile.compile_row_source_artifacts file (Source_input.read file) with
 | Compile.GoSuccess a -> a | Compile.GoFailure d -> fail (describe d)
let artifact path values=(List.find (fun (a:Emit_go.artifact) -> a.path=path) values).contents
let native ?source_root ?(extra_tests=[]) ?(test="") artifacts =
 let root=Filename.temp_dir "tesl-row-native-" "" in
 Fun.protect ~finally:(fun () -> remove root) (fun () ->
  List.iter (fun (a:Emit_go.artifact) -> if not (Filename.check_suffix a.path ".json") then
   write (Filename.concat root a.path) a.contents) artifacts;
  List.iter (fun (path,source) -> write (Filename.concat root path) source) extra_tests;
  let rec source_files path=if (Unix.lstat path).Unix.st_kind=Unix.S_DIR then
   Array.to_list (Sys.readdir path) |> List.concat_map (fun name -> source_files (Filename.concat path name))
   else if Filename.check_suffix path ".tesl" then [path,In_channel.with_open_bin path In_channel.input_all] else [] in
  let hidden=Option.fold ~none:[] ~some:source_files source_root in
  List.iter (fun (path,_) -> Sys.remove path) hidden;
  Fun.protect ~finally:(fun () -> List.iter (fun (path,bytes) -> write path bytes) hidden) (fun () ->
  if test<>"" then write (Filename.concat root "internal/teslmodapp/migration_registration_test.go") test;
  let log=Filename.concat root "native.log" in
  let status=Sys.command (Printf.sprintf "cd %s && timeout 180s go test -p 1 -race -timeout=120s -count=1 ./... > %s 2>&1" (Filename.quote root) (Filename.quote log)) in
  if status<>0 then fail (In_channel.with_open_bin log In_channel.input_all)))
let native_test = {|package teslmodapp
import (
 "testing"
 old "tesl.generated/teslmodapp/internal/teslmodschemanotesv1"
 "tesl.generated/teslmodapp/internal/teslrt"
)
func TestCompiledRow(t *testing.T) {
 input := old.Note{Id:"kept", Author:"writer", Title:"hello"}
 if _, err := MainDatabaseCompiledRowTransform0.Run(input); err == nil { t.Fatal("unsealed callback ran") }
 history, ok := MainDatabase.CompiledMigrationHistory()
 if !ok { t.Fatal("missing actual source companion") }
 if _, err := history.ExpansionPlan(1); err == nil { t.Fatal("source metadata gained expansion authority") }
 if err := teslrt.PreflightApplicationDatabases(MainDatabase); err != nil { t.Fatal(err) }
 input.Id="reject"
 rejected, rejectErr := MainDatabaseCompiledRowTransform0.Run(input)
 if rejectErr != nil || rejected.Tag != teslrt.MigratedReject || rejected.RejectReason != "source rejected" { t.Fatal("Tesl Reject branch lost", rejected, rejectErr) }
 input.Id="kept"
 result, err := MainDatabaseCompiledRowTransform0.Run(input)
 if err != nil || result.Tag != teslrt.MigratedRow || result.RowValue.Id != "kept" || result.RowValue.Owner != "writer" || result.RowValue.Title != "hello" || result.RowValue.Count.String() != "7" {
  t.Fatalf("wrong row: %#v %v", result, err)
 }
}
|}
let native_registration_tests = {|package rowregistrationtest

import (
	"os"
	"os/exec"
	"strings"
	"sync"
	migrate "tesl.generated/teslmodapp/internal/teslmodschemanotesmigratev2"
	before "tesl.generated/teslmodapp/internal/teslmodschemanotesv1"
	after "tesl.generated/teslmodapp/internal/teslmodschemanotesvcurrent"
	runtime "tesl.generated/teslmodapp/internal/teslrt"
	"testing"
)

// Every scenario starts a fresh native process. The metadata and private Tesl
// function bridge are the compiler's actual generated artifacts; this harness
// never injects a history JSON document, semantic hash, or erased callback.
func TestCompiledRowRegistration(t *testing.T) {
	for _, scenario := range []string{"missing", "zero-ref", "unknown-ref", "wrong-database", "wrong-nominal", "nil", "duplicate", "atomic-seal", "late-registration", "invalid-result", "reject", "concurrent"} {
		t.Run(scenario, func(t *testing.T) {
			cmd := exec.Command(os.Args[0], "-test.run=^TestCompiledRowScenario$")
			cmd.Env = append(os.Environ(), "TESL_ROW_REGISTRATION_SCENARIO="+scenario)
			out, err := cmd.CombinedOutput()
			if err != nil {
				t.Fatalf("%s: %v\n%s", scenario, err, out)
			}
		})
	}
}
func TestCompiledRowScenario(t *testing.T) {
	scenario := os.Getenv("TESL_ROW_REGISTRATION_SCENARIO")
	if scenario == "" {
		t.Skip("subprocess scenario")
	}
	db := runtime.RegisterDatabaseMigrationHistory(runtime.RegisterDatabaseIdentity("App.Main", runtime.NewDatabase("Main", runtime.PostgresConfig{Schema: "notes"}, nil)), "Schema.Notes")
	ref := runtime.LookupCompiledRowTransform(db, "Schema.Notes", 2, "Note")
	mustPanic := func(run func()) {
		t.Helper()
		defer func() {
			if recover() == nil {
				t.Fatal("invalid registration succeeded")
			}
		}()
		run()
	}
	original := before.Note{Id: "id", Author: "writer", Title: "keep"}
	switch scenario {
	case "missing":
		if err := runtime.PreflightApplicationDatabases(db); err == nil {
			t.Fatal("missing callback passed preflight")
		}
		return
	case "zero-ref":
		mustPanic(func() {
			runtime.RegisterCompiledRowTransform[before.Note, after.Note](runtime.PgRowTransformSourceRef{}, migrate.TeslCompiledRowCallback)
		})
		return
	case "unknown-ref":
		mustPanic(func() { runtime.LookupCompiledRowTransform(db, "Schema.Notes", 2, "Other") })
		return
	case "wrong-database":
		other := runtime.RegisterDatabaseMigrationHistory(runtime.NewDatabase("Other", runtime.PostgresConfig{Schema: "notes"}, nil), "Schema.Notes")
		mustPanic(func() { runtime.LookupCompiledRowTransform(other, "Schema.Notes", 2, "Note") })
		return
	case "wrong-nominal":
		mustPanic(func() {
			runtime.RegisterCompiledRowTransform[after.Note, after.Note](ref, func(row after.Note) runtime.Migrated[after.Note] {
				return runtime.Migrated[after.Note]{Tag: runtime.MigratedRow, RowValue: row}
			})
		})
		return
	case "nil":
		mustPanic(func() { runtime.RegisterCompiledRowTransform[before.Note, after.Note](ref, nil) })
		return
	}
	callback := migrate.TeslCompiledRowCallback
	if scenario == "invalid-result" {
		callback = func(before.Note) runtime.Migrated[after.Note] { return runtime.Migrated[after.Note]{Tag: 99} }
	}
	if scenario == "reject" {
		callback = func(before.Note) runtime.Migrated[after.Note] {
			return runtime.Migrated[after.Note]{Tag: runtime.MigratedReject, RejectReason: "test-reject"}
		}
	}
	handle := runtime.RegisterCompiledRowTransform[before.Note, after.Note](ref, callback)
	if _, err := handle.Run(original); err == nil {
		t.Fatal("callback ran before sealing")
	}
	if scenario == "duplicate" {
		mustPanic(func() { runtime.RegisterCompiledRowTransform[before.Note, after.Note](ref, callback) })
		return
	}
	if scenario == "atomic-seal" {
		if err := runtime.PreflightApplicationDatabases(db, nil); err == nil {
			t.Fatal("invalid second application target passed")
		}
		if _, err := handle.Run(original); err == nil {
			t.Fatal("failed batch sealed first callback")
		}
	}
	if err := runtime.PreflightApplicationDatabases(db); err != nil {
		t.Fatal(err)
	}
	if scenario == "late-registration" {
		mustPanic(func() { runtime.RegisterCompiledRowTransform[before.Note, after.Note](ref, callback) })
		return
	}
	result, err := handle.Run(original)
	if scenario == "invalid-result" {
		if err == nil || !strings.Contains(err.Error(), "invalid Migrated tag") {
			t.Fatal("unknown result tag accepted", err)
		}
		return
	}
	if err != nil {
		t.Fatal(err)
	}
	if scenario == "reject" {
		if result.Tag != runtime.MigratedReject || result.RejectReason != "test-reject" {
			t.Fatal("rejection did not survive typed handle")
		}
		return
	}
	if result.Tag != runtime.MigratedRow || result.RowValue.Owner != "writer" || result.RowValue.Title != "keep" {
		t.Fatal("actual compiled callback returned wrong row", result)
	}
	if scenario == "concurrent" {
		var wg sync.WaitGroup
		for range 8 {
			wg.Go(func() {
				for range 20 {
					row, err := handle.Run(original)
					if err != nil || row.Tag != runtime.MigratedRow || row.RowValue.Owner != "writer" {
						t.Error("concurrent typed callback failed", err)
					}
				}
			})
		}
		wg.Wait()
	}
}
|}
let source_companion () = project (fun root save path ->
 seal_edge root path;
 let app=save "app.tesl" app in accepts app (Source_input.read app);
 get (capture root (fun captured ->
  let history=List.assoc "App.Main" (P.row_histories captured) in
  check (list int) "generation advance" [1;2] (List.map (fun (v:RH.version) -> (List.hd v.entities).generation) (RH.versions history));
  check int "callback completeness" 1 (List.length (RH.bindings history));
  let b=List.hd (RH.bindings history) in
  check string "private callback bound" "convert" (Option.get (RH.row b).function_binding).declaration.name;
  check bool "origin1 execution errors retained" true (match (List.hd (List.hd (P.databases (P.source_program captured))).origins).steps with Error _ -> true | _ -> false)));
 let artifacts=emit app in
 native ~source_root:root ~extra_tests:["internal/rowregistrationtest/registration_test.go",native_registration_tests] ~test:native_test artifacts;
 let json=artifact "migration-source-history.json" artifacts in
 check bool "source envelope distinct" true (contains json "compiled-migration-source-history");
 check bool "secret omitted" false (contains json "secret-sentinel");
 check bool "Go nominal owner derived" true (contains json "tesl.generated/teslmodapp/internal/teslmodschemanotesv1");
 let generated=artifact "internal/teslmodapp/migration_rows_MainDatabase_generated.go" artifacts in
 check bool "explicit generics" true (contains generated "RegisterCompiledRowTransform[teslmodschemanotesv1.Note, teslmodschemanotesvcurrent.Note]");
 check bool "private function reference" true (contains generated "teslmodschemanotesmigratev2.TeslCompiledRowCallback");
 match Compile.compile_go_file app with
 | Compile.GoSuccess _ -> fail "public compile acquired Transform execution authority"
 | Compile.GoFailure diagnostics -> check bool "public execution refusal" true (List.exists (fun (d:Compile.diagnostic) -> d.code="MIG016") diagnostics))
let storage_node ()=project (fun root _ _ ->
 let schema=load (Filename.concat root "schema/notes/v-current.tesl") in
 let storage=get (Migration_storage.describe schema) in
 check string "same canonical digest" (Migration_storage.digest storage)
  (Migration_canonical.digest Migration_canonical.Migration (Migration_storage.node storage)))
let generation_bounds ()=
 check int "last valid generation" 32767 (get (RH.next_generation 32766));
 List.iter (fun value -> match RH.next_generation value with Error _ -> () | Ok _ -> fail "invalid generation advanced") [-1;0;32767;max_int]
let replace a b = Str.global_replace (Str.regexp_string a) b
let read p=In_channel.with_open_bin p In_channel.input_all
let parsed path source=match Parser.parse_module path source with Ok m -> m | Err e -> fail e.msg
let source_body = {|module Schema.Notes.Migrate.V2 exposing [migration]
import Tesl.Migration exposing [Migration, Entity(..), Rule(..)]
import Schema.Notes.V1
import Schema.Notes.VCurrent
migration = Migration {
 from: Schema.Notes.V1
 to: Schema.Notes.VCurrent
 same: []
 fixtures: []
 entities: {}
}
|}
let reseal root path body =
 let abi=Result.get_ok (Migration_abi.current ()) in
 let before=Filename.concat root "schema/notes/v1.tesl" and after=Filename.concat root "schema/notes/v-current.tesl" in
 let header=get (Migration_header.create ~previous:(seal root before) ~current:(seal root after)) in
 write path (Migration_header.encode header ^ body);
 match D.check ~compiler_abi:(Migration_abi.id abi) ~stored_value_compatibility:(Migration_abi.stored_value_compatibility abi)
  ~source:(read path) (parsed path (read path)) with
 | Ok (Some d) -> d | Ok None -> fail "missing declaration" | Error errors -> fail (String.concat "\n" (List.map (fun (e:S.error) -> e.message) errors))
let lowered source =
 let originals=P.source_modules source |> List.map fst in
 List.map (fun m -> match Migration_schema.lower_module ~modules:originals m with
 | Ok lowered -> Migration_form.erase lowered | Error _ -> fail "lowering") originals
let refuse = function Ok _ -> fail "expected refusal" | Error _ -> ()
let baseline_project f = project (fun root save path ->
 remove path;remove (Filename.concat root "schema/notes/v1.tesl");
 let app=save "app.tesl" app in f root save app)
let native_empty_test = {|package teslmodapp
import (
 "testing"
 "tesl.generated/teslmodapp/internal/teslrt"
)
func TestEmptyCompiledRows(t *testing.T) {
 if err:=teslrt.PreflightApplicationDatabases(MainDatabase); err!=nil {t.Fatal(err)}
}
|}
let baseline_native ()=baseline_project (fun root _ app ->
 let artifacts=emit app in native ~source_root:root ~test:native_empty_test artifacts;
 check bool "no unused callback file" false (List.exists (fun (a:Emit_go.artifact) -> contains a.path "migration_rows_") artifacts);
 get (capture root (fun h -> check int "all baseline entities generation one" 1
  (List.hd (List.hd (RH.versions (List.assoc "App.Main" (P.row_histories h)))).entities).generation)))
let additive_native ()=project ~after:(replace "V1" "VCurrent" old) (fun root save path ->
 ignore (reseal root path source_body);
 let app=save "app.tesl" app in
 get (capture root (fun h ->
  check (list int) "unchanged generation" [1;1] (List.map (fun (v:RH.version) -> (List.hd v.entities).generation)
    (RH.versions (List.assoc "App.Main" (P.row_histories h))))));
 native ~source_root:root ~test:native_empty_test (emit app))
let source_drift ()=baseline_project (fun root save _ ->
 refuse (capture root (fun _ -> ignore (save "schema/notes/v-current.tesl" (fresh ^ "# changed\n")))))
let escaped_source ()=baseline_project (fun root _ _ ->
 let source=get (capture root Fun.id) in
 refuse (P.verify_source_history source (lowered source));
 match Emit_go.compile_project ~row_source:source ~entry:(List.hd (lowered source)) (lowered source) with
 | Error _ -> () | Ok _ -> fail "escaped source-only value emitted artifacts")
let altered_graph ()=project (fun root save path ->
 seal_edge root path;ignore (save "app.tesl" app);
 get (capture root (fun source ->
  let modules=lowered source in
  get (P.verify_source_history source modules);
  refuse (P.verify_source_history source (List.tl modules));
  let changed=List.map (fun (m:Ast.module_form) ->
   if m.module_name<>"Schema.Notes.Migrate.V2" then m else
   Migration_form.erase (parsed path (replace "fn amount() -> Int = 7" "fn amount() -> Int = 8" (read path)))) modules in
  refuse (P.verify_source_history source changed);
  let entry=List.find (fun (m:Ast.module_form) -> m.module_name="App") modules in
  match Emit_go.compile_project ~row_source:source ~entry changed with
   | Error _ -> () | Ok _ -> fail "altered fixture/helper graph emitted under old link")))
let marker_collision ()=baseline_project (fun _ save app ->
 ignore (save "schema/notes/v-current.tesl" (replace "count: Int" "_tesl_v: Int" fresh));
 match Compile.compile_row_source_artifacts app (read app) with
 | Compile.GoFailure ds -> check bool "reserved marker refusal" true (List.exists (fun (d:Compile.diagnostic) -> contains d.message "_tesl_v") ds)
 | _ -> fail "user column claimed generation marker")
let derived_refusal ()=project (fun root save path ->
 let body=source_body |> replace "entities: {}" "entities: { Note: Derived [Rename author owner, Default count 7] }" in
 ignore (reseal root path body);let app=save "app.tesl" app in
 get (capture root (fun source ->
  let h=List.assoc "App.Main" (P.row_histories source) in
  check (list int) "derived metadata judged" [1;2] (List.map (fun (v:RH.version) -> (List.hd v.entities).generation) (RH.versions h));
  refuse (RH.require_migrate_callbacks h)));
 match Compile.compile_row_source_artifacts app (read app) with
 | Compile.GoFailure ds -> check bool "adapter refusal" true (List.exists (fun (d:Compile.diagnostic) -> contains d.message "Derived") ds)
 | _ -> fail "Derived fabricated callable adapter")
let same_owner_databases ()=project (fun root save path ->
 seal_edge root path;
 let extra=String.sub app (Str.search_forward (Str.regexp_string "database Main") app 0)
  (String.length app-Str.search_forward (Str.regexp_string "database Main") app 0)
  |> replace "database Main" "database Other" |> replace "namespace: \"notes\"" "namespace: \"other\"" in
 let app=save "app.tesl" (app ^ extra) in
 match Compile.compile_row_source_artifacts app (read app) with
 | Compile.GoFailure ds -> check bool (describe ds) true
   (List.exists (fun (d:Compile.diagnostic) -> contains d.message "belongs to two databases") ds)
 | _ -> fail "broadened unsupported same-owner database behavior")
let chain_extension root =
 let abi=Result.get_ok (Migration_abi.current ()) in
 match Migration_generate.start_with_compatibility
  ~stored_value_compatibility:(Some (Migration_abi.stored_value_compatibility abi)) ~compiler_abi:(Migration_abi.id abi)
  ~project_root:root ~family:"Schema.Notes" ~version:2 ~documents:[] with
 | Ok p -> List.iter (fun (e:Migration_manifest.edit) -> write e.path e.after) (Migration_manifest.edits p.manifest)
 | Error errors -> fail (String.concat "\n" (List.map (fun (e:Migration_generate.error) -> e.message) errors))
let after_transform_additive ()=project (fun root save path ->
 seal_edge root path;ignore (save "app.tesl" app);chain_extension root;
 get (capture root (fun source ->
  let h=List.assoc "App.Main" (P.row_histories source) in
  check (list int) "schema versions do not assign generation" [1;2;2]
   (List.map (fun (v:RH.version) -> (List.hd v.entities).generation) (RH.versions h));
  check int "one retained callback" 1 (List.length (RH.bindings h))));
 native ~source_root:root (emit (Filename.concat root "app.tesl")))
let final_additive_drift ()=project (fun root save path ->
 seal_edge root path;ignore (save "app.tesl" app);chain_extension root;
 refuse (capture root (fun _ -> ignore (save "schema/notes/v-current.tesl" (fresh ^ "# changed final additive\n")))))
let quoted_reordered ()=project
 ~before:(old |> replace "table \"notes\"" "table \"odd\\\"notes\"" |> replace "id: String, author: String, title: String" "title: String, author: String, id: String")
 ~after:(fresh |> replace "table \"notes\"" "table \"odd\\\"notes\"" |> replace "id: String, owner: String, title: String, count: Int" "count: Int, title: String, id: String, owner: String")
 (fun root save path -> seal_edge root path;let app=save "app.tesl" app in native ~source_root:root ~test:native_test (emit app))

let same_fact_source schema = schema
 |> replace "exposing [Note]" "exposing [Note, ValidTitle, titleProof]"
 |> replace "entity Note" "fact ValidTitle (value: String)\nestablish titleProof(value: String) -> Fact (ValidTitle value) = ValidTitle value\nentity Note"
 |> replace "title: String" "title: String ::: ValidTitle title"
let same_helper_native ()=project ~before:(same_fact_source old) ~after:(same_fact_source fresh) (fun root save path ->
 let source=source |> replace "Rule(..), Migrated(..)" "Rule(..), Same(..), Migrated(..)"
  |> replace "same: []" "same: [Same Schema.Notes.V1.ValidTitle Schema.Notes.VCurrent.ValidTitle]"
  |> replace "fn oldNote() -> Schema.Notes.V1.Note =" "fn oldNote() -> Schema.Notes.V1.Note =\n  let title = \"hello\"\n  let proof = Schema.Notes.V1.titleProof title"
  |> replace "title: \"hello\"" "title: title ::: proof" in
 let index=Str.search_forward (Str.regexp_string "fn convert") source 0 in
 let head=String.sub source 0 index and body=String.sub source index (String.length source-index) in
 let import_start=Str.search_forward (Str.regexp_string "import Tesl.Prelude") head 0 in
 let migration_start=Str.search_forward (Str.regexp_string "migration =") head 0 in
 let imports=String.sub head import_start (migration_start-import_start) in
 let helper="module Schema.Notes.Migrate.Helpers exposing [convert, oldNote]\n" ^ imports ^ body in
 let helper_path=save "migrations/notes/helpers.tesl" helper in
 check bool "public standalone helper lacks root Same context" true (List.exists (fun (d:Compile.diagnostic) -> d.code="V001") (errors helper_path helper));
 let body=head |> replace "exposing [migration, oldNote]" "exposing [migration]"
  |> replace "import Tesl.Prelude" "import Schema.Notes.Migrate.Helpers exposing [convert, oldNote]\nimport Tesl.Prelude" in
 ignore (reseal root path body);
 let app=save "app.tesl" app in accepts app (read app);
 native ~source_root:root ~test:native_test (emit app))
let multi_database_native ()=project (fun root save path ->
 seal_edge root path;
 let replace_family=replace "Schema.Notes" "Schema.Tasks" in
 let before=save "schema/tasks/v1.tesl" (replace_family old) in
 let after=save "schema/tasks/v-current.tesl" (replace_family fresh) in
 let header=get (Migration_header.create ~previous:(seal root before) ~current:(seal root after)) in
 ignore (save "migrations/tasks/v2.tesl" (Migration_header.encode header ^ replace_family source));
 ignore (save "second.tesl" (app |> replace "module App exposing []" "module Second exposing []" |> replace_family |> replace "namespace: \"notes\"" "namespace: \"tasks\""));
 let app=save "app.tesl" (replace "import Tesl.Database" "import Second exposing []\nimport Tesl.Database" app) in
 native ~source_root:root ~test:{|package teslmodapp
import (
 "testing"
 second "tesl.generated/teslmodapp/internal/teslmodsecond"
 old "tesl.generated/teslmodapp/internal/teslmodschemanotesv1"
 tasks "tesl.generated/teslmodapp/internal/teslmodschematasksv1"
 "tesl.generated/teslmodapp/internal/teslrt"
)
func TestTwoActualDatabaseBindings(t *testing.T) {
 if err:=teslrt.PreflightApplicationDatabases(MainDatabase,second.MainDatabase); err!=nil {t.Fatal(err)}
 a,e:=MainDatabaseCompiledRowTransform0.Run(old.Note{Id:"one",Author:"notes",Title:"a"})
 b,f:=second.MainDatabaseCompiledRowTransform0.Run(tasks.Note{Id:"two",Author:"tasks",Title:"b"})
 if e!=nil || f!=nil || a.RowValue.Owner!="notes" || b.RowValue.Owner!="tasks" { t.Fatal(a,b,e,f) }
}
|} (emit app))
let multi_entity_generations ()=project
 ~before:(old ^ "entity Unchanged table \"unchanged\" primaryKey id { id: String }\n")
 ~after:(fresh ^ "entity Unchanged table \"unchanged\" primaryKey id { id: String }\nentity Added table \"added\" primaryKey id { id: String }\n")
 (fun root save path ->
  ignore (reseal root path (replace "Note: Migrate convert [Rename author owner]" "Note: Migrate convert [Rename author owner], Added: New" source));
  ignore (save "app.tesl" app);
  get (capture root (fun source ->
   let versions=RH.versions (List.assoc "App.Main" (P.row_histories source)) in
   let values (version:RH.version)=List.map (fun (e:RH.entity) -> e.identity,e.generation) version.entities in
   check (list (pair string int)) "all V1 identities" ["Note",1;"Unchanged",1] (values (List.hd versions));
   check (list (pair string int)) "independent generation judgment" ["Added",1;"Note",2;"Unchanged",1] (values (List.hd (List.tl versions))))))
let lifecycle_refusals ()=project (fun root _ path ->
 let abi=Result.get_ok (Migration_abi.current ()) in
 let check_case name after body =
  write (Filename.concat root "schema/notes/v-current.tesl") after;write path body;
  match D.check ~compiler_abi:(Migration_abi.id abi) ~source:body (parsed path body) with
  | Error errors -> check bool (name ^ " rejected at checked declaration boundary") true
    (List.exists (fun (e:S.error) -> contains e.message "table or primary key identity") errors)
  | Ok None -> fail "missing lifecycle declaration"
  | Ok (Some edge) ->
   match RH.check ~schemas:[load (Filename.concat root "schema/notes/v1.tesl");load (Filename.concat root "schema/notes/v-current.tesl")] ~edges:[edge] with
    | Error _ -> () | Ok _ -> fail (name ^ " received row generation authority") in
 check_case "drop" "module Schema.Notes.VCurrent exposing []\n" (replace "entities: {}" "entities: { Note: Drop }" source_body);
 check_case "table rename" (replace "table \"notes\"" "table \"changed\"" (replace "V1" "VCurrent" old))
  (replace "entities: {}" "entities: { Note: Derived [] }" source_body);
 check_case "primary-key rename" (replace "primaryKey id" "primaryKey author" (replace "V1" "VCurrent" old))
  (replace "entities: {}" "entities: { Note: Derived [] }" source_body))
let jsonb_record_native ()=
 let old_schema=old |> replace "exposing [Note]" "exposing [Note, Metadata]"
  |> replace "entity Note" {|import Tesl.Json exposing [stringCodec]
record Metadata { text: String }
codec Metadata {
 toJson { text -> "oldText" with_codec stringCodec }
 fromJson [ { text <- "oldText" with_codec stringCodec } ]
}
entity Note|}
  |> replace "title: String }" "title: String, metadata: Metadata }" in
 let new_schema=fresh |> replace "exposing [Note]" "exposing [Note, Metadata]"
  |> replace "entity Note" {|import Tesl.Json exposing [stringCodec]
record Metadata { title: String }
codec Metadata {
 toJson { title -> "newTitle" with_codec stringCodec }
 fromJson [ { title <- "newTitle" with_codec stringCodec } ]
}
entity Note|}
  |> replace "count: Int }" "count: Int, metadata: Metadata }" in
 project ~before:old_schema ~after:new_schema (fun root _ path ->
  let source=source |> replace "count: amount() }" "count: amount(), metadata: Schema.Notes.VCurrent.Metadata { title: old.metadata.text } }"
   |> replace "title: \"hello\" }" "title: \"hello\", metadata: Schema.Notes.V1.Metadata { text: \"nested\" } }" in
  let abi=Result.get_ok (Migration_abi.current ()) in
  write path source;
  (match D.check ~compiler_abi:(Migration_abi.id abi) ~source (parsed path source) with
   | Error errors -> check bool "existing JSONB field computation remains explicit refusal" true
      (List.exists (fun (e:S.error) -> e.code="MIG022") errors)
   | _ -> fail "existing-field computation changed without a checked mapping judgment");
  ignore root);
 project ~after:new_schema (fun root save path ->
  let source=source |> replace "count: amount() }" "count: amount(), metadata: Schema.Notes.VCurrent.Metadata { title: old.title } }" in
  ignore (reseal root path source);
  let app=save "app.tesl" app in
  get (capture root (fun source ->
   let versions=RH.versions (List.assoc "App.Main" (P.row_histories source)) in
   let v=List.hd (List.rev versions) in
   let column=List.find (fun (c:Migration_storage.column) -> c.name="metadata") (List.hd v.entities).table.columns in
   check bool "computed record stored as JSONB" true (column.scalar=Migration_storage.Jsonb)));
  native ~source_root:root ~test:(native_test
   |> replace "result.RowValue.Count.String() != \"7\"" "result.RowValue.Count.String() != \"7\" || result.RowValue.Metadata.Title != \"hello\"") (emit app))
let overlay_source_guard ()=baseline_project (fun root _ _ ->
 get (capture root (fun source ->
  let file=Filename.concat root "schema/notes/v-current.tesl" in
  let project_root=Option.get (Source_input.project_root ()) in
  let modules=lowered source in
  let inputs=List.map (fun ((m:Ast.module_form),bytes) -> m.source_file,bytes) (P.source_modules source) in
  let changed=read file ^ "# overlay changed during emission\n" in
  (* Normal nested overlays reject changes to pins themselves. Suspend/reinstall
     pins deliberately to isolate the publication guard from that earlier check. *)
  Source_input.without_pinned_files (fun () ->
   Source_input.with_overlays ~project_root [file,changed] (fun () ->
    Source_input.with_pinned_files inputs (fun () -> refuse (P.verify_source_history source modules)))))))
let unsaved_root_source ()=baseline_project (fun _ _ app ->
 let bytes=read app ^ "# supplied unsaved root\n" in
 let entry=parsed app bytes in
 get (P.with_source_history ~entry ~source:bytes (function
  | Some source -> get (P.verify_source_history source (lowered source))
  | None -> fail "missing overlaid root source"));
 check bool "saved root unchanged" false (contains (read app) "supplied unsaved"))
let lifted_module_boundary ()=project (fun root save path ->
 seal_edge root path;
 let app=save "app.tesl" (replace "import Tesl.Database" "import Tesl.CivilTime exposing []\nimport Tesl.Database" app) in
 accepts app (read app);
 match Compile.compile_row_source_artifacts app (read app) with
 | Compile.GoFailure ds -> check bool "lifted owner explicitly refused" true
   (List.exists (fun (d:Compile.diagnostic) -> contains d.message "lifted Tesl.CivilTime") ds)
 | _ -> fail "uncaptured lifted module emitted")

let full_application_native ()=project (fun root save path ->
 seal_edge root path;
 let imports="import Tesl.Prelude exposing [String]\nimport Tesl.App exposing [App]\nimport Tesl.Telemetry exposing [counter]\n" in
 let source=(app |> replace "import Tesl.Database" (imports ^ "import Tesl.Database")) ^ {|
api ProbeApi { get "/probe" -> String }
handler get probe() -> String = "handler unchanged"
server ProbeServer for ProbeApi { probe }
main() -> App =
 let _ = counter "row-source-startup" 1 []
 App { database: Main, api: ProbeServer, port: 8093 }
|} in
 let app=save "app.tesl" source in accepts app source;
 let artifacts=emit app in
 native ~source_root:root ~test:{|package teslmodapp
import (
 "fmt"
 "strings"
 "testing"
 "net"
 "time"
 "tesl.generated/teslmodapp/internal/teslrt"
)
func TestActualMainRefusesSourceOnlyBeforeStartup(t *testing.T) {
 MainDatabase.Config.MigrationTopology="Embedded"
 listener,err:=net.ListenTCP("tcp", &net.TCPAddr{IP:net.ParseIP("127.0.0.1"),Port:0})
 if err!=nil {t.Fatal(err)}
 defer listener.Close()
 MainDatabase.Config.Host="127.0.0.1"
 MainDatabase.Config.Port=listener.Addr().(*net.TCPAddr).Port
 teslrt.ResetTelemetry()
 var failure any
 func(){defer func(){failure=recover()}();Main()}()
 message:=fmt.Sprint(failure)
 if failure==nil || !strings.Contains(message,"only fresh V1") {
  t.Fatal("actual generated Main did not refuse source-only metadata before effects/connection",failure)
 }
 if len(teslrt.MetricSeriesSnapshot())!=0 { t.Fatal("source application startup effect ran") }
 if err:=listener.SetDeadline(time.Now().Add(50*time.Millisecond)); err!=nil {t.Fatal(err)}
 if connection,err:=listener.Accept(); err==nil {connection.Close();t.Fatal("source-only Main contacted PostgreSQL")}
}
|} artifacts)

let full_v1_worker_application_native ()=baseline_project (fun root save _ ->
 ignore (save "schema/notes/v-current.tesl" {|module Schema.Notes.VCurrent exposing [Note]
import Tesl.Prelude exposing [String]
entity Note table "notes" primaryKey id { id: String, title: String }
|});
 let source={|module App exposing []
import Tesl.Prelude exposing [String]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, MigrationConfig, MigrationTopology(..), TcpConnection]
import Tesl.App exposing [App]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.DB exposing [dbRead, dbWrite]
import Schema.Notes.VCurrent exposing [Note]
database Main = Database {
  schema: Schema.Notes.VCurrent
  migrations: Schema.Notes.Migrate
  backend: Postgres (PostgresConfig {
    namespace: "notes_app"
    migrations: MigrationConfig { topology: Worker, controlOwner: "test_owner", requestRole: "test_request", workerRole: "test_worker", ddlConnection: "unused" }
    dbName: "unused"
    user: "test_request"
    password: ""
    connection: TcpConnection { host: "127.0.0.1", port: 5432 }
  })
}
api NotesApi {
  post "/add" -> String
  get "/note" -> String
  put "/edit" -> String
  delete "/remove" -> String
}
handler post addNote() -> String requires [dbWrite Note] =
  let rows = [Note { id: "one", title: "created" }]
  let _ = insertMany rows in Note
  "created"
handler get readNote() -> String requires [dbRead Note] =
  case selectOne note from Note where note.id == "one" of
    Nothing -> "missing"
    Something note -> note.title
handler put editNote() -> String requires [dbWrite Note] =
  update note in Note
    where note.id == "one"
    set note.title = "edited"
  "edited"
handler delete removeNote() -> String requires [dbWrite Note] =
  delete note from Note where note.id == "one"
  "removed"
server NotesServer for NotesApi { addNote, readNote, editNote, removeNote }
main() -> App requires [dbRead Note, dbWrite Note] =
  App { database: Main, api: NotesServer, port: 8093 }
|} in
 let app=save "app.tesl" source in accepts app source;
 native ~source_root:root ~test:{|package teslmodapp

import (
	"bytes"
	"context"
	"fmt"
	"net/http/httptest"
	"net/url"
	"os"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"tesl.generated/teslmodapp/internal/teslrt"
)

func TestCompiledV1WorkerAppHandlersUsePermanentBaseline(t *testing.T) {
	host, user, portText := os.Getenv("TESL_TEST_POSTGRES_SHARED_HOST"), os.Getenv("TESL_TEST_POSTGRES_SHARED_USER"), os.Getenv("TESL_TEST_POSTGRES_SHARED_PORT")
	if host == "" || user == "" || portText == "" {
		if os.Getenv("TESL_MIGRATION_TEST_REQUIRE_POSTGRES") == "1" {
			t.Fatal("required private PostgreSQL fixture is not configured")
		}
		t.Skip("private PostgreSQL fixture unavailable")
	}
	port, err := strconv.Atoi(portText)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	config, err := pgx.ParseConfig("")
	if err != nil {
		t.Fatal(err)
	}
	config.Host = host
	config.Port = uint16(port)
	config.User = user
	config.Database = os.Getenv("TESL_TEST_POSTGRES_SHARED_ADMIN_DATABASE")
	if config.Database == "" {
		config.Database = "postgres"
	}
	config.TLSConfig = nil
	admin, err := pgx.ConnectConfig(ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	name := "row_native_" + strings.ReplaceAll(teslrt.UUIDv7(), "-", "")
	roles := teslrt.PgMigrationControlRoles{Owner: name + "_owner", Worker: name + "_worker", Request: name + "_request"}
	quote := func(s string) string { return pgx.Identifier{s}.Sanitize() }
	defer func() {
		cleanup, stop := context.WithTimeout(context.Background(), 5*time.Second)
		defer stop()
		_, _ = admin.Exec(cleanup, "drop database if exists "+quote(name)+" with (force)")
		for _, role := range []string{roles.Request, roles.Worker, roles.Owner} {
			_, _ = admin.Exec(cleanup, "drop role if exists "+quote(role))
		}
		_ = admin.Close(cleanup)
	}()
	for _, sql := range []string{"create role " + quote(roles.Owner) + " nologin", "create role " + quote(roles.Worker) + " login", "create role " + quote(roles.Request) + " login", "create database " + quote(name), "grant create on database " + quote(name) + " to " + quote(roles.Owner), "revoke temporary on database " + quote(name) + " from public", "grant temporary on database " + quote(name) + " to " + quote(roles.Owner) + "," + quote(roles.Worker)} {
		if _, err := admin.Exec(ctx, sql); err != nil {
			t.Fatal(err)
		}
	}
	config.Database = name
	installer, err := pgx.ConnectConfig(ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	defer installer.Close(context.Background())
	if _, err := installer.Exec(ctx, "grant create on schema public to "+quote(roles.Owner)); err != nil {
		t.Fatal(err)
	}
	// Supply deployment credentials only. The exact compiler-owned Main pointer,
	// source snapshots, complete inventory, and generated SQL remain untouched.
	dsn := func(role string) string {
		u := url.URL{Scheme: "postgres", User: url.User(role), Host: "localhost", Path: "/" + name, RawQuery: url.Values{"host": {host}, "port": {portText}, "sslmode": {"disable"}}.Encode()}
		return u.String()
	}
	MainDatabase.Config = teslrt.PostgresConfig{Host: host, Port: port, DBName: name, User: roles.Request, Schema: "notes_app", MigrationTopology: "Worker", ControlOwner: roles.Owner, WorkerRole: roles.Worker, RequestRole: roles.Request, DDLConnection: dsn(user)}
	var output, diagnostics bytes.Buffer
	if handled, code := teslrt.RunSchemaCommand([]string{"--schema", "install", "--worker", roles.Worker, "--request", roles.Request, "--json"}, &output, &diagnostics); !handled || code != 0 {
		t.Fatal("actual generated DB alias selection / install", output.String(), diagnostics.String())
	}
	config.User = roles.Worker
	worker, err := pgx.ConnectConfig(ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	defer worker.Close(context.Background())
	MainDatabase.Config.DDLConnection = dsn(roles.Worker)
	if state, err := teslrt.ExecutePgCompiledRowBaseline(ctx, worker, MainDatabase, roles); err != nil || state.Current != 1 || state.Format != 5 {
		t.Fatal("Worker baseline", state, err)
	}
	config.User = roles.Request
	request, err := pgx.ConnectConfig(ctx, config)
	if err != nil {
		t.Fatal(err)
	}
	defer request.Close(context.Background())
	var temp bool
	if err := request.QueryRow(ctx, `select has_database_privilege(current_user,current_database(),'TEMP') or pg_my_temp_schema()<>0`).Scan(&temp); err != nil || temp {
		t.Fatal("Request required temporary DDL", temp, err)
	}
	teslrt.WithDatabase(MainDatabase, func() {
		for _, step := range []struct{ method, path, want string }{{"POST", "/add", "created"}, {"GET", "/note", "created"}, {"PUT", "/edit", "edited"}, {"GET", "/note", "edited"}, {"DELETE", "/remove", "removed"}, {"GET", "/note", "missing"}} {
			record := httptest.NewRecorder()
			NotesServer.ServeHTTP(record, httptest.NewRequest(step.method, step.path, nil))
			if record.Code != 200 || strings.TrimSpace(record.Body.String()) != fmt.Sprintf("%q", step.want) {
				t.Fatal("actual compiled handler", step, record.Code, record.Body.String())
			}
			var rows, bad int
			if err := request.QueryRow(ctx, `select count(*),count(*) filter(where _tesl_v<>1 or _tesl_v is null) from notes_app.notes`).Scan(&rows, &bad); err != nil || bad != 0 {
				t.Fatal("generated DML changed generation", rows, bad, err)
			}
		}
	})
	if _, err := request.Exec(ctx, `alter table notes_app.notes drop column _tesl_v`); err == nil {
		t.Fatal("Request acquired schema authority")
	}
	if _, err := request.Exec(ctx, `delete from notes_app.tesl_row_entities`); err == nil {
		t.Fatal("Request acquired control authority")
	}
}
|} (emit app))

let ()=run "checked source row companion" ["metadata",[
 test_case "complete source and real emitted binding" `Quick source_companion;
 test_case "existing canonical storage identity" `Quick storage_node;
 test_case "generation smallint bounds" `Quick generation_bounds;
 test_case "V1 Worker application handlers against PostgreSQL" `Quick full_v1_worker_application_native;
 test_case "baseline native zero rows" `Quick baseline_native;
 test_case "additive native zero rows" `Quick additive_native;
 test_case "baseline source drift" `Quick source_drift;
 test_case "escaped source history" `Quick escaped_source;
 test_case "private producer graph substitution" `Quick altered_graph;
 test_case "reserved marker" `Quick marker_collision;
 test_case "Derived requires typed adapter" `Quick derived_refusal;
 test_case "same-owner database boundary" `Quick same_owner_databases;
 test_case "additive after transform retains generation" `Quick after_transform_additive;
 test_case "final additive source drift" `Quick final_additive_drift;
 test_case "quoted table reordered fields native" `Quick quoted_reordered;
 test_case "helper-owned Same native and standalone denial" `Quick same_helper_native;
 test_case "two independent database bindings native" `Quick multi_database_native;
 test_case "independent per-entity generations" `Quick multi_entity_generations;
 test_case "unsupported entity lifecycles refuse" `Quick lifecycle_refusals;
 test_case "JSONB record computation and existing-field boundary" `Quick jsonb_record_native;
 test_case "pinned baseline overlay drift" `Quick overlay_source_guard;
 test_case "supplied unsaved root accepted" `Quick unsaved_root_source;
 test_case "lifted module explicit boundary" `Quick lifted_module_boundary;
 test_case "full App/Main refuses before startup and connection" `Quick full_application_native]]
