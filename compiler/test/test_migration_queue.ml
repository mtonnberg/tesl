open Alcotest
module I = Migration_inventory
module Q = Migration_queue
module S = Migration_seal
let replace a b = Str.global_replace (Str.regexp_string a) b
let rec mkdir p = if not (Sys.file_exists p) then (mkdir (Filename.dirname p); Unix.mkdir p 0o700)
let rec remove p = if (Unix.lstat p).Unix.st_kind=Unix.S_DIR then begin
  Array.iter (fun n -> remove (Filename.concat p n)) (Sys.readdir p); Unix.rmdir p
end else Sys.remove p
let with_project f =
  let root = Filename.temp_file "tesl-queue-schema-" ".dir" in Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let write relative source = let path=Filename.concat root relative in mkdir (Filename.dirname path);
      Out_channel.with_open_bin path (fun o -> output_string o source); path in
    ignore (write "tesl.toml" ""); f root write)
let parse path source = match Parser.parse_module path source with Ok m -> m | Err e -> fail e.msg
let load path = match I.load ~compiler_abi:"queue-test" ~root_file:path with Ok i -> i | Error e -> fail e.message
let seal root i = match S.create ~project_root:root i with Ok s -> s | Error e -> fail e.message
let decode s = match S.decode s with Ok s -> s | Error e -> fail e.message
let describes ds = String.concat "\n" (List.map (fun (d:Compile.diagnostic) -> d.code ^ ": " ^ d.message) ds)
let diagnostics path source =
  let context=Compile.agent_context_result_source path source in
  List.filter (fun (d:Compile.diagnostic) -> d.severity="error") context.diagnostics
let accepts path source = let ds=diagnostics path source in if ds<>[] then fail (describes ds)
let refuses code path source = let ds=diagnostics path source in
  check bool ("missing " ^ code ^ "\n" ^ describes ds) true (List.exists (fun (d:Compile.diagnostic) -> d.code=code) ds)
let errors expected es =
  let messages = String.concat "\n" (List.map (fun (e:Migration_sparse.error) -> e.message) es) in
  check bool messages true (es<>[] && List.for_all (fun (e:Migration_sparse.error) -> e.code="MIG028") es);
  check bool messages true (Compile.string_contains messages expected)
let imports = "import Tesl.Prelude exposing [String, Int]\n"
let source = {|module Schema.Todo.VCurrent exposing [Notifications, Notify, Other]
import Tesl.Prelude exposing [String, Int]
record Notify { text: String }
record Other { text: String }
queueSchema Notifications { jobs: [Notify] }
|}
let freeze root =
  match Migration_source.freeze_closure ~project_root:root ~family:"Schema.Todo" ~version:1 with
  | Error e -> fail e
  | Ok copies -> List.iter (fun (c:Migration_source.frozen_copy) -> mkdir (Filename.dirname c.target_path);
      Out_channel.with_open_bin c.target_path (fun o -> output_string o c.contents)) copies
let pair before after test = with_project (fun root write ->
  let current=write "schema/todo/v-current.tesl" before in
  accepts current before; let old_current=load current in freeze root;
  let previous=load (Filename.concat root "schema/todo/v1.tesl") in
  let before_seal=seal root previous in
  ignore old_current;
  ignore (write "schema/todo/v-current.tesl" after);
  accepts current after; let after=load current in
  test root write previous after before_seal)

let parser () = with_project (fun _ write ->
  let multiline=replace "{ jobs: [Notify] }" "{\n jobs: [\n  Notify,\n ]\n}" source in
  let p=write "schema/todo/v-current.tesl" multiline in accepts p multiline;
  let formatted=Formatter.format_source multiline in
  check string "formatter preserves contextual declaration idempotently" formatted (Formatter.format_source formatted);
  accepts p formatted;
  check bool "formatter preserves checked pure inventory" true
    (List.exists (function Ast.DQueueSchema _ -> true | _ -> false) (parse p formatted).decls);
  check int "one distinct pure declaration" 1 (List.length (List.filter (function Ast.DQueueSchema _ -> true | _ -> false) (parse p multiline).decls));
  List.iter (fun changed -> match Parser.parse_module p changed with
    | Err _ -> () | Ok _ -> fail "effectful/computed queueSchema parsed")
    [replace "jobs: [Notify]" "jobs: [Job Notify handler Nothing]" source;
     replace "jobs: [Notify]" "jobs: getJobs()" source;
     replace "jobs: [Notify]" "database: D" source;
     replace "jobs: [Notify]" "jobs: [Notify], retry: options" source];
  let ordinary="module Ordinary exposing [queueSchema]\n" ^ imports ^ "fn queueSchema(s: String) -> String = s\n" in
  accepts (write "ordinary.tesl" ordinary) ordinary)
