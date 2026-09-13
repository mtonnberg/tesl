open Alcotest
module D = Migration_declaration
module T = Migration_transform
module R = Migration_transform_rules
module S = Migration_sparse
let old = {|module Schema.Notes.V1 exposing [Note, makeNote, Metadata, makeMetadata]
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
record Metadata { text: String }
codec Metadata {
 toJson { text -> "oldText" with_codec stringCodec }
 fromJson [ { text <- "oldText" with_codec stringCodec } ]
}
fn makeMetadata(text: String) -> Metadata = Metadata { text: text }
entity Note table "notes" primaryKey id { metadata: Metadata, id: String, author: String, title: String, memo: String
 unique index [title] as "notes_title_unique" }
fn makeNote(id: String) -> Note = Note { metadata: makeMetadata id, id: id, author: "writer", title: id, memo: "base" }
|}
let fresh = {|module Schema.Notes.VCurrent exposing [Note, makeNote, Metadata, makeMetadata]
import Tesl.Prelude exposing [String, Int]
import Tesl.Json exposing [stringCodec]
record Metadata { text: String, extra: String }
codec Metadata {
 toJson { text -> "newText" with_codec stringCodec, extra -> "detail" with_codec stringCodec }
 fromJson [ { text <- "newText" with_codec stringCodec, extra <- "detail" with_codec stringCodec } ]
}
fn makeMetadata(text: String) -> Metadata = Metadata { text: text, extra: "made" }
entity Note table "notes" primaryKey id { metadata: Metadata @column("metadata__v2"), id: String, owner: String, title: String, count: Int, memo: String
 unique index [title] as "notes_title_unique" }
fn makeNote(id: String) -> Note = Note { metadata: makeMetadata id, id: id, owner: "writer", title: id, count: 9, memo: "base" }
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
  entities: { Note: Migrate convert [Rename author owner, Retype metadata, WriteBack metadata metadata backward] }
}
fn convert(old: Schema.Notes.V1.Note) -> Migrated Schema.Notes.VCurrent.Note =
  if old.id == "reject" then
    Reject "source rejected"
  else
    Row (Schema.Notes.VCurrent.Note { metadata: Schema.Notes.VCurrent.Metadata { text: old.metadata.text, extra: "migrated" }, id: old.id, owner: old.author, title: old.title, count: amount(), memo: old.memo })
fn backward(row: Schema.Notes.VCurrent.Note) -> Schema.Notes.V1.Metadata = Schema.Notes.V1.Metadata { text: row.metadata.text }
fn amount() -> Int = 7
fn oldNote() -> Schema.Notes.V1.Note =
  Schema.Notes.V1.Note { metadata: Schema.Notes.V1.Metadata { text: "fixture" }, id: "retained", author: "writer", title: "hello", memo: "fixture" }
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
import Tesl.Prelude exposing [String, List]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.App exposing [App]
import Tesl.Telemetry exposing [telemetry]
import Tesl.Env exposing [envInt, envRead]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import Schema.Notes.VCurrent exposing [Note, makeNote, Metadata, makeMetadata]
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
api NotesApi {
 get "/health" -> String
 get "/one" -> String
 get "/all" -> List Note
 post "/one" -> String
 post "/two" -> String
 post "/three" -> String
 post "/absent" -> String
 post "/missing" -> String
 post "/reject" -> String
 put "/one" -> String
 put "/all" -> String
 put "/conflict" -> String
 put "/effects" -> String
 put "/empty" -> String
}
handler get health() -> String = "ready"
handler get one() -> String requires [dbRead Note] =
 case selectOne note from Note where note.id == "one" of
  Nothing -> "missing"
  Something note -> note.title
handler get all() -> List Note requires [dbRead Note] = select note from Note order note.id asc
handler post addOne() -> String requires [dbWrite Note] =
 let rows = [makeNote "one"]
 let _ = insertMany rows in Note
 "created"
handler post addTwo() -> String requires [dbWrite Note] =
 let rows = [makeNote "two"]
 let _ = insertMany rows in Note
 "created"
handler post addThree() -> String requires [dbWrite Note] =
 let rows = [makeNote "three"]
 let _ = insertMany rows in Note
 "created"
handler post addAbsent() -> String requires [dbWrite Note] =
 let rows = [makeNote "absent"]
 let _ = insertMany rows in Note
 "created"
handler post addMissing() -> String requires [dbWrite Note] =
 let rows = [makeNote "missing"]
 let _ = insertMany rows in Note
 "created"
handler post addReject() -> String requires [dbWrite Note] =
 let rows = [makeNote "reject"]
 let _ = insertMany rows in Note
 "created"
