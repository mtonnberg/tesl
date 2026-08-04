(** W092 / W093 — the missing-index and unused-index lints.

    The value of these two rules is entirely in their precision. There is no
    suppression mechanism, so a false positive cannot be silenced at all, and a
    noisy W092 gets ignored wholesale — taking the real findings with it. Most of
    what follows therefore pins the SILENCE: the cases the lint must not report,
    each for a stated reason.

    The other half pins that one query produces exactly ONE finding. The nested
    applications of a query's own spine each match the emitter's extractor with a
    partial clause list, and the multi-line clause form arrives through a rebuild
    with no source location at all — both of which produced duplicate, weaker
    findings before the usages were keyed on query identity. *)

open Alcotest

let compiler =
  match Sys.getenv_opt "TESL_OCAML_COMPILER" with
  | Some p when Sys.file_exists p -> p
  | _ ->
    (match Sys.getenv_opt "TESL_BIN" with
     | Some v when Filename.basename v = "main.exe" && Sys.file_exists v -> v
     | _ ->
       let dir = Filename.dirname Sys.argv.(0) in
       let c1 = Filename.concat (Filename.dirname dir) "bin/main.exe" in
       let c2 = Filename.concat dir "../bin/main.exe" in
       if Sys.file_exists c1 then c1 else if Sys.file_exists c2 then c2 else "tesl")

let failf fmt = Printf.ksprintf failwith fmt

let run_cc args =
  let q = Filename.quote compiler :: List.map Filename.quote args in
  let ic = Unix.open_process_in (String.concat " " q ^ " 2>&1") in
  let out = In_channel.input_all ic in
  ignore (Unix.close_process_in ic);
  out

let with_source src f =
  let dir = Filename.temp_dir "tesl-idxlint" "" in
  let path = Filename.concat dir "Idx.tesl" in
  Out_channel.with_open_text path (fun oc -> Out_channel.output_string oc src);
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let contains hay needle =
  try ignore (Str.search_forward (Str.regexp_string needle) hay 0); true
  with Not_found -> false

(* Count only the diagnostic headers, not the "explain: tesl help W092" trailer
   that also carries the code. *)
let count_code out code =
  let re = Str.regexp ("^warning\\[" ^ code ^ "\\]") in
  String.split_on_char '\n' out
  |> List.filter (fun line ->
         try ignore (Str.search_forward re line 0); true with Not_found -> false)
  |> List.length

let postgres_db entities =
  Printf.sprintf {|
database MainDb = Database {
  schema: "app"
  entities: [%s]
  backend: Postgres (PostgresConfig {
    dbName: env "POSTGRES_DB"
    user: env "POSTGRES_USER"
    password: env "POSTGRES_PASSWORD"
    connection: TcpConnection {
      host: env "POSTGRES_HOST"
      port: envInt "POSTGRES_PORT" 5432
    }
  })
}
|} entities

let memory_db entities =
  Printf.sprintf {|
database MainDb = Database {
  schema: "app"
  entities: [%s]
  backend: Memory
}
|} entities

let prelude = {|module Idx exposing []
import Tesl.Prelude exposing [Bool(..), Int, List, String, Unit]
import Tesl.Time exposing [PosixMillis]
import Tesl.DB exposing [dbRead, dbWrite]
|}

let lint src = with_source (prelude ^ src) (fun p -> run_cc [ "--lint"; p ])

(* An Issue entity with the given extra body entries, a Postgres database, and
   the given function declarations. *)
let program ?(entity_extra = "") ?(db = postgres_db "Issue") funcs =
  Printf.sprintf {|
entity Issue table "issues" primaryKey id {
  id:        String
  orgId:     String
  slug:      String
  title:     String
  createdAt: PosixMillis
%s
}
%s
%s
|} entity_extra db funcs

let expect_codes label src ~w092 ~w093 =
  let out = lint src in
  let got92 = count_code out "W092" and got93 = count_code out "W093" in
  if got92 <> w092 || got93 <> w093 then
    failf "%s: expected W092=%d W093=%d, got W092=%d W093=%d:\n%s"
      label w092 got92 w093 got93 out

