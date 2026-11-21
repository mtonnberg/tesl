open Alcotest
let replace a b=Str.global_replace(Str.regexp_string a)b
let contains=Compile.string_contains
let rec mkdir p=if not(Sys.file_exists p)then(mkdir(Filename.dirname p);Unix.mkdir p 0o700)
let write p s=mkdir(Filename.dirname p);Out_channel.with_open_bin p(fun o->output_string o s)
let read p=In_channel.with_open_bin p In_channel.input_all
let rec remove p=if (Unix.lstat p).Unix.st_kind=Unix.S_DIR then(Array.iter(fun n->remove(Filename.concat p n))(Sys.readdir p);Unix.rmdir p)else Sys.remove p
let project f=let root=Filename.temp_dir "tesl-literal-proof-" ""in
 Fun.protect ~finally:(fun()->remove root)(fun()->let path=Filename.concat root in write(path "tesl.toml")"";f path)
let prefix={|module Rules exposing [IsPositive, take, make]
import Tesl.Prelude exposing [Int, Bool(..), String]
import Tesl.Maybe exposing [Maybe(..)]
fact IsPositive(n: Int) literal via tryPositive
establish tryPositive(n: Int) -> Maybe (value: Int ::: IsPositive value) =
  if n > 0 then
    Something (n ::: IsPositive n)
  else
    Nothing
fn take(n: Int ::: IsPositive n) -> Int = n
fn make() -> x: Int ::: IsPositive x =
  let x: Int ::: IsPositive x = 3
  x
|}
let check_source file source expected =
 let result=Compile.agent_context_result_source file source in
 check bool result.json expected result.ok;result
let checks ()=project(fun path->
 let file=path "Rules.tesl"in
 List.iter(fun(source,expected)->write file source;ignore(check_source file source expected))
  [prefix,true;replace "= 3" "= 0" prefix,false;replace "= 3" "= -1" prefix,false;
   replace "= 3" "= 99999999999999999999999999999999999999999999999999999" prefix,true;
   replace " literal via tryPositive" "" prefix,false;
   prefix ^ "\nfn unproven() -> Int = take 3\n",false;
   prefix ^ "\nfn dynamic(n: Int) -> Int =\n  let x: Int ::: IsPositive x = n\n  take x\n",false;
   prefix ^ "\nfn incomplete() -> Int =\n  case tryPositive 3 of\n    Something n -> n\n",false;
   replace "Something (n ::: IsPositive n)" "Something n" prefix,false;
   replace "literal via tryPositive" "literal via missing" prefix,false;
   replace "IsPositive x = 3" "IsPositive n = 3" prefix,false])
let imported ()=project(fun path->
 write(path "Rules.tesl")prefix;
 let source={|module Main exposing []
import Tesl.Prelude exposing [Int]
import Rules exposing [IsPositive, take]
fn result() -> Int =
  let x: Int ::: IsPositive x = 5
  take x
|}in
 let file=path "Main.tesl"in write file source;ignore(check_source file source true);
 write(path "Rules.tesl")(replace "n > 0" "n > 10" prefix |> replace "= 3" "= 13");
 ignore(check_source file source false);
 write(path "Rules.tesl")prefix;ignore(check_source file source true);
 let shadow=source |>replace "fn result" "fact IsPositive(n: Int)\nfn result" in
 write file shadow;ignore(check_source file shadow false))
let check_validator ()=project(fun path->
 let source=prefix |>replace "establish tryPositive(n: Int) -> Maybe (value: Int ::: IsPositive value)"
   "check tryPositive(n: Int) -> n: Int ::: IsPositive n" |>
   replace "Something (n ::: IsPositive n)" "ok n ::: IsPositive n" |>
   replace "    Nothing" "    fail 400 \"positive required\""in
 let file=path "Rules.tesl"in write file source;ignore(check_source file source true);
  let negative=replace "= 3" "= -3" source in write file negative;ignore(check_source file negative false))
