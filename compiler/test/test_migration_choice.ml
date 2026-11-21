open Alcotest
open Ast
module P = Migration_preview
module M = Migration_manifest
module S = Migration_source_syntax
let rec mkdir p = if not (Sys.file_exists p) then (mkdir (Filename.dirname p); Unix.mkdir p 0o700)
let write p source = mkdir (Filename.dirname p); Out_channel.with_open_bin p (fun out -> output_string out source)
let read p = In_channel.with_open_bin p In_channel.input_all
let rec remove p = if (Unix.lstat p).Unix.st_kind = Unix.S_DIR then
  (Array.iter (fun n -> remove (Filename.concat p n)) (Sys.readdir p); Unix.rmdir p) else Sys.remove p
let rec files p = Sys.readdir p |> Array.to_list |> List.concat_map (fun n ->
  let p = Filename.concat p n in if Sys.is_directory p then files p else [p,read p]) |> List.sort compare
let replace a b s = Str.global_replace (Str.regexp_string a) b s
let get = function Ok p -> p | Error es -> fail (String.concat "\n" (List.map (fun (e:P.error) -> e.message) es))
let syntax = function Ok p -> p | Error (e:S.error) -> fail e.message
let refused = function Error (_::_) -> () | _ -> fail "invalid choice accepted"
let app = {|module App exposing []
import Tesl.Database exposing [Database, Memory]
import NotesSchema.VCurrent
database Main = Database { schema: NotesSchema.VCurrent, migrations: NotesSchema.Migrate, backend: Memory }
|}
let simple = {|module NotesSchema.VCurrent exposing [Note]
import Tesl.Prelude exposing [String, Int]
entity Note table "notes" primaryKey id { id: String, amount: Int }
|}
let proof_source = {|module NotesSchema.VCurrent exposing [Note, Good, accept]
import Tesl.Prelude exposing [String, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
fact Good(value: String)
establish accept(value: String) -> Maybe (accepted: String ::: Good accepted) =
  if value != "" then
    Something (value ::: Good value)
  else
    Nothing
entity Note table "notes" primaryKey id { id: String, title: StringPROOF }
|}
let preview ?(documents=[]) root = P.generate ~project_root:root ~entry_file:(Filename.concat root "app.tesl")
  ~database:None ~new_revision:false ~documents
let materialize p =
  get (P.verify p ~documents:[]);
  List.iter (fun (e:M.edit) -> write e.path e.after) (M.edits (P.manifest p))
let with_project ?(old=simple) ?(program=app) f =
  let root = Filename.temp_file "tesl-migration-choice-" ".dir" in Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let path = Filename.concat root in
    write (path "tesl.toml") ""; write (path "schema/notes/v-current.tesl") old; write (path "app.tesl") program;
    materialize (get (preview root)); f root path)
let decisions p = Yojson.Basic.Util.(P.to_json p |> Yojson.Basic.from_string |> member "decisions" |> to_list)
let options p = let open Yojson.Basic.Util in
  decisions p |> List.concat_map (fun d -> member "options" d |> to_list |> List.map (fun o -> member "id" o |> to_string))
let choose ?(documents=[]) root p option_ =
  let open Yojson.Basic.Util in
  let d = List.find (fun d -> member "options" d |> to_list |> List.exists (fun o -> member "id" o |> to_string = option_)) (decisions p) in
  P.generate_choice ~project_root:root ~entry_file:(Filename.concat root "app.tesl") ~database:None ~documents
    ~decision:(member "id" d |> to_string) ~option_ ~expected_input_digest:(P.input_digest p)
let source p file = match List.find_opt (fun (e:M.edit) -> e.path=file) (M.edits (P.manifest p)) with
  | Some e -> e.after | None -> fail "selected choice did not update its migration file"
let check_app root =
  let file = Filename.concat root "app.tesl" in
  let r = Compile.agent_context_result_source file (read file) in
   if not r.ok then fail r.json
let check_emit file = match Compile.compile_go_source file(read file)with
 | Compile.GoSuccess _->()
 | Compile.GoFailure errors->fail(Compile.diagnostics_to_json errors)
let complete file source render ?fixture_body () =
  let view = syntax (S.read ~file ~source) in
  let edits = ref [] in
  let add expr text = edits := (syntax (S.range view expr),Migration_source.source_fragment ~source text) :: !edits in
  let visit = Ast_visitor.iter (function
    | EApp {fn=EVar {name="todo";_};arg=ELit {lit=LString reason;_};_} as expr -> add expr (render reason)
    | _ -> ()) in
  List.iter (function
    | DFunc f when f.name="fixtureNote" && fixture_body<>None -> add f.body (Option.get fixture_body)
    | d -> List.iter visit (Frontend_check.module_expression_roots {(S.module_ view) with decls=[d]})) (S.module_ view).decls;
  syntax (S.replace view !edits)
let finish root path p render ?fixture_body ?(extra="") () =
  let file=path "migrations/notes/v2.tesl" in
  check bool "custom holes block compilation" false (P.compilable p);
  materialize p;
  let chosen=read file in
  let repeated=get (preview root) in
  check int "refresh preserves the selected scaffold" 0 (List.length (M.edits (P.manifest repeated)));
   write file (complete file chosen render ?fixture_body () ^ extra); check_app root; check_emit file;
  check int "completed choice remains refresh-idempotent" 0 (List.length (M.edits (P.manifest (get (preview root)))))
let literal_choice () = with_project (fun root path ->
  let frozen=read (path "schema/notes/v1.tesl") in
  write (path "schema/notes/v-current.tesl") (replace "amount: Int" "amount: Int, title: String" simple);
  let p=get (preview root) in
  check int "input digest is full SHA-256" 64 (String.length (P.input_digest p));
  let before=files root in
  let chosen=get (choose root p "additive-default") in
  check bool "choice preview never writes" true (before=files root);
  finish root path chosen (fun _ -> "\"reviewed title\"") ();
  check string "choice never edits frozen source" frozen (read (path "schema/notes/v1.tesl")))
