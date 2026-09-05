open Ast
open Migration_canonical
open Migration_ir
open Alcotest

let imports =
  "import Tesl.Prelude exposing [Int, String, Bool, List]\n" ^
  "import Tesl.Maybe exposing [Maybe(..)]\n" ^
  "import Tesl.Float exposing [Float]\n" ^
  "import Tesl.Json exposing [intCodec, stringCodec]\n"

let prefix revision = "module NotesSchema." ^ revision ^ " exposing []\n" ^ imports

let parsed_complete source =
  let file = "<migration-ir>" in
  let diags = Compile.check_source file source |> List.filter (fun (d : Compile.diagnostic) -> d.severity = "error") in
  if diags <> [] then fail (Compile.diagnostics_to_json diags);
  match Parser.parse_module file source with Ok m -> m | Err e -> fail e.msg

let parsed ?(revision="VCurrent") source = parsed_complete (prefix revision ^ source)

(* Test resolver is deliberately explicit: production resolution must supply a
   declaration identity or a versioned primitive tag, never guess from a name. *)
let resolver m ns name =
  let member = List.exists (function
    | DFunc f -> ns = Value && f.name = name
    | DType (TypeNewtype t) -> (ns = Type || ns = Value) && t.name = name
    | DType (TypeAdt t) -> (ns = Type && t.name = name) || (ns = Value && List.exists (fun (v : adt_variant) -> v.ctor = name) t.variants)
    | DRecord r -> (ns = Type || ns = Value) && r.name = name
    | DEntity e -> (ns = Type || ns = Value) && e.name = name
    | DFact f -> ns = Predicate && f.name = name
    | DCodec c -> ns = Codec && c.name = name
    | _ -> false) m.decls in
  if member then Some (Global (m.module_name ^ "." ^ name))
  else match ns, name with
    | Type, ("Int" | "String" | "Bool" | "Float" | "Maybe" | "List" | "Unit")
    | Value, ("Something" | "Nothing" | "True" | "False") -> Some (Primitive ("core/" ^ name ^ "/1"))
    | Codec, ("intCodec" | "stringCodec") -> Some (Primitive ("core/" ^ name ^ "/1"))
    | _ -> None

let elaborate ?resolve ?nodes m decl =
  let typed_nodes = match nodes with Some ns -> ns | None ->
    let ns, errors = Checker.check_module_with_typed_nodes m in
    if errors <> [] then fail "typed IR fixture must pass checking";
    ns in
  let resolve = Option.value resolve ~default:(resolver m) in
  let revision = List.nth (String.split_on_char '.' m.module_name) 1 in
  Migration_ir.declaration ~scopes:[{family="NotesSchema"; revision; role=Snapshot_role}]
    ~resolve ~typed_nodes ~module_name:m.module_name decl

let get = function Ok x -> x | Error e -> fail e.message
let encoded m = List.map (fun d -> encode (get (elaborate m d)).node) m.decls
let fingerprint source = encoded (parsed source)
let different label a b = check bool label true (fingerprint a <> fingerprint b)

let source_invariance () =
  let source = "fn compute(n: Int) -> Int =\n  let doubled = n * 2\n  doubled + 1\n" in
  let base = fingerprint source in
  List.iter (fun variant -> check (list string) "comments, layout and local spelling are not semantics" base (fingerprint variant)) [
    "# leading\nfn compute(n: Int) -> Int =\n  # private note\n  let doubled = n * 2\n  doubled + 1\n";
    "fn compute(input: Int) -> Int =\n  let result = input * 2\n  result + 1\n";
    "fn compute(n: Int) -> Int =\n    let doubled = n * 2\n    doubled + 1\n";
  ];
  check (list string) "freezing alpha-renames only the version" base (encoded (parsed ~revision:"V8" source));
  let m = parsed source in
  let d = List.hd m.decls in
  let ns, _ = Checker.check_module_with_typed_nodes m in
  let relocated = List.map (fun (node, ty) -> node, ty) ns in
  check string "the AST object's identity, not a source reparse, indexes types"
    (encode (get (elaborate ~nodes:ns m d)).node)
    (encode (get (elaborate ~nodes:relocated m d)).node)

