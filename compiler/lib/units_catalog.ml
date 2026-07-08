(* First-Class Units — the SI dimension algebra and unit catalog.

   A dimension is 7 signed exponents over the SI base dimensions.  A
   dimensioned type is represented as a CANONICAL NOMINAL TCon whose name
   encodes the exponent vector ([dim_name]), so dimension equality is plain
   TCon string equality and the Robinson unifier needs NO change: cross-
   dimension add/compare fails through the existing TCon-mismatch arm, and
   the dimension algebra lives only in the checker's [infer_binop] split.

   The sigil characters in [dim_name] ("§", "[", ",") cannot appear in a Tesl
   identifier, so no user or stdlib TCon can ever collide with (or forge) a
   quantity type name — collision-proof by construction.

   Values ERASE to plain Float at runtime; only the Racket unit constructors
   (tesl/units.rkt) know conversion factors.  This module is deliberately
   dependency-free (like tz_zones.ml) so type_system.ml and checker.ml can
   both consume it. *)

type dim = {
  length  : int;   (* metre     m   *)
  mass    : int;   (* kilogram  kg  *)
  time    : int;   (* second    s   *)
  current : int;   (* ampere    A   *)
  temp    : int;   (* kelvin    K   *)
  amount  : int;   (* mole      mol *)
  lumin   : int;   (* candela   cd  *)
}

let dimensionless : dim =
  { length = 0; mass = 0; time = 0; current = 0; temp = 0; amount = 0; lumin = 0 }

let dim_add (a : dim) (b : dim) : dim =
  { length  = a.length  + b.length;
    mass    = a.mass    + b.mass;
    time    = a.time    + b.time;
    current = a.current + b.current;
    temp    = a.temp    + b.temp;
    amount  = a.amount  + b.amount;
    lumin   = a.lumin   + b.lumin }

let dim_sub (a : dim) (b : dim) : dim =
  { length  = a.length  - b.length;
    mass    = a.mass    - b.mass;
    time    = a.time    - b.time;
    current = a.current - b.current;
    temp    = a.temp    - b.temp;
    amount  = a.amount  - b.amount;
    lumin   = a.lumin   - b.lumin }

let dim_neg (a : dim) : dim = dim_sub dimensionless a

let dim_scale (k : int) (a : dim) : dim =
  { length = k * a.length; mass = k * a.mass; time = k * a.time;
    current = k * a.current; temp = k * a.temp; amount = k * a.amount;
    lumin = k * a.lumin }

let dim_is_zero (a : dim) : bool = a = dimensionless

(* Every exponent even — [Units.sqrt] is only defined on such dimensions. *)
let dim_all_even (a : dim) : bool =
  a.length mod 2 = 0 && a.mass mod 2 = 0 && a.time mod 2 = 0
  && a.current mod 2 = 0 && a.temp mod 2 = 0 && a.amount mod 2 = 0
  && a.lumin mod 2 = 0

let dim_halve (a : dim) : dim =
  { length = a.length / 2; mass = a.mass / 2; time = a.time / 2;
    current = a.current / 2; temp = a.temp / 2; amount = a.amount / 2;
    lumin = a.lumin / 2 }

(* ── Canonical TCon name ─────────────────────────────────────────────────── *)

let quantity_prefix = "\xc2\xa7Q["   (* "§Q[" — § is illegal in identifiers *)

(* Canonical, TOTAL, collision-proof name: exponent order is
   length,mass,time,current,temp,amount,lumin. *)
let dim_name (d : dim) : string =
  Printf.sprintf "%s%d,%d,%d,%d,%d,%d,%d]" quantity_prefix
    d.length d.mass d.time d.current d.temp d.amount d.lumin

let is_quantity_name (name : string) : bool =
  let p = quantity_prefix in
  String.length name > String.length p
  && String.sub name 0 (String.length p) = p

(* The canonical name IS the normal form — parse it back (stateless; no
   side-table has to be threaded through checker contexts). *)
let dim_of_name (name : string) : dim option =
  let p = quantity_prefix in
  let pl = String.length p in
  if not (is_quantity_name name) || name.[String.length name - 1] <> ']' then None
  else
    let body = String.sub name pl (String.length name - pl - 1) in
    match String.split_on_char ',' body with
    | [l; m; t; c; k; mol; cd] ->
      (try
         Some { length = int_of_string l; mass = int_of_string m;
                time = int_of_string t; current = int_of_string c;
                temp = int_of_string k; amount = int_of_string mol;
                lumin = int_of_string cd }
       with _ -> None)
    | _ -> None

