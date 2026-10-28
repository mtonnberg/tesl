open Alcotest
module D = Migration_declaration
module T = Migration_transform
module R = Migration_transform_rules
module S = Migration_sparse
let replace a b = Str.global_replace (Str.regexp_string a) b
let old = {|module Schema.Notes.V1 exposing [Note]
import Tesl.Prelude exposing [String]
entity Note table "notes" primaryKey id { id: String, author: String, title: String }
|}
let fresh = {|module Schema.Notes.VCurrent exposing [Note]
import Tesl.Prelude exposing [String, Int]
entity Note table "notes" primaryKey id { id: String, title: String, count: Int }
|}
let source = {|module Schema.Notes.Migrate.V2 exposing [migration, convert, oldNote]
import Tesl.Prelude exposing [String, Int, Bool(..)]
import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Migrated(..)]
import Schema.Notes.V1
import Schema.Notes.VCurrent
migration = Migration {
  from: Schema.Notes.V1
  to: Schema.Notes.VCurrent
  same: []
  fixtures: [oldNote]
  entities: { Note: Migrate convert [LegacyWith author backward] }
}
fn convert(old: Schema.Notes.V1.Note) -> Migrated Schema.Notes.VCurrent.Note =
  Row (Schema.Notes.VCurrent.Note { id: old.id, title: old.title, count: 7 })
fn oldNote() -> Schema.Notes.V1.Note =
  Schema.Notes.V1.Note { id: "retained", author: "writer", title: "hello" }
fn backward(row: Schema.Notes.VCurrent.Note) -> String = row.title
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
let checked path s = write path s; accepts path s; match Parser.parse_module path s with
  | Err e -> fail e.msg
  | Ok m -> match D.check ~compiler_abi:(match Migration_abi.current () with Ok abi -> Migration_abi.id abi | Error error -> fail error.message) ~source:s m with
    | Ok (Some d) -> d | Ok None -> fail "missing declaration"
    | Error errors -> fail (String.concat "\n" (List.map (fun (e:S.error) -> e.code ^ ": " ^ e.message) errors))
module L = Migration_transform_link
let transform path source = Option.get (D.transforms (checked path source))
let linked path source = match L.link (transform path source) with
  | Ok linked -> linked | Error error -> fail error.message
let contains text needle = Compile.string_contains text needle
let refuses code path source =
 let diagnostics=errors path source in
 if not(List.exists (fun (d:Compile.diagnostic)->d.code=code) diagnostics) then
  fail ("missing " ^ code ^ ": " ^ describe diagnostics)

let helper_source = {|module Schema.Notes.Migrate.Helpers exposing [backward]
import Tesl.Prelude exposing [String]
import Schema.Notes.VCurrent
fn backward(row: Schema.Notes.VCurrent.Note) -> String = hidden row.title
fn hidden(value: String) -> String = value ++ "!"
|}
let imported_source = source
 |> replace "import Schema.Notes.V1" "import Schema.Notes.Migrate.Helpers\nimport Schema.Notes.V1"
 |> replace "LegacyWith author backward" "LegacyWith author Schema.Notes.Migrate.Helpers.backward"
 |> replace "fn backward(row: Schema.Notes.VCurrent.Note) -> String = row.title\n" ""

let helper_ownership () = project(fun _ save path ->
 ignore(save "migrations/notes/helpers.tesl" helper_source);
 let checked=transform path imported_source in
 let binding=Option.get (List.hd (List.hd (T.rows checked)).legacies).function_binding in
 check string "exact helper owner" "Schema.Notes.Migrate.Helpers.backward" binding.identity;
 ignore(save "migrations/notes/helpers.tesl" (replace "exposing [backward]" "exposing []" helper_source));
 refuses "MIG021" path imported_source;
 ignore(save "migrations/notes/helpers.tesl" helper_source);
 refuses "MIG021" path (replace "LegacyWith author Schema.Notes.Migrate.Helpers.backward" "LegacyWith author backward" imported_source);
 ignore(save "schema/notes/v-current/other.tesl" {|module Schema.Notes.VCurrent.Other exposing [Note]
import Tesl.Prelude exposing [String]
record Note { title: String }
|});
 ignore(save "migrations/notes/helpers.tesl" (helper_source
  |> replace "import Schema.Notes.VCurrent" "import Schema.Notes.VCurrent.Other"
  |> replace "row: Schema.Notes.VCurrent.Note" "row: Schema.Notes.VCurrent.Other.Note"));
 refuses "MIG021" path imported_source)

