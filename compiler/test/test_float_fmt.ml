(** S15 — property tests for the single float choke point Float_fmt.

    Two guarantees, one per purpose:
      1. to_faithful_literal round-trips: float_of_string (to_faithful_literal f) = f
         for every double (the emission must not silently change the value).
      2. identity_key is injective: distinct bit patterns -> distinct keys
         (so a proof about one float can never be reused for another).  In
         particular it distinguishes +0.0 / -0.0 and NaN payloads, which "%.12g"
         (the old string_of_float identity) collapses.

    Pure OCaml, no alcotest / no Racket, so it runs in every gate:
      dune exec test/test_float_fmt.exe *)

let failures = ref 0
let check name ok = if ok then Printf.printf "ok   - %s\n" name
  else begin incr failures; Printf.printf "FAIL - %s\n" name end

(* nan-safe equality on the BIT pattern (nan <> nan under =, and 0.0 = -0.0). *)
let bits_eq a b = Int64.equal (Int64.bits_of_float a) (Int64.bits_of_float b)

(* to_faithful_literal must round-trip via OCaml's float_of_string for every
   FINITE double (source float literals are always finite).  Non-finite values
   use Racket's own +nan.0/+inf.0/-inf.0 syntax (OCaml's parser doesn't accept
   those), so they are checked separately below, not through this oracle. *)
let roundtrips f =
  let s = Float_fmt.to_faithful_literal f in
  bits_eq f (float_of_string s)

let sample_floats =
  [ 0.0; -0.0; 1.0; -1.0; 0.1; 0.2; 0.3; 1.5; 2.0; 3.141592653589793;
    2.718281828459045; 1e-300; 1e300; 4.9e-324 (* denormal min *);
    1.7976931348623157e308 (* max *); 123456789.123456789;
    0.0000001; 100000000.0; -273.15; 6.022e23;
    Float.of_int max_int; Float.epsilon; 1.0 /. 3.0 ]

let () =
  (* 1. Round-trip faithfulness over a spread of doubles + specials. *)
  List.iter (fun f ->
    check (Printf.sprintf "round-trip %h" f) (roundtrips f)) sample_floats;
  (* Non-finite: Racket special-value syntax (emitter never sees these, but the
     function must still produce valid Racket if ever called). *)
  check "emit +inf.0" (Float_fmt.to_faithful_literal infinity = "+inf.0");
  check "emit -inf.0" (Float_fmt.to_faithful_literal neg_infinity = "-inf.0");
  check "emit +nan.0" (Float_fmt.to_faithful_literal nan = "+nan.0");

  (* 2. identity_key injectivity on the cases "%.12g" collides. *)
  check "identity distinguishes +0.0 / -0.0"
    (Float_fmt.identity_key 0.0 <> Float_fmt.identity_key (-0.0));
  (* two distinct doubles that render identically under %.12g *)
  let a = 0.1 +. 0.2 (* 0.30000000000000004 *) and b = 0.3 in
  check "0.1+0.2 <> 0.3 have distinct identity keys"
    (not (bits_eq a b) && Float_fmt.identity_key a <> Float_fmt.identity_key b);
  check "%.12g would have collided them"
    (Printf.sprintf "%.12g" a = Printf.sprintf "%.12g" b);
  (* distinct NaN payloads -> distinct keys *)
  let nan1 = Int64.float_of_bits 0x7ff8000000000001L
  and nan2 = Int64.float_of_bits 0x7ff8000000000002L in
  check "distinct NaN payloads have distinct identity keys"
    (Float_fmt.identity_key nan1 <> Float_fmt.identity_key nan2);

  (* 3. identity_key is a total function (no exception on specials). *)
  List.iter (fun f -> ignore (Float_fmt.identity_key f))
    (infinity :: neg_infinity :: nan :: sample_floats);
  check "identity_key total over specials" true;

  (* 4. identity_key injective across the whole sample (pairwise distinct where
     bit patterns differ). *)
  let keys = List.map (fun f -> (f, Float_fmt.identity_key f)) sample_floats in
  let injective =
    List.for_all (fun (f1, k1) ->
      List.for_all (fun (f2, k2) ->
        bits_eq f1 f2 || k1 <> k2) keys) keys
  in
  check "identity_key injective over the sample" injective;

  Printf.printf "\n%s (%d failure(s))\n"
    (if !failures = 0 then "PASS" else "FAILURES") !failures;
  exit (if !failures = 0 then 0 else 1)
