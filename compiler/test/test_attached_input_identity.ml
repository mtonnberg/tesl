open Alcotest

let prelude = {|module Identity exposing []
import Tesl.Prelude exposing [String, Int, Bool(..), Fact]
import Tesl.Maybe exposing [Maybe(..)]
fact NonEmpty (value: String)
record Note { title: String ::: NonEmpty title }
check nonEmpty(value: String) -> value: String ::: NonEmpty value =
  if value != "" then
    ok value ::: NonEmpty value
  else
    fail 400 "empty"
fn identity(value: String ::: NonEmpty value) -> value: String ::: NonEmpty value = value
|}
let errors source = (Compile.agent_context_result_source "identity.tesl" source).diagnostics
  |> List.filter (fun (d : Compile.diagnostic) -> d.severity = "error")
let accepts source = match errors source with [] -> () | ds ->
  fail (String.concat "\n" (List.map (fun (d : Compile.diagnostic) -> d.message) ds))
let refuses source =
  let ds = errors source in
  check bool "input identity refusal, not an unrelated parse/type failure" true
    (List.exists (fun (d : Compile.diagnostic) -> d.code = "V001" &&
      Compile.string_contains d.message "does not preserve that input's subject identity") ds)
let positive body () = accepts (prelude ^ body)
let negative kind shape () =
  let signature = kind ^ " produce(value: String ::: NonEmpty value, other: String ::: NonEmpty other, choose: Bool) -> value: String ::: NonEmpty value =\n" in
  let good = match shape with
    | "case" -> "  case choose of\n    True -> value\n    False -> value\n"
    | "call" -> "  identity value\n"
    | "alias" -> "  let alias = value\n  alias\n"
    | _ -> "  if choose then\n    value\n  else\n    value\n" in
  let bad = match shape with
    | "case" -> "  case choose of\n    True -> value\n    False -> other\n"
    | "call" -> "  identity other\n"
    | "alias" -> "  let alias = other\n  alias\n"
    | _ -> "  if choose then\n    value\n  else\n    other\n" in
  accepts (prelude ^ signature ^ good);
  refuses (prelude ^ signature ^ bad)
let old_forgery () =
  refuses (prelude ^ {|
fn produce(value: String, replacement: String ::: NonEmpty replacement) -> value: String ::: NonEmpty value =
  if True then
    replacement
  else
    replacement
fn convert(raw: String, safe: String ::: NonEmpty safe) -> Note =
  let (title ::: witness) = produce raw safe
  Note { title: raw ::: witness }
|})
let check_alias () = accepts (prelude ^ {|
check checked(value: String) -> value: String ::: NonEmpty value =
  let alias = value
  if alias != "" then
    ok alias ::: NonEmpty alias
  else
    fail 400 "empty"
|})
let auth_identity wrong () =
  let final = if wrong then "    ok replacement ::: NonEmpty replacement\n" else "    fail 403 \"empty\"\n" in
  let source = prelude ^ "auth authorized(value: String) -> value: String ::: NonEmpty value =\n" ^
    "  let replacement = value ++ \"!\"\n  if value != \"\" then\n    ok value ::: NonEmpty value\n  else\n" ^ final in
  if wrong then refuses source else accepts source

let fresh = {|
fn transformed(raw: String) -> changed: String ::: NonEmpty changed =
  let changed = check nonEmpty (raw ++ "!")
  changed
fn inspect(raw: String) -> String =
  let title = transformed raw
  let note = Note { title: title }
  note.title
test "fresh returned value can differ from the original input" {
  expect inspect "" == "!"
  expect inspect "Göteborg" == "Göteborg!"
}
|}
let fresh_witness mode () =
  let converted field =
    "fn converted(raw: String) -> Note =\n" ^
    (if mode = "bound" then "  let result = transformed raw\n  let (title ::: witness) = result\n"
     else "  let (title ::: witness) = transformed raw\n") ^
    "  Note { title: " ^ field ^ " ::: witness }\n" in
  let source field = prelude ^ fresh ^ (if mode = "test" then
    "test \"fresh witness follows returned value\" {\n  let raw = \"\"\n  let (title ::: witness) = transformed raw\n  let note = Note { title: " ^ field ^ " ::: witness }\n  expect note.title == \"!\"\n}\n"
    else converted field) in
  accepts (source "title");
  let ds = errors (source "raw") in
  check bool "fresh witness cannot prove original input" true
    (List.exists (fun (d : Compile.diagnostic) -> d.code = "V001" &&
      Compile.string_contains d.message "different subject") ds)
