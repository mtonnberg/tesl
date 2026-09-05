open Migration_ir
open Migration_inventory
open Alcotest

let rec mkdir path =
  if not (Sys.file_exists path) then begin mkdir (Filename.dirname path); Unix.mkdir path 0o700 end
let rec remove path =
  if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  end else Sys.remove path
let with_project f =
  let root = Filename.temp_file "tesl-migration-same-" ".dir" in
  Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let write relative source =
      let path = Filename.concat root relative in mkdir (Filename.dirname path);
      Out_channel.with_open_bin path (fun channel -> output_string channel source); path in
    ignore (write "tesl.toml" ""); f root write)
let get = function Ok value -> value | Error (error : Migration_ir.error) -> fail error.message
let load ?(abi="test-compiler-1") path = get (load ~compiler_abi:abi ~root_file:path)
let replace before after = Str.global_replace (Str.regexp_string before) after
let equal = function Ok value -> value | Error (e : same_error) -> fail e.message
let rejected expected = function
  | Ok _ -> fail "accepted an invalid Same claim"
  | Error (e : same_error) -> check bool e.message true (e.kind = expected); e
let names evidence =
  let old, fresh = same_declarations evidence in
  Migration_ir.namespace old.namespace ^ " " ^ old.qualified_name ^ " -> " ^ fresh.qualified_name
let candidates before after = get (same_candidates ~before ~after) |> List.map names |> List.sort String.compare
let verify before after ns name = verify_same ~before ~after
  ~previous:(ns, "NotesSchema.V1.Shared." ^ name)
  ~current:(ns, "NotesSchema.VCurrent.Shared." ^ name)

let imports = {|import Tesl.Prelude exposing [Bool(..), Int, String]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Json exposing [stringCodec]
|}
let shared = {|module NotesSchema.VCurrent.Shared exposing [Id, Payload, State(..), Positive, accept]
|} ^ imports ^ {|type Id = String
type State
  = Pending
  | Done
codec State { adtJson }
record Payload { text: String, state: State }
codec Payload {
  toJson {
    text -> "body" with_codec stringCodec
    state -> "state" with_codec State
  }
  fromJson [
    { text <- "body" with_codec stringCodec, state <- "state" with_codec State }
    { text <- "title" with_codec stringCodec, state <- "state" with_codec State }
  ]
}
fact Positive (n: Int)
fn threshold() -> Int = 0
establish accept(n: Int) -> Maybe (v: Int ::: Positive v) =
  if n > threshold() then
    Something (n ::: Positive n)
  else
    Nothing
fn unrelated() -> Int = 99
entity Hidden table "hidden" primaryKey id {
  id: String
  amount: Int ::: Positive amount
  payload: Payload
}
|}
let fixture root write source =
  ignore (write "schema/notes/v-current/shared.tesl" source);
  let current_path = write "schema/notes/v-current.tesl"
    "module NotesSchema.VCurrent exposing []\nimport NotesSchema.VCurrent.Shared exposing []\n" in
  let live = load current_path in
  let copies = match Migration_source.freeze_closure ~project_root:root ~family:"NotesSchema" ~version:1 with
    | Ok copies -> copies | Error message -> fail message in
  List.iter (fun (copy : Migration_source.frozen_copy) ->
    mkdir (Filename.dirname copy.target_path);
    Out_channel.with_open_bin copy.target_path (fun channel -> output_string channel copy.contents)) copies;
  let old = load (Filename.concat root "schema/notes/v1.tesl") in
  old, live, current_path
let change write path source =
  ignore (write "schema/notes/v-current/shared.tesl" source); load path
let difference_name = Option.map (fun d -> d.qualified_name)
let expect_difference old_name new_name e =
  check (option string) "old differing declaration" old_name (difference_name e.difference.previous);
  check (option string) "new differing declaration" new_name (difference_name e.difference.current)

