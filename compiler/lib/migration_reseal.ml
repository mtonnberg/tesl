(* Re-sealing a migration history under the running compiler.

   Seals record the compiler ABI and the stored-value identity they were
   checked under. After a compiler upgrade the seals no longer match: with a
   new ABI only, completed steps are re-checked on every build (no trust, no
   checkpoints); with a new stored-value identity the build refuses (MIG013).
   Re-sealing recomputes every seal of the family: the two
   snapshot seals in each migration header (new identity, compiler ABI and
   snapshot digest), then each completed migration's frozen-source block (its
   root digest covers the header) and its checkpoint. Nothing else is
   rewritten, and no seal is recomputed unless every recorded byte it covers
   still matches: re-sealing never blesses an edited frozen source.

   This module only computes proposed file contents. The caller
   (Migration_preview.generate_reseal) re-checks the complete history under
   the new identity with trust disabled before it offers them as a guarded
   manifest. *)
module A = Migration_abi
module H = Migration_history_sources
module S = Migration_seal
module Header = Migration_header
module Closure = Migration_closure
module I = Migration_inventory
module E = Migration_sparse

exception Invalid of E.error list
let fail ?(code="MIG013") file message = raise (Invalid [{E.code;loc=Location.dummy_loc file;message;related=[]}])
let sparse = function Ok x -> x | Error errors -> raise (Invalid errors)
let sealed = function Ok x -> x | Error (e : S.error) ->
  raise (Invalid [{E.code="MIG013";loc=e.loc;message=e.message;related=[]}])
let history = function Ok x -> x | Error (e : H.error) ->
  raise (Invalid [{E.code="MIG020";loc=e.loc;message=e.message;related=[]}])
let protect f = try Ok (f ()) with Invalid errors -> Error errors
let overlay root writes f =
  Source_input.with_overlays ~project_root:(Option.value (Source_input.project_root ()) ~default:root) writes f

type edge = {
  migration : H.migration_source;
  previous_seal : S.t;            (* as recorded *)
  current_seal : S.t;
  checkpointed : bool;            (* the recorded frozen-source block names a checkpoint *)
  completed : bool;
}

type proposal = {
  writes : (string * string) list;   (* migration roots, then checkpoints *)
  reads : string list;
  recorded_identities : string list; (* identities the seals recorded, deduplicated *)
  recorded_abis : string list;       (* compiler ABIs the seals recorded, deduplicated *)
  identity : string;                 (* the identity now recorded *)
}

let module_root family version = family ^ ".Migrate.V" ^ string_of_int version

(* Verify every recorded byte before anything is recomputed. *)
let recorded ~project_root:root ~family (h : H.t) =
  let completed = H.completed_migrations h and current = H.current_migration h in
  List.map (fun (m : H.migration_source) ->
    let located = match sparse (Header.read ~file:m.path m.contents) with
      | Some located -> located
      | None -> fail m.path "this migration has no recorded source seals; finish it with `tesl migrate <entry.tesl>` first" in
    let previous,current_root = Header.roots located in
    let checked = sparse (Header.verify ~project_root:root ~migration_module:(module_root family m.version)
      ~previous ~current:current_root located) in
    let closure = sparse (Closure.read ~file:m.path m.contents) in
    let is_completed = List.memq m completed in
    (match closure,is_completed with
     | Some located,_ -> sparse (Closure.verify ~project_root:root ~root_file:m.path ~source:m.contents located)
     | None,true -> fail m.path "a completed migration requires its frozen-source block; restore it from version control"
     | None,false -> ());
    let previous_seal,current_seal = Header.seals checked in
    {migration=m;previous_seal;current_seal;completed=is_completed;
     checkpointed=(match closure with Some l -> Closure.checkpoint l <> None | None -> false)})
    (completed @ Option.to_list current)

