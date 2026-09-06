open Alcotest
module I = Migration_inventory
module S = Migration_sparse
module R = Migration_transform_rules

let replace before after = Str.global_replace (Str.regexp_string before) after
let rec mkdir path = if not (Sys.file_exists path) then (mkdir (Filename.dirname path); Unix.mkdir path 0o700)
let rec remove path = if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then
  (Array.iter (fun n -> remove (Filename.concat path n)) (Sys.readdir path); Unix.rmdir path)
  else Sys.remove path
let schema ?(declarations="") ?(extra="") owner = {|module Schema.Notes.VCurrent exposing [Note, Payload, Valid]
import Tesl.Prelude exposing [String, Int, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
record Payload { text: String }
fact Valid (value: String)
|} ^ declarations ^ "\nentity Note table \"notes\" primaryKey id {\n  id: String\n  " ^ owner ^ "\n" ^ extra ^ "}\n"
let old = schema "author: String"
let fresh = schema "owner: String"
let with_pair ?(before=old) ?(after=fresh) ?(same=true) f =
  let root = Filename.temp_file "tesl-transform-rules-" ".dir" in
  Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let save path source =
      let path = Filename.concat root path in mkdir (Filename.dirname path);
      Out_channel.with_open_bin path (fun out -> output_string out source);
      let ds = (Compile.agent_context_result_source path source).diagnostics
        |> List.filter (fun (d:Compile.diagnostic) -> d.severity = "error") in
      if ds <> [] then fail (String.concat "\n" (List.map (fun (d:Compile.diagnostic) -> d.message) ds)); path in
    let old_path = save "schema/notes/v1.tesl" (replace "VCurrent" "V1" before) in
    let new_path = save "schema/notes/v-current.tesl" after in
    let load path = match I.load ~compiler_abi:"rule-test-abi" ~root_file:path with
      | Ok inventory -> inventory | Error error -> fail error.message in
    let before = load old_path and after = load new_path in
    let loc = Location.dummy_loc new_path in
    let identities = if not same then [] else
      match I.same_candidates ~before ~after with
      | Error error -> fail error.message
      | Ok candidates -> List.map (fun evidence ->
        let old, fresh = I.same_declarations evidence in
        {S.previous=(old.namespace,old.qualified_name);current=(fresh.namespace,fresh.qualified_name);loc}) candidates in
    let coverage = match S.check ~before ~after ~identities ~entries:[{S.entity="Note";kind=S.Transform;loc}] ~loc with
      | Ok value -> value | Error ds -> fail (String.concat "\n" (List.map (fun (d:S.error) -> d.message) ds)) in
    f coverage loc)
let rename loc = R.Rename {previous="author";current="owner";loc}
let entry ?(mode=R.Derived) loc rules = {R.entity="Note";mode;rules;loc}
let value_names result =
  R.entities result |> List.concat_map (fun (e:R.entity) -> List.map (function
    | R.Copy {current;_} -> "copy:" ^ current.name
    | R.Renamed {previous;current} -> "rename:" ^ previous.name ^ ":" ^ current.name
    | R.Empty_optional field -> "empty:" ^ field.name
    | R.Constant (field,_) -> "constant:" ^ field.name
    | R.Computed field -> "computed:" ^ field.name) e.values)
let succeeds coverage entries = match R.check coverage ~entries with
  | Ok result -> result
  | Error ds -> fail (String.concat "\n" (List.map (fun (d:S.error) -> d.code ^ ": " ^ d.message) ds))
let refuses code coverage entries = match R.check coverage ~entries with
  | Ok _ -> fail ("accepted invalid rule: " ^ code)
  | Error ds -> if not (List.exists (fun (d:S.error) -> d.code=code) ds) then
      fail (String.concat "\n" (List.map (fun (d:S.error) -> d.code ^ ": " ^ d.message) ds))
let derived () =
  with_pair (fun coverage loc -> check (list string) "exact identity mapping"
    ["copy:id";"rename:author:owner"] (value_names (succeeds coverage [entry loc [rename loc]])));
  with_pair ~before:(schema "author: Maybe String")
    ~after:(schema ~extra:"  later: Maybe Int\n" "owner: Maybe String")
    (fun coverage loc -> check (list string) "NULL is a legitimate source value"
      ["copy:id";"empty:later";"rename:author:owner"]
      (value_names (succeeds coverage [entry loc [rename loc]])))
let computed () =
  with_pair ~after:(schema ~extra:"  wordCount: Int\n  note: Maybe String\n" "owner: String")
    (fun coverage loc ->
      check (list string) "all unruled new fields belong to the user row function"
        ["copy:id";"computed:note";"rename:author:owner";"computed:wordCount"]
        (value_names (succeeds coverage [entry ~mode:R.Migrate loc [rename loc]]));
      refuses "MIG016" coverage [entry loc [rename loc]])
let defaults () = with_pair ~after:(schema ~extra:"  priority: Int\n" "owner: String") (fun coverage loc ->
  let rule value = R.Default {entity="Note";field="priority";value;loc} in
  check (list string) "identity plus typed default" ["copy:id";"rename:author:owner";"constant:priority"]
    (value_names (succeeds coverage [entry loc [rename loc;rule (Migration_additive.Integer "0")]]));
  refuses "MIG022" coverage [entry loc [rename loc;rule (Migration_additive.Boolean false)]];
  refuses "MIG023" coverage [entry loc [rename loc;rule (Migration_additive.Integer "0");rule (Migration_additive.Integer "1")]])
