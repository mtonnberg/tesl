(* Sealed summary of a schema family's frozen history.

   When Start freezes revision V<n>, the checkpoint it writes for V<n>
   (Migration_checkpoint) also records:
   - one digest over the family's schema and migrations trees through V<n>
     ([walk] below): the frozen-history digest of a source manifest's history
     entry (Migration_manifest), in a variant that hashes every migration root
     (migrations/<family>/v<k>.tesl) without its frozen-source block and
     records every checkpoint's presence only.
     A frozen-source block holds the digest of its revision's checkpoint, and
     a checkpoint holds this digest, so neither can be inside it; the block and
     the checkpoint bytes are verified by whoever reads them (the checkpoint
     against the block, Migration_checkpoint.read_recorded; the chain of root
     digests the blocks record, Migration_checkpoint.load). Left out entirely:
     every entry of V<n+1> or later and VCurrent (as a manifest scope keeps the
     current revision's), and V<n>'s checkpoint;
   - the discovery facts of every frozen module that digest covers: its path,
     the SHA-256 of its bytes without a frozen-source block (the key its parse
     facts are recorded under, Migration_module_facts), its declared name and
     its imports;
   - the completed revisions through V<n> whose trust seals held then under the
     compiler ABI and stored-value contract the checkpoint records
     (Migration_trust.seals_hold: a function of those bytes, the ABI and the
     stored-value contract alone, whatever the full-history setting).

   A later command finds the newest checkpoint, checks its bytes against the
   digest in its revision's frozen-source block, checks that it was written by
   the running compiler ABI and stored-value contract, and walks and hashes the
   two trees once in the active source view. When the digest is equal, every
   source, name and kind the summary describes is unchanged, so the facts it
   records are what discovery, trust and parsing would compute again; they are
   used instead (Migration_history_sources, Migration_trust). Anything else
   (another digest, a newer frozen revision without a checkpoint, another
   compiler, a symbolic link in a tree, a tree parent that could hide an import
   candidate) leaves the summary unused and every revision is checked as
   before. Under --full-history the summary is never used; the full-history
   check recomputes the newest summary and refuses one whose facts differ
   while its digest is equal (MIG013, Migration_checkpoint.verify_summary).

   A verified summary is remembered for one compilation scope and source view,
   while disk answers are memoized; final guards observe disk anew. *)
module C = Migration_canonical
module F = Migration_module_facts

type entry = { path : string; key : string; facts : F.t }
type t = {
  family : string;
  through : int;
  compiler_abi : string;
  stored_value_compatibility : string;
  digest : string;
  sealed : int list;
  entries : entry list;
  by_path : (string, entry) Hashtbl.t;
  (* From the walk that verified it: each hashed file's SHA-256 (of all its
     bytes), and the project root and migrations directory. *)
  files : (string, string) Hashtbl.t;
  location : string * string;
}
let format = "tesl-history-summary-v1"
let through t = t.through
let family t = t.family
let digest t = t.digest
let sealed t = t.sealed
let compiler t = t.compiler_abi, t.stored_value_compatibility
(* The SHA-256 of a covered module's bytes, as this summary's walk read them. *)
let covers t path = if Hashtbl.mem t.by_path path then Hashtbl.find_opt t.files path else None
let facts t path = Option.map (fun (e:entry) -> e.facts) (Hashtbl.find_opt t.by_path path)
let file_digest t path = Hashtbl.find_opt t.files path

let relative ~project_root file =
  let prefix = project_root ^ Filename.dir_sep in
  if String.starts_with ~prefix file then
    "./" ^ String.sub file (String.length prefix) (String.length file - String.length prefix)
  else file
let absolute ~project_root file =
  if String.starts_with ~prefix:"./" file then Filename.concat project_root (String.sub file 2 (String.length file - 2))
  else file
let tree_relative root path =
  let prefix = if Filename.dirname root = root then root else root ^ Filename.dir_sep in
  let rel = if path = root then "" else String.sub path (String.length prefix) (String.length path - String.length prefix) in
  if Sys.win32 then String.map (function '\\' -> '/' | c -> c) rel else rel

let tree ~project_root ~family name =
  match Validation_common.schema_module_relative_path (family ^ name) with
  | Some relative -> Some (Filename.dirname (Filename.concat project_root relative))
  | None -> None
let migrations_dir ~project_root ~family = tree ~project_root ~family ".Migrate.V2"

