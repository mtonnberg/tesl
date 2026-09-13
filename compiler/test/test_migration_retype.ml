open Alcotest
module S=Migration_sparse
let old = {|module Schema.Notes.V1 exposing [Note, Metadata]
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
record Metadata { text: String }
codec Metadata {
 toJson { text -> "oldText" with_codec stringCodec }
 fromJson [ { text <- "oldText" with_codec stringCodec } ]
}
entity Note table "notes" primaryKey id { id: String, metadata: Metadata }
|}
let fresh = {|module Schema.Notes.VCurrent exposing [Note, Metadata]
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
record Metadata { text: String, extra: String }
codec Metadata {
 toJson { text -> "newText" with_codec stringCodec, extra -> "detail" with_codec stringCodec }
 fromJson [ { text <- "newText" with_codec stringCodec, extra <- "detail" with_codec stringCodec } ]
}
entity Note table "notes" primaryKey id { metadata: Metadata @column("metadata__v2"), id: String }
|}
let source = {|module Schema.Notes.Migrate.V2 exposing [migration, oldNote]
import Tesl.Prelude exposing [String]
import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Migrated(..)]
import Schema.Notes.V1
import Schema.Notes.VCurrent
migration = Migration {
 from: Schema.Notes.V1
 to: Schema.Notes.VCurrent
 same: []
 fixtures: [oldNote]
 entities: { Note: Migrate convert [Retype metadata, WriteBack metadata metadata backward] }
}
fn convert(old: Schema.Notes.V1.Note) -> Migrated Schema.Notes.VCurrent.Note =
 Row (Schema.Notes.VCurrent.Note { id: old.id, metadata: Schema.Notes.VCurrent.Metadata { text: old.metadata.text, extra: "new" } })
fn backward(row: Schema.Notes.VCurrent.Note) -> Schema.Notes.V1.Metadata =
 Schema.Notes.V1.Metadata { text: row.metadata.text }
fn oldNote() -> Schema.Notes.V1.Note =
 Schema.Notes.V1.Note { id: "one", metadata: Schema.Notes.V1.Metadata { text: "old" } }
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
let emit file = match Compile.compile_row_source_artifacts ~storage:true file (Source_input.read file) with
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

let replace a b s=Str.global_replace (Str.regexp_string a) b s
let reseal root path body =
 let before=Filename.concat root "schema/notes/v1.tesl" and after=Filename.concat root "schema/notes/v-current.tesl" in
 let header=match Migration_header.create ~previous:(seal root before) ~current:(seal root after) with
  | Ok h -> h | Error errors -> fail (String.concat "\n" (List.map (fun (e:S.error) -> e.message) errors)) in
 write path (Migration_header.encode header ^ body)
