open Alcotest

let replace before after = Str.global_replace (Str.regexp_string before) after
let occurrences needle text =
  let pattern = Str.regexp_string needle in
  let rec count start total =
    match Str.search_forward pattern text start with
    | position -> count (position + String.length needle) (total + 1)
    | exception Not_found -> total in
  count 0 0

let run postgres () =
  let path = Filename.concat (Sys.getenv "TESL_REPO_ROOT") "compiler/test/fixtures/keyed-insert-many.tesl" in
  let source = Source_input.read path in
  let source = if not postgres then source else source
    |> replace "[Database, Memory]" "[Database, Postgres, PostgresConfig, TcpConnection]"
    |> replace "backend: Memory" "backend: Postgres (PostgresConfig { dbName: \"unused\", user: \"unused\", password: \"\", connection: TcpConnection { host: \"127.0.0.1\", port: 5432 } })" in
  let checked = Compile.agent_context_result_source path source in
  if not checked.ok then fail checked.json;
  let artifacts = match Compile.compile_go_source path source with
    | Compile.GoSuccess files -> files
    | Compile.GoFailure diagnostics -> fail (Compile.diagnostics_to_json diagnostics) in
  let module_source = List.find (fun (a:Emit_go.artifact) -> Filename.basename a.path="module.go") artifacts in
  let all_source = String.concat "\n" (List.map (fun (a:Emit_go.artifact) -> a.contents) artifacts) in
  let prefix = if postgres then "Db" else "Table" in
  check int "nominal primary and nullable composite unique optimize" 1
    (occurrences ("teslrt." ^ prefix ^ "InsertManyKeyed(") module_source.contents);
  check int "secret primary and unsupported unique keep legacy path" 2
    (occurrences ("teslrt." ^ prefix ^ "InsertMany(") all_source);
  check bool "canonical Int key" true (occurrences ".Value.Key()" module_source.contents > 0);
  check bool "structured composite key" true
    (occurrences "teslrt.Tuple2[string, teslrt.Tuple2[string, bool]]" module_source.contents > 0);
  let root = Filename.temp_dir "tesl-memory-insert-many-" "" in
  Fun.protect ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ Filename.quote root))) (fun () ->
    List.iter (fun (a:Emit_go.artifact) ->
      let file = Filename.concat root a.path in
      ignore (Sys.command ("mkdir -p " ^ Filename.quote (Filename.dirname file)));
      Out_channel.with_open_bin file (fun channel -> output_string channel a.contents)) artifacts;
    let log = Filename.concat root "test.log" in
    let command = Printf.sprintf "cd %s && go test -race -count=1 -mod=readonly ./... > %s 2>&1"
      (Filename.quote root) (Filename.quote log) in
    if Sys.command command<>0 then fail (Source_input.read log);
    let command = Printf.sprintf "gofmt -l %s > %s" (Filename.quote root) (Filename.quote log) in
    if Sys.command command<>0 || String.trim (Source_input.read log)<>"" then
      fail ("generated Go formatting: " ^ Source_input.read log))

let () = Alcotest.run "compiled keyed Memory inserts" ["insertMany", [
  test_case "Memory constraints, rollback and fallback" `Quick (run false);
  test_case "PostgreSQL dispatch retains Memory behavior" `Quick (run true)]]
