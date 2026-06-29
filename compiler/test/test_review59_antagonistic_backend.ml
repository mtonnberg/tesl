(** Regression tests for backend.tesl correctness cases.

    These tests verify that the compiler correctly rejects the patterns that
    were previously documented as `_shouldNotWork` in example/chat/backend.tesl.
    The patterns were moved here to keep the example file clean while ensuring
    regressions in the compiler's enforcement are caught.

    Covers:
    1. ForAll SQL WHERE must use the declared subject variable (not a different binding)
    2. ForAll SQL WHERE must use a variable (not a literal string)
    3. ForAll SQL WHERE must use the declared parameter (not a different parameter)
    4. Existential insert id must be the witness variable (not a literal)
    5. Existential insert id must be the witness (not a different binding)
    6. Existential insert id must be the witness (not a different parameter)
    7. deadWorker publish without pubsub capability is rejected
*)

open Alcotest

let compiler =
  match Sys.getenv_opt "TESL_OCAML_COMPILER" with
  | Some p when Sys.file_exists p -> p
  | _ ->
    (match Sys.getenv_opt "TESL_BIN" with
     | Some v when Filename.basename v = "main.exe" && Sys.file_exists v -> v
     | _ ->
       let dir = Filename.dirname Sys.argv.(0) in
       let candidate = Filename.concat (Filename.dirname dir) "bin/main.exe" in
       let candidate2 = Filename.concat dir "../bin/main.exe" in
       if Sys.file_exists candidate then candidate
       else if Sys.file_exists candidate2 then candidate2
       else "tesl")

let run_command cmd =
  let ic = Unix.open_process_in cmd in
  let out = In_channel.input_all ic in
  let status = Unix.close_process_in ic in
  let code = match status with
    | Unix.WEXITED c -> c
    | Unix.WSIGNALED n -> 128 + n
    | Unix.WSTOPPED n -> 128 + n
  in
  (code, out)

let run_compiler args =
  let quoted = Filename.quote compiler :: List.map Filename.quote args in
  run_command (String.concat " " quoted ^ " 2>&1")

let failf fmt = Printf.ksprintf failwith fmt

let with_temp_file content f =
  let dir = Filename.temp_dir "tesl-r59b" "" in
  let name =
    let re = Str.regexp "module[ \\t\\n]+\\([A-Z][A-Za-z0-9_]*\\)" in
    try
      ignore (Str.search_forward re content 0);
      let mname = Str.matched_group 1 content in
      let buf = Buffer.create (String.length mname + 4) in
      String.iteri (fun i c ->
        if i = 0 then Buffer.add_char buf (Char.lowercase_ascii c)
        else if c >= 'A' && c <= 'Z' then begin
          Buffer.add_char buf '-';
          Buffer.add_char buf (Char.lowercase_ascii c)
        end else
          Buffer.add_char buf c
      ) mname;
      Buffer.contents buf ^ ".tesl"
    with Not_found -> "test.tesl"
  in
  let path = Filename.concat dir name in
  let oc = open_out path in
  output_string oc content;
  close_out oc;
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let should_fail pattern src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code = 0 then failf "expected failure matching %S, but compilation succeeded" pattern;
    let re = Str.regexp_case_fold pattern in
    try ignore (Str.search_forward re out 0)
    with Not_found -> failf "expected failure matching %S, got:\n%s" pattern out)

let should_pass src =
  with_temp_file src (fun path ->
    let code, out = run_compiler ["--check"; path] in
    if code <> 0 then failf "expected compilation success, got:\n%s" out)

let base_header = {|#lang tesl
module BackendTest exposing []

import Tesl.Prelude exposing [String, List]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Queue exposing [queueRead, queueWrite, pubsub, FromDeadQueue]
import Tesl.String exposing [String.length]
import Tesl.Random exposing [random]
import Tesl.Id exposing [generatePrefixedId]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]

fact ValidRoomId (id: String)
check checkRoomId(id: String) -> id: String ::: ValidRoomId id =
  if String.length id > 0 then
    ok id ::: ValidRoomId id
  else
    fail 400 "invalid"

entity Message table "messages" primaryKey id {
  id: String
  roomId: String @db(text)
}

database DB = Database {
  schema: "chat"
  entities: [Message]
  backend: Postgres (PostgresConfig {
    dbName: env "DB"
    user: env "U"
    password: env "P"
    connection: TcpConnection { host: env "H"  port: 5432 }
  })
}