(* The trees and what the digest leaves out: every entry of revision
   V<through+1> or later, VCurrent, and V<through>'s checkpoint. A revision's
   entries are named by their first component below a tree: v<k>.tesl, a v<k>
   directory, and in the migrations tree v<k>-contract.tesl and
   v<k>.checkpoint. *)
let scope ~project_root ~family ~through =
  let get name = match tree ~project_root ~family name with
    | Some tree -> tree | None -> invalid_arg ("not a schema family: " ^ family) in
  let schema = get ".VCurrent" and migrations = get ".Migrate.V2" in
  let checkpoint = Filename.concat migrations (Printf.sprintf "v%d.checkpoint" through) in
  let first tree path =
    let prefix = tree ^ Filename.dir_sep in
    if not (String.starts_with ~prefix path) then None else
    let rest = String.sub path (String.length prefix) (String.length path - String.length prefix) in
    Some (match String.index_opt rest Filename.dir_sep.[0] with Some i -> String.sub rest 0 i | None -> rest) in
  let version name =
    let stem = List.fold_left (fun name suffix ->
      if Filename.check_suffix name suffix then Filename.chop_suffix name suffix else name) name [".tesl";".checkpoint"] in
    let stem = if Filename.check_suffix stem "-contract" then Filename.chop_suffix stem "-contract" else stem in
    let digits = if String.length stem > 1 && stem.[0] = 'v' then String.sub stem 1 (String.length stem - 1) else "" in
    if digits <> "" && String.length digits <= 9 && String.for_all (function '0'..'9' -> true | _ -> false) digits
    then int_of_string_opt digits else None in
  let later name = match version name with Some k -> k > through | None -> false in
  let exclude path =
    path = checkpoint ||
    (match first schema path with
     | Some name -> name = "v-current.tesl" || name = "v-current" || later name
     | None -> match first migrations path with Some name -> later name | None -> false) in
  let root path = Filename.dirname path = migrations &&
    (match version (Filename.basename path) with
     | Some _ -> Filename.check_suffix path ".tesl" && not (Filename.check_suffix path "-contract.tesl")
     | None -> false) in
  List.sort String.compare [schema;migrations], exclude, root

(* One walk of the trees in the active source view: the digest, each hashed
   file's SHA-256 of all its bytes, and of the bytes it is summarized by (a
   migration root's without its frozen-source block, [root]). None when an entry is not a regular file or directory, or a tree's
   parent lists "schema" or "migrations" (an import from inside the trees could
   then resolve elsewhere; as for a manifest scope). *)
exception Unobservable
let walk ~project_root ~trees ~exclude ~root =
  let shadowed = List.exists (fun tree ->
    match Source_input.readdir (Filename.dirname tree) with
    | names -> Array.exists (fun name -> name = "schema" || name = "migrations") names
    | exception (Sys_error _ | Unix.Unix_error _) -> false) trees in
  if shadowed then None else
  let full = Hashtbl.create 256 and stripped = Hashtbl.create 256 in
  let kind path = match Source_input.kind path with
    | kind -> Some kind
    | exception Unix.Unix_error (Unix.ENOENT,_,_) -> None in
  try
    let lines = List.concat_map (fun tree ->
      let header = "tree\000" ^ tree_relative project_root tree in
      match kind tree with
      | None -> [header;"absent";"end"]
      | Some Unix.S_DIR ->
        let entries = ref [] in
        let rec visit directory =
          Array.iter (fun name ->
            let path = Filename.concat directory name in
            if not (exclude path) then begin
              let rel = tree_relative project_root path in
              match kind path with
              | Some Unix.S_DIR -> entries := (rel,"d\000" ^ rel) :: !entries; visit path
              | Some Unix.S_REG when Filename.check_suffix name ".checkpoint" ->
                entries := (rel,"c\000" ^ rel) :: !entries
              | Some Unix.S_REG ->
                let bytes = Source_input.read path in
                let digest = Migration_hash.digest bytes in
                let key = if not (root path) then digest else
                  match Migration_closure.without_block ~file:path bytes with
                  | Some body when String.length body <> String.length bytes -> Migration_hash.digest body
                  | _ -> digest in
                Hashtbl.replace full path digest; Hashtbl.replace stripped path key;
                entries := (rel,"f\000" ^ rel ^ "\000" ^ key) :: !entries
              | _ -> raise Unobservable
            end) (Source_input.readdir directory) in
        visit tree;
        header :: List.map snd (List.sort (fun (a,_) (b,_) -> String.compare a b) !entries) @ ["end"]
      | Some _ -> raise Unobservable) trees in
    let digest = Migration_hash.digest ("tesl-frozen-history-summary-v1\000" ^ String.concat "" (List.map (fun line -> line ^ "\000") lines)) in
    Some (digest,full,stripped)
  with Unobservable | Unix.Unix_error _ | Sys_error _ -> None