let revalidation_choice () = with_project ~old:(replace "PROOF" "" proof_source) (fun root path ->
  write (path "schema/notes/v-current.tesl") (replace "PROOF" " ::: Good title" proof_source);
  let p=get (preview root) in
  let chosen=get (choose root p "revalidate:NotesSchema.VCurrent.accept") in
  let actual=source chosen (path "migrations/notes/v2.tesl") in
  check bool "checked Revalidate rule is inserted" true (Compile.string_contains actual "Revalidate title NotesSchema.VCurrent.accept");
  finish root path chosen (fun reason -> if String.starts_with ~prefix:"Choose " reason then "Reject \"invalid historical title\"" else "\"fixture\"") ())
let primitive_choice_with_imports imports () = with_project (fun root path ->
  let file=path "migrations/notes/v2.tesl" in
  if imports<>"" then write file(replace "\nimport Tesl.Migration" ("\n" ^ imports ^ "import Tesl.Migration") (read file));
  write (path "schema/notes/v-current.tesl") (replace "amount: Int" "amount: String" simple);
  let p=get (preview root) in
  let chosen=get (choose root p "migrate-retype") in
  finish root path chosen (fun reason ->
    if String.starts_with ~prefix:"Choose " reason then "Reject \"rejected historical amount\""
    else if String.starts_with ~prefix:"Convert " reason then "Something \"converted\""
    else if String.starts_with ~prefix:"Return " reason then "Something 7"
    else if Compile.string_contains reason "Note.amount" then "7"
    else "\"fixture\"") ())
let primitive_choice () = primitive_choice_with_imports "" ()
let constructor_imports () =
  List.iter(fun imports->primitive_choice_with_imports imports ())
    ["import Tesl.Maybe exposing [Maybe, Something, Nothing]\nimport Tesl.Migration exposing [Migrated, Row, Reject]\n";
     "import Tesl.Maybe exposing [Maybe, Something]\nimport Tesl.Migration exposing [Migrated, Row]\n";
     "import Tesl.Maybe exposing [Maybe]\nimport Tesl.Maybe exposing [Nothing, Something]\n"]
let changed_proof_choice () = with_project ~old:(replace "PROOF" " ::: Good title" proof_source) (fun root path ->
  write (path "schema/notes/v-current.tesl") (proof_source |> replace "PROOF" " ::: Good title" |> replace "value != \"\"" "value != \"blocked\"");
  let p=get (preview root) in
  check bool "changed historical proof is never Revalidate" false (List.exists (String.starts_with ~prefix:"revalidate:") (options p));
  let chosen=get (choose root p "migrate-retype") in
   finish root path chosen (fun reason ->
    if String.starts_with ~prefix:"Choose " reason then "Reject \"invalid input\""
    else if String.starts_with ~prefix:"Convert " reason then "NotesSchema.VCurrent.accept value"
    else if String.starts_with ~prefix:"Return " reason then
      "NotesSchema.V1.accept current.title"
     else "\"fixture\"") ())
let validator_choice () = with_project ~old:(replace "PROOF" " ::: Good title" proof_source) (fun root path ->
  write (path "schema/notes/v-current.tesl") (proof_source |> replace "PROOF" " ::: Good title" |> replace "value != \"\"" "value != \"blocked\"");
  let p=get(preview root)in
  let chosen=get(choose root p "migrate-validators")in
  let actual=source chosen(path "migrations/notes/v2.tesl")in
  List.iter(fun expected->check bool ("generated " ^ expected) true (Compile.string_contains actual expected))
    ["NotesSchema.VCurrent.accept value";"NotesSchema.V1.accept current.title";"Maybe (previousValue:";"Retype title";"WriteBack title title"];
  finish root path chosen (fun reason->
    if String.starts_with ~prefix:"Choose an explicit Reject" reason then "Reject \"invalid historical title\""
    else "\"fixture\"") ())
let ambiguous_validator () = with_project ~old:(replace "PROOF" " ::: Good title" proof_source) (fun root path ->
  let fresh=proof_source |> replace "PROOF" " ::: Good title" |> replace "value != \"\"" "value != \"blocked\"" in
  write(path "schema/notes/v-current.tesl") (fresh |> replace "Good, accept]" "Good, accept, other]" |>
    fun source->source ^ "\nestablish other(value: String) -> Maybe (accepted: String ::: Good accepted) =\n  accept value\n");
  let p=get(preview root)in
  check bool "ambiguous validators require a manual choice" false(List.mem "migrate-validators"(options p));
  check bool "generic conversion remains available" true(List.mem "migrate-retype"(options p)))
let multiple_validator_fields () =
  let old=proof_source |> replace "PROOF" "" |> replace "title: String }" "title: String, memo: String }"in
  with_project ~old(fun root path->
    write(path "schema/notes/v-current.tesl") (old |> replace "title: String, memo: String"
      "title: String ::: Good title, memo: String ::: Good memo");
    let chosen=get(choose root (get(preview root)) "migrate-validators")in
    let actual=source chosen(path "migrations/notes/v2.tesl")in
    check bool "both fields receive storage rules" true
      (Compile.string_contains actual "Retype title" && Compile.string_contains actual "Retype memo");
    finish root path chosen (fun reason->if String.starts_with ~prefix:"Choose an explicit Reject" reason then
      "Reject \"invalid historical value\"" else if String.starts_with ~prefix:"Historical example" reason then
      "\"fixture\"" else fail("unnecessary domain hole: " ^ reason)) ())
