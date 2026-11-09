open Alcotest
open Ast
module P = Migration_preview
module M = Migration_manifest
module S = Migration_source_syntax
let rec mkdir p = if not (Sys.file_exists p) then (mkdir (Filename.dirname p); Unix.mkdir p 0o700)
let write p source = mkdir (Filename.dirname p); Out_channel.with_open_bin p (fun out -> output_string out source)
let read p = In_channel.with_open_bin p In_channel.input_all
let rec remove p = if (Unix.lstat p).Unix.st_kind = Unix.S_DIR then
  (Array.iter (fun n -> remove (Filename.concat p n)) (Sys.readdir p); Unix.rmdir p) else Sys.remove p
let rec files p = Sys.readdir p |> Array.to_list |> List.concat_map (fun n ->
  let p = Filename.concat p n in if Sys.is_directory p then files p else [p,read p]) |> List.sort compare
let replace a b s = Str.global_replace (Str.regexp_string a) b s
let get = function Ok p -> p | Error es -> fail (String.concat "\n" (List.map (fun (e:P.error) -> e.message) es))
let syntax = function Ok p -> p | Error (e:S.error) -> fail e.message
let refused = function Error (_::_) -> () | _ -> fail "invalid choice accepted"
let app = {|module App exposing []
import Tesl.Database exposing [Database, Memory]
import NotesSchema.VCurrent
database Main = Database { schema: NotesSchema.VCurrent, migrations: NotesSchema.Migrate, backend: Memory }
|}
let simple = {|module NotesSchema.VCurrent exposing [Note]
import Tesl.Prelude exposing [String, Int]
entity Note table "notes" primaryKey id { id: String, amount: Int }
|}
let proof_source = {|module NotesSchema.VCurrent exposing [Note, Good, accept]
import Tesl.Prelude exposing [String, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
fact Good(value: String)
establish accept(value: String) -> Maybe (accepted: String ::: Good accepted) =
  if value != "" then
    Something (value ::: Good value)
  else
    Nothing
entity Note table "notes" primaryKey id { id: String, title: StringPROOF }
|}
let preview ?(documents=[]) root = P.generate ~project_root:root ~entry_file:(Filename.concat root "app.tesl")
  ~database:None ~new_revision:false ~documents
let materialize p =
  get (P.verify p ~documents:[]);
  List.iter (fun (e:M.edit) -> write e.path e.after) (M.edits (P.manifest p))
let with_project ?(old=simple) f =
  let root = Filename.temp_file "tesl-migration-choice-" ".dir" in Sys.remove root; Unix.mkdir root 0o700;
  Fun.protect ~finally:(fun () -> remove root) (fun () ->
    let path = Filename.concat root in
    write (path "tesl.toml") ""; write (path "schema/notes/v-current.tesl") old; write (path "app.tesl") app;
    materialize (get (preview root)); f root path)
let decisions p = Yojson.Basic.Util.(P.to_json p |> Yojson.Basic.from_string |> member "decisions" |> to_list)
let options p = let open Yojson.Basic.Util in
  decisions p |> List.concat_map (fun d -> member "options" d |> to_list |> List.map (fun o -> member "id" o |> to_string))
let choose ?(documents=[]) root p option_ =
  let open Yojson.Basic.Util in
  let d = List.find (fun d -> member "options" d |> to_list |> List.exists (fun o -> member "id" o |> to_string = option_)) (decisions p) in
  P.generate_choice ~project_root:root ~entry_file:(Filename.concat root "app.tesl") ~database:None ~documents
    ~decision:(member "id" d |> to_string) ~option_ ~expected_input_digest:(P.input_digest p)
let source p file = match List.find_opt (fun (e:M.edit) -> e.path=file) (M.edits (P.manifest p)) with
  | Some e -> e.after | None -> fail "selected choice did not update its migration file"
let check_app root =
  let file = Filename.concat root "app.tesl" in
  let r = Compile.agent_context_result_source file (read file) in
  if not r.ok then fail r.json
let complete file source render ?fixture_body () =
  let view = syntax (S.read ~file ~source) in
  let edits = ref [] in
  let add expr text = edits := (syntax (S.range view expr),Migration_source.source_fragment ~source text) :: !edits in
  let visit = Ast_visitor.iter (function
    | EApp {fn=EVar {name="todo";_};arg=ELit {lit=LString reason;_};_} as expr -> add expr (render reason)
    | _ -> ()) in
  List.iter (function
    | DFunc f when f.name="fixtureNote" && fixture_body<>None -> add f.body (Option.get fixture_body)
    | d -> List.iter visit (Frontend_check.module_expression_roots {(S.module_ view) with decls=[d]})) (S.module_ view).decls;
  syntax (S.replace view !edits)
let finish root path p render ?fixture_body () =
  let file=path "migrations/notes/v2.tesl" in
  check bool "custom holes block compilation" false (P.compilable p);
  materialize p;
  let chosen=read file in
  let repeated=get (preview root) in
  check int "refresh preserves the selected scaffold" 0 (List.length (M.edits (P.manifest repeated)));
  write file (complete file chosen render ?fixture_body ()); check_app root;
  check int "completed choice remains refresh-idempotent" 0 (List.length (M.edits (P.manifest (get (preview root)))))
let literal_choice () = with_project (fun root path ->
  let frozen=read (path "schema/notes/v1.tesl") in
  write (path "schema/notes/v-current.tesl") (replace "amount: Int" "amount: Int, title: String" simple);
  let p=get (preview root) in
  check int "input digest is full SHA-256" 64 (String.length (P.input_digest p));
  let before=files root in
  let chosen=get (choose root p "additive-default") in
  check bool "choice preview never writes" true (before=files root);
  finish root path chosen (fun _ -> "\"reviewed title\"") ();
  check string "choice never edits frozen source" frozen (read (path "schema/notes/v1.tesl")))
let revalidation_choice () = with_project ~old:(replace "PROOF" "" proof_source) (fun root path ->
  write (path "schema/notes/v-current.tesl") (replace "PROOF" " ::: Good title" proof_source);
  let p=get (preview root) in
  let chosen=get (choose root p "revalidate:NotesSchema.VCurrent.accept") in
  let actual=source chosen (path "migrations/notes/v2.tesl") in
  check bool "checked Revalidate rule is inserted" true (Compile.string_contains actual "Revalidate title NotesSchema.VCurrent.accept");
  finish root path chosen (fun reason -> if String.starts_with ~prefix:"Choose " reason then "Reject \"invalid historical title\"" else "\"fixture\"") ())
let primitive_choice_with_imports imports () = with_project (fun root path ->
  let file=path "migrations/notes/v2.tesl" in
  if imports<>"" then write file(replace "\nimport Tesl.Migration" ("\n" ^ imports ^ "import Tesl.Migration") (read file));
  write (path "schema/notes/v-current.tesl") (replace "amount: Int" "amount: String" simple);
  let p=get (preview root) in
  let chosen=get (choose root p "migrate-retype") in
  finish root path chosen (fun reason ->
    if String.starts_with ~prefix:"Choose " reason then "Reject \"rejected historical amount\""
    else if String.starts_with ~prefix:"Convert " reason then "Something \"converted\""
    else if String.starts_with ~prefix:"Return " reason || String.ends_with ~suffix:".amount" reason then "7"
    else "\"fixture\"") ())
let primitive_choice () = primitive_choice_with_imports "" ()
let constructor_imports () =
  List.iter(fun imports->primitive_choice_with_imports imports ())
    ["import Tesl.Maybe exposing [Maybe, Something, Nothing]\nimport Tesl.Migration exposing [Migrated, Row, Reject]\n";
     "import Tesl.Maybe exposing [Maybe, Something]\nimport Tesl.Migration exposing [Migrated, Row]\n";
     "import Tesl.Maybe exposing [Maybe]\nimport Tesl.Maybe exposing [Nothing, Something]\n"]
let changed_proof_choice () = with_project ~old:(replace "PROOF" " ::: Good title" proof_source) (fun root path ->
  write (path "schema/notes/v-current.tesl") (proof_source |> replace "PROOF" " ::: Good title" |> replace "value != \"\"" "value != \"blocked\"");
  let p=get (preview root) in
  check bool "changed historical proof is never Revalidate" false (List.exists (String.starts_with ~prefix:"revalidate:") (options p));
  let chosen=get (choose root p "migrate-retype") in
  let fixture_body={|case NotesSchema.V1.accept "valid" of
    Nothing -> fixtureNote()
    Something title -> NotesSchema.V1.Note { id: "fixture", title: title }|} in
  finish root path chosen ~fixture_body (fun reason ->
    if String.starts_with ~prefix:"Choose " reason then "Reject \"invalid input\""
    else if String.starts_with ~prefix:"Convert " reason then "NotesSchema.VCurrent.accept value"
    else if String.starts_with ~prefix:"Return " reason then
      "case NotesSchema.V1.accept current.title of\n    Nothing ->\n      let previous = fixtureNote()\n      previous.title\n    Something previousValue -> previousValue"
     else fail ("unexpected custom hole: " ^ reason)) ())
let validator_choice () = with_project ~old:(replace "PROOF" " ::: Good title" proof_source) (fun root path ->
  write (path "schema/notes/v-current.tesl") (proof_source |> replace "PROOF" " ::: Good title" |> replace "value != \"\"" "value != \"blocked\"");
  let p=get(preview root)in
  let chosen=get(choose root p "migrate-validators")in
  let actual=source chosen(path "migrations/notes/v2.tesl")in
  List.iter(fun expected->check bool ("generated " ^ expected) true (Compile.string_contains actual expected))
    ["NotesSchema.VCurrent.accept value";"case NotesSchema.V1.accept current.title of";"Something previousValue -> previousValue";"Retype title";"WriteBack title title"];
  let fixture_body={|case NotesSchema.V1.accept "valid" of
    Nothing -> fixtureNote()
    Something title -> NotesSchema.V1.Note { id: "fixture", title: title }|}in
  finish root path chosen ~fixture_body (fun reason->
    if String.starts_with ~prefix:"Choose an explicit Reject" reason then "Reject \"invalid historical title\""
    else if String.starts_with ~prefix:"Choose a historical fallback" reason then
      "\n      let previous = fixtureNote()\n      previous.title"
    else fail("unexpected domain hole: " ^ reason)) ())
let ambiguous_validator () = with_project ~old:(replace "PROOF" " ::: Good title" proof_source) (fun root path ->
  let fresh=proof_source |> replace "PROOF" " ::: Good title" |> replace "value != \"\"" "value != \"blocked\"" in
  write(path "schema/notes/v-current.tesl") (fresh |> replace "Good, accept]" "Good, accept, other]" |>
    fun source->source ^ "\nestablish other(value: String) -> Maybe (accepted: String ::: Good accepted) =\n  accept value\n");
  let p=get(preview root)in
  check bool "ambiguous validators require a manual choice" false(List.mem "migrate-validators"(options p));
  check bool "generic conversion remains available" true(List.mem "migrate-retype"(options p)))
let multiple_validator_fields () =
  let old=proof_source |> replace "PROOF" "" |> replace "title: String }" "title: String, memo: String }"in
  with_project ~old(fun root path->
    write(path "schema/notes/v-current.tesl") (old |> replace "title: String, memo: String"
      "title: String ::: Good title, memo: String ::: Good memo");
    let chosen=get(choose root (get(preview root)) "migrate-validators")in
    let actual=source chosen(path "migrations/notes/v2.tesl")in
    check bool "both fields receive storage rules" true
      (Compile.string_contains actual "Retype title" && Compile.string_contains actual "Retype memo");
    finish root path chosen (fun reason->if String.starts_with ~prefix:"Choose an explicit Reject" reason then
      "Reject \"invalid historical value\"" else if String.starts_with ~prefix:"Supply reviewed historical fixture" reason then
      "\"fixture\"" else fail("unnecessary domain hole: " ^ reason)) ())
let stale_choice () = with_project (fun root path ->
  write (path "schema/notes/v-current.tesl") (replace "amount: Int" "amount: Int, title: String" simple);
  let p=get (preview root) in
  let before=files root in
  let unknown option_ decision = P.generate_choice ~project_root:root ~entry_file:(path "app.tesl") ~database:None ~documents:[]
    ~decision ~option_ ~expected_input_digest:(P.input_digest p) in
  refused (unknown "invented-option" "entity:Note"); refused (unknown "additive-default" "invented-decision");
  check bool "unknown choices cannot write" true (before=files root);
  write (path "app.tesl") (app ^ "# saved after preview\n");
  let before=files root in refused (choose root p "additive-default");
  check bool "stale source is preserved exactly" true (before=files root))
let stale_documents () = with_project (fun root path ->
  write (path "schema/notes/v-current.tesl") (replace "amount: Int" "amount: Int, title: String" simple);
  let documents=[{M.path=path "app.tesl";version=4}] in
  let p=get (preview ~documents root) in
  refused (choose root p "additive-default" ~documents:[{M.path=path "app.tesl";version=5}]);
  refused (choose root p "additive-default" ~documents:[]))
let unsupported_shapes () =
  List.iter (fun (label,fresh) -> with_project (fun root path ->
    write (path "schema/notes/v-current.tesl") fresh;
    let p=get (preview root) in
    check bool (label ^ " cannot offer a primitive converter") false (List.mem "migrate-retype" (options p))))
    ["changed primary key",replace "id: String" "id: Int" simple;
     "renamed field",replace "amount: Int" "renamed: String" simple;
     "changed index",replace "amount: Int }" "amount: String\n index [amount] as \"amount_lookup\"\n}" simple];
  with_project ~old:(replace "PROOF" "" proof_source) (fun root path ->
    write (path "schema/notes/v-current.tesl") (proof_source |> replace "PROOF" " ::: Good title" |> replace "[Note, Good, accept]" "[Note]");
    check (list string) "hidden proof owners have no guessed scaffold" [] (options (get (preview root))))
let crlf_choice () =
  let crlf=replace "\n" "\r\n" in
  with_project ~old:(crlf simple) (fun root path ->
    let file=path "migrations/notes/v2.tesl" in write file (crlf (replace "\r\n" "\n" (read file)));
    write (path "schema/notes/v-current.tesl") (crlf (replace "amount: Int" "amount: String" simple));
    let p=get (preview root) in let chosen=get (choose root p "migrate-retype") in
    let after=source chosen file in
    check bool "new metadata and helper fragments preserve CRLF" true (String.contains after '\r');
    String.iteri (fun i c -> if c='\n' then check bool "no bare generated LF" true (i>0 && after.[i-1]='\r')) after;
    materialize chosen;
    check int "CRLF scaffold refresh remains idempotent" 0 (List.length (M.edits (P.manifest (get (preview root))))))
let strict_command_flags () = with_project (fun _root path ->
  let digest=String.make 64 '0' in
  let flags=["--decision";"entity:Note";"--option";"additive-default";"--expected-input-digest";digest] in
  let args=["generate";path "app.tesl";"--manifest-json"] in
  List.iter (fun extra ->
    let response=Migration_command.run (args @ extra) in
    check int "invalid choice arguments fail" 1 response.exit_code;
    check bool "failure has no manifest" true (Compile.string_contains response.stdout "\"manifest\":null"))
    [["--decision";"entity:Note"];["--option";"additive-default"];["--expected-input-digest";digest];
     flags @ ["--new-revision"];flags @ ["--decision";"entity:Note"];
     ["--decision";"entity:Note";"--option";"additive-default";"--expected-input-digest";String.make 64 'A']];
  List.iter (fun verb -> let response=Migration_command.run ([verb;path "app.tesl";"--manifest-json"] @ flags) in
    check int "other verbs cannot consume a choice" 1 response.exit_code) ["contract";"plan"])
let () = run "Compiler-owned migration choices" ["complete source workflows",List.map (fun (name,test) -> test_case name `Quick test)
  ["required literal default",literal_choice;"checked first-proof revalidation",revalidation_choice;
   "primitive representation conversion",primitive_choice;"changed historical proof with exact write-back",changed_proof_choice;
   "stale or invented choices never apply",stale_choice;"document set and versions bind the choice",stale_documents;
   "unsupported shapes never guess converters",unsupported_shapes;"consistent CRLF survives a selected scaffold",crlf_choice;
   "choice flags are strict and grouped",strict_command_flags;
    "existing constructor imports remain valid",constructor_imports;
    "changed proofs reuse exact validators",validator_choice;
    "multiple fields reuse validators with plain historical write-back",multiple_validator_fields;
    "ambiguous validators are not guessed",ambiguous_validator]]