handler put editOne() -> String requires [dbWrite Note] =
 update note in Note
  where note.id == "one"
  set note.title = "edited"
  set note.memo = "one-edited"
  set note.metadata = makeMetadata "edited-metadata"
 "edited"
handler put editAll() -> String requires [dbWrite Note] =
 update note in Note
  set note.memo = "all-edited"
 "edited"
fn marked(value: String) -> String =
 telemetry "access-operand" { phase = value }
 value
handler put conflict() -> String requires [dbWrite Note] =
 update note in Note
  set note.title = "duplicate"
 "edited"
handler put effects() -> String requires [dbWrite Note] =
 update note in Note
  where note.id != (marked "where-multi")
  set note.memo = marked "set-multi"
 "edited"
handler put empty() -> String requires [dbWrite Note] =
 update note in Note
  where note.id == (marked "where-zero")
  set note.memo = marked "set-zero"
 "edited"
server NotesServer for NotesApi { health, one, all, addOne, addTwo, addThree, addAbsent, addMissing, addReject, editOne, editAll, conflict, effects, empty }
main() -> App requires [dbRead Note, dbWrite Note, envRead] =
 App { database: Main, api: NotesServer, port: envInt "ROW_PORT" 8093 }
|}
let load file =
 let abi=Result.get_ok (Migration_abi.current ()) in
 match Migration_inventory.load_with_compatibility
   ~stored_value_compatibility:(Some (Migration_abi.stored_value_compatibility abi))
   ~compiler_abi:(Migration_abi.id abi) ~root_file:file with
 | Ok i -> i | Error e -> fail e.message
let seal root file=match Migration_seal.create ~project_root:root (load file) with
 | Ok s -> s | Error e -> fail e.message
let seal_edge ?(body=source) root path =
 let before=Filename.concat root "schema/notes/v1.tesl" and after=Filename.concat root "schema/notes/v-current.tesl" in
 let header=match Migration_header.create ~previous:(seal root before) ~current:(seal root after) with
  | Ok h -> h | Error errors -> fail (String.concat "\n" (List.map (fun (e:S.error) -> e.message) errors)) in
 write path (Migration_header.encode header ^ body)
let emit ?(mode=Emit_go.Release) ?(physical=false) file = match Compile.compile_row_source_artifacts ~mode ~storage:true ~physical file (Source_input.read file) with
 | Compile.GoSuccess a -> a | Compile.GoFailure d -> fail (describe d)


let replace a b s=Str.global_replace (Str.regexp_string a) b s
let repository ()=Option.get (Sys.getenv_opt "TESL_REPO_ROOT")
let fixture name=Source_input.read (Filename.concat (repository ()) ("compiler/test/fixtures/row-access/" ^ name))
let command directory log text=
 let status=Sys.command (Printf.sprintf "cd %s && %s > %s 2>&1" (Filename.quote directory) text (Filename.quote log)) in
 if status<>0 then fail (text ^ "\n" ^ Source_input.read log)
let checked_plan path =
 let appfile=Filename.concat (Filename.dirname (Filename.dirname (Filename.dirname path))) "app.tesl" in
 let bytes=Source_input.read appfile in
 let entry=match Parser.parse_module appfile bytes with Ok m -> m | Err e -> fail e.msg in
 let get=function Ok v -> v | Error errors -> fail (String.concat "\n" (List.map (fun (e:S.error)->e.message) errors)) in
 get (P.with_source_history ~entry ~source:bytes (function
  | None -> fail "missing exact application history"
  | Some history -> get (Migration_retained_storage.plan (snd (List.hd (P.row_histories history))))))
