open Alcotest
module S = Migration_source_syntax
let get = function Ok x -> x | Error (e : S.error) -> fail e.message
let refuses = function Error _ -> () | Ok _ -> fail "unsafe source range/edit accepted"
let fixture ?(indent="    ") ?(after="") value =
  "module NotesSchema.Migrate.V2 exposing [migration]\n" ^
  "import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Same(..)]\n" ^
  "import NotesSchema.V1\nimport NotesSchema.VCurrent\n" ^
  "migration = Migration {\n  from: NotesSchema.V1\n  to: NotesSchema.VCurrent\n  same: []\n  entities: {\n" ^
  indent ^ "Note: " ^ value ^ after ^ "\n  }\n}\n# user suffix\n"
let view source = get (S.read ~file:"/tmp/migration-source-view.tesl" ~source)
let entry t =
  let c = List.find_map (function Ast.DConst c -> Some c | _ -> None) (S.module_ t).decls |> Option.get in
  match Migration_form.application c.value with
  | "Migration",[Ast.ERecord {fields;_}] -> (match List.assoc "entities" fields with
    | Ast.ERecord {fields;_} -> List.assoc "Note" fields | _ -> fail "entities fixture")
  | _ -> fail "migration fixture"
let fp ?(previous="NotesSchema.V1") ?(current="NotesSchema.VCurrent") expr =
  S.fingerprint ~previous ~current expr
let replace a b = Str.global_replace (Str.regexp_string a) b
let extracted value =
  let source = fixture ~after:" # user comment" value in
  let t = view source in
  let range = get (S.range t (entry t)) in
  check string "only the expression" value (S.text t range);
  check string "surrounding bytes remain identical" (replace value "New" source) (get (S.replace t [range,"New"]))
let exact_boundaries () = List.iter extracted
  ["Additive []";"New";"Drop";"Additive [Default title \"old\"]";
   "Additive [Default amount -000123]";"Additive [Default score 0001.2300]";
   "Additive [Default select 9]";
   {|Additive [Default title "quote \" and slash \\"]|};
   "Additive [Default title \"åäö\"]"]
let nested_leaf_ranges () =
  let t = view (fixture "Additive [Default title \"å\\\"b\\\\c\", Default count 00009, Default score 0001.2300]") in
  let leaves = ref [] in
  Ast_visitor.iter (function Ast.ELit _ as e -> leaves := e :: !leaves | _ -> ()) (entry t);
  let texts = List.map (fun e -> S.text t (get (S.range t e))) (List.rev !leaves) in
  check (list string) "raw lexical lengths, not decoded values" ["\"å\\\"b\\\\c\"";"00009";"0001.2300"] texts
let crlf_tabs () =
  let source = fixture ~indent:"\t" ~after:" # after" "Additive [Default title \"å\"]" |> replace "\n" "\r\n" in
  let t = view source in
  let range = get (S.range t (entry t)) in
  check string "tabs use bytes while diagnostic columns expand" "Additive [Default title \"å\"]" (S.text t range);
  check string "CRLF/comment/indent bytes preserved" (replace "Additive [Default title \"å\"]" "New" source)
    (get (S.replace t [range,"New"]))
let multiline () =
  let expression = "Additive [\n      Default title \"x\",\n      # note inside generated data\n      Default count 9\n    ]" in
  extracted expression
let separator () =
  let t = view (fixture ~after:", # entry note" "Additive []") in
  let range = get (S.range t (entry t)) in
  check string "comma remains outside edit" "Additive []" (S.text t range);
  check string "separator and comment remain" (fixture ~after:", # entry note" "New")
    (get (S.replace t [range,"New"]))
let record_range () =
  let t = view (fixture "Additive []") in
  let c = List.find_map (function Ast.DConst c -> Some c | _ -> None) (S.module_ t).decls |> Option.get in
  let _,args = Migration_form.application c.value in
  let expression = List.hd args in
  let text = S.text t (get (S.range t expression)) in
  check bool "closing brace included" true (String.ends_with ~suffix:"\n}" text);
  check bool "suffix excluded" false (String.contains text '#')
