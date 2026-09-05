open Alcotest
open Migration_inventory
module S = Migration_sparse

let rec mkdir path =
  if not (Sys.file_exists path) then (mkdir (Filename.dirname path); Unix.mkdir path 0o700)
let rec remove path =
  if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  end else Sys.remove path
let with_project f =
  let root = Filename.temp_file "tesl-migration-sparse-" ".dir" in
  Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let write relative source =
      let path = Filename.concat root relative in mkdir (Filename.dirname path);
      Out_channel.with_open_bin path (fun channel -> output_string channel source); path in
    ignore (write "tesl.toml" ""); f root write)
let get = function Ok value -> value | Error (error : Migration_ir.error) -> fail error.message
let load ?(abi="test-compiler-1") path = get (load ~compiler_abi:abi ~root_file:path)
let replace before after = Str.global_replace (Str.regexp_string before) after
let loc = Location.make_loc "migration.tesl" 10 2 10 20
let entry ?(at=loc) kind entity : S.entry = {entity;kind;loc=at}
let checked = function Ok value -> value | Error errors ->
  fail (String.concat "\n" (List.map (fun (e : S.error) -> e.code ^ ": " ^ e.message) errors))
let refused code = function
  | Ok _ -> fail ("accepted missing " ^ code ^ " boundary")
  | Error errors ->
    check bool ("reported " ^ code) true (List.exists (fun (e : S.error) -> e.code = code) errors); errors
let run ?(entries=[]) ?(identities=[]) before after = S.check ~before ~after ~entries ~identities ~loc
let all_same before after = get (same_candidates ~before ~after) |> List.map (fun evidence ->
  let old, fresh = same_declarations evidence in
  ({previous=(old.namespace,old.qualified_name);current=(fresh.namespace,fresh.qualified_name);loc} : S.identity))
let omit ns name identities = List.filter (fun (i : S.identity) ->
  fst i.previous <> ns || not (String.ends_with ~suffix:("." ^ name) (snd i.previous))) identities
let gaps result = S.entities result |> List.concat_map (function
  | S.Paired pair -> pair.missing_identities | _ -> [])
let describe gap = gap.S.current_field.entity ^ "." ^ gap.current_field.name
let prefix = "module NotesSchema.VCurrent exposing []\n"
let imports = {|import Tesl.Prelude exposing [Int, String]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.String exposing [String.length]
import Tesl.Json exposing [stringCodec]
|}
let shared = {|fact ValidText (text: String)
check validText(text: String) -> text: String ::: ValidText text =
  if String.length text > 0 then
    ok text ::: ValidText text
  else
    fail 422 "empty text"
record Details { text: String ::: ValidText text }
codec Details {
  toJson { text -> "body" with_codec stringCodec }
  fromJson [
    { text <- "body" with_codec stringCodec via validText }
    { text <- "title" with_codec stringCodec via validText }
  ]
}
type Change
  = Unchanged
  | Changed details: Details
type Wrapped = Details
record Unstored { text: String }
codec Unstored {
  toJson { text -> "response" with_codec stringCodec }
  fromJson [ { text <- "response" with_codec stringCodec } ]
}
|}
let tables = {|entity Note table "notes" primaryKey id {
  id: String
  details: Details @db(jsonb)
  backup: Maybe Details
  change: Change
  wrapped: Wrapped
  unrelated: Int
}
entity Archive table "archives" primaryKey id { id: String, value: Change }
entity Session table "sessions" primaryKey id { id: String, token: String }
|}
let source = prefix ^ imports ^ shared ^ tables
let fixture root write source =
  let path = write "schema/notes/v-current.tesl" source in
  let after = load path in
  let copies = match Migration_source.freeze_closure ~project_root:root ~family:"NotesSchema" ~version:1 with
    | Ok copies -> copies | Error message -> fail message in
  List.iter (fun (copy : Migration_source.frozen_copy) ->
    mkdir (Filename.dirname copy.target_path);
    Out_channel.with_open_bin copy.target_path (fun channel -> output_string channel copy.contents)) copies;
  load (Filename.concat root "schema/notes/v1.tesl"), after, path