let settled_test path =
 let module RP=Migration_retained_storage in
 let p=checked_plan path in
 let settled=Result.get_ok (RP.settled_version p ~version:2) in
 let node=Migration_retained_storage_canonical.settled_node ~family:"Schema.Notes" ~namespace:"notes" p settled in
 let contract,hash=RH.contract Migration_canonical.Migration node in
 Printf.sprintf {|package teslrt
import (
 "encoding/hex"
 "testing"
)
func TestCompilerSettledAndReverseBindings(t *testing.T) {
 compiled:=compiledRowHistories["Schema.Notes"]
 history:=compiledRowPhysicalHistories[compiled]
 if history==nil||len(history.versions)!=2{t.Fatal("missing actual physical compiler output")}
 window:=history.versions[1]
 encoded,digest:=%S,%S
 settled,err:=pgParseRowSettledPlan(encoded,digest)
 if err!=nil||settled==nil||settled.compiled!=nil {t.Fatal("settled observation",err)}
 if err=pgBindRowSettledPlan(compiled,window,settled);err!=nil{t.Fatal("checked current shape",err)}
 if settled.compiled!=nil{t.Fatal("description binding published authority")}
 derived,err:=pgRowSettledSourceShape(compiled,window)
 if err!=nil||derived.compiled!=nil||derived.hash!=""||derived.contract!=""{t.Fatal("pure predecessor shape acquired authority",err)}
 if _,err=pgParseRowPhysicalPlan(encoded,digest);err==nil{t.Fatal("settled entered retained parser")}
 if _,err=pgParseRowSettledPlan(window.contract,window.hash);err==nil{t.Fatal("window entered settled parser")}
 // Every mutant is freshly encoded and hashed, so none fails only an old digest.
 settledMutants:=map[string]func(*pgRowCanonical){
  "wrong-nullability":func(n *pgRowCanonical){for i:=range n.children[6].children[0].children[5].children {c:=&n.children[6].children[0].children[5].children[i];if c.children[0].isAtom("metadata__v2"){c.children[2]=pgRowList(pgRowAtom("bool"),pgRowAtom("true"))}}},
  "wrong-carrier":func(n *pgRowCanonical){for i:=range n.children[6].children[0].children[5].children {c:=&n.children[6].children[0].children[5].children[i];if c.children[0].isAtom("metadata__v2"){c.children[1]=pgRowAtom("text")}}},
  "changed-introduction":func(n *pgRowCanonical){for i:=range n.children[6].children[0].children[5].children {c:=&n.children[6].children[0].children[5].children[i];if c.children[0].isAtom("metadata__v2"){c.children[4]=pgRowAtom("1")}}},
  "drop-live-index":func(n *pgRowCanonical){n.children[6].children[0].children[7]=pgRowList()},
  "old-marker-default":func(n *pgRowCanonical){n.children[6].children[0].children[3]=pgRowAtom("1")},
 }
 for name,mutate:=range settledMutants {t.Run(name,func(t *testing.T){
  document,_,err:=pgReadRowCanonical(encoded);if err!=nil{t.Fatal(err)}
  mutate(&document.children[3]);raw,hash:=pgRowBaselineDocument(document.children[3])
  changed,err:=pgParseRowSettledPlan(hex.EncodeToString([]byte(raw)),hash)
  if err==nil {err=pgBindRowSettledPlan(compiled,window,changed)}
  if err==nil{t.Fatal("mutated settled source accepted")}
 })}
 reverseMutants:=map[string]func(*pgRowCanonical){
  "wrong-old-field":func(n *pgRowCanonical){n.children[6].children[0].children[9].children[0].children[0]=pgRowAtom("memo")},
  "wrong-new-field":func(n *pgRowCanonical){n.children[6].children[0].children[9].children[0].children[1]=pgRowAtom("memo")},
  "omitted":func(n *pgRowCanonical){n.children[6].children[0].children[9]=pgRowList()},
  "duplicate":func(n *pgRowCanonical){w:=&n.children[6].children[0].children[9];w.children=append(w.children,w.children[0])},
  "target-storage":func(n *pgRowCanonical){n.children[6].children[0].children[9].children[0].children[2]=pgRowAtom("metadata__v2")},
 }
 for name,mutate:=range reverseMutants {t.Run(name,func(t *testing.T){
  document,_,err:=pgReadRowCanonical(window.contract);if err!=nil{t.Fatal(err)}
  mutate(&document.children[3]);raw,hash:=pgRowBaselineDocument(document.children[3])
  changed,err:=pgParseRowPhysicalPlan(hex.EncodeToString([]byte(raw)),hash)
  if err==nil {err=pgBindRowPhysicalPlan(compiled,history.versions[0],changed)}
  if err==nil {t.Fatal("mutated WriteBack physical owner accepted")}
 })}
}
|} contract hash

let export ?(before=old) ?(after=fresh) ?(body=source) destination=project ~before ~after (fun root save path ->
 seal_edge ~body root path;let edge=Source_input.read path in
 let file=save "app.tesl" app in
 let build version=
  if version="v2" then (
   let plan=checked_plan path in
   let contract=Result.get_ok(Migration_contract.source ~plan ~version:2) in
   let contract_file=Filename.concat root "migrations/notes/v2-contract.tesl" in
   write contract_file contract;accepts contract_file contract);
  accepts file (Source_input.read file);
  let artifacts=emit ~physical:true file in
  let output=Filename.concat destination version in
  List.iter (fun (a:Emit_go.artifact) -> if not (Filename.check_suffix a.path ".json") then
   write (Filename.concat output a.path) a.contents) artifacts;
  let driver=replace {|args := []string{"--schema", os.Args[1], "--json"}|} {|args := []string{"--schema", os.Args[1], "--json"}
 if os.Args[1]=="contract" { args=[]string{"--schema","contract","V2","--json"} }|} (fixture "main.go") in
  write (Filename.concat output "cmd/access-test/main.go") driver;
  write (Filename.concat output "internal/teslmodapp/access_effects_test_bridge.go") (fixture "effects.go");
  command output (Filename.concat output "build.log") "timeout 120s go build -race -tags tesl_migration_test -o app ./cmd/access-test";
  if version="v2" then (
   write (Filename.concat output "internal/teslrt/physical_binding_test.go") (settled_test path);
   command output (Filename.concat output "binding.log") "timeout 120s go test -race -count=1 ./internal/teslrt") in
 remove path;remove (Filename.concat root "schema/notes/v1.tesl");
 ignore(save "schema/notes/v-current.tesl" (replace "Schema.Notes.V1" "Schema.Notes.VCurrent" before));build "v1";
 ignore(save "schema/notes/v1.tesl" before);ignore(save "schema/notes/v-current.tesl" after);write path edge;build "v2")
