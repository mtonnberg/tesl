open Ast

let loc = Location.dummy_loc "roadmap-test"
let var name = EVar { name; loc }

let app head args =
  List.fold_left (fun fn arg -> EApp { fn; arg; loc }) (var head) args

let test_sql_dispatch () =
  match Sql_query.parse_query_node (app "select" [var "row"; var "from"; var "Todo"]) with
  | Some (Sql_query.QuerySelect (seed, [])) ->
    assert (seed.entity = "Todo");
    assert (seed.binder = "row")
  | _ -> failwith "select query was not parsed as the canonical query node"

let test_openapi_path () =
  let return_spec = RetPlain { ty = TName { name = "String"; loc }; loc } in
  let endpoint = {
    name = "getTodo";
    method_ = GET;
    path = "/todos/:todoId";
    auth = None;
    captures = [];
    loc;
    kind = Http {
      body = None;
      body_wire_type = None;
      body_decoder = None;
      body_via = None;
      response_wire_type = Some "String";
      response_encoder = None;
      return_spec;
      has_explicit_return = true;
      has_clause_after_return = false;
    };
  } in
  let module_form = {
    module_name = "Roadmap";
    exports = [];
    imports = [];
    decls = [
      DApi { name = "TodoApi"; endpoints = [endpoint]; loc };
      DServer {
        name = "TodoServer";
        api_name = "TodoApi";
        handlers = ["getTodo"];
        session_policy = None;
        public_origin = None;
        sso_clauses = [];
        sso_session_key_env = None;
        sso_previous_key_env = None;
        after_login = None;
        session_revoked = None;
        listen_address = None;
        login_methods = None;
        password_policy_fn = None;
        trusted_proxies = [];
        health_probe_path = None;
        content_security_policy = None;
        loc;
      };
    ];
    source_file = "roadmap.tesl";
  } in
  let output = Emit_openapi.emit module_form ~server_name:"TodoServer" in
  assert (String.contains output '{');
  assert (String.length output > 0);
  assert (try ignore (Str.search_forward (Str.regexp_string "\"/todos/{todoId}\"") output 0); true
          with Not_found -> false)

let test_openapi_includes_imported_types () =
  let dir = Filename.temp_file "tesl-openapi-" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  let write name contents =
    let channel = open_out (Filename.concat dir name) in
    output_string channel contents;
    close_out channel
  in
  write "Models.tesl"
    "module Models exposing [User]\nimport Tesl.Prelude exposing [String]\nrecord User { name: String }\n";
  write "Main.tesl"
    "module Main exposing []\nimport Tesl.Prelude exposing [String]\nimport Models exposing [User]\napi Api { get \"/user\" -> User }\nserver S for Api { getUser }\n";
  let source_file = Filename.concat dir "Main.tesl" in
  let source = In_channel.with_open_text source_file In_channel.input_all in
  (match Parser.parse_module source_file source with
   | Err error -> failwith error.msg
   | Ok module_form ->
     let output = Emit_openapi.emit module_form ~server_name:"S" in
     assert (try ignore (Str.search_forward (Str.regexp_string "\"User\"") output 0); true
             with Not_found -> false));
  Sys.remove (Filename.concat dir "Models.tesl");
  Sys.remove source_file;
  Unix.rmdir dir

let () =
  test_sql_dispatch ();
  test_openapi_path ();
  test_openapi_includes_imported_types ()
