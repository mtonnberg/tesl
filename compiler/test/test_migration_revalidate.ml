open Alcotest
module D = Migration_declaration
module T = Migration_transform
module R = Migration_transform_rules
let replace a b = Str.global_replace (Str.regexp_string a) b
let before = {|module Schema.Notes.V1 exposing [Note]
import Tesl.Prelude exposing [String]
entity Note table "notes" primaryKey id { id: String, title: String, other: String }
|}
let after = {|module Schema.Notes.VCurrent exposing [Note, NonEmpty, tryTitle]
import Tesl.Prelude exposing [String, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
fact NonEmpty (value: String)
establish tryTitle(value: String) -> Maybe (v: String ::: NonEmpty v) =
  if value != "" then
    Something (value ::: NonEmpty value)
  else
    Nothing
entity Note table "notes" primaryKey id {
  id: String
  title: String ::: NonEmpty title
  other: String
}
|}
let source = {|module Schema.Notes.Migrate.V2 exposing [migration, convert, oldNote]
import Tesl.Prelude exposing [String, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Migrated(..)]
import Schema.Notes.V1
import Schema.Notes.VCurrent
migration = Migration {
  from: Schema.Notes.V1
  to: Schema.Notes.VCurrent
  same: []
  fixtures: [oldNote]
  entities: { Note: Migrate convert [Revalidate title Schema.Notes.VCurrent.tryTitle] }
}
fn convert(old: Schema.Notes.V1.Note) -> Migrated Schema.Notes.VCurrent.Note =
  case Schema.Notes.VCurrent.tryTitle old.title of
    Nothing -> Reject "empty title"
    Something validated -> Row (Schema.Notes.VCurrent.Note { id: old.id, title: validated, other: old.other })
fn oldNote() -> Schema.Notes.V1.Note =
  Schema.Notes.V1.Note { id: "retained", title: "hello", other: "other" }
|}
let native_tests = {|test "revalidate preserves nonempty Unicode exactly" {
  let old = Schema.Notes.V1.Note { id: "one", title: "å🙂", other: "different" }
  case convert old of
    Row row -> expect row.title == "å🙂"
    Reject reason -> expect False
}
test "revalidate rejects empty retained value" {
  let old = Schema.Notes.V1.Note { id: "two", title: "", other: "valid other" }
  case convert old of
    Row row -> expect False
    Reject reason -> expect reason == "empty title"
}
|}
let rec mkdir p = if not (Sys.file_exists p) then (mkdir (Filename.dirname p); Unix.mkdir p 0o700)
let write p s = mkdir (Filename.dirname p); Out_channel.with_open_bin p (fun o -> output_string o s)
let rec remove p = if (Unix.lstat p).Unix.st_kind=Unix.S_DIR then
  (Array.iter (fun n -> remove (Filename.concat p n)) (Sys.readdir p); Unix.rmdir p)
  else Sys.remove p
let project ?(previous=before) ?(current=after) f =
  let root=Filename.temp_file "tesl-revalidate-" ".dir" in Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let save p s = let file=Filename.concat root p in write file s; file in
    ignore (save "tesl.toml" "");
    ignore (save "schema/notes/v1.tesl" previous);
    ignore (save "schema/notes/v-current.tesl" current);
    let path=save "migrations/notes/v2.tesl" source in f root save path)
let describe ds = String.concat "\n" (List.map (fun (d:Compile.diagnostic) -> d.code ^ ": " ^ d.message) ds)
let errors path s = (Compile.agent_context_result_source path s).diagnostics
  |> List.filter (fun (d:Compile.diagnostic) -> d.severity="error")
let accepts path s = match errors path s with [] -> () | ds -> fail (describe ds)
let refuses ?code path s = let ds=errors path s in
  match code with
  | None -> if ds=[] then fail "invalid revalidation accepted"
  | Some code -> if not (List.exists (fun (d:Compile.diagnostic) -> d.code=code) ds) then
      fail ("missing " ^ code ^ ":\n" ^ describe ds)
