(* Compact wire form of the canonical contracts in compiled history documents.

   Every published contract is the exact canonical encoding of one document
   (Migration_canonical.encode), and every digest stays a digest of those
   bytes. Consecutive revisions repeat most of their schema and storage
   snapshots, so a history document carries, per database, one table of
   hash-consed list nodes ("canonicalNodes") and each contract field holds the
   index of its root node. The runtime re-encodes the exact bytes from the
   table and verifies the stored digest as before.

   Table grammar (contractEncoding "tesl-canonical-nodes-v1"): the table is a
   JSON array of list nodes. A list node is a JSON array whose elements are, in
   order, its children: an integer is the index of an earlier list node (so
   the table is acyclic and bottom-up), a string is an atom whose bytes are
   valid UTF-8, and {"hex":H} is an atom that is not valid UTF-8, as lowercase
   hexadecimal. No two entries are equal and every atom takes the string form
   when it can, so a set of contracts has exactly one table for a given
   interning order.

   Entries are appended in first-use order. A renderer interns contracts in
   revision order, so the entries a revision introduces form one contiguous
   block after those of earlier revisions; [length] marks the boundary. *)
module C = Migration_canonical

let encoding = "tesl-canonical-nodes-v1"

type t = {
  quote : string -> string;
  index : (string, int) Hashtbl.t;      (* rendered entry -> its index *)
  contracts : (string, int) Hashtbl.t;  (* hexadecimal contract -> root index *)
  entries : Buffer.t;
  mutable count : int;
}

let create ~quote =
  {quote; index=Hashtbl.create 1024; contracts=Hashtbl.create 256; entries=Buffer.create 4096; count=0}

let length t = t.count

let atom t value =
  if String.is_valid_utf_8 value then t.quote value
  else "{\"hex\":\"" ^ Migration_row_history.hex value ^ "\"}"

let rec intern t = function
  | C.Bytes _ -> invalid_arg "a canonical node table holds list nodes only"
  | C.Seq children ->
    let elements = List.map (function
      | C.Bytes value -> atom t value
      | C.Seq _ as child -> string_of_int (intern t child)) children in
    let entry = "[" ^ String.concat "," elements ^ "]" in
    match Hashtbl.find_opt t.index entry with
    | Some index -> index
    | None ->
      let index = t.count in
      if index > 0 then Buffer.add_char t.entries ',';
      Buffer.add_string t.entries entry;
      Hashtbl.add t.index entry index;
      t.count <- index + 1;
      index

(* The root index of a published contract, given as the lowercase hexadecimal
   of its canonical bytes (the form history records keep). *)
let contract t hex =
  match Hashtbl.find_opt t.contracts hex with
  | Some index -> index
  | None ->
    let index = intern t (C.parse (Migration_records.unhex hex)) in
    Hashtbl.add t.contracts hex index;
    index

(* A contract field's JSON value. *)
let reference t hex = string_of_int (contract t hex)

let to_json t = "[" ^ Buffer.contents t.entries ^ "]"