let stale_ast () =
  let source = fixture "Additive []" in
  let t = view source and other = view source in
  refuses (S.range t (entry other));
  let e = entry t in
  let clone = match e with Ast.EApp app -> Ast.EApp {app with loc=app.loc} | _ -> fail "fixture app" in
  refuses (S.range t clone);
  ignore (get (S.range t e))
let unsupported () =
  let t = view (fixture "Additive [Default count (1 + 2)]") in
  check (option string) "computed body cannot become generator-owned" None (fp (entry t));
  refuses (S.range t (entry t));
  let t = view (fixture "Additive [Default title \"value ${1 + 2}\"]") in
  check (option string) "interpolation stays user-owned" None (fp (entry t));
  refuses (S.range t (entry t))
let formatting_identity () =
  let source = fixture "Additive [Default count 007]" in
  let original = fp (entry (view source)) in
  check bool "supported body has identity" true (Option.is_some original);
  List.iter (fun changed -> check (option string) "layout does not change AST ownership" original (fp (entry (view changed))))
    [replace "007" "7" source;
     replace "Additive [Default count 007]" "Additive [\n      Default count 7\n    ]" source;
     replace "\n" "\r\n" source;
     Formatter.format_source source]
let semantic_edits () =
  let original = fp (entry (view (fixture "Additive [Default count 7]"))) in
  List.iter (fun changed -> check bool "body edit changes syntax identity" false
    (original = fp (entry (view (fixture changed)))))
    ["Additive [Default count 8]";"Additive [Default other 7]";"Additive [Default count \"7\"]";
     "Additive []";"New"]
let role_renaming () =
  let source = fixture "Additive [Default owner NotesSchema.VCurrent.Owner]" in
  let original = fp (entry (view source)) in
  let frozen = replace "NotesSchema.VCurrent" "NotesSchema.V2" source in
  check (option string) "freezing target preserves ownership identity" original
    (fp ~current:"NotesSchema.V2" (entry (view frozen)));
  check bool "role reversal is not identity" false
    (original = fp ~previous:"NotesSchema.VCurrent" ~current:"NotesSchema.V1" (entry (view source)));
  check (option string) "different families refused" None
    (fp ~current:"OtherSchema.VCurrent" (entry (view source)));
  check (option string) "identical roles refused" None
    (fp ~current:"NotesSchema.V1" (entry (view source)))
let disjoint_edits () =
  let source = fixture "Additive [Default count 7, Default size 9]" in
  let t = view source in
  let leaves = ref [] in Ast_visitor.iter (function Ast.ELit _ as e -> leaves := e :: !leaves | _ -> ()) (entry t);
  let edits = List.map (fun e -> get (S.range t e),"10") !leaves in
  check string "edits apply in source order" (fixture "Additive [Default count 10, Default size 10]") (get (S.replace t edits));
  let range = get (S.range t (entry t)) in
  refuses (S.replace t ((range,"New") :: edits));
  refuses (S.replace t [({S.start_byte=0;end_byte=String.length source + 1},"")]);
  refuses (S.replace t [({S.start_byte=(-1);end_byte=0},"")]);
  let insertion = {S.start_byte=range.start_byte;end_byte=range.start_byte} in
  refuses (S.replace t [insertion," ";insertion," "]);
  refuses (S.replace t [range,"Additive ["])
let malformed () = refuses (S.read ~file:"/tmp/migration.tesl" ~source:"module Broken exposing [")
let () = run "Migration source syntax" ["precise edits",List.map (fun (name,f) -> test_case name `Quick f)
  ["expression boundaries exclude comments and separators",exact_boundaries;
   "leaf ranges preserve raw literal spellings",nested_leaf_ranges;"CRLF and tab byte offsets",crlf_tabs;
   "multiline expression range",multiline;"record range excludes following source",record_range;
   "separators and comments are outside entry ranges",separator;
   "stale or reconstructed AST cannot address source",stale_ast;"unsupported expressions remain user-owned",unsupported;
   "formatting preserves syntax fingerprints",formatting_identity;"body changes invalidate fingerprints",semantic_edits;
   "schema role renaming",role_renaming;"disjoint edits and rejected overlap",disjoint_edits;
   "malformed source refuses editing",malformed]]
