open Alcotest
module Q = Migration_queue_transform
module I = Migration_inventory
let replace a b = Str.global_replace (Str.regexp_string a) b
let rec mkdir p = if not(Sys.file_exists p) then (mkdir(Filename.dirname p); Unix.mkdir p 0o700)
let write p s =
 mkdir(Filename.dirname p); Out_channel.with_open_bin p (fun o -> output_string o s);
 if Filename.check_suffix p ".tesl" then ignore(Compile.agent_context_result_source p s)
let read p = In_channel.with_open_bin p In_channel.input_all
let rec remove p = if (Unix.lstat p).Unix.st_kind=Unix.S_DIR then
  (Array.iter(fun n -> remove(Filename.concat p n))(Sys.readdir p); Unix.rmdir p) else Sys.remove p
let old = {|module Schema.Mail.V1 exposing [Delivery, Other, Jobs]
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
record Delivery { text: String }
record Other { text: String }
codec Delivery {
 toJson { text -> "oldText" with_codec stringCodec }
 fromJson [ { text <- "oldText" with_codec stringCodec } ]
}
queueSchema Jobs { jobs: [Delivery] }
|}
let fresh = {|module Schema.Mail.VCurrent exposing [Delivery, Jobs]
import Tesl.Prelude exposing [String, Int]
import Tesl.Json exposing [stringCodec, intCodec]
record Delivery { body: String, priority: Int }
codec Delivery {
 toJson { body -> "message" with_codec stringCodec, priority -> "priority" with_codec intCodec }
 fromJson [ { body <- "message" with_codec stringCodec, priority <- "priority" with_codec intCodec } ]
}
queueSchema Jobs { jobs: [Delivery] }
|}
let helper = {|module Schema.Mail.Migrate.Helpers exposing [convert, oldJob]
import Tesl.Prelude exposing [String, Int, Bool(..)]
import Tesl.Migration exposing [Migrated(..)]
import Schema.Mail.V1
import Schema.Mail.VCurrent
fn priority() -> Int = 7
fn convert(old: Schema.Mail.V1.Delivery) -> Migrated Schema.Mail.VCurrent.Delivery =
 if old.text == "" then
  Reject "empty job"
 else
  Row (Schema.Mail.VCurrent.Delivery { body: old.text, priority: priority() })
fn oldJob() -> Schema.Mail.V1.Delivery = Schema.Mail.V1.Delivery { text: "retained" }
test "convert the frozen job without losing its value" {
 case convert (oldJob()) of
  Row job ->
   expect job.body == "retained"
   expect job.priority == 7
  Reject reason -> expect False
}
test "rejected job keeps its original value" {
 let original = Schema.Mail.V1.Delivery { text: "" }
 case convert original of
  Row job -> expect False
  Reject reason -> expect reason == "empty job"
 expect original.text == ""
}
|}
let parse p s = match Parser.parse_module p s with Ok m -> m | Err e -> fail e.msg
let get = function Ok t -> t | Error es -> fail(String.concat "\n" (List.map(fun(e:Migration_sparse.error)->e.code ^ ": " ^ e.message)es))
let load file =
 let abi=Result.get_ok(Migration_abi.current()) in
 match I.load_with_compatibility ~stored_value_compatibility:(Some(Migration_abi.stored_value_compatibility abi))
   ~compiler_abi:(Migration_abi.id abi) ~root_file:file with Ok t->t|Error e->fail e.message
let ref_ file name = Ast.EVar {name;loc=Location.dummy_loc file}
let without_tests source =
  let stop=Str.search_forward (Str.regexp_string "test \"") source 0 in
  String.sub source 0 stop
let project ?(before=old) ?(after=fresh) ?(body=helper) run =
 let root=Filename.temp_dir "tesl-queue-transform-" "" in
 Fun.protect ~finally:(fun()->remove root)(fun()->
   let save relative bytes=let p=Filename.concat root relative in write p bytes; p in
   ignore(save "tesl.toml" "");
   let previous=save "schema/mail/v1.tesl" before and current=save "schema/mail/v-current.tesl" after in
   let file=save "migrations/mail/helpers.tesl" body in
   let check ?(version=2) ?(queue="Jobs") ?(job="Delivery") ?(callback="convert") ?(fixtures=["oldJob"]) () =
     let source=Source_input.read file in
     Q.check ~project_root:root ~before:(load previous) ~after:(load current) ~version ~queue ~job ~source (parse file source)
       ~callback:(ref_ file callback) ~fixtures:(List.map(ref_ file)fixtures) in
   run root save file check)
let refuses ?code result = match result with
 | Ok _ -> fail "unsafe queue conversion evidence accepted"
 | Error es -> Option.iter(fun code -> check bool (String.concat "\n" (List.map(fun(e:Migration_sparse.error)->e.message)es)) true
     (List.exists(fun(e:Migration_sparse.error)->e.code=code)es))code
let valid () = project(fun _ _ _ make ->
 let checked=get(make()) in
 check string "exact callback owner" "Schema.Mail.Migrate.Helpers.convert" (Q.callback checked).identity;
 check int "exact old fixture" 1 (List.length(Q.fixtures checked));
 check string "deterministic certificate" (Q.digest checked) (Q.digest(get(make())));
 let calls=ref 0 in ignore(get(Q.with_checked checked (fun()->incr calls)));
 check int "callback publication scope runs once" 1 !calls)