let native_case ?before ?after ?body kind ()=
 let output=Filename.temp_dir "tesl-row-retype-physical-" "" in
 Fun.protect ~finally:(fun () -> if Sys.getenv_opt "TESL_KEEP_ROW_RETYPE_PHYSICAL_TEST"=None then remove output) (fun () ->
  export ?before ?after ?body output;
  command (Filename.concat (repository ()) "runtime/go") (Filename.concat output "postgres.log")
   (Printf.sprintf "TESL_ROW_RETYPE_PHYSICAL_KIND=%s TESL_ROW_RETYPE_PHYSICAL_PROGRAMS=%s timeout 180s go test -p 1 -race -tags tesl_migration_test -timeout 150s ./teslrt -run '^TestPgRowRetypePhysical(ActualApp|ContractApp)$' -count=1 -v" (Filename.quote kind) (Filename.quote output));
  Printf.printf "actual generated Retype/WriteBack handler trace passed\n%!")
let adt () =
 let before=old |> replace "Metadata, makeMetadata" "Metadata(..), makeMetadata"
  |> replace {|record Metadata { text: String }
codec Metadata {
 toJson { text -> "oldText" with_codec stringCodec }
 fromJson [ { text <- "oldText" with_codec stringCodec } ]
}
fn makeMetadata(text: String) -> Metadata = Metadata { text: text }|}
 {|type Metadata =
 | Named text: String
 | Absent
codec Metadata { adtJson }
fn makeMetadata(text: String) -> Metadata =
 if text == "absent" || text == "missing" then
  Absent
 else
  Named { text: text }|} in
 let after=fresh |> replace "Metadata, makeMetadata" "Metadata(..), makeMetadata"
  |> replace {|record Metadata { text: String, extra: String }
codec Metadata {
 toJson { text -> "newText" with_codec stringCodec, extra -> "detail" with_codec stringCodec }
 fromJson [ { text <- "newText" with_codec stringCodec, extra <- "detail" with_codec stringCodec } ]
}
fn makeMetadata(text: String) -> Metadata = Metadata { text: text, extra: "made" }|}
 {|type Metadata =
 | Details text: String extra: String
 | Missing
codec Metadata { adtJson }
fn makeMetadata(text: String) -> Metadata =
 if text == "absent" || text == "missing" then
  Missing
 else
  Details { text: text, extra: "made" }|} in
 let body=source
  |> replace {|Schema.Notes.VCurrent.Metadata { text: old.metadata.text, extra: "migrated" }|} "upgrade old.metadata"
  |> replace {|Schema.Notes.V1.Metadata { text: row.metadata.text }|} "downgrade row.metadata"
  |> replace {|Schema.Notes.V1.Metadata { text: "fixture" }|} {|Schema.Notes.V1.Named { text: "fixture" }|}
  |> fun s -> s ^ {|
fn upgrade(value: Schema.Notes.V1.Metadata) -> Schema.Notes.VCurrent.Metadata =
 case value of
  Schema.Notes.V1.Named { text } -> Schema.Notes.VCurrent.Details { text: text, extra: "migrated" }
  Schema.Notes.V1.Absent -> Schema.Notes.VCurrent.Missing
fn downgrade(value: Schema.Notes.VCurrent.Metadata) -> Schema.Notes.V1.Metadata =
 case value of
  Schema.Notes.VCurrent.Details { text, extra } -> Schema.Notes.V1.Named { text: text }
  Schema.Notes.VCurrent.Missing -> Schema.Notes.V1.Absent
|} in
 native_case ~before ~after ~body "adt" ()
let ()=run "physical Retype and WriteBack" ["PostgreSQL",[
 test_case "unchanged V1/V2 App with distinct JSONB record codecs" `Quick (native_case "record");
 test_case "unchanged V1/V2 App with distinct JSONB ADT constructors" `Quick adt]]