let capability_diagnostics ()=project(fun path->
 let file=path "Rules.tesl"in
 let establish=prefix |> replace "fact IsPositive" "capability external\nfact IsPositive" |>
  replace "value: Int ::: IsPositive value) =" "value: Int ::: IsPositive value) requires [external] =" in
 let check=establish |>
  replace "establish tryPositive(n: Int) -> Maybe (value: Int ::: IsPositive value)"
    "check tryPositive(n: Int) -> n: Int ::: IsPositive n" |>
  replace "Something (n ::: IsPositive n)" "ok n ::: IsPositive n" |>
  replace "    Nothing" "    fail 400 \"positive required\"" in
 let message source =
  write file source;
  let result=check_source file source false in
  match List.find_opt(fun(d:Compile.diagnostic)->d.source="literal-proof")result.diagnostics with
  | None->fail "missing actionable literal-proof diagnostic"
  | Some d->
    Alcotest.check int "error points to literal rule" 4 d.start_line;
    List.iter(fun text->Alcotest.check bool ("diagnostic includes " ^ text) true(contains d.message text))
      ["IsPositive";"tryPositive";"requires [external]";"only available at runtime";
       "remove `literal via tryPositive`";"returned proof-carrying value"];
    d.message in
 Alcotest.check string "check and establish have identical capability guidance" (message establish)(message check);
 List.iter(fun(source,body)->
  let end_of_declarations=Str.search_forward(Str.regexp_string "fn make()")source 0 in
  let source=String.sub source 0 end_of_declarations |> replace " literal via tryPositive" "" |>
    replace ", make]" ", runtime]" in
  let source=source ^ body in write file source;ignore(check_source file source true))
  [establish,"\nfn runtime(n: Int) -> Maybe (value: Int ::: IsPositive value) requires [external] = tryPositive n\n";
   check,"\nfn runtime(n: Int) -> Int ? IsPositive requires [external] =\n  let value = check tryPositive(n)\n  value\n"];
 let helper=prefix |> replace "fact IsPositive" "capability external\nfact IsPositive" |>
  replace "n > 0" "needsContext n > 0" in
 let helper=helper ^ "\nfn needsContext(n: Int) -> Int requires [external] = n\n" in
 let diagnostic=message helper in
 Alcotest.check bool "transitive capability names responsible helper" true(contains diagnostic "Rules.needsContext"))
let strings ()=project(fun path->
 let source={|module Rules exposing []
import Tesl.Prelude exposing [String, Int, Bool(..)]
import Tesl.String exposing [String.trim, String.length]
import Tesl.Maybe exposing [Maybe(..)]
fact Good(s: String) literal via tryGood
establish tryGood(raw: String) -> Maybe (value: String ::: Good value) =
  let value = String.trim raw
  if String.length value > 0 && String.length value <= 2 then
    Something (value ::: Good value)
  else
    Nothing
fn accepted() -> value: String ::: Good value =
  let value: String ::: Good value = "å🙂"
  value
|}in
 let file=path "Rules.tesl"in
 List.iter(fun(value,ok)->let source=replace "\"å🙂\"" value source in write file source;ignore(check_source file source ok))
   ["\"å🙂\"",true;"\"å🙂x\"",false;"\" å🙂 \"",false;"\"\"",false])
let bad_rules ()=project(fun path->
 let file=path "Rules.tesl"in
 List.iter(fun source->write file source;ignore(check_source file source false))
  [prefix |>replace "fact IsPositive" "capability external\nfact IsPositive" |>replace "value: Int ::: IsPositive value) =" "value: Int ::: IsPositive value) requires [external] =";
   replace "n > 0" "n > 0" prefix |>replace "Something (n ::: IsPositive n)" "tryPositive n";
   prefix |>replace "  if n > 0 then" "  let changed = n + 1\n  if n > 0 then" |>replace "Something (n ::: IsPositive n)" "Something (changed ::: IsPositive changed)";
   prefix |>replace "establish tryPositive(n: Int)" "establish tryPositive(n: Int ::: IsPositive n)";
   prefix |>replace "literal via tryPositive" "literal via make";
   prefix |>replace "Something (n ::: IsPositive n)" "Something (n ::: Different n)" |>replace "fact IsPositive" "fact Different(n: Int)\nfact IsPositive"])
