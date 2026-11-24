(* Trust seals for completed migration history.

   A completed step Migrate.V<k> (its target is a frozen schema V<k>, not
   VCurrent) receives the complete compiler judgment when it is frozen. Its file
   then records SHA-256 digests of everything that judgment read:
   - the two snapshot seals cover the exact bytes of the V<k-1> and V<k> schema
     closures and their import resolution;
   - the frozen-migration block covers the migration root (including those seal
     headers), its private helpers and its Contract companion.
   Both snapshot seals also record the compiler ABI and the stored-value
   compatibility contract they were checked under.

   Later compilations re-hash those inputs. When every digest matches and both
   seals were recorded under this exact compiler ABI and stored-value contract,
   re-running the per-step checks would read the same bytes with the same
   compiler and reach the same result, so the step is trusted: its migration
   body, converters and fixtures are not type/proof checked again and its seals
   are not re-derived. Anything else falls back to the full check:
   - a changed, missing or unparsable recorded input (the full check then
     reports the ordinary MIG013/MIG001 integrity diagnostic);
   - a seal recorded under another compiler ABI with the same stored-value
     contract (re-checked under the current compiler, as before trust existed);
   - a different stored-value identity (refused with MIG013, naming what
     changed and `tesl migrate reseal`, which re-checks the complete
     history under the new semantics and re-records the seals);
   - the current step (target VCurrent), which has no completed seal.

   Trust only removes repeated per-step judgments. Cross-step history analysis
   (row history, retained storage, expansion origins, Contracts) and the data the
   newest step needs from older revisions (their checked inventories) are still
   computed from the hash-verified sources in every compilation.

   Accepted trade-off: a frozen file edited together with consistently recomputed
   digests is trusted until a full check. TESL_FULL_HISTORY=1 (or the compiler's
   --full-history flag) disables trust and re-checks every revision; CI should
   run it periodically. *)

let requested = ref false

let full_history () =
  !requested ||
  match Sys.getenv_opt "TESL_FULL_HISTORY" with
  | Some ("1" | "true" | "yes" | "on") -> true
  | _ -> false

