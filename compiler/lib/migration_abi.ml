module Input = Source_input
module Hash = Migration_hash
module V = Validation_common
module Build = Migration_build_snapshot
type error = {path:string;message:string}
type resource = {name:string;path:string;source:string;digest:string}
type t = {id:string;stored_value_compatibility:string;fingerprint:string;
          stdlib_semantics:(string * string) list;resources:resource list}
exception Invalid of error
let reject path message = raise (Invalid {path;message})
let id t = t.id
(* The stored-value identity: the string seals, compiled histories and
   databases record (`tesl-stored-value-v1:<hex>`; databases pin that format
   in CHECK constraints and installed functions). Two compilers with the same
   identity read, write and prove stored values the same way. *)
let stored_value_compatibility t = t.stored_value_compatibility
(* The semantic fingerprint the identity is derived from:
   `tesl-stored-value-fingerprint-v2:<hex>`. *)
let fingerprint t = t.fingerprint
let stdlib_semantics t = t.stdlib_semantics

(* The identity before semantic fingerprints (v1 derivation): SHA-256 over the
   raw bytes of every stdlib .tesl file plus one hand-bumped revision string.
   It is still computed so a database and seals recorded under it keep working:
   see [known_identities]. The string is frozen; behaviour revisions now live
   in Stored_value_revisions. *)
let legacy_semantics_revision = "tesl-stored-value-semantics-5"
let identity_prefix = "tesl-stored-value-v1:"
let fingerprint_prefix = "tesl-stored-value-fingerprint-v2:"
let valid_digest_suffix prefix value =
  String.starts_with ~prefix value && String.length value = String.length prefix + 64 &&
  String.for_all (function '0'..'9' | 'a'..'f' -> true | _ -> false)
    (String.sub value (String.length prefix) 64)
let valid_stored_value_compatibility = valid_digest_suffix identity_prefix
let frame values = String.concat "" (List.map (fun value -> string_of_int (String.length value) ^ ":" ^ value) values)
let component label values = frame (label :: List.map (fun (name,value) -> frame [name;value]) (List.sort compare values))

(* Canonical form of one stdlib module for the fingerprint: its lexical token
   stream, which drops comments, blank lines and horizontal spacing but keeps
   the indentation structure (INDENT/DEDENT/NEWLINE), every literal and name,
   and the one spacing distinction the parser reads (`f -3` versus `x - 3`).
   Test declarations cannot affect stored values and are left out. Renaming a
   local or reordering declarations still changes the fingerprint; that is a
   conservative answer, never a missed change. A module that does not parse is
   fingerprinted by its raw bytes. *)
let canonical_stdlib ~name source =
  match Parser.parse_module name source with
  | Parser.Err _ -> frame ["unparsed";source]
  | Parser.Ok m ->
    let tests = List.filter_map (function
      | Ast.DTest t -> Some t.loc | Ast.DApiTest t -> Some t.loc | Ast.DLoadTest t -> Some t.loc
      | _ -> None) m.decls in
    (* A test's lines are dropped with their layout tokens, except a DEDENT on
       its first line: that one closes the preceding declaration. *)
    let excluded (t : Lexer.full_token) = List.exists (fun (loc : Location.loc) ->
      t.line >= loc.start.line && t.line <= loc.stop.line &&
      not (t.tok = DEDENT && t.line = loc.start.line)) tests in
    let text (token : Token.t) = match token with
      | IDENT s -> "i" ^ s | UIDENT s -> "u" ^ s | INT n -> "n" ^ string_of_int n
      | BIGINT s -> "b" ^ s | FLOAT f -> "f" ^ Printf.sprintf "%h" f
      | STRING s -> "s" ^ s | INTERP (s,_) -> "p" ^ s
      | token -> "k" ^ Format.asprintf "%a" Token.pp token in
    let previous = ref None in
    let tokens = List.filter_map (fun (t : Lexer.full_token) ->
      let adjacent = match !previous with
        | Some (p : Lexer.full_token) -> p.line = t.line && p.col + 1 = t.col
        | None -> false in
      previous := Some t;
      if excluded t then None else Some ((if adjacent then "+" else " ") ^ text t.tok)) (Lexer.tokenize name source) in
    frame ("tokens" :: tokens)

let derive_fingerprint ~stdlib_semantics ~revisions =
  fingerprint_prefix ^ Hash.digest (frame ["tesl-stored-value-fingerprint-v2";
    component "stdlib-semantics" stdlib_semantics;
    component "builtin-revisions" (List.map (fun (name,revision) -> name,string_of_int revision) revisions)])
let derived_identity fingerprint =
  identity_prefix ^ Hash.digest (frame ["tesl-stored-value-identity-v2";fingerprint])