(* ── Money rates (First-Class Units × Money) ─────────────────────────────────
   A MoneyRate is money PER quantity — hourly consultant cost, price per kg.
   Currency stays a runtime qualifier (inside the value, like Money); the
   DENOMINATOR dimension joins the type algebra with its own canonical TCon
   family, so `Money / Duration : MoneyPerDuration` and
   `rate * Duration : Money` (dimensions cancel) while
   `rate * Mass` is a compile error.  Same collision-proof sigil scheme. *)

let money_rate_prefix = "\xc2\xa7MR["   (* "§MR[" *)

let money_rate_name (d : dim) : string =
  Printf.sprintf "%s%d,%d,%d,%d,%d,%d,%d]" money_rate_prefix
    d.length d.mass d.time d.current d.temp d.amount d.lumin

let is_money_rate_name (name : string) : bool =
  let p = money_rate_prefix in
  String.length name > String.length p
  && String.sub name 0 (String.length p) = p

let dim_of_money_rate_name (name : string) : dim option =
  let p = money_rate_prefix in
  let pl = String.length p in
  if not (is_money_rate_name name) || name.[String.length name - 1] <> ']' then None
  else
    let body = String.sub name pl (String.length name - pl - 1) in
    match String.split_on_char ',' body with
    | [l; m; t; c; k; mol; cd] ->
      (try
         Some { length = int_of_string l; mass = int_of_string m;
                time = int_of_string t; current = int_of_string c;
                temp = int_of_string k; amount = int_of_string mol;
                lumin = int_of_string cd }
       with _ -> None)
    | _ -> None

(* ── Named dimension aliases (the type names users write) ────────────────── *)

let d_length       = { dimensionless with length = 1 }
let d_mass         = { dimensionless with mass = 1 }
let d_duration     = { dimensionless with time = 1 }
let d_current      = { dimensionless with current = 1 }
let d_temperature  = { dimensionless with temp = 1 }
let d_amount       = { dimensionless with amount = 1 }
let d_lumin        = { dimensionless with lumin = 1 }
let d_speed        = { dimensionless with length = 1; time = -1 }
let d_acceleration = { dimensionless with length = 1; time = -2 }
let d_area         = { dimensionless with length = 2 }
let d_volume       = { dimensionless with length = 3 }
let d_force        = { dimensionless with length = 1; mass = 1; time = -2 }
let d_energy       = { dimensionless with length = 2; mass = 1; time = -2 }
let d_power        = { dimensionless with length = 2; mass = 1; time = -3 }
let d_pressure     = { dimensionless with length = -1; mass = 1; time = -2 }
let d_frequency    = { dimensionless with time = -1 }

(* (alias type name, dimension).  These names resolve in type annotations to
   the canonical quantity TCon; NOT nominal wrappers — `Speed` and the result
   of `Length.meters 1.0 / Duration.seconds 1.0` are the SAME type. *)
let aliases : (string * dim) list = [
  ("Length",            d_length);
  ("Mass",              d_mass);
  ("Duration",          d_duration);
  ("ElectricCurrent",   d_current);
  ("Temperature",       d_temperature);
  ("AmountOfSubstance", d_amount);
  ("LuminousIntensity", d_lumin);
  ("Speed",             d_speed);
  ("Acceleration",      d_acceleration);
  ("Area",              d_area);
  ("Volume",            d_volume);
  ("Force",             d_force);
  ("Energy",            d_energy);
  ("Power",             d_power);
  ("Pressure",          d_pressure);
  ("Frequency",         d_frequency);
]