let behavior_mutations () =
  List.iter (fun (a,b) -> different "semantic mutation changes node" a b) [
    "fn calc(n: Int) -> Int = n + 1\n", "fn calc(n: Int) -> Int = n - 1\n";
    "fn calc(n: Int) -> Int = n + 1\n", "fn calc(n: Int) -> Int = n + 2\n";
    "fn calc(x: Int, y: Int) -> Int = x - y\n", "fn calc(x: Int, y: Int) -> Int = y - x\n";
    "fn calc(x: Bool) -> Int =\n  if x then\n    1\n  else\n    2\n", "fn calc(x: Bool) -> Int =\n  if x then\n    2\n  else\n    1\n";
    "fn calc() -> String = \"é\"\n", "fn calc() -> String = \"é\"\n";
    "fn calc() -> Float = 0.0\n", "fn calc() -> Float = -0.0\n";
    "fn calc() -> List Int = [1, 2]\n", "fn calc() -> List Int = [2, 1]\n";
    "fn calc(n: Int) -> String = \"x${n}\"\n", "fn calc(n: Int) -> String = \"y${n}\"\n";
    "fn calc() -> Maybe Int = Nothing\n", "fn calc() -> Maybe String = Nothing\n";
    "type Count = Int\n", "type Count = String\n";
    "record Pair { first: Int, second: Int }\n", "record Pair { first: Int, second: String }\n";
  ]

let checker_variable_invariance () =
  let m = parsed "fn empty() -> Maybe Int =\n  let value = Nothing\n  value\n" in
  let decl = List.hd m.decls in
  let ns, _ = Checker.check_module_with_typed_nodes m in
  let rec renumber = function
    | Type_system.TVar n -> Type_system.TVar (n * 31 + 919)
    | TApp (a,b) -> TApp (renumber a, renumber b)
    | TFun (a,b) -> TFun (renumber a, renumber b)
    | TCon _ as t -> t in
  let changed = List.map (fun (e,t) -> e, renumber t) ns in
  check string "fresh IDs cannot affect persistent hashes"
    (encode (get (elaborate ~nodes:ns m decl)).node)
    (encode (get (elaborate ~nodes:changed m decl)).node);
  check (list string) "generic declared variables retain structural identity"
    (fingerprint "fn identity(value: a) -> a = value\n")
    (fingerprint "fn identity(input: b) -> b = input\n")

let references_are_resolved () =
  let m = parsed "fn helper(n: Int) -> Int = n + 1\nfn caller(n: Int) -> Int = helper n\n" in
  let d = List.nth m.decls 1 in
  let before = get (elaborate m d) in
  check bool "private helper enters semantic dependency inventory" true
    (List.mem (Value, Global "NotesSchema.VCurrent.helper") before.references);
  let alternate ns name = if ns = Value && name = "helper" then Some (Global "NotesSchema.VCurrent.Other.helper") else resolver m ns name in
  let after = get (elaborate ~resolve:alternate m d) in
  check bool "same leaf spelling with a different owner is different" true (before.node <> after.node);
  let altered_primitive ns name = if ns = Type && name = "Int" then Some (Primitive "core/Int/2") else resolver m ns name in
  check bool "primitive semantic version participates in identity" true (before.node <> (get (elaborate ~resolve:altered_primitive m d)).node)

let proof_behavior () =
  let source threshold = "fact Positive (n: Int)\ncheck validate(n: Int) -> n: Int ::: Positive n =\n  if n > " ^ threshold ^ " then\n    ok n ::: Positive n\n  else\n    fail 400 \"not positive\"\n" in
  let m = parsed (source "0") in
  let encoded = get (elaborate m (List.nth m.decls 1)) in
  check bool "minted fact is a semantic dependency" true
    (List.mem (Predicate, Global "NotesSchema.VCurrent.Positive") encoded.references);
  different "changed mint condition changes behavior" (source "0") (source "1");
  different "changed rejection status changes behavior" (source "0")
    (Str.global_replace (Str.regexp_string "fail 400") "fail 422" (source "0"))