let postgres = {|package teslmodapp
import (
 "context"
 "os"
 "strconv"
 "testing"
 "time"
 "github.com/jackc/pgx/v5"
 rt "tesl.generated/teslmodapp/internal/teslrt"
 fresh "tesl.generated/teslmodapp/internal/teslmodschemanotesvcurrent"
)
func TestRetypeRecordPostgres(t *testing.T) {
 host:=os.Getenv("TESL_TEST_POSTGRES_SHARED_HOST")
 if host=="" {if os.Getenv("TESL_MIGRATION_TEST_REQUIRE_POSTGRES")=="1"{t.Fatal("PostgreSQL required")};t.Skip("PostgreSQL unavailable")}
 cfg,err:=pgx.ParseConfig("");if err!=nil {t.Fatal(err)}
 cfg.Host=host;cfg.User=os.Getenv("TESL_TEST_POSTGRES_SHARED_USER");cfg.Database="postgres";cfg.TLSConfig=nil
 if v:=os.Getenv("TESL_TEST_POSTGRES_SHARED_ADMIN_DATABASE");v!="" {cfg.Database=v}
 port,err:=strconv.Atoi(os.Getenv("TESL_TEST_POSTGRES_SHARED_PORT"));if err!=nil{t.Fatal(err)};cfg.Port=uint16(port)
 ctx,cancel:=context.WithTimeout(context.Background(),30*time.Second);defer cancel()
 conn,err:=pgx.ConnectConfig(ctx,cfg);if err!=nil{t.Fatal(err)};defer conn.Close(ctx)
 storage:=MainDatabaseCompiledRowStorage0;backward:=MainDatabaseCompiledRowWriteBack0
 if _,err:=backward.Reverse(fresh.Note{});err==nil{t.Fatal("unsealed reverse accepted")}
 if err:=rt.PreflightApplicationDatabases(MainDatabase);err!=nil{t.Fatal(err)}
 source,err:=storage.SourceProjection().CheckOrder([]string{"id","metadata"});if err!=nil{t.Fatal(err)}
 target,err:=storage.TargetProjection().CheckOrder([]string{"metadata","id"});if err!=nil{t.Fatal(err)}
 // The two versioned physical JSONB columns share one logical field. Their
 // wire formats deliberately differ; only the checked constructors bridge them.
 _,err=conn.Exec(ctx,`CREATE TEMP TABLE "retype""notes" (id text PRIMARY KEY,metadata jsonb NOT NULL,metadata__v2 jsonb)`);if err!=nil{t.Fatal(err)}
 _,err=conn.Exec(ctx,`INSERT INTO "retype""notes" VALUES ('one','{"oldText":"distinct"}',NULL)`);if err!=nil{t.Fatal(err)}
 rows,err:=conn.Query(ctx,`SELECT id AS id,metadata AS metadata FROM "retype""notes"`);if err!=nil{t.Fatal(err)}
 if !rows.Next(){t.Fatal(rows.Err())};old,err:=storage.Decode(source,rows);rows.Close();if err!=nil{t.Fatal(err)}
 migrated,err:=MainDatabaseCompiledRowTransform0.Run(old);if err!=nil||migrated.Tag!=rt.MigratedRow{t.Fatal("actual Tesl transform",err)}
 value:=migrated.RowValue
 if value.Metadata.Text!="distinct"||value.Metadata.Extra!="new"{t.Fatal("new nominal constructor lost fields")}
 encoded,err:=storage.Encode(value);if err!=nil{t.Fatal(err)}
 params,err:=encoded.Parameters(target);if err!=nil{t.Fatal(err)}
 if _,err:=encoded.Parameters(source);err==nil{t.Fatal("foreign direction accepted")}
 _,err=conn.Exec(ctx,`UPDATE "retype""notes" SET metadata__v2=$1 WHERE id=$2`,params...);if err!=nil{t.Fatal(err)}
 value.Metadata.Text="new-write"
 reverse,err:=backward.Reverse(value);if err!=nil||reverse.Metadata.Text!="new-write"{t.Fatal("actual Tesl WriteBack",err)}
 legacy,err:=backward.Encode(value);if err!=nil{t.Fatal(err)}
 legacyParams,err:=legacy.Parameters(source);if err!=nil{t.Fatal(err)}
 _,err=conn.Exec(ctx,`UPDATE "retype""notes" SET metadata=$2 WHERE id=$1`,legacyParams...);if err!=nil{t.Fatal(err)}
 var newText,oldText string
 err=conn.QueryRow(ctx,`SELECT metadata__v2->>'newText',metadata->>'oldText' FROM "retype""notes"`).Scan(&newText,&oldText)
 if err!=nil||newText!="distinct"||oldText!="new-write"{t.Fatal("versioned codec writeback mismatch",err,newText,oldText)}
 rows,err=conn.Query(ctx,`SELECT id AS id,metadata AS metadata FROM "retype""notes"`);if err!=nil{t.Fatal(err)}
 if !rows.Next(){t.Fatal(rows.Err())};readback,err:=storage.Decode(source,rows);rows.Close();if err!=nil||readback.Metadata.Text!="new-write"{t.Fatal("old decoder readback",err)}
}
|}
let record () = project (fun root save path ->
 seal_edge root path;let file=save "app.tesl" app in accepts file (Source_input.read file);
 let artifacts=emit file in
 check bool "v3 companion" true (contains (artifact "row-transform-history.json" artifacts) "\"version\":3");
 native ~source_root:root ~test:postgres artifacts)
let refuses label before after body code =
 project ~before ~after (fun root save path ->
  reseal root path body;let file=save "app.tesl" app in
  let ds=errors file (Source_input.read file) in
  check bool (label ^ "\n" ^ describe ds) true (List.exists (fun (d:Compile.diagnostic) -> d.code=code) ds))
let negatives () =
 refuses "missing WriteBack" old fresh (replace ", WriteBack metadata metadata backward" "" source) "MIG022";
 refuses "wrong generated physical name" old (replace "metadata__v2" "metadata__v3" fresh) source "MIG027";
 refuses "no Retype judgment" old fresh (replace "Retype metadata, " "" source) "MIG022";
 refuses "wrong nominal return" old fresh (replace "-> Schema.Notes.V1.Metadata =" "-> Schema.Notes.VCurrent.Metadata =" source) "MIG021";
 refuses "wrong source endpoint" old fresh (replace "WriteBack metadata metadata backward" "WriteBack id metadata backward" source) "MIG009";
 refuses "duplicate WriteBack" old fresh (replace "WriteBack metadata metadata backward" "WriteBack metadata metadata backward, WriteBack metadata metadata backward" source) "MIG023"
