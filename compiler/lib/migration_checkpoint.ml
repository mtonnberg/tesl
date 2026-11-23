(* Seal-covered checkpoints of completed migration history.

   When Start freezes revision V<n>, it also writes migrations/<family>/v<n>.checkpoint:
   the canonical state that cross-revision analysis carries from V<n> to the next
   revision, so a later build resumes there instead of folding over every
   revision from V1. The checkpoint holds
   - the compiler ABI and stored-value contract that produced it;
   - the chain: every completed migration V2..V<n> with the root digest recorded
     in its frozen-source block (binding the checkpoint to that exact history);
   - row generations at V<n> (Migration_row_history.prefix);
   - the retained-storage planning state after V<n> (Migration_retained_storage);
   - the installation-origin refusal fixed by the prefix, if any.
   Its SHA-256 sits in V<n>'s frozen-source block, so an edited checkpoint byte
   fails like any other sealed byte (MIG013, Migration_closure.verify).

   A build uses the checkpoint of its newest completed migration only when every
   completed migration's trust seal verifies (Migration_trust: the same
   condition under which those steps are not re-checked) and the checkpoint was
   produced by this exact compiler ABI and stored-value contract. Otherwise, or
   under --full-history, history is folded from V1 as before. A full-history
   build also recomputes every recorded checkpoint and refuses a stale one.

   Histories outside the carried subset (table Drop, staged indexes, queue
   conversions, reverse writes) never get a checkpoint and always fold from V1. *)
module C = Migration_canonical
module D = Migration_declaration
module H = Migration_history_sources
module RH = Migration_row_history
module RS = Migration_retained_storage
module S = Migration_sparse

type t = {
  family : string;
  version : int;
  compiler_abi : string;
  stored_value_compatibility : string;
  chain : (int * string) list;
  prefix : RH.prefix;
  refusal : S.error list option;
  (* The published records of the revisions this checkpoint completes (V1 and
     V2 for the first, V<n> otherwise), with the application namespace they
     were computed for; None when they could not be recorded. *)
  records : (string * Migration_records.t) option;
}

let format = "tesl-migration-checkpoint-v2"
(* Written by earlier compilers, whose ABI never matches this one. *)
let earlier_formats = ["tesl-migration-checkpoint-v1"]
exception Invalid of S.error list
exception Earlier_format
let reject file message = raise (Invalid [{S.code="MIG013";loc=Location.dummy_loc file;message;related=[]}])
let atom s = C.Bytes s
let int n = atom (string_of_int n)

(* Paths inside the project are recorded relative to it, so a checkpoint stays
   valid when the repository is cloned elsewhere. *)
let relative ~project_root file =
  let prefix = project_root ^ Filename.dir_sep in
  if String.starts_with ~prefix file then
    "./" ^ String.sub file (String.length prefix) (String.length file - String.length prefix)
  else file
let absolute ~project_root file =
  if String.starts_with ~prefix:"./" file then Filename.concat project_root (String.sub file 2 (String.length file - 2))
  else file

let encode_error ~project_root (e:S.error) =
  C.Seq [atom e.code;atom e.message;atom (relative ~project_root e.loc.file);
    int e.loc.start.line;int e.loc.start.col;int e.loc.stop.line;int e.loc.stop.col;
    C.Seq (List.map (fun ((loc:Location.loc),text) -> C.Seq [atom (relative ~project_root loc.file);
      int loc.start.line;int loc.start.col;int loc.stop.line;int loc.stop.col;atom text]) e.related)]

let encode ~project_root t =
  let node = C.Seq [atom format;atom t.family;int t.version;atom t.compiler_abi;atom t.stored_value_compatibility;
    C.Seq (List.map (fun (version,digest) -> C.Seq [int version;atom digest]) t.chain);
    C.Seq (List.map (fun (identity,generation) -> C.Seq [atom identity;int generation]) t.prefix.generations);
    t.prefix.retained;
    C.Seq (match t.refusal with None -> [] | Some errors -> [C.Seq (List.map (encode_error ~project_root) errors)]);
    C.Seq (match t.records with None -> [] | Some (namespace,records) -> [atom namespace;Migration_records.encode records])] in
  format ^ "\n" ^ C.encode node ^ "\n"