|}

(* ── R59B_FA — ForAll SQL WHERE subject must match the declared variable ─── *)

let test_R59B_FA01_forall_where_different_binding () =
  (* getMessages_shouldNotWork: WHERE uses a different let-binding, not roomId *)
  should_fail "WHERE clause uses.*but return spec declares" (base_header ^ {|
handler badHandler(roomId: String ::: ValidRoomId roomId)
  -> List Message ? ForAll (FromDb (RoomId == roomId))
  requires [dbRead] =
  let sneaky = "sneaky2"
  select m from Message where m.roomId == sneaky
|})

let test_R59B_FA02_forall_where_literal () =
  (* getMessages_shouldNotWork2: WHERE uses a string literal, not roomId *)
  should_fail "WHERE condition does not match.*use parameter.*not a literal" (base_header ^ {|
handler badHandler(roomId: String ::: ValidRoomId roomId)
  -> List Message ? ForAll (FromDb (RoomId == roomId))
  requires [dbRead] =
  select m from Message where m.roomId == "sneaky"
|})

let test_R59B_FA03_forall_where_different_param () =
  (* getMessages_shouldNotWork3: WHERE uses a different parameter, not roomId *)
  should_fail "WHERE clause uses.*but return spec declares" (base_header ^ {|
handler badHandler(roomId: String ::: ValidRoomId roomId,
                   sneakyRoomId: String ::: ValidRoomId sneakyRoomId)
  -> List Message ? ForAll (FromDb (RoomId == roomId))
  requires [dbRead] =
  select m from Message where m.roomId == sneakyRoomId
|})

let test_R59B_FA04_forall_where_correct_compiles () =
  (* Correct: WHERE uses roomId to match the ForAll proof *)
  should_pass (base_header ^ {|
handler goodHandler(roomId: String ::: ValidRoomId roomId)
  -> List Message ? ForAll (FromDb (RoomId == roomId))
  requires [dbRead] =
  select m from Message where m.roomId == roomId
|})

(* ── R59B_EX — Existential insert id must be the witness variable ──────── *)

let base_exists = base_header ^ {|
record PostReq { content: String }

|}

let test_R59B_EX01_insert_id_literal () =
  (* postMessage_shouldNotWork: insert uses a literal "sneaky" for id, not msgId *)
  should_fail "insert uses a literal for.*id.*witness" (base_exists ^ {|
handler badPost(roomId: String ::: ValidRoomId roomId)
  -> exists msgId: String => Message ? FromDb (Id == msgId)
  requires [dbWrite, random] =
  let msgId = generatePrefixedId "msg"
  exists msgId =>
    insert Message { id: "sneaky", roomId: roomId }
|})

let test_R59B_EX02_insert_id_different_binding () =
  (* postMessage_shouldNotWork2: insert uses a different binding, not msgId *)
  should_fail "insert uses.*id.*but return spec declares.*do not match" (base_exists ^ {|
handler badPost(roomId: String ::: ValidRoomId roomId)
  -> exists msgId: String => Message ? FromDb (Id == msgId)
  requires [dbWrite, random] =
  let msgId = generatePrefixedId "msg"
  let sneaky = generatePrefixedId "msg"
  exists msgId =>
    insert Message { id: sneaky, roomId: roomId }
|})

let test_R59B_EX03_insert_id_different_param () =
  (* postMessage_shouldNotWork3: insert uses a different parameter, not msgId *)
  should_fail "insert uses.*id.*but return spec declares.*do not match" (base_exists ^ {|
handler badPost(roomId: String ::: ValidRoomId roomId,
                sneaky: String ::: ValidRoomId sneaky)
  -> exists msgId: String => Message ? FromDb (Id == msgId)
  requires [dbWrite, random] =
  let msgId = generatePrefixedId "msg"
  exists msgId =>
    insert Message { id: sneaky, roomId: roomId }
|})

let test_R59B_EX04_insert_correct_compiles () =
  (* Correct: insert uses msgId (the witness variable) for id *)
  should_pass (base_exists ^ {|
handler goodPost(roomId: String ::: ValidRoomId roomId)
  -> exists msgId: String => Message ? FromDb (Id == msgId)
  requires [dbWrite, random] =
  let msgId = generatePrefixedId "msg"
  exists msgId =>
    insert Message { id: msgId, roomId: roomId }
|})

