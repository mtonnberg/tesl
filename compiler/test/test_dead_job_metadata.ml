open Alcotest
let contains = Compile.string_contains
let replace a b = Str.global_replace (Str.regexp_string a) b
let imports = {|import Tesl.Prelude exposing [String, Int, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Queue exposing [DeadJob, DeadJobReason(..), DeadJob.id, DeadJob.reason, DeadJob.sourceVersion, DeadJob.attempts, DeadJob.typeName]
|}
let arms = ["AttemptsExhausted", "retry"; "PayloadInvalid", "payload";
            "MigrationRejected", "migration"; "LegacyUnresolved", "legacy"]
let match_arms xs = String.concat "\n" (List.map (fun (c,s) -> "    " ^ c ^ " -> \"" ^ s ^ "\"") xs)
let program body = "module Probe exposing [f]\n" ^ imports ^ body ^ "\n"
let errors source =
 let result = Compile.agent_context_result_source "probe.tesl" source in
 result.diagnostics |> List.filter (fun (d:Compile.diagnostic) -> d.severity="error")
let accepts source = match errors source with [] -> () | ds -> fail (String.concat "\n" (List.map (fun (d:Compile.diagnostic)->d.message) ds))
let refuses needle source =
 let ds=errors source in
 if not (List.exists (fun (d:Compile.diagnostic)->contains d.message needle) ds) then
 failf "expected %S refusal, got %s\n%s" needle (String.concat "; " (List.map (fun (d:Compile.diagnostic)->d.message) ds)) source
let direct_case = "fn f(job: DeadJob) -> String requires [] =\n  case DeadJob.reason job of\n" ^ match_arms arms
let exhaustive () =
 accepts (program direct_case);
 accepts (program ("fn f(reason: DeadJobReason) -> String =\n  case reason of\n" ^ match_arms arms));
 accepts (program ("fn f(job: DeadJob) -> String =\n  let reason = DeadJob.reason job\n  case reason of\n" ^ match_arms arms));
 List.iter (fun omitted ->
  let rest=List.filter (fun (c,_)->c<>omitted) arms in
  List.iter (fun scrutinee -> refuses omitted (program (scrutinee ^ match_arms rest)))
    ["fn f(job: DeadJob) -> String =\n  case DeadJob.reason job of\n";
     "fn f(job: DeadJob) -> String =\n  let reason = DeadJob.reason job\n  case reason of\n";
     "fn f(reason: DeadJobReason) -> String =\n  case reason of\n"])
   (List.map fst arms)
let typed () =
 List.iter (fun (name,ty,wrong) ->
   accepts (program (Printf.sprintf "fn f(job: DeadJob) -> %s requires [] = DeadJob.%s job" ty name));
   refuses "cannot unify" (program (Printf.sprintf "fn f(job: DeadJob) -> %s = DeadJob.%s job" wrong name)))
 ["id","String","Int"; "reason","DeadJobReason","String"; "sourceVersion","Maybe Int","Int";
  "attempts","Int","String"; "typeName","Maybe String","String"]
let optional_exhaustive () =
 List.iter (fun accessor ->
  let body="fn f(job: DeadJob) -> String =\n  case DeadJob." ^ accessor ^ " job of\n" in
  accepts (program (body ^ "    Nothing -> \"unknown\"\n    Something value -> \"known\""));
  refuses "Nothing" (program (body ^ "    Something value -> \"known\""));
  refuses "Something" (program (body ^ "    Nothing -> \"unknown\"")))
 ["sourceVersion";"typeName"]
let opaque () =
 List.iter (fun field -> refuses "has no field" (program ("fn f(job: DeadJob) -> String = job." ^ field)))
 ["payload";"id";"reason";"sourceVersion";"attempts";"typeName"];
 List.iter (fun value -> refuses "DeadJob" (program ("fn f() -> DeadJob = " ^ value)))
 ["DeadJob \"forged\""; "DeadJob {}"; "DeadJob { id: \"forged\" }"; "DeadJob"]
let gated () =
 List.iter (fun name ->
  let source=program ("fn f(job: DeadJob) -> String = DeadJob.id job") in
  let source=if name="DeadJob.id" then source else program direct_case in
  let source=replace (", " ^ name) "" source in
  refuses "import" source) ["DeadJob.id"; "DeadJob.reason"];
 refuses "import" (program direct_case |> replace "DeadJobReason(..)" "DeadJobReason");
 List.iter (fun ctor -> accepts (program ("fn f() -> DeadJobReason = " ^ ctor))) (List.map fst arms)
let retry_backoff_import () =
 List.iter (fun name ->
  let source="module Probe exposing []\nimport Tesl.Queue exposing [" ^ name ^ "]\n" in
  accepts source;
  match Compile.compile_go_source "probe.tesl" source with
  | Compile.GoSuccess _ -> ()
  | Compile.GoFailure ds -> fail(String.concat "\n"(List.map(fun(d:Compile.diagnostic)->d.message)ds)))
 ["QueueRetryBackoff"; "QueueRetryBackoff(..)"]
let rec mkdir p = if not (Sys.file_exists p) then (mkdir (Filename.dirname p); Unix.mkdir p 0o700)
let write p text=mkdir(Filename.dirname p);Out_channel.with_open_bin p (fun o->output_string o text)
let rec remove p=if (Unix.lstat p).Unix.st_kind=Unix.S_DIR then (Array.iter(fun n->remove(Filename.concat p n))(Sys.readdir p);Unix.rmdir p) else Sys.remove p
let native ?(qualified_only=false) ?(minimal_only=false) () =
 if Sys.command "go version >/dev/null 2>&1"<>0 then skip() else
 let root=Filename.temp_file "tesl-deadjob-native-" ".dir" in Sys.remove root;Unix.mkdir root 0o700;
 Fun.protect ~finally:(fun()->remove root) (fun()->
 let source=program (if qualified_only then "fn f(job: DeadJob) -> String = DeadJob.id job" else direct_case) ^ {|fn identifier(job: DeadJob) -> String = DeadJob.id job
fn attempts(job: DeadJob) -> Int = DeadJob.attempts job
fn sourceVersion(job: DeadJob) -> Maybe Int = DeadJob.sourceVersion job
fn typeName(job: DeadJob) -> Maybe String = DeadJob.typeName job
fn reason(job: DeadJob) -> DeadJobReason = DeadJob.reason job
|} |> replace "exposing [f]" "exposing [f, identifier, attempts, sourceVersion, typeName, reason]" in
 let source=if qualified_only then replace "import Tesl.Queue exposing [DeadJob, DeadJobReason(..), DeadJob.id, DeadJob.reason, DeadJob.sourceVersion, DeadJob.attempts, DeadJob.typeName]" "import Tesl.Queue" source else source in
 let source=if minimal_only then "module Probe exposing [f]\nimport Tesl.Prelude exposing [String]\nimport Tesl.Queue\nfn f(job: DeadJob) -> String = DeadJob.id job\n" else source in
 accepts source;
 let path=Filename.concat root "probe.tesl" in write path source;
 let artifacts=match Compile.compile_go_source path source with
 | Compile.GoSuccess a->a | Compile.GoFailure ds->fail(String.concat "\n"(List.map(fun(d:Compile.diagnostic)->d.message)ds)) in
 List.iter(fun(a:Emit_go.artifact)->write(Filename.concat root a.path)a.contents)artifacts;
 (* Test-only bridge constructs metadata, never decoded payloads. Actual emitted
    Tesl accessors and exhaustive matches are what this binary executes. *)
 write(Filename.concat root "internal/teslrt/dead_metadata_probe.go") {|package teslrt
func DeadMetadataProbe(reason string) (DeadJob,error) {
 name:="Schema.Tasks.Send"; version:=int32(7)
 return deadJobFromMetadata(nil,"retained-id",&name,&version,9,reason)
}
|};
 let native_test = {|package teslmodprobe
import (
 "testing"
 "tesl.generated/teslmodprobe/internal/teslrt"
)
func TestActualDeadMetadata(t *testing.T) {
 for reason,want:=range map[string]string{"attempts-exhausted":"retry","payload-invalid":"payload","migration-rejected":"migration","legacy-unresolved":"legacy"} {
  job,err:=teslrt.DeadMetadataProbe(reason);if err!=nil {t.Fatal(err)}
  if F(job)!=want || Reason(job).Tag!=teslrt.DeadJobReasonOf(job).Tag || Identifier(job)!="retained-id" || Attempts(job).String()!="9" {t.Fatal(reason,F(job),Identifier(job),Attempts(job))}
  version,ok:=SourceVersion(job).Value();if !ok || version.String()!="7" {t.Fatal("source version",version,ok)}
  name,ok:=TypeName(job).Value();if !ok || name!="Schema.Tasks.Send" {t.Fatal("type identity",name,ok)}
 }
 if _,err:=teslrt.DeadMetadataProbe("unknown");err==nil {t.Fatal("unknown reason accepted")}
}
|} in
 let native_test=if qualified_only then replace "F(job)!=want" "F(job)!=\"retained-id\" || want==\"\"" native_test else native_test in
 let native_test=if minimal_only then {|package teslmodprobe
import (
 "testing"
 "tesl.generated/teslmodprobe/internal/teslrt"
)
func TestActualDeadMetadata(t *testing.T) {
 job,err:=teslrt.DeadMetadataProbe("attempts-exhausted");if err!=nil {t.Fatal(err)}
 if F(job)!="retained-id" {t.Fatal(F(job))}
}
|} else native_test in
 write(Filename.concat root "internal/teslmodprobe/dead_metadata_test.go") native_test;
 let cmd=Printf.sprintf "cd %s && GOMAXPROCS=2 go test -race -p 1 ./internal/teslmodprobe -run '^TestActualDeadMetadata$' -count=1 2>&1"(Filename.quote root) in
 let channel=Unix.open_process_in cmd in let output=In_channel.input_all channel in
 match Unix.close_process_in channel with Unix.WEXITED 0->()|_->fail output)
let ()=run "Dead letter metadata" ["typed boundary",List.map(fun(n,f)->test_case n `Quick f)
 ["exhaustive four reasons",exhaustive;"precise pure accessor types",typed;"optional metadata exhaustive",optional_exhaustive;"opaque entry",opaque;
  "normal import gates",gated;"actual generated Go metadata",native ~qualified_only:false ~minimal_only:false; "qualified-only generated Go metadata",native ~qualified_only:true ~minimal_only:false; "documented retry backoff import",retry_backoff_import; "minimal qualified accessor imports",native ~qualified_only:true ~minimal_only:true]]