let optional_required () =
 let old=simple |> replace "import Tesl.Prelude" "import Tesl.Maybe exposing [Maybe(..)]\nimport Tesl.Prelude" |>
   replace "amount: Int" "amount: Maybe String"in
 with_project ~old(fun root path->
   write(path "schema/notes/v-current.tesl")(replace "amount: Maybe String" "amount: String" old);
   let p=get(preview root)in
   let chosen=get(choose root p "require-value")in
   let actual=source chosen(path "migrations/notes/v2.tesl")in
   List.iter(fun text->check bool text true(Compile.string_contains actual text))
     ["case old.amount of";"Something value -> value";"Something current.amount";"Retype amount";"WriteBack amount amount"];
   finish root path chosen(fun reason->
     if String.starts_with ~prefix:"Value to use when" reason then "\"No amount\""
     else if Compile.string_contains reason "Note.amount" then "Nothing"
     else "\"fixture\"") ())
let required_constructor_fixture () =
 let old=proof_source |> replace "[Note, Good, accept]" "[Note, Good, accept, newNote]" |>
   replace "title: StringPROOF" "title: String ::: Good title, details: Maybe String" in
 let old=old ^ "\nfn newNote(id: String, title: String ::: Good title) -> Note =\n  Note { id: id, title: title, details: Nothing }\n"in
 with_project ~old(fun root path->
   write(path "schema/notes/v-current.tesl")(old |> replace "details: Maybe String" "details: String" |> replace "details: Nothing" "details: \"\"");
   let chosen=get(choose root(get(preview root))"require-value")in
   let actual=source chosen(path "migrations/notes/v2.tesl")in
   check bool "old constructor fills unrelated fields" true(Compile.string_contains actual "NotesSchema.V1.newNote");
   check bool "old validator supplies the exact fixture proof" true(Compile.string_contains actual "case NotesSchema.V1.accept");
   let diagnostics=P.diagnostics chosen in
   check int "only three focused input holes remain" 3(List.length diagnostics);
   List.iter(fun(d:Compile.diagnostic)->check string "domain placeholder diagnostic" "MIG003" d.code;
     check bool "asks for the missing value or example" true(String.starts_with ~prefix:"Migration needs a value: " d.message))diagnostics;
   finish root path chosen(fun reason->if String.starts_with ~prefix:"Value to use when" reason then "old.id" else "\"reviewed example\"") ())
let stale_choice () = with_project (fun root path ->
  write (path "schema/notes/v-current.tesl") (replace "amount: Int" "amount: Int, title: String" simple);
  let p=get (preview root) in
  let before=files root in
  let unknown option_ decision = P.generate_choice ~project_root:root ~entry_file:(path "app.tesl") ~database:None ~documents:[]
    ~decision ~option_ ~expected_input_digest:(P.input_digest p) in
  refused (unknown "invented-option" "entity:Note"); refused (unknown "additive-default" "invented-decision");
  check bool "unknown choices cannot write" true (before=files root);
  write (path "app.tesl") (app ^ "# saved after preview\n");
  let before=files root in refused (choose root p "additive-default");
  check bool "stale source is preserved exactly" true (before=files root))
let stale_documents () = with_project (fun root path ->
  write (path "schema/notes/v-current.tesl") (replace "amount: Int" "amount: Int, title: String" simple);
  let documents=[{M.path=path "app.tesl";version=4}] in
  let p=get (preview ~documents root) in
  refused (choose root p "additive-default" ~documents:[{M.path=path "app.tesl";version=5}]);
  refused (choose root p "additive-default" ~documents:[]))
let unsupported_shapes () =
  List.iter (fun (label,fresh) -> with_project (fun root path ->
    write (path "schema/notes/v-current.tesl") fresh;
    let p=get (preview root) in
    check bool (label ^ " cannot offer a primitive converter") false (List.mem "migrate-retype" (options p))))
    ["changed primary key",replace "id: String" "id: Int" simple;
     "renamed field",replace "amount: Int" "renamed: String" simple;
     "changed index",replace "amount: Int }" "amount: String\n index [amount] as \"amount_lookup\"\n}" simple];
  with_project ~old:(replace "PROOF" "" proof_source) (fun root path ->
    write (path "schema/notes/v-current.tesl") (proof_source |> replace "PROOF" " ::: Good title" |> replace "[Note, Good, accept]" "[Note]");
    check (list string) "hidden proof owners have no guessed scaffold" [] (options (get (preview root))))
let crlf_choice () =
  let crlf=replace "\n" "\r\n" in
  with_project ~old:(crlf simple) (fun root path ->
    let file=path "migrations/notes/v2.tesl" in write file (crlf (replace "\r\n" "\n" (read file)));
    write (path "schema/notes/v-current.tesl") (crlf (replace "amount: Int" "amount: String" simple));
    let p=get (preview root) in let chosen=get (choose root p "migrate-retype") in
    let after=source chosen file in
    check bool "new metadata and helper fragments preserve CRLF" true (String.contains after '\r');
    String.iteri (fun i c -> if c='\n' then check bool "no bare generated LF" true (i>0 && after.[i-1]='\r')) after;
    materialize chosen;
    check int "CRLF scaffold refresh remains idempotent" 0 (List.length (M.edits (P.manifest (get (preview root))))))
let strict_command_flags () = with_project (fun _root path ->
  let digest=String.make 64 '0' in
  let flags=["--decision";"entity:Note";"--option";"additive-default";"--expected-input-digest";digest] in
  let args=["generate";path "app.tesl";"--manifest-json"] in
  List.iter (fun extra ->
    let response=Migration_command.run (args @ extra) in
    check int "invalid choice arguments fail" 1 response.exit_code;
    check bool "failure has no manifest" true (Compile.string_contains response.stdout "\"manifest\":null"))
    [["--decision";"entity:Note"];["--option";"additive-default"];["--expected-input-digest";digest];
     flags @ ["--new-revision"];flags @ ["--decision";"entity:Note"];
     ["--decision";"entity:Note";"--option";"additive-default";"--expected-input-digest";String.make 64 'A']];
  List.iter (fun verb -> let response=Migration_command.run ([verb;path "app.tesl";"--manifest-json"] @ flags) in
     check int "other verbs cannot consume a choice" 1 response.exit_code) ["contract";"plan"])