(* ── W092 fires, once, with the right suggestion ──────────────────────────── *)

let test_unindexed_filter () =
  let src = program {|
fn byOrg(orgId: String) -> List Issue requires [dbRead] =
  select i from Issue where i.orgId == orgId
|} in
  expect_codes "unindexed equality filter" src ~w092:1 ~w093:0;
  let out = lint src in
  if not (contains out "add `index [orgId]`") then
    failf "the diagnostic must name the exact declaration to add:\n%s" out

let test_composite_suggestion_from_multiline_query () =
  (* The multi-line clause form is rebuilt without a source location by the
     emitter's extractor.  Before usages were keyed on query identity this
     produced TWO findings: one at 1:1 over the full column set, and a weaker
     one suggesting `index [orgId]` at the `where` line. *)
  let src = program {|
fn recent(orgId: String) -> List Issue requires [dbRead] =
  select i from Issue
    where i.orgId == orgId
    order i.createdAt desc
    limit 50
|} in
  expect_codes "multi-line where + order" src ~w092:1 ~w093:0;
  let out = lint src in
  if not (contains out "add `index [orgId, createdAt]`") then
    failf "a where+order query wants the composite index, filter column first:\n%s" out;
  if contains out "Idx.tesl:1:1" then
    failf "a rebuilt query node must not be reported at the top of the file:\n%s" out

let test_one_finding_per_missing_index () =
  (* Three call sites, one missing index.  Reported once — the actionable unit is
     the declaration, and three copies of it is how a lint gets ignored. *)
  let src = program {|
fn a(orgId: String) -> List Issue requires [dbRead] =
  select i from Issue where i.orgId == orgId

fn b(orgId: String) -> List Issue requires [dbRead] =
  select i from Issue where i.orgId == orgId

fn c(orgId: String) -> List Issue requires [dbRead] =
  select i from Issue where i.orgId == orgId
|} in
  expect_codes "three queries, one missing index" src ~w092:1 ~w093:0;
  let out = lint src in
  if not (contains out "3 queries on `Issue` constrain") then
    failf "the count of affected queries should be in the message:\n%s" out

let test_delete_and_update_count () =
  expect_codes "a delete and an update on the same unindexed column"
    (program {|
fn purge(slug: String) -> Unit requires [dbWrite] =
  delete i from Issue where i.slug == slug
|}) ~w092:1 ~w093:0;
  expect_codes "an update filtering on an unindexed column"
    (program {|
fn rename(slug: String, t: String) -> Unit requires [dbRead, dbWrite] =
  update i in Issue
    where i.slug == slug
    set i.title = t
|}) ~w092:1 ~w093:0

