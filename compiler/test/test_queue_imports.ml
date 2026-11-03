open Alcotest
let contains = Compile.string_contains
let replace a b = Str.global_substitute (Str.regexp_string a) (fun _ -> b)
let rec mkdir path = if not (Sys.file_exists path) then (mkdir (Filename.dirname path); Unix.mkdir path 0o700)
let rec remove path = if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then
  (Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path)
  else Sys.remove path
let write path source = mkdir (Filename.dirname path); Out_channel.with_open_bin path (fun out -> output_string out source)
let errors path source = (Compile.agent_context_result_source path source).diagnostics
  |> List.filter (fun (d : Compile.diagnostic) -> d.severity = "error")
let describe ds = String.concat "\n" (List.map (fun (d : Compile.diagnostic) ->
  Printf.sprintf "%s:%d:%d: %s" d.file (d.start_line + 1) (d.start_col + 1) d.message) ds)
let save path source = write path source; ignore (errors path source)
let accepts path source = match errors path source with [] -> () | ds -> fail (describe ds)
let refuses needle path source =
  let ds = errors path source in
  if not (List.exists (fun (d : Compile.diagnostic) -> contains d.message needle) ds) then
    failf "expected %S, got %s" needle (describe ds)
let schema = {|module Jobs exposing [Notify]
import Tesl.Prelude exposing [String]
record Notify { message: String }
|}
let source ~job ~parameter ~enqueue = Printf.sprintf {|module App exposing [send, handle]
import Tesl.Prelude exposing [String]
import Tesl.Database exposing [Database, Memory]
import Tesl.App exposing [App]
import Tesl.Queue exposing [Queue, Job, FromQueue, queueRead, queueWrite]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.ApiTest exposing [processNextJob, pendingJobCount, expectJobOk]
import Jobs exposing [Notify]
database Main = Database { entities: [], backend: Memory }
record Request { message: String }
handler post send(body: Request) -> String requires [queueWrite Tasks] =
  enqueue %s { message: body.message }
  "queued"
worker handle(job: %s ::: FromQueue (Id == jobId) job) requires [queueRead Tasks] = job
queue Tasks requires [queueRead Tasks] = Queue {
  database: Main
  jobs: [Job %s handle Nothing]
}
api Routes { post "/send" body body: Request -> String }
server Web for Routes { send }
main() -> App requires [queueRead Tasks, queueWrite Tasks] =
  App { database: Main, queues: [Tasks], api: Web }
api-test "prefixed payload dispatch" for Web requires [queueRead Tasks, queueWrite Tasks] {
  let response = post "/send" body { "message": "retained value" }
  expect response.status == 200
  expect pendingJobCount Tasks == 1
  let result = processNextJob Tasks
  let job = expectJobOk result
  expect job.message == "retained value"
  expect pendingJobCount Tasks == 0
}
|} enqueue parameter job
let baseline = source ~job:"Notify" ~parameter:"Notify" ~enqueue:"Notify"
let project f =
  let root = Filename.temp_file "tesl-queue-imports-" ".dir" in
  Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let path = Filename.concat root in
    write (path "tesl.toml") "";
    save (path "jobs.tesl") schema;
    f root path)
let native root path source =
  save (path "app.tesl") source;
  accepts (path "app.tesl") source;
  let artifacts = match Compile.compile_go_source (path "app.tesl") source with
    | Compile.GoSuccess artifacts -> artifacts
    | Compile.GoFailure ds -> fail (describe ds) in
  let main = (List.find (fun (a : Emit_go.artifact) -> a.path = "internal/teslmodapp/module.go") artifacts).contents in
  check bool "Main starts the declared queue" true (contains main "teslrt.StartWorkers(TasksQueue,");
  if contains source "queues: [Tasks, OtherTasks]" then
    check bool "Main also starts the other queue" true (contains main "teslrt.StartWorkers(OtherTasksQueue,");
  List.iter (fun (a : Emit_go.artifact) -> write (path ("built/" ^ a.path)) a.contents) artifacts;
  let command = Printf.sprintf "cd %s && GOMAXPROCS=2 go test -p 1 ./internal/teslmodapp -count=1 2>&1"
    (Filename.quote (Filename.concat root "built")) in
  let channel = Unix.open_process_in command in
  let output = In_channel.input_all channel in
  match Unix.close_process_in channel with Unix.WEXITED 0 -> () | _ -> fail output