let column_rename () = with_project(fun root path->
 write(path "schema/notes/v-current.tesl")(replace "amount: Int" "count: Int" simple);
 let chosen=get(choose root(get(preview root))"rename:amount:count")in
 check bool "pure rename has no invented policy holes" true(P.compilable chosen);
 check bool "complete Derived rule" true(Compile.string_contains(source chosen(path "migrations/notes/v2.tesl"))"Derived [Rename amount count]");
 materialize chosen;check_app root;
 check int "rename refresh is stable" 0(List.length(M.edits(P.manifest(get(preview root))))))
let removed_column () = with_project(fun root path->
 write(path "schema/notes/v-current.tesl")(replace ", amount: Int" "" simple);
 let chosen=get(choose root(get(preview root))"map-fields")in
 check bool "old writers get an explicit projection" true(Compile.string_contains(source chosen(path "migrations/notes/v2.tesl"))"LegacyWith amount");
 finish root path chosen(fun reason->if String.starts_with ~prefix:"Return Something" reason then "Something 7" else if Compile.string_contains reason "amount"then "7"else "\"fixture\"") ())
let compound_columns () = with_project(fun root path->
 write(path "schema/notes/v-current.tesl")(replace "amount: Int" "amount: String, memo: String" simple);
 let chosen=get(choose root(get(preview root))"map-fields")in
 finish root path chosen(fun reason->
  if String.starts_with ~prefix:"Convert Note.amount" reason then "Something \"converted\""
  else if String.starts_with ~prefix:"Convert historical" reason then "Something 7"
  else if String.starts_with ~prefix:"Historical fallback" reason || Compile.string_contains reason "example for NotesSchema.V1.Note.amount" then "7"
  else "\"reviewed\"") ())
let stored_record = {|module NotesSchema.VCurrent exposing [Note, Meta]
import Tesl.Prelude exposing [String, Int]
import Tesl.Json exposing [stringCodec]
record Meta { text: String }
codec Meta {
 toJson { text -> "text" with_codec stringCodec }
 fromJson [ { text <- "text" with_codec stringCodec } ]
}
entity Note table "notes" primaryKey id { id: String, metadata: Meta }
|}
let codec_choice () = with_project ~old:stored_record(fun root path->
 write(path "schema/notes/v-current.tesl")(replace "\"text\"" "\"message\"" stored_record);
 let chosen=get(choose root(get(preview root))"map-fields")in
 let actual=source chosen(path "migrations/notes/v2.tesl")in
 check bool "nominal codec values rebuilt in both directions" true(Compile.string_contains actual "NotesSchema.VCurrent.Meta {" && Compile.string_contains actual "NotesSchema.V1.Meta {");
 finish root path chosen(fun _->"\"reviewed\"") ())
let record_shape_choice () = with_project ~old:stored_record(fun root path->
 let fresh=stored_record |> replace "Meta { text: String }" "Meta { text: String, tag: String }" |>
   replace "toJson { text -> \"text\" with_codec stringCodec }" "toJson { text -> \"text\" with_codec stringCodec, tag -> \"tag\" with_codec stringCodec }" |>
   replace "fromJson [ { text <- \"text\" with_codec stringCodec } ]" "fromJson [ { text <- \"text\" with_codec stringCodec, tag <- \"tag\" with_codec stringCodec } ]"in
 write(path "schema/notes/v-current.tesl")fresh;
 finish root path (get(choose root(get(preview root))"map-fields"))(fun _->"\"reviewed\"") ())
let stored_adt = {|module NotesSchema.VCurrent exposing [Note, Status(..)]
import Tesl.Prelude exposing [String]
type Status =
  | Idle
  | Active text: String
codec Status { adtJson }
entity Note table "notes" primaryKey id { id: String, status: Status }
|}
let adt_choice () = with_project ~old:stored_adt(fun root path->
 write(path "schema/notes/v-current.tesl")(replace "| Active text: String" "| Active text: String\n  | Paused reason: String" stored_adt);
 let chosen=get(choose root(get(preview root))"map-fields")in
 check bool "reverse enumerates new variants" true(Compile.string_contains(source chosen(path "migrations/notes/v2.tesl"))"NotesSchema.VCurrent.Paused");
 finish root path chosen(fun reason->
  if String.starts_with ~prefix:"Map removed" reason then "Something NotesSchema.V1.Idle"
  else if String.starts_with ~prefix:"Historical fallback" reason || Compile.string_contains reason "Note.status"then "NotesSchema.V1.Idle"
  else "\"fixture\"") ())