let alias_of_dim (d : dim) : string option =
  List.find_map (fun (a, d') -> if d = d' then Some a else None) aliases

let dim_of_alias (a : string) : dim option = List.assoc_opt a aliases

(* (alias type name, DENOMINATOR dimension) — the MoneyRate types users write.
   Owned by Tesl.Money (import-gated with it); resolved to the canonical
   §MR[...] TCon in annotations. *)
let money_rate_aliases : (string * dim) list = [
  ("MoneyPerDuration", d_duration);
  ("MoneyPerMass",     d_mass);
  ("MoneyPerLength",   d_length);
  ("MoneyPerArea",     d_area);
  ("MoneyPerVolume",   d_volume);
]

let dim_of_money_rate_alias (a : string) : dim option =
  List.assoc_opt a money_rate_aliases

let money_rate_alias_of_dim (d : dim) : string option =
  List.find_map (fun (a, d') -> if d = d' then Some a else None)
    money_rate_aliases

(* ── Rate boundary labels (GitHub #38: rates as SQL columns + wire output) ───
   At a BOUNDARY (JSON wire, database column) a rate is quantized to INTEGER
   minor units per one `per`-labelled unit — the same stance as Money itself
   (exact integers at rest, exact rationals only mid-computation, ONE
   half-even rounding at the edge).  (label, denominator dim, canonical units
   per one label unit as num/den).  The DEFAULT label per dimension is chosen
   for sane magnitudes (per HOUR, not per second — a 950 SEK/h rate stored
   per-second would quantize to 0).  tesl/money.rkt mirrors this table for
   decode; the factor seam is test-pinned. *)
let rate_labels : (string * dim * (int * int)) list = [
  ("s",   d_duration, (1, 1));
  ("h",   d_duration, (3600, 1));
  ("day", d_duration, (86400, 1));
  ("kg",  d_mass,     (1, 1));
  ("m",   d_length,   (1, 1));
  ("m^2", d_area,     (1, 1));
  ("m^3", d_volume,   (1, 1));
  ("L",   d_volume,   (1, 1000));
]

let rate_label_dim (label : string) : dim option =
  List.find_map (fun (l, d, _) -> if l = label then Some d else None)
    rate_labels

(* The label a DIVISION-built rate quantizes/stores/displays with. *)
let default_rate_label_of_dim (d : dim) : (string * (int * int)) option =
  let defaults = [ (d_duration, "h"); (d_mass, "kg"); (d_length, "m");
                   (d_area, "m^2"); (d_volume, "m^3") ] in
  match List.assoc_opt d defaults with
  | Some l ->
    List.find_map (fun (l', d', f) ->
        if l' = l && d' = d then Some (l, f) else None)
      rate_labels
  | None -> None

(* ── Pretty rendering (for pp_ty and error messages) ─────────────────────── *)

(* "m/s^2", "m^2", "m·kg/s^2", "1/s".  ASCII ^ exponents; "·" separator. *)
let unit_form (d : dim) : string =
  let base = [ (d.length, "m"); (d.mass, "kg"); (d.time, "s");
               (d.current, "A"); (d.temp, "K"); (d.amount, "mol");
               (d.lumin, "cd") ] in
  let part (e, sym) =
    if e = 1 then sym else Printf.sprintf "%s^%d" sym e in
  let pos = List.filter (fun (e, _) -> e > 0) base in
  let neg = List.filter_map (fun (e, s) ->
      if e < 0 then Some (-e, s) else None) base in
  let num = match pos with
    | [] -> "1"
    | ps -> String.concat "\xc2\xb7" (List.map part ps) in    (* "·" *)
  match neg with
  | [] -> num
  | ns -> num ^ "/" ^ String.concat "\xc2\xb7" (List.map part ns)

(* Alias when one exists ("Speed"), else the unit form ("m/s^3") — what user-
   facing type printing and dimension-mismatch errors show; the raw §Q[...]
   canonical name must never leak into a diagnostic. *)
let display_name (d : dim) : string =
  match alias_of_dim d with
  | Some a -> a
  | None -> unit_form d

(* Pretty for a quantity TCon NAME (checker/type_system convenience). *)
let display_of_name (name : string) : string option =
  Option.map display_name (dim_of_name name)

(* Pretty for a MoneyRate TCon NAME: the alias ("MoneyPerDuration") or
   "Money/<unit form>" ("Money/kg"); §MR[...] never leaks. *)
let money_rate_display_of_name (name : string) : string option =
  Option.map
    (fun d ->
       match money_rate_alias_of_dim d with
       | Some a -> a
       | None -> "Money/" ^ unit_form d)
    (dim_of_money_rate_name name)

(* ── Constructor / accessor catalog ──────────────────────────────────────── *)

(* (module, function, dimension) — one row per unit CONSTRUCTOR
   (Float -> Quantity).  Conversion factors live ONLY in tesl/units.rkt; a
   catalog row without a runtime binding is caught by the stdlib
   binding-existence seam test. *)
let constructors : (string * string * dim) list = [
  ("Length", "meters", d_length); ("Length", "kilometers", d_length);
  ("Length", "centimeters", d_length); ("Length", "millimeters", d_length);
  ("Length", "miles", d_length); ("Length", "feet", d_length);
  ("Length", "inches", d_length); ("Length", "yards", d_length);
  ("Length", "nauticalMiles", d_length);
  ("Mass", "kilograms", d_mass); ("Mass", "grams", d_mass);
  ("Mass", "milligrams", d_mass); ("Mass", "tonnes", d_mass);
  ("Mass", "pounds", d_mass); ("Mass", "ounces", d_mass);
  ("Duration", "seconds", d_duration); ("Duration", "milliseconds", d_duration);
  ("Duration", "minutes", d_duration); ("Duration", "hours", d_duration);
  ("Duration", "days", d_duration);
  ("Speed", "metersPerSecond", d_speed); ("Speed", "kilometersPerHour", d_speed);
  ("Speed", "milesPerHour", d_speed); ("Speed", "knots", d_speed);
  ("Acceleration", "metersPerSecondSquared", d_acceleration);
  ("Area", "squareMeters", d_area); ("Area", "squareKilometers", d_area);
  ("Area", "hectares", d_area); ("Area", "squareFeet", d_area);
  ("Area", "acres", d_area);
  ("Volume", "cubicMeters", d_volume); ("Volume", "liters", d_volume);
  ("Volume", "milliliters", d_volume); ("Volume", "gallons", d_volume);
  ("Temperature", "kelvin", d_temperature);
  ("Temperature", "celsius", d_temperature);       (* affine: +273.15 *)
  ("Temperature", "fahrenheit", d_temperature);    (* affine *)
  ("Force", "newtons", d_force);
  ("Energy", "joules", d_energy); ("Energy", "kilojoules", d_energy);
  ("Energy", "kilowattHours", d_energy); ("Energy", "calories", d_energy);
  ("Power", "watts", d_power); ("Power", "kilowatts", d_power);
  ("Power", "horsepower", d_power);
  ("Frequency", "hertz", d_frequency); ("Frequency", "kilohertz", d_frequency);
  ("Pressure", "pascals", d_pressure); ("Pressure", "kilopascals", d_pressure);
  ("Pressure", "bar", d_pressure);
]

(* (module, function, dimension) — accessors (Quantity -> Float), the explicit
   projections back to a raw Float in a NAMED unit. *)
let accessors : (string * string * dim) list = [
  ("Length", "inMeters", d_length); ("Length", "inKilometers", d_length);
  ("Length", "inCentimeters", d_length); ("Length", "inMillimeters", d_length);
  ("Length", "inMiles", d_length); ("Length", "inFeet", d_length);
  ("Length", "inInches", d_length); ("Length", "inYards", d_length);
  ("Length", "inNauticalMiles", d_length);
  ("Mass", "inKilograms", d_mass); ("Mass", "inGrams", d_mass);
  ("Mass", "inMilligrams", d_mass); ("Mass", "inTonnes", d_mass);
  ("Mass", "inPounds", d_mass); ("Mass", "inOunces", d_mass);
  ("Duration", "inSeconds", d_duration); ("Duration", "inMilliseconds", d_duration);
  ("Duration", "inMinutes", d_duration); ("Duration", "inHours", d_duration);
  ("Duration", "inDays", d_duration);
  ("Speed", "inMetersPerSecond", d_speed); ("Speed", "inKilometersPerHour", d_speed);
  ("Speed", "inMilesPerHour", d_speed); ("Speed", "inKnots", d_speed);
  ("Acceleration", "inMetersPerSecondSquared", d_acceleration);
  ("Area", "inSquareMeters", d_area); ("Area", "inSquareKilometers", d_area);
  ("Area", "inHectares", d_area); ("Area", "inSquareFeet", d_area);
  ("Area", "inAcres", d_area);
  ("Volume", "inCubicMeters", d_volume); ("Volume", "inLiters", d_volume);
  ("Volume", "inMilliliters", d_volume); ("Volume", "inGallons", d_volume);
  ("Temperature", "inKelvin", d_temperature);
  ("Temperature", "inCelsius", d_temperature);
  ("Temperature", "inFahrenheit", d_temperature);
  ("Force", "inNewtons", d_force);
  ("Energy", "inJoules", d_energy); ("Energy", "inKilojoules", d_energy);
  ("Energy", "inKilowattHours", d_energy); ("Energy", "inCalories", d_energy);
  ("Power", "inWatts", d_power); ("Power", "inKilowatts", d_power);
  ("Power", "inHorsepower", d_power);
  ("Frequency", "inHertz", d_frequency); ("Frequency", "inKilohertz", d_frequency);
  ("Pressure", "inPascals", d_pressure); ("Pressure", "inKilopascals", d_pressure);
  ("Pressure", "inBar", d_pressure);
]

(* Quantity qualifier modules (for known_qualifier_modules + import gating).
   "Units" additionally hosts the polymorphic dimension operations
   (Units.mul/div/square/sqrt/abs/min/max/sum) special-cased in the checker. *)
let quantity_modules : string list =
  [ "Length"; "Mass"; "Duration"; "Speed"; "Acceleration"; "Area"; "Volume";
    "Temperature"; "Force"; "Energy"; "Power"; "Frequency"; "Pressure";
    "Units" ]

(* All dotted names Tesl.Units exports (constructors + accessors + the
   polymorphic ops), plus the alias TYPE names. *)
let units_op_names : string list =
  [ "Units.mul"; "Units.div"; "Units.square"; "Units.sqrt";
    "Units.abs"; "Units.min"; "Units.max"; "Units.sum"; "Units.negate";
    "Units.requireNonZero" ]

(* Duration ⇄ PosixMillis-delta bridge (typed spans; the Int-ms forms stay
   canonical).  Time.add/subtract/diff live in Tesl.Time's export list. *)
let duration_bridge_names : string list =
  [ "Duration.toMillis"; "Duration.fromMillis" ]

let exported_names : string list =
  List.map (fun (m, f, _) -> m ^ "." ^ f) constructors
  @ List.map (fun (m, f, _) -> m ^ "." ^ f) accessors
  @ units_op_names
  @ duration_bridge_names
  @ List.map fst aliases

(* ── Active-alias gating ─────────────────────────────────────────────────────
   The bare alias TYPE names (Length/Speed/…) are common words a user module
   may legitimately declare itself (`type Speed = Slow | Fast`).  They
   therefore resolve to quantity types ONLY when activated for the module
   being compiled — i.e. exposed by an `import Tesl.Units` — and a local type
   declaration colliding with an ACTIVE alias is a compile error (fail-closed,
   never silent hijack).  The canonical §Q[...] names are collision-proof and
   always recognized.  The checker sets this per module (save/restore around
   nested module checks); emit/ir consult it afterwards in the same compile
   pass. *)
let active_aliases : (string, dim) Hashtbl.t = Hashtbl.create 16

let set_active_aliases (names : string list) : unit =
  Hashtbl.clear active_aliases;
  List.iter (fun n ->
      match List.assoc_opt n aliases with
      | Some d -> Hashtbl.replace active_aliases n d
      | None -> ())
    names

let snapshot_active_aliases () : string list =
  Hashtbl.fold (fun k _ acc -> k :: acc) active_aliases []

let active_dim_of_alias (a : string) : dim option =
  Hashtbl.find_opt active_aliases a

(* MoneyRate aliases (MoneyPerDuration, …) activate when the module imports
   Tesl.Money — same silent-hijack discipline as the Units aliases. *)
let money_rate_aliases_active : bool ref = ref false

let active_money_rate_dim_of_alias (a : string) : dim option =
  if !money_rate_aliases_active then List.assoc_opt a money_rate_aliases
  else None

(* Constructor/accessor dim lookup for typing rows. *)
let constructor_dim (qualified : string) : dim option =
  List.find_map (fun (m, f, d) ->
      if m ^ "." ^ f = qualified then Some d else None)
    constructors

let accessor_dim (qualified : string) : dim option =
  List.find_map (fun (m, f, d) ->
      if m ^ "." ^ f = qualified then Some d else None)
    accessors