let expected_occurrences = ["Archive.value";"Note.backup";"Note.change";"Note.details";"Note.wrapped"]
  |> List.map (fun name -> "NotesSchema.VCurrent." ^ name)
let transforms = List.map (entry S.Transform) ["Archive";"Note"]

let complete_coverage () = with_project (fun root write ->
  let before, after, _ = fixture root write source in
  let identities = all_same before after in
  let result = checked (run ~identities before after) in
  check int "all three unchanged entities folded" 3 (S.unchanged_count result);
  check int "all supplied identities preserved" (List.length identities) (List.length (S.identities result));
  check int "no implicit gaps" 0 (List.length (gaps result));
  let identities = identities |> omit Migration_ir.Type "Unstored" |> omit Migration_ir.Codec "Unstored" in
  check int "unused records/codecs impose no stored obligations" 3
    (S.unchanged_count (checked (run ~identities before after)));
  check (option (list string)) "a primitive field has an empty dependency inventory"
    (Some []) (Option.map (List.map (fun d -> d.qualified_name))
      (stored_dependencies after ~entity:"NotesSchema.VCurrent.Session" ~field:"id"));
  check bool "unknown field is distinguished from primitive-only" true
    (stored_dependencies after ~entity:"NotesSchema.VCurrent.Session" ~field:"absent" = None);
  check bool "wrong revision owns no current field" true
    (stored_dependencies after ~entity:"NotesSchema.V1.Session" ~field:"id" = None))

let omitted_nested_fact () = with_project (fun root write ->
  let before, after, _ = fixture root write source in
  let identities = omit Migration_ir.Predicate "ValidText" (all_same before after) in
  let errors = refused "MIG016" (run ~identities before after) in
  check int "both containing entities need entries" 2 (List.length errors);
  List.iter (fun (e : S.error) -> check bool "missing entry anchors migration" true (e.loc = loc)) errors;
  ignore (refused "MIG016" (run ~identities ~entries:[entry S.Additive "Note";entry S.Additive "Archive"] before after));
  let result = checked (run ~identities ~entries:transforms before after) in
  check (list string) "each nested nullable, ADT, newtype and direct occurrence remains"
    expected_occurrences (List.map describe (gaps result));
  List.iter (fun (g : S.missing_identity) ->
    check string "precise old fact" "NotesSchema.V1.ValidText" g.previous_declaration.qualified_name;
    check string "precise new fact" "NotesSchema.VCurrent.ValidText" g.current_declaration.qualified_name;
    check string "old source location" (Filename.concat root "schema/notes/v1.tesl") g.previous_field.loc.file;
    check string "new source location" (Filename.concat root "schema/notes/v-current.tesl") g.current_field.loc.file) (gaps result);
  check int "unrelated Session stays folded" 1 (S.unchanged_count result))

let namespace_omissions () = with_project (fun root write ->
  let before, after, _ = fixture root write source in
  List.iter (fun ns ->
    let identities = omit ns "Details" (all_same before after) in
    let result = checked (run ~identities ~entries:transforms before after) in
    check (list string) "the enclosing declaration does not imply another namespace's identity"
      expected_occurrences (List.map describe (gaps result));
    List.iter (fun g -> check bool "exact omitted namespace" true
      (g.S.previous_declaration.namespace = ns)) (gaps result)) [Migration_ir.Type;Migration_ir.Codec])

let every_identity_occurrence () = with_project (fun root write ->
  let before, after, _ = fixture root write source in
  List.iter (fun (ns,name,occurrences,affected) ->
    let identities = omit ns name (all_same before after) in
    let result = checked (run ~identities ~entries:(List.map (entry S.Transform) affected) before after) in
    check (list string) ("independent occurrence oracle for " ^ name)
      (List.map (fun s -> "NotesSchema.VCurrent." ^ s) occurrences)
      (List.map describe (gaps result))) [
      Migration_ir.Type,"Change",["Archive.value";"Note.change"],["Archive";"Note"];
      Migration_ir.Type,"Wrapped",["Note.wrapped"],["Note"];
      Migration_ir.Type,"Unstored",[],[];
      Migration_ir.Codec,"Unstored",[],[]])