let identities () = project(fun _ _ _ make ->
 refuses ~code:"MIG028" (make ~version:3 ());
 refuses ~code:"MIG028" (make ~queue:"Missing" ());
 refuses ~code:"MIG028" (make ~job:"Other" ());
 refuses ~code:"MIG021" (make ~callback:"missing" ()))
let fixtures () = project(fun _ _ _ make ->
 refuses ~code:"MIG003" (make ~fixtures:[] ());
 refuses ~code:"MIG023" (make ~fixtures:["oldJob";"oldJob"] ());
 refuses ~code:"MIG021" (make ~fixtures:["convert"] ()))
let wrong_parameter () = project ~body:(replace "fn convert(old: Schema.Mail.V1.Delivery)" "fn convert(old: Schema.Mail.V1.Other)" (without_tests helper))
 (fun _ _ _ make -> refuses ~code:"MIG021" (make()))
let wrong_result () =
 let body=without_tests helper
   |> replace "Migrated Schema.Mail.VCurrent.Delivery" "Migrated Schema.Mail.V1.Other"
   |> replace "Schema.Mail.VCurrent.Delivery { body: old.text, priority: priority() }" "Schema.Mail.V1.Other { text: old.text }" in
 project ~body (fun _ _ _ make -> refuses ~code:"MIG021" (make()))
let optional_source value = without_tests helper
   |> replace "import Tesl.Migration" "import Tesl.Maybe exposing [Maybe(..)]\nimport Tesl.Migration"
   |> replace "fn oldJob() -> Schema.Mail.V1.Delivery = Schema.Mail.V1.Delivery { text: \"retained\" }"
      ("fn oldJob() -> Maybe Schema.Mail.V1.Delivery = " ^ value)
let optional_fixture () =
 let body=optional_source "Something (Schema.Mail.V1.Delivery { text: \"retained\" })" in
 project ~body (fun _ _ _ make -> ignore(get(make())))
let fake_optional_fixture () =
 let body=without_tests helper
   |> replace "fn priority()" "type Maybe a = Present value: a\nfn priority()"
   |> replace "fn oldJob() -> Schema.Mail.V1.Delivery = Schema.Mail.V1.Delivery { text: \"retained\" }"
      "fn oldJob() -> Maybe Schema.Mail.V1.Delivery = Present (Schema.Mail.V1.Delivery { text: \"retained\" })" in
 project ~body (fun _ _ _ make -> refuses ~code:"MIG021" (make()))
let fake_result () =
 let body=without_tests helper
   |> replace "import Tesl.Migration exposing [Migrated(..)]" ""
   |> replace "fn priority()" "type Migrated a =\n | Accepted value: a\n | Denied reason: String\nfn priority()"
   |> replace "Reject \"empty job\"" "Denied \"empty job\""
   |> replace "  Row (" "  Accepted (" in
 project ~body (fun _ _ _ make -> refuses ~code:"MIG021" (make()))
let effectful () =
 let body=without_tests helper |> replace "fn priority() -> Int = 7" "fn priority() -> Int = fail 400 \"trap\"" in
 project ~body (fun _ _ _ make -> refuses (make()))
let private_callback () = project(fun _ save file make ->
 let hidden=without_tests helper
   |> replace "Migrate.Helpers exposing [convert, oldJob]" "Migrate.Hidden exposing []"
   |> replace "fn convert(" "fn hidden(" in
 ignore(save "migrations/mail/hidden.tesl" hidden);
 write file (replace "import Schema.Mail.V1" "import Schema.Mail.Migrate.Hidden\nimport Schema.Mail.V1" helper);
 refuses ~code:"MIG021" (make ~callback:"Schema.Mail.Migrate.Hidden.hidden" ()))
let helper_body () = project ~body:(replace "fn priority() -> Int = 7" "fn priority() -> Int = \"wrong\"" helper)
 (fun _ _ _ make -> refuses ~code:"MIG028" (make()))
let unused_body () = project ~body:(helper ^ "\nfn unused() -> Int = \"wrong\"\n")
 (fun _ _ _ make -> refuses ~code:"MIG028" (make()))
let wrong_family () = project ~body:(replace "Schema.Mail.Migrate.Helpers" "Schema.Other.Migrate.Helpers" helper)
 (fun _ _ _ make -> refuses ~code:"MIG028" (make()))
let invalid_test () = project ~body:(helper ^ "\ntest \"ill-typed test binding\" {\n let invalid: Int = \"wrong\"\n expect invalid == 42\n}\n")
 (fun _ _ _ make -> refuses ~code:"MIG028" (make()))
let unchanged () = project ~after:(replace "Schema.Mail.V1" "Schema.Mail.VCurrent" old)
 ~body:(replace "Schema.Mail.VCurrent.Delivery { body: old.text, priority: priority() }"
   "Schema.Mail.VCurrent.Delivery { text: old.text }" (without_tests helper))
 (fun _ _ _ make -> refuses ~code:"MIG028" (make()))