let request_full_history () =
  requested := true;
  (* Child compiler processes (for example the native CLI's helpers) inherit
     the same choice. *)
  Unix.putenv "TESL_FULL_HISTORY" "1"

(* Disable trust for one scope of this process only (revalidation's complete
   re-check); child processes are not affected. *)
let with_full_history f =
  let previous = !requested in
  requested := true;
  Fun.protect ~finally:(fun () -> requested := previous) f

type evidence = { root : string }

let root evidence = evidence.root

(* Roots trusted in this process, most recent first (tests and diagnostics). *)
let trusted_log : string list ref = ref []
let trusted_roots () = List.rev !trusted_log
let reset_trusted_roots () = trusted_log := []

(* Both snapshot seals of one completed edge were recorded by this exact
   compiler build. The ABI identity covers the compiler, its embedded runtime and
   the lifted stdlib bytes, so equal identities also mean an equal stored-value
   identity; a seal without an explicit identity (legacy seal format v1) is never
   trusted. *)
let same_compiler ~compiler_abi ~stored_value_compatibility seals =
  List.for_all (fun seal ->
    Migration_seal.compiler_abi seal = compiler_abi &&
    (match Migration_seal.stored_value_compatibility seal, stored_value_compatibility with
     | None, _ -> false
     | Some recorded, Some current -> recorded = current
     | Some _, None -> true)) seals

let completed root =
  match Validation_common.schema_module_parts root with
  | Some (_, revision, []) -> revision <> "VCurrent"
  | _ -> false

(* The caller must already have verified [header] against its sources and the
   module's adjacent roots, and [closure] against the raw closure bytes. *)
let of_verified ~compiler_abi ~stored_value_compatibility ~root ~header ~closure =
  match header, closure with
  | Some header, Some _ when not (full_history ()) ->
    let previous, current = Migration_header.seals header in
    if completed (Migration_seal.root_module current) &&
       same_compiler ~compiler_abi ~stored_value_compatibility [previous; current]
    then (trusted_log := root :: !trusted_log; Some { root }) else None
  | _ -> None

let current_compiler () =
  Option.map (fun abi -> Migration_abi.id abi, Migration_abi.stored_value_compatibility abi)
    (Result.to_option (Migration_abi.current ()))

(* Recorded parse facts are trusted state: never used under full history. *)
let () =
  Migration_module_facts.disabled := full_history;
  Migration_module_facts.current_abi := (fun () -> Option.map fst (current_compiler ()))

(* Self-contained decision for a saved completed migration file reached only as
   history (not the module being queried). Any failure means "not trusted"; the
   caller then runs the full check, which reports the precise diagnostic. *)
(* Whether completed migration [file] with exactly [source] has seals that hold
   under [compiler]: its frozen closure and both schema seals match the bytes
   they record, which were recorded by this compiler ABI and stored-value
   contract. The trust condition itself, whatever the full-history setting
   (a history summary records it, Migration_history_summary). *)
let seals_hold ~project_root ~compiler:(compiler_abi, contract) ~file ~source =
  try
    match Migration_header.read ~file source, Migration_closure.read ~file source with
    | Ok (Some located), Ok (Some closure) ->
      let previous, current = Migration_header.roots located in
      let migration_module = Migration_header.module_name located in
      Validation_common.schema_module_relative_path migration_module
        |> Option.map (Filename.concat project_root) = Some file &&
      Migration_closure.verify ~project_root ~root_file:file ~source closure = Ok () &&
      (match Migration_header.verify ~project_root ~migration_module ~previous ~current located with
       | Ok checked ->
         let previous, current = Migration_header.seals checked in
         completed (Migration_seal.root_module current) &&
         same_compiler ~compiler_abi ~stored_value_compatibility:(Some contract) [previous; current]
       | Error _ -> false)
    | _ -> false
  with Sys_error _ | Unix.Unix_error _ | Invalid_argument _ | Failure _ | Not_found -> false

let edge_uncached ~project_root ~compiler ~file ~source =
  if full_history () then None
  else match compiler with
  | None -> None
  | Some (compiler_abi, contract) ->
    try
      match Migration_header.read ~file source, Migration_closure.read ~file source with
      | Ok (Some located), Ok (Some closure) ->
        let previous, current = Migration_header.roots located in
        let migration_module = Migration_header.module_name located in
        if Validation_common.schema_module_relative_path migration_module
           |> Option.map (Filename.concat project_root) <> Some file then None
        else
        (* The closure first: its verified checkpoint supplies the parse facts
           both verifications use. *)
        let closure_checked = Migration_closure.verify ~project_root ~root_file:file ~source closure in
        (match Migration_header.verify ~project_root ~migration_module ~previous ~current located, closure_checked with
         | Ok checked, Ok () ->
           of_verified ~compiler_abi ~stored_value_compatibility:(Some contract)
             ~root:migration_module ~header:(Some checked) ~closure:(Some closure)
         | _ -> None)
      | _ -> None
    with Sys_error _ | Unix.Unix_error _ | Invalid_argument _ | Failure _ | Not_found -> None

(* One command asks about the same completed edge from discovery, the
   checkpoint, the application check and the capture. A decision is reused only
   under the identical source view (same overlays and pinned resources) in
   which it re-hashed every recorded input; any other view decides again. *)
(* A decision is also reused in another view when every filesystem
   observation it made gets the same answer there (Source_input.same_reads). *)
let edge_memo : (string * string * string * (string * string) option,
  Source_input.view_token list ref * Source_input.observation list * evidence option) Migration_analysis_cache.t =
  Migration_analysis_cache.create ~limit:4096
let edge ~project_root ~compiler ~file ~source =
  if full_history () then None else
  (* A completed revision below the newest checkpoint, unchanged since that
     checkpoint's verified history summary recorded that its seals held. *)
  match compiler with
  | Some compiler when Migration_history_summary.sealed_edge ~project_root ~compiler ~file ~source ->
    let root = match Migration_header.read ~file source with
      | Ok (Some located) -> Migration_header.module_name located | _ -> file in
    trusted_log := root :: !trusted_log; Some { root }
  | _ ->
  let key = project_root,file,Migration_hash.digest source,compiler in
  let decide () =
    let token = Source_input.view_token () in
    let evidence,reads = Source_input.recording (fun () -> Source_input.with_path_memo (fun () -> edge_uncached ~project_root ~compiler ~file ~source)) in
    ref [token],reads,evidence in
  (* Trust re-hashes recorded bytes only; no proof scope shapes it. *)
  let _,_,evidence = Migration_analysis_cache.find ~any_scope:true edge_memo ~key
    ~guard:(fun (tokens,reads,_) -> List.exists Source_input.same_view !tokens ||
      (Source_input.same_reads (List.hd !tokens) reads && (tokens := Source_input.view_token () :: !tokens; true))) decide in
  Option.iter (fun e -> trusted_log := e.root :: !trusted_log) evidence;
  evidence

(* [edge] for a parsed captured module, deriving the project root from its
   canonical versioned path. A completed migration root, or the Contract
   companion of one (its bytes belong to the root's frozen closure), can be
   trusted. *)
let module_edge ~compiler (m : Ast.module_form) source =
  match Validation_common.schema_module_parts m.module_name,
        Validation_common.schema_module_relative_path m.module_name with
  | Some (family, "Migrate", [revision]), Some relative ->
    let file = Validation_common.canonical_import_path m.source_file in
    let suffix = Filename.dir_sep ^ relative in
    if not (String.ends_with ~suffix file) then None
    else
      let project_root = String.sub file 0 (String.length file - String.length suffix) in
      if Filename.check_suffix revision "Contract" then
        let root = family ^ ".Migrate." ^ Filename.chop_suffix revision "Contract" in
        match Validation_common.schema_module_relative_path root with
        | None -> None
        | Some relative ->
          let root_file = Filename.concat project_root relative in
          (try edge ~project_root ~compiler ~file:root_file ~source:(Source_input.read root_file)
           with Sys_error _ | Unix.Unix_error _ | Invalid_argument _ | Failure _ -> None)
      else edge ~project_root ~compiler ~file ~source
  | Some (family, revision, _), Some relative when revision <> "VCurrent" && revision <> "Migrate" ->
    (* A frozen schema module V<k> (or a private module of its closure) whose
       exact bytes are recorded in a seal of a trusted completed migration:
       the previous-schema seal of V<k+1> or the current-schema seal of V<k>.
       That seal was written from this compiler's checked inventory of exactly
       these bytes. *)
    let file = Validation_common.canonical_import_path m.source_file in
    let suffix = Filename.dir_sep ^ relative in
    (match int_of_string_opt (String.sub revision 1 (String.length revision - 1)) with
     | Some version when revision.[0] = 'V' && String.ends_with ~suffix file ->
       let project_root = String.sub file 0 (String.length file - String.length suffix) in
       let digest = Migration_hash.digest source in
       let covered migration pick =
         match Validation_common.schema_module_relative_path (Printf.sprintf "%s.Migrate.V%d" family migration) with
         | None -> false
         | Some relative ->
           let root_file = Filename.concat project_root relative in
           (try
              let root_source = Source_input.read root_file in
              edge ~project_root ~compiler ~file:root_file ~source:root_source <> None &&
              (match Migration_header.read ~file:root_file root_source with
               | Ok (Some located) ->
                 let seal = pick (Migration_header.recorded_seals located) in
                 Migration_seal.root_module seal = family ^ "." ^ revision &&
                 List.assoc_opt m.module_name (Migration_seal.sources seal) = Some digest
               | _ -> false)
            with Sys_error _ | Unix.Unix_error _ | Invalid_argument _ | Failure _ -> false) in
       if covered (version + 1) fst || (version > 1 && covered version snd)
       then Some { root = m.module_name } else None
     | _ -> None)
  | _ -> None