let spelling_matrix () =
  if Sys.command "go version >/dev/null 2>&1" <> 0 then Alcotest.skip () else
  List.iter (fun job -> List.iter (fun parameter -> List.iter (fun enqueue ->
    project (fun root path -> native root path (source ~job ~parameter ~enqueue)))
    ["Notify"; "Jobs.Notify"]) ["Notify"; "Jobs.Notify"]) ["Notify"; "Jobs.Notify"]
let qualified_only () = project (fun root path ->
  native root path (source ~job:"Jobs.Notify" ~parameter:"Jobs.Notify" ~enqueue:"Jobs.Notify"
    |> replace "import Jobs exposing [Notify]" "import Jobs"))
let schema_prefix () = project (fun root path ->
  save (path "schema/tasks/v-current.tesl") (replace "module Jobs" "module Schema.Tasks.VCurrent" schema);
  native root path (source ~job:"Jobs.Notify" ~parameter:"Jobs.Notify" ~enqueue:"Jobs.Notify"
    |> replace "import Jobs exposing [Notify]" "import Jobs exposing []"
    |> replace "Jobs" "Schema.Tasks.VCurrent"))
let ownership () = project (fun _ path ->
  save (path "other.tesl") (replace "module Jobs" "module Other" schema);
  let imported = replace "import Jobs exposing [Notify]" "import Jobs exposing [Notify]\nimport Other" baseline in
  refuses "must accept exactly one" (path "app.tesl") (replace "job: Notify" "job: Other.Notify" imported);
  refuses "no queue declares job type" (path "app.tesl") (replace "enqueue Notify" "enqueue Other.Notify" imported);
  let duplicate = replace "jobs: [Job Notify handle Nothing]"
    "jobs: [Job Notify handle Nothing, Job Jobs.Notify handle Nothing]" imported in
  refuses "declared by 2 queues" (path "app.tesl") duplicate;
  refuses "requires" (path "app.tesl") (source ~job:"Jobs.Notify" ~parameter:"Notify" ~enqueue:"Notify"
    |> replace "send(body: Request) -> String requires [queueWrite Tasks]"
       "send(body: Request) -> String requires []"))
let imported_worker_owner () = project (fun _ path ->
  save (path "other.tesl") (replace "module Jobs" "module Other" schema);
  let worker imported = Printf.sprintf {|module Workers exposing [handle]
import Tesl.Queue exposing [FromQueue, queueRead]
import %s exposing [Notify]
worker handle(job: Notify ::: FromQueue (Id == jobId) job) requires [queueRead] = job
|} imported in
  let application = baseline
    |> replace "module App exposing [send, handle]" "module App exposing [send]"
    |> replace "import Jobs exposing [Notify]" "import Jobs exposing [Notify]\nimport Workers exposing [handle]"
    |> replace "worker handle(job: Notify ::: FromQueue (Id == jobId) job) requires [queueRead Tasks] = job\n" ""
    |> replace "queueRead Tasks" "queueRead" in
  save (path "workers.tesl") (worker "Jobs");
  accepts (path "app.tesl") application;
  save (path "workers.tesl") (worker "Other");
  refuses "must accept exactly one" (path "app.tesl") application)
