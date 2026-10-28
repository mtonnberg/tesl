open Alcotest

let rec remove path =
  if Sys.is_directory path then begin
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  end else Sys.remove path

let with_project f =
  let root = Filename.temp_dir "tesl-qualified-predicates-" "" in
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let write name source =
      let path = Filename.concat root name in
      let rec mkdir dir = if not (Sys.file_exists dir) then begin mkdir (Filename.dirname dir); Unix.mkdir dir 0o700 end in
      mkdir (Filename.dirname path);
      Out_channel.with_open_bin path (fun out -> output_string out source);
      path in
    ignore (write "tesl.toml" ""); f write)

let imports = "import Tesl.Prelude exposing [String, Int, Fact, List, Bool(..), attachFact]\nimport Tesl.Maybe exposing [Maybe(..)]\nimport Tesl.List exposing [List.length]\n"
let owner name = "module " ^ name ^ " exposing [Valid, trust, evidence, sink, factSink, count, Box, Envelope(..)]\n" ^ imports ^ {|
fact Valid (value: String)
check trust(value: String) -> value: String ::: Valid value = ok value ::: Valid value
establish evidence(value: String) -> Fact (Valid value) = Valid value
fn sink(value: String ::: Valid value) -> String = value
fn factSink(value: String, proof: Fact (Valid value)) -> String = attachFact value proof
fn count(values: List String ::: ForAll (Valid) values) -> Int = List.length values
record Box { title: String ::: Valid title }
type Envelope = Wrapped title: String ::: Valid title
|}
let setup write =
  ignore (write "old-owner.tesl" (owner "OldOwner"));
  ignore (write "new-owner.tesl" (owner "NewOwner"))