let complete_inventory () = with_project (fun root write ->
  let before, after, _ = fixture root write shared in
  let ds = declarations after in
  check int "private types, codecs, fact producers, helpers and entity" 10 (List.length ds);
  List.iter (fun d -> check string "actual private source file"
    (Filename.concat root "schema/notes/v-current/shared.tesl") d.source_loc.file) ds;
  let expected = List.map (fun (ns, name) ->
    Migration_ir.namespace ns ^ " NotesSchema.V1.Shared." ^ name ^ " -> NotesSchema.VCurrent.Shared." ^ name)
    [Type,"Id"; Type,"Payload"; Type,"State"; Predicate,"Positive"; Codec,"Payload"; Codec,"State"]
    |> List.sort String.compare in
  check (list string) "all eligible private declarations, with namespaces kept distinct"
    expected (candidates before after);
  let evidence = equal (verify before after Predicate "Positive") in
  check string "evidence is bound to this compiler" "test-compiler-1" (same_compiler_abi evidence);
  check string "same-domain identity of the complete checked closure"
    (Migration_canonical.digest Same (get (closure before [Predicate,"NotesSchema.V1.Shared.Positive"])))
    (same_digest evidence);
  check bool "snapshot and Same cannot substitute for one another" true
    (same_digest evidence <> Migration_canonical.digest Snapshot (get (closure before [Predicate,"NotesSchema.V1.Shared.Positive"]))))

let changed_private_helper () = with_project (fun root write ->
  let before, _, path = fixture root write shared in
  let after = change write path (replace "threshold() -> Int = 0" "threshold() -> Int = 1" shared) in
  let e = rejected Different_closure (verify before after Predicate "Positive") in
  expect_difference (Some "NotesSchema.V1.Shared.threshold") (Some "NotesSchema.VCurrent.Shared.threshold") e;
  check (option string) "old related location belongs to the frozen dependency"
    (Some (Filename.concat root "schema/notes/v1/shared.tesl"))
    (Option.map (fun d -> d.source_loc.file) e.difference.previous);
  check (option string) "new related location belongs to the live dependency"
    (Some (Filename.concat root "schema/notes/v-current/shared.tesl"))
    (Option.map (fun d -> d.source_loc.file) e.difference.current);
  check int "only the changed fact loses its candidate" 5 (List.length (candidates before after));
  ignore (equal (verify before after Type "Payload")))

let changed_owner () = with_project (fun root write ->
  let before, _, path = fixture root write shared in
  let after = change write path (replace "n > threshold()" "n >= threshold()" shared) in
  let e = rejected Different_closure (verify before after Predicate "Positive") in
  expect_difference (Some "NotesSchema.V1.Shared.accept") (Some "NotesSchema.VCurrent.Shared.accept") e)

let added_and_removed_owner () = with_project (fun root write ->
  let before, _, path = fixture root write shared in
  let after = change write path (shared ^ {|establish alsoAccept(n: Int) -> Maybe (v: Int ::: Positive v) =
  if n > 10 then
    Something (n ::: Positive n)
  else
    Nothing
|}) in
  let e = rejected Different_closure (verify before after Predicate "Positive") in
  expect_difference None (Some "NotesSchema.VCurrent.Shared.alsoAccept") e;
  let reversed = rejected Different_closure (verify_same ~before:after ~after:before
    ~previous:(Predicate,"NotesSchema.VCurrent.Shared.Positive") ~current:(Predicate,"NotesSchema.V1.Shared.Positive")) in
  expect_difference (Some "NotesSchema.VCurrent.Shared.alsoAccept") None reversed)

let unrelated_changes () = with_project (fun root write ->
  let before, live, path = fixture root write shared in
  let after = change write path (replace "Int = 99" "Int = 100" shared) in
  check bool "snapshot includes unrelated helpers" true (snapshot live <> snapshot after);
  check (list string) "per-declaration evidence excludes unreachable helpers"
    (candidates before live) (candidates before after))

let codec_directions () = with_project (fun root write ->
  let before, _, path = fixture root write shared in
  List.iter (fun source ->
    let after = change write path source in
    List.iter (fun ns ->
      let e = rejected Different_closure (verify before after ns "Payload") in
      expect_difference (Some "NotesSchema.V1.Shared.Payload") (Some "NotesSchema.VCurrent.Shared.Payload") e;
      check (option string) "diagnostic names the codec namespace, not the unchanged record"
        (Some "codec") (Option.map (fun d -> Migration_ir.namespace d.namespace) e.difference.current)) [Type; Codec];
    ignore (equal (verify before after Type "State"))) [
      replace "text -> \"body\"" "text -> \"content\"" shared;
      replace "text <- \"title\"" "text <- \"legacy\"" shared;
      replace "    { text <- \"title\" with_codec stringCodec, state <- \"state\" with_codec State }\n" "" shared;
      replace "toJson {\n    text -> \"body\" with_codec stringCodec\n    state -> \"state\" with_codec State\n  }" "toJson forbidden" shared;
    ])

