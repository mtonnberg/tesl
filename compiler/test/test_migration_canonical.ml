open Alcotest
open Migration_canonical

let get = function Ok value -> value | Error message -> fail message

let wire_format () =
  List.iter (fun (value, expected) -> check Alcotest.string "canonical bytes" expected (encode value)) [
    Bytes "", "s0:";
    Seq [], "l0:";
    Bytes "å", "s2:å";
    Bytes "\000:sl\255", "s5:\000:sl\255";
    Seq [Bytes "a"; Seq [Bytes ""; Bytes ":"]], "l2:s1:al2:s0:s1::";
    Seq [Seq []; Bytes "l0:"], "l2:l0:s3:l0:";
  ];
  check Alcotest.string "domain envelope"
    "l4:s24:tesl-migration-canonicals1:1s8:snapshots0:"
    (encode (document Snapshot (Bytes "")))

let independent_vectors () =
  let cases = [
    "empty-string", Bytes "";
    "empty-list", Seq [];
    "unicode", string "å界\000e\204\129";
    "nested", Seq [Bytes "a"; Seq [Bytes ""; Bytes ":"]];
    "large-int", get (integer "000123456789012345678901234567890");
    "negative-zero", get (float (-0.));
    "old-reference", get (reference [{ family="NotesSchema"; revision="V7"; role=From_role }] "NotesSchema.V7.Checks.checkCount");
  ] in
  let hex text = String.to_seq text |> Seq.map (fun c -> Printf.sprintf "%02x" (Char.code c)) |> List.of_seq |> String.concat "" in
  let path = Filename.concat (Compile.default_root_path ()) "compiler/test/fixtures/migration-canonical-vectors.txt" in
  let lines = In_channel.with_open_text path In_channel.input_all |> String.split_on_char '\n' |> List.filter ((<>) "") in
  check int "golden inventory is complete" (List.length cases) (List.length lines);
  List.iter (fun line -> match String.split_on_char ' ' line with
    | [name; expected_wire; expected_hash] ->
      let value = List.assoc name cases in
      check Alcotest.string (name ^ " independent wire bytes") expected_wire (hex (encode (document Snapshot value)));
      check Alcotest.string (name ^ " independent SHA-256") expected_hash (digest Snapshot value)
    | _ -> fail "invalid canonical golden row") lines

let symbol_identity () =
  let scope revision role = { family="NotesSchema"; revision; role } in
  let ref scopes name = get (reference scopes name) |> encode in
  check Alcotest.string "snapshot freeze preserves identity"
    (ref [scope "VCurrent" Snapshot_role] "NotesSchema.VCurrent.Shared.Count")
    (ref [scope "V8" Snapshot_role] "NotesSchema.V8.Shared.Count");
  let current = [scope "V7" From_role; scope "VCurrent" To_role] in
  let frozen = [scope "V7" From_role; scope "V8" To_role] in
  check Alcotest.string "finished migration target rewrite preserves identity"
    (ref current "NotesSchema.VCurrent.checkCount") (ref frozen "NotesSchema.V8.checkCount");
  check Alcotest.bool "switching old to new helper changes identity" true
    (ref current "NotesSchema.V7.checkCount" <> ref current "NotesSchema.VCurrent.checkCount");
  check Alcotest.bool "moving helper between child modules changes identity" true
    (ref current "NotesSchema.V7.Left.check" <> ref current "NotesSchema.V7.Right.check");
  check Alcotest.string "a nested version-like prefix stays a global name"
    (encode (Seq [Bytes "global"; Seq (List.map bytes ["Wrapper"; "NotesSchema"; "VCurrent"; "value"])]))
    (ref current "Wrapper.NotesSchema.VCurrent.value");
  check Alcotest.string "migration helper namespace is not a schema revision"
    (encode (Seq [Bytes "global"; Seq (List.map bytes ["NotesSchema"; "Migrate"; "V8"; "helper"])]))
    (ref current "NotesSchema.Migrate.V8.helper");
  List.iter (fun name -> check Alcotest.bool ("unresolved or invalid: " ^ name) true (Result.is_error (reference current name)))
    ["NotesSchema.V9.Count"; "OtherSchema.VCurrent.Count"; "NotesSchema..Count"; "../Outside"; "Count"; "NotesSchema.V7.Count\000"];
  List.iter (fun scopes -> check Alcotest.bool "ambiguous scope refused" true
    (Result.is_error (reference scopes "NotesSchema.V7.Count"))) [
      [scope "V7" From_role; scope "V7" To_role];
      [scope "V7" From_role; scope "V8" From_role];
      [scope "V0" Snapshot_role];
      [scope "V2147483647" Snapshot_role];
      [{ family="NotesSchema.V7"; revision="V8"; role=Snapshot_role }];
    ]

let scalars_and_domains () =
  List.iter (fun (input, expected) -> check Alcotest.string "canonical integer" expected
    (match get (integer input) with Seq [Bytes "int"; Bytes value] -> value | _ -> fail "integer node")) [
    "0", "0"; "-0", "0"; "0000", "0"; "-0000", "0"; "-00042", "-42";
    "00123456789012345678901234567890", "123456789012345678901234567890";
  ];
  List.iter (fun input -> check Alcotest.bool "bad integer refused" true (Result.is_error (integer input)))
    [""; "-"; "+1"; " 1"; "1 "; "1.0"; "0x12"; "1_000"; "1\000"];
  List.iter (fun value -> check Alcotest.bool "non-finite float refused" true (Result.is_error (float value)))
    [Float.nan; Float.infinity; Float.neg_infinity];
  check Alcotest.bool "negative float zero is retained" true (float (-0.) <> float 0.);
  check Alcotest.bool "no Unicode normalization" true (string "é" <> string "e\204\129");
  let payload = Seq [get (integer "1"); get (float 1.); string "1"; bool true] in
  let hashes = List.map (fun domain -> digest domain payload) [Snapshot; Migration; Same; Repair; Contract; Provenance] in
  check int "domain separation" 6 (List.length (List.sort_uniq String.compare hashes))

