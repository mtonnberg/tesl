open Alcotest
let replace a b s =
 if not (Compile.string_contains s a) then fail ("missing replacement target: " ^ a);
 Str.global_replace (Str.regexp_string a) b s
let old = {|module Schema.Notes.V1 exposing [Note, tryTitle, NonEmpty]
import Tesl.Prelude exposing [String, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
fact NonEmpty (value: String)
establish tryTitle(value: String) -> Maybe (v: String ::: NonEmpty v) =
 if value != "" then
  Something (value ::: NonEmpty value)
 else
  Nothing
entity Note table "notes" primaryKey id { id: String, title: String ::: NonEmpty title, memo: String }
|}
let fresh = {|module Schema.Notes.VCurrent exposing [Note, tryTitle, Allowed]
import Tesl.Prelude exposing [String, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
fact Allowed (value: String)
establish tryTitle(value: String) -> Maybe (v: String ::: Allowed v) =
 if value == "" then
  Nothing
 else
  if value == "blocked" then
   Nothing
  else
   Something (value ::: Allowed value)
entity Note table "notes" primaryKey id { id: String, title: String ::: Allowed title @column("title__v2"), memo: String }
|}
let migration = {|module Schema.Notes.Migrate.V2 exposing [migration, oldNote]
import Tesl.Prelude exposing [String]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Migrated(..)]
import Schema.Notes.V1
import Schema.Notes.VCurrent
migration = Migration { from: Schema.Notes.V1, to: Schema.Notes.VCurrent, same: [], fixtures: [oldNote],
 entities: { Note: Migrate convert [Retype title, WriteBack title title backward] } }
fn convert(old: Schema.Notes.V1.Note) -> Migrated Schema.Notes.VCurrent.Note =
 case Schema.Notes.VCurrent.tryTitle old.title of
  Nothing -> Reject "title rejected by changed proof"
  Something title -> Row (Schema.Notes.VCurrent.Note { id: old.id, title: title, memo: old.memo })
fn backward(row: Schema.Notes.VCurrent.Note) -> value: String ::: Schema.Notes.V1.NonEmpty value =
 case Schema.Notes.V1.tryTitle row.title of
  Nothing ->
   case Schema.Notes.V1.tryTitle "valid" of
    Nothing -> backward row
    Something fallback -> fallback
  Something title -> title
fn oldNote() -> Schema.Notes.V1.Note =
 case Schema.Notes.V1.tryTitle "valid" of
  Nothing -> oldNote()
  Something title -> Schema.Notes.V1.Note { id: "fixture", title: title, memo: "base" }
|}
let rec mkdir p = if not(Sys.file_exists p) then (mkdir(Filename.dirname p);Unix.mkdir p 0o700)
let write p s = mkdir(Filename.dirname p);Out_channel.with_open_bin p(fun o->output_string o s)
let rec remove p = if Sys.is_directory p then (Array.iter(fun n->remove(Filename.concat p n))(Sys.readdir p);Unix.rmdir p) else Sys.remove p
let check ?(previous=old) ?(current=fresh) expected body =
 let root=Filename.temp_dir "tesl-reverse-proof-" "" in
 Fun.protect ~finally:(fun()->remove root)(fun()->
  write(Filename.concat root "tesl.toml") "";
  write(Filename.concat root "schema/notes/v1.tesl") previous;
  write(Filename.concat root "schema/notes/v-current.tesl") current;
  let file=Filename.concat root "migrations/notes/v2.tesl" in write file body;
  let errors=(Compile.agent_context_result_source file body).diagnostics |> List.filter(fun(d:Compile.diagnostic)->d.severity="error") in
  let description=Compile.diagnostics_to_json errors in
  match expected with
  | None -> if errors<>[] then fail description
  | Some code -> Alcotest.check bool description true
      (List.exists(fun(d:Compile.diagnostic)->d.code=code)errors))
let return_type="value: String ::: Schema.Notes.V1.NonEmpty value"
let positive ()=check None migration
let wrong_owner ()=check (Some "MIG021") (replace return_type "value: String ::: Schema.Notes.VCurrent.Allowed value" migration)
let missing ()=check (Some "MIG021") (replace return_type "String" migration)
let wrong_subject ()=check (Some "MIG021") (replace return_type "value: String ::: Schema.Notes.V1.NonEmpty row" migration)
let wrong_type ()=check (Some "MIG021") (replace "[String]" "[String, Int]" migration |> replace return_type "value: Int ::: Schema.Notes.V1.NonEmpty value")
let optional ()=check (Some "MIG021") (replace return_type ("Maybe ("^return_type^")") migration)
let backwards_body={|case Schema.Notes.V1.tryTitle row.title of
  Nothing ->
   case Schema.Notes.V1.tryTitle "valid" of
    Nothing -> backward row
    Something fallback -> fallback
  Something title -> title|}
let branch_projection () = check None
 (replace {|Nothing ->
   case Schema.Notes.V1.tryTitle "valid" of
    Nothing -> backward row
    Something fallback -> fallback|}
   {|Nothing ->
   let previous = oldNote()
   previous.title|} migration)
let forged ()=check (Some "P001") (replace backwards_body "row.title ::: Schema.Notes.V1.NonEmpty row.title" migration)
let bare ()=check (Some "V001") (replace backwards_body "row.title" migration)
let wrong_same_name ()=
 let current=fresh |> replace "Allowed" "NonEmpty" in
 check ~current (Some "MIG021") (replace return_type "value: String ::: Schema.Notes.VCurrent.NonEmpty value" migration)
let alpha ()=check None (replace return_type "oldValue: String ::: Schema.Notes.V1.NonEmpty oldValue" migration)
let legacy ()=
 let current=replace "title: String ::: Allowed title @column(\"title__v2\"), " "" fresh in
 let body=migration |> replace "Retype title, WriteBack title title backward" "LegacyWith title backward"
   |> replace "id: old.id, title: title, memo: old.memo" "id: old.id, memo: old.memo" |> replace backwards_body {|case Schema.Notes.V1.tryTitle "valid" of
  Nothing -> backward row
  Something fallback -> fallback|} in
 check ~current None body
let remove_proof () =
 let current=fresh
  |> replace "title: String ::: Allowed title" "title: String"
  |> replace "establish tryTitle(value: String) -> Maybe (v: String ::: Allowed v)" "fn tryTitle(value: String) -> Maybe String"
  |> replace "Something (value ::: Allowed value)" "Something value" in
 check ~current None migration

let conjunction_previous () = old
 |> replace "tryTitle, NonEmpty]" "tryTitle, NonEmpty, Bounded]"
 |> replace "fact NonEmpty (value: String)" "fact NonEmpty (value: String)\nfact Bounded (value: String)"
 |> replace "NonEmpty v)" "NonEmpty v && Bounded v)"
 |> replace "NonEmpty value)" "NonEmpty value && Bounded value)"
 |> replace "NonEmpty title," "NonEmpty title && Bounded title,"
let conjunction_return = "value: String ::: Schema.Notes.V1.NonEmpty value && Schema.Notes.V1.Bounded value"
let conjunction_exact () = check ~previous:(conjunction_previous()) None
 (replace return_type conjunction_return migration)
let conjunction_alpha () = check ~previous:(conjunction_previous()) None
 (replace return_type "result: String ::: Schema.Notes.V1.NonEmpty result && Schema.Notes.V1.Bounded result" migration)
let conjunction_missing () = check ~previous:(conjunction_previous()) (Some "MIG021") migration
let conjunction_owner () = check ~previous:(conjunction_previous()) (Some "MIG021")
 (replace return_type "value: String ::: Schema.Notes.V1.NonEmpty value && Schema.Notes.VCurrent.Allowed value" migration)
let conjunction_subject () = check ~previous:(conjunction_previous()) (Some "MIG021")
 (replace return_type "value: String ::: Schema.Notes.V1.NonEmpty value && Schema.Notes.V1.Bounded row" migration)
let conjunction_order () = check ~previous:(conjunction_previous()) (Some "MIG021")
 (replace return_type "value: String ::: Schema.Notes.V1.Bounded value && Schema.Notes.V1.NonEmpty value" migration)
let ()=run "historical reverse field proofs" ["evidence",[
 test_case "exact historical conjunction" `Quick conjunction_exact;
 test_case "alpha-renamed historical conjunction" `Quick conjunction_alpha;
 test_case "missing historical conjunct" `Quick conjunction_missing;
 test_case "foreign owner in second conjunct" `Quick conjunction_owner;
 test_case "wrong subject in second conjunct" `Quick conjunction_subject;
 test_case "conjunction ordering remains exact" `Quick conjunction_order;
 test_case "removing proof retains proven old representation" `Quick remove_proof;
 test_case "branch-local proven reverse projection" `Quick branch_projection;
 test_case "exact historical proof" `Quick positive;
 test_case "alpha-renamed subject" `Quick alpha;
 test_case "different predicate owner" `Quick wrong_owner;
 test_case "same spelling different owner" `Quick wrong_same_name;
 test_case "missing attached proof" `Quick missing;
 test_case "wrong subject" `Quick wrong_subject;
 test_case "wrong underlying type" `Quick wrong_type;
 test_case "optional reverse result" `Quick optional;
 test_case "forged old evidence" `Quick forged;
 test_case "new proof is not old proof" `Quick bare;
 test_case "removal supplies old field proof" `Quick legacy;
]]