let app body = "module App exposing []\n" ^ imports ^ "import OldOwner\nimport NewOwner\n" ^ body
let errors path = Compile.check_file path |> List.filter (fun (d : Compile.diagnostic) -> d.severity = "error")
let accepted path = match errors path with
  | [] -> ()
  | diagnostics -> fail (String.concat "\n" (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
let rejected path =
  (match Parser.parse_module path (In_channel.with_open_bin path In_channel.input_all) with
   | Ok _ -> () | Err error -> fail ("fixture must parse: " ^ error.msg));
  let diagnostics = errors path in
  if diagnostics = [] then fail "cross-owner proof unexpectedly accepted";
  let messages = String.concat "\n" (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics) in
  let relevant = Str.regexp_case_fold "proof\\|fact\\|cannot unify\\|type mismatch" in
  if not (try ignore (Str.search_forward relevant messages 0); true with Not_found -> false)
  then fail ("expected an ownership/proof/type rejection: " ^ messages)
let scenario body expected () = with_project (fun write ->
  setup write; expected (write "app.tesl" (app body)))
let rejected_pair body () = with_project (fun write ->
  setup write;
  let control = Str.global_replace (Str.regexp_string "NewOwner") "OldOwner" body in
  accepted (write "app.tesl" (app control));
  rejected (write "app.tesl" (app body)))

let independently_proven = scenario {|
fn previous(value: String) -> String =
  let oldValue = check OldOwner.trust value
  OldOwner.sink oldValue
fn current(value: String) -> String =
  let newValue = check NewOwner.trust value
  NewOwner.sink newValue
fn previousFact(value: String) -> Fact (OldOwner.Valid value) = OldOwner.evidence value
fn currentFact(value: String) -> Fact (NewOwner.Valid value) = NewOwner.evidence value
fn readPrevious(box: OldOwner.Box) -> String = OldOwner.sink box.title
fn readCurrent(box: NewOwner.Box) -> String = NewOwner.sink box.title
|} accepted

let cross_check = rejected_pair {|
fn bridge(value: String) -> String =
  let proven = check OldOwner.trust value
  NewOwner.sink proven
|}
let cross_fact = rejected_pair {|
fn bridge(value: String) -> String = NewOwner.factSink value (OldOwner.evidence value)
|}
let cross_return = rejected_pair {|
fn bridge(value: String) -> Fact (NewOwner.Valid value) = OldOwner.evidence value
|}
let cross_record_field = rejected_pair {|
fn bridge(box: OldOwner.Box) -> String = NewOwner.sink box.title
|}
let cross_record_construction = rejected_pair {|
fn bridge(value: String) -> NewOwner.Box =
  let proven = check OldOwner.trust value
  NewOwner.Box { title: proven }
|}
let cross_adt_construction = rejected_pair {|
fn bridge(value: String) -> NewOwner.Envelope =
  let proven = check OldOwner.trust value
  NewOwner.Wrapped proven
|}
let unqualified_annotation = scenario {|
fn bridge(value: String ::: Valid value) -> String = value
|} rejected
let local_collision () = with_project (fun write ->
  setup write;
  let local = {|
fact Valid (value: String)
establish evidence(value: String) -> Fact (Valid value) = Valid value
fn own(value: String, witness: Fact (Valid value)) -> String = attachFact value witness
fn safe(value: String) -> String = own value (evidence value)
|} in
  accepted (write "app.tesl" (app local));
  rejected (write "app.tesl" (app (local ^ "\nfn bridge(value: String) -> String = OldOwner.factSink value (evidence value)\n")));
  rejected (write "app.tesl" ("module App exposing []\n" ^ imports ^ "import OldOwner exposing [Valid]\n" ^ local)))

let higher_order partial alias () = rejected_pair ("\n" ^ {|
fn run(value: String, callback: Fact (OldOwner.Valid value) -> String, proof: Fact (OldOwner.Valid value)) -> String = callback proof
fn bridge(value: String) -> String =
  let proof = OldOwner.evidence value
|} ^ (if alias then "  let callback = NewOwner.factSink value\n" else "") ^
  (if partial then "  run value " ^ (if alias then "callback" else "(NewOwner.factSink value)") ^ " proof\n"
   else "  run value (fn(witness: Fact (NewOwner.Valid value)) -> NewOwner.factSink value witness) proof\n")) ()

let immediate_fact_lambda = rejected_pair {|
fn bridge(value: String) -> String =
  let proof = OldOwner.evidence value
  (fn(witness: Fact (NewOwner.Valid value)) -> NewOwner.factSink value witness) proof
|}

let direct_combinator = rejected_pair {|
fn bridge(value: String) -> String =
  let proof = OldOwner.evidence value
  NewOwner.sink (attachFact value proof)
|}

let shadowed_combinator () = with_project (fun write ->
  setup write;
  let source = app {|
fn attachFact(value: String, proof: Fact (NewOwner.Valid value)) -> String = NewOwner.factSink value proof
fn bridge(value: String) -> String = attachFact value (OldOwner.evidence value)
|} in
  let path = write "app.tesl" source in
  (match Parser.parse_module path source with
   | Err e -> check bool "proof operator is a reserved token" true
       (try ignore (Str.search_forward (Str.regexp_string "expected identifier, got attachFact") e.msg 0);
         true with Not_found -> false)
   | Ok _ -> fail "source can shadow the reserved proof operator");
  let env = Type_system.make_stdlib_env () in
  let intrinsic = List.assoc "attachFact" env in
  let loc = Location.dummy_loc "app.tesl" in
  let reference = Ast.EVar { name = "attachFact"; loc } in
  let original = Checker.make_ctx ~filename:"app.tesl" ~env () in
  check bool "resolved original intrinsic" true (Checker.is_intrinsic_fact_combinator original reference);
  let shadow = { intrinsic with mono = intrinsic.mono } in
  let overridden = Checker.make_ctx ~filename:"app.tesl" ~env:(("attachFact", shadow) :: env) () in
  check bool "same spelling and shape confer no intrinsic authority" false
    (Checker.is_intrinsic_fact_combinator overridden reference))

let cross_forall = rejected_pair {|
fn bridge(values: List String ::: ForAll (OldOwner.Valid) values) -> Int = NewOwner.count values
|}

let forall_metadata_matches_source () = with_project (fun write ->
  setup write;
  let source = app {|
fn bridge(values: List String ::: ForAll (OldOwner.Valid) values) -> Int = OldOwner.count values
|} in
  let path = write "app.tesl" source in
  let m = match Parser.parse_module path source with Ok m -> m | Err e -> fail e.msg in
  let actual = match m.decls with
    | [Ast.DFunc { params = [{ proof_ann = Some p; _ }]; _ }] -> p
    | _ -> fail "missing source proof" in
  let fi = List.assoc "OldOwner.count" (Validation_common.load_imported_func_info m) in
  let required = Option.get (List.hd fi.fi_params).proof_ann in
  if not (Validation_common.proof_matches required [actual]) then
    fail (Printf.sprintf "transport/source differ: %S versus %S"
      (Validation_common.pp_proof required) (Validation_common.pp_proof actual)))

let unrelated_exposed_nominals () = with_project (fun write ->
  setup write;
  ignore (write "ordinary.tesl" ("module Ordinary exposing [Valid, Holder, Choice(..)]\n" ^ imports ^ {|
record Valid { value: String }
record Holder { item: Valid }
type Choice = Chosen item: Valid
|}));
  accepted (write "app.tesl" (app {|
import Ordinary exposing [Valid, Holder, Choice(..)]
fn recordRoundTrip(value: String) -> String =
  let holder = Holder { item: Valid { value: value } }
  holder.item.value
fn adtRoundTrip(value: String) -> Choice = Chosen (Valid { value: value })
|})))

let nested_quantifier_transport () =
  List.iter (fun quantifier ->
    let source = "module Example exposing []\nfn use(xs: Int ::: " ^ quantifier ^
      " (Valid && Other) xs) -> Int = xs\n" in
    let m = match Parser.parse_module "example.tesl" source with
      | Ok m -> m | Err e -> fail e.msg in
    let proof = match m.decls with
      | [Ast.DFunc { params = [{ proof_ann = Some p; _ }]; _ }] -> p
      | _ -> fail "missing parsed quantifier proof" in
    let mapped = Validation_common.map_predicate_proof
      (fun name -> if name = "Valid" || name = "Other" then "Owner." ^ name else name) proof in
    match mapped with
    | Ast.PredApp { pred; args = [inner; subject]; _ } ->
      check string "framework predicate retained" quantifier pred;
      check string "both inner predicate owners retained" "Owner.Valid && Owner.Other" inner;
      check string "collection subject unchanged" "xs" subject
    | _ -> fail "unexpected quantifier proof") ["ForAll"; "ForAllValues"; "ForAllKeys"]

let hidden_forwarding same_owner () = with_project (fun write ->
  setup write;
  ignore (write "forwarder.tesl" ("module Forwarder exposing [forwarded]\n" ^ imports ^ {|
import OldOwner exposing [Valid, evidence]
fn forwarded(value: String) -> Fact (Valid value) = evidence value
|}));
  let sink_owner = if same_owner then "OldOwner" else "NewOwner" in
  ignore (write "consumer.tesl" ("module Consumer exposing [consume]\n" ^ imports ^
    "import " ^ sink_owner ^ " exposing [Valid, factSink]\n" ^ {|
fn consume(value: String, proof: Fact (Valid value)) -> String = factSink value proof
|}));
  let path = write "app.tesl" ("module App exposing []\n" ^ imports ^ {|
import Forwarder
import Consumer
fn bridge(value: String) -> String = Consumer.consume value (Forwarder.forwarded value)
|}) in
  (if same_owner then accepted else rejected) path)

let fact_ir_preserves_predicate_namespace () = with_project (fun write ->
  setup write;
  let lower revision owner =
    let source = app ("fn preserve(value: String) -> Fact (" ^ owner ^ ".Valid value) = " ^ owner ^ ".evidence value\n") in
    let path = write "app.tesl" source in accepted path;
    let m = match Parser.parse_module path source with Ok m -> m | Err e -> fail e.msg in
    let typed_nodes, type_errors = Checker.check_module_with_typed_nodes m in
    check int "ordinary checker accepted typed Fact" 0 (List.length type_errors);
    let resolve ns name =
      let open Migration_ir in
      match ns, name with
      | Type, ("String" | "Fact") -> Some (Primitive ("core/" ^ name))
      | Predicate, "OldOwner.Valid" -> Some (Global "Schema.Todo.V1.Valid")
      | Predicate, "NewOwner.Valid" -> Some (Global ("Schema.Todo." ^ revision ^ ".Valid"))
      | Value, "OldOwner.evidence" -> Some (Global "Schema.Todo.V1.evidence")
      | Value, "NewOwner.evidence" -> Some (Global ("Schema.Todo." ^ revision ^ ".evidence"))
      | _ -> None in
    let scopes = Migration_canonical.[
      { family = "Schema.Todo"; revision = "V1"; role = From_role };
      { family = "Schema.Todo"; revision; role = To_role }] in
    match Migration_ir.declaration ~scopes ~resolve ~typed_nodes ~module_name:m.module_name (List.hd m.decls) with
    | Error e -> fail e.message
    | Ok lowered ->
      check bool "Fact payload resolves in Predicate namespace" true
        (List.exists (fun (ns, _) -> ns = Migration_ir.Predicate) lowered.references);
      Migration_canonical.encode lowered.node in
  let current = lower "VCurrent" "NewOwner" in
  check string "freezing retains owner role in surface and inferred Fact types"
    current (lower "V8" "NewOwner");
  check bool "the other owner's Fact has different IR" true
    (current <> lower "VCurrent" "OldOwner"))

let generated_fact_callbacks_execute () = with_project (fun write ->
  setup write;
  let path = write "app.tesl" (app {|
fn run(value: String, callback: Fact (OldOwner.Valid value) -> String, proof: Fact (OldOwner.Valid value)) -> String = callback proof
fn previous(value: String) -> String =
  let proof = OldOwner.evidence value
  let callback = OldOwner.factSink value
  run value callback proof
fn current(value: String) -> String =
  let proof = NewOwner.evidence value
  NewOwner.sink (attachFact value proof)
test "qualified facts retain their values through callbacks" {
  expect previous "previous" == "previous"
  expect current "current" == "current"
}
|}) in
  accepted path;
  let artifacts = match Compile.compile_go_file path with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure ds -> fail (Compile.diagnostics_to_json ds) in
  List.iter (fun (a : Emit_go.artifact) -> ignore (write ("out/" ^ a.path) a.contents)) artifacts;
  let root = Filename.dirname path in
  let log = Filename.concat root "go-test.log" in
  let command = Printf.sprintf "cd %s && timeout 90s go test -timeout=60s -count=1 -v ./... > %s 2>&1"
    (Filename.quote (Filename.concat root "out")) (Filename.quote log) in
  let status = Sys.command command in
  let output = In_channel.with_open_bin log In_channel.input_all in
  if status <> 0 then fail output;
  check bool "the emitted application test actually executed" true
    (try ignore (Str.search_forward (Str.regexp_string "--- PASS:") output 0); true with Not_found -> false))

let schema_fact_inventory () = with_project (fun write ->
  let source revision = "module Schema.Todo." ^ revision ^ " exposing [Valid, evidence, Todo]\n" ^ imports ^ {|
fact Valid (value: String)
establish evidence(value: String) -> Fact (Valid value) = Valid value
entity Todo table "todos" primaryKey id { id: String, title: String ::: Valid title }
|} in
  let inventory relative revision =
    let path = write relative (source revision) in accepted path;
    match Migration_inventory.load ~compiler_abi:"qualified-predicate-test" ~root_file:path with
    | Ok inventory -> inventory
    | Error error -> fail error.message in
  let current = inventory "schema/todo/v-current.tesl" "VCurrent" in
  let frozen = inventory "schema/todo/v1.tesl" "V1" in
  check string "complete Fact producer closure survives freezing"
    (Migration_canonical.encode (Migration_inventory.snapshot current))
    (Migration_canonical.encode (Migration_inventory.snapshot frozen)))

let single_owner_qualified () = with_project (fun write ->
  setup write;
  let source extra = "module App exposing []\n" ^ imports ^ "import OldOwner\n" ^ extra ^ {|
fn previous(value: String) -> Fact (OldOwner.Valid value) = OldOwner.evidence value
fn use(value: String ::: OldOwner.Valid value) -> String = OldOwner.sink value
fn read(box: OldOwner.Box) -> String = OldOwner.sink box.title
fn run(value: String, callback: Fact (OldOwner.Valid value) -> String, proof: Fact (OldOwner.Valid value)) -> String = callback proof
fn invoke(value: String) -> String = run value (OldOwner.factSink value) (OldOwner.evidence value)
|} in
  accepted (write "app.tesl" (source ""));
  ignore (write "unrelated.tesl" ("module Unrelated exposing [Different]\n" ^ imports ^ "fact Different (value: String)\n"));
  accepted (write "app.tesl" (source "import Unrelated\n")))

let reexport_qualified () = with_project (fun write ->
  setup write;
  ignore (write "facade.tesl" ("module Facade exposing [Valid]\n" ^ imports ^ "import OldOwner exposing [Valid]\n"));
  let path = write "app.tesl" ("module App exposing []\n" ^ imports ^ "import OldOwner\nimport Facade\n" ^ {|
fn previous(value: String) -> Fact (Facade.Valid value) = OldOwner.evidence value
fn use(value: String ::: Facade.Valid value) -> String = OldOwner.sink value
|}) in
  let parsed = match Parser.parse_module path (In_channel.with_open_bin path In_channel.input_all) with
    | Ok m -> m | Err e -> fail e.msg in
  Validation_common.with_predicate_scope parsed (fun () ->
    check string "reexport resolves original declaration" "OldOwner.Valid"
      (Validation_common.predicate_identity "Facade.Valid"));
  let diagnostics = errors path in
  check bool "language still refuses source reexports" true (List.exists (fun (d : Compile.diagnostic) ->
    try ignore (Str.search_forward (Str.regexp_string "re-export is not supported") d.message 0); true with Not_found -> false) diagnostics))

let same_owner_subjects mode () = with_project (fun write ->
  setup write;
  let body captured = "module App exposing []\n" ^ imports ^ "import OldOwner\n" ^ {|
fn run(n: String, callback: Fact (OldOwner.Valid n) -> String, witness: Fact (OldOwner.Valid n)) -> String = callback witness
fn bridge(n: String, m: String) -> String =
|} ^ (match mode with
    | "alias" -> "  let sink = OldOwner.factSink " ^ captured ^ "\n  run n sink (OldOwner.evidence n)\n"
    | "lambda" -> "  run n (fn(w: Fact (OldOwner.Valid " ^ captured ^ ")) -> OldOwner.factSink " ^ captured ^ " w) (OldOwner.evidence n)\n"
    | _ -> "  run n (OldOwner.factSink " ^ captured ^ ") (OldOwner.evidence n)\n") in
  accepted (write "app.tesl" (body "n"));
  rejected (write "app.tesl" (body "m")))

let callback_body_subjects () = with_project (fun write ->
  setup write;
  let source witness = "module App exposing []\n" ^ imports ^ "import OldOwner\n" ^
    "fn run(n: String, m: String, callback: Fact (OldOwner.Valid n) -> String, witness: Fact (OldOwner.Valid " ^ witness ^ ")) -> String = callback witness\n" in
  accepted (write "app.tesl" (source "n"));
  rejected (write "app.tesl" (source "m")))

let callback_field_subjects () = with_project (fun write ->
  setup write;
  let source field = "module App exposing []\n" ^ imports ^ "import OldOwner\n" ^ {|
record Pair { left: String, right: String }
fn run(n: String, callback: Fact (OldOwner.Valid n) -> String, witness: Fact (OldOwner.Valid n)) -> String = callback witness
fn bridge(pair: Pair) -> String =
|} ^ "  let left = pair.left\n  let captured = pair." ^ field ^ "\n  run left (OldOwner.factSink captured) (OldOwner.evidence left)\n" in
  accepted (write "app.tesl" (source "left"));
  rejected (write "app.tesl" (source "right")))

let opaque_callbacks () = with_project (fun write ->
  setup write;
  let prefix = "module App exposing []\n" ^ imports ^ "import OldOwner\n" in
  accepted (write "app.tesl" (prefix ^ {|
record Box { callback: String -> String }
type Callback = (String) -> String
fn identity(value: String) -> String = value
fn factory() -> String -> String = identity
|}));
  List.iter (fun body ->
    let path = write "app.tesl" (prefix ^ body) in
    let diagnostics = errors path in
    check bool "opaque dependent callback has an explicit refusal" true
      (List.exists (fun (d : Compile.diagnostic) -> try ignore (Str.search_forward
        (Str.regexp_string "unsupported opaque dependent Fact callback") d.message 0); true with Not_found -> false) diagnostics)) [
      "fn factory(value: String) -> Fact (OldOwner.Valid value) -> String = OldOwner.factSink value\n";
      "record Box { value: String, callback: Fact (OldOwner.Valid value) -> String }\n";
      "type Box = Boxed value: String callback: Fact (OldOwner.Valid value) -> String\n";
      "type Callback = (Fact (OldOwner.Valid value)) -> String\n"
    ])

let detached_fact_storage () = with_project (fun write ->
  setup write;
  let prefix = "module App exposing []\n" ^ imports ^ "import OldOwner\n" in
  accepted (write "app.tesl" (prefix ^ {|
type Label = String
record Witness { value: String ::: OldOwner.Valid value }
type Checked = CheckedValue value: String ::: OldOwner.Valid value
fn wrap(value: String) -> Witness =
  let proven = check OldOwner.trust value
  Witness { value: proven }
fn consume(witness: Witness) -> String = OldOwner.sink witness.value
fn roundTrip(value: String) -> String = consume (wrap value)
fn detached(value: String) -> Fact (OldOwner.Valid value) = OldOwner.evidence value
|}));
  List.iter (fun body ->
    let source = prefix ^ body in
    let path = write "app.tesl" source in
    (match Parser.parse_module path source with
     | Ok _ -> () | Err e -> fail ("storage boundary fixture must parse: " ^ e.msg));
    let diagnostics = errors path in
    check bool "raw Fact storage has an explicit boundary diagnostic" true
      (List.exists (fun (d : Compile.diagnostic) -> try ignore (Str.search_forward
        (Str.regexp_string "unsupported detached Fact storage") d.message 0); true with Not_found -> false) diagnostics)
  ) [
    "record Witness { value: String, proof: Fact (OldOwner.Valid value) }\n";
    "record Witness { value: String, proof: Maybe (Fact (OldOwner.Valid value)) }\n";
    "entity Witness table \"witnesses\" primaryKey value { value: String, proof: Fact (OldOwner.Valid value) }\n";
    "type Witness = Witnessed value: String proof: Fact (OldOwner.Valid value)\n";
    "type Evidence = Fact (OldOwner.Valid value)\ntype Callback = Evidence -> String\n";
    "type Evidence = List (Fact (OldOwner.Valid value))\n";
    {|
record Witness { value: String, proof: Fact (OldOwner.Valid value) }
fn wrap(value: String) -> Witness =
  let proof = OldOwner.evidence value
  Witness { value: value, proof: proof }
fn consume(value: String, witness: Witness) -> String = OldOwner.factSink value witness.proof
fn bridge(n: String, m: String) -> String = consume m (wrap n)
|};
    {|
type Evidence = Fact (OldOwner.Valid value)
fn wrap(value: String) -> Evidence = Evidence (OldOwner.evidence value)
fn consume(value: String, proof: Evidence) -> String = OldOwner.factSink value proof.value
fn bridge(n: String, m: String) -> String = consume m (wrap n)
|}
  ])

let fact_conjunction_identity () = with_project (fun write ->
  setup write;
  let prefix = app {|
fact Local (value: String)
establish local(value: String) -> Fact (Local value) = Local value
fn sink(value: String, proof: Fact (OldOwner.Valid value && NewOwner.Valid value && Local value)) -> String = attachFact value proof
fn together(value: String, old: Fact (OldOwner.Valid value), current: Fact (NewOwner.Valid value), here: Fact (Local value)) -> String =
  sink value ((current && old) && here)
fn reordered(value: String, old: Fact (OldOwner.Valid value), current: Fact (NewOwner.Valid value), here: Fact (Local value)) -> String =
  sink value (here && (old && current))
|} in
  accepted (write "app.tesl" prefix);
  rejected (write "app.tesl" (prefix ^ {|
fn missing(value: String, old: Fact (OldOwner.Valid value), here: Fact (Local value)) -> String =
  sink value ((old && old) && here)
|}));
  rejected (write "app.tesl" (prefix ^ {|
fn changedSubject(value: String, other: String, old: Fact (OldOwner.Valid value), current: Fact (NewOwner.Valid other), here: Fact (Local value)) -> String =
  sink value ((old && current) && here)
|})))

let builtin_fact_conjunction () = with_project (fun write ->
  setup write;
  let prefix = app "import Tesl.String exposing [IsNonEmpty]\n" ^ {|
fn sink(value: String, proof: Fact (IsNonEmpty value && OldOwner.Valid value)) -> String = attachFact value proof
fn both(value: String, builtin: Fact (IsNonEmpty value), owned: Fact (OldOwner.Valid value)) -> String =
  sink value (builtin && owned)
fn reverse(value: String, builtin: Fact (IsNonEmpty value), owned: Fact (OldOwner.Valid value)) -> String =
  sink value (owned && builtin)
fn run(value: String, callback: Fact (OldOwner.Valid value) -> String, proof: Fact (OldOwner.Valid value)) -> String = callback proof
|} in
  accepted (write "app.tesl" prefix);
  List.iter (fun body -> rejected (write "app.tesl" (prefix ^ body))) [{|
fn missingBuiltin(value: String, proof: Fact (OldOwner.Valid value)) -> String = sink value proof
|}; {|
fn changedOwner(value: String, builtin: Fact (IsNonEmpty value), proof: Fact (NewOwner.Valid value)) -> String =
  sink value (builtin && proof)
|}; {|
fn changedSubject(value: String, other: String, builtin: Fact (IsNonEmpty other), proof: Fact (OldOwner.Valid value)) -> String =
  sink value (builtin && proof)
|}; {|
fn changedCallback(value: String, proof: Fact (OldOwner.Valid value)) -> String = run value (sink value) proof
|}])

let hidden_local_owners () = with_project (fun write ->
  ignore (write "unrelated.tesl" (owner "Unrelated"));
  List.iter (fun name ->
    let source = owner name |> Str.global_replace (Str.regexp_string "fact Valid") "import Unrelated\nfact Valid" in
    accepted (write (Validation_common.module_name_to_kebab name ^ ".tesl") source)) ["OldOwner"; "NewOwner"];
  let wrapper name original = "module " ^ name ^ " exposing [forward]\n" ^ imports ^
    "import " ^ original ^ " exposing [Valid, evidence]\nimport Unrelated\nfn forward(value: String) -> Fact (Valid value) = evidence value\n" in
  accepted (write "old-forward.tesl" (wrapper "OldForward" "OldOwner"));
  accepted (write "new-forward.tesl" (wrapper "NewForward" "NewOwner"));
  let body owner = "module App exposing []\n" ^ imports ^ "import OldForward\nimport NewForward\nimport OldOwner\nimport NewOwner\n" ^
    "fn use(value: String) -> String = " ^ owner ^ ".factSink value (OldForward.forward value)\n" in
  accepted (write "app.tesl" (body "OldOwner"));
  rejected (write "app.tesl" (body "NewOwner")))

let callback_capture_names () = with_project (fun write ->
  setup write;
  let source captured = "module App exposing []\n" ^ imports ^ "import OldOwner\n" ^ {|
fn run(n: String, callback: Fact (OldOwner.Valid n) -> String, witness: Fact (OldOwner.Valid n)) -> String = callback witness
fn bridge(__callback_arg0: String, proof: String) -> String =
|} ^ "  run __callback_arg0 (OldOwner.factSink " ^ captured ^ ") (OldOwner.evidence __callback_arg0)\n" in
  accepted (write "app.tesl" (source "__callback_arg0"));
  rejected (write "app.tesl" (source "proof"));
  let same = "module App exposing []\n" ^ imports ^ "import OldOwner\n" ^ {|
fn run(n: String, callback: Fact (OldOwner.Valid n) -> String, witness: Fact (OldOwner.Valid n)) -> String = callback witness
fn bridge(proof: String) -> String = run proof (OldOwner.factSink proof) (OldOwner.evidence proof)
|} in accepted (write "app.tesl" same))

let test_callback_subjects () = with_project (fun write ->
  setup write;
  let source value = "module App exposing []\n" ^ imports ^ "import OldOwner\n" ^ {|
test "tracked callback" {
  let raw = "first"
  let other = "second"
  let callback = OldOwner.factSink raw
|} ^ "  expect callback (OldOwner.evidence " ^ value ^ ") == raw\n}\n" in
  accepted (write "app.tesl" (source "raw"));
  rejected (write "app.tesl" (source "other")))

let opaque_branch_callbacks () = with_project (fun write ->
  setup write;
  let prefix = "module App exposing []\n" ^ imports ^ "import OldOwner\nimport Tesl.List exposing [List.map]\n" in
  accepted (write "app.tesl" (prefix ^ {|
fn map(flag: Bool, values: List String) -> List String =
  let chosen = if flag then
    fn(v: String) -> v
  else
    fn(v: String) -> v
  List.map chosen values
|}));
  let source tail = prefix ^ {|
fn bridge(n: String, m: String, flag: Bool) -> List String =
|} ^ tail in
  rejected (write "app.tesl" (source {|
  let chosen = if flag then
    fn(w: Fact (OldOwner.Valid m)) -> OldOwner.factSink m w
  else
    fn(w: Fact (OldOwner.Valid m)) -> OldOwner.factSink m w
  List.map chosen [OldOwner.evidence n]
|}));
  rejected (write "app.tesl" (source {|
  let callback = if flag then
    OldOwner.factSink n
  else
    OldOwner.factSink m
  [callback (OldOwner.evidence n)]
|})))

let test_opaque_callback_bindings () = with_project (fun write ->
  setup write;
  let prefix = "module App exposing []\n" ^ imports ^ "import OldOwner\n" in
  accepted (write "app.tesl" (prefix ^ {|
fn identity(value: String) -> String = value
test "attached values remain ordinary arguments" {
  let callback = if True then
    identity
  else
    identity
  let raw = "first"
  let value = check OldOwner.trust raw
  if True then
    let branchCallback = OldOwner.factSink raw
    expect branchCallback (OldOwner.evidence raw) == raw
  else
    expect True
  expect callback value == "first"
}
|}));
  List.iter (fun statements ->
    let path = write "app.tesl" (prefix ^ "test \"opaque bound evidence\" {\n" ^ statements ^ "\n}\n") in
    rejected path;
    check bool "opaque callback refusal names the unsupported contract" true
      (List.exists (fun (d : Compile.diagnostic) ->
        try ignore (Str.search_forward (Str.regexp_string "unsupported opaque dependent Fact callback") d.message 0); true
        with Not_found -> false) (errors path))
  ) [{|
  let raw = "first"
  let other = "second"
  let callback = if True then
    OldOwner.factSink raw
  else
    OldOwner.factSink other
  let witness = OldOwner.evidence raw
  expect callback witness == raw
|}; {|
  let raw = "first"
  let other = "second"
  let callback = if True then
    OldOwner.factSink raw
  else
    OldOwner.factSink other
  let proven = check OldOwner.trust raw
  let (_ ::: witness) = proven
  expect callback witness == raw
|}; {|
  let raw = "first"
  let other = "second"
  let callback = if True then
    OldOwner.factSink raw
  else
    OldOwner.factSink other
  let witness = OldOwner.evidence raw
  if True then
    let alias = witness
    expect callback alias == raw
  else
    expect True
|}; {|
  let raw = "first"
  let other = "second"
  let callback = if True then
    OldOwner.factSink raw
  else
    OldOwner.factSink other
  let witness = OldOwner.evidence raw
  let maybe = Something witness
  case maybe of
    Nothing -> expect True
    Something alias -> expect callback alias == raw
|}])

let http_owner name = "module " ^ name ^ " exposing [Allowed, Tagged, Role, authenticate, validate, validateTagged, reply, adminReply]\n" ^
  "import Tesl.Prelude exposing [String, List]\nimport Tesl.Http exposing [HttpRequest]\n" ^ {|
fact Allowed(value: String)
fact Tagged(value: String)
fact Role(value: String, role: String)
auth authenticate(request: HttpRequest) -> value: String ::: Allowed value && Role value "reader" =
  fail 401 "denied"
check validate(value: String) -> value: String ::: Allowed value && Role value "reader" =
  ok value ::: Allowed value && Role value "reader"
check validateTagged(value: String) -> value: String ::: Allowed value && Tagged value =
  ok value ::: Allowed value && Tagged value
handler get reply(value: String ::: Allowed value && Role value "reader") -> String = value
handler get adminReply(value: String ::: Allowed value && Role value "admin") -> String = value
|}

let with_http_project f = with_project (fun write ->
  ignore (write "boundary.tesl" (http_owner "Boundary"));
  ignore (write "other-boundary.tesl" (Str.global_replace (Str.regexp_string "authenticate")
    "otherAuthenticate" (http_owner "OtherBoundary")));
  f write)

let http_app ?(extra = "") ?(via = "authenticate")
    ?(handler = "respond") endpoint_proof handler_proof =
  "module App exposing []\nimport Tesl.Prelude exposing [String, List]\n" ^
  "import Tesl.Agent exposing [Tool, serverTools]\n" ^
  "import Boundary exposing [Allowed, Role, authenticate, reply, adminReply]\nimport OtherBoundary exposing [otherAuthenticate]\n" ^ extra ^
  Printf.sprintf {|
handler get respond(value: String ::: %s) -> String = value
api A { get "/value" auth value: String ::: %s via %s -> String }
server S for A { %s }
|} handler_proof endpoint_proof via handler

let http_imported_auth_identity () = with_http_project (fun write ->
  let bare = "Allowed value && Role value \"reader\"" in
  let qualified = "Boundary.Allowed value && Boundary.Role value \"reader\"" in
  List.iter (fun (endpoint, handler) ->
    accepted (write "app.tesl" (http_app endpoint handler)))
    [bare, bare; bare, qualified; qualified, bare; qualified, qualified];
  accepted (write "app.tesl" (http_app ~handler:"reply" bare bare));
  List.iter (fun proof ->
    rejected (write "app.tesl" (http_app proof proof)))
    ["OtherBoundary.Allowed value && OtherBoundary.Role value \"reader\"";
     "Allowed value && Role value \"admin\""];
  rejected (write "app.tesl" (http_app bare
    "OtherBoundary.Allowed value && OtherBoundary.Role value \"reader\""));
  rejected (write "app.tesl" (http_app ~via:"otherAuthenticate" bare bare));
  rejected (write "app.tesl" (http_app bare "Allowed value && Role value \"admin\""));
  rejected (write "app.tesl" (http_app ~handler:"adminReply" bare bare)))

let http_local_auth_owner () = with_http_project (fun write ->
  let source = http_app ~extra:"fact Allowed(value: String)\n" "Allowed value" "Allowed value" in
  let source = Str.global_replace
    (Str.regexp_string "import Boundary exposing [Allowed, Role, authenticate, reply, adminReply]")
    "import Boundary exposing [authenticate]" source in
  rejected (write "app.tesl" source))

let http_capture_identity () = with_http_project (fun write ->
  let source endpoint handler = Printf.sprintf {|module App exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
import Boundary exposing [Allowed, Role, validate]
import OtherBoundary
handler get read(value: String ::: %s) -> String = value
api A { get "/value/:value" capture value: String ::: %s using stringCodec via validate -> String }
server S for A { read }
|} handler endpoint in
  let bare = "Allowed value && Role value \"reader\"" in
  let qualified = "Boundary.Allowed value && Boundary.Role value \"reader\"" in
  accepted (write "app.tesl" (source bare qualified));
  accepted (write "app.tesl" (source qualified bare));
  rejected (write "app.tesl" (source "OtherBoundary.Allowed value" "OtherBoundary.Allowed value"));
  rejected (write "app.tesl" (source "Role value \"admin\"" "Role value \"admin\""));
  rejected (write "app.tesl" (source bare "Role value \"admin\"")))

let http_response_identity () = with_http_project (fun write ->
  let source proof = Printf.sprintf {|module App exposing []
import Tesl.Prelude exposing [String]
import Boundary exposing [Role, authenticate]
import OtherBoundary
handler get respond(value: String ::: Boundary.Role value "reader") -> value: String ::: Boundary.Role value "reader" = value
api A { get "/value" auth value: String ::: Role value "reader" via authenticate -> reply: String ::: %s }
server S for A { respond }
|} proof in
  accepted (write "app.tesl" (source "Role reply \"reader\""));
  rejected (write "app.tesl" (source "Role reply \"admin\""));
  rejected (write "app.tesl" (source "OtherBoundary.Role reply \"reader\"")))

let http_tool_identity () = with_http_project (fun write ->
  let source proof = http_app
    "Boundary.Allowed value && Boundary.Role value \"reader\""
    "Allowed value && Role value \"reader\"" ^
    Printf.sprintf "\nfn expose(value: String ::: %s) -> List Tool = serverTools S value\n" proof in
  accepted (write "app.tesl" (source "Allowed value && Role value \"reader\""));
  rejected (write "app.tesl" (source "OtherBoundary.Allowed value && OtherBoundary.Role value \"reader\""));
  rejected (write "app.tesl" (source "Allowed value && Role value \"admin\"")))

let http_quantified_response_identity () = with_http_project (fun write ->
  let source handler endpoint = Printf.sprintf {|module App exposing []
import Tesl.Prelude exposing [String, List]
import Tesl.List exposing [List.filterCheck]
import Boundary exposing [Allowed, Tagged, validateTagged]
import OtherBoundary
handler get respond(values: List String) -> %s = List.filterCheck validateTagged values
api A { get "/values" body values: List String -> %s }
server S for A { respond }
|} handler endpoint in
  let handlers = [
    "List String ? ForAll (Boundary.Allowed && Boundary.Tagged)";
    "result: List String ::: ForAll (Boundary.Allowed && Boundary.Tagged) result"] in
  List.iter (fun handler ->
    List.iter (fun endpoint -> accepted (write "app.tesl" (source handler endpoint))) [
      "List String ? ForAll (Allowed)";
      "List String ? ForAll (Tagged && Allowed)";
      "reply: List String ::: ForAll (Allowed) reply";
      "reply: List String ::: ForAll (Tagged && Allowed) reply"];
    List.iter (fun endpoint -> rejected (write "app.tesl" (source handler endpoint))) [
      "List String ? ForAll (OtherBoundary.Allowed)";
      "reply: List String ::: ForAll (OtherBoundary.Allowed) reply";
      "reply: List String ::: ForAll (Allowed && OtherBoundary.Tagged) reply"]
  ) handlers)

let http_auth_proof_on_capture () = with_http_project (fun write ->
  let source annotation = Printf.sprintf {|module App exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
import Boundary exposing [Allowed, authenticate, validate]
handler get respond(principal: String ::: Allowed principal, value: String ::: Allowed value) -> String = value
api A { get "/value/:value" auth user: String ::: Allowed user via authenticate capture value: String %s using stringCodec -> String }
server S for A { respond }
|} annotation in
  let proven = source "::: Allowed value" |> Str.global_replace
    (Str.regexp_string "using stringCodec") "using stringCodec via validate" in
  accepted (write "app.tesl" proven);
  rejected (write "app.tesl" (source "")))

let http_raw_body_proofs () = with_http_project (fun write ->
  let source ty annotation = Printf.sprintf {|module App exposing []
import Tesl.Prelude exposing [String, List]
import Boundary exposing [Allowed, validate]
handler post respond(value: %s) -> String = "ok"
api A { post "/value" body value: %s %s -> String }
server S for A { respond }
|} ty ty annotation in
  List.iter (fun (ty, annotation, message) ->
    let path = write "app.tesl" (source ty annotation) in
    rejected path;
    check bool message true (List.exists (fun (d:Compile.diagnostic) ->
      Compile.string_contains d.message message) (errors path)))
    ["String", "::: Allowed value", "does not establish a top-level proof";
     "List String", "::: ForAll (Allowed) value", "does not establish a top-level proof";
     "String", "via validate", "body `via` validation is not implemented";
     "String", "::: Allowed value via validate", "body `via` validation is not implemented"];
  accepted (write "app.tesl" {|module App exposing []
import Tesl.Prelude exposing [String]
import Tesl.Json exposing [stringCodec]
import Boundary exposing [Allowed, validate]
record Input { title: String ::: Allowed title }
codec Input {
  toJson { title -> "title" with_codec stringCodec }
  fromJson [ { title <- "title" with_codec stringCodec via validate } ]
}
handler post respond(value: Input) -> String = value.title
api A { post "/value" body value: Input -> String }
server S for A { respond }
|}))

let () = run "qualified predicate identity" ["ownership", [
  test_case "HTTP auth aliases keep their original authority and role" `Quick http_imported_auth_identity;
  test_case "HTTP auth cannot mint a same-spelled local proof" `Quick http_local_auth_owner;
  test_case "HTTP capture aliases preserve owner and proof arguments" `Quick http_capture_identity;
  test_case "serverTools matches imported aliases without widening authority" `Quick http_tool_identity;
  test_case "HTTP response guarantees preserve owners and literal arguments" `Quick http_response_identity;
  test_case "HTTP quantified response retains owner and conjunct coverage" `Quick http_quantified_response_identity;
  test_case "auth evidence does not prove another captured value" `Quick http_auth_proof_on_capture;
  test_case "raw body annotations and unexecuted via cannot supply proofs" `Quick http_raw_body_proofs;
  test_case "detached Fact storage refuses while attached fields remain supported" `Quick detached_fact_storage;
  test_case "Fact conjunction retains every owner and subject in either order" `Quick fact_conjunction_identity;
  test_case "builtin and qualified Fact conjunctions preserve all proof requirements" `Quick builtin_fact_conjunction;
  test_case "test bindings distinguish detached Facts from proven values" `Quick test_opaque_callback_bindings;
  test_case "callback alpha-renaming cannot capture caller names" `Quick callback_capture_names;
  test_case "test statement callback aliases preserve subjects" `Quick test_callback_subjects;
  test_case "opaque conditional callbacks cannot enter generic HOFs" `Quick opaque_branch_callbacks;
  test_case "same-owner partial callback retains captured subjects" `Quick (same_owner_subjects "partial");
  test_case "same-owner alias callback retains captured subjects" `Quick (same_owner_subjects "alias");
  test_case "same-owner lambda callback retains captured subjects" `Quick (same_owner_subjects "lambda");
  test_case "HOF body must respect callback proof subjects" `Quick callback_body_subjects;
  test_case "captured record fields retain distinct subjects" `Quick callback_field_subjects;
  test_case "opaque returned and stored dependent callbacks refuse" `Quick opaque_callbacks;
  test_case "local owner wins over unrelated reachable predicates" `Quick hidden_local_owners;
  test_case "single owner qualified annotations retain original identity" `Quick single_owner_qualified;
  test_case "qualified reexport aliases retain original identity" `Quick reexport_qualified;
  test_case "each namespace keeps its own checks, facts and fields" `Quick independently_proven;
  test_case "check cannot satisfy the other owner" `Quick cross_check;
  test_case "returned Fact cannot satisfy the other owner" `Quick cross_fact;
  test_case "Fact return cannot relabel its owner" `Quick cross_return;
  test_case "record field cannot satisfy the other owner" `Quick cross_record_field;
  test_case "record construction preserves predicate owner" `Quick cross_record_construction;
  test_case "ADT construction preserves predicate owner" `Quick cross_adt_construction;
  test_case "unqualified predicate remains ambiguous" `Quick unqualified_annotation;
  test_case "local namespace owner stays distinct and exposed collisions refuse" `Quick local_collision;
  test_case "partially applied Fact callback cannot change owner" `Quick (higher_order true false);
  test_case "stored Fact callback cannot change owner" `Quick (higher_order true true);
  test_case "Fact lambda callback cannot change owner" `Quick (higher_order false false);
  test_case "immediate Fact lambda cannot change owner" `Quick immediate_fact_lambda;
  test_case "direct attachFact retains the proof owner" `Quick direct_combinator;
  test_case "local spelling cannot impersonate proof combinators" `Quick shadowed_combinator;
  test_case "ForAll keeps the inner predicate owner" `Quick cross_forall;
  test_case "ForAll metadata matches the qualified source annotation" `Quick forall_metadata_matches_source;
  test_case "all collection quantifiers retain nested owners" `Quick nested_quantifier_transport;
  test_case "unrelated exposed types and constructors keep working" `Quick unrelated_exposed_nominals;
  test_case "hidden forwarded owners stay distinct" `Quick (hidden_forwarding false);
  test_case "hidden forwarding preserves the same original owner" `Quick (hidden_forwarding true);
  test_case "Fact IR separates type and predicate namespaces" `Quick fact_ir_preserves_predicate_namespace;
  test_case "qualified Fact callbacks emit and execute" `Quick generated_fact_callbacks_execute;
  test_case "complete schema Fact inventory freezes" `Quick schema_fact_inventory;
]]
