(** Seam tests for the builtin-surface documentation catalog
    ({!Stdlib_docs} / {!Stdlib_docs_entries} — roadmap:
    improved_transparency_for_built_in_types).

    The catalog is drift-proof by construction ONLY under these pins:

    1. COVERAGE — every stdlib export (tesl_module_exports), every
       always-available name, and every bare gated name
       (stdlib_bare_home_module) resolves through [Stdlib_docs.lookup].
       Adding a stdlib name without documenting it fails here.
    2. RENDER — every entry renders [Ok]: a [KFunction] whose param-name count
       disagrees with its live [stdlib_env] scheme arity, a phantom entry with
       no scheme, a capability without a provider row, or a config entry
       without a schema row all surface here with the offending name.
    3. LOOKUP — the flagship queries the roadmap names (SmtpConfig, Email.send)
       return substantive Tesl signatures, and family constructors resolve to
       their family entry. *)

let all_documentable_names () : (string * string) list =
  (* (name, provenance) pairs the coverage sweep must resolve. *)
  List.concat_map (fun (m, names) -> List.map (fun n -> (n, m)) names)
    Type_system.tesl_module_exports
  @ List.map (fun n -> (n, "<always-available>"))
      Type_system.always_available_stdlib_names
  @ List.map (fun (n, m) -> (n, m)) Type_system.stdlib_bare_home_module

let t_coverage () =
  let missing =
    List.filter (fun (name, _prov) ->
      not (Stdlib_docs.family_member name) && Stdlib_docs.lookup name = [])
      (all_documentable_names ())
  in
  if missing <> [] then
    Alcotest.failf
      "%d stdlib name(s) have no Stdlib_docs entry (add rows to \
       stdlib_docs_entries.ml):\n%s"
      (List.length missing)
      (String.concat "\n"
         (List.map (fun (n, m) -> Printf.sprintf "  %-30s (%s)" n m) missing))

let t_all_entries_render () =
  let broken =
    List.filter_map (fun (en : Stdlib_docs.entry) ->
      match Stdlib_docs.render en with
      | Ok _ -> None
      | Error msg -> Some (Printf.sprintf "  %s: %s" en.name msg))
      Stdlib_docs.entries
  in
  if broken <> [] then
    Alcotest.failf "%d catalog entr(ies) fail to render:\n%s"
      (List.length broken) (String.concat "\n" broken)

let contains hay needle =
  let n = String.length needle and h = String.length hay in
  let rec go i = i + n <= h && (String.sub hay i n = needle || go (i + 1)) in
  n = 0 || go 0

let render_one name =
  match Stdlib_docs.lookup name with
  | [] -> Alcotest.failf "lookup %S returned nothing" name
  | en :: _ ->
    (match Stdlib_docs.render en with
     | Ok s -> s
     | Error m -> Alcotest.failf "render %S failed: %s" name m)

let t_smtp_config () =
  let s = render_one "SmtpConfig" in
  List.iter (fun needle ->
    if not (contains s needle) then
      Alcotest.failf "SmtpConfig signature missing %S:\n%s" needle s)
    [ "host: String"; "port: Int"; "tls: Bool"; "# optional" ]

let t_email_send () =
  let s = render_one "Email.send" in
  List.iter (fun needle ->
    if not (contains s needle) then
      Alcotest.failf "Email.send signature missing %S:\n%s" needle s)
    [ "to: String"; "subject: String"; "body: EmailBody"; "emailCap" ]

let t_function_types_come_from_checker () =
  (* String.length's rendered type must be the checker's, not hand-written. *)
  let s = render_one "String.length" in
  if not (contains s "fn String.length(") || not (contains s "-> Int") then
    Alcotest.failf "String.length signature unexpected:\n%s" s

let t_capability_render () =
  let s = render_one "emailCap" in
  if not (contains s "import Tesl.Email exposing [emailCap]") then
    Alcotest.failf "emailCap entry must name its import:\n%s" s

let t_family_lookup () =
  (match Stdlib_docs.lookup "EuropeStockholm" with
   | [ en ] when en.name = "TimeZone" -> ()
   | _ -> Alcotest.fail "EuropeStockholm must resolve to the TimeZone family");
  (match Stdlib_docs.lookup "Sek" with
   | [ en ] when en.name = "Currency" -> ()
   | _ -> Alcotest.fail "Sek must resolve to the Currency family");
  (match Stdlib_docs.lookup "Money.sek" with
   | [ en ] when en.name = "MoneyCtors" -> ()
   | _ -> Alcotest.fail "Money.sek must resolve to the MoneyCtors family")

let t_requires_suffix () =
  let s = render_one "nowMillis" in
  if not (contains s "requires [time]") then
    Alcotest.failf "nowMillis must surface its capability:\n%s" s

let t_suggestions () =
  let sugg = Stdlib_docs.suggestions "Email.snd" in
  if not (List.mem "Email.send" sugg) then
    Alcotest.failf "suggestions for 'Email.snd' must include Email.send, got: %s"
      (String.concat ", " sugg)

let t_module_surface_nonempty () =
  let empty =
    List.filter (fun m -> Stdlib_docs.module_surface m = [])
      (List.map fst Type_system.tesl_module_exports)
  in
  if empty <> [] then
    Alcotest.failf "modules with an empty doc surface: %s"
      (String.concat ", " empty)

let () =
  Alcotest.run "Stdlib-Docs"
    [ ( "seam",
        [ Alcotest.test_case "every stdlib name documented" `Quick t_coverage;
          Alcotest.test_case "every entry renders" `Quick t_all_entries_render;
          Alcotest.test_case "module surfaces non-empty" `Quick t_module_surface_nonempty;
        ] );
      ( "lookup",
        [ Alcotest.test_case "SmtpConfig fields visible" `Quick t_smtp_config;
          Alcotest.test_case "Email.send signature" `Quick t_email_send;
          Alcotest.test_case "fn types come from checker" `Quick t_function_types_come_from_checker;
          Alcotest.test_case "capability names its import" `Quick t_capability_render;
          Alcotest.test_case "family constructors resolve" `Quick t_family_lookup;
          Alcotest.test_case "capability suffix on effects" `Quick t_requires_suffix;
          Alcotest.test_case "typo suggestions" `Quick t_suggestions;
        ] );
    ]