let establish_shape () =
  let ds = errors (prelude ^ {|
establish invalid(value: String) -> value: String ::: NonEmpty value =
  value ::: NonEmpty value
|}) in
  check bool "ordinary attached establish remains unsupported" true
    (List.exists (fun (d : Compile.diagnostic) -> d.code = "P001" &&
      Compile.string_contains d.message "establish functions must return") ds)
let second_parameter () = accepts (prelude ^ {|
fn second(unrelated: String, value: String ::: NonEmpty value) -> value: String ::: NonEmpty value =
  let alias = value
  alias
fn useSecond(raw: String, good: String ::: NonEmpty good) -> good: String ::: NonEmpty good =
  second raw good
|})

let partial_application () =
  let source = prelude ^ {|
fn second(value: String ::: NonEmpty value, extra: Int) -> value: String ::: NonEmpty value = value
fn partial(value: String ::: NonEmpty value) -> Int -> String = second value
fn complete(value: String ::: NonEmpty value) -> value: String ::: NonEmpty value = second value 1
|} in
  let parsed = match Parser.parse_module "identity.tesl" source with Ok m -> m | Err e -> fail e.msg in
  let funcs = Validation_common.build_func_info parsed.Ast.decls in
  let body name = match List.find_map (function Ast.DFunc f when f.name = name -> Some f.body | _ -> None) parsed.Ast.decls with
    | Some e -> e | None -> fail "fixture function missing" in
  let partial = body "partial" and complete = body "complete" in
  check (option string) "partial application is not its first input" None
    (Validation_common.attached_subject_of_expr funcs [] partial);
  check int "partial application has no returned proof" 0
    (List.length (Validation_structural.proofs_of_expr "closure" funcs [] [] partial));
  check (option string) "completed application preserves named input" (Some "value")
    (Validation_common.attached_subject_of_expr funcs [] complete);
  check int "completed application has its returned proof" 1
    (List.length (Validation_structural.proofs_of_expr "result" funcs [] [] complete));
  accepts (prelude ^ fresh ^ {|
fn suffix(raw: String, extra: String) -> output: String ::: NonEmpty output =
  let output = transformed (raw ++ extra)
  output
fn use(raw: String) -> Note =
  let (title ::: witness) = suffix raw "!"
  Note { title: title ::: witness }
|});
  let ds = errors (prelude ^ fresh ^ {|
fn suffix(raw: String, extra: String) -> output: String ::: NonEmpty output =
  let output = transformed (raw ++ extra)
  output
fn bad(raw: String) -> Note =
  let (closure ::: witness) = suffix raw
  Note { title: raw ::: witness }
|}) in
  check bool "partially applied producer cannot provide witness" true
    (List.exists (fun (d : Compile.diagnostic) -> d.code = "V001") ds)