let purity () = with_project (fun _ write ->
  List.iter (fun (name,changed) -> let p=write name changed in refuses "MIG028" p changed)
    ["app.tesl",replace "module Schema.Todo.VCurrent" "module App" source;
     "schema/todo/v-current.tesl",replace "jobs: [Notify]" "jobs: []" source;
     "schema/todo/v-current.tesl",replace "jobs: [Notify]" "jobs: [Notify, Notify]" source;
     "schema/todo/v-current.tesl",replace "jobs: [Notify]" "jobs: [String]" source;
     "schema/todo/v-current.tesl",replace "jobs: [Notify]" "jobs: [Missing]" source;
     "schema/todo/v-current.tesl",replace "record Notify { text: String }" "entity Notify table \"notify\" primaryKey text { text: String }" source])
let canonical () = pair (replace "[Notify]" "[Notify, Other]" source) (replace "[Notify]" "[Other, Notify]" source)
  (fun _ _ before after _ ->
    check bool "membership is sorted and revision-relative" true (I.snapshot before=I.snapshot after);
    match I.verify_same ~before ~after ~previous:(Migration_ir.Value,"Schema.Todo.V1.Notifications")
      ~current:(Migration_ir.Value,"Schema.Todo.VCurrent.Notifications") with
    | Ok _ -> () | Error e -> fail e.message)
let additive () = pair source (replace "[Notify]" "[Notify, Other]" source) (fun _ _ before after _ ->
  check int "new payload identity is additive" 0 (List.length (Q.changes ~before ~after));
  let q=List.hd (I.queue_contracts after) in
  check string "wire queue identity" "Notifications" (Q.wire_identity after q.queue_name);
  check (list string) "wire job identities" ["Notify";"Other"] (List.map (fun p -> Q.wire_identity after p.I.payload_name) q.payloads))
let incompatible () =
  List.iter (fun (label,after) -> pair source after (fun _ _ before after _ -> errors label (Q.changes ~before ~after)))
    ["shape",replace "record Notify { text: String }" "record Notify { text: Int }" source;
     "removed",replace "queueSchema Notifications { jobs: [Notify] }" "" (replace "Notifications, " "" source);
     "renamed",replace "Notifications" "Mail" source;
     "removed",replace "jobs: [Notify]" "jobs: [Other]" source;
     "moved",source |> replace "jobs: [Notify]" "jobs: [Other]" |> fun s -> s ^ "queueSchema Delayed { jobs: [Notify] }\n"]
let duplicate_owner () = with_project (fun _ write ->
  let s=source ^ "queueSchema Delayed { jobs: [Notify] }\n" in
  let p=write "schema/todo/v-current.tesl" s in
  match I.load ~compiler_abi:"queue-test" ~root_file:p with
  | Ok _ -> fail "payload can belong to only one queue"
  | Error e -> check bool e.message true (Compile.string_contains e.message "multiple queueSchema"))
let duplicate_private_children () = with_project (fun _ write ->
  ignore (write "schema/todo/v-current/payload.tesl"
    ("module Schema.Todo.VCurrent.Payload exposing [Notify]\n" ^ imports ^ "record Notify { text: String }\n"));
  List.iter (fun (file,name) ->
    ignore (write ("schema/todo/v-current/" ^ file ^ ".tesl")
      ("module Schema.Todo.VCurrent." ^ name ^ " exposing []\n" ^
       "import Schema.Todo.VCurrent.Payload\nqueueSchema Tasks { jobs: [Schema.Todo.VCurrent.Payload.Notify] }\n")))
    ["email","Email";"background","Background"];
  let root="module Schema.Todo.VCurrent exposing []\nimport Schema.Todo.VCurrent.Email\nimport Schema.Todo.VCurrent.Background\n" in
  let path=write "schema/todo/v-current.tesl" root in
  refuses "MIG028" path root;
  match I.load ~compiler_abi:"queue-test" ~root_file:path with
  | Ok _ -> fail "private child contracts cannot share durable payload ownership"
  | Error e -> check bool e.message true (Compile.string_contains e.message "multiple queueSchema"))
