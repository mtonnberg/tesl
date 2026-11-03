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
let emit ?(physical=false) file = match Compile.compile_row_source_artifacts ~storage:true ~physical file (Source_input.read file) with
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

let smoke ()=project (fun root save path -> seal_edge root path; let file=save "app.tesl" app in
 accepts file (Source_input.read file);
 let artifacts=emit file in
 check bool "companion v2" true (contains (artifact "row-transform-history.json" artifacts) "\"version\":2");
 let original=match Compile.compile_row_source_artifacts file (Source_input.read file) with Compile.GoSuccess a -> a | Compile.GoFailure ds -> fail(describe ds) in
 let hash artifacts =
  let open Yojson.Basic.Util in
  Yojson.Basic.from_string (artifact "row-transform-history.json" artifacts) |> member "databases" |> to_list |> List.hd |> member "transforms" |> to_list |> List.hd |> member "transformContractHash" |> to_string in
 check string "layout version does not relabel callback semantics" (hash original) (hash artifacts);
 native ~source_root:root artifacts)

let replace a b s=Str.global_replace (Str.regexp_string a) b s
let reseal root path body =
 let before=Filename.concat root "schema/notes/v1.tesl" and after=Filename.concat root "schema/notes/v-current.tesl" in
 let header=match Migration_header.create ~previous:(seal root before) ~current:(seal root after) with
  | Ok h -> h | Error errors -> fail (String.concat "\n" (List.map (fun (e:S.error) -> e.message) errors)) in
 write path (Migration_header.encode header ^ body)
let payload = {|import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Float exposing [Float]
import Tesl.Json exposing [stringCodec]
fact ValidText (value: String)
check checkedText(value: String) -> value: String ::: ValidText value =
 if value != "bad" then
  ok value ::: ValidText value
 else
  fail 400 "private-codec-secret-sentinel"
establish trustedText(value: String) -> Fact (ValidText value) = ValidText value
record Metadata { text: String ::: ValidText text }
codec Metadata {
 toJson { text -> "storedText" with_codec stringCodec }
 fromJson [ { text <- "storedText" with_codec stringCodec via checkedText } ]
}
|}
let stored_schema current = current
 |> replace "exposing [Note]" "exposing [Note, Archive, Metadata, ValidText, trustedText]"
 |> replace "exposing [String]" "exposing [String, Int, Bool]"
 |> replace "exposing [String, Int]" "exposing [String, Int, Bool]"
 |> replace "entity Note" (payload ^ "entity Note")
 |> replace "table \"notes\"" "table \"odd\\\"notes\""
 |> replace "id: String, author: String, title: String" "title: String, author: String, id: String"
 |> replace "id: String, owner: String, title: String, count: Int" "count: Int, title: String, id: String, owner: String"

let storage_fields = ", huge: Int, active: Bool, score: Float, optional: Maybe String"
let archive = "\nentity Archive table \"archive\" primaryKey id { id: String, metadata: Metadata, optionalJson: Maybe Metadata }\n"
let stored_old=stored_schema old |> replace "id: String }" ("id: String" ^ storage_fields ^ " }") |> fun s -> s ^ archive
let stored_new=stored_schema fresh |> replace "owner: String }" ("owner: String" ^ storage_fields ^ ", metadata: Metadata, optionalJson: Maybe Metadata }") |> fun s -> s ^ archive
let stored_source=source |> replace "import Tesl.Prelude" "import Tesl.Maybe exposing [Maybe(..)]\nimport Tesl.Prelude"
 |> replace "Rule(..), Migrated(..)" "Rule(..), Same(..), Migrated(..)"
 |> replace "same: []" "same: [Same Schema.Notes.V1.Metadata Schema.Notes.VCurrent.Metadata, Same Schema.Notes.V1.ValidText Schema.Notes.VCurrent.ValidText]"
 |> replace "count: amount() }" "count: amount(), huge: old.huge, active: old.active, score: old.score, optional: old.optional, metadata: convertMetadata old.title, optionalJson: Nothing }"

 |> replace "title: \"hello\" }" "title: \"hello\", huge: 123, active: True, score: 2.5, optional: Nothing }"