let test_join_column_on_joined_entity () =
  (* The joined side needs its own index: the join column there is `ownerId`,
     not that entity's primary key. *)
  let src = Printf.sprintf {|
entity Issue table "issues" primaryKey id {
  id:      String
  orgId:   String
}

entity Owner table "owners" primaryKey id {
  id:      String
  ownerId: String
  index [ownerId]
}
%s

fn joined(orgId: String) -> List Issue requires [dbRead] =
  select i from Issue
    innerJoin Owner on i.orgId Owner.ownerId
    where i.orgId == orgId
|} (postgres_db "Issue, Owner") in
  (* Only Issue.orgId is unserved — Owner.ownerId is indexed above. *)
  expect_codes "join column indexed on the joined entity" src ~w092:1 ~w093:0;
  let out = lint src in
  if contains out "on `Owner`" then
    failf "the joined entity's index serves the join, so it must be silent:\n%s" out

let test_join_column_unindexed_on_joined_entity () =
  let src = Printf.sprintf {|
entity Issue table "issues" primaryKey id {
  id:      String
  orgId:   String
  index [orgId]
}

entity Owner table "owners" primaryKey id {
  id:      String
  ownerId: String
}
%s

fn joined(orgId: String) -> List Issue requires [dbRead] =
  select i from Issue
    innerJoin Owner on i.orgId Owner.ownerId
    where i.orgId == orgId
|} (postgres_db "Issue, Owner") in
  expect_codes "unindexed join column on the joined entity" src ~w092:1 ~w093:0;
  let out = lint src in
  if not (contains out "on `Owner`") then
    failf "the unindexed join column on the joined entity must be reported:\n%s" out

(* ── The silences ─────────────────────────────────────────────────────────── *)

let test_primary_key_filter_silent () =
  expect_codes "filtering on the primary key"
    (program {|
fn byId(id: String) -> List Issue requires [dbRead] =
  select i from Issue where i.id == id
|}) ~w092:0 ~w093:0

let test_declared_index_silences () =
  expect_codes "the declared index serves the query"
    (program ~entity_extra:"  index [orgId]" {|
fn byOrg(orgId: String) -> List Issue requires [dbRead] =
  select i from Issue where i.orgId == orgId
|}) ~w092:0 ~w093:0

let test_leading_column_prefix_serves () =
  (* PostgreSQL can use an index whose LEADING column is constrained, so a
     composite index serves a filter on its first column alone.  Reporting here
     would be a false positive. *)
  expect_codes "a composite index serves a filter on its leading column"
    (program ~entity_extra:"  index [orgId, createdAt]" {|
fn byOrg(orgId: String) -> List Issue requires [dbRead] =
  select i from Issue where i.orgId == orgId
|}) ~w092:0 ~w093:0

let test_memory_backend_silent () =
  expect_codes "a Memory-backed database has nothing to index"
    (program ~db:(memory_db "Issue") {|
fn byOrg(orgId: String) -> List Issue requires [dbRead] =
  select i from Issue where i.orgId == orgId
|}) ~w092:0 ~w093:0

let test_no_database_silent () =
  (* Without a database declaration in this file the backend is unknown, so
     there is nothing to say. *)
  expect_codes "an entity with no database declaration"
    (program ~db:"" {|
fn byOrg(orgId: String) -> List Issue requires [dbRead] =
  select i from Issue where i.orgId == orgId
|}) ~w092:0 ~w093:0

let test_ilike_silent () =
  (* A default-collation B-tree does not serve ILIKE, so suggesting an index
     would be bad advice. *)
  expect_codes "an ilike filter"
    (program {|
fn search(q: String) -> List Issue requires [dbRead] =
  select i from Issue where ilike i.title q
|}) ~w092:0 ~w093:0

let test_like_silent () =
  expect_codes "a like filter"
    (program {|
fn search(q: String) -> List Issue requires [dbRead] =
  select i from Issue where like i.title q
|}) ~w092:0 ~w093:0

let test_test_block_query_silent () =
  (* A query in a `test` block is not a production access path. *)
  expect_codes "a query inside a test block"
    (program {|
test "reads by slug" requires [dbRead, dbWrite] {
  let _ = insert Issue { id: "i1", orgId: "o", slug: "s", title: "t", createdAt: 0 }
  let rows = select i from Issue where i.slug == "s"
  expect rows != []
}
|}) ~w092:0 ~w093:0

let test_unfiltered_query_silent () =
  expect_codes "a query with no where/order at all"
    (program {|
fn all() -> List Issue requires [dbRead] =
  select i from Issue
|}) ~w092:0 ~w093:0

let test_group_by_time_trunc_silent () =
  (* `groupBy (Time.truncDay …)` groups by an EXPRESSION, which a plain column
     index cannot serve. *)
  expect_codes "a Time.trunc groupBy key"
    (Printf.sprintf {|
import Tesl.Tuple exposing [Tuple2]
import Tesl.Time exposing [Time.truncDay, TimeZone, Utc]

entity Issue table "issues" primaryKey id {
  id:        String
  createdAt: PosixMillis
}
%s

fn perDay(zone: TimeZone) -> List (Tuple2 PosixMillis Int) requires [dbRead] =
  selectCountBy i from Issue groupBy (Time.truncDay zone i.createdAt)
|} (postgres_db "Issue")) ~w092:0 ~w093:0

(* ── W093 ─────────────────────────────────────────────────────────────────── *)

let test_unused_index_reported () =
  let src = program ~entity_extra:"  index [orgId]\n  index [title]" {|
fn byOrg(orgId: String) -> List Issue requires [dbRead] =
  select i from Issue where i.orgId == orgId
|} in
  expect_codes "an index no query uses" src ~w092:0 ~w093:1;
  let out = lint src in
  if not (contains out "`index [title]` on `Issue` is not used") then
    failf "W093 should name the unused index:\n%s" out

let test_index_used_by_order_only () =
  (* `order` alone justifies an index, so an index whose leading column is only
     ever ORDERED by is used, not dead. *)
  expect_codes "an index used only by an order clause"
    (program ~entity_extra:"  index [createdAt]" {|
fn newest() -> List Issue requires [dbRead] =
  select i from Issue order i.createdAt desc limit 10
|}) ~w092:0 ~w093:0

let test_unique_index_used_by_on_conflict () =
  (* `onConflict [slug]` REQUIRES the unique index (checked as a hard error
     elsewhere), so the upsert is what makes that index used.  Reporting it as
     dead would contradict the compiler. *)
  expect_codes "a unique index used only by an upsert conflict target"
    (program ~entity_extra:"  unique index [slug]" {|
fn save(id: String, slug: String, title: String) -> Unit requires [dbWrite] =
  let done = upsert Issue { id: id, orgId: "o", slug: slug, title: title, createdAt: 0 }
    onConflict [slug] doUpdate [title]
  ok
|}) ~w092:0 ~w093:0

let test_schema_only_module_silent () =
  (* The common multi-module layout: a module holding entities and indexes, with
     the queries living in sibling modules.  W093 sees one file at a time and
     must not declare all of those indexes dead. *)
  expect_codes "a schema-only module with no queries"
    (program ~entity_extra:"  index [orgId]\n  index [title]" "") ~w092:0 ~w093:0

let test_memory_backend_no_unused_report () =
  expect_codes "unused index on a Memory-backed entity"
    (program ~db:(memory_db "Issue") ~entity_extra:"  index [title]" {|
fn byOrg(orgId: String) -> List Issue requires [dbRead] =
  select i from Issue where i.orgId == orgId
|}) ~w092:0 ~w093:0

(* ── Cross-module W092 (Phase A) ──────────────────────────────────────────── *)

(* The realistic layout: a schema module declaring the entity AND its database,
   plus a module that imports the entity and queries it.  Both files live in one
   directory because local imports resolve there and nowhere else
   (Validation_common.resolve_local_import_path). *)
let with_project files f =
  let dir = Filename.temp_dir "tesl-idxproj" "" in
  let paths =
    List.map (fun (name, content) ->
        let p = Filename.concat dir name in
        Out_channel.with_open_text p (fun oc -> Out_channel.output_string oc content);
        p) files
  in
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun p -> try Sys.remove p with _ -> ()) paths;
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f dir)

