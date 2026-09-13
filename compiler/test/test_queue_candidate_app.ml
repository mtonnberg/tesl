(** A compiled full App is the witness: schema/job identities, codecs, HTTP
    handlers and workers all come from Tesl. The Go bridge only provisions a
    private PostgreSQL candidate and supplies deterministic scheduling. *)
open Alcotest

let rec mkdir path =
  if not (Sys.file_exists path) then (mkdir (Filename.dirname path); Unix.mkdir path 0o700)
let read path = In_channel.with_open_bin path In_channel.input_all
let write path source =
  mkdir (Filename.dirname path);
  Out_channel.with_open_bin path (fun channel -> output_string channel source)
let rec remove path =
  if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  end else Sys.remove path
let fixture () =
  let rec find path =
    let candidates = [Filename.concat path "fixtures/queue-candidate-app";
      Filename.concat path "compiler/test/fixtures/queue-candidate-app"] in
    match List.find_opt (fun candidate -> Sys.file_exists (Filename.concat candidate "app.tesl")) candidates with
    | Some path -> path
    | None -> let parent = Filename.dirname path in
      if parent = path then fail "queue candidate fixture missing" else find parent
  in
  match Sys.getenv_opt "TESL_REPO_ROOT" with
  | Some root -> find root
  | None -> find (Sys.getcwd ())
let describe diagnostics =
  String.concat "\n" (List.map (fun (d : Compile.diagnostic) -> d.code ^ ": " ^ d.message) diagnostics)
let sources = ["app.tesl"; "schema/tasks/v-current.tesl"; "schema/tasks/v-current/detail.tesl"]
let with_project run =
  let root = Filename.temp_file "tesl-compiled-queue-" ".dir" in
  Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let fixture = fixture () in
    write (Filename.concat root "tesl.toml") "";
    List.iter (fun name -> write (Filename.concat root name) (read (Filename.concat fixture name))) sources;
    List.iter (fun name ->
      let path = Filename.concat root name in
      let diagnostics = (Compile.agent_context_result_source path (read path)).diagnostics in
      let errors = List.filter (fun (d : Compile.diagnostic) -> d.severity = "error") diagnostics in
      if errors <> [] then fail (describe errors)) sources;
    run fixture root)
let emit root =
  let path = Filename.concat root "app.tesl" in
  match Compile.compile_go_file path with
  | Compile.GoSuccess artifacts -> artifacts
  | Compile.GoFailure diagnostics -> fail (describe diagnostics)
let checked_source () = with_project (fun _ root -> ignore (emit root))
let native () = with_project (fun fixture root ->
  if Sys.command "go version >/dev/null 2>&1" <> 0 then skip ();
  let output = Filename.concat root "generated" in
  List.iter (fun (artifact : Emit_go.artifact) ->
    write (Filename.concat output artifact.path) artifact.contents) (emit root);
  (* The generated binary must use compiler literals, not a loose sidecar. *)
  List.iter (fun name -> Sys.remove (Filename.concat output name)) ["queue-history.json"; "migration-history.json"];
  List.iter (fun (source, target) ->
    write (Filename.concat output target) (read (Filename.concat fixture source)))
    ["candidate_bridge.go", "internal/teslrt/candidate_bridge.go";
     "candidate_app_test.go", "internal/teslmodapp/candidate_app_test.go"];
  let command = Printf.sprintf
    "cd %s && GOMAXPROCS=2 go test -race -p 2 ./internal/teslmodapp -run '^TestCompiledCandidateApplication$' -count=1 -v 2>&1"
    (Filename.quote output) in
  let channel = Unix.open_process_in command in
  let result = In_channel.input_all channel in
  match Unix.close_process_in channel with
  | Unix.WEXITED 0 ->
    (* Surface the native evidence and explicit PostgreSQL skip, if unconfigured. *)
    print_string result
  | _ -> fail result)
let () = run "Compiled queued PostgreSQL App"
  ["candidate boundary", [test_case "full App and nested proof codec compile" `Quick checked_source;
    test_case "actual emitted handlers and workers on PostgreSQL" `Slow native]]