let stored_source=stored_source ^ {|
fn convertMetadata(text: String) -> Schema.Notes.VCurrent.Metadata =
 let proof = Schema.Notes.VCurrent.trustedText text
 Schema.Notes.VCurrent.Metadata { text: text ::: proof }
|}
let postgres_test = {|package teslmodapp
import (
 "context"
 "fmt"
 "os"
 "strconv"
 "strings"
 "testing"
 "time"
 "github.com/jackc/pgx/v5"
 rt "tesl.generated/teslmodapp/internal/teslrt"
 second "tesl.generated/teslmodapp/internal/teslmodsecond"
 fresh "tesl.generated/teslmodapp/internal/teslmodschemanotesvcurrent"
 old "tesl.generated/teslmodapp/internal/teslmodschemanotesv1"
)
type trackedRow struct {pgx.CollectableRow; scanned bool}
func (r *trackedRow) Scan(values ...any) error {r.scanned=true;return r.CollectableRow.Scan(values...)}
func panicExpected(t *testing.T, fn func()) { t.Helper();caught:=false;func(){defer func(){caught=recover()!=nil}();fn()}();if !caught {t.Fatal("expected refusal")}}
func TestActualPostgresStorageAdapters(t *testing.T) {
 host:=os.Getenv("TESL_TEST_POSTGRES_SHARED_HOST")
 if host=="" { if os.Getenv("TESL_MIGRATION_TEST_REQUIRE_POSTGRES")=="1" {t.Fatal("required PostgreSQL environment missing")};t.Skip("PostgreSQL environment missing") }
 cfg,err:=pgx.ParseConfig(""); if err!=nil {t.Fatal(err)}
 cfg.Host=host;cfg.User=os.Getenv("TESL_TEST_POSTGRES_SHARED_USER");cfg.Database="postgres";cfg.TLSConfig=nil
 if value:=os.Getenv("TESL_TEST_POSTGRES_SHARED_ADMIN_DATABASE");value!="" {cfg.Database=value}
 port,err:=strconv.Atoi(os.Getenv("TESL_TEST_POSTGRES_SHARED_PORT"));if err!=nil {t.Fatal(err)};cfg.Port=uint16(port)
 ctx,cancel:=context.WithTimeout(context.Background(),30*time.Second);defer cancel()
 conn,err:=pgx.ConnectConfig(ctx,cfg);if err!=nil {t.Fatal(err)};defer conn.Close(ctx)
 adapter:=MainDatabaseCompiledRowStorage0
 source:=adapter.SourceProjection();target:=adapter.TargetProjection()
 want:=[]string{"title","author","id","huge","active","score","optional"}
 if fmt.Sprint(source.Fields())!=fmt.Sprint(want) {t.Fatal("source order was replaced by sorted schema order")}
 readback:=source.Fields();readback[0]="mutated";if source.Fields()[0]!="title" {t.Fatal("projection order escaped")}
 sourcePlan,err:=source.CheckOrder(want);if err!=nil {t.Fatal(err)}
 targetPlan,err:=target.CheckOrder(target.Fields());if err!=nil {t.Fatal(err)}
 foreignPlan,err:=second.MainDatabaseCompiledRowStorage0.SourceProjection().CheckOrder(want);if err!=nil {t.Fatal(err)}
 swapped:=append([]string(nil),want...);swapped[0],swapped[1]=swapped[1],swapped[0]
 if _,err:=source.CheckOrder(swapped);err==nil {t.Fatal("same-typed swapped source fields accepted")}
 if _,err:=source.CheckOrder(want[:len(want)-1]);err==nil {t.Fatal("partial projection accepted")}
 if _,err:=adapter.Decode(sourcePlan,nil);err==nil {t.Fatal("unsealed adapter decoded")}
 panicExpected(t,func(){rt.RegisterCompiledRowStorage(MainDatabaseCompiledRowTransform0,old.TeslDecodeRowNote,fresh.TeslEncodeRowNote,fresh.TeslDecodeRowNote,old.TeslEncodeRowNote)})
 foreignTarget,err:=second.MainDatabaseCompiledRowStorage0.TargetProjection().CheckOrder(target.Fields());if err!=nil {t.Fatal(err)}
 panicExpected(t,func(){rt.RegisterCompiledRowStorage(MainDatabaseCompiledRowTransform0,nil,fresh.TeslEncodeRowNote,fresh.TeslDecodeRowNote,old.TeslEncodeRowNote)})
 var zero *rt.PgRowStorage[old.Note,fresh.Note]
 if _,err:=zero.Encode(fresh.Note{});err==nil {t.Fatal("zero adapter encoded")}
 if _,err:=adapter.Encode(fresh.Note{});err==nil {t.Fatal("unsealed adapter encoded")}
 if err:=rt.PreflightApplicationDatabases(MainDatabase,second.MainDatabase);err!=nil {t.Fatal(err)}
 panicExpected(t,func(){rt.RegisterCompiledRowStorage(MainDatabaseCompiledRowTransform0,old.TeslDecodeRowNote,fresh.TeslEncodeRowNote,fresh.TeslDecodeRowNote,old.TeslEncodeRowNote)})
 // The intentionally quoted test fixture has no relationship to retained or
 // shadow storage allocation. Every selected value uses an explicit logical alias.
 _,err=conn.Exec(ctx,`CREATE TEMP TABLE "odd""source" ("t" text,"a" text,"i" text,"n" numeric,"b" boolean,"f" double precision,"o" text,"j" jsonb,"q" jsonb)`)
 if err!=nil {t.Fatal(err)}
 _,err=conn.Exec(ctx,`INSERT INTO "odd""source" VALUES ('title-distinct','author-distinct','kept',123456789012345678901234567890,true,2.75,NULL,'{"storedText":"good"}',NULL)`)
 if err!=nil {t.Fatal(err)}
 expressions:=[]string{`"t" AS "title"`,`"a" AS "author"`,`"i" AS "id"`,`"n" AS "huge"`,`"b" AS "active"`,`"f" AS "score"`,`"o" AS "optional"`}
 decode:=func(plan rt.PgRowProjectionPlan,parts []string)(old.Note,error,bool){
  rows,err:=conn.Query(ctx,"SELECT "+strings.Join(parts,",")+` FROM "odd""source"`);if err!=nil {t.Fatal(err)};defer rows.Close()
  if !rows.Next(){t.Fatal("missing fixture row",rows.Err())}
  tracked:=&trackedRow{CollectableRow:rows};value,err:=adapter.Decode(plan,tracked);return value,err,tracked.scanned
 }
 for _,plan:=range []rt.PgRowProjectionPlan{targetPlan,foreignPlan,{}} {if _,err,scanned:=decode(plan,expressions);err==nil||scanned {t.Fatal("foreign direction/database/zero plan reached scanner",err)}}
 shifted:=append([]string(nil),expressions...);shifted[0],shifted[1]=shifted[1],shifted[0]
 if _,err,scanned:=decode(sourcePlan,shifted);err==nil||scanned {t.Fatal("same-typed swapped SQL fields reached scanner",err)}
 wrongType:=append([]string(nil),expressions...);wrongType[3]=`1::integer AS "huge"`
 if _,err,scanned:=decode(sourcePlan,wrongType);err==nil||scanned {t.Fatal("wrong SQL carrier reached scanner",err)}
 value,err,scanned:=decode(sourcePlan,expressions);if err!=nil||!scanned {t.Fatal("generated source decoder",err)}
 if value.Title!="title-distinct"||value.Author!="author-distinct"||value.Huge.String()!="123456789012345678901234567890"||!value.Active||value.Score!=2.75||value.Optional.Tag!=rt.MaybeNothing {t.Fatal("decoded primitive/NULL/JSONB values shifted")}
 result,err:=MainDatabaseCompiledRowTransform0.Run(value);if err!=nil||result.Tag!=rt.MigratedRow {t.Fatal("actual Tesl callback",err)}
 encoded,err:=adapter.Encode(result.RowValue);if err!=nil {t.Fatal(err)}
 if _,err:=encoded.Parameters(sourcePlan);err==nil {t.Fatal("encoded target accepted source plan")}
 if _,err:=encoded.Parameters(foreignTarget);err==nil {t.Fatal("encoded target accepted foreign database target plan")}
 params,err:=encoded.Parameters(targetPlan);if err!=nil {t.Fatal(err)}
 _,err=conn.Exec(ctx,`CREATE TEMP TABLE "odd""target" ("count" numeric,"title" text,"id" text,"owner" text,"huge" numeric,"active" boolean,"score" double precision,"optional" text,"metadata" jsonb,"optionalJson" jsonb)`);if err!=nil {t.Fatal(err)}
 _,err=conn.Exec(ctx,`INSERT INTO "odd""target" VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10)`,params...);if err!=nil {t.Fatal("actual generated encoder bindings",err)}
 var title,owner,huge,json string;var count int;var nullText,nullJSON bool
 err=conn.QueryRow(ctx,`SELECT "count"::int,"title","owner","huge"::text,"metadata"->>'storedText',"optional" IS NULL,"optionalJson" IS NULL FROM "odd""target"`).Scan(&count,&title,&owner,&huge,&json,&nullText,&nullJSON)
 if err!=nil||count!=7||title!="title-distinct"||owner!="author-distinct"||huge!="123456789012345678901234567890"||json!="title-distinct"||!nullText||!nullJSON {t.Fatal("encoded SQL projection/codec/null mismatch",err)}
 value.Id="reject";rejected,err:=MainDatabaseCompiledRowTransform0.Run(value);if err!=nil||rejected.Tag!=rt.MigratedReject {t.Fatal("actual Tesl Reject lost")}
 for _,expression:=range []string{`NULL::numeric AS "huge"`,`1.25::numeric AS "huge"`} {
  parts:=append([]string(nil),expressions...);parts[3]=expression
  if _,err,scanned:=decode(sourcePlan,parts);err==nil||!scanned {t.Fatal("numeric null/fractional value accepted",err)}
 }
 // The unchanged Archive has its own old nominal SQL codecs. Reading it needs
 // no callback, nominal conversion, or transforming-generation authority.
 readArchive:=func(jsonExpression,optionalExpression string) (old.Archive,error) {
  rows,err:=conn.Query(ctx,`SELECT "i",`+jsonExpression+`,`+optionalExpression+` FROM "odd""source"`);if err!=nil {t.Fatal(err)};defer rows.Close();if !rows.Next(){t.Fatal(rows.Err())}
  return old.TeslDecodeRowArchive(rows)
 }
 archive,err:=readArchive(`"j"`,`"q"`);if err!=nil||archive.Metadata.Text!="good"||archive.OptionalJson.Tag!=rt.MaybeNothing {t.Fatal("old private JSONB codec",err)}
 archiveParams,err:=old.TeslEncodeRowArchive(archive);if err!=nil {t.Fatal(err)}
 var oldJSON string;var oldNull bool
 err=conn.QueryRow(ctx,`SELECT $2::jsonb->>'storedText',$3::jsonb IS NULL WHERE $1::text='kept'`,archiveParams...).Scan(&oldJSON,&oldNull)
 if err!=nil||oldJSON!="good"||!oldNull {t.Fatal("old codec SQL encoding",err)}
 targetExpressions:=[]string{`"count"`,`"title"`,`"id"`,`"owner"`,`"huge"`,`"active"`,`"score"`,`"optional"`,`"metadata"`,`"optionalJson"`}
 decodeTarget:=func(parts []string)(fresh.Note,error){
  rows,err:=conn.Query(ctx,"SELECT "+strings.Join(parts,",")+` FROM "odd""target"`);if err!=nil {t.Fatal(err)};defer rows.Close();if !rows.Next(){t.Fatal(rows.Err())};return adapter.DecodeTarget(targetPlan,rows)
 }
 reread,err:=decodeTarget(targetExpressions);if err!=nil||reread.Metadata.Text!="title-distinct"||reread.OptionalJson.Tag!=rt.MaybeNothing {t.Fatal("target nominal roundtrip",err)}
 for _,change:=range []struct{index int;expression string}{
  {8,`NULL::jsonb AS "metadata"`},{8,`'null'::jsonb AS "metadata"`},
  {8,`'{"storedText":"bad"}'::jsonb AS "metadata"`},
  {9,`'null'::jsonb AS "optionalJson"`},{9,`'{"storedText":"bad"}'::jsonb AS "optionalJson"`},
 } {parts:=append([]string(nil),targetExpressions...);parts[change.index]=change.expression;if _,err:=decodeTarget(parts);err==nil||strings.Contains(err.Error(),"sentinel")||strings.Contains(err.Error(),"storedText") {t.Fatal("stored invalid JSONB did not safely refuse",change.index,err)}}
 optional:=append([]string(nil),targetExpressions...);optional[7]=`'present'::text AS "optional"`;optional[9]=`'{"storedText":"nested"}'::jsonb AS "optionalJson"`
 present,err:=decodeTarget(optional);if err!=nil||present.Optional.Tag!=rt.MaybeSomething||present.OptionalJson.Tag!=rt.MaybeSomething||present.OptionalJson.SomethingValue.Text!="nested" {t.Fatal("SQL present JSON optional failed",err)}
}
|}
let storage_completeness_test = {|package storagecompletenesstest
import (
 "strings"
 "testing"
 rt "tesl.generated/teslmodapp/internal/teslrt"
 old "tesl.generated/teslmodapp/internal/teslmodschemanotesv1"
 fresh "tesl.generated/teslmodapp/internal/teslmodschemanotesvcurrent"
 migrate "tesl.generated/teslmodapp/internal/teslmodschemanotesmigratev2"
 tasksOld "tesl.generated/teslmodapp/internal/teslmodschematasksv1"
 tasksFresh "tesl.generated/teslmodapp/internal/teslmodschematasksvcurrent"
 tasksMigrate "tesl.generated/teslmodapp/internal/teslmodschematasksmigratev2"
)
func TestCompiledStorageCompletenessAtomicRetry(t *testing.T) {
 // Import the real compiler-emitted callback/codec owner packages without App's
 // automatic complete registrations. No source, loose metadata, or hashes are
 // supplied by this negative public-API harness.
 db:=rt.RegisterDatabaseMigrationHistory(rt.RegisterDatabaseIdentity("App.Main",rt.NewDatabase("Main",rt.PostgresConfig{Schema:"notes"},nil)),"Schema.Notes")
 other:=rt.RegisterDatabaseMigrationHistory(rt.RegisterDatabaseIdentity("Second.Main",rt.NewDatabase("Main",rt.PostgresConfig{Schema:"tasks"},nil)),"Schema.Tasks")
 first:=rt.RegisterCompiledRowTransform[old.Note,fresh.Note](rt.LookupCompiledRowTransform(db,"Schema.Notes",2,"Note"),migrate.TeslCompiledRowCallback)
 second:=rt.RegisterCompiledRowTransform[tasksOld.Note,tasksFresh.Note](rt.LookupCompiledRowTransform(other,"Schema.Tasks",2,"Note"),tasksMigrate.TeslCompiledRowCallback)
 adapter:=rt.RegisterCompiledRowStorage(first,old.TeslDecodeRowNote,fresh.TeslEncodeRowNote,fresh.TeslDecodeRowNote,old.TeslEncodeRowNote)
 if err:=rt.PreflightApplicationDatabases(db,other);err==nil||!strings.Contains(err.Error(),"storage adapter bindings are incomplete") {t.Fatal("missing storage did not fail exact completeness guard",err)}
 if _,err:=first.Run(old.Note{});err==nil {t.Fatal("failed batch sealed first callback")}
 if _,err:=adapter.Encode(fresh.Note{});err==nil {t.Fatal("failed batch sealed first adapter")}
 rt.RegisterCompiledRowStorage(second,tasksOld.TeslDecodeRowNote,tasksFresh.TeslEncodeRowNote,tasksFresh.TeslDecodeRowNote,tasksOld.TeslEncodeRowNote)
 if err:=rt.PreflightApplicationDatabases(db,other);err!=nil {t.Fatal("complete retry failed",err)}
 value:=old.Note{Id:"kept",Title:"safe",Huge:rt.FromInt64(42)}
 result,err:=first.Run(value);if err!=nil||result.Tag!=rt.MigratedRow||result.RowValue.Metadata.Text!="safe" {t.Fatal("retry did not seal actual callback",err)}
 if _,err:=adapter.Encode(result.RowValue);err!=nil {t.Fatal("retry did not seal codec",err)}
}
|}
let shared_fixture ()=project ~before:stored_old ~after:stored_new (fun root save path ->
 reseal root path stored_source;
 let family=replace "Schema.Notes" "Schema.Tasks" in
 ignore(save "schema/tasks/v1.tesl" (family stored_old));ignore(save "schema/tasks/v-current.tesl" (family stored_new));
 let before=Filename.concat root "schema/tasks/v1.tesl" and after=Filename.concat root "schema/tasks/v-current.tesl" in
 let header=Result.get_ok (Migration_header.create ~previous:(seal root before) ~current:(seal root after)) in
 ignore(save "migrations/tasks/v2.tesl" (Migration_header.encode header ^ family stored_source));
 ignore(save "second.tesl" (app |> replace "module App exposing []" "module Second exposing []" |> family |> replace "namespace: \"notes\"" "namespace: \"tasks\""));
 let file=save "app.tesl" (replace "import Tesl.Database" "import Second exposing []\nimport Tesl.Database" app) in accepts file (Source_input.read file);
 native ~source_root:root ~extra_tests:["internal/storagecompletenesstest/completeness_test.go",storage_completeness_test] ~test:postgres_test (emit file))