let queue_schema={|module NotesSchema.VCurrent exposing [Tasks, Notify]
import Tesl.Prelude exposing [String, Int]
import Tesl.Json exposing [stringCodec, intCodec]
record Notify { text: String }
codec Notify {
 toJson { text -> "text" with_codec stringCodec }
 fromJson [ { text <- "text" with_codec stringCodec } ]
}
queueSchema Tasks { jobs: [Notify] }
|}
let queue_program={|module App exposing []
import NotesSchema.VCurrent
import Tesl.Prelude exposing [Unit, String]
import Tesl.Database exposing [Database, Memory]
import Tesl.Queue exposing [Queue, FromQueue, queueRead]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.App exposing [App]
database Main = Database { schema: NotesSchema.VCurrent, migrations: NotesSchema.Migrate, backend: Memory }
queue Tasks requires [queueRead] = Queue { database: Main, schema: NotesSchema.VCurrent.Tasks,
 jobs: [Job NotesSchema.VCurrent.Notify handle Nothing] }
worker handle(job: NotesSchema.VCurrent.Notify ::: FromQueue (Id == jobId) job) requires [queueRead] = job
handler get healthy() -> String = "ok"
api Routes { get "/" -> String }
server Web for Routes { healthy }
main() -> App requires [queueRead] = App { database: Main, queues: [Tasks], api: Web }
|}
let queue_choice () = with_project ~old:queue_schema ~program:queue_program(fun root path->
 let fresh=queue_schema |> replace "text: String" "body: String, priority: Int" |>
   replace "text -> \"text\" with_codec stringCodec" "body -> \"message\" with_codec stringCodec, priority -> \"priority\" with_codec intCodec" |>
   replace "text <- \"text\" with_codec stringCodec" "body <- \"message\" with_codec stringCodec, priority <- \"priority\" with_codec intCodec"in
 write(path "schema/notes/v-current.tesl")fresh;
 let proposal=get(preview root)in
 let chosen=get(choose root proposal "map-queued-payload")in
 check bool "queue helper is a separate proposed source file" true(List.exists(fun(e:M.edit)->Compile.string_contains e.path "/v2/author-notify.tesl")(M.edits(P.manifest chosen)));
  check bool "queue inputs remain explicit holes" false(P.compilable chosen);
  check bool "queue helper holes request domain values rather than unknown identifiers" true
    (List.exists(fun(d:Compile.diagnostic)->d.code="MIG003" && Compile.string_contains d.message "Migration needs a value:")(P.diagnostics chosen) &&
     not(List.exists(fun(d:Compile.diagnostic)->Compile.string_contains d.message "unknown name: todo")(P.diagnostics chosen)));
  let inputs p = P.diagnostics p |> List.filter(fun(d:Compile.diagnostic)->d.code="MIG003" && String.starts_with ~prefix:"Migration needs a value: " d.message) in
  check int "all queue helper inputs appear once in the proposed preview" 3 (List.length(inputs chosen));
  materialize chosen;
  check int "all queue helper inputs remain navigable after application" 3 (List.length(inputs(get(preview root))));
 List.iter(fun(e:M.edit)->if Compile.string_contains e.path "/v2/author-notify.tesl"then
   write e.path(complete e.path(read e.path)(fun reason->
     if Compile.string_contains reason ".body"then "value.text"
     else if Compile.string_contains reason ".priority"then "7"
     else "\"historical\"")()))(M.edits(P.manifest chosen));
 check_app root;check_emit(path "migrations/notes/v2.tesl");
 check int "queue choice refresh preserves helper edits" 0(List.length(M.edits(P.manifest(get(preview root))))))
let added_proven_field () = with_project ~old:(replace "PROOF" "" proof_source)(fun root path->
 write(path "schema/notes/v-current.tesl")(proof_source |>replace "PROOF" " ::: Good title" |>replace "Good title }" "Good title, memo: String }");
 finish root path(get(choose root(get(preview root))"map-fields"))(fun _->"\"reviewed\"") ())
let new_record_field () = with_project(fun root path->
 let fresh=simple |>replace "[Note]" "[Note, Meta]" |>replace "entity Note" "import Tesl.Json exposing [stringCodec]\nrecord Meta { text: String }\ncodec Meta {\n toJson { text -> \"text\" with_codec stringCodec }\n fromJson [ { text <- \"text\" with_codec stringCodec } ]\n}\nentity Note" |>
   replace "amount: Int }" "amount: Int, metadata: Meta }"in
 write(path "schema/notes/v-current.tesl")fresh;
 finish root path(get(choose root(get(preview root))"map-fields"))(fun reason->if Compile.string_contains reason "Note.amount"then "7"else "\"example\"") ())
let required_optional () = with_project(fun root path->
 let fresh=simple |>replace "import Tesl.Prelude" "import Tesl.Maybe exposing [Maybe(..)]\nimport Tesl.Prelude" |>replace "amount: Int" "amount: Maybe Int"in
 write(path "schema/notes/v-current.tesl")fresh;
 let chosen=get(choose root(get(preview root))"map-fields")in
 finish root path chosen(fun reason->if Compile.string_contains reason "amount"||Compile.string_contains reason "Amount" then "7" else "\"example\"") ())
let adt_remove () = with_project ~old:stored_adt(fun root path->
 write(path "schema/notes/v-current.tesl")(replace "  | Active text: String\n" "" stored_adt);
 let chosen=get(choose root(get(preview root))"map-fields")in
 finish root path chosen(fun reason->
  if String.starts_with ~prefix:"Map removed" reason then "Something NotesSchema.VCurrent.Idle"
  else if Compile.string_contains reason "Note.status" then "NotesSchema.V1.Idle"else "\"example\"") ())
let adt_payload () = with_project ~old:stored_adt(fun root path->
 write(path "schema/notes/v-current.tesl")(stored_adt |>replace "[String]" "[String, Int]" |>replace "Active text: String" "Active text: String count: Int");
 finish root path(get(choose root(get(preview root))"map-fields"))(fun reason->
  if Compile.string_contains reason ".count"then "3"else if Compile.string_contains reason "Note.status"then "NotesSchema.V1.Idle"else "\"example\"") ())
let optional_record () =
 let old=stored_record |>replace "import Tesl.Prelude" "import Tesl.Maybe exposing [Maybe(..)]\nimport Tesl.Prelude" |>replace "metadata: Meta" "metadata: Maybe Meta"in
 with_project ~old(fun root path->
  write(path "schema/notes/v-current.tesl")(replace "\"text\"" "\"message\"" old);
  finish root path(get(choose root(get(preview root))"map-fields"))(fun reason->if Compile.string_contains reason "Note.metadata"then "Nothing"else "\"example\"") ())