let db_module ?(entity_extra = "") ?(backend = `Postgres) () =
  Printf.sprintf {|module Db exposing [Issue]

import Tesl.Prelude exposing [String]
import Tesl.Time exposing [PosixMillis]

entity Issue table "issues" primaryKey id {
  id:        String
  orgId:     String
  slug:      String
  createdAt: PosixMillis
%s
}
%s
|} entity_extra
  (match backend with `Postgres -> postgres_db "Issue" | `Memory -> memory_db "Issue")

let app_module = {|module App exposing [byOrg]

import Tesl.Prelude exposing [List, String]
import Tesl.DB exposing [dbRead]
import Db exposing [Issue]

fn byOrg(orgId: String) -> List Issue requires [dbRead] =
  select i from Issue where i.orgId == orgId
|}

let lint_in_project files target =
  with_project files (fun dir -> run_cc [ "--lint"; Filename.concat dir target ])

let test_cross_module_missing_index () =
  let out =
    lint_in_project [ ("db.tesl", db_module ()); ("app.tesl", app_module) ] "app.tesl"
  in
  if count_code out "W092" <> 1 then
    failf "a query on an IMPORTED entity must be judged against that entity's \
           indexes (expected 1 W092):\n%s" out;
  if not (contains out "add `index [orgId]`") then
    failf "the suggestion should name the imported entity's missing index:\n%s" out

let test_cross_module_index_silences () =
  let out =
    lint_in_project
      [ ("db.tesl", db_module ~entity_extra:"  index [orgId]" ()); ("app.tesl", app_module) ]
      "app.tesl"
  in
  if count_code out "W092" <> 0 then
    failf "an index declared in the IMPORTED module must silence the query:\n%s" out

let test_cross_module_memory_backend_silent () =
  (* The backend is declared in the imported module too, so the Memory
     suppression has to cross the same edge. *)
  let out =
    lint_in_project
      [ ("db.tesl", db_module ~backend:`Memory ()); ("app.tesl", app_module) ]
      "app.tesl"
  in
  if count_code out "W092" <> 0 then
    failf "a Memory backend declared in the imported module must suppress:\n%s" out