let checked_mapping () = project (fun _ _ path ->
  accepts path source;
  let parsed=match Parser.parse_module path source with Ok m -> m | Err e -> fail e.msg in
  let d=match D.check ~compiler_abi:"revalidate-test" ~source parsed with
    | Ok (Some d) -> d
    | Error es -> fail (String.concat "\n" (List.map (fun (e:Migration_sparse.error) -> e.message) es))
    | _ -> fail "missing declaration" in
  let row=List.hd (T.rows (Option.get (D.transforms d))) in
  check int "one revalidated field" 1 (List.length (List.filter (function R.Revalidated _ -> true | _ -> false) row.mapping.values));
  let formatted=Formatter.format_source source in
  accepts path formatted;
  check string "format idempotent" formatted (Formatter.format_source formatted))
let wrong_projection () = project (fun _ _ path ->
  List.iter (fun value -> refuses ~code:"MIG018" path (replace "tryTitle old.title of" ("tryTitle " ^ value ^ " of") source))
    ["old.other";"\"fixed\"";"(old.title ++ \"\")"])
let wrong_result () = project (fun _ _ path ->
  List.iter (fun value -> refuses ~code:"MIG018" path (replace "title: validated" ("title: " ^ value) source))
    ["old.title";"old.other";"(validated ++ \"\")"])
let shadowed_binder () = project (fun _ _ path ->
  refuses ~code:"MIG018" path (replace "Something validated -> Row" "Something validated ->\n      let validated = old.other\n      Row" source);
  refuses ~code:"MIG018" path (replace "Something validated -> Row" "Something validated ->\n      let old = oldNote()\n      Row" source))
let nested_case_shadow () = project (fun _ _ path ->
  refuses ~code:"MIG018" path (replace "Something validated -> Row"
    "Something validated ->\n      case validated of\n        validated -> Row" source))
let establish_case_shadow () =
  let current=replace "    Something (value ::: NonEmpty value)"
    "    case value of\n      value -> Something (value ::: NonEmpty value)" after in
  (* Schema validation rejects establish argument shadowing before the
     migration-specific origin checker sees the declaration. *)
  project ~current (fun _ _ path -> refuses ~code:"MIG020" path source)
let establish_qualification () = project (fun _ _ path ->
  (* The normal fixture uses the complete module prefix in the rule and call.
     Exposing the exact same owned establish must preserve that resolution. *)
  accepts path source;
  let exposed=source
    |> replace "import Schema.Notes.VCurrent\n" "import Schema.Notes.VCurrent exposing [tryTitle]\n"
    |> replace "Schema.Notes.VCurrent.tryTitle" "tryTitle" in
  accepts path exposed)
let row_wrapper () = project (fun _ _ path ->
  let start=Str.search_forward (Str.regexp_string "  case Schema.Notes.VCurrent.tryTitle") source 0 in
  let finish=Str.search_forward (Str.regexp_string "fn oldNote()") source start in
  let body=String.sub source start (finish-start) in
  let wrapped=replace body "  wrapped old\n" source ^
    "\nfn wrapped(old: Schema.Notes.V1.Note) -> Migrated Schema.Notes.VCurrent.Note =\n" ^ body in
  refuses ~code:"MIG018" path wrapped)
let conflicts () = project (fun _ _ path ->
  let rule="Revalidate title Schema.Notes.VCurrent.tryTitle" in
  List.iter (fun other -> List.iter (fun rules ->
    refuses ~code:"MIG023" path (replace ("[" ^ rule ^ "]") ("[" ^ rules ^ "]") source))
    [rule ^ ", " ^ other;other ^ ", " ^ rule])
    ["Retype title";"Rename title other";"Default title \"default\"";
     "WriteBack title title Schema.Notes.VCurrent.tryTitle"];
  refuses ~code:"MIG023" path (replace ("[" ^ rule ^ "]") ("[" ^ rule ^ ", " ^ rule ^ "]") source))
let no_proof () =
  let current=after |> replace "title: String ::: NonEmpty title" "title: String"
    |> replace "  other: String" "  other: String\n  added: String" in
  project ~current (fun _ _ path ->
    refuses ~code:"MIG022" path (replace "other: old.other" "other: old.other, added: old.other" source))
let prior_proof () =
  let previous=replace "Schema.Notes.VCurrent" "Schema.Notes.V1" after in
  project ~previous (fun _ _ path -> refuses ~code:"MIG022" path source)