let nominal_boundary () =
 let before=stored_old |> replace "optional: Maybe String }" "optional: Maybe String, metadata: Metadata }" in
 project ~before ~after:stored_new (fun root save path ->
  let body=stored_source |> replace "fn oldNote() -> Schema.Notes.V1.Note =" "fn oldNote() -> Schema.Notes.V1.Note =\n  let text = \"fixture\"\n  let proof = Schema.Notes.V1.trustedText text"
   |> replace "optional: Nothing }" "optional: Nothing, metadata: Schema.Notes.V1.Metadata { text: text ::: proof } }"
   |> replace "convertMetadata old.title" "convertMetadata old.metadata.text" in
  reseal root path body;
  let file=save "app.tesl" app in
  let ds=errors file (Source_input.read file) in
  check bool "retained nominal record computation needs a new checked mapping judgment" true
   (List.exists (fun (d:Compile.diagnostic) -> d.code="MIG018" && contains d.message "exact original projection") ds))
let adt_boundary () =
 let schema text = text |> replace "entity Archive" "type Status =\n | Ready\n | Done\nentity Archive"
  |> replace "exposing [Note, Archive" "exposing [Status(..), Note, Archive"
  |> replace "primaryKey id { id: String, metadata: Metadata, optionalJson: Maybe Metadata }" "primaryKey id { id: String, metadata: Metadata, optionalJson: Maybe Metadata, status: Status }" in
 project ~before:(schema stored_old) ~after:(schema stored_new) (fun root save path ->
  let body=stored_source |> replace "same: [" "same: [Same Schema.Notes.V1.Status Schema.Notes.VCurrent.Status, " in
  reseal root path body;let file=save "app.tesl" app in accepts file (Source_input.read file);
  native ~source_root:root (emit file))