let multi_rename () =
 let old=simple |>replace "amount: Int }" "amount: Int, title: String }"in
 with_project ~old(fun root path->
  write(path "schema/notes/v-current.tesl")(old |>replace "amount: Int" "count: Int" |>replace "title: String" "label: String");
  let chosen=get(choose root(get(preview root))"rename-all")in
  check bool "multiple explicit renames are complete" true(P.compilable chosen);materialize chosen;check_app root)
let mixed_queue_refusal () =
 let old=queue_schema ^ "entity Note table \"notes\" primaryKey id { id: String }\n" |>replace "Tasks, Notify]" "Tasks, Notify, Note]"in
 with_project ~old ~program:queue_program(fun root path->
  write(path "schema/notes/v-current.tesl")(old |>replace "{ id: String }" "{ id: String, amount: Int }" |>replace "\"text\"" "\"message\"");
  let p=get(preview root)in
  check bool "mixed queue transition never gets an executable template" false(List.mem "map-queued-payload"(options p));
  let open Yojson.Basic.Util in
  let queue=List.find(fun d->String.starts_with ~prefix:"job:"(member "id" d|>to_string))(decisions p)in
  check bool "explains an ordered split" true(Compile.string_contains(member "reason" queue|>to_string)"Split this change"))
let remove_queue () = with_project ~old:queue_schema ~program:queue_program(fun root path->
 write(path "schema/notes/v-current.tesl")(queue_schema |>replace "Tasks, " "" |>replace "queueSchema Tasks { jobs: [Notify] }\n" "");
 write(path "app.tesl")app;
 let chosen=get(choose root(get(preview root))"remove-empty-queue")in
 check bool "empty queue retirement source checks" true(P.compilable chosen);materialize chosen;check_app root)
let placeholder_shadow () = with_project(fun root path->
 let file=path "migrations/notes/v2.tesl"in
 write file(read file ^ "\nfn todo(reason: String) -> String = reason\n");
 write(path "schema/notes/v-current.tesl")(replace "amount: Int" "amount: String" simple);
 check (list string) "holes cannot resolve to user executable code" [] (options(get(preview root))))
let multiple_revalidation () =
 let old=proof_source |>replace "PROOF" "" |>replace "title: String }" "title: String, memo: String }"in
 with_project ~old(fun root path->
  write(path "schema/notes/v-current.tesl")(old |>replace "title: String, memo: String" "title: String ::: Good title, memo: String ::: Good memo");
  let chosen=get(choose root(get(preview root))"revalidate-fields")in
  finish root path chosen(fun reason->if String.starts_with ~prefix:"Choose a Reject" reason then "Reject \"invalid old value\"" else "\"historical\"") ())
let removed_proof () =
  let old=proof_source |>replace "PROOF" " ::: Good title" |>replace "Good, accept]" "Good, accept, newNote]"in
 let old=old ^ {|
fn newNote(id: String, title: String ::: Good title) -> Note = Note { id: id, title: title }
|}in
 with_project ~old(fun root path->
  write(path "schema/notes/v-current.tesl")(replace "title: String ::: Good title }" "title: String }" old);
  let chosen=get(choose root(get(preview root))"migrate-validators")in
  check bool "forward proof erasure needs no rejected-row policy" false(Compile.string_contains(source chosen(path "migrations/notes/v2.tesl"))"Choose an explicit Reject");
   finish root path chosen(fun _->"\"historical\"") ())
let nested_list_record () =
 let old=stored_record |>replace "[Note, Meta]" "[Note, Meta, Inner]" |>replace "[String, Int]" "[String, Int, List]" |>
   replace "[stringCodec]" "[stringCodec, listCodec]" |>
   replace "record Meta { text: String }" "record Inner { text: String }\ncodec Inner {\n toJson { text -> \"inner\" with_codec stringCodec }\n fromJson [ { text <- \"inner\" with_codec stringCodec } ]\n}\nrecord Meta { text: List Inner }" |>
   replace "\"text\" with_codec stringCodec" "\"text\" with_codec listCodec"in
 with_project ~old(fun root path->
  write(path "schema/notes/v-current.tesl")(replace "\"inner\"" "\"message\"" old);
  finish root path(get(choose root(get(preview root))"map-fields"))(fun reason->
    if Compile.string_contains reason "metadata.text"then "[NotesSchema.V1.Inner { text: \"old\" }]"else "\"fixture\"") ())
let record_field_proof () =
 let old=stored_record |>replace "[Note, Meta]" "[Note, Meta, GoodMeta, acceptMeta]" |>
   replace "import Tesl.Prelude" "import Tesl.Maybe exposing [Maybe(..)]\nimport Tesl.Prelude" |>
   replace "entity Note" "fact GoodMeta(value: Meta)\nestablish acceptMeta(value: Meta) -> Maybe (accepted: Meta ::: GoodMeta accepted) =\n  if value.text != \"\" then\n    Something (value ::: GoodMeta value)\n  else\n    Nothing\nentity Note"in
 with_project ~old(fun root path->
  write(path "schema/notes/v-current.tesl")(replace "metadata: Meta }" "metadata: Meta ::: GoodMeta metadata }" old);
  let chosen=get(choose root(get(preview root))"map-fields")in
  check bool "record validation follows typed reconstruction" true(Compile.string_contains(source chosen(path "migrations/notes/v2.tesl"))"NotesSchema.VCurrent.acceptMeta");
  finish root path chosen(fun _->"\"reviewed\"") ())