(* Identities this compiler can explain, each with the semantics it stands for.
   The first entry is the v1 baseline: the byte-derived identity that every
   history sealed and every database installed before semantic fingerprints
   records. The compiler that introduced fingerprints computed both values for
   the same stdlib and builtins, so a compiler whose fingerprint equals that
   baseline has the same stored-value semantics and keeps the v1 identity:
   comment and formatting edits no longer change it.
   Every other entry must use [derived_identity] of its fingerprint; only the
   baseline may name a byte-derived identity (test_migration_abi pins it).
   When an intentional semantic change gives a new fingerprint, record it here
   (the test prints the entry) so MIG013 can explain later mismatches. *)
type known = {identity:string;known_fingerprint:string;stdlib:(string * string) list;builtins:(string * int) list}
let known_identities : known list = [
  {identity="tesl-stored-value-v1:9b265343069c361d3879d623b69de5081f934ec0f2f8826dc0efeda951384a30";
   known_fingerprint="tesl-stored-value-fingerprint-v2:72ce3657022baa8ad5d45710064ab59ec1ad98319fcd082a82077435c6a454b6";
   stdlib=[
     "civil-time.tesl","d782f214a4260ffb71feaf84460551b83224ea67bf2463fe8799e9fe55b2abcd";
     "either.tesl","0cc54b243a0f0cab5f223e3784c98c927f435c56212f4c1ab92bab0fd6db0f9e";
     "list-prim.tesl","a84c7277c1401f762cc77a8bc163a1cbf4f93a3955556da6b25e1fb29afc572b";
     "list.tesl","29e1b683d6de4276547270700be8d9948d6663e1df08e502c0d8c7b31332bdfc"];
   builtins=["proof-interpretation",5;"canonical-storage-mapping",1;"json-codecs",1;"database-values",1;
     "numbers-and-units",1;"text-and-patterns",1;"time",1;"credentials",1;"urls-and-hosts",1;
     "collections",1;"checks",1]};
]
let identity_of_fingerprint fingerprint =
  match List.find_opt (fun k -> k.known_fingerprint = fingerprint) known_identities with
  | Some known -> known.identity
  | None -> derived_identity fingerprint

(* What differs between a recorded identity and this compiler, as short
   sentences for MIG013. *)
let explain_difference t ~recorded =
  match List.find_opt (fun k -> k.identity = recorded) known_identities with
  | None -> ["the recorded identity " ^ recorded ^ " is not known to this compiler; it was recorded by a \
              different compiler build, whose stdlib or builtin behaviour differs"]
  | Some known ->
    let modules = List.sort_uniq compare (List.map fst known.stdlib @ List.map fst t.stdlib_semantics) in
    let stdlib = List.filter_map (fun name ->
      match List.assoc_opt name known.stdlib,List.assoc_opt name t.stdlib_semantics with
      | Some a,Some b when a = b -> None
      | Some _,Some _ -> Some ("stdlib module " ^ name ^ " changed declarations")
      | None,Some _ -> Some ("stdlib module " ^ name ^ " was added")
      | Some _,None -> Some ("stdlib module " ^ name ^ " was removed")
      | None,None -> None) modules in
    let current = Stored_value_revisions.revisions () in
    let families = List.sort_uniq compare (List.map fst known.builtins @ List.map fst current) in
    let builtins = List.filter_map (fun name ->
      match List.assoc_opt name known.builtins,List.assoc_opt name current with
      | Some a,Some b when a = b -> None
      | Some a,Some b -> Some (Printf.sprintf "builtin behaviour %s changed from revision %d to %d" name a b)
      | None,Some b -> Some (Printf.sprintf "builtin behaviour %s was introduced at revision %d" name b)
      | Some a,None -> Some (Printf.sprintf "builtin behaviour %s (revision %d) was removed" name a)
      | None,None -> None) families in
    match stdlib @ builtins with
    | [] -> ["the semantic fingerprint differs although no recorded component did"]
    | changes -> changes

let reseal_command = "tesl migrate reseal <entry.tesl>"

let lifted_source t module_name =
 Option.bind (V.lifted_stdlib_basename module_name) (fun name ->
  Option.map (fun resource -> resource.path,resource.source)
   (List.find_opt (fun resource -> resource.name=name) t.resources))
let source_inputs t = List.map (fun r -> r.path,r.digest) t.resources |> List.sort compare
let compiled = lazy (
  if Embedded_go_runtime.files=[] then reject "<compiler>" "migration source commands require an embedded execution runtime";
  component "compiler" (("ocaml-version",Build.ocaml_version)::Build.compiler_sources),
  component "embedded-go-runtime" (List.map (fun (name,source) -> name,Hash.digest source) Embedded_go_runtime.files))