let helper_purity () = project(fun _ save path ->
 ignore(save "migrations/notes/helpers.tesl" helper_source);
 accepts path imported_source;
 List.iter(fun implementation ->
  ignore(save "migrations/notes/helpers.tesl" (replace "fn hidden(value: String) -> String = value ++ \"!\"" implementation helper_source));
  refuses "MIG021" path imported_source)
 ["fn hidden(value: String) -> String = fail 400 \"private\"";
  "fn hidden(value: String) -> String = unsafe value\ncheck unsafe(value: String) -> String = value";
  "fn hidden(value: String) -> String = stored\nstored = fail 400 \"private\"";
  "fn hidden(value: String) -> String =\n let action = fn (text: String) -> fail 400 \"private\"\n action value"])

let closure_identity () = project(fun _ save path ->
 let helper=save "migrations/notes/helpers.tesl" helper_source in
 let first=linked path imported_source in
 write helper (replace "value ++ \"!\"" "value ++ \"?\"" helper_source);
 (match L.revalidate first with Error e -> check bool "stale exact source" true (contains e.message "changed") | Ok()->fail "changed legacy helper accepted");
 let second=linked path imported_source in
 check bool "helper body changes exact transform" false (L.digest first=L.digest second);
 check bool "helper body changes ABI-independent behavior" false (L.behavior_digest first=L.behavior_digest second);
 Sys.remove helper;
 (match L.revalidate second with Error e -> check bool "deleted closure" true (contains e.message "source") | Ok()->fail "deleted legacy helper accepted"))

let literal_identity () = project(fun _ _ path ->
 let first_source=source |> replace "LegacyWith author backward" "Legacy author \"retired\"" in
 let first=linked path first_source in
 let second=linked path (replace "Legacy author \"retired\"" "Legacy author \"other\"" first_source) in
 check bool "literal changes exact transform" false (L.digest first=L.digest second);
 check bool "literal changes behavior" false (L.behavior_digest first=L.behavior_digest second))

let cross_field () =
 let schema text=text |> replace "exposing [Note]" "exposing [Note, Related, Local]"
  |> replace "entity Note" "fact Related (left: String) (right: String)\nfact Local (value: String)\nentity Note"
  |> replace "title: String" "title: String ::: Local title && Related title id" in
 let body=source |> replace "Rule(..), Migrated(..)" "Rule(..), Same(..), Migrated(..)"
  |> replace "same: []" "same: [Same Schema.Notes.V1.Related Schema.Notes.VCurrent.Related, Same Schema.Notes.V1.Local Schema.Notes.VCurrent.Local]" in
 project ~before:(schema old) ~after:(schema fresh) (fun _ _ path ->
  (* The removed field is unproven. The unsafe relation belongs to a DIFFERENT,
     surviving old field, which a per-field reverse constructor cannot justify. *)
  refuses "MIG021" path body;
  refuses "MIG021" path (replace "LegacyWith author backward" "Legacy author \"retired\"" body))

let nominal_return () =
 let schema text=text |> replace "exposing [Note]" "exposing [Note, Metadata]"
  |> replace "entity Note" {|import Tesl.Json exposing [stringCodec]
record Metadata { text: String }
codec Metadata {
 toJson { text -> "text" with_codec stringCodec }
 fromJson [ { text <- "text" with_codec stringCodec } ]
}
entity Note|} in
 let before=schema old |> replace "author: String" "author: Metadata" in
 let after=schema fresh in
 let body=source
  |> replace "author: \"writer\"" "author: Schema.Notes.V1.Metadata { text: \"writer\" }"
  |> replace "-> String = row.title" "-> Schema.Notes.V1.Metadata = Schema.Notes.V1.Metadata { text: row.title }" in
 project ~before ~after(fun _ _ path ->
  accepts path body;
  refuses "MIG021" path (replace "-> Schema.Notes.V1.Metadata = Schema.Notes.V1.Metadata" "-> Schema.Notes.VCurrent.Metadata = Schema.Notes.VCurrent.Metadata" body);
  refuses "T001" path (replace "= Schema.Notes.V1.Metadata { text: row.title }" "= Schema.Notes.VCurrent.Metadata { text: row.title }" body))

let () = run "Legacy proof and closure boundaries" ["checked source",[
 test_case "nominal legacy result requires original owner and checked body" `Quick nominal_return;
 test_case "helper exact owner and explicit export" `Quick helper_ownership;
 test_case "transitive helper HTTP failure cannot escape" `Quick helper_purity;
 test_case "complete helper closure binds both identities and source guard" `Quick closure_identity;
 test_case "literal bytes bind both identities" `Quick literal_identity;
 test_case "unrelated surviving old field cross-proof refuses" `Quick cross_field]]
