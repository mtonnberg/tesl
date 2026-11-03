open Migration_ir
open Migration_canonical
open Alcotest
module G = Migration_checked_graph

let rec mkdir path =
  if not (Sys.file_exists path) then begin mkdir (Filename.dirname path); Unix.mkdir path 0o700 end
let rec remove path =
  if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
  end else Sys.remove path
let with_project f =
  let root = Filename.temp_file "tesl-checked-graph-" ".dir" in
  Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let write relative source =
      let path = Filename.concat root relative in mkdir (Filename.dirname path);
      Out_channel.with_open_bin path (fun channel -> output_string channel source); path in
    ignore (write "tesl.toml" ""); f root write)
let get = function Ok result -> result | Error error -> fail error.message
let parse path source = match Parser.parse_module path source with Ok m -> m | Err e -> fail e.msg
let capture path = let source = Source_input.read path in parse path source, source
let expect_error fragment = function
  | Ok _ -> fail ("unexpected successful graph: " ^ fragment)
  | Error error -> check bool (fragment ^ ": " ^ error.message) true
      (try ignore (Str.search_forward (Str.regexp_string fragment) error.message 0); true with Not_found -> false)
let scope role = [{family="Schema.Notes";revision="VCurrent";role}]
let imports = "import Tesl.Prelude exposing [Int, String]\nimport Tesl.Maybe exposing [Maybe(..)]\n"
let source = {|module Schema.Notes.VCurrent exposing []
import Tesl.Prelude exposing [Int, String]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Json exposing [stringCodec]
fact NonEmpty(value: String)
fn threshold() -> Int = 0
check accept(value: String) -> value: String ::: NonEmpty value =
  if value != "" then
    ok value ::: NonEmpty value
  else
    fail 400 "empty"
record Payload { title: String ::: NonEmpty title }
codec Payload {
  toJson { title -> "title" with_codec stringCodec }
  fromJson [ { title <- "title" with_codec stringCodec via accept } ]
}
entity Note table "notes" primaryKey id { id: String, payload: Payload @db(jsonb) }
|}
let fixture write = write "schema/notes/v-current.tesl" source
let closure role graph roots =
  let scopes = scope role in
  let definitions = get (G.lower ~scopes graph) in
  get (Migration_ir.closure_with_definitions ~scopes ~definitions ~roots)
let keys ds = List.map (fun d -> match d.key with _,Global name -> name | _ -> assert false) ds |> List.sort String.compare

let inventory_identity () = with_project (fun _ write ->
  let path = fixture write in
  let inventory = get (Migration_inventory.load ~compiler_abi:"graph-refactor-1" ~root_file:path) in
  (* Recorded using the pre-extraction inventory implementation. *)
  check string "unchanged captured inventory identity" "3aa7d9c1595cd97133ca1f90604a3ee64527145dadf89f8648a1279e9ee3ef66"
    (digest Snapshot (Migration_inventory.snapshot inventory)))

let same_ast_and_roles () = with_project (fun _ write ->
  let path = fixture write in let m,source = capture path in
  let graph = get (G.check [m,source]) in
  check bool "factory retains original AST object" true (List.hd (G.modules graph) == m);
  let roots = [Type, Global "Schema.Notes.VCurrent.Note"] in
  let snapshot, reached = closure Snapshot_role graph roots in
  let from, _ = closure From_role graph roots and target, _ = closure To_role graph roots in
  check bool "source role is lowered into bodies" true (snapshot <> from);
  check bool "target role is lowered into bodies" true (target <> from);
  check (list string) "private producer and codec are in complete closure"
    ["Schema.Notes.VCurrent.NonEmpty"; "Schema.Notes.VCurrent.Note";
     "Schema.Notes.VCurrent.Payload"; "Schema.Notes.VCurrent.Payload"; "Schema.Notes.VCurrent.accept"] (keys reached);
  let snapshot_again, _ = closure Snapshot_role graph roots in
  check string "lowering in other roles does not mutate snapshot" (encode snapshot) (encode snapshot_again))