let patterns_and_lambdas () =
  let source = {|type Choice
  = Picked Int
  | Empty
fn select(choice: Choice) -> Int =
  case choice of
    Picked amount -> amount
    Empty -> 0
fn wrap(n: Int) -> Choice = Picked n
fn apply(n: Int) -> Int =
  let increment = fn(value: Int) -> value + 1
  increment n
|} in
  let base = fingerprint source in
  check int "every pure declaration was elaborated" 4 (List.length base);
  List.iter (fun (old_,new_) -> different "pattern/lambda mutation changes behavior" source
    (Str.global_replace (Str.regexp_string old_) new_ source)) [
      "Empty -> 0", "Empty -> 1"; "amount -> amount", "amount -> amount + 1"; "value + 1", "value - 1";
    ];
  check (list string) "pattern binder alpha-renaming" base (fingerprint (Str.global_replace (Str.regexp_string "amount") "payload" source))

let no_incomplete_hashes () =
  let m = parsed "fn calc(n: Int) -> Int = n + 1\n" in
  let d = List.hd m.decls in
  let expect_error label result = match result with Error _ -> () | Ok _ -> fail (label ^ " unexpectedly hashed") in
  expect_error "missing inferred nodes" (elaborate ~nodes:[] m d);
  expect_error "unresolved primitive" (elaborate ~resolve:(fun _ _ -> None) m d);
  let ns, _ = Checker.check_module_with_typed_nodes m in
  let node = fst (List.hd ns) in
  expect_error "conflicting type observations" (elaborate ~nodes:((node, Type_system.TCon "String") :: ns) m d);
  let invalid ns name = if ns = Type && name = "Int" then Some (Global "Int") else resolver m ns name in
  expect_error "non-qualified global" (elaborate ~resolve:invalid m d);
  let empty_tag ns name = if ns = Type && name = "Int" then Some (Primitive "") else resolver m ns name in
  expect_error "empty primitive tag" (elaborate ~resolve:empty_tag m d);
  let f = match d with DFunc f -> f | _ -> fail "fixture" in
  List.iter (fun kind -> expect_error "application function" (elaborate m (DFunc {f with kind})))
    [HandlerKind; AuthKind; WorkerKind; DeadWorkerKind; MainKind];
  expect_error "capability" (elaborate m (DFunc {f with capabilities=["dbRead"]}));
  let e = ETelemetry {name="leak"; fields=[]; loc=f.loc} in
  expect_error "ambient telemetry" (elaborate ~nodes:[e, Type_system.TCon "Unit"] m (DFunc {f with body=e}))

let semantic_closures () =
  let source threshold extra = "fact Positive (n: Int)\nfn minimum() -> Int = " ^ threshold ^ "\n" ^
    "check validate(n: Int) -> n: Int ::: Positive n =\n  if n > minimum() then\n    ok n ::: Positive n\n  else\n    fail 400 \"bad\"\n" ^ extra in
  let build ?(revision="VCurrent") source =
    let m = parsed ~revision source in
    let nodes, errors = Checker.check_module_with_typed_nodes m in
    check int "closure fixture types" 0 (List.length errors);
    let scopes = [{family="NotesSchema"; revision; role=Snapshot_role}] in
    let defs = List.map (fun d -> get (Migration_ir.define ~scopes ~resolve:(resolver m) ~typed_nodes:nodes m d)) m.decls in
    let root = Predicate, Global (m.module_name ^ ".Positive") in
    scopes, defs, root in
  let scopes, defs, root = build (source "0" "") in
  let close defs = get (Migration_ir.closure ~scopes ~definitions:defs ~roots:[root]) in
  let base = close defs in
  check bool "inventory order does not move closure hash" true (base = close (List.rev defs));
  let frozen_scopes, frozen, frozen_root = build ~revision:"V8" (source "0" "") in
  check bool "full fact/check/helper cycle freezes identically" true
    (base = get (Migration_ir.closure ~scopes:frozen_scopes ~definitions:frozen ~roots:[frozen_root]));
  let _, changed, _ = build (source "1" "") in
  check bool "unchanged fact/check observes a transitive helper edit" true (base <> close changed);
  let _, unrelated, _ = build (source "0" "fn unrelated() -> String = \"noise\"\n") in
  check bool "unreachable pure helper stays outside the fact closure" true (base = close unrelated);
  let second = "check another(n: Int) -> n: Int ::: Positive n =\n  if n > 100 then\n    ok n ::: Positive n\n  else\n    fail 400 \"bad\"\n" in
  let _, extra_owner, _ = build (source "0" second) in
  check bool "every additional minting check enters the fact closure" true (base <> close extra_owner);
  let expect_refusal label defs = match Migration_ir.closure ~scopes ~definitions:defs ~roots:[root] with
    | Error _ -> () | Ok _ -> fail (label ^ " received an incomplete closure") in
  expect_refusal "missing helper" (List.filter (fun d -> d.key <> (Value, Global "NotesSchema.VCurrent.minimum")) defs);
  expect_refusal "duplicate definition" (List.hd defs :: defs)

