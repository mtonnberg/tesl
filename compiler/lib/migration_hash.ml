(** SHA-256 for migration identities. The serialized semantic input is owned by
    Migration_ir; this module deliberately accepts bytes, not ASTs or locations.
    Fixed-width Int32 arithmetic makes native and JavaScript compiler builds agree. *)

let constants = [|
  0x428a2f98l; 0x71374491l; 0xb5c0fbcfl; 0xe9b5dba5l;
  0x3956c25bl; 0x59f111f1l; 0x923f82a4l; 0xab1c5ed5l;
  0xd807aa98l; 0x12835b01l; 0x243185bel; 0x550c7dc3l;
  0x72be5d74l; 0x80deb1fel; 0x9bdc06a7l; 0xc19bf174l;
  0xe49b69c1l; 0xefbe4786l; 0x0fc19dc6l; 0x240ca1ccl;
  0x2de92c6fl; 0x4a7484aal; 0x5cb0a9dcl; 0x76f988dal;
  0x983e5152l; 0xa831c66dl; 0xb00327c8l; 0xbf597fc7l;
  0xc6e00bf3l; 0xd5a79147l; 0x06ca6351l; 0x14292967l;
  0x27b70a85l; 0x2e1b2138l; 0x4d2c6dfcl; 0x53380d13l;
  0x650a7354l; 0x766a0abbl; 0x81c2c92el; 0x92722c85l;
  0xa2bfe8a1l; 0xa81a664bl; 0xc24b8b70l; 0xc76c51a3l;
  0xd192e819l; 0xd6990624l; 0xf40e3585l; 0x106aa070l;
  0x19a4c116l; 0x1e376c08l; 0x2748774cl; 0x34b0bcb5l;
  0x391c0cb3l; 0x4ed8aa4al; 0x5b9cca4fl; 0x682e6ff3l;
  0x748f82eel; 0x78a5636fl; 0x84c87814l; 0x8cc70208l;
  0x90befffal; 0xa4506cebl; 0xbef9a3f7l; 0xc67178f2l;
|]

let rotate x n =
  Int32.logor (Int32.shift_right_logical x n) (Int32.shift_left x (32 - n))

let xor3 a b c = Int32.logxor (Int32.logxor a b) c
let ( +! ) = Int32.add

(* 2^32 - 1, built at run time: a JavaScript build (which never takes the
   native path) must not see a literal its 32-bit ints cannot represent. *)
let mask = Int64.to_int 0xffffffffL
let[@inline] rot x n = ((x lsr n) lor (x lsl (32 - n))) land mask
let native_constants = Array.map (fun c -> Int32.to_int c land mask) constants

(* One compression of [w] into [state]; the working variables stay in
   registers as loop arguments. *)
let compress state w =
  let rec round i a b c d e f g h =
    if i = 64 then begin
      Array.unsafe_set state 0 ((Array.unsafe_get state 0 + a) land mask);
      Array.unsafe_set state 1 ((Array.unsafe_get state 1 + b) land mask);
      Array.unsafe_set state 2 ((Array.unsafe_get state 2 + c) land mask);
      Array.unsafe_set state 3 ((Array.unsafe_get state 3 + d) land mask);
      Array.unsafe_set state 4 ((Array.unsafe_get state 4 + e) land mask);
      Array.unsafe_set state 5 ((Array.unsafe_get state 5 + f) land mask);
      Array.unsafe_set state 6 ((Array.unsafe_get state 6 + g) land mask);
      Array.unsafe_set state 7 ((Array.unsafe_get state 7 + h) land mask) end
    else
      let s1 = rot e 6 lxor rot e 11 lxor rot e 25 in
      let ch = (e land f) lxor ((lnot e) land g) in
      let t1 = h + s1 + ch + Array.unsafe_get native_constants i + Array.unsafe_get w i in
      let s0 = rot a 2 lxor rot a 13 lxor rot a 22 in
      let maj = (a land b) lxor (a land c) lxor (b land c) in
      round (i+1) ((t1 + s0 + maj) land mask) a b c ((d + t1) land mask) e f g in
  round 0 (Array.unsafe_get state 0) (Array.unsafe_get state 1) (Array.unsafe_get state 2) (Array.unsafe_get state 3)
    (Array.unsafe_get state 4) (Array.unsafe_get state 5) (Array.unsafe_get state 6) (Array.unsafe_get state 7)
let load_block w text offset =
  for i = 0 to 15 do
    let p = offset + 4 * i in
    Array.unsafe_set w i ((Char.code (String.unsafe_get text p) lsl 24) lor (Char.code (String.unsafe_get text (p + 1)) lsl 16)
             lor (Char.code (String.unsafe_get text (p + 2)) lsl 8) lor Char.code (String.unsafe_get text (p + 3)))
  done;
  for i = 16 to 63 do
    let x = Array.unsafe_get w (i - 15) and y = Array.unsafe_get w (i - 2) in
    let s0 = rot x 7 lxor rot x 18 lxor (x lsr 3) in
    let s1 = rot y 17 lxor rot y 19 lxor (y lsr 10) in
    Array.unsafe_set w i ((Array.unsafe_get w (i - 16) + s0 + Array.unsafe_get w (i - 7) + s1) land mask)
  done

(* An incremental native SHA-256: [feed] pieces, then [finish]. Hashing a
   sequence of pieces equals hashing their concatenation, without building it. *)
type stream = { state : int array; w : int array; pending : Bytes.t; mutable fill : int; mutable length : int }
let stream () = { state = [|0x6a09e667; 0xbb67ae85; 0x3c6ef372; 0xa54ff53a; 0x510e527f; 0x9b05688c; 0x1f83d9ab; 0x5be0cd19|];
  w = Array.make 64 0; pending = Bytes.create 64; fill = 0; length = 0 }