let test_schema_module_stays_silent () =
  (* db.tesl declares the entity, the database and two indexes but contains no
     query.  W093 is file-scoped by design, so it must not call them dead. *)
  let out =
    lint_in_project
      [ ("db.tesl", db_module ~entity_extra:"  index [orgId]\n  index [slug]" ());
        ("app.tesl", app_module) ]
      "db.tesl"
  in
  if count_code out "W092" <> 0 || count_code out "W093" <> 0 then
    failf "a schema-only module must stay silent (W092=%d W093=%d):\n%s"
      (count_code out "W092") (count_code out "W093") out

let test_unresolvable_import_is_silent () =
  (* The importing module is linted alone: the entity cannot be resolved, so
     there is nothing to say.  Fail-silent, never "no index". *)
  let out = lint_in_project [ ("app.tesl", app_module) ] "app.tesl" in
  if count_code out "W092" <> 0 then
    failf "with the imported module absent the lint must say nothing:\n%s" out

let test_local_entity_wins_over_imported () =
  (* Both modules declare an `Issue`.  The local one is indexed; the query must
     be judged against IT, not against the imported one.  (A name exposed by two
     modules is a hard error elsewhere — this pins the local-shadows-imported
     order, which is what makes the lookup unambiguous.) *)
  let local_issue = Printf.sprintf {|module App exposing [byOrg]

import Tesl.Prelude exposing [List, String]
import Tesl.Time exposing [PosixMillis]
import Tesl.DB exposing [dbRead]
import Db exposing [Issue]

entity Issue table "local_issues" primaryKey id {
  id:    String
  orgId: String
  index [orgId]
}
%s

fn byOrg(orgId: String) -> List Issue requires [dbRead] =
  select i from Issue where i.orgId == orgId
|} (postgres_db "Issue") in
  let out = lint_in_project [ ("db.tesl", db_module ()); ("app.tesl", local_issue) ] "app.tesl" in
  if count_code out "W092" <> 0 then
    failf "the LOCAL entity's index must be the one consulted:\n%s" out

(* ── The editor path: buffer in a temp file, real path in TESL_LOGICAL_PATH ── *)

let run_cc_env env args =
  let assignments = String.concat " " (List.map (fun (k, v) -> k ^ "=" ^ Filename.quote v) env) in
  let q = Filename.quote compiler :: List.map Filename.quote args in
  let ic = Unix.open_process_in (assignments ^ " " ^ String.concat " " q ^ " 2>&1") in
  let out = In_channel.input_all ic in
  ignore (Unix.close_process_in ic);
  out

(* Without the logical path the lint resolves imports from the temp directory,
   finds no sibling, and goes quiet — a "works on the CLI, silent in the editor"
   divergence with no error anywhere.  This is the one prerequisite Phase A
   could not skip. *)
let test_temp_buffer_needs_logical_path () =
  with_project
    [ ("db.tesl", db_module ()); ("app.tesl", app_module) ]
    (fun dir ->
       let real = Filename.concat dir "app.tesl" in
       let tmp = Filename.temp_file "tesl-buffer" ".tesl" in
       Fun.protect ~finally:(fun () -> try Sys.remove tmp with _ -> ())
         (fun () ->
            let content = In_channel.with_open_text real In_channel.input_all in
            Out_channel.with_open_text tmp (fun oc -> Out_channel.output_string oc content);
            let without = run_cc [ "--lint"; tmp ] in
            if count_code without "W092" <> 0 then
              failf "a temp copy with no logical path cannot see its siblings, so \
                     it must be silent:\n%s" without;
            let with_lp = run_cc_env [ ("TESL_LOGICAL_PATH", real) ] [ "--lint"; tmp ] in
            if count_code with_lp "W092" <> 1 then
              failf "with TESL_LOGICAL_PATH the temp buffer must resolve its \
                     siblings and report (expected 1 W092):\n%s" with_lp))

