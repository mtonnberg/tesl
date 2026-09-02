(** Entity index declarations — the compile-time half.

    Two things are pinned here.

    {2 The declaration surface}

    `index [a, b]` / `unique index [a] as "name"` inside an entity body, with
    every validation rule that keeps a declaration from becoming a runtime
    surprise.  Two of them are not obvious:

    - explicit index names must be unique across EVERY entity, not per entity:
      a PostgreSQL index is a `pg_class` relation, so its name lives in the
      SCHEMA namespace, and two entities sharing a name would silently have the
      second `create index if not exists` match the first one's index.
    - `index` and `unique` must stay ORDINARY identifiers.  Every SQL clause
      word in Tesl (`where`, `order`, `onConflict`, …) is a plain identifier
      recognised positionally, and promoting `index` to a keyword would break
      every existing program using it as a field or variable name.  The
      backward-compatibility cases below are the ratchet for that.

    {2 The correctness payoff — `onConflict`}

    `upsert E { … } onConflict [cols] doUpdate [cols]` lowers to PostgreSQL
    `insert … on conflict (cols) do update …`, and PostgreSQL can only INFER a
    conflict target from a unique index on exactly those columns; without one it
    raises "there is no unique or exclusion constraint matching the ON CONFLICT
    specification".  Before unique indexes existed in the language, any
    `onConflict` on a non-primary-key column list was therefore UNFIXABLE — and
    it failed green, because the in-memory backend finds the conflicting row by
    scanning whatever columns were named, with no uniqueness requirement, so the
    same program passed `tesl test` and died in production.  These cases pin
    that the compiler now rejects it. *)

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
  let st = Unix.close_process_in ic in
  let code = match st with Unix.WEXITED c -> c | Unix.WSIGNALED n | Unix.WSTOPPED n -> 128 + n in
  (code, out)