let nested_adt () = with_project (fun root write ->
  let before, _, path = fixture root write shared in
  let after = change write path (replace "Pending" "Waiting" shared) in
  List.iter (fun (ns, name) ->
    let e = rejected Different_closure (verify before after ns name) in
    expect_difference (Some "NotesSchema.V1.Shared.State") (Some "NotesSchema.VCurrent.Shared.State") e;
    check (option string) "nested ADT owns the first changed node" (Some "type")
      (Option.map (fun d -> Migration_ir.namespace d.namespace) e.difference.current))
    [Type,"Payload"; Type,"State"; Codec,"Payload"; Codec,"State"];
  check int "only unrelated Id and Positive remain equal" 2 (List.length (candidates before after)))

let generic_adt () = with_project (fun root write ->
  let source = "module NotesSchema.VCurrent.Shared exposing []\n" ^ imports ^ {|type Box a
  = Packed { value: a }
type State
  = On
  | Off
record Holder { nested: Box (Maybe State) }
|} in
  let before, live, path = fixture root write source in
  ignore (equal (verify before live Type "Holder"));
  let alpha = change write path (replace "Box a\n  = Packed { value: a }" "Box item\n  = Packed { value: item }" source) in
  ignore (equal (verify before alpha Type "Box"));
  let after = change write path (replace "  | Off" "  | Off\n  | Unknown" source) in
  ignore (rejected Different_closure (verify before after Type "Holder"));
  ignore (equal (verify before after Type "Box")))

let same_kind_and_scope () = with_project (fun root write ->
  let before, live, path = fixture root write shared in
  List.iter (fun (old, fresh) -> ignore (rejected Invalid_declaration
    (verify_same ~before ~after:live ~previous:old ~current:fresh))) [
    (Type,"NotesSchema.V1.Shared.Missing"), (Type,"NotesSchema.VCurrent.Shared.Id");
    (Value,"NotesSchema.V1.Shared.Id"), (Value,"NotesSchema.VCurrent.Shared.Id");
    (Value,"NotesSchema.V1.Shared.Pending"), (Value,"NotesSchema.VCurrent.Shared.Pending");
    (Type,"Tesl.Prelude.String"), (Type,"Tesl.Prelude.String");
    (Type,"NotesSchema.VCurrent.Shared.Id"), (Type,"NotesSchema.V1.Shared.Id");
    (Type,"NotesSchema.V2.Shared.Id"), (Type,"NotesSchema.VCurrent.Shared.Id");
  ];
  List.iter (fun (ns, name) -> ignore (rejected Invalid_declaration (verify before live ns name)))
    [Type,"Hidden"; Value,"threshold"; Value,"accept"];
  let after = change write path (replace "type Id = String" "record Id { value: String }" shared) in
  ignore (rejected Different_kind (verify before after Type "Id"));
  ignore (rejected Different_kind (verify_same ~before ~after:live
    ~previous:(Type,"NotesSchema.V1.Shared.Payload") ~current:(Codec,"NotesSchema.VCurrent.Shared.Payload"))))

let nominal_identity () = with_project (fun root write ->
  let source = "module NotesSchema.VCurrent.Shared exposing []\n" ^ imports ^
    "type LeftId = String\ntype RightId = String\n" in
  let before, after, _ = fixture root write source in
  ignore (rejected Different_closure (verify_same ~before ~after
    ~previous:(Type,"NotesSchema.V1.Shared.LeftId") ~current:(Type,"NotesSchema.VCurrent.Shared.RightId")));
  ignore (equal (verify before after Type "LeftId"));
  ignore (equal (verify before after Type "RightId")))