let fail () = invalid_arg "malformed history summary"
let str = function C.Bytes s -> s | C.Seq _ -> fail ()
let num n = match int_of_string_opt (str n) with Some n -> n | None -> fail ()
let items = function C.Seq xs -> xs | C.Bytes _ -> fail ()

let encode ~project_root t =
  let atom s = C.Bytes s in
  C.Seq [atom format; atom t.family; atom (string_of_int t.through); atom t.compiler_abi;
    atom t.stored_value_compatibility; atom t.digest;
    C.Seq (List.map (fun v -> atom (string_of_int v)) t.sealed);
    C.Seq (List.map (fun (e:entry) -> C.Seq [atom (relative ~project_root e.path); atom e.key;
      atom e.facts.F.module_name; C.Seq (List.map atom e.facts.F.imports)]) t.entries)]

let decode ~project_root node =
  match node with
  | C.Seq [C.Bytes tag;family;through;abi;stored;digest;sealed;entries] when tag = format ->
    let entries = List.map (function
      | C.Seq [path;key;name;imports] ->
        {path=absolute ~project_root (str path);key=str key;
         facts={F.module_name=str name;imports=List.map str (items imports)}}
      | _ -> fail ()) (items entries) in
    let by_path = Hashtbl.create (List.length entries) in
    List.iter (fun (e:entry) -> Hashtbl.replace by_path e.path e) entries;
    {family=str family;through=num through;compiler_abi=str abi;stored_value_compatibility=str stored;
     digest=str digest;sealed=List.map num (items sealed);entries;by_path;files=Hashtbl.create 1;location=("","")}
  | _ -> fail ()

(* The summary through [through] in the active source view: [modules] are the
   modules discovery read, with their parse facts; [sealed] the completed
   revisions whose seals hold. None when the trees cannot be summarized. *)
let compute ~project_root ~family ~through ~compiler_abi ~stored_value_compatibility ~modules ~sealed =
  let trees,exclude,root = scope ~project_root ~family ~through in
  match walk ~project_root ~trees ~exclude ~root with
  | None -> None
  | Some (digest,_,stripped) ->
    let entries = List.filter_map (fun (path,facts) ->
      Option.map (fun key -> {path;key;facts}) (Hashtbl.find_opt stripped path)) modules
      |> List.sort_uniq (fun (a:entry) b -> compare a.path b.path) in
    Some (encode ~project_root {family;through;compiler_abi;stored_value_compatibility;digest;
      sealed=List.sort_uniq compare sealed;entries;by_path=Hashtbl.create 1;files=Hashtbl.create 1;location=("","")})

(* "v<N>.checkpoint" *)
let checkpoint_version name =
  let n = String.length name in
  if n > 12 && name.[0] = 'v' && Filename.check_suffix name ".checkpoint" then
    let digits = String.sub name 1 (n - 12) in
    if digits.[0] <> '0' && String.length digits <= 9 && String.for_all (function '0'..'9' -> true | _ -> false) digits
    then Some (int_of_string digits) else None
  else None

(* The summary of a checkpoint's text: its section follows the format line and
   the module facts section. *)
let of_checkpoint ~project_root text =
  let header = F.checkpoint_format ^ "\n" in
  if not (String.starts_with ~prefix:header text) then None else
  match C.parse_at text ~from:(String.length header) with
  | exception Invalid_argument _ -> None
  | _,facts_end ->
    if facts_end >= String.length text || text.[facts_end] <> '\n' then None else
    match C.parse_at text ~from:(facts_end+1) with
    | exception Invalid_argument _ -> None
    | node,_ -> (try Some (decode ~project_root node) with Invalid_argument _ -> None)