let parse_node = C.parse

let decode ~project_root text =
  let fail () = invalid_arg "malformed migration checkpoint" in
  let header = format ^ "\n" in
  if List.exists (fun earlier -> String.starts_with ~prefix:(earlier ^ "\n") text) earlier_formats then raise Earlier_format;
  if not (String.starts_with ~prefix:header text && String.ends_with ~suffix:"\n" text) then fail ();
  let body = String.sub text (String.length header) (String.length text - String.length header - 1) in
  let str = function C.Bytes s -> s | C.Seq _ -> fail () in
  let num n = match int_of_string_opt (str n) with Some n -> n | None -> fail () in
  let items = function C.Seq xs -> xs | C.Bytes _ -> fail () in
  let location file sl sc el ec = Location.make_loc (absolute ~project_root (str file)) (num sl) (num sc) (num el) (num ec) in
  let error = function
    | C.Seq [code;message;file;sl;sc;el;ec;related] ->
      {S.code=str code;message=str message;loc=location file sl sc el ec;
       related=List.map (function C.Seq [file;sl;sc;el;ec;text] -> location file sl sc el ec,str text | _ -> fail ()) (items related)}
    | _ -> fail () in
  match parse_node body with
  | C.Seq [C.Bytes tag;family;version;abi;stored;chain;generations;retained;refusal;records] when tag=format ->
    let version = num version in
    {family=str family;version;compiler_abi=str abi;stored_value_compatibility=str stored;
     chain=List.map (function C.Seq [v;d] -> num v,str d | _ -> fail ()) (items chain);
     prefix={RH.through=version;retained;
       generations=List.map (function C.Seq [i;g] -> str i,num g | _ -> fail ()) (items generations)};
     refusal=(match items refusal with [] -> None | [errors] -> Some (List.map error (items errors)) | _ -> fail ());
     records=(match items records with [] -> None | [namespace;records] -> Some (str namespace,Migration_records.decode records) | _ -> fail ())}
  | _ -> fail ()

(* The checkpoint text for version [through] of a checked history: [rows] is a
   fold from V1 or a resumption of an earlier checkpoint, [plan] its retained
   storage, [prior_refusal] the refusal carried by that earlier checkpoint.
   None when the prefix through [through] uses a feature no checkpoint carries. *)
let text ~project_root ~family ~compiler_abi ~stored_value_compatibility ~chain ~rows ~plan ?prior_refusal ?records ~through () =
  match RS.prefix_state plan ~through with
  | None -> None
  | Some retained ->
    match RH.prefix_state rows ~through ~retained with
    | None -> None
    | Some prefix ->
      let refusal = match prior_refusal with
        | Some (Some errors) -> Some errors
        | _ -> Migration_expansion.refusal ~edges:(List.filter (fun d -> D.version d<=through) (RH.declarations rows)) in
      let chain = List.filter (fun (version,_) -> version<=through) chain in
      if List.map fst chain <> List.init (through-1) (fun i -> i+2) then None
      else Some (encode ~project_root {family;version=through;compiler_abi;stored_value_compatibility;chain;prefix;refusal;records})