let generic_adt () =
 let old={|module NotesSchema.VCurrent exposing [Note, Box(..)]
import Tesl.Prelude exposing [String]
type Box a =
  | Wrapped value: a
entity Note table "notes" primaryKey id { id: String, metadata: Box String }
|}in
 with_project ~old(fun root path->
  write(path "schema/notes/v-current.tesl")(replace "| Wrapped value: a" "| Wrapped value: a label: String" old);
  let preview=get(preview root)in
  check (list string) "no template that fails native generic emission" [] (options preview);
  let open Yojson.Basic.Util in
  check bool "the native boundary has a concrete explanation" true(List.exists(fun d->Compile.string_contains(member "reason" d|>to_string)"generic stored ADT")(decisions preview)))
let cleanup_authoring () =
 let program=app |>replace "[Database, Memory]" "[Database, Postgres, PostgresConfig, TcpConnection, MigrationConfig, Worker]" |>
   replace "backend: Memory" "backend: Postgres (PostgresConfig { namespace: \"notes\", dbName: \"unused\", user: \"unused\", password: \"\", connection: TcpConnection { host: \"127.0.0.1\", port: 5432 }, migrations: MigrationConfig { topology: Worker, controlOwner: \"owner\", workerRole: \"worker\", requestRole: \"request\", ddlConnection: \"\" } })"in
 with_project ~program(fun root path->
  write(path "schema/notes/v-current.tesl")(replace "amount: Int" "amount: String" simple);
  finish root path(get(choose root(get(preview root))"migrate-retype"))(fun reason->
    if String.starts_with ~prefix:"Choose " reason then "Reject \"invalid\""
    else if String.starts_with ~prefix:"Convert " reason then "Something \"converted\""
    else if String.starts_with ~prefix:"Return " reason then "Something 7"
    else if Compile.string_contains reason "Note.amount" then "7"
    else "\"fixture\"") ();
  let module U=Yojson.Basic.Util in
  let metadata=P.to_json(get(preview root))|>Yojson.Basic.from_string in
  let cleanup=U.member "cleanup" metadata|>U.to_list in
  check int "one reviewed cleanup is needed" 1(List.length cleanup);
  check bool "cleanup is not yet present" false(U.member "present"(List.hd cleanup)|>U.to_bool);
  refused(P.generate ~project_root:root ~entry_file:(path "app.tesl") ~database:None ~new_revision:true ~documents:[]);
  let proposal=get(P.generate_contract ~project_root:root ~entry_file:(path "app.tesl") ~database:None ~version:2 ~documents:[])in
  check bool "generated cleanup passes source checks" true(P.compilable proposal);
  materialize proposal;check_app root;check_emit(path "app.tesl");
  ignore(get(P.generate ~project_root:root ~entry_file:(path "app.tesl") ~database:None ~new_revision:true ~documents:[])))
let native_tests ?(extra=fun ()->()) path file =
 let artifacts=match Compile.compile_go_source file(read file)with
  | Compile.GoSuccess artifacts->artifacts|Compile.GoFailure errors->fail(Compile.diagnostics_to_json errors)in
  List.iter(fun(a:Emit_go.artifact)->write(path("out/" ^ a.path))a.contents)artifacts;
 extra ();
 let log=path "native.log"in
 let command=Printf.sprintf "cd %s && GOMAXPROCS=2 go test -p 1 -count=1 -timeout=60s -v ./... > %s 2>&1"
   (Filename.quote(path "out"))(Filename.quote log)in
 if Sys.command command<>0 then fail(read log);
 check bool "native tests executed" true(Compile.string_contains(read log)"--- PASS:")
let fallible_reverse () = with_project ~old:(replace "PROOF" " ::: Good title" proof_source)(fun root path->
 let frozen=read(path "schema/notes/v1.tesl")in
 write(path "schema/notes/v-current.tesl")(proof_source |> replace "PROOF" " ::: Good title" |> replace "value != \"\"" "value != \"blocked\"");
 let chosen=get(choose root(get(preview root))"migrate-validators")in
 finish root path chosen(fun reason->if String.starts_with ~prefix:"Choose an explicit Reject" reason then "Reject \"invalid\""else "\"fixture\"") ();
 let file=path "migrations/notes/v2.tesl"in
 let valid=read file |> replace "exposing [String]" "exposing [String, Bool(..)]"in
 write file(valid ^ {|
fn withFallback(current: NotesSchema.VCurrent.Note) -> Maybe (previous: String ::: NotesSchema.V1.Good previous) =
  case NotesSchema.V1.accept current.title of
    Nothing -> NotesSchema.V1.accept "business fallback"
    Something previous -> Something previous
test "ordinary Maybe preserves proof and allows explicit fallback" {
  case NotesSchema.VCurrent.accept "" of
    Nothing -> expect False
    Something title ->
      let current = NotesSchema.VCurrent.Note { id: "new", title: title }
      expect writeBackNoteTitle current == Nothing
      expect withFallback current == Something "business fallback"
}
|});check_app root;native_tests path file;
 write file(valid ^ "\nfn unchecked() -> value: String ::: NotesSchema.V1.Good value =\n  case NotesSchema.V1.accept \"valid\" of\n    Something value -> value\n");
 let errors=(Compile.agent_context_result_source file(read file)).diagnostics in
 check bool "migrations have no exception to exhaustive cases" true(List.exists(fun(d:Compile.diagnostic)->Compile.string_contains d.message "non-exhaustive")errors);
 write file(replace "NotesSchema.V1.accept current.title" "Something \"forged\"" valid);
 check bool "optional result cannot fabricate old proof" false(Compile.agent_context_result_source file(read file)).ok;
 write file valid;check_app root;
 check string "old proof API unchanged" frozen(read(path "schema/notes/v1.tesl")))

