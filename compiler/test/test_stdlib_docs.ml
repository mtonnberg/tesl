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

let t_search_relevance () =
  let fixture = Filename.concat (Filename.dirname Sys.executable_name) "search-queries.tsv" in
  let rows = In_channel.with_open_text fixture In_channel.input_all
    |> String.split_on_char '\n'
    |> List.filter (fun s -> s <> "" && s.[0] <> '#') in
  Alcotest.(check int) "versioned query count" 20 (List.length rows);
  List.iter (fun row -> match String.split_on_char '\t' row with
    | [query; expected] ->
      let result = Builtin_search.search query in
      Alcotest.(check (option string)) query None result.error;
      let top5 = result.results |> List.filteri (fun i _ -> i < 5) |> List.map (fun e -> e.Stdlib_docs.name) in
      if not (List.mem expected top5) then
        Alcotest.failf "%s: wanted %s in top 5; got %s" query expected (String.concat ", " top5)
    | _ -> Alcotest.failf "bad relevance fixture: %s" row) rows

let t_search_type_boundaries () =
  let open Type_system in
  let matches q t = Builtin_search.matches (Builtin_search.parse_type q) t in
  let a = TVar 42 and b = TVar 99 in
  let cases = [
    "alpha-renaming", true, "x -> x", TFun (a, a);
    "repeated vs independent", false, "x -> x", TFun (a, b);
    "independent vs repeated", false, "x -> y", TFun (a, a);
    "nominal identity", false, "Int -> String", TFun (TCon "Int32", TCon "String");
    "no specialization", false, "a -> a", TFun (TCon "Int", TCon "Int");
    "argument order", false, "String -> Int -> Bool", TFun (TCon "Int", TFun (TCon "String", TCon "Bool"));
    "arity", false, "String -> Int", TFun (TCon "String", TFun (TCon "String", TCon "Int"));
    "nested application", true, "List (Maybe x) -> x", TFun (TApp (TCon "List", TApp (TCon "Maybe", a)), a);
    "nested nominal identity", false, "List (Maybe x) -> x", TFun (TApp (TCon "List", TApp (TCon "Either", a)), a);
  ] in
  List.iter (fun (name, expected, query, ty) -> Alcotest.(check bool) name expected (matches query ty)) cases;
  List.iter (fun query ->
    let result = Builtin_search.search query in
    if result.error = None then Alcotest.failf "unsupported query accepted: %s" query)
    ["String ->"; ":: (String"; ":: String)"; ":: _"; "s: String -> Int";
     "String ::: Safe -> Int"; "String -> Int requires [time]"; String.make 257 'a';
     ":: " ^ String.make 25 '(' ^ "a" ^ String.make 25 ')'];
  Alcotest.(check int) "no invented types" 0 (Builtin_search.search "UnknownNominal -> Int").total;
  Alcotest.(check int) "combined name and type" 1 (Builtin_search.search "String.length :: String -> Int").total;
  Alcotest.(check int) "unquantified scheme variables cannot become query generics" 0
    (Builtin_search.search "Dict.map :: (a -> b) -> Dict k a -> Dict k b").total;
  Alcotest.(check int) "text-only syntax excluded" 0 (Builtin_search.search "List.map :: (a -> b) -> List a -> List b").total

let t_search_metadata () =
  let entry name = match (Builtin_search.search name).results with
    | e :: _ -> e | [] -> Alcotest.failf "missing %s" name in
  let now = Builtin_search.entry_json (entry "nowMillis") in
  List.iter (fun needle -> if not (contains now needle) then Alcotest.failf "lost metadata: %s" needle)
    [ {|"capabilities":["time"]|}; {|"proofs_status":"unavailable"|} ];
  let length = Builtin_search.entry_json (entry "String.length") in
  List.iter (fun needle -> if not (contains length needle) then Alcotest.failf "lost metadata: %s" needle)
    [ {|"parameter_labels":["s"]|}; "import Tesl.String exposing [String.length]"; {|"tag":"fun"|} ];
  let map = Builtin_search.entry_json (entry "List.map") in
  List.iter (fun needle -> if not (contains map needle) then Alcotest.failf "lost unknown: %s" needle)
    [ {|"type":null|}; {|"structural_status":"text-only"|}; {|"capabilities_status":"unavailable"|}; "requires c" ];
  if not (contains (Builtin_search.entry_json (entry "Dict.map")) {|"structural_status":"incomplete-scheme"|}) then
    Alcotest.fail "the current Dict.map scheme omits its key variable from quantification; expose that limitation";
  let ids = List.map Builtin_search.id Builtin_search.entries in
  Alcotest.(check int) "unique stable IDs" (List.length ids) (List.length (List.sort_uniq compare ids));
  let e = entry "String.length" in
  let timezone = entry "europestockholm" in
  if not (List.mem "EuropeStockholm" timezone.aliases) then
    Alcotest.fail "generated aliases must be exported and participate in catalog identity";
  if Builtin_search.entry_json e = Builtin_search.entry_json {e with doc = e.doc ^ " changed"} then
    Alcotest.fail "catalog identity input ignores documentation changes";
  Alcotest.(check string) "allocation-independent type identity"
    (Builtin_search.canonical_type Type_system.(TFun (TVar 1, TVar 2)))
    (Builtin_search.canonical_type Type_system.(TFun (TVar 90, TVar 10)))

let () =
  Alcotest.run "Stdlib-Docs"
    [ ( "search",
        [ Alcotest.test_case "20 relevance queries" `Quick t_search_relevance;
          Alcotest.test_case "type boundary and malformed query suite" `Quick t_search_type_boundaries;
          Alcotest.test_case "requirements and catalog identity" `Quick t_search_metadata;
        ] );
      ( "seam",
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
