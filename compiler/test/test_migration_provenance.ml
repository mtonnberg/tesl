open Alcotest
module S = Migration_source_syntax
module P = Migration_provenance
let previous = "NotesSchema.V1" and current = "NotesSchema.VCurrent"
let get = function Ok x -> x | Error (e : S.error) -> fail e.message
let refuses = function Error _ -> () | Ok _ -> fail "user-owned bytes would be annotated"
let replace a b = Str.global_replace (Str.regexp_string a) b
let fixture ?(after="") expression =
  "module NotesSchema.Migrate.V2 exposing [migration]\n" ^
  "import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Same(..)]\n" ^
  "import NotesSchema.V1\nimport NotesSchema.VCurrent\n" ^
  "migration = Migration {\n  from: NotesSchema.V1\n  to: NotesSchema.VCurrent\n  same: []\n  entities: {\n    Note: " ^ expression ^ after ^ "\n  }\n}\n"
let view source = get (S.read ~file:"/tmp/migration-provenance.tesl" ~source)
let entries t =
  let c = List.find_map (function Ast.DConst c -> Some c | _ -> None) (S.module_ t).decls |> Option.get in
  match Migration_form.application c.value with
  | "Migration",[Ast.ERecord {fields;_}] -> (match List.assoc "entities" fields with
    | Ast.ERecord {fields;_} -> fields | _ -> fail "fixture entities")
  | _ -> fail "fixture migration"
let entry t = List.assoc "Note" (entries t)
let status ?(current=current) source =
  let t = view source in P.ownership t ~previous ~current ~id:"entity:Note" (entry t)
let annotate source = let t = view source in get (P.annotate t ~previous ~current ["entity:Note",entry t])
let base = fixture "Additive [Default count 7]"
let fresh () =
  check bool "unmarked source stays distinct" true (status base = P.Unmarked);
  let generated = annotate base in
  check bool "fresh marker matches its syntax" true (status generated = P.Generated);
  check string "annotation is idempotent" generated (annotate generated)
let user_edit () =
  let generated = annotate base in
  List.iter (fun changed ->
    check bool "changed body is user-owned" true (status changed = P.User_owned);
    let t = view changed in refuses (P.annotate t ~previous ~current ["entity:Note",entry t]);
    check string "annotation refusal retains bytes" changed (S.source t))
    [replace "count 7" "count 8" generated;replace "count 7" "other 7" generated;
     replace "Additive [Default count 7]" "New" generated]
let formatting () =
  let generated = annotate base in
  List.iter (fun changed -> check bool "formatting retains generated status" true (status changed = P.Generated))
    [Formatter.format_source generated;replace "count 7" "count 007" generated;
     replace "\n" "\r\n" generated;replace "    Note:" "\tNote:" generated]
let comments_inside () =
  let generated = annotate base in
  let changed = replace "Additive [Default count 7]"
    "Additive [\n      # User explanation must survive refresh.\n      Default count 7\n    ]" generated in
  check bool "new internal comment protects the node" true (status changed = P.User_owned);
  let t = view changed in refuses (P.annotate t ~previous ~current ["entity:Note",entry t])
let hashes_in_strings () =
  let source = fixture {|Additive [Default title "# @tesl-gen text with \"quote\" and \\ slash"]|} in
  let generated = annotate source in
  check bool "hash inside string is not a source comment" true (status generated = P.Generated)
let existing_tails () =
  List.iter (fun after ->
    let source = fixture ~after "Additive []" in
    let t = view source in refuses (P.annotate t ~previous ~current ["entity:Note",entry t]);
    check string "comments and code remain byte-identical" source (S.source t))
    [" # user explanation";", Other: New";" # @tesl-gen invalid nonsense"]
let comma () =
  let source = fixture ~after:"," "Additive []" in
  let generated = annotate source in
  check bool "marker follows the separator" true
    (try ignore (Str.search_forward (Str.regexp_string "Additive [], # @tesl-gen") generated 0); true with Not_found -> false);
  check bool "trailing-comma marker is owned" true (status generated = P.Generated)
let roles () =
  let source = fixture "Additive [Default owner NotesSchema.VCurrent.Owner]" in
  let generated = annotate source in
  let frozen = replace "NotesSchema.VCurrent" "NotesSchema.V2" generated in
  check bool "frozen role still matches original fingerprint" true (status ~current:"NotesSchema.V2" frozen = P.Generated);
  check bool "wrong role cannot authorize rewriting" true (status ~current:"OtherSchema.VCurrent" generated = P.User_owned)
let malformed_markers () =
  let generated = annotate base in
  List.iter (fun changed ->
    check bool "edited/malformed marker remains user-owned" true (status changed = P.User_owned))
    [replace "entity:Note" "entity:Other" generated;
     replace "# @tesl-gen " "# @tesl-gen-v2 " generated;
     replace "# @tesl-gen " "# @tesl-gen  " generated;
     replace "entity:Note " "entity:Note x" generated]
let duplicate_ids () =
  let t = view (fixture ~after:", Other: New" "Additive []") in
  let fields = entries t in
  refuses (P.annotate t ~previous ~current ["entity:Note",List.assoc "Note" fields;"entity:Note",List.assoc "Other" fields]);
  let t = view base in
  refuses (P.annotate t ~previous ~current ["one",entry t;"two",entry t]);
  refuses (P.annotate t ~previous ~current ["bad id",entry t])
let unsupported () =
  let t = view (fixture "Additive [Default count (1 + 2)]") in
  refuses (P.annotate t ~previous ~current ["entity:Note",entry t]);
  check bool "unsupported data is protected" true (P.ownership t ~previous ~current ~id:"entity:Note" (entry t) = P.User_owned)
let stale_node () =
  let t = view base in
  let annotated = view (annotate base) in
  check bool "old AST cannot authorize a new view" true
    (P.ownership annotated ~previous ~current ~id:"entity:Note" (entry t) = P.User_owned)
let () = run "Migration generated-node ownership" ["source preservation",List.map (fun (name,f) -> test_case name `Quick f)
  ["fresh and idempotent annotations",fresh;"edited bodies stay user-owned",user_edit;
   "formatting and byte layouts",formatting;"user comments protect generated bodies",comments_inside;
   "marker-like string content",hashes_in_strings;"existing comments and code are never overwritten",existing_tails;
   "separators stay outside comments",comma;"freeze-normalized role fingerprints",roles;
   "malformed or edited metadata protects source",malformed_markers;"duplicate and invalid identities",duplicate_ids;
   "unsupported expressions stay user-owned",unsupported;"stale AST ownership refuses",stale_node]]