let metadata_is_not_value_or_type () = with_project (fun _ write ->
  ignore (write "schema/todo/v-current.tesl" source);
  List.iter (fun body ->
    let app="module App exposing []\nimport Schema.Todo.VCurrent\n" ^ imports ^ body in
    let path=write "app.tesl" app in refuses "T001" path app)
    ["fn misuse(value: Schema.Todo.VCurrent.Notifications) -> String = \"ok\"\n";
     "fn misuse() -> String = Schema.Todo.VCurrent.Notifications\n"])
let imported () = with_project (fun root write ->
  let child="module Schema.Todo.VCurrent.Payload exposing [Notify]\n" ^ imports ^ "record Notify { text: String }\n" in
  ignore (write "schema/todo/v-current/payload.tesl" child);
  let prefix="module Schema.Todo.VCurrent exposing [Notifications]\n" in
  let qualified=prefix ^ "import Schema.Todo.VCurrent.Payload\nqueueSchema Notifications { jobs: [Schema.Todo.VCurrent.Payload.Notify] }\n" in
  let path=write "schema/todo/v-current.tesl" qualified in accepts path qualified; let before=load path in
  let exposed=prefix ^ "import Schema.Todo.VCurrent.Payload exposing [Notify]\nqueueSchema Notifications { jobs: [Notify] }\n" in
  ignore (write "schema/todo/v-current.tesl" exposed); accepts path exposed; let after=load path in
  check bool "prefixed and exposed imports have the same canonical identity" true (I.snapshot before=I.snapshot after);
  ignore (write "schema/todo/v-current/payload.tesl" (replace "exposing [Notify]" "exposing []" child));
  refuses "MIG028" path qualified;
  ignore root)
let codecs () =
  let codecs={|import Tesl.Json exposing [stringCodec]
codec Notify {
 toJson { text -> "text" with_codec stringCodec }
 fromJson [ { text <- "text" with_codec stringCodec } ]
}
|} in
  let s=replace "record Notify" ("import Tesl.Json exposing [stringCodec]\nrecord Notify") source ^
    String.sub codecs (String.length "import Tesl.Json exposing [stringCodec]\n") (String.length codecs - String.length "import Tesl.Json exposing [stringCodec]\n") in
  pair s (replace "\"text\"" "\"message\"" s) (fun _ _ before after _ -> errors "codec" (Q.changes ~before ~after))
let proofs () =
  let s=source |> replace "[String, Int]" "[String, Int]\nimport Tesl.Maybe exposing [Maybe(..)]"
    |> replace "record Notify { text: String }" {|fact Valid (text: String)
establish validate(text: String) -> Maybe (value: String ::: Valid value) =
 if text != "" then
  Something (text ::: Valid text)
 else
  Nothing
record Notify { text: String ::: Valid text }|} in
  pair s (replace "text != \"\"" "text != \"blocked\"" s) (fun _ _ before after _ -> errors "proof" (Q.changes ~before ~after))
let legacy encoded =
  let lines=String.split_on_char '\n' encoded in
  match String.split_on_char ' ' (List.hd lines) with
  | [hash;_;root;abi;"none";digest;_] -> String.concat "\n" ((String.concat " " [hash;"tesl:snapshot-seal:v1";root;abi;digest]) :: List.tl lines)
  | _ -> fail "unexpected seal test shape"
let capability () = pair source source (fun root _ before after previous ->
  let current=seal root after in
  check bool "new seal records complete inventory" true (S.queue_inventory_complete current);
  let old=decode (legacy (S.encode previous)) in
  check bool "legacy absence stays unknown" false (S.queue_inventory_complete old);
  errors "legacy absence" (Q.historical_capability ~before ~after (Some (old,current)));
  check int "new inventories support comparison" 0 (List.length (Q.historical_capability ~before ~after (Some (previous,current))));
  errors "lacks" (Q.historical_capability ~before ~after None))
