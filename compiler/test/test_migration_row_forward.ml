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
let emit ?(physical=false) file = match Compile.compile_row_source_artifacts ~storage:true ~physical file (Source_input.read file) with
 | Compile.GoSuccess a -> a | Compile.GoFailure d -> fail (describe d)

(* This suite emits each predecessor before its successor and builds every native
   runtime from the compiler's actual embedded snapshot. Test bridges can select
   only the registered typed storage; they cannot construct admission tokens. *)
let repository () = match Sys.getenv_opt "TESL_REPO_ROOT" with
 | Some p -> Unix.realpath p | None -> fail "TESL_REPO_ROOT is required for native row migration regression"
let fixture_file name = Source_input.read (Filename.concat (repository ()) ("compiler/test/fixtures/row-forward/" ^ name))
let command directory log text =
 let status=Sys.command (Printf.sprintf "cd %s && %s > %s 2>&1" (Filename.quote directory) text (Filename.quote log)) in
 if status<>0 then fail (Printf.sprintf "%s failed (%d):\n%s" text status (Source_input.read log))
let export destination = project (fun root save path ->
 seal_edge root path;
 let edge=Source_input.read path in
 let file=save "app.tesl" app in
 let build version =
  accepts file (Source_input.read file);
  let artifacts=emit ~physical:true file in
  let output=Filename.concat destination version in
  List.iter (fun (a:Emit_go.artifact) -> write (Filename.concat output a.path) a.contents) artifacts;
  write (Filename.concat output "cmd/forward-test/main.go") (fixture_file (version ^ "-main.go"));
  if version="v2" then write (Filename.concat output "internal/teslrt/forward_test_bridge.go") (fixture_file "bridge.go");
  command output (Filename.concat output "build.log") "timeout 120s go build -race -tags tesl_migration_test -o app ./cmd/forward-test" in
 (* The authentic V1 executable and manifest are retained unchanged. *)
 remove path;remove (Filename.concat root "schema/notes/v1.tesl");
 ignore(save "schema/notes/v-current.tesl" (Str.global_replace (Str.regexp_string "Schema.Notes.V1") "Schema.Notes.VCurrent" old));
 build "v1";
 ignore(save "schema/notes/v1.tesl" old);ignore(save "schema/notes/v-current.tesl" fresh);write path edge;
 build "v2")
let rec copy source target =
 match (Unix.lstat source).Unix.st_kind with
 | Unix.S_DIR -> mkdir target;Array.iter (fun name ->
    if not (String.starts_with ~prefix:"_build" name) &&
       not (List.mem name [".git";".tesl-stuff";"node_modules";"elm-stuff"]) then
      copy (Filename.concat source name) (Filename.concat target name)) (Sys.readdir source)
 | Unix.S_REG -> write target (Source_input.read source)
 | _ -> fail ("unexpected special compiler input " ^ source)
let native_forward () =
 let repo=repository () in
 let output=Filename.temp_dir "tesl-row-forward-programs-" "" in
 Fun.protect ~finally:(fun () -> if Sys.getenv_opt "TESL_KEEP_ROW_FORWARD_TEST"=None then remove output) (fun () ->
  export output;
  (* B is an independently built compiler with a query-only source change.
     Neither ABI values nor generated metadata/runtime bytes are patched. *)
  let clone=Filename.concat output "compiler-b" in mkdir clone;
  List.iter (fun path -> copy (Filename.concat repo path) (Filename.concat clone path))
   ["compiler";"runtime/go";"tesl";"manual";"dev-docs";"example";"README.md";"INSTALL.md";"LANGUAGE-SPEC.md"];
  let query=Filename.concat clone "compiler/lib/compiler_query.ml" in
  write query (Source_input.read query ^ "\n(* Native row migration ABI ordering regression. *)\n");
  let compiler=Filename.concat clone "compiler" in
  command compiler (Filename.concat output "compiler-b-build.log") "timeout 180s dune build -j 2 test/test_migration_row_forward.exe";
  let boutput=Filename.concat output "other-build" in
  command compiler (Filename.concat output "compiler-b-export.log")
    (Printf.sprintf "TESL_REPO_ROOT=%s TESL_ROW_FORWARD_EXPORT=%s timeout 180s _build/default/test/test_migration_row_forward.exe"
      (Filename.quote clone) (Filename.quote boutput));
  Unix.rename (Filename.concat boutput "v2") (Filename.concat output "v2b");
  Unix.rename (Filename.concat boutput "v1") (Filename.concat output "v1b");
  command (Filename.concat repo "runtime/go") (Filename.concat output "postgres.log")
    (Printf.sprintf "TESL_ROW_FORWARD_CALIBRATION=%s timeout 240s go test -race -tags tesl_migration_test -timeout 210s ./teslrt -run '^TestPgRowForward(Compiled|Preopened|FirstABI)' -count=1 -v" (Filename.quote output));
  if Sys.getenv_opt "TESL_KEEP_ROW_FORWARD_TEST"<>None then Printf.printf "native row fixture retained: %s\n%!" output)
let () = match Sys.getenv_opt "TESL_ROW_FORWARD_EXPORT" with
 | Some path -> export path
 | None -> run "source-generated row forward protocol" ["PostgreSQL",[
   test_case "authentic V1/V2, crashes, cancellation and compiler ABI ordering" `Quick native_forward]]
