(** Frozen queue contracts are a language prerequisite. This module grants no
    runtime admission, claim, decoder, or processing authority. *)
open Ast
module I = Migration_inventory
module S = Migration_sparse
let error loc message = {S.code="MIG028";loc;message;related=[]}
let relative inventory name =
  let prefix = I.root_module inventory ^ "." in
  if not (String.starts_with ~prefix name) then invalid_arg "queue identity is outside its owning schema";
  String.sub name (String.length prefix) (String.length name - String.length prefix)
let wire_identity = relative

let changes ~before ~after =
  let old = I.queue_contracts before and fresh = I.queue_contracts after in
  let current = List.map (fun q -> relative after q.I.queue_name,q) fresh in
  List.concat_map (fun q ->
    let name = relative before q.I.queue_name in
    match List.assoc_opt name current with
    | None -> [error q.queue_loc ("queueSchema `" ^ name ^ "` was removed or renamed; queue payload migrations are not implemented")]
    | Some target ->
      let payloads = List.map (fun p -> relative after p.I.payload_name,p) target.payloads in
      List.filter_map (fun payload ->
        let identity = relative before payload.I.payload_name in
        match List.assoc_opt identity payloads with
        | None -> Some (error payload.payload_loc ("queue payload `" ^ identity ^ "` was removed, renamed or moved from `" ^ name ^ "`; declare a new payload identity without deleting its predecessor until jobs migrations are available"))
        | Some p when p.payload_contract <> payload.payload_contract ->
          Some (error p.payload_loc ("queue payload `" ^ identity ^ "` changed its frozen shape, proof or codec closure; jobs migrations are not implemented"))
        | Some _ -> None) q.payloads) old

let historical_capability ~before ~after seals =
  if I.queue_contracts before = [] && I.queue_contracts after = [] then [] else
  match seals with
  | Some (previous,current) when Migration_seal.queue_inventory_complete previous &&
      Migration_seal.queue_inventory_complete current -> []
  | _ -> [error (Location.dummy_loc "<queue-history>")
      "queue history lacks an authoritative complete payload inventory; legacy absence is unknown, including when its source now contains no queueSchema. Do not regenerate old seals to claim completeness"]

let constructor = function EConstructor {name;args=[];_} -> Some name | _ -> None
let fields expression = Option.fold ~none:[] ~some:Desugar.config_record_fields expression

(** Resolve contextual metadata through the same direct import/export boundary
    as ordinary source names. Merely finding an owned declaration is insufficient. *)
let visible_reference modules (m:module_form) declared_name name =
  let local = List.filter_map (fun d -> Option.map (fun n -> m.module_name ^ "." ^ n) (declared_name d)) m.decls in
  let own = m.module_name ^ "." ^ name in
  if List.mem name local then Some name else if List.mem own local then Some own else
  let candidates = List.concat_map (fun (imp:import_decl) ->
    match List.find_opt (fun (owner:module_form) -> owner.module_name=imp.module_name) modules with
    | None -> []
    | Some owner -> List.filter_map (fun d -> match declared_name d with
        | None -> None
        | Some n when List.mem (ExportName n) owner.exports ->
          let qualified = owner.module_name ^ "." ^ n in
          let exposed = match imp.names with ImportAll -> false | ImportExposing names -> List.mem n names in
          if name=qualified || (name=n && exposed) then Some qualified else None
        | Some _ -> None) owner.decls) m.imports |> List.sort_uniq compare in
  match candidates with [one] -> Some one | _ -> None

let active_queues (m:module_form) =
  match List.find_map (function DFunc fd when fd.kind=MainKind -> Some fd | _ -> None) m.decls with
  | None -> Ok []
  | Some fd ->
    (match Ast.app_record_of_main fd with
     | None -> Error "versioned queues require main to end in a literal App record; imperative or computed activation is not supported"
     | Some app ->
       match List.assoc_opt "queues" (Desugar.config_record_fields app) with
       | None -> Ok []
       | Some (EList {elems;_}) when List.for_all (fun e -> constructor e<>None) elems ->
         Ok (List.filter_map constructor elems)
       | Some _ -> Error "versioned queues require a literal App.queues list of local queue names")

let application_bindings ~modules ~(database_module:module_form) ~(database:database_form) inventory =
  let contracts = I.queue_contracts inventory in
  let database_identity = database_module.module_name ^ "." ^ database.name in
  let family_databases = List.concat_map (fun (m:module_form) -> List.filter_map (function
    | DDatabase d when Option.bind (List.assoc_opt "schema" (fields d.config_expr)) constructor = Some (I.root_module inventory) ->
      Some (m.module_name ^ "." ^ d.name)
    | _ -> None) m.decls) modules in
  let family_databases = database_identity :: family_databases in
  let contract_names = List.map (fun q -> q.I.queue_name) contracts in
  let bindings = ref [] and errors = ref [] in
  let report loc message = errors := error loc message :: !errors in
  List.iter (fun (m:module_form) ->
    let active = active_queues m in
    List.iter (function
      | DQueue q ->
        let config = fields q.config_expr in
        let db = Option.bind (List.assoc_opt "database" config) constructor
          |> fun name -> Option.bind name (visible_reference modules m (function DDatabase d -> Some d.name | _ -> None)) in
        if Option.fold ~none:false ~some:(fun db -> List.mem db family_databases) db then begin
          let schema = Option.bind (List.assoc_opt "schema" config) constructor
            |> fun name -> Option.bind name (visible_reference modules m (function DQueueSchema q -> Some q.name | _ -> None)) in
          match schema with
          | None -> report q.loc "a queue on a versioned database requires `schema:` naming its imported queueSchema contract"
          | Some name when not (List.mem name contract_names) -> report q.loc "Queue.schema must belong to its database's VCurrent schema closure"
          | Some name ->
            let contract = List.find (fun c -> c.I.queue_name=name) contracts in
            bindings := (name,q.loc) :: !bindings;
            (match active with
             | Error message -> report q.loc message
             | Ok names ->
               if List.length (List.filter ((=) q.name) names) <> 1 then
                 report q.loc "a versioned queue contract must be activated exactly once in main's App.queues list");
            let jobs = match List.assoc_opt "jobs" config with
              | Some (EList {elems;_} as e) ->
                let jobs=Desugar.job_entries e in
                if List.length jobs<>List.length elems then
                  report q.loc "versioned Queue.jobs accepts only complete Job <Payload> <worker> <dead-slot> entries; bare or computed members are not supported";
                jobs
              | _ ->
                report q.loc "versioned Queue.jobs must be a literal list of complete Job entries"; [] in
            let jobs = List.map (fun (name,_,_) ->
              visible_reference modules m (function DRecord r -> Some r.name | _ -> None) name) jobs in
            let expected = List.map (fun p -> p.I.payload_name) contract.payloads |> List.sort compare in
            if List.exists Option.is_none jobs || List.sort compare (List.filter_map Fun.id jobs) <> expected then
              report q.loc "Queue.jobs must bind each frozen queueSchema payload exactly once using Job entries"
        end
      | _ -> ()) m.decls) modules;
  List.iter (fun contract ->
    match List.filter (fun (name,_) -> name=contract.I.queue_name) !bindings with
    | [_] -> ()
    | [] -> report contract.queue_loc ("queueSchema `" ^ relative inventory contract.queue_name ^ "` has no activated application Queue binding; deleting a binding does not remove durable jobs")
    | _ -> report contract.queue_loc "a queueSchema contract must have exactly one application Queue binding") contracts;
  List.rev !errors
