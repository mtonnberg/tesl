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
entity Note table "notes" primaryKey id { id: String, owner: String, title: String, count: Int }
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
  entities: { Note: Migrate convert [Rename author owner] }
}
fn convert(old: Schema.Notes.V1.Note) -> Migrated Schema.Notes.VCurrent.Note =
  Row (Schema.Notes.VCurrent.Note { id: old.id, owner: old.author, title: old.title, count: 7 })
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
let basic () = project (fun _ _ path ->
  let original=transform path source in
  let result=match L.link original with Ok result -> result | Error error -> fail error.message in
  check bool "original checked descriptor retained" true (L.checked_transform result == original);
  let before=List.hd (T.rows original) and after=List.hd (T.rows (L.checked_transform result)) in
  check bool "callback AST bound to semantic link" true
    ((Option.get before.function_binding).declaration == (Option.get after.function_binding).declaration);
  check string "bound callback target" "Schema.Notes.VCurrent.Note" after.mapping.current.entity_name;
  check int "complete sources retained outside semantics" 3 (List.length (L.source_inputs result));
  let encoded = Migration_canonical.encode (L.semantic result) in
  check bool "source paths absent" false (contains encoded (Filename.dirname path));
  check bool "From scope" true (contains encoded "s4:from");
  check bool "To scope" true (contains encoded "s2:to");
  check bool "Snapshot scope not relabelled" false (contains encoded "s8:snapshot");
  check bool "compiler ABI bound" true (contains encoded (L.compiler_abi result));
  let behavior = Migration_canonical.encode (L.behavior result) in
  check bool "behavior separates build provenance" false (contains behavior (L.compiler_abi result));
  check bool "behavior binds stored-value contract" true (contains behavior "stored-value-compatibility");
  check bool "behavior retains checked callback" true (contains behavior "migrate");
  check bool "behavior retains fixture closure" true (contains behavior "retained");
  check bool "mapping retained" true (contains encoded "rename");
  check bool "fixture closure retained" true (contains encoded "retained");
  check bool "runtime authority not exposed" false (contains encoded "generation");
  match L.revalidate result with Ok () -> () | Error error -> fail error.message)
let stable digest () =
  let hash path source = digest (linked path source) in
  let first=project (fun _ _ path -> hash path source) in
  project (fun _ _ path ->
    check string "relocation and comments" first (hash path ("# relocated\n" ^ source));
    check string "formatting" first (hash path (Formatter.format_source source));
    check string "local alpha renaming" first (hash path (source |> replace "old:" "input:" |> replace "old." "input."));
    check string "ordinary tests checked but not executable closure" first
      (hash path (replace "actual pure transformation helper" "a renamed test" source)))
let mutation digest () =
  let hash path source = digest (linked path source) in project (fun _ _ path ->
  let first=hash path source in
  List.iter (fun (name,s) -> check bool name false (first=hash path s))
    ["computed value", replace "count: 7" "count: 8" source;
     "fixture bytes", replace "title: \"hello\"" "title: \"other\"" source])
let helper digest () =
  let hash path source = digest (linked path source) in project (fun _ _ path ->
  let with_helper = replace "count: 7" "count: amount old.title" source ^
    "fn amount(title: String) -> Int =\n  if title == \"\" then\n    0\n  else\n    7\n" in
  let first=hash path with_helper in
  check bool "private reachable body retained" false (first=hash path (replace "else\n    7" "else\n    8" with_helper));
  check string "unreferenced checked function not in closure" first
    (hash path (with_helper ^ "fn unused() -> Int = 999\n")))
let ordinary_constant () = project (fun _ _ path ->
  let t=transform path (source ^ "unrelated = 12\n") in
  match L.link t with
  | Ok _ -> fail "ordinary constant silently omitted"
  | Error error -> check bool "explicit unsupported IR refusal" true (contains error.message "application declaration"))
let changed_inputs () = project (fun _ save path ->
  let result=linked path source in
  ignore (save "schema/notes/v1.tesl" (old ^ "# changed after checking\n"));
  match L.revalidate result with Ok () -> fail "source mutation retained authority" | Error _ -> ())
let changed_before_link () = project (fun _ _ path ->
  let t=transform path source in
  write path (source ^ "# changed before link\n");
  match L.link t with Ok _ -> fail "stale descriptor linked" | Error _ -> ())
let graph_binding () = project (fun _ _ path ->
  let t=transform path source in
  let owner=T.root t in
  let captured=T.captured_sources t in
  let graph=match Migration_checked_graph.check ~context:(T.proof_context t) captured with
    | Ok graph -> graph | Error error -> fail error.message in
  let declaration=List.find_map (function Ast.DConst c when Migration_form.is_declaration owner c -> Some c | _ -> None) owner.decls |> Option.get in
  let clone={owner with decls=owner.decls} in
  match Migration_checked_graph.lower_transform ~scopes:[] ~contextual:(clone,declaration) graph with
  | Ok _ -> fail "replacement owner qualified for contextual omission"
  | Error error -> check bool "original AST required" true (contains error.message "original checked graph node"))