let catalog_and_codecs () =
  let entity = {|entity Note table "notes" primaryKey id {
  id: String @db(text)
  alternate: String @db(text)
  title: String @db(text)
  index [title] as "notes_title"
}
|} in
  List.iter (fun (old_,new_) -> different "catalog mapping mutation" entity
    (Str.global_replace (Str.regexp_string old_) new_ entity)) [
      "table \"notes\"", "table \"other_notes\""; "primaryKey id", "primaryKey alternate";
      "index [title]", "unique index [title]"; "index [title]", "index [id, title]";
      "notes_title", "notes_by_title"; "title: String @db(text)", "title: String @db(varchar)";
    ];
  let codec = {|record Counter { count: Int }
codec Counter {
  toJson { count -> "count" with_codec intCodec }
  fromJson [ { count <- "count" with_codec intCodec } ]
}
fn make(n: Int) -> Counter = Counter { count: n }
fn value(c: Counter) -> Int = c.count
fn add(a: Int, b: Int) -> Int = a + b
fn sum(n: Int) -> Int = add n 2
|} in
  let m = parsed codec in
  check int "records, codecs, fields and multi-argument calls elaborate" 6 (List.length (encoded m));
  let type_closure source =
    let m = parsed source in
    let nodes, _ = Checker.check_module_with_typed_nodes m in
    let scopes = [{family="NotesSchema"; revision="VCurrent"; role=Snapshot_role}] in
    let defs = List.map (fun d -> get (Migration_ir.define ~scopes ~resolve:(resolver m) ~typed_nodes:nodes m d)) m.decls in
    get (Migration_ir.closure ~scopes ~definitions:defs ~roots:[Type, Global (m.module_name ^ ".Counter")]) in
  let base = type_closure codec in
  List.iter (fun (old_,new_) ->
    let changed = Str.global_replace (Str.regexp_string old_) new_ codec in
    check bool "type closure includes its codec's wire behavior" true (base <> type_closure changed)) [
      "-> \"count\"", "-> \"total\""; "<- \"count\"", "<- \"total\"";
      "count <- \"count\" with_codec intCodec", "count <- default 0";
    ]

let independent_typed_golden () =
  let relative = "fixtures/migration-ir-vectors.txt" in
  let path = if Sys.file_exists relative then relative else "test/" ^ relative in
  let rows = In_channel.with_open_text path In_channel.input_all |> String.split_on_char '\n'
    |> List.filter (fun line -> line <> "" && not (String.starts_with ~prefix:"#" line)) in
  let hex bytes = String.to_seq bytes |> List.of_seq |> List.map (fun c -> Printf.sprintf "%02x" (Char.code c)) |> String.concat "" in
  List.iter (fun row -> match String.split_on_char ' ' row with
    | ["increment"; expected_hash; expected_document] ->
      List.iter (fun revision ->
        let m = parsed ~revision "fn increment(n: Int) -> Int = n + 1\n" in
        let node = (get (elaborate m (List.hd m.decls))).node in
        check string "independent typed document bytes" expected_document (hex (encode (document Same node)));
        check string "independent typed document hash" expected_hash (digest Same node)
      ) ["VCurrent"; "V8"]
    | _ -> fail "invalid independent typed golden") rows;
  check int "golden cannot silently disappear" 1 (List.length rows)

