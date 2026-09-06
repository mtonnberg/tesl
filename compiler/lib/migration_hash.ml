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

let digest source =
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