let empty_capability () =
  let empty="module Schema.Todo.VCurrent exposing []\n" in
  pair empty source (fun root _ before after previous ->
    check bool "explicit empty inventory still has authority" true (S.queue_inventory_complete previous);
    check int "new payloads can follow recorded empty inventory" 0
      (List.length (Q.historical_capability ~before ~after (Some (previous,seal root after))));
    errors "legacy absence" (Q.historical_capability ~before ~after (Some (decode (legacy (S.encode previous)),seal root after))));
  pair empty empty (fun _ _ before after previous ->
    check int "legacy queue-free history remains usable without claiming completeness" 0
      (List.length (Q.historical_capability ~before ~after (Some (decode (legacy (S.encode previous)),previous)))))
let app={|module TodoApp exposing []
import Schema.Todo.VCurrent
import Tesl.Prelude exposing [Unit, String]
import Tesl.Database exposing [Database, Memory]
import Tesl.Queue exposing [Queue, FromQueue, queueRead]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.App exposing [App]
database D = Database { schema: Schema.Todo.VCurrent, migrations: Schema.Todo.Migrate, backend: Memory }
queue Tasks requires [queueRead] = Queue { database: D, schema: Schema.Todo.VCurrent.Notifications,
 jobs: [Job Schema.Todo.VCurrent.Notify handle Nothing] }
worker handle(job: Schema.Todo.VCurrent.Notify ::: FromQueue (Id == jobId) job)
 requires [queueRead] = job
handler get healthy() -> String = "ok"
api Routes { get "/" -> String }
server Web for Routes { healthy }
main() -> App requires [queueRead] = App { database: D, queues: [Tasks], api: Web }
|}
let binding_errors write inventory app =
  let path=write "todo-app.tesl" app in
  let m=parse path app in
  let schema_path=Filename.concat (Filename.dirname path) "schema/todo/v-current.tesl" in
  let schema= parse schema_path (In_channel.with_open_bin schema_path In_channel.input_all) in
  let database=List.find_map (function Ast.DDatabase d -> Some d | _ -> None) m.decls |> Option.get in
  Q.application_bindings ~modules:[m;schema] ~database_module:m ~database inventory
let bindings () = with_project (fun _ write ->
  let path=write "schema/todo/v-current.tesl" source in let i=load path in
  check int "complete active binding" 0 (List.length (binding_errors write i app));
  accepts (write "todo-app.tesl" app) app;
  check int "handler and application queue renames preserve identity" 0
    (List.length (binding_errors write i (app |> replace "Tasks" "Background" |> replace "handle(" "process(" |> replace " handle " " process ")));
  List.iter (fun changed -> errors "" (binding_errors write i changed))
    [replace "queues: [Tasks]" "queues: []" app;
     replace "queues: [Tasks]" "queues: [Tasks, Tasks]" app;
     replace "Job Schema.Todo.VCurrent.Notify handle Nothing" "Job Schema.Todo.VCurrent.Notify handle Nothing, Schema.Todo.VCurrent.Other" app;
     replace "Job Schema.Todo.VCurrent.Notify handle Nothing" "Schema.Todo.VCurrent.Notify" app;
     replace "schema: Schema.Todo.VCurrent.Notifications," "" app;
     replace "Job Schema.Todo.VCurrent.Notify handle Nothing" "Job Schema.Todo.VCurrent.Other handle Nothing" app;
     replace "Job Schema.Todo.VCurrent.Notify handle Nothing" "Job Schema.Todo.VCurrent.Notify handle Nothing, Job Schema.Todo.VCurrent.Notify handle Nothing" app;
     replace "queue Tasks requires [queueRead] = Queue { database: D, schema: Schema.Todo.VCurrent.Notifications,\n jobs: [Job Schema.Todo.VCurrent.Notify handle Nothing] }\n" "" app;
     app ^ "queue Duplicate = Queue { database: D, schema: Schema.Todo.VCurrent.Notifications, jobs: [Job Schema.Todo.VCurrent.Notify handle Nothing] }\n"])

let write_edge root write before after before_seal =
  let header = match Migration_header.create ~previous:before_seal ~current:(seal root after) with
    | Ok h -> h | Error es -> fail (List.hd es).Migration_sparse.message in
  let body=Printf.sprintf {|module Schema.Todo.Migrate.V2 exposing [migration]
import Tesl.Migration exposing [Migration, Same(..)]
import %s
import %s
migration = Migration { from: %s, to: %s, same: [], entities: {} }
|} (I.root_module before) (I.root_module after) (I.root_module before) (I.root_module after) in
  let source=Migration_header.encode header ^ body in
  write "migrations/todo/v2.tesl" source,source
