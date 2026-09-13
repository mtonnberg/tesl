open Alcotest
module S=Migration_sparse
let rec mkdir p = if not (Sys.file_exists p) then (mkdir (Filename.dirname p); Unix.mkdir p 0o700)
let write p s = mkdir (Filename.dirname p); Out_channel.with_open_bin p (fun o -> output_string o s)
let rec remove p = if (Unix.lstat p).Unix.st_kind=Unix.S_DIR then (Array.iter (fun n -> remove (Filename.concat p n)) (Sys.readdir p); Unix.rmdir p) else Sys.remove p
let describe ds = String.concat "\n" (List.map (fun (d:Compile.diagnostic) -> d.code ^ ": " ^ d.message) ds)
let errors path s = (Compile.agent_context_result_source path s).diagnostics |> List.filter (fun (d:Compile.diagnostic) -> d.severity="error")
let accepts path s = match errors path s with [] -> () | ds -> fail (describe ds)

module RH=Migration_row_history
module P=Migration_program
let get = function Ok value -> value | Error errors -> fail (String.concat "\n" (List.map (fun (e:S.error) -> e.code ^ ": " ^ e.message) errors))
let capture root f =
 let file=Filename.concat root "app.tesl" in
 let source=Source_input.read file in
 let entry=match Parser.parse_module file source with Ok m -> m | Err e -> fail e.msg in
 P.with_source_history ~entry ~source (function Some h -> f h | None -> fail "missing source history")
let emit file = match Compile.compile_row_source_artifacts file (Source_input.read file) with
 | Compile.GoSuccess a -> a | Compile.GoFailure d -> fail (describe d)
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

let source = {|module App exposing [leap]
import Tesl.Prelude exposing [Int, Bool]
import Tesl.CivilTime exposing [CivilTime.isLeapYear]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import Schema.Notes.VCurrent
fn leap(year: Int) -> Bool = CivilTime.isLeapYear(year)
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
|}
let fixture f =
 let root=Filename.temp_dir "tesl-row-civil-" "" in
 Fun.protect ~finally:(fun()->remove root)(fun()->
  write(Filename.concat root "tesl.toml") "";
  write(Filename.concat root "schema/notes/v-current.tesl") {|module Schema.Notes.VCurrent exposing [Note]
import Tesl.Prelude exposing [String]
entity Note table "notes" primaryKey id { id: String, title: String }
|};
  let entry=Filename.concat root "app.tesl" in write entry source;f root entry)
let native_calendar={|package teslmodapp
import("testing";"tesl.generated/teslmodapp/internal/teslrt")
func TestCalendar(t *testing.T){
 for _,c:=range []struct{year int64;want bool}{{2000,true},{1900,false},{2024,true},{2023,false}} {
  if got:=Leap(teslrt.FromInt64(c.year)); got!=c.want {t.Fatalf("year %d: %v",c.year,got)}
 }
}
|}
let actual_calendar ()=fixture(fun root entry ->
 accepts entry source;
 let artifacts=emit entry in
 check bool "captured CivilTime emitted" true(List.exists(fun(a:Emit_go.artifact)->a.path="internal/teslmodciviltime/module.go")artifacts);
 native ~source_root:root ~test:native_calendar artifacts)
let unsaved_helper ()=fixture(fun root entry ->
 let helper={|module Calendar exposing [leap]
import Tesl.Prelude exposing [Int, Bool]
import Tesl.CivilTime exposing [CivilTime.isLeapYear]
fn leap(year: Int) -> Bool = CivilTime.isLeapYear(year)
|} in
 let helper_path=Filename.concat root "calendar.tesl" in write helper_path helper;accepts helper_path helper;
 let replace a b=Str.global_replace(Str.regexp_string a)b in
 let edited=source |> replace "import Tesl.CivilTime exposing [CivilTime.isLeapYear]" "import Calendar"
  |> replace "CivilTime.isLeapYear(year)" "Calendar.leap(year)" in
 Source_input.with_overlays ~project_root:root [entry,edited](fun()->
  accepts entry edited;
  ignore(get(capture root(fun h ->
   check (option string) "application overlay root retained" (Some root) (Source_input.project_root());
   check int "one transitive ABI module" 1(List.length(List.filter(fun(m,_)->m.Ast.module_name="CivilTime")(P.source_modules h))))));
  let artifacts=match Compile.compile_row_source_artifacts ~mode:Emit_go.Debug entry edited with
   | Compile.GoSuccess value->value | Compile.GoFailure ds->fail(describe ds) in
  check string "unsaved application did not replace backing file" source(In_channel.with_open_bin entry In_channel.input_all);
  native ~source_root:root ~test:native_calendar artifacts))