let proven_schema = fresh
 |> replace "[Delivery, Jobs]" "[Delivery, Jobs, Trusted, tryBody]"
 |> replace "record Delivery" {|import Tesl.Maybe exposing [Maybe(..)]
fact Trusted(value: String)
establish tryBody(value: String) -> Maybe (v: String ::: Trusted v) =
 if value != "blocked" then
  Something (value ::: Trusted value)
 else
  Nothing
check checkBody(value: String) -> value: String ::: Trusted value =
 if value != "blocked" then
  ok value ::: Trusted value
 else
  fail 400 "blocked"
record Delivery|}
 |> replace "body: String," "body: String ::: Trusted body,"
 |> replace {|body <- "message" with_codec stringCodec|} {|body <- "message" with_codec stringCodec via checkBody|}
let proven_helper = helper
 |> replace "import Tesl.Migration" "import Tesl.Maybe exposing [Maybe(..)]\nimport Tesl.Migration"
 |> replace "  Row (Schema.Mail.VCurrent.Delivery { body: old.text, priority: priority() })"
   {|  case Schema.Mail.VCurrent.tryBody old.text of
   Nothing -> Reject "blocked title"
   Something body -> Row (Schema.Mail.VCurrent.Delivery { body: body, priority: priority() })|}
 |> fun body -> body ^ {|
test "new proof can reject an old-valid job" {
 let original = Schema.Mail.V1.Delivery { text: "blocked" }
 case convert original of
  Row job -> expect False
  Reject reason -> expect reason == "blocked title"
 expect original.text == "blocked"
}
|}
let proof_required () = project ~after:proven_schema (fun _ _ _ make -> refuses ~code:"MIG028" (make()))
let codec_direction () =
 List.iter(fun(before,after) -> project ~before ~after (fun _ _ _ make -> refuses ~code:"MIG028" (make())))
  [replace {|fromJson [ { text <- "oldText" with_codec stringCodec } ]|} "fromJson_forbidden" old,fresh;
   replace {|fromJson [ { text <- "oldText" with_codec stringCodec } ]|} "fromJson []" old,fresh;
   old,replace {|toJson { body -> "message" with_codec stringCodec, priority -> "priority" with_codec intCodec }|} "toJson_forbidden" fresh]
let semantic_dependencies () = project(fun _ save file make ->
 let initial=get(make()) in
 write file (replace "fn priority() -> Int = 7" "fn priority() -> Int = 8" helper);
 check bool "helper body changes certificate" false (Q.digest initial=Q.digest(get(make())));
 write file helper;
 ignore(save "schema/mail/v-current.tesl" (replace {|body -> "message"|} {|body -> "changed"|} fresh));
 check bool "target encoder changes certificate" false (Q.digest initial=Q.digest(get(make())));
 ignore(save "schema/mail/v-current.tesl" fresh);
 ignore(save "schema/mail/v1.tesl" (replace {|text <- "oldText"|} {|text <- "legacy"|} old));
 check bool "frozen decoder changes certificate" false (Q.digest initial=Q.digest(get(make()))))
let unrelated_helpers () = project(fun _ _ file make ->
 let t=get(make()) in
 write file(helper ^ "\n# Layout and unreachable pure helpers are not callback semantics.\nfn unrelated() -> Int = 42\n");
 check string "unreachable helpers do not change conversion meaning" (Q.digest t) (Q.digest(get(make())));
 refuses ~code:"MIG013" (Q.with_checked t Fun.id))
let source_guards () = project(fun _ _ file make ->
 let t=get(make()) in
 write file (helper ^ "\n# concurrent source edit\n");
 let ran=ref false in refuses ~code:"MIG013" (Q.with_checked t (fun()->ran:=true));
 check bool "stale callback did not run" false !ran;
 write file helper;
 let calls=ref 0 in
 refuses ~code:"MIG013" (Q.with_checked t (fun()->incr calls;write file(helper ^ "\n# publication edit\n")));
 check int "publication failure never replays callback" 1 !calls)
let artifact_guard () = project(fun _ _ file make ->
 let checked=get(make()) in
 write file (replace "fn priority() -> Int = 7" "fn priority() -> Int = 8" helper);
 match Compile.compile_queue_conversion_artifacts checked with
 | Compile.GoSuccess _ -> fail "stale queue conversion emitted runtime bindings"
 | Compile.GoFailure ds -> check bool (Compile.diagnostics_to_json ds) true
     (List.exists(fun(d:Compile.diagnostic)->d.code="MIG013")ds))
let dependency_guard () = project(fun _ save _ make ->
 let t=get(make()) in
 ignore(save "schema/mail/v1.tesl" (old ^ "\n# concurrent old decoder edit\n"));
 refuses ~code:"MIG013" (Q.with_checked t Fun.id))
let directory_guard () = project(fun _ save _ make ->
 let t=get(make()) in
 ignore(save "migrations/mail/another-helper.tesl" "module Schema.Mail.Migrate.AnotherHelper exposing []\n");
 refuses ~code:"MIG013" (Q.with_checked t Fun.id))
let unsaved_guard () = project(fun root _ file make ->
 let changed=replace "fn priority() -> Int = 7" "fn priority() -> Int = 8" helper in
 let t=Source_input.with_overlays ~project_root:root [file,changed] (fun()->
   let t=get(make()) in ignore(get(Q.with_checked t Fun.id));t) in
 check string "unsaved checking never writes the source file" helper (read file);
 refuses ~code:"MIG013" (Q.with_checked t Fun.id))