let dead_queue_value () = project (fun root path ->
  save (path "other.tesl") (schema |> replace "module Jobs" "module Other" |> replace "Notify" "Tasks");
  let base = baseline
    |> replace "import Tesl.Queue exposing [" "import Tesl.Queue exposing [deadJobs, DeadJob, "
    |> replace "import Tesl.Prelude exposing [String]" "import Tesl.Prelude exposing [String, List]\nimport Tesl.List exposing [List.length]"
    |> replace "import Jobs exposing [Notify]" "import Jobs exposing [Notify]\nimport Other exposing [Tasks]"
    |> replace "queueRead Tasks" "queueRead" in
  let inspect ty = Printf.sprintf "fn inspect(value: %s) -> List DeadJob requires [queueRead] = deadJobs value\n" ty in
  let valid = base |> replace "api Routes" (inspect "Tasks" ^ "api Routes")
    |> replace "expect pendingJobCount Tasks == 0" "expect pendingJobCount Tasks == 0\n  expect List.length (inspect Tasks) == 0" in
  native root path valid;
  let invalid = base |> replace "api Routes" (inspect "Other.Tasks" ^ "api Routes") in
  refuses "requires a declared queue value" (path "app.tesl") invalid;
  refuses "requires a declared queue value" (path "app.tesl")
    (invalid |> replace "= deadJobs value" "=\n  let entries = deadJobs value\n  entries");
  match Compile.compile_go_source (path "app.tesl") invalid with
  | Compile.GoFailure _ -> ()
  | Compile.GoSuccess _ -> fail "payload escaped into a Go *Queue parameter")
let distinct_homonyms ?(collision = false) () = project (fun root path ->
  save (path "other.tesl") (schema |> replace "module Jobs" "module Other"
    |> fun text -> if collision then replace "Notify" "Tasks" text else text);
  let extra = {|worker other(job: Other.Notify ::: FromQueue (Id == jobId) job) requires [queueRead OtherTasks] = job
queue OtherTasks requires [queueRead OtherTasks] = Queue {
  database: Main
  jobs: [Job Other.Notify other Nothing]
}
handler post otherSend(body: Request) -> String requires [queueWrite OtherTasks] =
  enqueue Other.Notify { message: body.message }
  "queued other"
|} in
  let program = baseline
    |> replace "import Jobs exposing [Notify]" "import Jobs exposing [Notify]\nimport Other"
    |> replace "api Routes" (extra ^ "api Routes")
    |> replace "post \"/send\" body body: Request -> String }"
       "post \"/send\" body body: Request -> String\n post \"/other\" body body: Request -> String }"
    |> replace "server Web for Routes { send }" "server Web for Routes { send, otherSend }"
    |> replace "queues: [Tasks]" "queues: [Tasks, OtherTasks]"
    |> replace "main() -> App requires [queueRead Tasks, queueWrite Tasks]"
       "main() -> App requires [queueRead Tasks, queueRead OtherTasks, queueWrite Tasks, queueWrite OtherTasks]"
    |> fun source -> source ^ {|
api-test "same-named payloads use their own queues" for Web requires [queueRead Tasks, queueRead OtherTasks, queueWrite Tasks, queueWrite OtherTasks] {
  let first = post "/send" body { "message": "first" }
  let second = post "/other" body { "message": "second" }
  expect first.status == 200
  expect second.status == 200
  expect pendingJobCount Tasks == 1
  expect pendingJobCount OtherTasks == 1
  let original = expectJobOk (processNextJob Tasks)
  let otherResult = expectJobOk (processNextJob OtherTasks)
  expect original.message == "first"
  expect otherResult.message == "second"
  expect pendingJobCount Tasks == 0
  expect pendingJobCount OtherTasks == 0
}
 |} in
  native root path (if collision then program
    |> replace "import Other\n" "import Other exposing [Tasks]\n"
    |> replace "Other.Notify" "Other.Tasks" else program))
let () = run "Queue import identity" ["nominal payloads", List.map (fun (name, f) -> test_case name `Quick f)
  ["eight enqueue, Job and worker spellings execute", spelling_matrix;
   "qualified-only import executes", qualified_only;
   "full schema prefix and empty exposing execute", schema_prefix;
   "wrong owner, duplicate aliases and scoped effects refuse", ownership;
   "imported worker resolves its own imported payload", imported_worker_owner;
   "dead-letter inspection takes a queue value, not a payload", dead_queue_value;
   "same-named records remain distinct", distinct_homonyms ~collision:false;
   "queue value and imported payload names are distinct", distinct_homonyms ~collision:true]]