(* Root digest recorded in each completed migration's frozen-source block. *)
let chain ~project_root:_ (completed : H.migration_source list) =
  List.filter_map (fun (m:H.migration_source) ->
    match Migration_closure.read ~file:m.path m.contents with
    | Ok (Some located) ->
      Option.map (fun digest -> m.version,digest) (List.assoc_opt (Migration_closure.root located) (Migration_closure.sources located))
    | _ -> None) completed

type usable = { checkpoint : t; through : int }

(* The checkpoint of the newest completed migration at or below [through]
   (default: the newest), when every completed migration up to it is trusted
   and the checkpoint matches this compiler. A recorded checkpoint whose bytes
   differ from its digest is refused with MIG013. *)
(* The recorded checkpoint of completed migration [m], whose history chain
   through [m] is [expected_chain] (see [chain]). None when [m]
   records none, it was written by another compiler, or by an earlier format;
   MIG013 when its bytes differ from the recorded digest or it belongs to
   another history. *)
let read_recorded ~root ~family ~abi ~stored ~expected_chain (m : H.migration_source) =
  match Migration_closure.read ~file:m.path m.contents with
  | Ok (Some located) ->
    (match Migration_closure.checkpoint located with
     | None -> None
     | Some digest ->
       let file = Migration_closure.checkpoint_file m.path in
       let bytes = try Source_input.read file with Sys_error _ | Unix.Unix_error _ ->
         reject file "a recorded migration checkpoint is missing; restore it from version control" in
       if Migration_hash.digest bytes <> digest then
         reject file "recorded migration checkpoint changed; restore it, or run the full-history check to find which bytes differ";
       match decode ~project_root:root bytes with
       | exception Earlier_format -> None
       | exception Invalid_argument message -> reject file message
       | checkpoint ->
         if checkpoint.compiler_abi<>abi || checkpoint.stored_value_compatibility<>stored then None
         else if checkpoint.family<>family || checkpoint.version<>m.version ||
                 checkpoint.chain<>expected_chain then
           reject file "migration checkpoint belongs to another history; restore the checkpoint written with this revision"
         else Some checkpoint)
  | _ -> None

let load ?through ~project_root ~family (completed : H.migration_source list) =
  if Migration_trust.full_history () then None else
  let completed = match through with
    | None -> completed
    | Some limit -> List.filter (fun (m:H.migration_source) -> m.version<=limit) completed in
  match List.rev completed, Migration_trust.current_compiler () with
  | [],_ | _,None -> None
  | newest::_,(Some (abi,stored) as compiler) ->
    let root = Source_input.realpath project_root in
    let trusted (m:H.migration_source) =
      Migration_trust.edge ~project_root:root ~compiler ~file:m.path ~source:m.contents <> None in
    if not (List.for_all trusted completed) then None else
    Option.map (fun checkpoint -> {checkpoint;through=newest.version})
      (read_recorded ~root ~family ~abi ~stored ~expected_chain:(chain ~project_root:root completed) newest)

(* The published records of every revision through [usable], read from the
   checkpoint of each completed migration up to it. None unless every one of
   them recorded its records for [namespace]; the caller then folds from V1.
   The completed migrations were verified trusted by [load]. *)
let load_records ~project_root ~family ~namespace (completed : H.migration_source list) (usable : usable) =
  match Migration_trust.current_compiler () with
  | None -> None
  | Some (abi,stored) ->
    let root = Source_input.realpath project_root in
    let completed = List.filter (fun (m:H.migration_source) -> m.version<=usable.through) completed in
    (* The newest checkpoint's chain covers every earlier one. *)
    let chain = usable.checkpoint.chain in
    let rec gather acc = function
      | [] -> Some (List.rev acc)
      | (m:H.migration_source)::rest ->
        let checkpoint = if m.version=usable.through then Some usable.checkpoint
          else read_recorded ~root ~family ~abi ~stored
              ~expected_chain:(List.filter (fun (version,_) -> version<=m.version) chain) m in
        match Option.bind checkpoint (fun (c:t) -> c.records) with
        | Some (recorded,records) when recorded=namespace -> gather (records :: acc) rest
        | _ -> None in
    if List.map (fun (m:H.migration_source) -> m.version) completed <> List.init (usable.through-1) (fun i -> i+2) then None
    else Option.map Migration_records.concat (gather [] completed)

(* Records Start stores for the revisions checkpoint V<through> completes,
   when they are recordable and every revision among them passes the Contract
   prerequisite a resumed build no longer re-checks. [contract] checks one
   Contract source against [plan]; [queue_versions] covers those revisions. *)
let records_for ~family ~namespace ~through ~rows ~plan ~contracts ~queue_versions =
  let low = if through=2 then 1 else through in
  if not (Migration_records.storable ~low ~high:through rows) then None else
  if Migration_records.prerequisites ~family ~namespace ~low ~high:through plan (List.map snd contracts) <> [] then None else
  let contracts = List.map fst contracts in
  let versions=List.filter_map (fun (q:Migration_records.queue_version) -> if q.version>=low && q.version<=through then Some q.version else None) queue_versions in
  if versions<>List.init (through-low+1) (fun i -> low+i) then None else
  Some (namespace,Migration_records.of_history ~family ~namespace ~low ~high:through ~rows ~plan ~contracts ~queue_versions)

(* Full-history check: every recorded checkpoint whose compiler matches this one
   must equal the checkpoint recomputed from the complete fold. Its records are
   compared when they were recorded for the namespace this build checks. *)
let verify_all ~project_root ~family ~compiler_abi ~stored_value_compatibility ~rows ~plan
    ?records:(records:(string * (int -> (string * Migration_records.t) option)) option)
    (completed : H.migration_source list) =
  let root = Source_input.realpath project_root in
  let chain = chain ~project_root:root completed in
  List.iter (fun (m:H.migration_source) ->
    match Migration_closure.read ~file:m.path m.contents with
    | Ok (Some located) ->
      Option.iter (fun _ ->
        let file = Migration_closure.checkpoint_file m.path in
        let bytes = Source_input.read file in
        let recorded = try `Recorded (decode ~project_root:root bytes) with
          | Earlier_format -> `Earlier | Invalid_argument _ -> `Malformed in
        match recorded with
        | `Earlier -> ()
        | `Recorded recorded when recorded.compiler_abi<>compiler_abi || recorded.stored_value_compatibility<>stored_value_compatibility -> ()
        | recorded ->
          (* Records computed for another application namespace cannot be
             recomputed by this build; the state they accompany still is. *)
          let records = match recorded,records with
            | `Recorded {records=Some (namespace,_);_},Some (checked,derive) when namespace=checked -> derive m.version
            | `Recorded {records=Some other;_},_ -> Some other
            | _ -> None in
          let expected = text ~project_root:root ~family ~compiler_abi ~stored_value_compatibility ~chain ~rows ~plan ?records ~through:m.version () in
          if expected <> Some bytes then
            reject file (Printf.sprintf "migration checkpoint v%d differs from the full-history recomputation; regenerate it from the revision's source" m.version))
        (Migration_closure.checkpoint located)
    | _ -> ()) completed

let protect f = try Ok (f ()) with Invalid errors -> Error errors

(* Checked row history through [through] in the active source view, resumed
   from the previous revision's checkpoint when usable. *)
let declaration ?stored_value_compatibility ~compiler_abi (m:H.migration_source) =
  match Parser.parse_module m.path m.contents with
  | Parser.Err e -> raise (Invalid [{S.code="MIG020";loc=e.loc;message=e.msg;related=[]}])
  | Parser.Ok ast -> match D.check ?stored_value_compatibility ~compiler_abi ~source:m.contents ast with
    | Ok (Some edge) -> edge
    | Ok None -> reject m.path "migration declaration missing from history"
    | Error errors -> raise (Invalid errors)

(* [gap] (default 1) is how many revisions before [through] the checkpoint may
   be at most: 2 keeps revision [through-1] in the resumed plan, so its Contract
   can be checked against it. *)
let resumed ?stored_value_compatibility ?(gap=1) ~compiler_abi ~project_root ~family h ~through =
  let completed = List.filter (fun (m:H.migration_source) -> m.version<=through) (H.completed_migrations h) in
  let edge version = match List.find_opt (fun (m:H.migration_source) -> m.version=version)
      (completed @ Option.to_list (H.current_migration h)) with
    | Some m -> declaration ?stored_value_compatibility ~compiler_abi m
    | None -> reject project_root (Printf.sprintf "missing migration V%d" version) in
  let schema version = match List.find_opt (fun (s:H.schema) -> s.version=version) (H.frozen h @ [H.current h]) with
    | Some s -> H.inventory s | None -> reject project_root (Printf.sprintf "missing schema V%d" version) in
  match load ~through:(through-gap) ~project_root ~family completed with
  | None -> None
  | Some usable ->
    let k = usable.through in
    let schemas = List.init (through-k+1) (fun i -> schema (k+i)) in
    let edges = List.init (through-k) (fun i -> edge (k+i+1)) in
    Option.map (fun rows -> usable,rows) (RH.resume ~prefix:usable.checkpoint.prefix ~schemas ~edges)

let derive ?stored_value_compatibility ?namespace ?check_contract ~compiler_abi ~project_root ~family ~through () =
  try
    let h = match H.discover_with_compatibility ~stored_value_compatibility ~compiler_abi ~project_root ~family with
      | Ok h -> h | Error e -> reject e.loc.file e.message in
    let root = Source_input.realpath project_root in
    let completed = List.filter (fun (m:H.migration_source) -> m.version<=through) (H.completed_migrations h) in
    let rows,prior_refusal = match resumed ?stored_value_compatibility ~gap:2 ~compiler_abi ~project_root ~family h ~through with
      | Some (usable,rows) -> rows,Some usable.checkpoint.refusal
      | None ->
        let schemas = List.filter (fun (s:H.schema) -> s.version<=through) (H.frozen h @ [H.current h])
          |> List.map H.inventory in
        let edges = List.map (declaration ?stored_value_compatibility ~compiler_abi) completed in
        (match RH.check ~schemas ~edges with Ok rows -> rows | Error errors -> raise (Invalid errors)),None in
    let plan = match RS.plan rows with Ok plan -> plan | Error errors -> raise (Invalid errors) in
    (* Records need the application namespace and every input a later build
       would publish them from; any failure only omits them. *)
    let records = match namespace,check_contract with
      | None,_ | _,None -> None
      | Some namespace,Some check_contract ->
      try
        let low = if through=2 then 1 else through in
        let contracts = H.contracts h |> List.filter_map (fun (s:H.migration_source) ->
          if s.version>=low-1 && s.version<=through then
            match check_contract ~plan ~namespace ~file:s.path ~source:s.contents with
            | Ok c -> Some c | Error errors -> raise (Invalid errors)
          else None) in
        let schemas = List.filter (fun (s:H.schema) -> s.version>=low && s.version<=through) (H.frozen h @ [H.current h]) in
        let next = List.filter (fun (m:H.migration_source) -> m.version=through+1)
            (H.completed_migrations h @ Option.to_list (H.current_migration h))
          |> List.map (declaration ?stored_value_compatibility ~compiler_abi) in
        let edges = List.filter (fun d -> D.version d>=low) (RH.declarations rows) @ next in
        let queue_versions = Migration_records.queue_versions schemas edges in
        records_for ~family ~namespace ~through ~rows ~plan ~contracts ~queue_versions
      with Invalid _ | Migration_records.Storage_invalid _ -> None in
    match Migration_trust.current_compiler () with
    | None -> None
    | Some (abi,stored) ->
      text ~project_root:root ~family ~compiler_abi:abi ~stored_value_compatibility:stored
        ~chain:(chain ~project_root:root completed) ~rows ~plan ?prior_refusal ?records ~through ()
  with Invalid _ | Sys_error _ | Unix.Unix_error _ | Invalid_argument _ | Failure _ | Not_found -> None

let recorded (completed : H.migration_source list) =
  List.exists (fun (m:H.migration_source) -> match Migration_closure.read ~file:m.path m.contents with
    | Ok (Some located) -> Migration_closure.checkpoint located <> None
    | _ -> false) completed