let row_deletion_choice () = with_project ~old:stored_adt(fun root path->
 write(path "schema/notes/v-current.tesl")(replace "  | Active text: String\n" "" stored_adt);
 let chosen=get(choose root(get(preview root))"delete-rows")in
 finish root path chosen(fun reason->
  if String.starts_with ~prefix:"Return True" reason then "case old.status of\n    NotesSchema.V1.Active { text = text } -> True\n    NotesSchema.V1.Idle -> False"
  else if String.starts_with ~prefix:"Map removed" reason then "Nothing"
  else if Compile.string_contains reason "Note.status" then "NotesSchema.V1.Idle"
  else "\"obsolete\"") ();
 let file=path "migrations/notes/v2.tesl"in
 write file(read file ^ {|
test "removed variant selects explicit row deletion" {
  let old = NotesSchema.V1.Note { id: "obsolete", status: NotesSchema.V1.Active { text: "retired" } }
  case migrateNote old of
    KeepRow row -> expect False
    DeleteRow reason -> expect reason == "obsolete"
    RejectRow reason -> expect False
}
test "retained variant remains a checked row" {
  let old = NotesSchema.V1.Note { id: "retained", status: NotesSchema.V1.Idle }
  case migrateNote old of
    KeepRow row -> expect row.id == "retained"
    DeleteRow reason -> expect False
    RejectRow reason -> expect False
}
|});check_app root;native_tests path file)

let malformed_writeback_tag () = with_project (fun _root path ->
 let extra () =
  let module_line=List.hd(String.split_on_char '\n'(read(path "out/go.mod"))) in
  let module_name=String.sub module_line 7 (String.length module_line-7) in
  (* Execute the exact field-unwrapping fragment used by generated row adapters.
     A malformed native result must trap, not become a compatibility refusal. *)
  let preparation=Emit_go.optional_writeback_preparation
    ~variable:"previous" ~callback:"input" ~previous_type:"string" in
  write(path "out/internal/writebackguard/writeback_test.go")
   ("package writebackguard\nimport (\"testing\"; teslrt \"" ^ module_name ^ "/internal/teslrt\")\n" ^
    "func reverse(input teslrt.Maybe[string]) teslrt.Maybe[string] {\n" ^ preparation ^
    "return teslrt.Something(previous.SomethingValue)\n}\n" ^ {|
func TestWriteBackResultClassification(t *testing.T) {
  t.Run("Something preserves its value", func(t *testing.T) {
    result := reverse(teslrt.Something("historical"))
    if result.Tag != teslrt.MaybeSomething || result.SomethingValue != "historical" { t.Fatal("lost historical value") }
  })
  t.Run("Nothing is an explicit refusal", func(t *testing.T) {
    if reverse(teslrt.Nothing[string]()).Tag != teslrt.MaybeNothing { t.Fatal("lost explicit refusal") }
  })
  t.Run("unknown tag is a failure", func(t *testing.T) {
    defer func() { if recover() == nil { t.Fatal("invalid Maybe tag became a compatibility refusal") } }()
    reverse(teslrt.Maybe[string]{Tag: 99})
  })
}
|}) in
 native_tests ~extra path (path "app.tesl"))

let () = run "Compiler-owned migration choices" ["complete source workflows",List.map (fun (name,test) -> test_case name `Quick test)
  ["required literal default",literal_choice;"checked first-proof revalidation",revalidation_choice;
   "primitive representation conversion",primitive_choice;"changed historical proof with exact write-back",changed_proof_choice;
   "stale or invented choices never apply",stale_choice;"document set and versions bind the choice",stale_documents;
   "unsupported shapes never guess converters",unsupported_shapes;"consistent CRLF survives a selected scaffold",crlf_choice;
   "choice flags are strict and grouped",strict_command_flags;
    "existing constructor imports remain valid",constructor_imports;
    "changed proofs reuse exact validators",validator_choice;
     "multiple fields reuse validators with plain historical write-back",multiple_validator_fields;
     "optional primitive becomes required with a missing-value choice",optional_required;
     "required fields reuse historical constructor and explain domain holes",required_constructor_fixture;
     "ambiguous validators are not guessed",ambiguous_validator;
     "column rename preserves data without holes",column_rename;
     "removed columns generate old-writer projections",removed_column;
     "new and retyped fields compose",compound_columns;
     "codec-only changes rebuild exact nominal values",codec_choice;
     "stored record shape changes scaffold fields",record_shape_choice;
     "ADT additions generate exhaustive reverse cases",adt_choice;
     "queue record and codec changes generate a pure helper module",queue_choice;
     "proof strengthening composes with added columns",added_proven_field;
     "new record fields receive typed constructor skeletons",new_record_field;
     "required-to-optional generates the reverse missing policy",required_optional;
     "removed ADT variants receive explicit forward policies",adt_remove;
     "ADT payload additions receive field holes",adt_payload;
     "optional stored records preserve Nothing",optional_record;
     "multiple explicit renames compose",multi_rename;
     "mixed rows and queues explain a split",mixed_queue_refusal;
     "whole empty queues have an explicit retirement choice",remove_queue;
     "placeholder names never resolve to user code",placeholder_shadow;
     "multiple first proofs share checked revalidation",multiple_revalidation;
     "removed proofs preserve values with old validation",removed_proof;
     "nested record lists rebuild through exact codecs",nested_list_record;
     "record-valued field proofs reuse target validators",record_field_proof;
     "generic ADT backend limits do not offer unusable plans",generic_adt;
      "cleanup is reviewable before freezing the next revision",cleanup_authoring;
       "fallible write-back uses ordinary Maybe and exhaustive cases",fallible_reverse;
        "removed ADT variants can select explicit whole-row deletion",row_deletion_choice;
        "generated write-back rejects malformed optional results",malformed_writeback_tag]]