let seals_and_closures ~context ~project_root:root ~family =
  protect (fun () ->
  let abi = A.id context and identity = A.stored_value_compatibility context in
  let h = history (H.discover_with_compatibility ~stored_value_compatibility:(Some identity)
    ~compiler_abi:abi ~project_root:root ~family) in
  let edges = recorded ~project_root:root ~family h in
  if edges = [] then fail ~code:"MIG020" root "this database has no migration history yet; there are no seals to re-record";
  let recorded_identities = List.concat_map (fun e ->
    List.filter_map S.stored_value_compatibility [e.previous_seal;e.current_seal]) edges
    |> List.sort_uniq compare in
  let recorded_abis = List.concat_map (fun e -> [S.compiler_abi e.previous_seal;S.compiler_abi e.current_seal]) edges
    |> List.sort_uniq compare in
  if recorded_identities = [identity] && recorded_abis = [abi] then
    fail ~code:"MIG020" root "every seal already records this compiler's ABI and stored-value identity; there is nothing to re-seal";
  let schemas = H.frozen h @ [H.current h] in
  let fresh recorded_seal =
    let root_module = S.root_module recorded_seal in
    let schema = match List.find_opt (fun s -> I.root_module (H.inventory s) = root_module) schemas with
      | Some s -> s | None -> fail root ("the history no longer contains the sealed schema " ^ root_module) in
    S.inherit_queue_inventory ~from:recorded_seal (sealed (S.create ~project_root:root (H.inventory schema))) in
  let headers = List.map (fun e ->
    let header = sparse (Header.create ~previous:(fresh e.previous_seal) ~current:(fresh e.current_seal)) in
    e,sparse (Header.replace ~file:e.migration.path ~source:e.migration.contents header)) edges in
  (* Each completed root's digest covers its new header, so capture under the
     proposed headers. The checkpoint is added separately: it depends on the
     complete proposed history. *)
  let roots = List.map (fun (e,source) -> e.migration.path,source) headers in
  let closed = overlay root roots (fun () -> List.map (fun (e,source) ->
    if not e.completed then e,source,None else
    let closure = sparse (Closure.capture ~project_root:root ~root_file:e.migration.path ~source) in
    let closure = Closure.with_checkpoint closure None in
    e,sparse (Closure.attach ~file:e.migration.path ~source closure),Some closure) headers) in
  let reads = List.map fst (H.source_inputs h) in
  closed,reads,(recorded_identities,recorded_abis),identity,h)

(* Add the recomputed checkpoints. [derive] returns None when the prefix no
   longer checks; the caller has already reported the full diagnostics. *)
let with_checkpoints ~context ~project_root:root ~family (closed,reads,(recorded_identities,recorded_abis),identity,_) =
  protect (fun () ->
  let abi = A.id context in
  let roots = List.map (fun (e,source,_) -> e.migration.path,source) closed in
  let finished = List.map (fun (e,source,closure) ->
    match closure with
    | Some closure when e.checkpointed ->
      let text = overlay root roots (fun () ->
        Migration_checkpoint.derive ~stored_value_compatibility:identity ~compiler_abi:abi
          ~project_root:root ~family ~through:e.migration.version ()) in
      (match text with
       | None -> fail e.migration.path (Printf.sprintf
           "the checkpoint of V%d cannot be recomputed under the new stored-value semantics" e.migration.version)
       | Some text ->
         let closure = Closure.with_checkpoint closure (Some (Migration_hash.digest text)) in
         [e.migration.path,sparse (Closure.attach ~file:e.migration.path ~source closure);
          Closure.checkpoint_file e.migration.path,text])
    | _ -> [e.migration.path,source]) closed |> List.concat in
  let roots,checkpoints = List.partition (fun (file,_) -> Filename.check_suffix file ".tesl") finished in
  {writes=roots @ checkpoints;reads;recorded_identities;recorded_abis;identity})

let unchecked_writes (closed,_,_,_,_) = List.map (fun (e,source,_) -> e.migration.path,source) closed