let bools_and_conjunctions ()=project(fun path->
 let source=prefix ^ {|
fact IsEven(n: Int) literal via tryEven
establish tryEven(n: Int) -> Maybe (value: Int ::: IsEven value) =
  if n % 2 == 0 then
    Something (n ::: IsEven n)
  else
    Nothing
fact Enabled(b: Bool) literal via tryEnabled
establish tryEnabled(b: Bool) -> Maybe (value: Bool ::: Enabled value) =
  if b then
    Something (b ::: Enabled b)
  else
    Nothing
fn both() -> x: Int ::: IsPositive x && IsEven x =
  let x: Int ::: IsPositive x && IsEven x = 4
  x
fn enabled() -> b: Bool ::: Enabled b =
  let b: Bool ::: Enabled b = True
  b
|}in
 let file=path "Rules.tesl"in write file source;ignore(check_source file source true);
 let bad=replace "= 4" "= 3" source in write file bad;ignore(check_source file bad false);
 let bad=replace "= True" "= False" source in write file bad;ignore(check_source file bad false))
let native ()=project(fun path->
 let source=prefix ^ {|
test "literal bindings work in test blocks" {
  let x: Int ::: IsPositive x = 9
  expect take x == 9
  expect make() == 3
}
|}in
 let file=path "Rules.tesl"in write file source;ignore(check_source file source true);
 let artifacts=match Compile.compile_go_source file source with
  | Compile.GoSuccess xs->xs|Compile.GoFailure ds->fail(Compile.diagnostics_to_json ds)in
 List.iter(fun(a:Emit_go.artifact)->write(path("out/" ^ a.path))a.contents)artifacts;
 let log=path "native.log"in
 if Sys.command(Printf.sprintf "cd %s && GOMAXPROCS=2 go test -p 1 -count=1 -v ./... > %s 2>&1" (Filename.quote(path "out"))(Filename.quote log))<>0 then fail(read log);
 check bool "actual literal proof test executed" true(contains(read log)"--- PASS:"))
let isolation ()=project(fun path->
 let file=path "Rules.tesl"in
 let cases=[
  prefix ^ "\nfn unrelated() -> Int =\n  let x = 3\n  take x\n",false;
  prefix ^ "\nfn shadowed() -> Int =\n  let x: Int ::: IsPositive x = 3\n  let x = -1\n  take x\n",false;
  prefix ^ "\nfact Other(n: Int)\nfn unrelatedFact() -> Int =\n  let x: Int ::: IsPositive x && Other x = 3\n  take x\n",false;
  prefix ^ "\nfn alias() -> Int =\n  let x: Int ::: IsPositive x = 3\n  let y = x\n  take y\n",true;
  (replace "Something (n ::: IsPositive n)" "helper n" prefix ^
   "\nfn helper(n: Int) -> Maybe (value: Int ::: IsPositive value) =\n  Something (n ::: IsPositive n)\n"),false;
  prefix |> replace "n > 0" "n / 0 > 0",false;
  prefix |> replace "= 3" ("= " ^ String.make 4097 '9'),false;
  prefix |> replace "n > 0" "n * n > 0" |> replace "= 3" ("= " ^ String.make 400 '9'),false
 ]in
 List.iter(fun(source,expected)->write file source;ignore(check_source file source expected))cases)
let overlays ()=project(fun path->
 let rule=path "Rules.tesl"and file=path "Main.tesl"in write rule prefix;
 let source={|module Main exposing []
import Tesl.Prelude exposing [Int]
import Rules exposing [IsPositive, take]
fn result() -> Int =
  let x: Int ::: IsPositive x = 5
  take x
|}in write file source;
 Source_input.with_overlays ~project_root:(path "") [rule,replace "n > 0" "n > 10" prefix |> replace "= 3" "= 13"]
  (fun()->ignore(check_source file source false));
 ignore(check_source file source true);
 let invalid=replace "= 5" "= -5" source in
 ignore(check_source file invalid false);
 ignore(check_source file source true))