let adt () =
 let before={|module Schema.Notes.V1 exposing [Note, Metadata(..)]
import Tesl.Prelude exposing [String]
type Metadata =
 | Named text: String
 | Absent
codec Metadata { adtJson }
entity Note table "notes" primaryKey id { id: String, metadata: Metadata }
|} in
 let after={|module Schema.Notes.VCurrent exposing [Note, Metadata(..)]
import Tesl.Prelude exposing [String]
type Metadata =
 | Details text: String extra: String
 | Missing
codec Metadata { adtJson }
entity Note table "notes" primaryKey id { metadata: Metadata @column("metadata__v2"), id: String }
|} in
 let body=source
  |> replace "Schema.Notes.VCurrent.Metadata { text: old.metadata.text, extra: \"new\" }" "upgrade old.metadata"
  |> replace "Schema.Notes.V1.Metadata { text: row.metadata.text }" "downgrade row.metadata"
  |> replace "Schema.Notes.V1.Metadata { text: \"old\" }" "Schema.Notes.V1.Named { text: \"old\" }"
  |> fun s -> s ^ {|
fn upgrade(value: Schema.Notes.V1.Metadata) -> Schema.Notes.VCurrent.Metadata =
 case value of
  Schema.Notes.V1.Named { text } -> Schema.Notes.VCurrent.Details { text: text, extra: "new" }
  Schema.Notes.V1.Absent -> Schema.Notes.VCurrent.Missing
fn downgrade(value: Schema.Notes.VCurrent.Metadata) -> Schema.Notes.V1.Metadata =
 case value of
  Schema.Notes.VCurrent.Details { text, extra } -> Schema.Notes.V1.Named { text: text ++ "-back" }
  Schema.Notes.VCurrent.Missing -> Schema.Notes.V1.Absent
|} in
 let test=postgres
  |> replace "TestRetypeRecordPostgres" "TestRetypeADTPostgres"
  |> replace {|{"oldText":"distinct"}|} {|{"tag":"Named","fields":{"text":"distinct"}}|}
  |> replace {|if value.Metadata.Text!="distinct"||value.Metadata.Extra!="new"{t.Fatal("new nominal constructor lost fields")}|} ""
  |> replace {|value.Metadata.Text="new-write"|} ""
  |> replace {|reverse,err:=backward.Reverse(value);if err!=nil||reverse.Metadata.Text!="new-write"{t.Fatal("actual Tesl WriteBack",err)}|} ""
  |> replace "metadata__v2->>'newText',metadata->>'oldText'" "metadata__v2->'fields'->>'text',metadata->'fields'->>'text'"
  |> replace {|oldText!="new-write"|} {|oldText!="distinct-back"|}
  |> replace {|readback,err:=storage.Decode(source,rows);rows.Close();if err!=nil||readback.Metadata.Text!="new-write"{t.Fatal("old decoder readback",err)}|} {|_,err=storage.Decode(source,rows);rows.Close();if err!=nil{t.Fatal("old decoder readback",err)}|} in
 project ~before ~after (fun root save path -> reseal root path body;
  let file=save "app.tesl" app in accepts file (Source_input.read file);native ~source_root:root ~test (emit file))
let generated_column ()=project (fun root save path ->
 seal_edge root path;
 let missing=replace " @column(\"metadata__v2\")" "" fresh in
 let target=save "schema/notes/v-current.tesl" missing in
 let abi=Result.get_ok (Migration_abi.current ()) in
 let preview=match Migration_generate.refresh_with_compatibility
   ~stored_value_compatibility:(Some (Migration_abi.stored_value_compatibility abi))
   ~compiler_abi:(Migration_abi.id abi) ~project_root:root ~family:"Schema.Notes" ~version:2 ~documents:[] with
  | Ok p -> p | Error errors -> fail (String.concat "\n" (List.map (fun (e:Migration_generate.error) -> e.message) errors)) in
 check string "generation does not mutate source" missing (Source_input.read target);
 let edits=Migration_manifest.overlays preview.manifest in
 check bool "generator owns introducing physical column" true
  (Option.fold ~none:false ~some:(fun s -> contains s "@column(\"metadata__v2\")") (List.assoc_opt target edits));
 check bool (describe preview.diagnostics) false (List.exists (fun (d:Compile.diagnostic) -> d.severity="error") preview.diagnostics);
 Source_input.with_overlays ~project_root:root edits (fun () -> accepts path (Source_input.read path)))