let captured_graph ()=fixture(fun root _ -> ignore(get(capture root(fun h ->
 let captured=P.source_modules h in
 let original,bytes=List.find(fun(m,_)->m.Ast.module_name="CivilTime")captured in
 check bool "ABI module outside application manifest" false
  (String.starts_with ~prefix:(root ^ "/") original.source_file);
 check string "ABI bytes match exact parsed source" bytes (Source_input.read original.source_file);
 let graph=get(P.source_lowering h) in
 let modules=Go_graph_lowering.modules graph in
 ignore(get(P.verify_source_history h modules));
 let forged=List.map(fun(m:Ast.module_form)->if m.module_name="CivilTime" then {m with decls=[]} else m)modules in
 check bool "forged lifted AST refused" true(match P.verify_source_history h forged with Error es->List.exists(fun(e:S.error)->e.code="MIG013")es | Ok()->false)))))
let with_stdlib f =
 let root=Filename.temp_dir "tesl-civil-stdlib-" "" in
 let previous=Sys.getenv_opt "TESL_STDLIB_DIR" in
 let abi=Result.get_ok(Migration_abi.current()) in
 List.iter(fun(path,_)->write(Filename.concat root(Filename.basename path))(Source_input.read path))(Migration_abi.source_inputs abi);
 Fun.protect ~finally:(fun()->Unix.putenv "TESL_STDLIB_DIR" (Option.value previous ~default:"");Query_cache.clear();remove root)(fun()->
 Unix.putenv "TESL_STDLIB_DIR" root;Query_cache.clear();f root)
let drift ()=with_stdlib(fun stdlib->fixture(fun root _ ->
 let path=Filename.concat stdlib "civil-time.tesl" in
 let bytes=Source_input.read path in
 Fun.protect ~finally:(fun()->write path bytes)(fun()->
 let result=capture root(fun h ->
  let graph=get(P.source_lowering h) in
  write path(bytes ^ "\n# changed after capture\n");
  check bool "captured module stays original under live disk drift" true
   (List.exists(fun(m,b)->m.Ast.module_name="CivilTime" && b=bytes)(P.source_modules h));
  check bool "pre-emission ABI drift refused" true(match P.verify_source_history h (Go_graph_lowering.modules graph) with
   | Error es->List.exists(fun(e:S.error)->e.code="MIG013")es | Ok()->false)) in
 check bool "publication ABI drift refused" true(match result with Error es->List.exists(fun(e:S.error)->e.code="MIG013")es | Ok()->false))))
let missing ()=with_stdlib(fun stdlib->fixture(fun _ entry ->
 Sys.remove(Filename.concat stdlib "civil-time.tesl");
 match Compile.compile_row_source_artifacts entry source with
 | Compile.GoSuccess _->fail "missing required ABI source accepted"
 | Compile.GoFailure ds->check bool "missing lifted input reports MIG013" true(List.exists(fun(d:Compile.diagnostic)->d.code="MIG013")ds)))
let ()=run "Captured lifted CivilTime" ["source",[
 test_case "actual captured calendar" `Quick actual_calendar;
 test_case "unsaved transitive debug helper" `Quick unsaved_helper;
 test_case "exact lifted graph" `Quick captured_graph;
 test_case "ABI disk drift" `Quick drift;
 test_case "missing ABI module" `Quick missing]]