let captured_imports () = with_project (fun _ write ->
  let helper = write "schema/notes/v-current/helper.tesl"
    ("module Schema.Notes.VCurrent.Helper exposing [answer]\n" ^ imports ^ "fn answer() -> Int = 7\n") in
  let root = write "schema/notes/v-current.tesl"
    ("module Schema.Notes.VCurrent exposing []\n" ^ imports ^
     "import Schema.Notes.VCurrent.Helper exposing [answer]\nfn result() -> Int = answer()\n") in
  let rm = capture root and hm = capture helper in
  expect_error "uncaptured migration dependency" (G.check [rm]);
  expect_error "duplicate captured migration module" (G.check [rm;hm;hm]);
  let m,s = hm in
  expect_error "does not match source" (G.check [rm; m, Str.global_replace (Str.regexp_string "= 7") "= 8" s]);
  let graph = get (G.check [rm;hm]) in
  ignore (get (G.lower ~scopes:(scope Snapshot_role) graph));
  let old = get (G.lower ~scopes:(scope Snapshot_role) graph) in
  ignore (write "schema/notes/v-current/helper.tesl"
    ("module Schema.Notes.VCurrent.Helper exposing [answer]\n" ^ imports ^ "fn answer() -> String = \"changed\"\n"));
  let captured = get (G.check [rm;hm]) in
  check bool "all passes use captured helper bytes, not changed saved interfaces" true
    (old = get (G.lower ~scopes:(scope Snapshot_role) captured));
  check string "pinning does not overwrite saved source" "changed"
    (if String.contains (Source_input.read helper) '"' then "changed" else "overwritten"))

let public_frontend_gate () = with_project (fun _ write ->
  let path = write "schema/notes/v-current.tesl"
    ("module Schema.Notes.VCurrent exposing []\n" ^ imports ^
     "import Tesl.Prelude exposing [Bool]\nimport Tesl.Regex exposing [Regex.matches]\nfn broken(raw: String) -> Bool = Regex.matches \"[\" raw\n") in
  let m,s = capture path in
  let _,errors = Checker.check_module_with_typed_nodes m in
  check int "type inference alone admits invalid regex" 0 (List.length errors);
  match G.check [m,s] with Error _ -> () | Ok _ -> fail "graph bypassed public literal validation")

let unsupported_constants () = with_project (fun _ write ->
  let path = write "helpers.tesl" ("module Helpers exposing []\n" ^ imports ^ "answer = 7\nfn read() -> Int = answer\n") in
  let graph = get (G.check [capture path]) in
  expect_error "application declaration is forbidden" (G.lower ~scopes:[] graph))

let early_complexity_gate () = with_project (fun _ write ->
  let path = write "helpers.tesl"
    ("module Helpers exposing []\n" ^ imports ^ "fn answer() -> Int = 7\n") in
  let m, source = capture path in
  let fn = List.find_map (function Ast.DFunc f -> Some f | _ -> None) m.decls |> Option.get in
  let depth = ref fn.body in
  for _ = 1 to Frontend_check.max_expression_depth + 1 do
    depth := Ast.EUnop { op = Ast.UNeg; arg = !depth; loc = fn.loc }
  done;
  let oversized body = { m with decls = [Ast.DFunc { fn with body }] } in
  (* Deliberately mismatched source: the cheap budget gate must run before the
     recursive AST/source equivalence check, not merely before type inference. *)
  expect_error "source complexity budget exceeded" (G.check [oversized !depth, source]);
  let width = Ast.EList { elems = List.init (Frontend_check.max_expression_nodes + 1)
    (fun _ -> fn.body); loc = fn.loc } in
  expect_error "source complexity budget exceeded" (G.check [oversized width, source]))

let overlay_cycle () = with_project (fun root _write ->
  let root_path = Filename.concat root "schema/notes/v-current.tesl" in
  let helper_path = Filename.concat root "schema/notes/v-current/helper.tesl" in
  let root_source = "module Schema.Notes.VCurrent exposing [answer]\n" ^ imports ^
    "import Schema.Notes.VCurrent.Helper exposing []\nfn answer() -> Int = 7\n" in
  let helper_source = "module Schema.Notes.VCurrent.Helper exposing []\n" ^ imports ^
    "import Schema.Notes.VCurrent exposing [answer]\nfn read() -> Int = answer()\n" in
  Source_input.with_overlays ~project_root:root [root_path,root_source;helper_path,helper_source] (fun () ->
    let graph = get (G.check [parse root_path root_source,root_source;parse helper_path helper_source,helper_source]) in
    ignore (get (G.lower ~scopes:(scope Snapshot_role) graph));
    check (option string) "factory preserves caller project root" (Some root) (Source_input.project_root ()));
  check bool "unsaved captured graph creates no source files" false (Sys.file_exists root_path))

let () = run "migration-checked-graph" ["checked graph", [
  test_case "exact inventory identity" `Quick inventory_identity;
  test_case "same AST, complete private closure and explicit roles" `Quick same_ast_and_roles;
  test_case "complete coherent capture" `Quick captured_imports;
  test_case "full public frontend before typed lowering" `Quick public_frontend_gate;
  test_case "constants fail explicitly instead of disappearing" `Quick unsupported_constants;
  test_case "complexity before capture comparison" `Quick early_complexity_gate;
  test_case "unsaved graph and root-helper cycle" `Quick overlay_cycle;
]]
