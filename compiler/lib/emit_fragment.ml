(* The finished Go-emission output of one completed revision.

   Emitting an application compiles every module of its history and renders
   every revision's entries in the generated history documents, so a release's
   emit grew with the number of revisions. A completed revision's output never
   changes while its sources (fixed by its trust seals) and the emission's
   inputs stay the same. When Start freezes revision V<n>, it emits the
   proposed application once and stores V<n>'s finished output pieces in V<n>'s
   checkpoint (Migration_checkpoint); a later emit splices those pieces and
   compiles only the modules that are not covered by them.

   A fragment holds, for revision k:
   - [files]: every emitted file in the Go packages of revision k's modules
     (its schema snapshot V<k>, Migrate.V<k> and Migrate.V<k>Contract);
   - [runtime]: the embedded runtime files those modules required;
   - [rows]: revision k's declarations in the row-history registration file of
     each database, the imports they add and the Go names they took in the
     owning package;
   - [fixtures]: revision k's generated fixture tests;
   - [blocks]: revision k's entries in each generated history document, with
     the canonical-node table entries they introduced.

   [environment] digests every emission input that is not a source of the
   revision (compiler ABI, project path, debug/release mode, row storage and
   physical flags, document-wide shape flags, the database and its queues);
   [parameters] digests the per-module emission inputs of revision k's modules
   and their imports. A fragment is spliced only when both equal the digests
   the splicing emit computes, its revision's modules are present and are
   their own Go packages, and each recorded name choice replays to the same
   name; any difference makes the emit compile everything (Emit_go). Both
   digests are inside the checkpoint, whose SHA-256 is in the revision's
   sealed frozen-source block. A full-history emit recomputes every recorded
   fragment from the complete compilation and refuses a difference (MIG013). *)
module C = Migration_canonical

type rows = {
  database : string;
  go_var : string;
  declarations : string list;
  imports : (string * string) list;
  (* (requested, chosen) Go names, in the order the declarations took them. *)
  taken : (string * string) list;
}
type block = { document : string; database : string; entries : string list; nodes : string list }
type t = {
  revision : int;
  environment : string;
  parameters : string;
  files : (string * string) list;
  runtime : string list;
  rows : rows list;
  fixture_first : int;
  fixtures : string list;
  fixture_imports : (string * string) list;
  blocks : block list;
  (* The dependency markers its Go files reference (Emit_go rebuilds go.mod
     from the markers of every emitted file). *)
  markers : string list;
}

let atom s = C.Bytes s
let int n = atom (string_of_int n)
let strings xs = C.Seq (List.map atom xs)
let pairs xs = C.Seq (List.map (fun (a,b) -> C.Seq [atom a;atom b]) xs)

let encode t =
  C.Seq [int t.revision;atom t.environment;atom t.parameters;pairs t.files;strings t.runtime;
    C.Seq (List.map (fun (r:rows) -> C.Seq [atom r.database;atom r.go_var;strings r.declarations;pairs r.imports;pairs r.taken]) t.rows);
    int t.fixture_first;strings t.fixtures;pairs t.fixture_imports;
    C.Seq (List.map (fun (b:block) -> C.Seq [atom b.document;atom b.database;strings b.entries;strings b.nodes]) t.blocks);
    strings t.markers]

let decode node =
  let fail () = invalid_arg "malformed emitted revision fragment" in
  let str = function C.Bytes s -> s | C.Seq _ -> fail () in
  let num n = match int_of_string_opt (str n) with Some n -> n | None -> fail () in
  let items = function C.Seq xs -> xs | C.Bytes _ -> fail () in
  let strings n = List.map str (items n) in
  let pairs n = List.map (function C.Seq [a;b] -> str a,str b | _ -> fail ()) (items n) in
  match node with
  | C.Seq [revision;environment;parameters;files;runtime;rows;fixture_first;fixtures;fixture_imports;blocks;markers] ->
    {revision=num revision;environment=str environment;parameters=str parameters;files=pairs files;
     runtime=strings runtime;
     rows=List.map (function
       | C.Seq [database;go_var;declarations;imports;taken] ->
         {database=str database;go_var=str go_var;declarations=strings declarations;imports=pairs imports;taken=pairs taken}
       | _ -> fail ()) (items rows);
     fixture_first=num fixture_first;fixtures=strings fixtures;fixture_imports=pairs fixture_imports;
     blocks=List.map (function
       | C.Seq [document;database;entries;nodes] ->
         {document=str document;database=str database;entries=strings entries;nodes=strings nodes}
       | _ -> fail ()) (items blocks);
     markers=strings markers}
  | _ -> fail ()

(* A digest of already computed values: one SHA-256 over their length-prefixed
   concatenation. *)