let test_check_json_reports_on_the_edited_document () =
  (* --check-json is the entry point the LSP actually uses.  The finding must
     come back anchored at the checked file, so the editor puts the squiggle on
     the document being edited rather than on the imported module. *)
  with_project
    [ ("db.tesl", db_module ()); ("app.tesl", app_module) ]
    (fun dir ->
       let real = Filename.concat dir "app.tesl" in
       let tmp = Filename.temp_file "tesl-buffer" ".tesl" in
       Fun.protect ~finally:(fun () -> try Sys.remove tmp with _ -> ())
         (fun () ->
            let content = In_channel.with_open_text real In_channel.input_all in
            Out_channel.with_open_text tmp (fun oc -> Out_channel.output_string oc content);
            let out = run_cc_env [ ("TESL_LOGICAL_PATH", real) ] [ "--check-json"; tmp ] in
            if not (contains out "W092") then
              failf "--check-json must carry the W092 finding:\n%s" out;
            (* The diagnostic's file is the checked (temp) path, which the LSP
               treats as an entry-document row — never the imported module. *)
            if contains out "db.tesl\", \"start_line" then
              failf "the finding must not be anchored in the imported module:\n%s" out))

let () =
  run "database index lints" [
    "W092 reports", [
      test_case "unindexed filter"                  `Quick test_unindexed_filter;
      test_case "multi-line where+order, once"      `Quick test_composite_suggestion_from_multiline_query;
      test_case "one finding per missing index"     `Quick test_one_finding_per_missing_index;
      test_case "delete and update filters"         `Quick test_delete_and_update_count;
      test_case "join column indexed on joined"     `Quick test_join_column_on_joined_entity;
      test_case "join column unindexed on joined"   `Quick test_join_column_unindexed_on_joined_entity;
    ];
    "W092 silences", [
      test_case "primary-key filter"                `Quick test_primary_key_filter_silent;
      test_case "declared index"                    `Quick test_declared_index_silences;
      test_case "composite leading-column prefix"   `Quick test_leading_column_prefix_serves;
      test_case "Memory backend"                    `Quick test_memory_backend_silent;
      test_case "no database declaration"           `Quick test_no_database_silent;
      test_case "ilike filter"                      `Quick test_ilike_silent;
      test_case "like filter"                       `Quick test_like_silent;
      test_case "query inside a test block"         `Quick test_test_block_query_silent;
      test_case "unfiltered query"                  `Quick test_unfiltered_query_silent;
      test_case "Time.trunc groupBy key"            `Quick test_group_by_time_trunc_silent;
    ];
    "W093", [
      test_case "unused index reported"             `Quick test_unused_index_reported;
      test_case "index used by order only"          `Quick test_index_used_by_order_only;
      test_case "unique index used by onConflict"   `Quick test_unique_index_used_by_on_conflict;
      test_case "schema-only module stays silent"   `Quick test_schema_only_module_silent;
      test_case "Memory backend not reported"       `Quick test_memory_backend_no_unused_report;
    ];
    "cross-module W092", [
      test_case "imported entity, missing index"    `Quick test_cross_module_missing_index;
      test_case "imported entity, index silences"   `Quick test_cross_module_index_silences;
      test_case "imported Memory backend"           `Quick test_cross_module_memory_backend_silent;
      test_case "schema-only module silent"         `Quick test_schema_module_stays_silent;
      test_case "unresolvable import silent"        `Quick test_unresolvable_import_is_silent;
      test_case "local entity shadows imported"     `Quick test_local_entity_wins_over_imported;
    ];
    "editor path", [
      test_case "temp buffer needs logical path"    `Quick test_temp_buffer_needs_logical_path;
      test_case "check-json anchors on document"    `Quick test_check_json_reports_on_the_edited_document;
    ];
  ]
