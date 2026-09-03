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

let () =
  test_sql_dispatch ();
  test_openapi_path ()