let digest parts =
  Migration_hash.digest_parts (List.concat_map (fun part -> [string_of_int (String.length part);":";part]) parts)

(* The revision a module belongs to: schema snapshot V<k> (and its submodules),
   Migrate.V<k> and Migrate.V<k>Contract of [family]. Helpers and every other
   module belong to none and are always compiled. *)
let revision_of_module ~family name =
  let number text = if String.length text>1 && text.[0]='V' then
      int_of_string_opt (String.sub text 1 (String.length text-1)) else None in
  match Validation_common.schema_module_parts name with
  | Some (owner,revision,_) when owner=family && revision<>"Migrate" && revision<>"VCurrent" -> number revision
  | Some (owner,"Migrate",[step]) when owner=family ->
    let step = if String.ends_with ~suffix:"Contract" step then String.sub step 0 (String.length step-8) else step in
    (match number step with Some k when k>=2 -> Some k | _ -> None)
  | _ -> None

(* The emission of one document entry list. [spliced] gives the stored blocks
   of the covered revisions, in revision order; entries of later revisions are
   rendered, and the blocks of [recording] revisions are captured. *)
exception Mismatch of string
let mismatch message = raise (Mismatch message)

type context = {
  spliced : t list;
  recording : int list;
  (* Captured blocks, newest first. *)
  mutable captured : (int * block) list;
  (* Recording revisions whose entries could not be stored. *)
  mutable refused : int list;
}
let active : context option ref = ref None
let with_context context f =
  let saved = !active in
  active := Some context;
  Fun.protect ~finally:(fun () -> active := saved) f

(* [shape] turns a stored entry into the entry this emission renders, and
   [unshape] the reverse (None when the entry cannot be stored): a document may
   add fields to every entry that depend on later revisions. *)
let render_entries ?(shape=Fun.id) ?(unshape=Option.some) ~document ~database ~revision nodes render items =
  let spliced = match !active with None -> [] | Some c -> c.spliced in
  let covered = List.fold_left (fun acc f -> max acc f.revision) 0 spliced in
  let stored = List.concat_map (fun f ->
    match List.filter (fun b -> b.document=document && b.database=database) f.blocks with
    | [b] -> List.iter (Migration_canonical_nodes.preload nodes) b.nodes; List.map shape b.entries
    | [] -> mismatch ("revision fragment lacks its " ^ document ^ " block")
    | _ -> mismatch "revision fragment repeats a document block") spliced in
  let earlier = List.filter (fun x -> revision x<=covered) items in
  if List.length earlier<>List.length stored then mismatch ("spliced " ^ document ^ " entries differ from the history records");
  let live = List.filter (fun x -> revision x>covered) items in
  let rec groups acc = function
    | [] -> List.rev acc
    | x :: _ as xs ->
      let r = revision x in
      let mine,rest = List.partition (fun y -> revision y=r) xs in
      groups ((r,mine)::acc) rest in
  let rendered = List.concat_map (fun (r,xs) ->
    let before = Migration_canonical_nodes.length nodes in
    let entries = List.map render xs in
    (match !active with
     | Some c when List.mem r c.recording ->
       let stored = List.filter_map unshape entries in
       if List.length stored<>List.length entries then c.refused <- r :: c.refused else
       c.captured <- (r,{document;database;entries=stored;nodes=Migration_canonical_nodes.since nodes before}) :: c.captured
     | _ -> ());
    entries) (groups [] live) in
  (* A recorded revision without entries here has an empty block. *)
  (match !active with
   | Some c -> List.iter (fun r ->
       if not (List.exists (fun (r',(b:block)) -> r'=r && b.document=document && b.database=database) c.captured) then
         c.captured <- (r,{document;database;entries=[];nodes=[]}) :: c.captured) c.recording
   | None -> ());
  "[" ^ String.concat "," (stored @ rendered) ^ "]"

(* Recording at freeze: the emitter is reached through a hook the compiler
   driver installs, and the application entry through the selection that
   started the revision. *)
let recorder : (entry_file:string -> revisions:int list -> t list) option ref = ref None
let entry : string option ref = ref None
let with_entry file f =
  let saved = !entry in
  entry := Some file;
  Fun.protect ~finally:(fun () -> entry := saved) f
let record ~revisions =
  match !recorder,!entry with
  | Some run,Some entry_file when revisions<>[] -> (try run ~entry_file ~revisions with _ -> [])
  | _ -> []

(* The revisions a recording emit captures, and what it produced. *)
let requested : int list ref = ref []
let produced : t list ref = ref []
(* How many revisions the last project emission spliced (a test probe). *)
let last_spliced = ref 0