(* Canonical digests are a pure function of the bytes; parse each version once. *)
let semantic_digests : (string,string) Hashtbl.t = Hashtbl.create 8
let semantic_digest r =
  match Hashtbl.find_opt semantic_digests r.digest with
  | Some digest -> digest
  | None ->
    let digest = Hash.digest (canonical_stdlib ~name:r.path r.source) in
    Hashtbl.replace semantic_digests r.digest digest; digest
(* The v1 (byte-derived) identity of a resource set; see [known_identities]. *)
let legacy_identity resources =
  identity_prefix ^ Hash.digest (frame [legacy_semantics_revision;
    component "lifted-stdlib" (List.map (fun r -> r.name,r.digest) resources)])
let legacy_stored_value_compatibility t = legacy_identity t.resources
let current () =
  try
    let compiler,runtime = Lazy.force compiled in
    let chosen = Hashtbl.create 8 in
    List.iter (fun directory ->
      if Input.exists directory then begin
        if Input.kind (Input.realpath directory) <> Unix.S_DIR then reject directory "stdlib resource directory is not a directory";
        Input.readdir directory |> Array.to_list |> List.sort String.compare |> List.iter (fun name ->
          if Filename.check_suffix name ".tesl" && not (Hashtbl.mem chosen name) then begin
            let file = Filename.concat directory name in
            let resolved = Input.realpath file in
            if Input.kind resolved <> Unix.S_REG then reject file "stdlib ABI inputs must resolve to regular files";
            let source = Input.read resolved in
            Hashtbl.add chosen name {name;path=resolved;source;digest=Hash.digest source}
          end)
      end) (V.stdlib_source_directories ());
    List.iter (fun (_,name) -> if not (Hashtbl.mem chosen name) then
      reject name "a required lifted stdlib source is unavailable for the compiler ABI") V.lifted_stdlib_sources;
    let resources = Hashtbl.to_seq chosen |> List.of_seq |> List.sort compare |> List.map snd in
    let stdlib = component "lifted-stdlib" (List.map (fun r -> r.name,r.digest) resources) in
    let id = "tesl-source-abi-v1:" ^ Hash.digest (frame ["migration-compiler";compiler;runtime;stdlib]) in
    let stdlib_semantics = List.map (fun r -> r.name,semantic_digest r) resources in
    let fingerprint = derive_fingerprint ~stdlib_semantics ~revisions:(Stored_value_revisions.revisions ()) in
    let stored_value_compatibility = identity_of_fingerprint fingerprint in
    Ok {id;stored_value_compatibility;fingerprint;stdlib_semantics;resources}
  with
  | Invalid error -> Error error
  | Sys_error message | Invalid_argument message | Failure message -> Error {path="<compiler>";message}
  | Unix.Unix_error (error,operation,path) -> Error {path;message=operation ^ ": " ^ Unix.error_message error}
(* MIG013 text for a seal recorded under another identity. *)
let mismatch_message ~recorded =
  let changes = match current () with
    | Ok t -> explain_difference t ~recorded
    | Error _ -> [] in
  let current = match current () with Ok t -> t.stored_value_compatibility | Error _ -> "unavailable" in
  Printf.sprintf "this migration history was sealed under stored-value identity %s, but this compiler's \
    stored-value semantics have identity %s%s. Run `%s` to re-check the complete frozen history under the \
    new semantics and re-record its seals. A database that already stores values under the old identity \
    refuses binaries built after revalidation; see manual/migration-operations.md \"Stored-value identity\""
    recorded current
    (match changes with [] -> "" | changes -> " (" ^ String.concat "; " changes ^ ")")
    reseal_command
let verify expected = match Input.without_pinned_files current with
  | Error error -> Error error
  | Ok actual when actual.id=expected.id -> Ok ()
  | Ok _ -> Error {path="<compiler>";message="compiler or lifted stdlib ABI changed after source generation began"}

let active_snapshot : string option ref = ref None
let with_snapshot snapshot f =
  match !active_snapshot with
  | Some id when id <> snapshot.id -> Error {path="<compiler>";message="nested generation cannot change the compiler ABI"}
  | _ -> match verify snapshot with
  | Error _ as error -> error
  | Ok () ->
    let previous = !active_snapshot in
    active_snapshot := Some snapshot.id;
    let result = Fun.protect ~finally:(fun () -> active_snapshot := previous) (fun () ->
      Input.with_pinned_files (List.map (fun r -> r.path,r.source) snapshot.resources) (fun () ->
        V.with_fixed_stdlib_sources (List.map (fun r -> r.name,r.path) snapshot.resources) f)) in
    match verify snapshot with
    | Error _ as error -> error
    | Ok () -> Ok result
