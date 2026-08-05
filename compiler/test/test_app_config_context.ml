(** App config-context — the LSP's field hover/completion inside `App { … }`.

    [Compile.config_decl_expr] enumerated the typed config blocks the LSP offers
    field help for (`Database`, `Queue`, `Email`, …) but omitted `main`'s
    trailing `App { … }` record, so the ONE block every project has produced no
    field hints at all — even though `Validation_structural.config_block_schema`
    has always carried a full "App" schema.

    Pinned here because it is invisible to every other test: the compiler builds,
    checks and emits identically whether or not this is wired, so a refactor
    could silently drop it again. The `mountPath` doc in particular is the field
    whose CORRECT USE is least obvious from its type (what is mounted, what is
    not, and how to point a load balancer at it), which is exactly where an
    editor hint earns its keep. *)

let src = {|module AppCtx exposing []
import Tesl.Prelude exposing [String]
import Tesl.Database exposing [Database, Memory]
import Tesl.App exposing [App]

database Db = Database {
  entities: []
  backend: Memory
}

handler get ping() -> String requires [] =
  "pong"

api A {
  get "/ping" -> String
}

server S for A {
  ping
}

main() -> App requires [] =
  App {
    database: Db
    api: S
    port: 8080
    mountPath: "/api"
  }
|}

(* 0-based line of `mountPath:` inside the App record. *)
let mount_path_line =
  let lines = String.split_on_char '\n' src in
  let rec find i = function
    | [] -> failwith "fixture lost its mountPath line"
    | l :: rest ->
      let trimmed = String.trim l in
      if String.length trimmed >= 9 && String.sub trimmed 0 9 = "mountPath" then i
      else find (i + 1) rest
  in
  find 0 lines

let context_at line =
  Compile.config_context_source "<test>" src line 6

let test_app_block_is_recognised () =
  match context_at mount_path_line with
  | None ->
    Alcotest.fail
      "no config context inside `App { … }` — the LSP offers no field help for \
       the one config block every project has"
  | Some c ->
    Alcotest.(check string) "block type" "App" c.Compile.cc_block

let test_app_fields_are_offered () =
  match context_at mount_path_line with
  | None -> Alcotest.fail "no config context inside `App { … }`"
  | Some c ->
    let names = List.map (fun f -> f.Compile.cfi_name) c.Compile.cc_fields in
    List.iter (fun expected ->
      if not (List.mem expected names) then
        Alcotest.failf "App schema should offer `%s`; got [%s]"
          expected (String.concat ", " names))
      [ "database"; "api"; "port"; "static"; "mountPath"; "queues" ]

let test_required_and_present_flags () =
  match context_at mount_path_line with
  | None -> Alcotest.fail "no config context inside `App { … }`"
  | Some c ->
    let field n = List.find_opt (fun f -> f.Compile.cfi_name = n) c.Compile.cc_fields in
    (match field "database" with
     | Some f ->
       Alcotest.(check bool) "database is required" true f.Compile.cfi_required;
       Alcotest.(check bool) "database is present in the fixture" true f.Compile.cfi_present
     | None -> Alcotest.fail "no `database` field");
    (match field "queues" with
     | Some f ->
       Alcotest.(check bool) "queues is optional" false f.Compile.cfi_required;
       Alcotest.(check bool) "queues is absent from the fixture" false f.Compile.cfi_present
     | None -> Alcotest.fail "no `queues` field")

let test_mount_path_hover_is_actionable () =
  match context_at mount_path_line with
  | None -> Alcotest.fail "no config context inside `App { … }`"
  | Some c ->
    (match List.find_opt (fun f -> f.Compile.cfi_name = "mountPath") c.Compile.cc_fields with
     | None -> Alcotest.fail "no `mountPath` field in the App schema"
     | Some f ->
       (* The type label must state the slash rule, since "which end does the
          slash go on" is the friction this field exists to remove. *)
       let ty = f.Compile.cfi_type in
       if not (String.length ty > 0) then Alcotest.fail "empty type label";
       let contains hay needle =
         let n = String.length hay and m = String.length needle in
         let found = ref false in
         for i = 0 to n - m do
           if m <= n && String.sub hay i m = needle then found := true done;
         !found
       in
       if not (contains ty "/") then
         Alcotest.failf "type label should state the slash rule, got %S" ty;
       (* The doc must actually explain the feature, not be the empty default
          every config field used to get. *)
       let doc = f.Compile.cfi_doc in
       if String.length doc < 80 then
         Alcotest.failf "mountPath hover doc is missing or too thin: %S" doc;
       List.iter (fun needle ->
         if not (contains doc needle) then
           Alcotest.failf "mountPath hover should mention %S; got:\n%s" needle doc)
         (* what it does, what is NOT mounted, and the validation rule *)
         [ "prefix"; "SSO"; "static"; "start with `/`"; "not end with `/`" ])

let test_other_blocks_still_work () =
  (* Guard against the App wiring breaking the pre-existing blocks. *)
  let lines = String.split_on_char '\n' src in
  let rec find i = function
    | [] -> failwith "fixture lost its backend line"
    | l :: rest ->
      let t = String.trim l in
      if String.length t >= 7 && String.sub t 0 7 = "backend" then i else find (i + 1) rest
  in
  match context_at (find 0 lines) with
  | None -> Alcotest.fail "no config context inside `Database { … }`"
  | Some c -> Alcotest.(check string) "block type" "Database" c.Compile.cc_block

let () =
  Alcotest.run "App config-context (LSP field help)" [
    "App block", [
      Alcotest.test_case "the App record is recognised" `Quick test_app_block_is_recognised;
      Alcotest.test_case "its schema fields are offered" `Quick test_app_fields_are_offered;
      Alcotest.test_case "required/present flags are right" `Quick test_required_and_present_flags;
      Alcotest.test_case "mountPath hover is actionable" `Quick test_mount_path_hover_is_actionable;
    ];
    "regression guard", [
      Alcotest.test_case "other config blocks still resolve" `Quick test_other_blocks_still_work;
    ];
  ]