let semantic_writeback ()=project (fun root save path ->
 seal_edge root path;let file=save "app.tesl" app in
 let hash artifacts=let open Yojson.Basic.Util in Yojson.Basic.from_string (artifact "row-transform-history.json" artifacts)
  |> member "databases" |> to_list |> List.hd |> member "transforms" |> to_list |> List.hd |> member "transformContractHash" |> to_string in
 let first=hash (emit file) in
 reseal root path (replace "text: row.metadata.text" "text: row.metadata.text ++ \"-changed\"" source);
 check bool "WriteBack body closure affects callback identity" false (first=hash (emit file)))
let proof_nullable () =
 let binding_test={|package teslrt
import (
 "encoding/hex"
 "encoding/json"
 "strings"
 "testing"
)
func TestActualTwoWriteBackSemanticBijection(t *testing.T) {
 history:=compiledRowHistories["Schema.Notes"].history
 original,err:=pgReadRowCompanion(history,teslGeneratedRowHistoryJSON)
 if err!=nil||len(original)!=1||len(original[0].Transforms)!=1||len(original[0].Transforms[0].WriteBacks)!=2 {
  t.Fatal("actual complete two-field WriteBack refused",err)
 }
 for _,duplicate:=range []int{0,1} {
  t.Run([]string{"duplicate-first-omit-second","duplicate-second-omit-first"}[duplicate],func(t *testing.T){
   var envelope map[string]any
   if err:=json.Unmarshal([]byte(teslGeneratedRowHistoryJSON),&envelope);err!=nil{t.Fatal(err)}
   descriptor:=envelope["databases"].([]any)[0].(map[string]any)["transforms"].([]any)[0].(map[string]any)
   document,_,err:=pgReadRowCanonical(descriptor["transformContract"].(string));if err!=nil{t.Fatal(err)}
   writes:=&document.children[3].children[3].children[0].children[6].children[2]
   if len(writes.children)!=2||writes.children[0].children[1].value==writes.children[1].children[1].value{t.Fatal("test requires two distinct checked endpoints")}
   writes.children[1-duplicate]=writes.children[duplicate]
   // Update both bytes and hash so refusal must come from the endpoint
   // inventory check, never stale canonical digest validation.
   raw,hash:=pgRowBaselineDocument(document.children[3])
   descriptor["transformContract"],descriptor["transformContractHash"]=hex.EncodeToString([]byte(raw)),hash
   payload,err:=json.Marshal(envelope);if err!=nil{t.Fatal(err)}
   _,err=pgReadRowCompanion(history,string(payload))
   if err==nil||!strings.Contains(err.Error(),"WriteBack semantic closure endpoints are not a bijection") {
    t.Fatal("duplicate closure hid an omitted reverse field",err)
   }
  })
 }
}
|} in
 let proof={|fact ValidText (value: String)
check checkedText(value: String) -> value: String ::: ValidText value =
 if value != "bad" then
  ok value ::: ValidText value
 else
  fail 400 "private-codec-secret-sentinel"
establish trustedText(value: String) -> Fact (ValidText value) = ValidText value
|} in
 let schema text=text
  |> replace "exposing [Note, Metadata]" "exposing [Note, Metadata, ValidText, trustedText]"
  |> replace "import Tesl.Json" "import Tesl.Maybe exposing [Maybe(..)]\nimport Tesl.Json"
  |> replace "record Metadata" (proof ^ "record Metadata")
  |> replace "record Metadata { text: String" "record Metadata { text: String ::: ValidText text"
  |> replace {|text <- "oldText" with_codec stringCodec|} {|text <- "oldText" with_codec stringCodec via checkedText|}
  |> replace {|text <- "newText" with_codec stringCodec|} {|text <- "newText" with_codec stringCodec via checkedText|} in
 let before=schema old |> replace "metadata: Metadata }" "metadata: Metadata, optionalMetadata: Maybe Metadata }" in
 let after=schema fresh |> replace {|@column("metadata__v2"), id|} {|@column("metadata__v2"), optionalMetadata: Maybe Metadata @column("optional_metadata__v2"), id|} in
 let body=source
  |> replace "import Tesl.Prelude" "import Tesl.Maybe exposing [Maybe(..)]\nimport Tesl.Prelude"
  |> replace "WriteBack metadata metadata backward]" "WriteBack metadata metadata backward, Retype optionalMetadata, WriteBack optionalMetadata optionalMetadata backOptional]"
  |> replace {|Row (Schema.Notes.VCurrent.Note|} {|if old.id == "reject" then
  Reject "expected rejection"
 else
  Row (Schema.Notes.VCurrent.Note|}
  |> replace {|metadata: Schema.Notes.VCurrent.Metadata { text: old.metadata.text, extra: "new" }|} {|metadata: newMetadata old.metadata.text, optionalMetadata: upgradeOptional old.optionalMetadata|}
  |> replace {| Schema.Notes.V1.Metadata { text: row.metadata.text }|} {| oldMetadata row.metadata.text|}
  |> replace {|metadata: Schema.Notes.V1.Metadata { text: "old" }|} {|metadata: oldMetadata "old", optionalMetadata: Nothing|}
  |> fun text -> text ^ {|
fn newMetadata(text: String) -> Schema.Notes.VCurrent.Metadata =
 let proof = Schema.Notes.VCurrent.trustedText text
 Schema.Notes.VCurrent.Metadata { text: text ::: proof, extra: "new" }
fn oldMetadata(text: String) -> Schema.Notes.V1.Metadata =
 let proof = Schema.Notes.V1.trustedText text
 Schema.Notes.V1.Metadata { text: text ::: proof }
fn upgradeOptional(value: Maybe Schema.Notes.V1.Metadata) -> Maybe Schema.Notes.VCurrent.Metadata =
 case value of
  Nothing -> Nothing
  Something item -> Something (newMetadata item.text)
fn backOptional(row: Schema.Notes.VCurrent.Note) -> Maybe Schema.Notes.V1.Metadata =
 case row.optionalMetadata of
  Nothing -> Nothing
  Something item -> Something (oldMetadata item.text)
|} in
 let test=postgres
  |> replace {|"testing"|} {|"testing"
 "strings"|}
  |> replace {|[]string{"id","metadata"}|} {|[]string{"id","metadata","optionalMetadata"}|}
  |> replace {|[]string{"metadata","id"}|} {|[]string{"metadata","optionalMetadata","id"}|}
  |> replace {|metadata jsonb NOT NULL,metadata__v2 jsonb|} {|metadata jsonb NOT NULL,optional_metadata jsonb,metadata__v2 jsonb,optional_metadata__v2 jsonb|}
  |> replace {|VALUES ('one','{"oldText":"distinct"}',NULL)|} {|VALUES ('one','{"oldText":"distinct"}',NULL,NULL,NULL)|}
  |> replace {|SELECT id AS id,metadata AS metadata FROM|} {|SELECT id AS id,metadata AS metadata,optional_metadata AS "optionalMetadata" FROM|}
  |> replace {|SET metadata__v2=$1 WHERE id=$2|} {|SET metadata__v2=$1,optional_metadata__v2=$2 WHERE id=$3|}
  |> replace {|SET metadata=$2 WHERE id=$1|} {|SET metadata=$2,optional_metadata=$3 WHERE id=$1|}
  |> replace {|migrated,err:=MainDatabaseCompiledRowTransform0.Run(old)|} {|old.Id="reject";rejected,err:=MainDatabaseCompiledRowTransform0.Run(old);if err!=nil||rejected.Tag!=rt.MigratedReject{t.Fatal("actual Tesl Reject branch",err)};old.Id="one"
 migrated,err:=MainDatabaseCompiledRowTransform0.Run(old)|}
  |> replace {|if value.Metadata.Text!="distinct"|} {|if value.OptionalMetadata.Tag!=rt.MaybeNothing{t.Fatal("SQL NULL optional JSONB changed")}
 if value.Metadata.Text!="distinct"|}
  |> replace {|value.Metadata.Text="new-write"|} {|value.Metadata.Text="new-write"
 value.OptionalMetadata=rt.Something(fresh.Metadata{Text:"second-write",Extra:"new"})|}
  |> replace {|reverse.Metadata.Text!="new-write"|} {|reverse.Metadata.Text!="new-write"||reverse.OptionalMetadata.Tag!=rt.MaybeSomething||reverse.OptionalMetadata.SomethingValue.Text!="second-write"|}
  |> replace {|readback.Metadata.Text!="new-write"{t.Fatal("old decoder readback",err)}|} {|readback.Metadata.Text!="new-write"{t.Fatal("old decoder readback",err)}
 _,err=conn.Exec(ctx,`UPDATE "retype""notes" SET optional_metadata='null'`);if err!=nil{t.Fatal(err)}
 rows,err=conn.Query(ctx,`SELECT id AS id,metadata AS metadata,optional_metadata AS "optionalMetadata" FROM "retype""notes"`);if err!=nil{t.Fatal(err)}
 if !rows.Next(){t.Fatal(rows.Err())};_,err=storage.Decode(source,rows);rows.Close();if err==nil{t.Fatal("JSON null confused with SQL NULL")}
 _,err=conn.Exec(ctx,`UPDATE "retype""notes" SET optional_metadata=NULL,metadata='{"oldText":"bad"}'`);if err!=nil{t.Fatal(err)}
 rows,err=conn.Query(ctx,`SELECT id AS id,metadata AS metadata,optional_metadata AS "optionalMetadata" FROM "retype""notes"`);if err!=nil{t.Fatal(err)}
 if !rows.Next(){t.Fatal(rows.Err())};_,err=storage.Decode(source,rows);rows.Close();if err==nil||strings.Contains(err.Error(),"secret-sentinel"){t.Fatal("old private proof decoder refusal",err)}|}
  |> replace {|readback.Metadata.Text!="new-write"|} {|readback.Metadata.Text!="new-write"||readback.OptionalMetadata.Tag!=rt.MaybeSomething||readback.OptionalMetadata.SomethingValue.Text!="second-write"|} in
 project ~before ~after (fun root save path -> reseal root path body;
  let file=save "app.tesl" app in accepts file (Source_input.read file);
  native ~source_root:root ~test ~extra_tests:["internal/teslrt/migration_writeback_bijection_test.go",binding_test] (emit file))
let writeback_registration ()=project (fun root save path ->
 seal_edge root path;let file=save "app.tesl" app in
 let artifacts=emit file |> List.map (fun (a:Emit_go.artifact) ->
  if a.path<>"internal/teslmodapp/migration_rows_MainDatabase_generated.go" then a else
  let lines=String.split_on_char '\n' a.contents in
  let without=List.filter (fun line -> not (String.starts_with ~prefix:"var MainDatabaseCompiledRowWriteBack0 =" line)) lines in
  check int "remove exactly the emitted reverse registration" 1 (List.length lines-List.length without);
  {a with contents=String.concat "\n" without}) in
 native ~source_root:root artifacts ~test:{|package teslmodapp
import (
 "strings"
 "testing"
 rt "tesl.generated/teslmodapp/internal/teslrt"
 old "tesl.generated/teslmodapp/internal/teslmodschemanotesv1"
 fresh "tesl.generated/teslmodapp/internal/teslmodschemanotesvcurrent"
 migration "tesl.generated/teslmodapp/internal/teslmodschemanotesmigratev2"
)
func expectWriteBackPanic(t *testing.T,fn func()){t.Helper();caught:=false;func(){defer func(){caught=recover()!=nil}();fn()}();if !caught{t.Fatal("expected WriteBack refusal")}}
func TestMissingWriteBackThenRetry(t *testing.T){
 if err:=rt.PreflightApplicationDatabases(MainDatabase);err==nil||!strings.Contains(err.Error(),"WriteBack adapter bindings are incomplete"){t.Fatal("missing WriteBack exact completeness guard",err)}
 if _,err:=MainDatabaseCompiledRowTransform0.Run(old.Note{});err==nil{t.Fatal("failed preflight sealed callback")}
 callback:=func(row fresh.Note)old.Note{return old.Note{Id:row.Id,Metadata:migration.TeslCompiledWriteBackCallback(row)}}
 expectWriteBackPanic(t,func(){rt.RegisterCompiledRowWriteBack(MainDatabaseCompiledRowStorage0,nil)})
 expectWriteBackPanic(t,func(){rt.RegisterCompiledRowWriteBack[old.Note,fresh.Note](nil,callback)})
 adapter:=rt.RegisterCompiledRowWriteBack(MainDatabaseCompiledRowStorage0,callback)
 expectWriteBackPanic(t,func(){rt.RegisterCompiledRowWriteBack(MainDatabaseCompiledRowStorage0,callback)})
 if _,err:=adapter.Reverse(fresh.Note{});err==nil{t.Fatal("unsealed reverse ran")}
 if err:=rt.PreflightApplicationDatabases(MainDatabase);err!=nil{t.Fatal(err)}
 row,err:=adapter.Reverse(fresh.Note{Id:"kept",Metadata:fresh.Metadata{Text:"old-readable",Extra:"new-only"}})
 if err!=nil||row.Id!="kept"||row.Metadata.Text!="old-readable"{t.Fatal("actual checked private g after retry",err)}
 expectWriteBackPanic(t,func(){rt.RegisterCompiledRowWriteBack(MainDatabaseCompiledRowStorage0,callback)})
}
|})
let wire_tests={|package teslrt
import (
 "encoding/json"
 "strings"
 "testing"
)
func TestActualCompiledWriteBackWireRefusals(t *testing.T){
 base:=compiledRowHistories["Schema.Notes"].history
 mutate:=func(name,reason string,fn func(map[string]any,map[string]any)){
  t.Run(name,func(t *testing.T){
   var value map[string]any
   if err:=json.Unmarshal([]byte(teslGeneratedRowHistoryJSON),&value);err!=nil{t.Fatal(err)}
   db:=value["databases"].([]any)[0].(map[string]any)
   transform:=db["transforms"].([]any)[0].(map[string]any)
   fn(value,transform)
   bytes,err:=json.Marshal(value);if err!=nil{t.Fatal(err)}
   _,err=pgReadRowCompanion(base,string(bytes))
   if err==nil||!strings.Contains(err.Error(),reason){t.Fatal("wrong refusal",err)}
  })
 }
 mutate("missing-writeback","lacks its exact",func(_,d map[string]any){d["writeBacks"]=[]any{}})
 mutate("wrong-current","invalid WriteBack endpoints",func(_,d map[string]any){d["writeBacks"].([]any)[0].(map[string]any)["current"]="id"})
 mutate("duplicate","invalid WriteBack endpoints",func(_,d map[string]any){writes:=d["writeBacks"].([]any);d["writeBacks"]=append(writes,writes[0])})
 mutate("v2-strict","unexpected",func(root,_ map[string]any){root["version"]=2})
 mutate("v1-strict","unexpected",func(root,_ map[string]any){root["version"]=1})
 mutate("wrong-physical","exact adjacent source inventories",func(_,d map[string]any){d["targetSchemaColumns"].([]any)[1].(map[string]any)["name"]="metadata__v3"})
 mutate("foreign-direction","exact adjacent source inventories",func(_,d map[string]any){d["fromTypeContractHash"]=d["toTypeContractHash"]})
}
|}
let wire_refusals ()=project (fun root save path ->
 seal_edge root path;let file=save "app.tesl" app in
 native ~source_root:root ~extra_tests:["internal/teslrt/migration_writeback_wire_test.go",wire_tests] (emit file))
let renamed_retype () =
 let after=fresh |> replace "metadata: Metadata" "payload: Metadata" |> replace "metadata__v2" "payload__v2" in
 let body=source |> replace "Retype metadata, WriteBack metadata metadata backward" "Rename metadata payload, Retype payload, WriteBack metadata payload backward"
  |> replace "metadata: Schema.Notes.VCurrent.Metadata" "payload: Schema.Notes.VCurrent.Metadata"
  |> replace "row.metadata.text" "row.payload.text" in
 project ~after (fun root save path -> reseal root path body;
  let file=save "app.tesl" app in accepts file (Source_input.read file);native ~source_root:root (emit file))
let removed_computed_writeback () =
 let after=fresh |> replace {|metadata: Metadata @column("metadata__v2")|} "payload: Metadata" in
 let body=source |> replace "Retype metadata, WriteBack metadata metadata backward" "WriteBack metadata payload backward"
  |> replace "metadata: Schema.Notes.VCurrent.Metadata" "payload: Schema.Notes.VCurrent.Metadata"
  |> replace "row.metadata.text" "row.payload.text" in
 project ~after (fun root save path -> reseal root path body;
  let file=save "app.tesl" app in accepts file (Source_input.read file);native ~source_root:root (emit file))
let storage_source_ownership () =
 let ordinary="module App exposing []\nimport Tesl.Prelude exposing [String]\nentity Note table \"notes\" primaryKey id { id: String, title: String @column(\"title__v2\") }\n" in
 check bool "ordinary entities cannot claim compiler-owned storage" true
  (List.exists (fun (d:Compile.diagnostic) -> d.code="MIG027") (errors "/tmp/retype-ordinary-owner.tesl" ordinary));
 let body=fresh |> replace {|metadata: Metadata @column("metadata__v2"), id: String|} "\n\tmetadata: Metadata @db(jsonb) # keep comment ä\n\tid: String\n" in
 let view=match Migration_source_syntax.read ~file:"v-current.tesl" ~source:body with Ok v -> v | Error e -> fail e.message in
 let field=List.find_map (function Ast.DEntity e -> List.find_opt (fun (f:Ast.field_def) -> f.name="metadata") e.fields | _ -> None) (Migration_source_syntax.module_ view).decls |> Option.get in
 let get=function Ok value->value|Error (e:Migration_source_syntax.error)->fail e.message in
 let point=get (Migration_source_syntax.field_storage_point view field) in
 let edited=get (Migration_source_syntax.replace view [point,{| @column("metadata__v2")|}]) in
 check bool "exact annotation endpoint retains db override and comment" true (contains edited {|@db(jsonb) @column("metadata__v2") # keep comment ä|});
 let foreign={field with db_column=Some "forged"} in
 check bool "reconstructed source field refuses" true (Result.is_error (Migration_source_syntax.field_storage_point view foreign));
 let invalid=replace {|metadata: Metadata @column("metadata__v2")|} {|metadata: Metadata @column("a") @column("b")|} fresh in
 check bool "duplicate physical annotation refuses parsing" true (match Parser.parse_module "v-current.tesl" invalid with Err _ -> true | Ok _ -> false)
let malformed_storage_annotations () =
 List.iter (fun annotation ->
  let text="module App exposing []\nimport Tesl.Prelude exposing [String]\nentity Note table \"notes\" primaryKey id { id: String, title: String " ^ annotation ^ " }\n" in
  check bool ("malformed final field must refuse: " ^ annotation) true
   (match Parser.parse_module "/tmp/malformed-storage.tesl" text with Err _ -> true | Ok _ -> false))
 ["@column(\"title__v2\""; "@db(jsonb"; "@column("; "@db("]
let cross_field_reverse_boundary () =
 let schema text=text |> replace "exposing [Note, Metadata]" "exposing [Note, Metadata, Related]"
  |> replace "record Metadata" "fact Related (left: String) (right: String)\nrecord Metadata"
  |> replace "primaryKey id {" "primaryKey id { tag: String ::: Related tag id," in
 let body=source |> replace "Rule(..), Migrated(..)" "Rule(..), Same(..), Migrated(..)"
  |> replace "same: []" "same: [Same Schema.Notes.V1.Related Schema.Notes.VCurrent.Related]"
  |> replace "id: old.id," "id: old.id, tag: old.tag," in
 refuses "old cross-field predicates need full reverse proof" (schema old) (schema fresh) body "MIG021";
 let nested text=schema text |> replace "Metadata, Related]" "Metadata, Related, Local]" |> replace "fact Related" "fact Local (value: String)\nfact Related"
  |> replace "Related tag id," "Local tag && Local tag && Related tag id," in
 refuses "nested sibling predicate needs whole reverse proof" (nested old) (nested fresh)
  (body |> replace "same: [Same" "same: [Same Schema.Notes.V1.Local Schema.Notes.VCurrent.Local, Same") "MIG021"
let unary_reverse_copy () =
 let schema text=text |> replace "exposing [Note, Metadata]" "exposing [Note, Metadata, ValidTag, tagProof]"
  |> replace "record Metadata" "fact ValidTag (value: String)\nestablish tagProof(value: String) -> Fact (ValidTag value) = ValidTag value\nrecord Metadata"
  |> replace "primaryKey id {" "primaryKey id { tag: String ::: ValidTag tag," in
 let body=source |> replace "Rule(..), Migrated(..)" "Rule(..), Same(..), Migrated(..)"
  |> replace "same: []" "same: [Same Schema.Notes.V1.ValidTag Schema.Notes.VCurrent.ValidTag]"
  |> replace "id: old.id," "id: old.id, tag: old.tag,"
  |> replace "fn oldNote() -> Schema.Notes.V1.Note =" "fn oldNote() -> Schema.Notes.V1.Note =\n let tag = \"fixture-tag\"\n let proof = Schema.Notes.V1.tagProof tag"
  |> replace "id: \"one\"," "id: \"one\", tag: tag ::: proof," in
 project ~before:(schema old) ~after:(schema fresh) (fun root save path ->
  reseal root path body; let file=save "app.tesl" app in
  accepts file (Source_input.read file); native ~source_root:root (emit file))
let ()=run "checked Retype and WriteBack" ["retype",[
 test_case "nominal JSONB actual PostgreSQL bidirectional codecs" `Quick record;
 test_case "rule and exact nominal signature refusals" `Quick negatives;
 test_case "nominal ADT PostgreSQL bidirectional codecs" `Quick adt;
 test_case "guarded refresh generates Retype storage identity" `Quick generated_column;
 test_case "WriteBack semantic closure is hashed" `Quick semantic_writeback;
 test_case "private proof codecs nullable JSONB and actual Reject" `Quick proof_nullable;
 test_case "WriteBack registration completeness and retry" `Quick writeback_registration;
 test_case "actual emitted v3 wire substitution refusal" `Quick wire_refusals;
 test_case "Rename plus Retype exact endpoints" `Quick renamed_retype;
 test_case "removed field with computed target WriteBack" `Quick removed_computed_writeback;
 test_case "exact field source ownership and annotation syntax" `Quick storage_source_ownership;
 test_case "old cross-field reverse proof boundary" `Quick cross_field_reverse_boundary;
 test_case "unary copied proof with generated reverse constructor" `Quick unary_reverse_copy;
 test_case "malformed final storage annotations refuse" `Quick malformed_storage_annotations]]