let frontend_edges () =
  List.iter (fun after -> pair source after (fun root write before after previous ->
    let path,edge=write_edge root write before after previous in
    refuses "MIG028" path edge;
    let file=write "todo-app.tesl" app in refuses "MIG028" file app))
    [replace "record Notify { text: String }" "record Notify { text: Int }" source;
     replace "[Notify]" "[Other]" source];
  pair source source (fun root write before after previous ->
    let path,edge=write_edge root write before after previous in accepts path edge;
    let file=write "todo-app.tesl" app in accepts file app;
    let missing=replace "queues: [Tasks]" "queues: []" app in
    refuses "MIG028" file missing;
    let _,legacy_edge=write_edge root write before after (decode (legacy (S.encode previous))) in
    refuses "MIG028" path legacy_edge;
    refuses "MIG028" file app)
let nested_payload () =
  let s=source |> replace "record Notify { text: String }"
    "type Detail =\n | Pending\n | Sent body: String\nrecord Notify { detail: Detail }" in
  pair s (replace "Sent body: String" "Sent body: Int" s) (fun _ _ before after _ -> errors "shape" (Q.changes ~before ~after))
let apply manifest = List.iter (fun (e:Migration_manifest.edit) -> mkdir (Filename.dirname e.path);
  Out_channel.with_open_bin e.path (fun o -> output_string o e.after)) (Migration_manifest.edits manifest)
let generate root version = match Migration_generate.start ~compiler_abi:"queue-test" ~project_root:root ~family:"Schema.Todo" ~version ~documents:[] with
  | Ok preview -> apply preview.manifest
  | Error es -> fail (String.concat "\n" (List.map (fun (e:Migration_generate.error) -> e.message) es))
let complete_history () = with_project (fun root write ->
  let empty="module Schema.Todo.VCurrent exposing []\n" in
  ignore (write "schema/todo/v-current.tesl" empty);
  generate root 1;
  let edge_path=Filename.concat root "migrations/todo/v2.tesl" in
  let edge=In_channel.with_open_bin edge_path In_channel.input_all in
  let header=match Migration_header.read ~file:edge_path edge with Ok (Some h) -> h | _ -> fail "missing generated header" in
  let previous,current=Migration_header.recorded_seals header in
  let legacy_header=Result.get_ok (Migration_header.create
      ~previous:(decode (legacy (S.encode previous))) ~current:(decode (legacy (S.encode current)))) in
  let legacy_edge=Result.get_ok (Migration_header.replace ~file:edge_path ~source:edge legacy_header) in
  ignore (write "migrations/todo/v2.tesl" legacy_edge);
  generate root 2;
  let archived=In_channel.with_open_bin edge_path In_channel.input_all in
  let header=match Migration_header.read ~file:edge_path archived with Ok (Some h) -> h | _ -> fail "missing archived header" in
  let _,frozen=Migration_header.recorded_seals header in
  check bool "freezing cannot invent authority for an old target" false (S.queue_inventory_complete frozen);
  generate root 3;
  ignore (write "schema/todo/v-current.tesl" source);
  let refreshed=match Migration_generate.refresh ~compiler_abi:"queue-test" ~project_root:root ~family:"Schema.Todo" ~version:4 ~documents:[] with
    | Ok p -> p | Error es -> fail (String.concat "\n" (List.map (fun (e:Migration_generate.error) -> e.message) es)) in
  check int "latest edge alone is additive" 0 (List.length (List.filter (fun (d:Compile.diagnostic) -> d.severity="error") refreshed.diagnostics));
  apply refreshed.manifest;
  let path=write "todo-app.tesl" app in
  refuses "MIG028" path app)
