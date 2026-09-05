open Alcotest
module S = Migration_source_syntax
module P = Migration_provenance
module M = Migration_source_merge
let previous = "NotesSchema.V1" and current = "NotesSchema.VCurrent"
let get = function Ok x -> x | Error (e : S.error) -> fail e.message
let refuses = function Error _ -> () | Ok _ -> fail "unsafe source merge accepted"
let replace a b = Str.global_replace (Str.regexp_string a) b
let fixture ?(same="[]") entities =
  "module NotesSchema.Migrate.V2 exposing [migration]\n" ^
  "import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Same(..)]\n" ^
  "import NotesSchema.V1\nimport NotesSchema.VCurrent\n" ^
  "# Human introduction.\nmigration = Migration {\n  from: NotesSchema.V1\n  to: NotesSchema.VCurrent\n" ^
  "  same: " ^ same ^ "\n  entities: " ^ entities ^ "\n}\n" ^
  "# Human helper and regression.\nfn identity(n: Int) -> Int = n\ntest \"unchanged\" { expect identity 1 == 1 }\n"
let view source = get (S.read ~file:"/tmp/migration-source-merge.tesl" ~source)
let collection name view =
  let c = List.find_map (function Ast.DConst c -> Some c | _ -> None) (S.module_ view).decls |> Option.get in
  match Migration_form.application c.value with
  | "Migration",[Ast.ERecord {fields;_}] -> List.assoc name fields
  | _ -> fail "fixture migration"
let ids view name =
  get (S.members view (collection name view)) |> List.map (fun (key,value) ->
    let id = match key with Some key -> "entity:" ^ key | None ->
      (match Migration_form.application value with
       | "Same",[Ast.EConstructor {name;_};_] -> "same:" ^ List.hd (List.rev (String.split_on_char '.' name))
       | _ -> fail "fixture Same") in id,value)
let mark ?(name="entities") source = let v = view source in get (P.annotate v ~previous ~current (ids v name))
let merge ?(name="entities") source desired =
  let v = view source in M.reconcile v ~collection:(collection name v) ~previous ~current ~existing:(ids v name) ~desired
let wanted key body = {M.id="entity:" ^ key;key=Some key;body}
let same key = {M.id="same:" ^ key;key=None;body="Same NotesSchema.V1." ^ key ^ " NotesSchema.VCurrent." ^ key}
let base = fixture "{\n    Note: Additive []\n  }"
let generated () = mark base
let ownership source = let v = view source in List.iter (fun (id,value) ->
  check bool "emitted marker authorizes only its own unchanged node" true
    (P.ownership v ~previous ~current ~id value = P.Generated)) (ids v "entities")
let noop () =
  let source = generated () |> replace "Additive []" "Additive [\n    ]" in
  let result = get (merge source [wanted "Note" "Additive []"]) in
  check string "equal syntax preserves every byte" source result.source;
  check (list string) "generated entry is not protected" [] result.protected
let changed () =
  let source = generated () in
  let result = get (merge source [wanted "Note" "Additive [Default count 9]"]) in
  ownership result.source;
  let v = view result.source in
  let value = snd (List.hd (ids v "entities")) in
  check string "actual replacement" "Additive [Default count 9]" (S.text v (get (S.range v value)));
  check string "repeat refresh is idempotent" result.source
    (get (merge result.source [wanted "Note" "Additive [Default count 9]"])).source;
  check bool "helper and test bytes survive" true (String.ends_with ~suffix:
    "# Human helper and regression.\nfn identity(n: Int) -> Int = n\ntest \"unchanged\" { expect identity 1 == 1 }\n" result.source)
let remove_generated () =
  let source = fixture "{\n    # before\n    Note: Additive []\n    # after\n  }" |> mark in
  let v = view source in let c = collection "entities" v in
  let id,value = List.hd (ids v "entities") in
  let span = P.editable_member v ~collection:c ~previous ~current ~id value |> Option.get in
  let result = get (merge source []) in
  check string "only the owned member and marker disappear" (get (S.replace v [span,""])) result.source;
  check int "empty collection parses" 0 (List.length (ids (view result.source) "entities"));
  check string "second deletion is no-op" result.source (get (merge result.source [])).source
let additions () =
  List.iter (fun entities ->
    let source = fixture entities in
    let result = get (merge source [wanted "Notes.Note" "Additive []";wanted "Tag" "New"]) in
    ownership result.source;
    check int "two additions" 2 (List.length (ids (view result.source) "entities"));
    check string "second append is no-op" result.source
      (get (merge result.source [wanted "Notes.Note" "Additive []";wanted "Tag" "New"])).source)
    ["{}";"{\n    # Please preserve this explanation.\n  }"]
let mixed () =
  let source = fixture "{\n    Note: Additive []\n    Tag: New,\n  }" |> mark in
  let source = replace "Note: Additive []" "Note: Additive [Default title \"edited\"]" source in
  let desired = [wanted "Note" "Drop";wanted "Session" "New"] in
  let result = get (merge source desired) in
  check (list string) "only edited node is protected" ["entity:Note"] result.protected;
  check (list string) "edited node retained, obsolete generated removed, new appended"
    ["entity:Note";"entity:Session"] (List.map fst (ids (view result.source) "entities"));
  check bool "user body is still present" true
    (try ignore (Str.search_forward (Str.regexp_string "Note: Additive [Default title \"edited\"]") result.source 0); true with Not_found -> false)
