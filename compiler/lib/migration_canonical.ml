(** Canonical migration wire format 1. The typed elaborator constructs these
    nodes after name/type resolution; this module never treats source text or
    Marshal output as semantic IR. See LANGUAGE-SPEC §10.2 for the wire contract. *)

type node = Bytes of string | Seq of node list
type domain = Snapshot | Migration | Same | Repair | Contract | Provenance
type role = Snapshot_role | From_role | To_role
type scope = { family : string; revision : string; role : role }

let bytes s = Bytes s
let seq nodes = Seq nodes

let encode root =
  let output = Buffer.create 128 in
  let rec emit = function
    | Bytes value ->
      Buffer.add_char output 's';
      Buffer.add_string output (string_of_int (String.length value));
      Buffer.add_char output ':';
      Buffer.add_string output value
    | Seq children ->
      Buffer.add_char output 'l';
      Buffer.add_string output (string_of_int (List.length children));
      Buffer.add_char output ':';
      List.iter emit children in
  emit root;
  Buffer.contents output

let domain_name = function
  | Snapshot -> "snapshot" | Migration -> "migration" | Same -> "same"
  | Repair -> "repair" | Contract -> "contract" | Provenance -> "provenance"

let document domain payload =
  Seq [Bytes "tesl-migration-canonical"; Bytes "1"; Bytes (domain_name domain); payload]

let digest domain payload = Migration_hash.digest (encode (document domain payload))

let role_name = function
  | Snapshot_role -> "snapshot" | From_role -> "from" | To_role -> "to"

let identifier segment =
  String.length segment > 0 &&
  (match segment.[0] with 'a'..'z' | 'A'..'Z' | '_' -> true | _ -> false) &&
  String.for_all (function 'a'..'z' | 'A'..'Z' | '0'..'9' | '_' -> true | _ -> false) segment

let reference scopes name =
  let parts = String.split_on_char '.' name in
  if List.length parts < 2 || not (List.for_all identifier parts) then Error "invalid resolved symbol name"
  else
    let rec validate seen = function
      | [] -> Ok ()
      | scope :: rest ->
        let prefix = scope.family ^ "." ^ scope.revision in
        if not (Migration_source.valid_family scope.family && Migration_source.valid_revision scope.revision) ||
           Validation_common.schema_module_relative_path prefix = None then
          Error ("invalid schema scope " ^ prefix)
        else if List.exists (fun s -> s.family = scope.family && s.revision = scope.revision) seen then
          Error ("duplicate schema scope " ^ prefix)
        else if List.exists (fun s -> s.family = scope.family && s.role = scope.role) seen then
          Error ("two revisions have the same schema role in " ^ scope.family)
        else validate (scope :: seen) rest in
    match validate [] scopes with
    | Error _ as error -> error
    | Ok () ->
      match parts with
      | family :: revision :: remaining ->
        (match List.find_opt (fun s -> s.family = family && s.revision = revision) scopes with
         | Some scope -> Ok (Seq [Bytes "schema"; Bytes family; Bytes (role_name scope.role);
                                  Seq (List.map bytes remaining)])
         | None when Migration_schema.schema_prefix (family ^ "." ^ revision) <> None ->
           Error ("unbound schema revision " ^ family ^ "." ^ revision)
         | None -> Ok (Seq [Bytes "global"; Seq (List.map bytes parts)]))
      | _ -> Ok (Seq [Bytes "global"; Seq (List.map bytes parts)])

let integer decimal =
  let negative = String.length decimal > 0 && decimal.[0] = '-' in
  let start = if negative then 1 else 0 in
  let length = String.length decimal in
  if start = length ||
     not (String.for_all (function '0'..'9' -> true | _ -> false)
            (String.sub decimal start (length - start))) then
    Error "integer literal must be signed decimal"
  else
    let first = ref start in
    while !first < length - 1 && decimal.[!first] = '0' do incr first done;
    let magnitude = String.sub decimal !first (length - !first) in
    let normal = if negative && magnitude <> "0" then "-" ^ magnitude else magnitude in
    Ok (Seq [Bytes "int"; Bytes normal])

let float value =
  match classify_float value with
  | FP_nan | FP_infinite -> Error "non-finite float literal in migration IR"
  | FP_normal | FP_subnormal | FP_zero ->
    Ok (Seq [Bytes "float64"; Bytes (Printf.sprintf "%016Lx" (Int64.bits_of_float value))])

let string value = Seq [Bytes "string"; Bytes value]
let bool value = Seq [Bytes "bool"; Bytes (if value then "true" else "false")]