let optional_source = {|fact Positive (n: Int)
establish tryPositive(n: Int) -> Maybe (v: Int ::: Positive v) =
  if n > 0 then
    Something (n ::: Positive n)
  else
    Nothing
check validate(n: Int) -> value: Int ::: Positive value =
  case tryPositive n of
    Nothing -> fail 400 "not positive"
    Something validated ->
      let (value ::: evidence) = validated
      ok value ::: evidence
check relay(n: Int) -> value: Int ::: Positive value =
  let (value ::: evidence) = check validate n
  ok value ::: evidence
|}

let roadmap_establish_source () =
  let path = Filename.concat (Compile.default_root_path ()) "roadmap/next/database-migrations.md" in
  let document = In_channel.with_open_text path In_channel.input_all in
  let first = Str.search_forward (Str.regexp_string "# in schema module ShopSchema.V8") document 0 in
  let last = Str.search_forward (Str.regexp_string "# in the migration file") document first in
  String.sub document first (last - first)

let optional_proof_and_decomposition () =
  let source = optional_source in
  let base = fingerprint source in
  check int "optional establish and decomposition elaborate" 4 (List.length base);
  check (list string) "renaming an evidence binder retains identity" base
    (fingerprint (Str.global_replace (Str.regexp_string "evidence") "witness" source));
  different "optional establish condition belongs to semantic identity" source
    (Str.global_replace (Str.regexp_string "n > 0") "n > 1" source);
  ignore (parsed (roadmap_establish_source ()))

let optional_establish_refusals () =
  let facts = "fact Positive (n: Int)\nfact Small (n: Int)\n" in
  let candidate ?(proof="Positive result") body = facts ^
    "establish candidate(n: Int, other: Int) -> Maybe (result: Int ::: " ^ proof ^ ") =\n" ^ body ^ "\n" in
  ignore (parsed (candidate "  Something (n ::: Positive n)"));
  ignore (parsed (candidate ~proof:"Positive result && Small result" "  Something (n ::: Small n && Positive n)"));
  List.iter (fun (label, source) ->
    (match Parser.parse_module "<optional-negative>" (prefix "VCurrent" ^ source) with
     | Ok _ -> () | Err e -> fail (label ^ ": invalid negative fixture: " ^ e.msg));
    let errors = Compile.check_source "<optional-negative>" (prefix "VCurrent" ^ source)
      |> List.filter (fun (d : Compile.diagnostic) -> d.severity = "error") in
    if errors = [] then fail (label ^ " forged an optional proof")) [
      "raw payload", candidate "  Something n";
      "wrong predicate", candidate "  Something (n ::: Small n)";
      "wrong subject", candidate "  Something (n ::: Positive other)";
      "missing conjunct", candidate ~proof:"Positive result && Small result" "  Something (n ::: Positive n)";
      "branch without proof", candidate "  if n > 0 then\n    Something (n ::: Positive n)\n  else\n    Something other";
      "let-hidden raw success", candidate "  let result = Something n\n  result";
      "keyword ok is HTTP-shaped", candidate "  Something (ok n ::: Positive n)";
      "HTTP failure", candidate "  if n > 0 then\n    Something (n ::: Positive n)\n  else\n    fail 400 \"bad\"";
      "fn boundary cannot mint", Str.global_replace (Str.regexp_string "establish candidate") "fn candidate"
        (candidate "  Something (n ::: Positive n)");
      "discarded proof cannot validate another value", candidate "  let proven = n ::: Positive n\n  Something other";
    ]

