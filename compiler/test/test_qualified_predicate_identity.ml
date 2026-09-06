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

let () = run "qualified predicate identity" ["ownership", [
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