let frozen_target () = project(fun root save file make ->
 let initial=get(make()) in
 let target=save "schema/mail/v2.tesl" (replace "Schema.Mail.VCurrent" "Schema.Mail.V2" fresh) in
 let bytes=replace "Schema.Mail.VCurrent" "Schema.Mail.V2" helper in
 write file bytes;
 let before=load(save "schema/mail/v1.tesl" old) and after=load target in
 let t=get(Q.check ~project_root:root ~before ~after ~version:2 ~queue:"Jobs" ~job:"Delivery" ~source:bytes (parse file bytes)
   ~callback:(ref_ file "convert") ~fixtures:[ref_ file "oldJob"]) in
 check string "freezing target preserves semantic evidence" (Q.digest initial) (Q.digest t))
let non_executable () = project(fun root save _ make ->
 let before=load(Filename.concat root "schema/mail/v1.tesl") and after=load(Filename.concat root "schema/mail/v-current.tesl") in
 let seal i=match Migration_seal.create ~project_root:root i with Ok s->s|Error e->fail e.message in
 let header=get(Migration_header.create ~previous:(seal before) ~current:(seal after)) in
 let body=Migration_header.encode header ^ {|module Schema.Mail.Migrate.V2 exposing [migration]
import Tesl.Migration exposing [Migration]
import Schema.Mail.V1
import Schema.Mail.VCurrent
migration = Migration { from: Schema.Mail.V1, to: Schema.Mail.VCurrent, same: [], entities: {} }
|} in
 let path=save "migrations/mail/v2.tesl" body in
 let evidence=get(make()) in
 let diagnostics=get(Q.with_checked evidence (fun () -> (Compile.agent_context_result_source path body).diagnostics)) in
 check bool "source certificate does not enable unimplemented queue execution" true
   (List.exists(fun(d:Compile.diagnostic)->d.code="MIG028" && d.severity="error")diagnostics))
let job_declaration = {|module Schema.Mail.Migrate.V2 exposing [migration]
import Tesl.Migration exposing [Migration, Entity(..)]
import Schema.Mail.V1
import Schema.Mail.VCurrent
import Schema.Mail.Migrate.Helpers
migration = Migration {
 from: Schema.Mail.V1
 to: Schema.Mail.VCurrent
 same: []
 entities: {}
 fixtures: [Schema.Mail.Migrate.Helpers.oldJob]
 jobs: { Delivery: Migrate Schema.Mail.Migrate.Helpers.convert }
}
|}
let with_job_declaration ?(before=old) ?(after=fresh) ?(helper_source=helper) ?(declaration=job_declaration) run =
 project ~before ~after ~body:helper_source (fun root save _ _ ->
 let previous=load(Filename.concat root "schema/mail/v1.tesl") and current=load(Filename.concat root "schema/mail/v-current.tesl") in
 let seal inventory=match Migration_seal.create ~project_root:root inventory with Ok s->s|Error e->fail e.message in
 let header=Migration_header.encode(get(Migration_header.create ~previous:(seal previous) ~current:(seal current))) in
 let file=save "migrations/mail/v2.tesl" (header ^ declaration) in
 run root save file header)
let checked_jobs () = with_job_declaration(fun _ save file _ ->
 let source=read file in
 let context=Compile.agent_context_result_source file source in
 check bool context.json true context.ok;
 let formatted=Formatter.format_source source in
 check string "jobs formatting is stable" formatted (Formatter.format_source formatted);
 let formatted_context=Compile.agent_context_result_source file formatted in
 check bool formatted_context.json true formatted_context.ok;
 let declaration=Option.get(get(Migration_declaration.check ~compiler_abi:"compiler-local-unsealed-comparison" ~source (parse file source))) in
 check int "checked explicit payload decision" 1 (List.length(Migration_declaration.queue_transforms declaration));
 check bool "no invented row transform" true (Migration_declaration.transforms declaration=None);
 let before,after=Migration_sparse.inventories(Migration_declaration.coverage declaration) in
 List.iter(fun initial ->
   refuses ~code:"MIG028" (Migration_expansion.generate ~initial_version:initial ~schemas:[before;after] ~edges:[declaration])) [1;2];
 refuses ~code:"MIG028" (Migration_row_history.check ~schemas:[before;after] ~edges:[declaration]);
 (match Compile.compile_go_file file with
  | Compile.GoSuccess _ -> fail "checked jobs leaked executable history"
  | Compile.GoFailure ds -> check bool (Compile.diagnostics_to_json ds) true (List.exists(fun(d:Compile.diagnostic)->d.code="MIG028")ds));
 let app={|module App exposing []
import Tesl.Prelude exposing [String]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import Tesl.Queue exposing [Queue, FromQueue, queueRead]
import Tesl.App exposing [App]
import Schema.Mail.VCurrent exposing [Delivery]
database D = Database { schema: Schema.Mail.VCurrent, migrations: Schema.Mail.Migrate,
 backend: Postgres (PostgresConfig { namespace: "mail", dbName: "unused", user: "unused", password: "unused",
 connection: TcpConnection { host: "127.0.0.1", port: 5432 } }) }
queue Tasks requires [queueRead] = Queue { database: D, schema: Schema.Mail.VCurrent.Jobs,
 jobs: [Job Schema.Mail.VCurrent.Delivery handle Nothing] }
worker handle(job: Delivery ::: FromQueue (Id == jobId) job) = job
handler get health() -> String = "ready"
api Api { get "/" -> String }
server Web for Api { health }
main() -> App requires [queueRead] = App { database: D, queues: [Tasks], api: Web, port: 8080 }
|} in
 let appfile=save "app.tesl" app in
 (match Compile.compile_go_file appfile with
  | Compile.GoSuccess _ -> fail "application deployed checked jobs before protected execution"
  | Compile.GoFailure ds -> check bool (Compile.diagnostics_to_json ds) true
     (List.exists(fun(d:Compile.diagnostic)->d.code="MIG028" && Compile.string_contains d.message "protected transformation")ds)))