let physical_roundtrip ()=project (fun root save path ->
 let extra=", userURL: String, userUri: String" in
 ignore(save "schema/notes/v1.tesl" (old |> replace "title: String }" ("title: String" ^ extra ^ "\nindex [title] as \"title_historical\" }")));
 ignore(save "schema/notes/v-current.tesl" ((fresh |> replace "count: Int }" ("count: Int" ^ extra ^ "\nindex [owner] as \"owner_current\" }")) ^ "entity Zoo table \"zoo\" primaryKey id { id: String, label: String }\n"));
 let body=source |> replace "count: amount() }" "count: amount(), userURL: old.userURL, userUri: old.userUri }"
  |> replace "Note: Migrate convert [Rename author owner]" "Note: Migrate convert [Rename author owner], Zoo: New"
  |> replace "title: \"hello\" }" "title: \"hello\", userURL: \"upper\", userUri: \"mixed\" }" in
 reseal root path body;let file=save "app.tesl" app in accepts file (Source_input.read file);
 let artifacts=emit ~physical:true file in
 check bool "physical companion generated" true (contains (artifact "retained-physical-history.json" artifacts) "compiled-retained-physical-history");
 let test={|package teslrt
import("testing";"encoding/hex";"strings")
func rewrittenPhysical(t *testing.T,p *pgRowPhysicalPlan,change func(*pgRowCanonical)) *pgRowPhysicalPlan {
 t.Helper();n,_,err:=pgReadRowCanonical(p.contract);if err!=nil{t.Fatal(err)};change(&n.children[3]);raw,hash:=pgRowBaselineDocument(n.children[3]);result,err:=pgParseRowPhysicalPlan(hex.EncodeToString([]byte(raw)),hash);if err!=nil{t.Fatal(err)};return result
}
func rejectPhysicalLineage(t *testing.T,before,after *pgRowPhysicalPlan,change func(*pgRowCanonical)) {
 t.Helper();n,_,err:=pgReadRowCanonical(after.contract);if err!=nil{t.Fatal(err)};change(&n.children[3]);raw,hash:=pgRowBaselineDocument(n.children[3]);changed,err:=pgParseRowPhysicalPlan(hex.EncodeToString([]byte(raw)),hash)
 if err==nil {err=pgValidateRowPhysicalLineage(before,changed)}
 if err==nil {t.Fatal("freshly rehashed invalid lineage accepted")}
}
func physicalProjectionNode(n *pgRowCanonical,logical string) *pgRowCanonical {
 for i:=range n.children[6].children[0].children[6].children {p:=&n.children[6].children[0].children[6].children[i];if p.children[0].isAtom(logical){return p}}
 panic("test logical projection missing")
}
func TestActualCompiledPhysicalLineage(t *testing.T) {
 if len(compiledRowPhysicalHistories)!=1 {t.Fatal("missing complete physical registration")}
 for compiled,history:=range compiledRowPhysicalHistories {
  if len(history.versions)!=2 {t.Fatal("missing adjacent physical revision")};before,after:=history.versions[0],history.versions[1]
  if before.compiled!=compiled||after.compiled!=compiled {t.Fatal("physical authority owner differs")}
  for _,p:=range history.versions {
   parsed,err:=pgParseRowPhysicalPlan(p.contract,p.hash);if err!=nil||parsed.compiled!=nil {t.Fatal("structural parse minted execution authority",err)}
   e:=p.entity("Note");if e.field("userURL")!="user_url"||e.field("userUri")!="user_uri" {t.Fatal("logical acronym order lost")}
  }
  if err:=pgValidateRowPhysicalLineage(before,after);err!=nil {t.Fatal(err)}
  aliases:=after.entity("Note").aliases;if len(aliases)!=1||aliases[0].logical!="owner"||aliases[0].physical!="author" {t.Fatal("actual old NOT NULL column has no typed write source")}
  if err:=pgBindRowPhysicalPlan(compiled,before,after);err!=nil {t.Fatal(err)}
  cases:=map[string]func(*pgRowCanonical){
   "same carrier old owners swapped":func(n *pgRowCanonical){a,b:=physicalProjectionNode(n,"title"),physicalProjectionNode(n,"userURL");a.children[1],b.children[1]=b.children[1],a.children[1]},
   "retained alias resurrected":func(n *pgRowCanonical){physicalProjectionNode(n,"owner").children[1]=pgRowAtom("author");n.children[6].children[0].children[8].children[0].children[1]=pgRowAtom("owner")},
   "retained write source omitted":func(n *pgRowCanonical){n.children[6].children[0].children[8]=pgRowList()},
   "independent old owners merged":func(n *pgRowCanonical){e:=&n.children[6].children[0];p:=e.children[6].children;for i,v:=range p{if v.children[0].isAtom("title"){e.children[6].children=append(p[:i],p[i+1:]...);break}};e.children[8].children=append(e.children[8].children,pgRowList(pgRowAtom("owner"),pgRowAtom("title")))},
   "new physical value invented as historical alias":func(n *pgRowCanonical){e:=&n.children[6].children[0];p:=e.children[6].children;for i,v:=range p{if v.children[0].isAtom("count"){e.children[6].children=append(p[:i],p[i+1:]...);break}};e.children[8].children=append(e.children[8].children,pgRowList(pgRowAtom("owner"),pgRowAtom("count")))},
   "old catalog nullability changed":func(n *pgRowCanonical){cols:=n.children[6].children[0].children[5].children;for i,c:=range cols{if c.children[0].isAtom("title"){cols[i].children[2]=pgRowBoolNode(true)}}},
   "retained column removed":func(n *pgRowCanonical){e:=&n.children[6].children[0];e.children[5].children=e.children[5].children[1:]},
   "future shadow column origin":func(n *pgRowCanonical){cols:=n.children[6].children[0].children[5].children;for i,c:=range cols{if c.children[0].isAtom("owner"){cols[i].children[4]=pgRowAtom("3")}}},
   "old write marker default advanced":func(n *pgRowCanonical){n.children[6].children[0].children[3]=pgRowAtom("2")},
   "invalidation omits old dependency":func(n *pgRowCanonical){w:=&n.children[7].children[0];w.children[7].children=w.children[7].children[1:]},
  }
  for name,change:=range cases {t.Run(name,func(t *testing.T){rejectPhysicalLineage(t,before,after,change)})}
  // Source hash substitution never rebinds a canonical physical plan.
  forged:=rewrittenPhysical(t,after,func(n *pgRowCanonical){n.children[4]=pgRowAtom(strings.Repeat("a",64));n.children[7].children[0].children[5]=n.children[4]})
  if err:=pgBindRowPhysicalPlan(compiled,before,forged);err==nil {t.Fatal("forged source snapshot accepted")}
  forged=rewrittenPhysical(t,after,func(n *pgRowCanonical){n.children[7].children[0].children[6]=pgRowAtom(strings.Repeat("b",64))})
  if err:=pgBindRowPhysicalPlan(compiled,before,forged);err==nil {t.Fatal("foreign callback accepted")}
  forged=rewrittenPhysical(t,after,func(n *pgRowCanonical){n.children[6].children[0].children[7]=pgRowList(pgRowList(pgRowAtom("invented"),pgRowList(pgRowAtom("title")),pgRowBoolNode(false)))})
  if err:=pgBindRowPhysicalPlan(compiled,before,forged);err==nil {t.Fatal("invented source index accepted")}
  forged=rewrittenPhysical(t,before,func(n *pgRowCanonical){for i,c:=range n.children[6].children[0].children[5].children{if c.children[0].isAtom("author"){n.children[6].children[0].children[5].children[i].children[2]=pgRowBoolNode(true)}}})
  if err:=pgBindRowPhysicalPlan(compiled,nil,forged);err==nil {t.Fatal("changed source nullability accepted")}
  forged=rewrittenPhysical(t,after,func(n *pgRowCanonical){cols:=n.children[6].children[1].children[5].children;for i,c:=range cols{if c.children[0].isAtom("label"){cols[i].children[2]=pgRowBoolNode(true)}}})
  if err:=pgBindRowPhysicalPlan(compiled,before,forged);err==nil {t.Fatal("later-born entity changed source nullability")}
  forged=rewrittenPhysical(t,after,func(n *pgRowCanonical){n.children[6].children[0].children[7].children=n.children[6].children[0].children[7].children[1:]})
  if err:=pgBindRowPhysicalPlan(compiled,before,forged);err==nil {t.Fatal("new source index omitted")}
  forged=rewrittenPhysical(t,after,func(n *pgRowCanonical){n.children[6].children[0].children[7].children[0].children[1]=pgRowList(pgRowAtom("title"))})
  if err:=pgBindRowPhysicalPlan(compiled,before,forged);err==nil {t.Fatal("new source index changed shape")}
  if _,err:=pgCompiledRowPhysicalPlan(nil,1);err==nil {t.Fatal("parsed source granted database authority")}
 }
}
|} in native ~source_root:root ~extra_tests:["internal/teslrt/physical_roundtrip_test.go",test] artifacts)
let physical_registration ()=project (fun root save path ->
 seal_edge root path;
 let family=replace "Schema.Notes" "Schema.Tasks" in
 let before=save "schema/tasks/v1.tesl" (family old) in
 let after=save "schema/tasks/v-current.tesl" (family fresh) in
 let header=match Migration_header.create ~previous:(seal root before) ~current:(seal root after) with
  | Ok header -> header | Error errors -> fail (String.concat "\n" (List.map (fun (e:S.error) -> e.message) errors)) in
 ignore(save "migrations/tasks/v2.tesl" (Migration_header.encode header ^ family source));
 ignore(save "second.tesl" (app |> replace "module App exposing []" "module Second exposing []" |> family |> replace "namespace: \"notes\"" "namespace: \"tasks\""));
 let file=save "app.tesl" (replace "import Tesl.Database" "import Second exposing []\nimport Tesl.Database" app) in
 accepts file (Source_input.read file);
 let artifacts=emit ~physical:true file in
 let test={|package teslrt
import("encoding/json";"testing")
func TestActualPhysicalRegistrationAtomicity(t *testing.T) {
 if len(compiledRowPhysicalHistories)!=2 {t.Fatal("missing two actual physical owners")}
 original:=compiledRowPhysicalHistories
 defer func(){compiledRowPhysicalHistories=original}()
 var payload string
 for _,h:=range original {payload=h.payload}
 mutate:=func(change func(map[string]any)) string {var obj map[string]any;if err:=json.Unmarshal([]byte(payload),&obj);err!=nil{t.Fatal(err)};change(obj);b,err:=json.Marshal(obj);if err!=nil{t.Fatal(err)};return string(b)}
 rejected:=func(name,text string){t.Helper();t.Run(name,func(t *testing.T){compiledRowPhysicalHistories=map[*pgCompiledRowHistory]*pgCompiledRowPhysicalHistory{};panicked:=false;func(){defer func(){panicked=recover()!=nil}();registerCompiledRowPhysicalHistory(text)}();if !panicked||len(compiledRowPhysicalHistories)!=0{t.Fatal("invalid complete envelope partially registered")}})}
 rejected("missing second database",mutate(func(o map[string]any){o["databases"]=o["databases"].([]any)[:1]}))
 rejected("duplicate family",mutate(func(o map[string]any){ds:=o["databases"].([]any);ds[1]=ds[0]}))
 rejected("second database owner",mutate(func(o map[string]any){o["databases"].([]any)[1].(map[string]any)["database"]="Foreign.Main"}))
 rejected("second database history hash",mutate(func(o map[string]any){o["databases"].([]any)[1].(map[string]any)["versions"].([]any)[1].(map[string]any)["hash"]="bad"}))
 rejected("ABI differs",mutate(func(o map[string]any){o["compilerAbi"]="foreign-build"}))
 rejected("compatibility differs",mutate(func(o map[string]any){o["storedValueCompatibility"]="foreign-contract"}))
 rejected("unknown envelope member",mutate(func(o map[string]any){o["unknown"]=true}))
 rejected("empty revisions",mutate(func(o map[string]any){o["databases"].([]any)[1].(map[string]any)["versions"]=[]any{}}))
 compiledRowPhysicalHistories=map[*pgCompiledRowHistory]*pgCompiledRowPhysicalHistory{}
 registerCompiledRowPhysicalHistory(payload)
 if len(compiledRowPhysicalHistories)!=2{t.Fatal("valid complete retry did not register both owners")}
 for owner,h:=range compiledRowPhysicalHistories{for _,p:=range h.versions{if p.compiled!=owner{t.Fatal("cross database physical authority")}}}
 registerCompiledRowPhysicalHistory(payload)
 if len(compiledRowPhysicalHistories)!=2{t.Fatal("exact repeated registration changed registry")}
 for owner:=range original {
  family:=owner.history.Family;old,exists:=pgMigrationClosedFamilies[family];pgMigrationClosedFamilies[family]=true
  func(){defer func(){if exists{pgMigrationClosedFamilies[family]=old}else{delete(pgMigrationClosedFamilies,family)}}();panicked:=false;func(){defer func(){panicked=recover()!=nil}();registerCompiledRowPhysicalHistory(payload)}();if !panicked{t.Fatal("closed application accepted a physical attachment")}}()
  break
 }
}
|} in native ~source_root:root ~extra_tests:["internal/teslrt/physical_registration_test.go",test] artifacts)