let invalid_same_claims () = with_project (fun root write ->
  let before, after, path = fixture root write source in
  let claims = all_same before after in
  let valid = List.hd claims in
  let bad previous current = ({previous;current;loc} : S.identity) in
  List.iter (fun claim ->
    let errors = refused "MIG024" (run ~identities:[claim] before after) in
    check int "invalid evidence yields no missing-entry cascades" 1 (List.length errors)) [
    bad (Migration_ir.Type,"Int") (Migration_ir.Type,"Int");
    bad (Migration_ir.Value,"NotesSchema.V1.validText") (Migration_ir.Value,"NotesSchema.VCurrent.validText");
    bad valid.current valid.previous;
    bad (Migration_ir.Type,"NotesSchema.V1.Details") (Migration_ir.Codec,"NotesSchema.VCurrent.Details");
    bad (Migration_ir.Type,"NotesSchema.V8.Details") (Migration_ir.Type,"NotesSchema.VCurrent.Details")];
  ignore (refused "MIG024" (run ~identities:(valid :: claims) before after));
  ignore (write "schema/notes/v-current.tesl" (replace "> 0" "> 1" source));
  let changed = load path in
  let errors = refused "MIG024" (run ~identities:claims before changed) in
  check bool "stale candidate lists are freshly checked" true (List.length errors > 0);
  check bool "related locations identify changed producer" true
    (List.exists (fun (e : S.error) -> List.exists (fun (_, message) ->
      String.ends_with ~suffix:"validText" message) e.related) errors);
  let result = checked (run ~identities:(all_same before changed) ~entries:transforms before changed) in
  check int "actual changed closure leaves Session alone" 1 (S.unchanged_count result))

let table_and_index_coverage () = with_project (fun root write ->
  let before, after, path = fixture root write source in
  List.iter (fun edited ->
    ignore (write "schema/notes/v-current.tesl" edited);
    let fresh = load path in
    let identities = all_same before fresh in
    let errors = refused "MIG002" (run ~identities before fresh) in
    check int "one changed entity despite equal fields" 1 (List.length errors);
    check int "both schema locations retained" 2 (List.length (List.hd errors).S.related);
    let result = checked (run ~identities ~entries:[entry S.Transform "Session"] before fresh) in
    check int "other two stay folded" 2 (S.unchanged_count result)) [
      replace "table \"sessions\"" "table \"new_sessions\"" source;
      replace "entity Session table \"sessions\" primaryKey id { id: String, token: String }"
        "entity Session table \"sessions\" primaryKey id { id: String, token: String\n index [token]\n}" source];
  List.iter (fun kind -> ignore (refused "MIG002" (run ~identities:(all_same before after)
    ~entries:[entry kind "Session"] before after))) [S.Additive;S.Transform;S.Reset;S.New;S.Drop])

let add_drop_and_kind () = with_project (fun root write ->
  let before, _, path = fixture root write source in
  let edited = replace "entity Session table \"sessions\" primaryKey id { id: String, token: String }"
      "entity Tag table \"tags\" primaryKey id { id: String }" source in
  ignore (write "schema/notes/v-current.tesl" edited);
  let after = load path in let identities = all_same before after in
  check int "addition and removal both need coverage" 2
    (List.length (refused "MIG002" (run ~identities before after)));
  let result = checked (run ~identities ~entries:[entry S.Drop "Session";entry S.New "Tag"] before after) in
  check int "two surviving entities folded" 2 (S.unchanged_count result);
  List.iter (fun kind ->
    if kind <> S.New then ignore (refused "MIG002" (run ~identities
      ~entries:[entry S.Drop "Session";entry kind "Tag"] before after));
    if kind <> S.Drop then ignore (refused "MIG002" (run ~identities
      ~entries:[entry kind "Session";entry S.New "Tag"] before after)))
    [S.Additive;S.Transform;S.Reset;S.New;S.Drop])