let with_source src f =
  let dir = Filename.temp_dir "tesl-dbindex" "" in
  let path = Filename.concat dir "Indexes.tesl" in
  Out_channel.with_open_text path (fun oc -> Out_channel.output_string oc src);
  Fun.protect
    ~finally:(fun () ->
      (try Sys.remove path with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f path)

let contains hay needle =
  try ignore (Str.search_forward (Str.regexp_string needle) hay 0); true
  with Not_found -> false

let count_occurrences hay needle =
  let re = Str.regexp_string needle in
  let rec go from acc =
    match (try Some (Str.search_forward re hay from) with Not_found -> None) with
    | None -> acc
    | Some i -> go (i + 1) (acc + 1)
  in
  go 0 0

let prelude = {|module Indexes exposing []
import Tesl.Prelude exposing [String, Int]
import Tesl.Time exposing [PosixMillis]
import Tesl.Money exposing [Money]
import Tesl.DB exposing [dbWrite]
|}

let check src = with_source (prelude ^ src) (fun p -> run_cc ["--check"; p])

let emit_go src =
  match Compile.compile_go_source "Indexes.tesl" (prelude ^ src) with
  | Compile.GoFailure diagnostics ->
    failf "Go emit failed: %s"
      (String.concat "; " (List.map (fun (d : Compile.diagnostic) -> d.message) diagnostics))
  | Compile.GoSuccess artifacts ->
    match List.find_opt (fun (a : Emit_go.artifact) -> a.path = "internal/teslmodindexes/module.go") artifacts with
    | Some artifact -> artifact.contents
    | None -> failf "Go emit produced no module.go artifact"

let should_pass label src =
  let code, out = check src in
  if code <> 0 then failf "%s: expected a clean check, got exit %d:\n%s" label code out

let should_fail label ~expect src =
  let code, out = check src in
  if code = 0 then failf "%s: expected REJECTION, but the check passed" label;
  if not (contains out expect) then
    failf "%s: rejected, but not for the expected reason (wanted %S):\n%s" label expect out

(* An entity body wrapped in a database so the declaration is fully wired. *)
let entity body =
  Printf.sprintf
    {|entity Issue table "kanel_issues" primaryKey id {
  id:        String
  orgId:     String
  slug:      String
  amount:    Money
  createdAt: PosixMillis
%s
}

database MainDb = Database {
  schema: "app"
  entities: [Issue]
  backend: Memory
}
|} body

(* ── The declaration surface ─────────────────────────────────────────────── *)

let test_accepted_forms () =
  should_pass "plain, composite, unique and explicitly named indexes"
    (entity {|  index [createdAt]
  index [orgId, createdAt]
  unique index [orgId, slug]
  index [slug] as "kanel_issues_by_slug"|})

let test_no_indexes_still_fine () =
  should_pass "an entity with no index declarations" (entity "")

let test_unknown_field () =
  should_fail "an index naming a field the entity does not have"
    ~expect:"which is not a field of `Issue`"
    (entity "  index [nope]")

let test_repeated_field () =
  should_fail "the same field twice inside one index"
    ~expect:"names `orgId` twice"
    (entity "  index [orgId, orgId]")

let test_duplicate_index () =
  should_fail "two identical index declarations"
    ~expect:"declares `index [orgId]` twice"
    (entity {|  index [orgId]
  index [orgId]|})

let test_unique_and_plain_on_same_columns_differ () =
  (* Same columns but different uniqueness are DIFFERENT objects: the unique one
     enforces an invariant.  Only an exact (columns, uniqueness) repeat is dead
     weight. *)
  should_pass "a unique and a plain index over the same columns"
    (entity {|  index [orgId]
  unique index [orgId]|})

let test_money_field_rejected () =
  (* A Money field stores into two derived columns, so "an index over the field"
     is not a meaningful object — the same reason it is already refused as a
     primary key and as an upsert conflict key. *)
  should_fail "indexing a Money field"
    ~expect:"which is a Money field"
    (entity "  index [amount]")

let test_primary_key_index_redundant () =
  should_fail "an index that just repeats the primary key"
    ~expect:"duplicates the primary-key index"
    (entity "  index [id]")

let test_composite_starting_with_pk_allowed () =
  (* Only the exact single-column PK repeat is redundant; a composite that
     happens to lead with the PK is a real, different index. *)
  should_pass "a composite index whose first column is the primary key"
    (entity "  index [id, createdAt]")

let test_empty_index_rejected () =
  should_fail "an index naming no fields at all"
    ~expect:"names no fields"
    (entity "  index []")

let test_bad_explicit_name () =
  should_fail "an explicit name that is not a plain SQL identifier"
    ~expect:"is not a plain SQL identifier"
    (entity {|  index [orgId] as "no-hyphens-please"|})

let test_overlong_explicit_name () =
  (* PostgreSQL truncates identifiers at 63 bytes with only a NOTICE, so two
     long names sharing a 63-byte prefix collide and `if not exists` then
     matches the WRONG index.  Explicit names are rejected outright rather than
     silently truncated. *)
  should_fail "an explicit name longer than PostgreSQL's 63-byte limit"
    ~expect:"PostgreSQL truncates identifiers at 63"
    (entity (Printf.sprintf "  index [orgId] as \"%s\"" (String.make 64 'a')))

let test_name_collision_across_entities () =
  should_fail "the same explicit index name on two different entities"
    ~expect:"is already used by entity `A`"
    {|entity A table "a" primaryKey id {
  id: String
  k:  String
  index [k] as "shared_idx"
}

entity B table "b" primaryKey id {
  id: String
  k:  String
  index [k] as "shared_idx"
}

database MainDb = Database {
  schema: "app"
  entities: [A, B]
  backend: Memory
}
|}

let test_same_name_on_one_entity_collides () =
  should_fail "the same explicit index name twice on one entity"
    ~expect:"is already used by entity `Issue`"
    (entity {|  index [orgId] as "dup_idx"
  index [createdAt] as "dup_idx"|})

(* ── Backward compatibility: `index` is NOT a keyword ─────────────────────── *)

let test_index_is_still_an_ordinary_field_name () =
  should_pass "fields named `index` and `unique`, indexed by an index entry"
    {|entity Row table "rows" primaryKey id {
  id:     String
  index:  Int
  unique: String
  index [index]
  unique index [unique]
}

database MainDb = Database {
  schema: "app"
  entities: [Row]
  backend: Memory
}
|}

let test_index_is_still_an_ordinary_variable_name () =
  should_pass "a function parameter and a let binding named `index`"
    {|fn bump(index: Int) -> Int =
  let unique = index + 1
  unique
|}

let test_index_still_a_record_field () =
  (* Index entries are entity-only; a record body must keep treating `index` as
     an ordinary field name. *)
  should_pass "a record with a field named `index`"
    {|record Cursor {
  index: Int
}
|}

(* ── The Go artifacts and memory behavior are the authority ───────────────── *)

let test_entity_metadata_carries_all_indexes () =
  let src = prelude ^ entity {|  index [orgId, createdAt]
  unique index [orgId, slug]
  index [slug] as "kanel_issues_by_slug"|} in
  let metadata = match Parser.parse_module "Indexes.tesl" src with
    | Ok module_ -> Ir.module_to_json ~source_name:"Indexes.tesl" module_
    | Err _ -> failf "entity metadata source did not parse"
  in
  let expected =
    {|"indexes":[{"fields":["orgId","createdAt"],"unique":false,"name":null},{"fields":["orgId","slug"],"unique":true,"name":null},{"fields":["slug"],"unique":false,"name":"kanel_issues_by_slug"}]|}
  in
  if not (contains metadata expected) then
    failf "entity metadata does not carry every declared index (wanted %S):\n%s"
      expected metadata

let test_emitted_go_enforces_unique_index () =
  (* Memory has no physical index artifact. The observable contract is emitted at
     each write: the exact unique key is handed to the table implementation. *)
  let out = emit_go {|
entity Issue table "kanel_issues" primaryKey id {
  id: String
  orgId: String
  slug: String
  unique index [orgId, slug]
}

database MainDb = Database {
  schema: "app"
  entities: [Issue]
  backend: Memory
}

fn add(issue: Issue) -> Issue requires [dbWrite] =
  insert Issue {
    id: issue.id,
    orgId: issue.orgId,
    slug: issue.slug
  }
|} in
  List.iter (fun expected ->
    if not (contains out expected) then
      failf "emitted Go does not enforce the unique index (wanted %S):\n%s" expected out)
    [ "teslrt.UniqueIndexOf("; "[]string{\"org_id\", \"slug\"}";
      "(teslLeft.OrgId == teslRight.OrgId) && (teslLeft.Slug == teslRight.Slug)" ]

let test_no_indexes_emits_no_index_artifact () =
  let out = emit_go (entity "") in
  if contains out "UniqueIndexOf" || contains out "PostgresIndexOf" then
    failf "an entity with no indexes emitted an index artifact:\n%s" out

(* ── `onConflict` needs a unique index ───────────────────────────────────── *)

let upsert_program ~index_decls ~conflict =
  Printf.sprintf
    {|entity User table "users" primaryKey id {
  id:    String
  email: String
  name:  String
%s
}

database MainDb = Database {
  schema: "app"
  entities: [User]
  backend: Memory
}

fn save(id: String, email: String, name: String) -> Int requires dbWrite =
  let done = upsert User { id: id, email: email, name: name } onConflict [%s] doUpdate [name]
  1
|} index_decls conflict

let test_conflict_on_primary_key_ok () =
  should_pass "onConflict on the primary key needs no declaration"
    (upsert_program ~index_decls:"" ~conflict:"id")

let test_conflict_without_unique_index_rejected () =
  should_fail "onConflict on a non-primary-key column with no unique index"
    ~expect:"needs a unique index on (email)"
    (upsert_program ~index_decls:"" ~conflict:"email")

let test_conflict_hint_names_the_fix () =
  let _, out = check (upsert_program ~index_decls:"" ~conflict:"email") in
  if not (contains out "add `unique index [email]`") then
    failf "the diagnostic should name the exact declaration to add:\n%s" out

let test_plain_index_does_not_satisfy_conflict () =
  (* A plain index cannot infer a conflict target — PostgreSQL requires
     uniqueness, so accepting this would reintroduce the runtime failure. *)
  should_fail "onConflict backed by a plain (non-unique) index"
    ~expect:"needs a unique index on (email)"
    (upsert_program ~index_decls:"  index [email]" ~conflict:"email")

let test_unique_index_satisfies_conflict () =
  should_pass "onConflict backed by a unique index"
    (upsert_program ~index_decls:"  unique index [email]" ~conflict:"email")

let test_composite_conflict_needs_matching_composite_unique () =
  should_pass "a composite onConflict matched by a composite unique index"
    (upsert_program ~index_decls:"  unique index [email, name]" ~conflict:"email, name")

let test_composite_conflict_column_order_matters () =
  (* PostgreSQL infers by column SET, but the declaration is what the compiler
     can check exactly; a reversed list is a different declaration and is
     reported rather than guessed at. *)
  should_fail "a composite onConflict whose column order differs from the index"
    ~expect:"needs a unique index on (name, email)"
    (upsert_program ~index_decls:"  unique index [email, name]" ~conflict:"name, email")

let test_conflict_reported_once () =
  (* The upsert spine is a chain of nested applications; a looser match reports
     the same upsert three times. *)
  let _, out = check (upsert_program ~index_decls:"" ~conflict:"email") in
  let n = count_occurrences out "needs a unique index on (email)" in
  if n <> 1 then failf "expected exactly one diagnostic, got %d:\n%s" n out

let () =
  run "database indexes" [
    "declaration surface", [
      test_case "accepted forms"                      `Quick test_accepted_forms;
      test_case "no indexes is fine"                  `Quick test_no_indexes_still_fine;
      test_case "unknown field rejected"              `Quick test_unknown_field;
      test_case "repeated field rejected"             `Quick test_repeated_field;
      test_case "duplicate index rejected"            `Quick test_duplicate_index;
      test_case "unique vs plain are distinct"        `Quick test_unique_and_plain_on_same_columns_differ;
      test_case "Money field rejected"                `Quick test_money_field_rejected;
      test_case "primary-key repeat rejected"         `Quick test_primary_key_index_redundant;
      test_case "composite leading with pk allowed"   `Quick test_composite_starting_with_pk_allowed;
      test_case "empty index rejected"                `Quick test_empty_index_rejected;
      test_case "bad explicit name rejected"          `Quick test_bad_explicit_name;
      test_case "over-long explicit name rejected"    `Quick test_overlong_explicit_name;
      test_case "name collision across entities"      `Quick test_name_collision_across_entities;
      test_case "name collision within one entity"    `Quick test_same_name_on_one_entity_collides;
    ];
    "backward compatibility", [
      test_case "`index` still a field name"          `Quick test_index_is_still_an_ordinary_field_name;
      test_case "`index` still a variable name"       `Quick test_index_is_still_an_ordinary_variable_name;
      test_case "`index` still a record field"        `Quick test_index_still_a_record_field;
    ];
    "Go artifacts", [
      test_case "entity metadata carries all indexes" `Quick test_entity_metadata_carries_all_indexes;
      test_case "emitted Go enforces unique index"    `Quick test_emitted_go_enforces_unique_index;
      test_case "no indexes emits no artifact"        `Quick test_no_indexes_emits_no_index_artifact;
    ];
    "upsert onConflict", [
      test_case "primary-key conflict accepted"       `Quick test_conflict_on_primary_key_ok;
      test_case "no unique index rejected"            `Quick test_conflict_without_unique_index_rejected;
      test_case "diagnostic names the fix"            `Quick test_conflict_hint_names_the_fix;
      test_case "plain index does not satisfy"        `Quick test_plain_index_does_not_satisfy_conflict;
      test_case "unique index satisfies"              `Quick test_unique_index_satisfies_conflict;
      test_case "composite unique satisfies"          `Quick test_composite_conflict_needs_matching_composite_unique;
      test_case "composite order matters"             `Quick test_composite_conflict_column_order_matters;
      test_case "reported exactly once"               `Quick test_conflict_reported_once;
    ];
  ]