let jobs_negative () = with_job_declaration(fun _ save file header ->
 List.iter(fun(label,change,code)->
   let source=header ^ change job_declaration in
   ignore(save "migrations/mail/v2.tesl" source);
   let ds=(Compile.agent_context_result_source file source).diagnostics in
   check bool (label ^ ": " ^ Compile.diagnostics_to_json ds) true
     (List.exists(fun(d:Compile.diagnostic)->d.code=code && d.severity="error")ds)) [
   "missing coverage",replace "jobs: { Delivery: Migrate Schema.Mail.Migrate.Helpers.convert }" "jobs: {}","MIG028";
   "missing fixture",replace "fixtures: [Schema.Mail.Migrate.Helpers.oldJob]" "fixtures: []","MIG003";
   "duplicate alias",replace "jobs: { Delivery:" "jobs: { Schema.Mail.V1.Delivery: Migrate Schema.Mail.Migrate.Helpers.convert, Delivery:","MIG023";
   "unknown payload",replace "jobs: { Delivery:" "jobs: { Missing:","MIG028";
   "unimplemented decision",replace "Migrate Schema.Mail.Migrate.Helpers.convert" "Drop","MIG028";
   "wrong callback",replace "Migrate Schema.Mail.Migrate.Helpers.convert" "Migrate Schema.Mail.Migrate.Helpers.oldJob","MIG021";
   "typed hole",replace "Migrate Schema.Mail.Migrate.Helpers.convert" "todo \"choose conversion\"","MIG003"])
let jobs_guard () = with_job_declaration(fun _ save file _ ->
 let source=read file in
 let prepared=Option.get(get(Migration_declaration.prepare ~compiler_abi:"compiler-local-unsealed-comparison" ~source (parse file source))) in
 ignore(save "migrations/mail/helpers.tesl" (replace "fn priority() -> Int = 7" "fn priority() -> Int = 8" helper));
 refuses ~code:"MIG013" (Migration_declaration.check_prepared prepared))
let mixed_job_row_fixtures () =
 let before=(old |> replace "[Delivery, Other, Jobs]" "[Delivery, Other, Jobs, Note]") ^
   "entity Note table \"notes\" primaryKey id { id: String, title: String }\n" in
 let after=(fresh |> replace "[Delivery, Jobs]" "[Delivery, Jobs, Note]") ^
   "entity Note table \"notes\" primaryKey id { id: String, title: String, count: Int }\n" in
 let helper_source=(helper |> replace "[convert, oldJob]" "[convert, oldJob, convertNote, oldNote]") ^ {|
fn convertNote(old: Schema.Mail.V1.Note) -> Migrated Schema.Mail.VCurrent.Note =
 Row (Schema.Mail.VCurrent.Note { id: old.id, title: old.title, count: 1 })
fn oldNote() -> Schema.Mail.V1.Note = Schema.Mail.V1.Note { id: "one", title: "retained" }
|} in
 let declaration=job_declaration
   |> replace "entities: {}" "entities: { Note: Migrate Schema.Mail.Migrate.Helpers.convertNote [] }"
   |> replace "fixtures: [Schema.Mail.Migrate.Helpers.oldJob]" "fixtures: [Schema.Mail.Migrate.Helpers.oldJob, Schema.Mail.Migrate.Helpers.oldNote]" in
 with_job_declaration ~before ~after ~helper_source ~declaration (fun _ _ file _ ->
  let source=read file in
  let context=Compile.agent_context_result_source file source in check bool context.json true context.ok;
  let d=Option.get(get(Migration_declaration.check ~compiler_abi:"compiler-local-unsealed-comparison" ~source (parse file source))) in
  let queues=Migration_declaration.queue_transforms d and rows=Migration_transform.rows(Option.get(Migration_declaration.transforms d)) in
  check int "one queue fixture" 1 (List.length(Q.fixtures(List.hd queues)));
  check int "one entity fixture" 1 (List.length(List.hd rows).fixtures))