let empty_then_added () = with_project (fun root write ->
  let empty="module Schema.Todo.VCurrent exposing []\n" in
  ignore (write "schema/todo/v-current.tesl" empty); generate root 1;
  ignore (write "schema/todo/v-current.tesl" source);
  let p=match Migration_generate.refresh ~compiler_abi:"queue-test" ~project_root:root ~family:"Schema.Todo" ~version:2 ~documents:[] with
    | Ok p -> p | Error es -> fail (String.concat "\n" (List.map (fun (e:Migration_generate.error) -> e.message) es)) in
  apply p.manifest;
  let path=write "todo-app.tesl" app in accepts path app;
  let no_binding=replace "queue Tasks requires [queueRead] = Queue { database: D, schema: Schema.Todo.VCurrent.Notifications,\n jobs: [Job Schema.Todo.VCurrent.Notify handle Nothing] }\n" "" app
    |> replace "queues: [Tasks]" "queues: []" in
  refuses "MIG028" path no_binding)
let unversioned_target () = with_project (fun _ write ->
  ignore (write "schema/todo/v-current.tesl" source);
  let unversioned=replace "schema: Schema.Todo.VCurrent, migrations: Schema.Todo.Migrate," "" app in
  let path=write "todo-app.tesl" unversioned in refuses "MIG028" path unversioned)

let imported_activation () = with_project (fun _ write ->
  ignore (write "schema/todo/v-current.tesl" source);
  let queue="queue Tasks requires [queueRead] = Queue { database: D, schema: Schema.Todo.VCurrent.Notifications,\n jobs: [Job Schema.Todo.VCurrent.Notify handle Nothing] }\n" in
  let stop=Str.search_forward (Str.regexp_string "handler get healthy") app 0 in
  let workers=String.sub app 0 stop |> replace "module TodoApp exposing []" "module Workers exposing [Tasks]" in
  ignore (write "workers.tesl" workers);
  let root=app |> replace queue "" |> replace "import Schema.Todo.VCurrent" "import Workers\nimport Schema.Todo.VCurrent"
    |> replace "queues: [Tasks]" "queues: [Workers.Tasks]" in
  let path=write "todo-app.tesl" root in
  let ds=diagnostics path root in
  check bool (describes ds) true (List.exists (fun (d:Compile.diagnostic) -> d.code="V001" && Compile.string_contains d.message "unknown queue") ds);
  check bool "imported activation cannot count as a local binding" true (List.exists (fun (d:Compile.diagnostic) -> d.code="MIG028") ds))
let parser_recovery () = with_project (fun _ write ->
  let source="module Schema.Todo.VCurrent exposing []\n" ^ imports ^
    "record Notify { text: String }\nfn broken() -> String = )\nqueueSchema Notifications { jobs: [Notify] }\nfn kept() -> String = \"ok\"\n" in
  let path=write "schema/todo/v-current.tesl" source in
  check bool "ordinary parse fails" true (match Parser.parse_module path source with Err _ -> true | Ok _ -> false);
  match Parser.parse_module_recover path source with
  | None -> fail "recovering parse lost module"
  | Some m ->
    check bool "recovers queueSchema boundary" true (List.exists (function Ast.DQueueSchema q -> q.name="Notifications" | _ -> false) m.decls);
    check bool "preserves later functions" true (List.exists (function Ast.DFunc f -> f.name="kept" | _ -> false) m.decls))
let () = run "Queue schema prerequisite" ["contracts",[
  test_case "pure contextual parser" `Quick parser;
  test_case "purity and payload types" `Quick purity;
  test_case "canonical membership and Same" `Quick canonical;
  test_case "new identities additive" `Quick additive;
  test_case "incompatible histories" `Quick incompatible;
  test_case "one owner per payload" `Quick duplicate_owner;
  test_case "private child contracts cannot duplicate ownership" `Quick duplicate_private_children;
  test_case "queue metadata is neither value nor type" `Quick metadata_is_not_value_or_type;
  test_case "prefixed imports and visibility" `Quick imported;
  test_case "codec closure" `Quick codecs;
  test_case "proof producer closure" `Quick proofs;
  test_case "historical capability" `Quick capability;
  test_case "empty versus unknown" `Quick empty_capability;
  test_case "application bindings" `Quick bindings;
  test_case "frontend edge and application errors" `Quick frontend_edges;
  test_case "nested ADT payload closure" `Quick nested_payload;
  test_case "whole history authority" `Quick complete_history;
  test_case "late addition and deleted binding" `Quick empty_then_added;
  test_case "unversioned target refused" `Quick unversioned_target;
  test_case "imported activation remains unsupported" `Quick imported_activation;
  test_case "contextual declaration recovery" `Quick parser_recovery]]