let changed_carrier () =
  let previous=replace "exposing [String]" "exposing [String, Int]" before
    |> replace "title: String" "title: Int" in
  project ~previous (fun _ _ path -> refuses ~code:"MIG022" path source)
let changed_storage () = project ~current:(replace "title: String ::: NonEmpty title" "title: String ::: NonEmpty title @column(\"title__v2\")" after)
  (fun _ _ path -> refuses ~code:"MIG022" path source)
let value_changing_establish () =
  let current=replace "Something (value ::: NonEmpty value)"
    "let changed = value ++ \"!\"\n    Something (changed ::: NonEmpty changed)" after in
  project ~current (fun _ _ path -> refuses ~code:"MIG018" path source)
let wrong_fact () =
  let current=after |> replace "NonEmpty, tryTitle" "NonEmpty, Other, tryTitle"
    |> replace "fact NonEmpty (value: String)" "fact NonEmpty (value: String)\nfact Other (value: String)"
    |> replace "v: String ::: NonEmpty v" "v: String ::: Other v"
    |> replace "value ::: NonEmpty value" "value ::: Other value" in
  project ~current (fun _ _ path -> refuses ~code:"MIG022" path source)
let wrong_owner () = project (fun _ save path ->
  let endpoint=Str.search_forward (Str.regexp_string "entity Note") after 0 in
  let helper=String.sub after 0 endpoint
    |> replace "module Schema.Notes.VCurrent" "module Schema.Notes.Migrate.Helper"
    |> replace "exposing [Note, NonEmpty, tryTitle]" "exposing [NonEmpty, tryTitle]" in
  ignore (save "migrations/notes/helper.tesl" helper);
  let s=source |> replace "import Schema.Notes.V1" "import Schema.Notes.Migrate.Helper\nimport Schema.Notes.V1"
    |> replace "Schema.Notes.VCurrent.tryTitle" "Schema.Notes.Migrate.Helper.tryTitle" in
  refuses ~code:"MIG022" path s)
let requires_migrate () = project (fun _ _ path ->
  refuses ~code:"MIG022" path (replace "Migrate convert" "Derived" source))
let native () = project (fun root save path ->
  if Sys.command "go version >/dev/null 2>&1"<>0 then skip ();
  ignore (save "migrations/notes/v2.tesl" (source ^ native_tests));
  let artifacts=match Compile.compile_go_file path with
    | Compile.GoSuccess a -> a | Compile.GoFailure ds -> fail (describe ds) in
  List.iter (fun (a:Emit_go.artifact) -> ignore (save ("out/" ^ a.path) a.contents)) artifacts;
  List.iter (fun name -> remove (Filename.concat root name)) ["schema";"migrations";"tesl.toml"];
  let command=Printf.sprintf "cd %s && GOMAXPROCS=2 go test -race -p 1 -count=1 -timeout=60s -v ./... 2>&1" (Filename.quote (Filename.concat root "out")) in
  let channel=Unix.open_process_in command in let output=In_channel.input_all channel in
  match Unix.close_process_in channel with
  | Unix.WEXITED 0 ->
    check bool "accept test executed" true (Compile.string_contains output "--- PASS: TestTesl0");
    check bool "reject test executed" true (Compile.string_contains output "--- PASS: TestTesl1");
    check bool "native tests passed" true (Compile.string_contains output "--- PASS:")
  | _ -> fail output)
let () = run "Revalidate" ["checked source and execution", List.map (fun (name,f) -> test_case name `Quick f)
  ["checked mapping and formatting",checked_mapping;"wrong projection",wrong_projection;
   "wrong result",wrong_result;"shadowed binder",shadowed_binder;
   "nested case shadows proof binder",nested_case_shadow;"establish case shadows input",establish_case_shadow;
   "qualified and exposed establish",establish_qualification;"row wrapper refused",row_wrapper;
   "conflicts both orders",conflicts;
   "requires new proof",no_proof;"previous proof refused",prior_proof;"changed carrier refused",changed_carrier;
   "changed storage refused",changed_storage;"value-changing establish refused",value_changing_establish;
   "wrong fact refused",wrong_fact;"wrong owner refused",wrong_owner;"requires Migrate",requires_migrate;
   "native accept and reject",native]]