let export_physical destination = project (fun root save path ->
 let export version file =
  let artifacts=emit ~physical:true file in
  List.iter (fun (artifact:Emit_go.artifact) -> write (Filename.concat destination (version ^ "/" ^ artifact.path)) artifact.contents) artifacts in
 seal_edge root path;let file=save "app.tesl" app in accepts file (Source_input.read file);export "v2" file;
 remove path;remove (Filename.concat root "schema/notes/v1.tesl");
 ignore(save "schema/notes/v-current.tesl" (replace "Schema.Notes.V1" "Schema.Notes.VCurrent" old));
 accepts file (Source_input.read file);export "v1" file)
let () = Option.iter export_physical (Sys.getenv_opt "TESL_PHYSICAL_TEST_EXPORT")
let ()=run "checked row storage adapters" ["storage",[
 test_case "physical companion roundtrip and source binding" `Quick physical_roundtrip;
 test_case "complete physical registration is atomic" `Quick physical_registration;
 test_case "native generated adapters and stable semantic link" `Quick smoke;
 test_case "actual PostgreSQL private proof JSONB codecs" `Quick shared_fixture;
 test_case "retained nominal JSONB migration boundary" `Quick nominal_boundary;
 test_case "direct ADT compiler-owned carrier" `Quick adt_boundary]]