let abi_mismatch () = project (fun _ _ path ->
  let m=match Parser.parse_module path source with Ok m -> m | Err e -> fail e.msg in
  let d=match D.check ~compiler_abi:"wrong-source-abi" ~source m with Ok (Some d) -> d | _ -> fail "test descriptor refused" in
  match L.link (Option.get (D.transforms d)) with
  | Ok _ -> fail "different inventory ABI linked"
  | Error error -> check bool "ABI refusal" true (contains error.message "different compiler ABI"))
let without_test = String.split_on_char '\n' source |> fun lines ->
  let rec take = function [] -> [] | line::_ when String.starts_with ~prefix:"test " line -> [] | line::tail -> line::take tail in
  String.concat "\n" (take lines) ^ "\n"
let proof_schema = {|module Schema.Notes.VCurrent exposing [Note, NonEmpty, tryTitle]
import Tesl.Prelude exposing [String, Int, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
fact NonEmpty (value: String)
establish tryTitle(value: String) -> Maybe (v: String ::: NonEmpty v) =
  if value != "" then
    Something (value ::: NonEmpty value)
  else
    Nothing
entity Note table "notes" primaryKey id {
  id: String
  owner: String
  title: String
  count: Int
  checkedTitle: String ::: NonEmpty checkedTitle
}
|}
let proof_source = without_test
  |> replace "import Tesl.Prelude" "import Tesl.Maybe exposing [Maybe(..)]\nimport Tesl.Prelude"
  |> replace "  Row (Schema.Notes.VCurrent.Note { id: old.id, owner: old.author, title: old.title, count: 7 })"
    {|  case Schema.Notes.VCurrent.tryTitle old.title of
    Nothing -> Reject "empty title"
    Something validated -> Row (Schema.Notes.VCurrent.Note { id: old.id, owner: old.author, title: old.title, count: 7, checkedTitle: validated })|}
let private_producer digest () =
  let hash path source = digest (linked path source) in project ~after:proof_schema (fun _ save path ->
  let hidden = "\nestablish hiddenTitle(value: String) -> Maybe (v: String ::: NonEmpty v) =\n  if value != \"x\" then\n    Something (value ::: NonEmpty value)\n  else\n    Nothing\n" in
  ignore (save "schema/notes/v-current.tesl" (proof_schema ^ hidden));
  let first=hash path proof_source in
  ignore (save "schema/notes/v-current.tesl" (proof_schema ^ replace "value != \"x\"" "value != \"y\"" hidden));
  check bool "private fact producer reverse dependency" false (first=hash path proof_source))
let default_mapping digest () =
  let hash path source = digest (linked path source) in project (fun _ _ path ->
  let s=source |> replace "Migrate convert [Rename author owner]" "Derived [Rename author owner, Default count 7]"
    |> replace "fixtures: [oldNote]" "fixtures: []" in
  let first=hash path s in
  check bool "compiler derived default retained" false
    (first=hash path (replace "Default count 7" "Default count 8" s)))
let graph_mismatch () = project (fun _ _ path ->
  let t=transform path source in
  let captures=T.captured_sources t in
  let context=T.proof_context t in
  let subset=List.filter (fun (m,_) -> m.Ast.module_name <> (T.root t).module_name) captures in
  match Migration_checked_graph.check ~context subset with
  | Ok _ -> fail "context attached to subset graph"
  | Error error -> check bool "complete graph required" true (contains error.message "complete source graph"))
let codec_closure digest () =
  let hash path source = digest (linked path source) in
  let after=fresh |> replace "exposing [Note]" "exposing [Note, Metadata]"
    |> replace "entity Note" "import Tesl.Json exposing [intCodec]\nrecord Metadata { count: Int }\ncodec Metadata {\n  toJson { count -> \"count\" with_codec intCodec }\n  fromJson [ { count <- \"count\" with_codec intCodec } ]\n}\nentity Note"
    |> replace "count: Int }" "count: Int, metadata: Metadata }" in
  (* Only Note receives the new field; Metadata is its independent record. *)
  let after=replace "record Metadata { count: Int, metadata: Metadata }" "record Metadata { count: Int }" after in
  project ~after (fun _ save path ->
    let s=replace "count: 7 }" "count: 7, metadata: Schema.Notes.VCurrent.Metadata { count: 7 } }" source in
    let first=hash path s in
    ignore (save "schema/notes/v-current.tesl" (replace "\"count\" with_codec" "\"total\" with_codec" after));
    check bool "record codec reverse dependency" false (first=hash path s))
let same_fact_source schema =
  schema |> replace "exposing [Note]" "exposing [Note, ValidTitle, titleProof]"
  |> replace "entity Note" {|fact ValidTitle (value: String)
establish titleProof(value: String) -> Fact (ValidTitle value) = ValidTitle value
entity Note|}
  |> replace "title: String" "title: String ::: ValidTitle title"
let same_fact_copy_source = without_test
  |> replace "Rule(..), Migrated(..)" "Rule(..), Same(..), Migrated(..)"
  |> replace "same: []" "same: [Same Schema.Notes.V1.ValidTitle Schema.Notes.VCurrent.ValidTitle]"
  |> replace "fn oldNote() -> Schema.Notes.V1.Note =" "fn oldNote() -> Schema.Notes.V1.Note =\n  let title = \"hello\"\n  let proof = Schema.Notes.V1.titleProof title"
  |> replace "title: \"hello\"" "title: title ::: proof"
let same_context () =
  project ~before:(same_fact_source old) ~after:(same_fact_source fresh) (fun _ _ path ->
    let t=transform path same_fact_copy_source in
    let linked=match L.link t with Ok linked -> linked | Error error -> fail error.message in
    check bool "verified Same retained" true (contains (Migration_canonical.encode (L.semantic linked)) "s4:same");
    check bool "behavior retains verified Same" true (contains (Migration_canonical.encode (L.behavior linked)) "s4:same");
    let context=T.proof_context t and captures=T.captured_sources t in
    Migration_proof_context.with_context context (fun () ->
      match Migration_checked_graph.check captures with
      | Ok _ -> fail "context-free factory inherited ambient Same grant"
      | Error error -> check bool "ordinary proof refusal without token" true (contains error.message "does not statically satisfy"));
    let root=T.root t in
    let fn=List.find_map (function Ast.DFunc f -> Some f | _ -> None) root.decls |> Option.get in
    let body=ref fn.body in
    for _=1 to Frontend_check.max_expression_depth + 1 do
      body:=Ast.EUnop {op=Ast.UNeg;arg= !body;loc=fn.loc}
    done;
    let oversized={root with decls=[Ast.DFunc {fn with body= !body}]} in
    match Migration_checked_graph.check ~context [oversized,same_fact_copy_source] with
    | Ok _ -> fail "oversized context comparison accepted"
    | Error error -> check bool "complexity precedes context comparison" true (contains error.message "source complexity budget exceeded"))
let unsaved_buffer () = project (fun _ _ path ->
  let supplied=replace "count: 7" "count: 8" source in
  let m=match Parser.parse_module path supplied with Ok m -> m | Err e -> fail e.msg in
  let abi=match Migration_abi.current () with Ok abi -> Migration_abi.id abi | Error e -> fail e.message in
  let t=match D.check ~compiler_abi:abi ~source:supplied m with
    | Ok (Some d) -> Option.get (D.transforms d)
    | Error errors -> fail (String.concat "\n" (List.map (fun (e:S.error) -> e.message) errors))
    | _ -> fail "missing transform" in
  let result=match L.link t with Ok result -> result | Error error -> fail error.message in
  (match L.revalidate result with Ok () -> () | Error error -> fail error.message);
  write path (source ^ "# observed saved source changed\n");
  match L.revalidate result with Ok () -> fail "unsaved descriptor ignored later source-view mutation" | Error _ -> ())
let lower_after_mutation () = project (fun _ save path ->
  let t=transform path source in
  let graph=match Migration_checked_graph.check ~context:(T.proof_context t) (T.captured_sources t) with
    | Ok graph -> graph | Error error -> fail error.message in
  ignore (save "schema/notes/v1.tesl" (old ^ "# changed before lower\n"));
  match Migration_checked_graph.lower ~scopes:[] graph with
  | Ok _ -> fail "lower ignored stale checked context"
  | Error error -> check bool "precondition checked before lowering" true (contains error.message "changed"))
let fixture_order digest () =
  let hash path source = digest (linked path source) in project (fun _ _ path ->
  let s=replace "fixtures: [oldNote]" "fixtures: [oldNote, olderNote]" source ^
    "fn olderNote() -> Schema.Notes.V1.Note =\n  Schema.Notes.V1.Note { id: \"older\", author: \"writer\", title: \"earlier\" }\n" in
  let first=hash path s in
  check string "fixture declaration order normalized" first
    (hash path (replace "fixtures: [oldNote, olderNote]" "fixtures: [olderNote, oldNote]" s));
  check bool "every fixture retained" false (first=hash path (replace "title: \"earlier\"" "title: \"changed\"" s)))
let other_root () = project (fun _ _ path ->
  let first=transform path source in
  project (fun _ _ path ->
    let second=transform path source in
    match Migration_checked_graph.check ~context:(T.proof_context first) (T.captured_sources second) with
    | Ok _ -> fail "another source root borrowed proof token"
    | Error error -> check bool "root-bound token" true (contains error.message "complete source graph")))
let abi_mutation () = project (fun root save path ->
  let original=Sys.getenv_opt "TESL_STDLIB_DIR" in
  let directory=Filename.concat root "stdlib" in
  let inputs=Validation_common.stdlib_source_directories () |> List.concat_map (fun directory ->
    if Sys.file_exists directory then Sys.readdir directory |> Array.to_list |> List.filter_map (fun name ->
      if Filename.check_suffix name ".tesl" then
        Some (name,In_channel.with_open_bin (Filename.concat directory name) In_channel.input_all)
      else None) else []) in
  List.iter (fun (name,text) -> ignore (save ("stdlib/" ^ name) text)) inputs;
  Unix.putenv "TESL_STDLIB_DIR" directory;
  Fun.protect ~finally:(fun () -> Unix.putenv "TESL_STDLIB_DIR" (Option.value original ~default:""); Query_cache.clear ()) (fun () ->
    let result=linked path source in
    let name,text=List.hd inputs in
    ignore (save ("stdlib/" ^ name) (text ^ "\n# changed compiler resource\n"));
    (match L.revalidate result with
    | Ok () -> fail "changed compiler resource retained link"
    | Error error -> check bool "ABI resource precondition" true (contains error.message "compiler or lifted stdlib ABI changed"));
    Query_cache.clear ();
    let updated = linked path source in
    check bool "changed stdlib changes ABI-bound link" false (L.digest result = L.digest updated);
    check bool "changed stored contract changes behavior" false (L.behavior_digest result = L.behavior_digest updated)))
let behavior_abi_literal () = project (fun _ _ path ->
  let abi = match Migration_abi.current () with Ok abi -> Migration_abi.id abi | Error error -> fail error.message in
  let original = linked path (replace "title: \"hello\"" ("title: \"" ^ abi ^ "\"") source) in
  check bool "ABI-looking user literal is retained verbatim" true
    (contains (Migration_canonical.encode (L.behavior original)) abi);
  let changed = linked path (replace "title: \"hello\"" ("title: \"" ^ abi ^ "-changed\"") source) in
  check bool "ABI-looking literal changes behavior" false
    (L.behavior_digest original = L.behavior_digest changed))
let behavior_same_only () =
  let extra schema = replace "exposing [Note]" "exposing [Note, Tag]" schema ^ "\nrecord Tag { value: String }\n" in
  project ~before:(extra old) ~after:(extra fresh) (fun _ _ path ->
    let plain = linked path source in
    let verified = linked path (source
      |> replace "Rule(..), Migrated(..)" "Rule(..), Same(..), Migrated(..)"
      |> replace "same: []" "same: [Same Schema.Notes.V1.Tag Schema.Notes.VCurrent.Tag]") in
    check bool "unused checked Same changes behavior directly" false
      (L.behavior_digest plain = L.behavior_digest verified))
let both_identities run () =
  run L.digest ();
  run L.behavior_digest ()
let () = run "migration transform semantic link" ["link", [
  test_case "behavior retains ABI-looking user literals" `Quick behavior_abi_literal;
  test_case "behavior binds standalone Same judgments" `Quick behavior_same_only;
  test_case "explicit roles and complete semantic payload" `Quick basic;
  test_case "location and spelling invariance" `Quick (both_identities stable);
  test_case "semantic mutations change identity" `Quick (both_identities mutation);
  test_case "private helper reachability" `Quick (both_identities helper);
  test_case "ordinary constants refuse" `Quick ordinary_constant;
  test_case "post-link source mutation" `Quick changed_inputs;
  test_case "pre-link source mutation" `Quick changed_before_link;
  test_case "omission requires original owner" `Quick graph_binding;
  test_case "compiler ABI exact binding" `Quick abi_mismatch;
  test_case "private fact producer closure" `Quick (both_identities private_producer);
  test_case "derived mapping semantics" `Quick (both_identities default_mapping);
  test_case "context rejects incomplete graph" `Quick graph_mismatch;
  test_case "record codec reverse dependency" `Quick (both_identities codec_closure);
  test_case "Same context is explicit and bounded" `Quick same_context;
  test_case "unsaved buffer publication guards" `Quick unsaved_buffer;
  test_case "lower checks mutation again" `Quick lower_after_mutation;
  test_case "all fixtures included in canonical order" `Quick (both_identities fixture_order);
  test_case "context refuses another root" `Quick other_root;
  test_case "compiler resources rechecked at publication" `Quick abi_mutation]]