let arithmetic_runtime ()=project(fun path->
 let values=["-8";"8";"-99999999999999999999999999999999999999";"99999999999999999999999999999999999999"]in
 let source={|module Arithmetic exposing []
import Tesl.Prelude exposing [Int, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
fact Arithmetic(n: Int) literal via validate
establish validate(n: Int) -> Maybe (value: Int ::: Arithmetic value) =
  if n / 7 * 7 + n % 7 == n && ((n < 0 && n % 7 <= 0) || (n >= 0 && n % 7 >= 0)) && n * n - n * (n - 1) == n then
    Something (n ::: Arithmetic n)
  else
    Nothing
fn runtimeAccepts(n: Int) -> Bool =
  case validate n of
    Something value -> True
    Nothing -> False
|} ^ String.concat "\n"(List.mapi(fun i n->Printf.sprintf {|
test "arithmetic agreement %d" {
  let x: Int ::: Arithmetic x = %s
  expect runtimeAccepts x
}
|}i n)values)in
 let file=path "Arithmetic.tesl"in write file source;ignore(check_source file source true);
 let artifacts=match Compile.compile_go_source file source with
  | Compile.GoSuccess xs->xs|Compile.GoFailure ds->fail(Compile.diagnostics_to_json ds)in
 List.iter(fun(a:Emit_go.artifact)->write(path("out/" ^ a.path))a.contents)artifacts;
 let log=path "native.log"in
 if Sys.command(Printf.sprintf "cd %s && GOMAXPROCS=2 go test -p 1 -count=1 -v ./... > %s 2>&1" (Filename.quote(path "out"))(Filename.quote log))<>0 then fail(read log);
 check bool "runtime validators agree with compiled literal proofs" true(contains(read log)"--- PASS:"))
let metadata ()=project(fun path->
 let file=path "Rules.tesl"in write file prefix;
 let bindings=Compile.local_bindings_source file prefix in
 check bool "refined literal type is visible to tooling" true(List.exists(fun(b:Compile.local_binding)->b.name="x" && contains b.ty "IsPositive")bindings);
 let lines=String.split_on_char '\n' prefix in
 let col=Str.search_forward(Str.regexp_string "tryPositive")(List.nth lines 3)0 in
 (match Compile.definition_source file prefix 3 col with
  | Some location->check int "literal rule navigates to its validator" 4 location.line
  | None->fail "literal rule lost its definition link");
 check int "validator occurrences include its literal rule" 2
  (List.length(Compile.occurrences_source file prefix 3 col));
 let formatted=Formatter.format_source prefix in ignore(check_source file formatted true))
let captured_sources ()=project(fun path->
 let file=path "Rules.tesl"in write file prefix;
 let m=match Parser.parse_module file prefix with Parser.Ok m->m|Parser.Err e->fail e.msg in
 (match Literal_proof.with_graph ~entry:file [m,prefix](fun()->write file(prefix ^ "# concurrent change\n");true)with
  | Error _->()|Ok _->fail "source drift published a literal proof graph");
 write file prefix;
 let caller={|module Main exposing []
import Tesl.Prelude exposing [Int]
import Rules exposing [IsPositive, take]
fn result() -> Int =
  let x: Int ::: IsPositive x = 5
  take x
test "imported literal rule" { expect result() == 5 }
|}in
 let entry=path "Main.tesl"in write entry caller;
 match Compile.compile_go_source entry caller with
 | Compile.GoSuccess _->()
 | Compile.GoFailure ds->fail(Compile.diagnostics_to_json ds))
let schema_identity ()=project(fun path->
 let common=prefix ^ "\nestablish tryOther(n: Int) -> Maybe (value: Int ::: IsPositive value) =\n  tryPositive n\n"in
 let previous=path "schema/notes/v1.tesl"and current=path "schema/notes/v-current.tesl"in
 write previous(replace "module Rules" "module NotesSchema.V1" common);
 write current(replace "module Rules" "module NotesSchema.VCurrent" common);
 let load file=match Migration_inventory.load ~compiler_abi:"literal-rule-test" ~root_file:file with
  | Ok i->i|Error e->fail e.message in
 let before=load previous and after=load current in
 let same after=Migration_inventory.verify_same ~before ~after
   ~previous:(Migration_ir.Predicate,"NotesSchema.V1.IsPositive") ~current:(Migration_ir.Predicate,"NotesSchema.VCurrent.IsPositive")in
 (match same after with Ok _->()|Error e->fail e.message);
 write current(replace "module Rules" "module NotesSchema.VCurrent" common |> replace "n > 0" "n > 1");
 (match same(load current)with Error _->()|Ok _->fail "changing the validator body did not change fact identity");
 write current(replace "module Rules" "module NotesSchema.VCurrent" common);
 write current(read current |> replace "literal via tryPositive" "literal via tryOther");
 (match same(load current)with Error _->()|Ok _->fail "changing a literal rule did not change fact identity"))
let row_artifacts ()=project(fun path->
 let schema=replace "module Rules" "module Schema.Notes.VCurrent" prefix ^
  "\nentity Note table \"notes\" primaryKey id { id: String, amount: Int ::: IsPositive amount }\n"in
 write(path "schema/notes/v-current.tesl")schema;
 let source={|module App exposing []
import Tesl.Prelude exposing [Int]
import Tesl.Env exposing [env, envInt, envRead]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection, MigrationConfig, Worker]
import Schema.Notes.VCurrent exposing [IsPositive, take, make]
database Main = Database {
  schema: Schema.Notes.VCurrent
  migrations: Schema.Notes.Migrate
  backend: Postgres (PostgresConfig {
    namespace: "notes"
    dbName: env "NOTES_DB_NAME"
    user: env "NOTES_DB_USER"
    password: env "NOTES_DB_PASSWORD"
    connection: TcpConnection { host: env "NOTES_DB_HOST", port: envInt "NOTES_DB_PORT" 5432 }
    migrations: MigrationConfig {
      topology: Worker
      controlOwner: env "NOTES_CONTROL_OWNER"
      requestRole: env "NOTES_REQUEST_ROLE"
      workerRole: env "NOTES_WORKER_ROLE"
      ddlConnection: env "NOTES_DDL_CONNECTION"
    }
  })
}
test "literal proofs survive row source capture and lowering" {
  let x: Int ::: IsPositive x = 5
  expect take x == 5
  expect make() == 3
}
|}in
 let file=path "App.tesl"in write file source;
 let artifacts=match Compile.compile_go_source file source with
  | Compile.GoSuccess xs->xs|Compile.GoFailure ds->fail(Compile.diagnostics_to_json ds)in
 List.iter(fun(a:Emit_go.artifact)->write(path("out/" ^ a.path))a.contents)artifacts;
 let log=path "native.log"in
 if Sys.command(Printf.sprintf "cd %s && GOMAXPROCS=2 go test -p 1 -count=1 -v ./... > %s 2>&1" (Filename.quote(path "out"))(Filename.quote log))<>0 then fail(read log);
 check bool "captured row application runs literal proofs" true(contains(read log)"--- PASS:"))
let ()=run "explicit literal proof rules" ["rules",[
 test_case "literal introduction is explicit and value-specific" `Quick checks;
 test_case "imported rules recheck dependencies and preserve ownership" `Quick imported;
 test_case "pure check validators can reject constants" `Quick check_validator;
 test_case "capability-dependent check and establish explain runtime validation" `Quick capability_diagnostics;
 test_case "Unicode and normalization preserve the literal value" `Quick strings;
 test_case "impure, recursive, mismatched and forged rules refuse" `Quick bad_rules;
 test_case "Bool and conjunctions use declared validators" `Quick bools_and_conjunctions;
 test_case "ordinary native execution needs no runtime check" `Quick native;
 test_case "tooling and formatting retain the literal rule" `Quick metadata;
 test_case "captured compilation guards literal rule sources" `Quick captured_sources;
 test_case "literal rules participate in frozen fact identity" `Quick schema_identity;
 test_case "evidence stays scoped and evaluation stays bounded" `Quick isolation;
 test_case "unsaved inputs cannot reuse stale literal evidence" `Quick overlays;
 test_case "bounded integer evaluation agrees with native arithmetic" `Quick arithmetic_runtime;
 test_case "row application capture retains literal validation" `Quick row_artifacts]]