let nullary_source = {|
fn nullary() -> title: String ::: NonEmpty title =
  let title = check nonEmpty "ready"
  title
establish maybeTitle() -> Maybe (title: String ::: NonEmpty title) =
  let title = "rea" ++ "dy"
  Something (title ::: NonEmpty title)
fact Global
establish global() -> Fact (Global) = Global
fn requireGlobal(proof: Fact (Global)) -> Int = 7
fn nullaryRecord() -> Note =
  let title = nullary()
  Note { title: title }
fn optionalRecord() -> Maybe Note =
  case maybeTitle() of
    Nothing -> Nothing
    Something title -> Something (Note { title: title })
test "nullary calls retain returned proofs" {
  expect (nullaryRecord()).title == "ready"
  expect requireGlobal (global()) == 7
  let (title ::: witness) = nullary()
  let note = Note { title: title ::: witness }
  expect note.title == "ready"
  case optionalRecord() of
    Nothing -> expect False
    Something stored -> expect stored.title == "ready"
}
|}
let nullary () =
  let source = prelude ^ nullary_source in accepts source;
  let parsed = match Parser.parse_module "identity.tesl" source with Ok m -> m | Err e -> fail e.msg in
  let funcs = Validation_common.build_func_info parsed.Ast.decls in
  let call = match List.find_map (function
    | Ast.DFunc { name = "nullaryRecord"; body = Ast.ELet {value; _}; _ } -> Some value
    | _ -> None) parsed.Ast.decls with Some value -> value | None -> fail "fixture call missing" in
  check int "real parsed nullary Unit call retains its returned proof" 1
    (List.length (Validation_structural.proofs_of_expr "result" funcs [] [] call));
  let ds = errors (source ^ {|
fn unrelated(raw: String) -> Note =
  let (title ::: witness) = nullary()
  Note { title: raw ::: witness }
|}) in
  check bool "nullary witness does not belong to unrelated input" true
    (List.exists (fun (d : Compile.diagnostic) -> d.code = "V001" &&
      Compile.string_contains d.message "different subject") ds)

let native () =
  let root = Filename.temp_dir "tesl-attached-identity-" "" in
  let rec remove path = if Sys.is_directory path then begin
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
  end else Sys.remove path in
  let rec mkdir path = if not (Sys.file_exists path) then (mkdir (Filename.dirname path); Unix.mkdir path 0o700) in
  let write path contents = mkdir (Filename.dirname path); Out_channel.with_open_bin path (fun out -> output_string out contents) in
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let source = prelude ^ fresh ^ nullary_source in accepts source;
    let file = Filename.concat root "identity.tesl" in write file source;
    let artifacts = match Compile.compile_go_file file with
      | Compile.GoSuccess artifacts -> artifacts
      | Compile.GoFailure ds -> fail (Compile.diagnostics_to_json ds) in
    let output = Filename.concat root "out" in
    List.iter (fun (a : Emit_go.artifact) -> write (Filename.concat output a.path) a.contents) artifacts;
    Sys.remove file;
    let log = Filename.concat root "test.log" in
    let status = Sys.command (Printf.sprintf "cd %s && timeout 90s go test -race -count=1 -timeout=60s -v ./... > %s 2>&1"
      (Filename.quote output) (Filename.quote log)) in
    let contents = In_channel.with_open_bin log In_channel.input_all in
    if status <> 0 then fail contents;
    check bool "actual native test executed" true (Compile.string_contains contents "--- PASS:"))

let () = run "attached input subject identity" ["return", [
  test_case "ordinary same-input alias" `Quick (positive {|
fn aliased(value: String ::: NonEmpty value) -> value: String ::: NonEmpty value =
  let alias = value
  alias
|});
  test_case "all if leaves preserve the input" `Quick (negative "fn" "if");
  test_case "all case leaves preserve the input" `Quick (negative "fn" "case");
  test_case "a direct call must preserve the input" `Quick (negative "fn" "call");
  test_case "an alias must preserve the input" `Quick (negative "fn" "alias");
  test_case "handler if leaves preserve the input" `Quick (negative "handler" "if");
  test_case "handler case leaves preserve the input" `Quick (negative "handler" "case");
  test_case "old detached proof record forgery" `Quick old_forgery;
  test_case "check accepts a real input alias" `Quick check_alias;
  test_case "auth can preserve input on every branch" `Quick (auth_identity false);
  test_case "auth cannot silently substitute input" `Quick (auth_identity true);
  test_case "fresh detached proof cannot validate original input" `Quick (fresh_witness "direct");
  test_case "bound fresh detached proof cannot validate input" `Quick (fresh_witness "bound");
  test_case "test statement fresh witness cannot validate input" `Quick (fresh_witness "test");
  test_case "actual second parameter subject is retained" `Quick second_parameter;
  test_case "ordinary establish shape stays refused" `Quick establish_shape;
  test_case "partial calls have no input identity or returned proof" `Quick partial_application;
  test_case "nullary Unit calls transport returned proof" `Quick nullary;
  test_case "fresh transformed result compiles and runs" `Quick native;
]]