let endpoints () = with_pair (fun coverage loc ->
  refuses "MIG021" coverage [];
  refuses "MIG023" coverage [entry loc [rename loc];entry loc [rename loc]];
  refuses "MIG023" coverage [entry loc [rename loc;rename loc]];
  refuses "MIG022" coverage [{(entry loc [rename loc]) with entity="Elsewhere"}];
  List.iter (fun (previous,current) ->
    refuses "MIG022" coverage [entry loc [R.Rename {previous;current;loc}]])
    ["missing","owner";"author","missing";"author","author"];
  refuses "MIG009" coverage [entry loc [R.Rename {previous="id";current="owner";loc}]];
  refuses "MIG023" coverage [entry loc [rename loc;R.Default {entity="Note";field="owner";value=Migration_additive.Text "";loc}]];
  refuses "MIG023" coverage [entry loc [R.Default {entity="Note";field="owner";value=Migration_additive.Text "";loc};rename loc]])
let unsafe_storage () =
  List.iter (fun after -> with_pair ~after (fun coverage loc ->
    refuses "MIG009" coverage [entry loc [rename loc]]))
    [replace "table \"notes\"" "table \"other_notes\"" fresh;
     replace "id: String" "id: Int" fresh];
  with_pair ~after:(schema "owner: Int") (fun coverage loc ->
    refuses "MIG022" coverage [entry loc [rename loc]]);
  with_pair ~before:(schema ~extra:"  legacy: String\n" "author: String") (fun coverage loc ->
    refuses "MIG022" coverage [entry ~mode:R.Migrate loc [rename loc]]);
  with_pair ~after:(schema ~extra:"  added: Int\n" "author: String") (fun coverage loc ->
    refuses "MIG016" coverage [entry loc [R.Default {entity="Note";field="added";value=Migration_additive.Integer "0";loc}]])
let stored_dependencies () =
  let before = schema "author: Payload" and after = schema "owner: Payload" in
  with_pair ~before ~after (fun coverage loc -> ignore (succeeds coverage [entry loc [rename loc]]));
  with_pair ~before ~after ~same:false (fun coverage loc -> refuses "MIG024" coverage [entry loc [rename loc]]);
  with_pair ~before ~after:(replace "text: String" "text: Int" after)
    (fun coverage loc -> refuses "MIG022" coverage [entry loc [rename loc]]);
  let before = schema "author: String ::: Valid author" and after = schema "owner: String ::: Valid owner" in
  with_pair ~before ~after (fun coverage loc -> ignore (succeeds coverage [entry loc [rename loc]]));
  with_pair ~before ~after ~same:false (fun coverage loc -> refuses "MIG024" coverage [entry loc [rename loc]])

let sibling_subjects () =
  let before = schema ~extra:"  receipt: String ::: Valid author\n" "author: String" in
  let after = schema ~extra:"  receipt: String ::: Valid owner\n" "owner: String" in
  with_pair ~before ~after (fun coverage loc ->
    check (list string) "rename preserves a sibling proof's subject"
      ["copy:id";"rename:author:owner";"copy:receipt"]
      (value_names (succeeds coverage [entry loc [rename loc]])));
  with_pair ~before ~after:(replace "Valid owner" "Valid receipt" after)
    (fun coverage loc -> refuses "MIG022" coverage [entry loc [rename loc]])

let changed_semantics () =
  let declarations = {|fn threshold() -> Int = 0
establish validate(value: String) -> Maybe (v: String ::: Valid v) =
  if threshold() == 0 then
    Something (value ::: Valid value)
  else
    Nothing
|} in
  let before = schema ~declarations "author: String ::: Valid author" in
  let after = schema ~declarations "owner: String ::: Valid owner" in
  with_pair ~before ~after (fun coverage loc -> ignore (succeeds coverage [entry loc [rename loc]]));
  with_pair ~before ~after:(replace "fn threshold() -> Int = 0" "fn threshold() -> Int = 1" after)
    (fun coverage loc -> refuses "MIG022" coverage [entry loc [rename loc]]);
  let codec = {|codec Payload {
  toJson { text -> "text" with_codec stringCodec }
  fromJson [ { text <- "text" with_codec stringCodec } ]
}
|} in
  let json_schema field = schema ~declarations:codec field
    |> replace "import Tesl.Maybe" "import Tesl.Json exposing [stringCodec]\nimport Tesl.Maybe" in
  let before = json_schema "author: Payload" and after = json_schema "owner: Payload" in
  with_pair ~before ~after (fun coverage loc -> ignore (succeeds coverage [entry loc [rename loc]]));
  with_pair ~before ~after:(replace "text <- \"text\"" "text <- \"legacy\"" after)
    (fun coverage loc -> refuses "MIG022" coverage [entry loc [rename loc]])

let () = run "Transforming field rules" ["checked inventory mapping", List.map (fun (name,run) -> test_case name `Quick run)
  ["Derived rename and nullable data",derived;
   "computed fields require a row function",computed;
   "literal defaults remain exactly typed",defaults;
   "ownership, missing and conflicting rules",endpoints;
   "primary keys and discarded storage refuse",unsafe_storage;
   "JSONB and proof dependencies need verified identities",stored_dependencies;
   "renamed subjects preserve sibling proofs",sibling_subjects;
   "changed producer and codec closures refuse",changed_semantics]]