let injectivity () =
  (* Independent parser of the specified wire format, rather than a second call
     to encode. Binary/delimiter-heavy random trees exercise length boundaries. *)
  let decode source =
    let offset = ref 0 in
    let rec read () =
      let tag = source.[!offset] in
      incr offset;
      let colon = String.index_from source !offset ':' in
      let count = int_of_string (String.sub source !offset (colon - !offset)) in
      offset := colon + 1;
      match tag with
      | 's' -> let value = String.sub source !offset count in offset := !offset + count; Bytes value
      | 'l' -> Seq (List.init count (fun _ -> read ()))
      | _ -> fail "bad wire tag" in
    let result = read () in
    check int "no trailing bytes" (String.length source) !offset;
    result in
  let rng = Random.State.make [|2026;9;5|] in
  let rec generate depth =
    if depth = 0 || Random.State.bool rng then
      Bytes (String.init (Random.State.int rng 130) (fun _ -> Char.chr (Random.State.int rng 256)))
    else Seq (List.init (Random.State.int rng 5) (fun _ -> generate (depth - 1))) in
  for _ = 1 to 500 do
    let original = generate 4 in
    check Alcotest.bool "independent decoding recovers exact tree" true (decode (encode original) = original)
  done

let typed_node_identity () =
  let source = {|module TypedMigrationInput exposing []
import Tesl.Prelude exposing [Int, String, Bool]
import Tesl.Maybe exposing [Maybe(..)]
fn emptyNumber() -> Maybe Int = Nothing
fn emptyText() -> Maybe String = Nothing
fn fromContext(flag: Bool) -> Maybe Int =
  let candidate = if flag then
    Nothing
  else
    Something 1
  candidate
fn polymorphicLet() -> Maybe Int =
  let candidate = Nothing
  candidate
|} in
  let parsed = match Parser.parse_module "<typed-migration>" source with
    | Ok m -> m | Err e -> fail e.msg in
  (* The tested nodes deliberately share a source span. A position-indexed elaborator
     would merge the two Nothing expressions and corrupt one function's type. *)
  let shared = Location.dummy_loc "<typed-migration>" in
  let rec same_location e =
    match Ast_visitor.map_children same_location e with
    | Ast.EConstructor c -> Ast.EConstructor { c with loc = shared }
    | Ast.EVar v -> Ast.EVar { v with loc = shared }
    | Ast.ELet l -> Ast.ELet { l with loc = shared }
    | Ast.EIf i -> Ast.EIf { i with loc = shared }
    | other -> other in
  let m = { parsed with decls = List.map (function
    | Ast.DFunc fd -> Ast.DFunc { fd with body = same_location fd.body }
    | other -> other) parsed.decls } in
  let nodes, errors = Checker.check_module_with_typed_nodes m in
  check int "typed fixture passes ordinary type checking" 0 (List.length errors);
  let functions = List.filter_map (function Ast.DFunc fd -> Some (fd.name, fd.body) | _ -> None) m.decls in
  let expect_node label expression expected =
    let types = List.filter_map (fun (node, ty) -> if node == expression then Some ty else None) nodes in
    check Alcotest.bool (label ^ " was retained by identity") true (types <> []);
    List.iter (fun ty -> check Alcotest.string (label ^ " uses final function-local substitution") expected (Type_system.pp_ty ty)) types in
  expect_node "numeric Nothing" (List.assoc "emptyNumber" functions) "Maybe Int";
  expect_node "text Nothing" (List.assoc "emptyText" functions) "Maybe String";
  (match List.assoc "fromContext" functions with
   | Ast.ELet { value; body; _ } ->
     expect_node "inferred let value" value "Maybe Int";
     expect_node "inferred let use" body "Maybe Int";
     (match value with
      | Ast.EIf { then_; _ } -> expect_node "earlier branch after later unification" then_ "Maybe Int"
      | _ -> fail "fixture lost its conditional")
   | _ -> fail "fixture lost its let");
  (match List.assoc "polymorphicLet" functions with
   | Ast.ELet { value; body; _ } ->
     expect_node "specialized use of polymorphic binding" body "Maybe Int";
     let value_types = List.filter_map (fun (node, ty) -> if node == value then Some ty else None) nodes in
     check Alcotest.bool "let-generalized value retains its type variable" true
       (value_types <> [] && List.for_all (function
          | Type_system.TApp (TCon "Maybe", TVar _) -> true | _ -> false) value_types)
   | _ -> fail "fixture lost its polymorphic let")

let () = run "migration-canonical" ["format 1", [
  test_case "specified wire bytes" `Quick wire_format;
  test_case "independent serialization and SHA-256 vectors" `Quick independent_vectors;
  test_case "schema roles and freeze invariance" `Quick symbol_identity;
  test_case "literal normal forms and hash domains" `Quick scalars_and_domains;
  test_case "binary-tree injectivity against independent decoder" `Quick injectivity;
  test_case "typed IR keeps node identity and final local substitutions" `Quick typed_node_identity;
]]