let wire_tests = {|package teslmodschemamailmigratehelpers
import (
 "encoding/json"
 "testing"
 old "tesl.generated/teslmodschemamailmigratehelpers/internal/teslmodschemamailv1"
 current "tesl.generated/teslmodschemamailmigratehelpers/internal/teslmodschemamailvcurrent"
 rt "tesl.generated/teslmodschemamailmigratehelpers/internal/teslrt"
)
func TestQueueConversionFrozenAndTargetCodecs(t *testing.T) {
 for _, text := range []string{"retained", "雪", ""} {
  original, err := json.Marshal(map[string]string{"oldText":text})
  if err!=nil {t.Fatal(err)}
  preserved:=string(original)
  raw,err:=rt.ParseJSON(original);if err!=nil {t.Fatal(err)}
  previous,ok:=old.DecodeDeliveryJSON(raw).Value();if !ok {t.Fatal("frozen decoder refused",string(original))}
  converted:=Convert(previous)
  if text=="" {
   if converted.Tag!=rt.MigratedReject||converted.RejectReason!="empty job" {t.Fatal("wrong rejection",converted)}
  } else {
   if converted.Tag!=rt.MigratedRow||converted.RowValue.Body!=text||converted.RowValue.Priority.String()!="7" {t.Fatal("lost logical conversion",converted)}
   encoded,err:=json.Marshal(current.EncodeDeliveryJSON(converted.RowValue));if err!=nil {t.Fatal(err)}
   var object map[string]any
   if err:=json.Unmarshal(encoded,&object);err!=nil {t.Fatal(err)}
   if len(object)!=2||object["message"]!=text||object["priority"]!=float64(7) {t.Fatal("wrong target codec",object)}
   targetRaw,err:=rt.ParseJSON(encoded);if err!=nil {t.Fatal(err)}
   next,ok:=current.DecodeDeliveryJSON(targetRaw).Value()
   if !ok||next.Body!=text||next.Priority.String()!="7" {t.Fatal("target codec cannot read converted bytes",next)}
   if old.DecodeDeliveryJSON(targetRaw).OK() {t.Fatal("fixture accidentally hides incompatible wire shapes")}
  }
  if string(original)!=preserved||previous.Text!=text {t.Fatal("conversion changed retained input")}
 }
 for _, encoded:=range []string{`{}`,`{"oldText":7}`,`{"message":"current","priority":7}`} {
  raw,err:=rt.ParseJSON([]byte(encoded));if err!=nil {t.Fatal(err)}
  if old.DecodeDeliveryJSON(raw).OK() {t.Fatal("malformed old payload was treated as typed data",encoded)}
 }
}
|}
let adapter_tests digest = Printf.sprintf {|package teslqueueconversions
import (
 "encoding/json"
 "strings"
 "testing"
 old "tesl.generated/teslmodschemamailmigratehelpers/internal/teslmodschemamailv1"
 current "tesl.generated/teslmodschemamailmigratehelpers/internal/teslmodschemamailvcurrent"
 rt "tesl.generated/teslmodschemamailmigratehelpers/internal/teslrt"
)
func TestCompiledQueueAdapter(t *testing.T) {
 input:=[]byte(`{"oldText":"retained"}`)
 converted,err:=Conversion0.Convert(1,input)
 if err!=nil||converted.Kind()!="converted"||converted.Original()!=string(input) {t.Fatal("bound conversion",converted,err)}
 if converted.SourceDigest()!=%s||converted.SourceVersion()!=1||converted.TargetVersion()!=2 {t.Fatal("outcome lost source binding")}
 var value map[string]any
 if err=json.Unmarshal([]byte(converted.Payload()),&value);err!=nil||len(value)!=2||value["message"]!="retained"||value["priority"]!=float64(7) {t.Fatal("bound target encoder",value,err)}
 input[0]='!'
 if converted.Original()!=`{"oldText":"retained"}` {t.Fatal("result aliases mutable input")}
 rejected,err:=Conversion0.Convert(1,[]byte(`{"oldText":""}`))
 if err!=nil||rejected.Kind()!="migration-rejected"||rejected.Reason()!="empty job"||rejected.Payload()!=""||rejected.Original()!=`{"oldText":""}` {t.Fatal("rejection fabricated encoded output",rejected,err)}
 for _,body:=range []string{"", "{", `{}`, `{"oldText":7}`, `{"message":"current","priority":7}`} {
  result,err:=Conversion0.Convert(1,[]byte(body))
  if err!=nil||result.Kind()!="payload-invalid"||result.Original()!=body||result.Payload()!="" {t.Fatal("invalid frozen input",result,err)}
 }
 for _,version:=range []int{-1,0,2,3} {
  if _,err:=Conversion0.Convert(version,[]byte(`{"oldText":"retained"}`));err==nil {t.Fatal("foreign source version accepted",version)}
 }
 var empty rt.CompiledQueueConversion[old.Delivery,current.Delivery]
 if _,err:=empty.Convert(1,nil);err==nil {t.Fatal("zero adapter accepted")}
 if _,err:=rt.BindCompiledQueueConversion(strings.Repeat("0",64),decodeOld0,convert0,encodeNew0,decodeNew0);err==nil {t.Fatal("unregistered source accepted")}
 if _,err:=rt.BindCompiledQueueConversion(%s,decodeOld0,convert0,encodeNew0,decodeNew0);err!=nil {t.Fatal("exact generated rebind",err)}
 if _,err:=rt.BindCompiledQueueConversion(%s,decodeOld0,convert0,func(v current.Delivery) any{return nil},decodeNew0);err==nil {t.Fatal("same-typed foreign encoder bound")}
 if _,err:=rt.BindCompiledQueueConversion(%s,decodeOld0,(func(old.Delivery) rt.Migrated[current.Delivery])(nil),encodeNew0,decodeNew0);err==nil {t.Fatal("nil callback bound")}
 type OtherOld old.Delivery
 if _,err:=rt.BindCompiledQueueConversion(%s,func(any)rt.Check[OtherOld]{return rt.Accept(OtherOld{})},func(OtherOld)rt.Migrated[current.Delivery]{return rt.Migrated[current.Delivery]{}},encodeNew0,decodeNew0);err==nil||!strings.Contains(err.Error(),"nominal types") {t.Fatal("same-shaped nominal impostor bound",err)}
}
|} (Emit_go.go_quote digest) (Emit_go.go_quote digest) (Emit_go.go_quote digest) (Emit_go.go_quote digest) (Emit_go.go_quote digest)
let metadata_tests = {|package teslrt
import (
 "encoding/hex"
 "strings"
 "testing"
)
func TestQueueConversionMetadataRefusesSubstitution(t *testing.T) {
 if len(compiledQueueConversionSources.byDigest)!=1 {t.Fatal("missing actual compiler registration")}
 var original pgQueueConversionSourceSpec
 for _,value:=range compiledQueueConversionSources.byDigest {original=value.spec}
 mutate:=func(name string,change func(*pgRowCanonical)) {
  t.Run(name,func(t *testing.T){
   spec:=original
   document,_,err:=pgReadRowCanonical(spec.document);if err!=nil {t.Fatal(err)}
   change(&document.children[3])
   raw,hash:=pgRowBaselineDocument(document.children[3])
   spec.document,spec.digest=hex.EncodeToString([]byte(raw)),hash
   if _,err:=pgReadQueueConversionSource(spec);err==nil {t.Fatal("freshly hashed substitution accepted")}
  })
 }
 mutate("wrong-payload-owner",func(n *pgRowCanonical){n.children[6]=pgRowAtom("Other")})
 mutate("reversed-codecs",func(n *pgRowCanonical){n.children[9],n.children[10]=n.children[10],n.children[9]})
 mutate("missing-fixtures",func(n *pgRowCanonical){n.children[12]=pgRowList()})
 mutate("duplicate-fixture",func(n *pgRowCanonical){n.children[12].children=append(n.children[12].children,n.children[12].children[0])})
 mutate("missing-callback-closure",func(n *pgRowCanonical){n.children[11]=pgRowList()})
 mutate("malformed-codec-closure",func(n *pgRowCanonical){n.children[9]=pgRowAtom("not a closure")})
 mutate("missing-payload-closure",func(n *pgRowCanonical){n.children[7]=pgRowList()})
 mutate("missing-codec-dependency",func(n *pgRowCanonical){
  defs:=&n.children[9].children[2]
  for i,d:=range defs.children {if d.children[1].children[0].isAtom("record-declaration") {defs.children=append(defs.children[:i],defs.children[i+1:]...);return}}
  t.Fatal("fixture had no codec type dependency")
 })
 mutate("callback-signature",func(n *pgRowCanonical){
  roots:=n.children[11].children[1]
  for i:=range n.children[11].children[2].children {
   d:=&n.children[11].children[2].children[i]
   if pgRowCanonicalEqual(d.children[0],roots.children[0]) {d.children[1].children[4]=pgRowList(pgRowAtom("plain"),pgRowAtom("forged"))}
  }
 })
 mutate("missing-source-dependency",func(n *pgRowCanonical){
  defs:=&n.children[11].children[2]
  for i,d:=range defs.children {if d.children[1].children[0].isAtom("codec") {defs.children=append(defs.children[:i],defs.children[i+1:]...);return}}
  t.Fatal("fixture had no codec dependency")
 })
 mutate("missing-fixture-source-dependency",func(n *pgRowCanonical){
  defs:=&n.children[12].children[0].children[2]
  for i,d:=range defs.children {if d.children[1].children[0].isAtom("record-declaration") {defs.children=append(defs.children[:i],defs.children[i+1:]...);return}}
  t.Fatal("fixture had no old payload definition")
 })
 before:=len(compiledQueueConversionSources.byDigest)
 candidate:=original
 document,_,err:=pgReadRowCanonical(candidate.document);if err!=nil {t.Fatal(err)}
 document.children[3].children[4]=pgRowAtom("3")
 raw,hash:=pgRowBaselineDocument(document.children[3])
 candidate.document,candidate.digest=hex.EncodeToString([]byte(raw)),hash
 if _,err:=pgReadQueueConversionSource(candidate);err!=nil {t.Fatal("atomicity fixture needs another structurally valid source",err)}
 func(){defer func(){if recover()==nil {t.Fatal("invalid registration batch accepted")}}()
  bad:=original;bad.digest=strings.Repeat("0",64)
  registerCompiledQueueConversionSources([]pgQueueConversionSourceSpec{candidate,bad})
 }()
 if len(compiledQueueConversionSources.byDigest)!=before||compiledQueueConversionSources.byDigest[original.digest].spec!=original {t.Fatal("failed registration changed registry")}
 if compiledQueueConversionSources.byDigest[candidate.digest]!=nil {t.Fatal("failed registration published its valid prefix")}
}
|}
let native ?(after=fresh) ?(body=helper) ?(extra_tests=[]) ?(pure_tests=true) ?(setup=(fun _->())) ?expected_failure () = project ~after ~body (fun root save _ make ->
 setup save;
 let checked=get(make()) in
 let artifacts=match Compile.compile_queue_conversion_artifacts checked with
   | Compile.GoSuccess a->a|Compile.GoFailure ds->fail(Compile.diagnostics_to_json ds) in
 List.iter(fun(a:Emit_go.artifact)->ignore(save ("out/" ^ a.path)a.contents))artifacts;
 ignore(save "out/internal/teslmodschemamailmigratehelpers/queue_codec_test.go" wire_tests);
 ignore(save "out/internal/teslqueueconversions/conversions_test.go" (adapter_tests(Q.digest checked)));
 ignore(save "out/internal/teslrt/queue_conversion_metadata_test.go" metadata_tests);
 List.iter(fun name->remove(Filename.concat root name))["schema";"migrations";"tesl.toml"];
 let command=Printf.sprintf "cd %s && go test -race -p 1 -count=1 -timeout=60s -v ./... 2>&1" (Filename.quote(Filename.concat root "out")) in
 let channel=Unix.open_process_in command in
 let output=In_channel.input_all channel in
 let status=Unix.close_process_in channel in
 match expected_failure with
 | Some message ->
   check bool "invalid fixture fails the actual generated tests" false (status=Unix.WEXITED 0);
   check bool output true (Compile.string_contains output message)
 | None ->
   (match status with Unix.WEXITED 0 -> () | _ -> fail output);
   List.iter(fun name -> check bool ("actual typed callback test: " ^ name) true
     (Compile.string_contains output ("--- PASS: " ^ name)))
     ((if pure_tests then ["TestTesl0";"TestTesl1"] else []) @
      ["TestTeslQueueConversionFixture0_0";"TestQueueConversionFrozenAndTargetCodecs";"TestCompiledQueueAdapter";"TestQueueConversionMetadataRefusesSubstitution"] @ extra_tests))
