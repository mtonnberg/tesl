open Alcotest
let rec mkdir p = if not(Sys.file_exists p) then (mkdir(Filename.dirname p);Unix.mkdir p 0o700)
let write p s = mkdir(Filename.dirname p);Out_channel.with_open_bin p(fun o->output_string o s)
let rec remove p = match(Unix.lstat p).Unix.st_kind with
 | Unix.S_DIR -> Array.iter(fun n->remove(Filename.concat p n))(Sys.readdir p);Unix.rmdir p
 | _ -> Sys.remove p
let repository ()=Unix.realpath(Option.get(Sys.getenv_opt "TESL_REPO_ROOT"))
let command directory log text =
 let status=Sys.command(Printf.sprintf "cd %s && %s > %s 2>&1" (Filename.quote directory) text(Filename.quote log)) in
 if status<>0 then fail(text ^ "\n" ^ Source_input.read log)
let rec copy source target = match(Unix.lstat source).Unix.st_kind with
 | Unix.S_DIR -> mkdir target;Array.iter(fun name->
    if not(String.starts_with ~prefix:"_build" name) &&
       not(List.mem name [".git";".tesl-stuff";"node_modules";"elm-stuff"]) then
      copy(Filename.concat source name)(Filename.concat target name))(Sys.readdir source)
 | Unix.S_REG -> write target(Source_input.read source)
 | _ -> fail("unexpected special compiler input " ^ source)
let export output =
 let repo=repository() in
 let abi=Result.get_ok(Migration_abi.current()) in
 write(Filename.concat output "identity.json") (Yojson.Basic.to_string(`Assoc[
  "compilerAbi",`String(Migration_abi.id abi);
  "storedValueCompatibility",`String(Migration_abi.stored_value_compatibility abi)]));
 command(Filename.concat repo "compiler")(Filename.concat output "export.log")
  (Printf.sprintf "TESL_ROW_SETTLED_EXPORT=%s timeout 180s _build/default/test/test_migration_row_access.exe" (Filename.quote output))
let native () =
 let repo=repository() and output=Filename.temp_dir "tesl-empty-contract-abi-" "" in
 Fun.protect ~finally:(fun()->if Sys.getenv_opt "TESL_KEEP_ROW_CONTRACT_ABI_TEST"=None then remove output)(fun()->
  export output;
  let clone=Filename.concat output "compiler-b" in mkdir clone;
  List.iter(fun p->copy(Filename.concat repo p)(Filename.concat clone p))
   ["compiler";"runtime/go";"tesl";"manual";"dev-docs";"example";"README.md";"INSTALL.md";"LANGUAGE-SPEC.md"];
  let query=Filename.concat clone "compiler/lib/compiler_query.ml" in
  write query(Source_input.read query ^ "\n(* Empty-retirement compiler build provenance regression. *)\n");
  let compiler=Filename.concat clone "compiler" in
  command compiler(Filename.concat output "compiler-b-build.log")
   "timeout 240s dune build -j 2 test/test_migration_row_contract_abi.exe test/test_migration_row_access.exe";
  let boutput=Filename.concat output "other-build" in
  command compiler(Filename.concat output "compiler-b-export.log")
   (Printf.sprintf "TESL_REPO_ROOT=%s TESL_ROW_CONTRACT_ABI_EXPORT=%s timeout 180s _build/default/test/test_migration_row_contract_abi.exe" (Filename.quote clone)(Filename.quote boutput));
  Unix.rename(Filename.concat boutput "v2")(Filename.concat output "v2b");
  Unix.rename(Filename.concat boutput "identity.json")(Filename.concat output "identity-b.json");
  (* Retained executables run with no Tesl source, generated Go or loose metadata. *)
  remove clone;remove boutput;
  List.iter(fun version->let dir=Filename.concat output version in
    Array.iter(fun n->if n<>"app" then remove(Filename.concat dir n))(Sys.readdir dir)) ["v1";"v2";"v2b";"v2query"];
  command(Filename.concat repo "runtime/go")(Filename.concat output "postgres.log")
   (Printf.sprintf "TESL_ROW_CONTRACT_ABI_PROGRAMS=%s timeout 240s go test -p 1 -race -tags tesl_migration_test -timeout 210s ./teslrt -run '^TestPgRowEmptyContractABI$' -count=1 -v"(Filename.quote output));
  if Sys.getenv_opt "TESL_KEEP_ROW_CONTRACT_ABI_TEST"<>None then Printf.printf "retained empty-contract ABI fixture: %s\n%!" output)
let ()=match Sys.getenv_opt "TESL_ROW_CONTRACT_ABI_EXPORT" with
 | Some output->export output
 | None->run "empty retirement across compiler builds" ["PostgreSQL",[
    test_case "actual A/B empty retirement and first-write races" `Quick native]]