let optional_establish_runtime () =
  let source = Str.global_replace (Str.regexp_string "NotesSchema.VCurrent") "OptionalEstablish"
    (prefix "VCurrent" ^ optional_source ^ roadmap_establish_source () ^ {|
fn consume(value: Int ::: Positive value) -> Int = value
fn execute(n: Int) -> Int =
  case tryPositive n of
    Nothing -> 0
    Something validated ->
      let (value ::: evidence) = validated
      consume (value ::: evidence)
test "optional establish preserves real values and rejects absent evidence" {
  expect execute 7 == 7
  expect execute 2147483648 == 2147483648
  expect execute 0 == 0
  expect execute (-9) == 0
  expect tryPositive 7 == Something 7
  expect tryPositive 0 == Nothing
  let value = check relay 5
  expect value == 5
  expect tryNonNegative 0 == Something 0
  expect tryNonNegative (-1) == Nothing
  let nonNegative = check checkNonNegative 0
  expect nonNegative == 0
  expectFail check checkNonNegative (-1)
}
|}) in
  let artifacts = match Compile.compile_go_source "optional-establish.tesl" source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure errors -> fail (Compile.diagnostics_to_json errors) in
  let root = Filename.temp_dir "tesl-optional-establish-" "" in
  let rec mkdir path = if not (Sys.file_exists path) then (mkdir (Filename.dirname path); Unix.mkdir path 0o700) in
  let rec remove path =
    if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
    end else Sys.remove path in
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    List.iter (fun (a : Emit_go.artifact) ->
      let path = Filename.concat root a.path in mkdir (Filename.dirname path);
      Out_channel.with_open_bin path (fun channel -> output_string channel a.contents)) artifacts;
    let log = Filename.concat root "go-test.log" in
    let command = Printf.sprintf "cd %s && timeout 90s go test -timeout=60s -count=1 -v ./... > %s 2>&1"
      (Filename.quote root) (Filename.quote log) in
    let status = Sys.command command in
    let output = In_channel.with_open_text log In_channel.input_all in
    if status <> 0 then fail output;
    check bool "generated test actually ran" true
      (try ignore (Str.search_forward (Str.regexp_string "--- PASS:") output 0); true with Not_found -> false))

let optional_witness_scopes () =
  let nested = {|
check nested(n: Int, other: Int) -> value: Int ::: Positive value =
  case tryPositive n of
    Nothing -> fail 400 "first"
    Something first ->
      let (firstValue ::: firstProof) = first
      case tryPositive other of
        Nothing -> fail 400 "second"
        Something second ->
          let (value ::: evidence) = second
          ok value ::: evidence
|} in
  let aliases = {|
check aliases(n: Int) -> value: Int ::: Positive value =
  case tryPositive n of
    Nothing -> fail 400 "absent"
    Something validated ->
      let (first ::: evidence) = validated
      let second = first
      let value = second
      ok value ::: evidence
|} in
  let branches = {|
check branches(n: Int, other: Int) -> value: Int ::: Positive value =
  if n > 0 then
    let (value ::: evidence) = check validate n
    ok value ::: evidence
  else
    let (value ::: evidence) = check validate other
    ok value ::: evidence
|} in
  let pairs = {|
fact Small (n: Int)
establish tryBoth(n: Int) -> Maybe (v: Int ::: Positive v && Small v) =
  Something (n ::: Positive n && Small n)
check both(n: Int) -> value: Int ::: Positive value && Small value =
  case tryBoth n of
    Nothing -> fail 400 "absent"
    Something validated ->
      let (value ::: evidence) = validated
      ok value ::: evidence
|} in
  let replace old_ new_ = Str.global_replace (Str.regexp_string old_) new_ in
  let projected = pairs
    |> replace "check both(n: Int) -> value: Int ::: Positive value && Small value"
       "check both(n: Int) -> value: Int ::: Small value"
    |> replace "let (value ::: evidence) = validated" "let (value ::: positive && small) = validated"
    |> replace "ok value ::: evidence" "ok value ::: small" in
  let transformed = {|
check shifted(n: Int) -> value: Int ::: Positive value =
  let value = n + 1
  ok value ::: Positive value
check twoResults(n: Int) -> value: Int ::: Positive value =
  let (first ::: firstProof) = check validate n
  let (value ::: evidence) = check shifted n
  ok value ::: evidence
|} in
  let authenticated = {|
fact Authenticated (n: Int)
auth authenticate(request: HttpRequest) -> identity: Int ::: Positive identity && Authenticated identity =
  let n = 7
  case tryPositive n of
    Nothing -> fail 401 "absent"
    Something validated ->
      let (value ::: evidence) = validated
      ok value ::: evidence && Authenticated identity
|} in
  (* These are application consumers of optional schema proofs. In particular,
     auth functions belong outside schema modules; a schema-boundary diagnostic
     must not mask the subject-binding rejection this matrix is checking. *)
  let scope_source source = "module ProofConsumers exposing []\n" ^ imports ^
    "import Tesl.Http exposing [HttpRequest]\n" ^ optional_source ^ source in
  List.iter (fun source -> ignore (parsed_complete (scope_source source)))
    [nested; aliases; branches; pairs; projected; transformed; authenticated];
  List.iter (fun (label, source) ->
    let source = scope_source source in
    (match Parser.parse_module "<witness-scope>" source with
     | Ok _ -> () | Err e -> fail (label ^ ": malformed fixture: " ^ e.msg));
    let errors = Compile.check_source "<witness-scope>" source
      |> List.filter (fun (d : Compile.diagnostic) -> d.severity = "error") in
    if errors = [] then fail (label ^ " accepted evidence from another subject or scope");
    check bool (label ^ " fails at a proof gate") true
      (List.exists (fun (d : Compile.diagnostic) ->
        try ignore (Str.search_forward (Str.regexp_case_fold "proof\\|witness\\|attached") d.message 0); true
        with Not_found -> false) errors)) [
      "nested Maybe subjects", replace "ok value ::: evidence" "ok value ::: firstProof" nested;
      "arithmetic creates a different subject", replace "let value = second" "let value = second + 1" aliases;
      "witness does not escape a sibling branch", replace
        "let (value ::: evidence) = check validate other" "let value = other" branches;
      "a conjunction cannot lose its second fact", replace
        "Something (n ::: Positive n && Small n)" "Something (n ::: Positive n)" pairs;
      "projection retains only the chosen conjunct", replace "ok value ::: small" "ok value ::: positive" projected;
      "check outputs do not share their first argument's subject", replace "ok value ::: evidence" "ok value ::: firstProof" transformed;
      "auth cannot transfer its witness to a computed identity", replace "ok value ::: evidence" "ok (value + 1) ::: evidence" authenticated;
    ]