let verify ~project_root ~dir =
  match Migration_abi.current () with
  | Error _ -> None
  | Ok abi ->
  let newest = Array.fold_left (fun newest name -> match checkpoint_version name, newest with
    | Some n, Some m when n <= m -> newest | Some n, _ -> Some n | None, _ -> newest) None (Source_input.readdir dir) in
  match newest with
  | None -> None
  | Some n ->
    let root = Filename.concat dir (Printf.sprintf "v%d.tesl" n) in
    let checkpoint = Filename.concat dir (Printf.sprintf "v%d.checkpoint" n) in
    match Migration_closure.read ~file:root (Source_input.read root) with
    | Ok (Some located) ->
      (match Migration_closure.checkpoint located with
       | None -> None
       | Some recorded ->
         let text = Source_input.read checkpoint in
         if Migration_hash.digest text <> recorded then None else
         match of_checkpoint ~project_root text with
         | None -> None
         | Some s ->
           if s.through <> n || s.compiler_abi <> Migration_abi.id abi ||
              s.stored_value_compatibility <> Migration_abi.stored_value_compatibility abi ||
              migrations_dir ~project_root ~family:s.family <> Some dir then None else
           let trees,exclude,root = scope ~project_root ~family:s.family ~through:n in
           match walk ~project_root ~trees ~exclude ~root with
           | Some (digest,full,stripped) when digest = s.digest &&
               List.for_all (fun (e:entry) -> Hashtbl.find_opt stripped e.path = Some e.key) s.entries ->
             F.add ~compiler_abi:s.compiler_abi (List.map (fun (e:entry) -> e.key,e.facts) s.entries);
             Some {s with files=full;location=(project_root,dir)}
           | _ -> None)
    | _ -> None

(* Verified summaries of this compilation scope. The verification is memoized
   per source view through Source_input.memo_in_view: a judgment recording its
   observations sees the walk's, and another view reuses the answer only when
   every observation still holds there. *)
let verified : (string, t) Hashtbl.t = Hashtbl.create 4
let () = Source_input.on_scope_exit (fun () -> Hashtbl.reset verified)
let find_dir ~project_root ~dir =
  if !F.disabled () || not (Source_input.memoizing ()) then None else
  (* A judgment recording its observations does not take the walk's: one that
     used this summary checks it again where it is reused
     (Migration_history_sources.inspect); Migration_trust asks it anew. *)
  let answer = Source_input.unrecorded @@ fun () -> Source_input.memo_in_view ("tesl-history-summary\000" ^ project_root ^ "\000" ^ dir) (fun () ->
    match (try verify ~project_root ~dir with
      | Sys_error _ | Unix.Unix_error _ | Invalid_argument _ | Failure _ | Not_found -> None) with
    | None -> ""
    | Some s ->
      (* One verification per id: its file digests belong to the view it walked. *)
      let id = string_of_int (Hashtbl.length verified + 1) in
      Hashtbl.replace verified id s;
      id) in
  if answer = "" then None else Hashtbl.find_opt verified answer
let find ~project_root ~family =
  match migrations_dir ~project_root ~family with
  | None -> None
  | Some dir -> match find_dir ~project_root ~dir with
    | Some s when s.family = family -> Some s
    | _ -> None
(* The summary verifying in the active view in place of [t] (the same
   revision and digest), whose file digests are those of this view. *)
let current t =
  let project_root,dir = t.location in
  if dir = "" then None else
  match find_dir ~project_root ~dir with
  | Some s when s == t || (s.digest = t.digest && s.through = t.through && s.family = t.family) -> Some s
  | _ -> None

(* The module of completed revision [file] (V<k>, k at most the summary's
   revision) with exactly [source], when its seals held under this compiler
   when the summary was recorded. *)
let sealed_edge ~project_root ~compiler:(abi,stored) ~file ~source =
  match find_dir ~project_root ~dir:(Filename.dirname file) with
  | Some s when s.compiler_abi = abi && s.stored_value_compatibility = stored ->
    let name = Filename.basename file in
    let version = if String.length name > 6 && name.[0] = 'v' && Filename.check_suffix name ".tesl"
      then int_of_string_opt (String.sub name 1 (String.length name - 6)) else None in
    (match version, facts s file with
     | Some k, Some facts when k <= s.through && List.mem k s.sealed &&
         Hashtbl.find_opt s.files file = Some (Migration_hash.digest source) -> Some facts.F.module_name
     | _ -> None)
  | _ -> None
