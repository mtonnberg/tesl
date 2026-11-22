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
}

let format = "tesl-migration-checkpoint-v1"
exception Invalid of S.error list
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
    C.Seq (match t.refusal with None -> [] | Some errors -> [C.Seq (List.map (encode_error ~project_root) errors)])] in
  format ^ "\n" ^ C.encode node ^ "\n"

(* Inverse of Migration_canonical.encode. *)
let parse_node text =
  let length = String.length text in
  let fail () = invalid_arg "malformed checkpoint encoding" in
  let rec number position acc =
    if position >= length then fail () else
    match text.[position] with
    | '0'..'9' as c when acc < 1 lsl 40 -> number (position+1) (acc*10 + Char.code c - 48)
    | ':' -> acc,position+1
    | _ -> fail () in
  let rec node position =
    if position >= length then fail () else
    match text.[position] with
    | 's' ->
      let size,start = number (position+1) 0 in
      if start+size > length then fail ();
      C.Bytes (String.sub text start size),start+size
    | 'l' ->
      let count,start = number (position+1) 0 in
      let rec children n position acc =
        if n=0 then C.Seq (List.rev acc),position else
        let child,next = node position in children (n-1) next (child::acc) in
      children count start []
    | _ -> fail () in
  let root,stop = node 0 in
  if stop<>length then fail ();
  root

let decode ~project_root text =
  let fail () = invalid_arg "malformed migration checkpoint" in
  let header = format ^ "\n" in
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
  | C.Seq [C.Bytes tag;family;version;abi;stored;chain;generations;retained;refusal] when tag=format ->
    let version = num version in
    {family=str family;version;compiler_abi=str abi;stored_value_compatibility=str stored;
     chain=List.map (function C.Seq [v;d] -> num v,str d | _ -> fail ()) (items chain);
     prefix={RH.through=version;retained;
       generations=List.map (function C.Seq [i;g] -> str i,num g | _ -> fail ()) (items generations)};
     refusal=(match items refusal with [] -> None | [errors] -> Some (List.map error (items errors)) | _ -> fail ())}
  | _ -> fail ()

(* The checkpoint text for version [through] of a checked history: [rows] is a
   fold from V1 or a resumption of an earlier checkpoint, [plan] its retained
   storage, [prior_refusal] the refusal carried by that earlier checkpoint.
   None when the prefix through [through] uses a feature no checkpoint carries. *)
let text ~project_root ~family ~compiler_abi ~stored_value_compatibility ~chain ~rows ~plan ?prior_refusal ~through () =
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
      else Some (encode ~project_root {family;version=through;compiler_abi;stored_value_compatibility;chain;prefix;refusal})

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
    match Migration_closure.read ~file:newest.path newest.contents with
    | Ok (Some located) ->
      (match Migration_closure.checkpoint located with
       | None -> None
       | Some digest ->
         let file = Migration_closure.checkpoint_file newest.path in
         let bytes = try Source_input.read file with Sys_error _ | Unix.Unix_error _ ->
           reject file "a recorded migration checkpoint is missing; restore it from version control" in
         if Migration_hash.digest bytes <> digest then
           reject file "recorded migration checkpoint changed; restore it, or run the full-history check to find which bytes differ";
         let checkpoint = try decode ~project_root:root bytes with Invalid_argument message -> reject file message in
         if checkpoint.compiler_abi<>abi || checkpoint.stored_value_compatibility<>stored then None
         else if checkpoint.family<>family || checkpoint.version<>newest.version ||
                 checkpoint.chain<>chain ~project_root:root completed then
           reject file "migration checkpoint belongs to another history; restore the checkpoint written with this revision"
         else Some {checkpoint;through=newest.version})
    | _ -> None

(* Full-history check: every recorded checkpoint whose compiler matches this one
   must equal the checkpoint recomputed from the complete fold. *)
let verify_all ~project_root ~family ~compiler_abi ~stored_value_compatibility ~rows ~plan
    (completed : H.migration_source list) =
  let root = Source_input.realpath project_root in
  let chain = chain ~project_root:root completed in
  List.iter (fun (m:H.migration_source) ->
    match Migration_closure.read ~file:m.path m.contents with
    | Ok (Some located) ->
      Option.iter (fun _ ->
        let file = Migration_closure.checkpoint_file m.path in
        let bytes = Source_input.read file in
        let recorded = try Some (decode ~project_root:root bytes) with Invalid_argument _ -> None in
        match recorded with
        | Some recorded when recorded.compiler_abi<>compiler_abi || recorded.stored_value_compatibility<>stored_value_compatibility -> ()
        | _ ->
          let expected = text ~project_root:root ~family ~compiler_abi ~stored_value_compatibility ~chain ~rows ~plan ~through:m.version () in
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

let resumed ?stored_value_compatibility ~compiler_abi ~project_root ~family h ~through =
  let completed = List.filter (fun (m:H.migration_source) -> m.version<=through) (H.completed_migrations h) in
  let edge version = match List.find_opt (fun (m:H.migration_source) -> m.version=version)
      (completed @ Option.to_list (H.current_migration h)) with
    | Some m -> declaration ?stored_value_compatibility ~compiler_abi m
    | None -> reject project_root (Printf.sprintf "missing migration V%d" version) in
  let schema version = match List.find_opt (fun (s:H.schema) -> s.version=version) (H.frozen h @ [H.current h]) with
    | Some s -> H.inventory s | None -> reject project_root (Printf.sprintf "missing schema V%d" version) in
  match load ~through:(through-1) ~project_root ~family completed with
  | None -> None
  | Some usable ->
    let k = usable.through in
    let schemas = List.init (through-k+1) (fun i -> schema (k+i)) in
    let edges = List.init (through-k) (fun i -> edge (k+i+1)) in
    Option.map (fun rows -> usable,rows) (RH.resume ~prefix:usable.checkpoint.prefix ~schemas ~edges)

let derive ?stored_value_compatibility ~compiler_abi ~project_root ~family ~through () =
  try
    let h = match H.discover_with_compatibility ~stored_value_compatibility ~compiler_abi ~project_root ~family with
      | Ok h -> h | Error e -> reject e.loc.file e.message in
    let root = Source_input.realpath project_root in
    let completed = List.filter (fun (m:H.migration_source) -> m.version<=through) (H.completed_migrations h) in
    let rows,prior_refusal = match resumed ?stored_value_compatibility ~compiler_abi ~project_root ~family h ~through with
      | Some (usable,rows) -> rows,Some usable.checkpoint.refusal
      | None ->
        let schemas = List.filter (fun (s:H.schema) -> s.version<=through) (H.frozen h @ [H.current h])
          |> List.map H.inventory in
        let edges = List.map (declaration ?stored_value_compatibility ~compiler_abi) completed in
        (match RH.check ~schemas ~edges with Ok rows -> rows | Error errors -> raise (Invalid errors)),None in
    let plan = match RS.plan rows with Ok plan -> plan | Error errors -> raise (Invalid errors) in
    match Migration_trust.current_compiler () with
    | None -> None
    | Some (abi,stored) ->
      text ~project_root:root ~family ~compiler_abi:abi ~stored_value_compatibility:stored
        ~chain:(chain ~project_root:root completed) ~rows ~plan ?prior_refusal ~through ()
  with Invalid _ | Sys_error _ | Unix.Unix_error _ | Invalid_argument _ | Failure _ | Not_found -> None

let recorded (completed : H.migration_source list) =
  List.exists (fun (m:H.migration_source) -> match Migration_closure.read ~file:m.path m.contents with
    | Ok (Some located) -> Migration_closure.checkpoint located <> None
    | _ -> false) completed