let typed_nodes_after_cached_query () =
  let previous = !Query_cache.enabled in
  Query_cache.set_enabled true;
  Fun.protect ~finally:(fun () -> Query_cache.set_enabled previous) (fun () ->
    let source = "fn compute(input: Int) -> Int =\n  let doubled = input * 2\n  doubled + 1\n" in
    let m = parsed source in
    ignore (Checker.check_module_with_metadata m);
    let hits = !Query_cache.hits in
    ignore (Checker.check_module_with_metadata m);
    check bool "fixture warms the read-only metadata cache" true (!Query_cache.hits > hits);
    List.iter (fun ast ->
      let nodes, errors = Checker.check_module_with_typed_nodes ast in
      check int "typed collection has no errors" 0 (List.length errors);
      check bool "cache hit cannot skip typed-node collection" true (nodes <> []);
      List.iter (fun decl -> ignore (get (elaborate ~nodes ast decl))) ast.decls)
      [m; parsed source])

let () = run "migration typed IR" ["semantic nodes", [
  test_case "typed nodes survive warmed editor metadata caches" `Quick typed_nodes_after_cached_query;
  test_case "freeze, formatting and local alpha-renaming" `Quick source_invariance;
  test_case "behavior mutation matrix" `Quick behavior_mutations;
  test_case "checker fresh-variable allocation is irrelevant" `Quick checker_variable_invariance;
  test_case "resolved helper and primitive dependencies" `Quick references_are_resolved;
  test_case "proof minting and rejection behavior" `Quick proof_behavior;
  test_case "constructor patterns and first-class functions" `Quick patterns_and_lambdas;
  test_case "refuse incomplete or effectful inputs" `Quick no_incomplete_hashes;
  test_case "transitive fact owners, cycles and complete closure" `Quick semantic_closures;
  test_case "catalog mappings, codec reverse dependencies and call spines" `Quick catalog_and_codecs;
  test_case "independent typed-node wire and SHA-256 golden" `Quick independent_typed_golden;
  test_case "optional establish, proof decomposition and checked calls" `Quick optional_proof_and_decomposition;
  test_case "optional establish refuses false, partial and misplaced evidence" `Quick optional_establish_refusals;
  test_case "optional establish compiles and runs with proof-requiring callers" `Quick optional_establish_runtime;
  test_case "optional witnesses retain subjects and lexical branch scope" `Quick optional_witness_scopes;
]]
