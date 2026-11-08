open Alcotest

let replace before after = Str.global_replace (Str.regexp_string before) after
let occurrences needle text =
  let pattern = Str.regexp_string needle in
  let rec count start total =
    match Str.search_forward pattern text start with
    | position -> count (position + String.length needle) (total + 1)
    | exception Not_found -> total in
  count 0 0
let fixture () =
  let root = Sys.getenv "TESL_REPO_ROOT" in
  let path = Filename.concat root "compiler/test/fixtures/bounded-memory.tesl" in
  path,Source_input.read path

let run postgres () =
  let path,source = fixture () in
  let source = if not postgres then source else source
    |> replace "[Database, Memory]" "[Database, Postgres, PostgresConfig, TcpConnection]"
    |> replace "backend: Memory" "backend: Postgres (PostgresConfig { dbName: \"unused\", user: \"unused\", password: \"\", connection: TcpConnection { host: \"127.0.0.1\", port: 5432 } })" in
  let checked = Compile.agent_context_result_source path source in
  if not checked.ok then fail checked.json;
  let artifacts = match Compile.compile_go_source path source with
    | Compile.GoSuccess files -> files
    | Compile.GoFailure diagnostics -> fail (Compile.diagnostics_to_json diagnostics) in
  let module_source = List.find (fun (a:Emit_go.artifact) -> Filename.basename a.path="module.go") artifacts in
  let prefix = if postgres then "Db" else "Table" in
  check int "all bounded strict selectors emitted" 5
    (occurrences ("teslrt." ^ prefix ^ "SelectTop(") module_source.contents);
  check int "ordered selectOne optimized" 1
    (occurrences ("teslrt." ^ prefix ^ "SelectOneTop(") module_source.contents);
  let legacy = if postgres then "DbSelectOne(" else "TableSelectOneSorted(" in
  check int "IEEE Float and wrapped Float keep legacy ordering" 2
    (occurrences ("teslrt." ^ legacy) module_source.contents);
  let root = Filename.temp_dir "tesl-memory-selection-" "" in
  Fun.protect ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote root))) (fun () ->
    List.iter (fun (a:Emit_go.artifact) ->
      let file = Filename.concat root a.path in
      ignore (Sys.command ("mkdir -p " ^ Filename.quote (Filename.dirname file)));
      Out_channel.with_open_bin file (fun channel -> output_string channel a.contents)) artifacts;
    let log = Filename.concat root "test.log" in
    let command = Printf.sprintf "cd %s && go test -race -count=1 -mod=readonly ./... > %s 2>&1"
      (Filename.quote root) (Filename.quote log) in
    if Sys.command command<>0 then fail (Source_input.read log))

let () = Alcotest.run "compiled bounded Memory queries" ["selection", [
  test_case "Memory queries and NaN compatibility" `Quick (run false);
  test_case "PostgreSQL dispatch retains Memory semantics" `Quick (run true)]]
