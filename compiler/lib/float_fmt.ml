(** Single float-formatting choke point (S15), split by PURPOSE.

    Two jobs that must never be confused, so they are two named functions:

    - [to_faithful_literal] — EMISSION.  Produce Racket source that reads back as
      EXACTLY the same double.  OCaml's [string_of_float] uses "%.12g", which is
      NOT round-trip faithful (e.g. 3.141592653589793 -> "3.14159265359", a
      ~2e-13 silent drift), so a naive emission would change the program's
      meaning.

    - [identity_key] — IDENTITY.  A collision-free key for a float used as a
      proof SUBJECT or proof ARGUMENT.  "%.12g" collides — 0.0 and -0.0 print
      identically, and two distinct nearby doubles can share a rendering — which
      would let a proof established about one float be silently reused for a
      different float (a proof-subject forgery).  The IEEE-754 bit pattern is
      total and injective over all doubles (it distinguishes +0.0/-0.0 and NaN
      payloads), so it is the right identity.

    Raw [string_of_float] / "%g" on a float is BANNED elsewhere in the compiler:
    pick the function whose PURPOSE matches (emission vs identity). *)

(** EMISSION: shortest decimal that round-trips to [f], falling back to %.17g.
    Source float literals are always finite, so the non-finite arms are
    unreachable via the emitter today — but guard them anyway, using Racket's
    own special-value syntax ([+nan.0]/[+inf.0]/[-inf.0]) rather than falling
    through the decimal path (which would produce the invalid "nan.0"). *)
let to_faithful_literal (f : float) : string =
  if Float.is_nan f then "+nan.0"
  else if f = Float.infinity then "+inf.0"
  else if f = Float.neg_infinity then "-inf.0"
  else
  let default = string_of_float f in
  if float_of_string default = f then default
  else begin
    let rec shortest p =
      if p > 17 then Printf.sprintf "%.17g" f
      else
        let s = Printf.sprintf "%.*g" p f in
        if float_of_string s = f then s else shortest (p + 1)
    in
    let s = shortest 15 in
    if String.contains s '.' || String.contains s 'e' || String.contains s 'E'
    then s else s ^ ".0"
  end

(** IDENTITY: total, injective key over the whole double bit-space. *)
let identity_key (f : float) : string =
  Printf.sprintf "f#0x%016Lx" (Int64.bits_of_float f)