let abi_and_family () = with_project (fun root write ->
  let before, _, path = fixture root write shared in
  let foreign_abi = load ~abi:"test-compiler-2" path in
  ignore (rejected Incompatible_inventories (verify before foreign_abi Type "Id"));
  check bool "candidate generation refuses instead of returning an empty list" true
    (Result.is_error (same_candidates ~before ~after:foreign_abi));
  let foreign = write "schema/other/v-current.tesl"
    ("module OtherSchema.VCurrent exposing []\n" ^ imports ^ "type Id = String\n") |> load in
  ignore (rejected Incompatible_inventories (verify_same ~before ~after:foreign
    ~previous:(Type,"NotesSchema.V1.Shared.Id") ~current:(Type,"OtherSchema.VCurrent.Id")));
  check bool "candidate generation refuses a different family" true
    (Result.is_error (same_candidates ~before ~after:foreign)))

let harmless_source_changes () = with_project (fun root write ->
  let before, live, path = fixture root write shared in
  let evidence = equal (verify before live Predicate "Positive") in
  let source = "# private schema comment λ\n" ^ shared
    |> replace "accept(n: Int)" "accept(input: Int)"
    |> replace "if n > threshold()" "if input > threshold()"
    |> replace "Something (n ::: Positive n)" "Something (input ::: Positive input)"
    |> replace "\n" "\r\n" in
  let after = change write path source in
  check string "alpha-renaming, comments, Unicode and CRLF preserve evidence" (same_digest evidence)
    (same_digest (equal (verify before after Predicate "Positive")));
  check (list string) "candidate inventory is invariant" (candidates before live) (candidates before after))

let recursive_closure () = with_project (fun root write ->
  let source = "module NotesSchema.VCurrent.Shared exposing []\n" ^ imports ^ {|type Tree
  = Leaf { text: String }
  | Branch { child: Maybe Tree }
codec Tree { adtJson }
record Holder { tree: Tree }
|} in
  let before, live, path = fixture root write source in
  ignore (equal (verify before live Type "Tree"));
  ignore (equal (verify before live Type "Holder"));
  let after = change write path (replace "text: String" "label: String" source) in
  ignore (rejected Different_closure (verify before after Type "Holder"));
  ignore (rejected Different_closure (verify before after Codec "Tree")))

let candidate_identity_and_order () = with_project (fun root write ->
  let before, live, path = fixture root write shared in
  let reordered = change write path (replace "type Id = String\n" "" shared ^ "type Id = String\n") in
  check (list string) "declaration order cannot reorder proposed Same entries"
    (get (same_candidates ~before ~after:live) |> List.map names)
    (get (same_candidates ~before ~after:reordered) |> List.map names);
  let renamed = change write path (replace "type Id = String" "type FreshId = String"
    (replace "exposing [Id," "exposing [FreshId," shared)) in
  let pairs = candidates before renamed in
  check int "no invented pairing for a removed and newly named type" 5 (List.length pairs);
  ignore (rejected Invalid_declaration (verify before renamed Type "Id")))

let retained_queries () =
  let enabled = !Query_cache.enabled in
  Query_cache.set_enabled true;
  Fun.protect ~finally:(fun () -> Query_cache.set_enabled enabled) (fun () ->
    changed_private_helper ();
    nested_adt ();
    harmless_source_changes ())

let () = run "migration-same" ["checked semantic equality", [
  test_case "complete private inventory and domain-separated evidence" `Quick complete_inventory;
  test_case "private helper change and precise source locations" `Quick changed_private_helper;
  test_case "fact owner body changes" `Quick changed_owner;
  test_case "added and removed private fact producers" `Quick added_and_removed_owner;
  test_case "unrelated helper does not invalidate an equal type" `Quick unrelated_changes;
  test_case "encoder, legacy decoder, pruning and forbidden direction" `Quick codec_directions;
  test_case "nested ADT closure reaches every parent codec" `Quick nested_adt;
  test_case "generic arguments and binder normalization" `Quick generic_adt;
  test_case "strict declaration kinds, namespaces and schema ownership" `Quick same_kind_and_scope;
  test_case "equal representations preserve distinct nominal identities" `Quick nominal_identity;
  test_case "compiler ABI and schema family refusal" `Quick abi_and_family;
  test_case "comments, local binders and source formatting" `Quick harmless_source_changes;
  test_case "recursive ADT and codec closure terminates" `Quick recursive_closure;
  test_case "candidate order and declaration identity" `Quick candidate_identity_and_order;
  test_case "retained editor query caches cannot hide changed dependencies" `Quick retained_queries;
]]