let feed t text =
  let size = String.length text in
  t.length <- t.length + size;
  let position = ref 0 in
  if t.fill > 0 then begin
    let take = min (64 - t.fill) size in
    Bytes.blit_string text 0 t.pending t.fill take;
    t.fill <- t.fill + take; position := take;
    if t.fill = 64 then begin
      load_block t.w (Bytes.unsafe_to_string t.pending) 0; compress t.state t.w; t.fill <- 0
    end
  end;
  while size - !position >= 64 do
    load_block t.w text !position; compress t.state t.w; position := !position + 64
  done;
  if !position < size then begin
    Bytes.blit_string text !position t.pending 0 (size - !position); t.fill <- size - !position
  end
let finish t =
  let rest = t.fill in
  let tail = Bytes.make (if rest < 56 then 64 else 128) '\000' in
  Bytes.blit t.pending 0 tail 0 rest;
  Bytes.set tail rest '\128';
  let bits = t.length * 8 and size = Bytes.length tail in
  for i = 0 to 7 do Bytes.set tail (size - 1 - i) (Char.unsafe_chr ((bits lsr (8 * i)) land 255)) done;
  let tail = Bytes.unsafe_to_string tail in
  load_block t.w tail 0; compress t.state t.w;
  if size = 128 then (load_block t.w tail 64; compress t.state t.w);
  String.concat "" (Array.to_list (Array.map (Printf.sprintf "%08x") t.state))

(* SHA-256 over native integers for 64-bit builds: each 32-bit word lives in
   an untagged int masked to 32 bits, so hashing allocates nothing per block.
   JavaScript builds (32-bit ints) use the Int32 [compute] below; a test pins
   both to the same digests. *)
let compute_native source = let t = stream () in feed t source; finish t

(* Checking one application rehashes the same canonical inputs many times
   (46,112 calls over 217 MB with 553 distinct inputs for a twenty-revision
   history). SHA-256 is a pure function of its input, so a bounded memo returns
   the identical result; OCaml's string hashing and equality are far cheaper
   than this portable implementation. The memo is cleared when it would retain
   more than memo_limit bytes, so long-lived sessions stay bounded. *)
let memo : (string, string) Hashtbl.t = Hashtbl.create 1024
let memo_bytes = ref 0
let memo_limit = 256 * 1024 * 1024

let rec digest source =
  match Hashtbl.find_opt memo source with
  | Some result -> result
  | None ->
    let result = if Sys.int_size >= 63 then compute_native source else compute source in
    if !memo_bytes + String.length source > memo_limit then begin
      Hashtbl.reset memo; memo_bytes := 0
    end;
    Hashtbl.replace memo source result;
    memo_bytes := !memo_bytes + String.length source;
    result

and compute source =
  let length = String.length source in
  (* One block of scratch space: hashing a large schema must not require another
     whole copy of the input just to append its padding. *)
  let blocks = length / 64 + (if length mod 64 < 56 then 1 else 2) in
  let bits = Int64.mul (Int64.of_int length) 8L in
  let byte block offset =
    let position = block * 64 + offset in
    if position < length then Char.code source.[position]
    else if position = length then 128
    else if block = blocks - 1 && offset >= 56 then
      Int64.(to_int (logand 255L (shift_right_logical bits ((63 - offset) * 8))))
    else 0
  in
  let state = [|0x6a09e667l; 0xbb67ae85l; 0x3c6ef372l; 0xa54ff53al;
                0x510e527fl; 0x9b05688cl; 0x1f83d9abl; 0x5be0cd19l|] in
  let words = Array.make 64 0l in
  for block = 0 to blocks - 1 do
    for i = 0 to 15 do
      let word = ref 0l in
      for j = 0 to 3 do
        word := Int32.logor (Int32.shift_left !word 8) (Int32.of_int (byte block (4 * i + j)))
      done;
      words.(i) <- !word
    done;
    for i = 16 to 63 do
      let x = words.(i - 15) and y = words.(i - 2) in
      let s0 = xor3 (rotate x 7) (rotate x 18) (Int32.shift_right_logical x 3) in
      let s1 = xor3 (rotate y 17) (rotate y 19) (Int32.shift_right_logical y 10) in
      words.(i) <- words.(i - 16) +! s0 +! words.(i - 7) +! s1
    done;
    let a = ref state.(0) and b = ref state.(1) and c = ref state.(2) and d = ref state.(3)
    and e = ref state.(4) and f = ref state.(5) and g = ref state.(6) and h = ref state.(7) in
    for i = 0 to 63 do
      let s1 = xor3 (rotate !e 6) (rotate !e 11) (rotate !e 25) in
      let ch = Int32.logxor (Int32.logand !e !f) (Int32.logand (Int32.lognot !e) !g) in
      let t1 = !h +! s1 +! ch +! constants.(i) +! words.(i) in
      let s0 = xor3 (rotate !a 2) (rotate !a 13) (rotate !a 22) in
      let maj = xor3 (Int32.logand !a !b) (Int32.logand !a !c) (Int32.logand !b !c) in
      let t2 = s0 +! maj in
      h := !g; g := !f; f := !e; e := !d +! t1;
      d := !c; c := !b; b := !a; a := t1 +! t2
    done;
    Array.iteri (fun i x -> state.(i) <- state.(i) +! x)
      [|!a; !b; !c; !d; !e; !f; !g; !h|]
  done;
  Array.to_list state |> List.map (Printf.sprintf "%08lx") |> String.concat ""

(* The digest of the concatenation of [parts], without building it. *)
let digest_parts parts =
  if Sys.int_size >= 63 then begin
    let t = stream () in List.iter (feed t) parts; finish t
  end else compute (String.concat "" parts)