let protect_user () =
  List.iter (fun source ->
    List.iter (fun desired ->
      let result = get (merge source desired) in
      check string "user bytes are never changed" source result.source;
      check (list string) "reports decision ownership" ["entity:Note"] result.protected)
      [[];[wanted "Note" "New"]])
    [base;replace "Additive []" "Additive [Default title \"user\"]" (generated ());
     replace "Additive []" "Additive [\n      # user internal explanation\n    ]" (generated ());
     replace "entity:Note" "entity:Changed" (generated ())]
let unsupported_sibling () =
  let source = fixture "{\n    Note: Additive []\n  }" |> mark in
  let source = replace "\n  }" "\n    Manual: Additive [Default count (1 + 2)] # manual rule\n  }" source in
  let result = get (merge source [wanted "Note" "Drop";wanted "Tag" "New"]) in
  check (list string) "unsupported sibling stays protected" ["entity:Manual"] result.protected;
  check bool "manual rule survives exact" true
    (try ignore (Str.search_forward (Str.regexp_string "Manual: Additive [Default count (1 + 2)] # manual rule") result.source 0); true with Not_found -> false)
let keys_and_ranges () =
  List.iter (fun key ->
    let source = fixture ("{\n    " ^ key ^ ": Additive []\n  }") in
    let v = view source in let c = collection "entities" v in
    let _,e = List.hd (get (S.members v c)) in
    check string "original key and exact value" (key ^ ": Additive []") (S.text v (get (S.member_range v ~collection:c e))))
    ["Note";"Notes.Note";"\"Notes.Note\"";"\"escaped\\\"key\"";"email";"schema";"telemetry"];
  (* A colon cannot currently be followed by a newline before its value. *)
  refuses (S.read ~file:"/tmp/migration-key.tesl" ~source:(fixture "{\n    Note:\n      Additive []\n  }"))
let layouts () =
  List.iter (fun source ->
    let result = get (merge source [wanted "Note" "Drop";wanted "Tag" "New"]) in
    ownership result.source;
    check string "layout refresh idempotent" result.source
      (get (merge result.source [wanted "Note" "Drop";wanted "Tag" "New"])).source)
    [generated () |> replace "\n" "\r\n";
     fixture "{\n\tNote: Additive []\n}" |> mark;
     fixture "{Note: Additive [],\n  }" |> mark]
let same_merge () =
  let source = fixture ~same:"[\n    Same NotesSchema.V1.Payload NotesSchema.VCurrent.Payload,\n  ]" "{}" |> mark ~name:"same" in
  let result = get (merge ~name:"same" source [same "Owner"]) in
  check (list string) "Same ownership supports replace membership" ["same:Owner"] (List.map fst (ids (view result.source) "same"));
  check string "Same refresh is idempotent" result.source (get (merge ~name:"same" result.source [same "Owner"])).source
let malformed () =
  List.iter (fun body -> refuses (merge (generated ()) [wanted "Note" body]))
    ["New # new comment";"New, Other: Drop";"New\n} }\nfn evil() = 1\n#";
     "Additive [Default count (1 + 2)]";"Additive [\n # hidden comment\n]"];
  refuses (merge (generated ()) [wanted "Note" "New";wanted "Note" "Drop"]);
  refuses (merge (generated ()) [{M.id="different";key=Some "Note";body="New"}]);
  refuses (merge (generated ()) [{M.id="entity:Note";key=Some "Changed";body="New"}]);
  refuses (merge (generated ()) [{M.id="invalid id";key=Some "Other";body="New"}]);
  let duplicate = view (fixture "{Note: New, Note: Drop}") in
  refuses (M.reconcile duplicate ~collection:(collection "entities" duplicate) ~previous ~current ~existing:[] ~desired:[]);
  refuses (merge (fixture "{}") [{M.id="entity:Other";key=Some "bad\"key";body="New"}])
let stale () =
  let source = generated () in let v = view source and other = view source in
  refuses (M.reconcile v ~collection:(collection "entities" other) ~previous ~current ~existing:(ids other "entities") ~desired:[]);
  refuses (M.reconcile v ~collection:(collection "entities" v) ~previous ~current ~existing:[] ~desired:[]);
  let id,e = List.hd (ids v "entities") in
  refuses (M.reconcile v ~collection:(collection "entities" v) ~previous ~current ~existing:[id,e;"other",e] ~desired:[]);
  let leaf = match Migration_form.application e with _,[x] -> x | _ -> fail "list child" in
  refuses (S.member_range v ~collection:(collection "entities" v) leaf)
let () = run "Migration source reconciliation" ["preserved ownership",List.map (fun (name,f) -> test_case name `Quick f)
  ["equal syntax keeps exact bytes",noop;"replace generated and renew marker",changed;
   "remove only generated member",remove_generated;"append into empty collections",additions;
   "mixed removal, addition and user edit",mixed;"user bodies and comments remain protected",protect_user;
   "arbitrary user expressions beside generated entries",unsupported_sibling;
   "exact qualified/quoted keys and malformed layout",keys_and_ranges;"CRLF, tabs and inline delimiters",layouts;
   "Same list membership refresh",same_merge;"invalid fragments, keys and identities",malformed;
   "stale nodes and incomplete member inventory",stale]]