let unknown_and_duplicate_entries () = with_project (fun root write ->
  let before, after, path = fixture root write source in
  let identities = all_same before after in
  List.iter (fun name -> ignore (refused "MIG002" (run ~identities ~entries:[entry S.Transform name] before after)))
    ["Missing";"Details";"OtherSchema.VCurrent.Note";"NotesSchema.V9.Note"];
  ignore (write "schema/notes/v-current.tesl" (replace "table \"notes\"" "table \"new_notes\"" source));
  let after = load path in
  List.iter (fun pair -> ignore (refused "MIG002" (run ~identities
    ~entries:(List.map (entry S.Transform) pair) before after))) [
      ["Note";"Note"];["Note";"NotesSchema.VCurrent.Note"];
      ["NotesSchema.V1.Note";"NotesSchema.VCurrent.Note"]];
  List.iter (fun name -> ignore (checked (run ~identities ~entries:[entry S.Transform name] before after)))
    ["Note";"NotesSchema.V1.Note";"NotesSchema.VCurrent.Note"])

let private_collisions () = with_project (fun root write ->
  let child side table = Printf.sprintf
    "module NotesSchema.VCurrent.%s exposing []\nimport Tesl.Prelude exposing [String]\nentity Hidden table \"%s\" primaryKey id { id: String }\n" side table in
  ignore (write "schema/notes/v-current/a.tesl" (child "A" "a"));
  ignore (write "schema/notes/v-current/b.tesl" (child "B" "b"));
  let before, _, path = fixture root write
    (prefix ^ "import NotesSchema.VCurrent.A\nimport NotesSchema.VCurrent.B\n") in
  ignore (write "schema/notes/v-current/a.tesl" (child "A" "a_new"));
  ignore (write "schema/notes/v-current/b.tesl" (child "B" "b_new"));
  let after = load path in
  let errors = refused "MIG002" (run ~entries:[entry S.Transform "Hidden"] before after) in
  check bool "ambiguity reports both owning paths" true (List.exists (fun (e : S.error) ->
    String.starts_with ~prefix:"ambiguous entity" e.message && List.length e.related = 4) errors);
  check int "relative private module paths select exactly two owners" 2
    (List.length (S.entities (checked (run ~entries:[entry S.Transform "A.Hidden";entry S.Transform "B.Hidden"] before after))));
  ignore (refused "MIG002" (run ~entries:[entry S.Transform "A.Hidden";
    entry S.Transform "NotesSchema.V1.A.Hidden";entry S.Transform "B.Hidden"] before after)))

let boundaries () = with_project (fun _ write ->
  let path = write "schema/notes/v-current.tesl" prefix in
  let before = load ~abi:"A" path and after = load ~abi:"B" path in
  ignore (refused "MIG020" (run before after));
  let other = write "schema/other/v-current.tesl" "module OtherSchema.VCurrent exposing []\n" in
  ignore (refused "MIG020" (run before (load ~abi:"A" other)));
  check int "empty equal inventories are still valid coverage" 0
    (S.unchanged_count (checked (run before before))))

let recursive_and_generic () = with_project (fun root write ->
  let extended = source ^ {|type Recursive
  = Leaf details: Details
  | Link child: Recursive
type Box a
  = Boxed value: a
entity Tree table "trees" primaryKey id { id: String, root: Recursive, box: Box Details }
|} in
  let before, after, _ = fixture root write extended in
  let identities = omit Migration_ir.Predicate "ValidText" (all_same before after) in
  let result = checked (run ~identities ~entries:(entry S.Transform "Tree" :: transforms) before after) in
  check int "recursive closure terminates and generic arguments keep their fact" 7 (List.length (gaps result));
  check (list string) "new occurrences retain exact field names"
    ["NotesSchema.VCurrent.Tree.box";"NotesSchema.VCurrent.Tree.root"]
    (gaps result |> List.map describe |> List.filter (String.starts_with ~prefix:"NotesSchema.VCurrent.Tree.")))