(* ── R59B_DW — deadWorker capability checking ─────────────────────────── *)

let base_dead = {|#lang tesl
module BackendDeadTest exposing []

import Tesl.Prelude exposing [String]
import Tesl.Queue exposing [queueRead, pubsub, FromQueue, FromDeadQueue, Queue, Job, QueueRetryStrategy, Exponential]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection]
import Tesl.SSE exposing [SseChannel]

record NotifyJob { senderName: String roomName: String }
type RoomEvent = NotifyFailed senderName: String roomName: String

entity Dummy table "dummy" primaryKey id { id: String }

database DB = Database {
  schema: "chat"
  entities: [Dummy]
  backend: Postgres (PostgresConfig {
    dbName: env "DB"
    user: env "U"
    password: env "P"
    connection: TcpConnection { host: env "H"  port: 5432 }
  })
}

sseChannel RoomMessages(roomId: String) = SseChannel {
  database: DB
  payload: RoomEvent
}

# Normal worker for the folded queue's job list. The job type is paired with
# this worker and the (per-test) dead-letter worker `handleDeadNotify`.
worker handleNotify(job: NotifyJob ::: FromQueue (Id == jobId) job)
  requires [queueRead] =
  job

# Folded queue: `jobs: [Job T worker (Something deadWorker)]` wires the dead
# worker `handleDeadNotify` declared in each test below.
queue NotificationQueue requires [queueRead, pubsub] = Queue {
  database: DB
  jobs: [Job NotifyJob handleNotify (Something handleDeadNotify)]
  retry: QueueRetryStrategy { maxAttempts: 3  backoff: Exponential  initialDelay: 5 }
}

|}

let test_R59B_DW01_dead_worker_publish_no_cap () =
  (* deadWorker (wired into the folded NotificationQueue) that publishes without
     declaring pubsub capability is rejected. The capability is enforced on the
     deadWorker function decl itself, regardless of how the queue references it. *)
  should_fail "deadWorker.*uses.*pubsub.*but does not declare" (base_dead ^ {|
deadWorker handleDeadNotify(job: NotifyJob ::: FromDeadQueue (Id == jobId) job) =
  publish RoomMessages(job.roomName) NotifyFailed { senderName: job.senderName, roomName: job.roomName }
  job
|})

let test_R59B_DW02_dead_worker_publish_with_cap_compiles () =
  (* deadWorker (wired into the folded NotificationQueue) that declares pubsub
     capability can publish. *)
  should_pass (base_dead ^ {|
deadWorker handleDeadNotify(job: NotifyJob ::: FromDeadQueue (Id == jobId) job)
  requires [pubsub] =
  publish RoomMessages(job.roomName) NotifyFailed { senderName: job.senderName, roomName: job.roomName }
  job
|})

let () =
  run "Review59-Backend" [
    "forall-where-mismatch", [
      test_case "R59B_FA01 ForAll WHERE uses different binding" `Quick test_R59B_FA01_forall_where_different_binding;
      test_case "R59B_FA02 ForAll WHERE uses literal" `Quick test_R59B_FA02_forall_where_literal;
      test_case "R59B_FA03 ForAll WHERE uses different param" `Quick test_R59B_FA03_forall_where_different_param;
      test_case "R59B_FA04 ForAll WHERE correct compiles" `Quick test_R59B_FA04_forall_where_correct_compiles;
    ];
    "existential-insert-mismatch", [
      test_case "R59B_EX01 insert id literal rejected" `Quick test_R59B_EX01_insert_id_literal;
      test_case "R59B_EX02 insert id different binding rejected" `Quick test_R59B_EX02_insert_id_different_binding;
      test_case "R59B_EX03 insert id different param rejected" `Quick test_R59B_EX03_insert_id_different_param;
      test_case "R59B_EX04 insert id correct compiles" `Quick test_R59B_EX04_insert_correct_compiles;
    ];
    "dead-worker-capability", [
      test_case "R59B_DW01 deadWorker publish without pubsub rejected" `Quick test_R59B_DW01_dead_worker_publish_no_cap;
      test_case "R59B_DW02 deadWorker publish with pubsub compiles" `Quick test_R59B_DW02_dead_worker_publish_with_cap_compiles;
    ];
  ]