let native_cycle () =
 let body=helper |> replace "exposing [convert, oldJob]" "exposing [convert, oldJob, basePriority]"
  |> replace "fn priority() -> Int = 7" "fn basePriority() -> Int = 7\nfn priority() -> Int = Schema.Mail.Migrate.Priority.priority()"
  |> replace "import Schema.Mail.V1" "import Schema.Mail.Migrate.Priority\nimport Schema.Mail.V1" in
 let setup save=ignore(save "migrations/mail/priority.tesl" {|module Schema.Mail.Migrate.Priority exposing [priority]
import Tesl.Prelude exposing [Int]
import Schema.Mail.Migrate.Helpers exposing [basePriority]
fn priority() -> Int = basePriority()
|}) in
 native ~body ~setup ()
let () = run "sealed queue conversion source" ["source",List.map(fun(name,f)->test_case name `Quick f)
 ["checked callback fixture and stable identity",valid;
  "exact adjacent queue and payload identities",identities;
  "fixtures required unique and exact",fixtures;
  "wrong previous nominal parameter",wrong_parameter;
  "wrong nominal migration result",wrong_result;
  "exact builtin Maybe fixture",optional_fixture;
  "user Maybe cannot supply fixture authority",fake_optional_fixture;
  "user Migrated cannot supply conversion authority",fake_result;
  "throwing helper cannot be a pure queue conversion",effectful;
  "private callback cannot be named through captured globals",private_callback;
  "whole helper body is frontend checked",helper_body;
  "unused helper bodies are also checked",unused_body;
  "test bodies are checked before lowering omits them",invalid_test;
  "another migration family cannot own conversion evidence",wrong_family;
  "unchanged payloads cannot invent a conversion",unchanged;
  "new payload proofs cannot be fabricated",proof_required;
  "both codec directions required",codec_direction;
  "callback and codec closure dependencies bind identity",semantic_dependencies;
  "unreachable helpers preserve meaning but not source preconditions",unrelated_helpers;
  "source guard before and after publication",source_guards;
  "frozen decoder source guard",dependency_guard;
  "adjacent source membership is guarded",directory_guard;
  "unsaved source evidence cannot escape its source view",unsaved_guard;
  "freezing target preserves semantic identity",frozen_target;
  "source evidence cannot activate changed jobs",non_executable;
  "generated accept reject tests run without source files",(fun()->native());
  "generated proof-bearing accept and reject preserve old payload",(fun()->native ~after:proven_schema ~body:proven_helper ~extra_tests:["TestTesl2"] ());
  "generated optional fixture unwraps the old payload",(fun()->native ~pure_tests:false ~body:(optional_source "Something (Schema.Mail.V1.Delivery { text: \"retained\" })") ());
  "generated Nothing fixture fails by fixture identity",(fun()->native ~pure_tests:false ~body:(optional_source "Nothing")
    ~expected_failure:"queue conversion fixture Schema.Mail.Migrate.Helpers.oldJob: fixture returned Nothing" ());
  "generated rejecting fixture is a valid smoke outcome",(fun()->native ~pure_tests:false ~body:(replace "text: \"retained\"" "text: \"\"" (without_tests helper)) ());
  "generated adapter binds lowered helper cycles and collisions",native_cycle;
  "artifact publication refuses stale source evidence",artifact_guard;
  "public jobs source checks without inventing execution",checked_jobs;
  "jobs coverage, ownership and fixture diagnostics",jobs_negative;
  "jobs source views cannot mask edited helpers",jobs_guard;
  "queue and entity fixtures retain independent nominal owners",mixed_job_row_fixtures]]