let direct_field_fact () = with_project (fun root write ->
  let source = source ^ "entity Direct table \"direct\" primaryKey id { id: String, text: String ::: ValidText text }\n" in
  let before, after, _ = fixture root write source in
  let identities = omit Migration_ir.Predicate "ValidText" (all_same before after) in
  let result = checked (run ~identities ~entries:(entry S.Transform "Direct" :: transforms) before after) in
  check int "direct and nested obligations coexist" 6 (List.length (gaps result));
  check bool "direct field location survives" true
    (List.mem "NotesSchema.VCurrent.Direct.text" (List.map describe (gaps result))))

let many_occurrences () = with_project (fun root write ->
  let tables = List.init 300 (fun i -> Printf.sprintf
    "entity E%d table \"table_%d\" primaryKey id { id: String, payload: Maybe Details }\n" i i)
    |> String.concat "" in
  let before, after, _ = fixture root write (prefix ^ imports ^ shared ^ tables) in
  let claims = all_same before after in
  check int "all 300 unchanged tables fold" 300 (S.unchanged_count (checked (run ~identities:claims before after)));
  let identities = omit Migration_ir.Predicate "ValidText" claims in
  check int "one missing shared fact affects every table" 300
    (List.length (refused "MIG016" (run ~identities before after)));
  check int "one covered occurrence cannot discharge the other 299" 299
    (List.length (refused "MIG016" (run ~identities ~entries:[entry S.Transform "E0"] before after)));
  let entries = List.init 300 (fun i -> entry S.Transform ("E" ^ string_of_int i)) in
  let result = checked (run ~identities ~entries before after) in
  check int "exactly one gap retained for each stored occurrence" 300 (List.length (gaps result));
  check int "no missing table is folded" 0 (S.unchanged_count result);
  let reordered = checked (run ~identities:(List.rev identities) ~entries:(List.rev entries) before after) in
  check (list string) "verified evidence order is deterministic"
    (List.map same_digest (S.identities result)) (List.map same_digest (S.identities reordered));
  check (list string) "report order is independent of user list order"
    (List.map describe (gaps result)) (List.map describe (gaps reordered)))

let diagnostic_registry () =
  let index = Error_codes.index () in
  List.iter (fun code -> match Error_codes.lookup code with
    | None -> fail ("unregistered migration diagnostic " ^ code)
    | Some entry ->
      check bool "migration category" true (entry.category = Error_codes.Migration);
      check bool "listed in public code index" true
        (try ignore (Str.search_forward (Str.regexp_string code) index 0); true with Not_found -> false))
    ["MIG002";"MIG015";"MIG016";"MIG020";"MIG022";"MIG023";"MIG024"]

let () = Alcotest.run "migration-sparse" ["coverage and identity", [
  test_case "complete and unused identity coverage" `Quick complete_coverage;
  test_case "omitted nested fact cannot hide behind an enclosing Same" `Quick omitted_nested_fact;
  test_case "record and codec identities are distinct" `Quick namespace_omissions;
  test_case "per-declaration occurrence oracle" `Quick every_identity_occurrence;
  test_case "invalid duplicate and stale Same claims" `Quick invalid_same_claims;
  test_case "table/index changes and redundant entries" `Quick table_and_index_coverage;
  test_case "New/Drop coverage and wrong kinds" `Quick add_drop_and_kind;
  test_case "unknown and duplicate entity aliases" `Quick unknown_and_duplicate_entries;
  test_case "private same-named entity disambiguation" `Quick private_collisions;
  test_case "family ABI and empty schema boundaries" `Quick boundaries;
  test_case "recursive and generic stored proof closure" `Quick recursive_and_generic;
  test_case "direct and nested field facts coexist" `Quick direct_field_fact;
  test_case "300 independent stored occurrences and deterministic order" `Quick many_occurrences;
  test_case "migration diagnostics appear in the public registry" `Quick diagnostic_registry;
]]
