"""Deterministic, reviewable source inputs for a twenty-release project tracker."""

RELEASES = {
    1: "Projects, Tasks and Members baseline",
    2: "Task optional priority",
    3: "Project optional color and timezone",
    4: "Member optional role",
    5: "Project name -> title",
    6: "Add Audit table",
    7: "Task metadata Retype/WriteBack: text -> text+kind",
    8: "Member optional active flag",
    9: "Project memo removal with Legacy value",
    10: "Task optional due date",
    11: "Member name -> displayName",
    12: "Project optional archived flag",
    13: "Task metadata Retype/WriteBack: body+kind+revision",
    14: "Audit optional category",
    15: "Task title proof strengthening via Revalidate",
    16: "Member optional contact",
    17: "Project timezone -> zone",
    18: "Audit event -> message",
    19: "Project externalCode and Member note added together",
    20: "Project title -> label and Member role removal together",
}
TRANSFORMS = {5, 7, 9, 11, 13, 15, 17, 18, 20}


def fields(version):
    project_name = "name" if version < 5 else "title" if version < 20 else "label"
    member_name = "name" if version < 11 else "displayName"
    result = {
        "Project": {"id": "String", project_name: "String"},
        "Task": {"id": "String", "projectId": "String", "title": "String" + (" ::: AllowedTitle title" if version >= 15 else ""), "metadata": "Metadata"},
        "Member": {"id": "String", "projectId": "String", member_name: "String"},
    }
    if version < 9:
        result["Project"]["memo"] = "String"
    if version >= 2:
        result["Task"]["priority"] = "Maybe Int"
    if version >= 3:
        result["Project"].update({"color": "Maybe String", "timezone" if version < 17 else "zone": "Maybe String"})
    if 4 <= version < 20:
        result["Member"]["role"] = "Maybe String"
    if version >= 6:
        result["Audit"] = {"id": "String", "event" if version < 18 else "message": "String"}
    if version >= 8:
        result["Member"]["active"] = "Maybe Bool"
    if version >= 10:
        result["Task"]["due"] = "Maybe String"
    if version >= 12:
        result["Project"]["archived"] = "Maybe Bool"
    if version >= 14:
        result["Audit"]["category"] = "Maybe String"
    if version >= 16:
        result["Member"]["contact"] = "Maybe String"
    if version >= 19:
        result["Project"]["externalCode"] = "Maybe String"
        result["Member"]["note"] = "Maybe String"
    return result


def schema(version):
    entities = fields(version)
    meta = {"text": "String"} if version < 7 else {"text": "String", "kind": "String"} if version < 13 else {"body": "String", "kind": "String", "revision": "Int"}
    meta_values = {"text": "text"} if version < 7 else {"text": "text", "kind": '"created"'} if version < 13 else {"body": "text", "kind": '"created"', "revision": "13"}
    exports = list(entities) + ["Metadata", "makeMetadata", "metadataText", "metadataKind", "metadataRevision", "tryTitle"] + ["make" + entity for entity in entities]
    if version >= 15:
        exports.append("AllowedTitle")
    result = ["module Schema.Tracker.VCurrent exposing [" + ", ".join(exports) + "]",
              "import Tesl.Prelude exposing [String, Int, Bool(..)]", "import Tesl.Maybe exposing [Maybe(..)]",
              "import Tesl.Json exposing [stringCodec, intCodec]",
              "record Metadata { " + ", ".join(f"{key}: {ty}" for key, ty in meta.items()) + " }",
              "codec Metadata {", "  toJson { " + ", ".join(f'{key} -> "{key}" with_codec {"intCodec" if ty == "Int" else "stringCodec"}' for key, ty in meta.items()) + " }",
              "  fromJson [ { " + ", ".join(f'{key} <- "{key}" with_codec {"intCodec" if ty == "Int" else "stringCodec"}' for key, ty in meta.items()) + " } ]", "}"]
    if version >= 15:
        result += ["fact AllowedTitle (value: String)",
                   "establish tryTitle(value: String) -> Maybe (v: String ::: AllowedTitle v) =",
                   '  if value == "" || value == "blocked" then\n    Nothing\n  else\n    Something (value ::: AllowedTitle value)']
    else:
        result += ['fn tryTitle(value: String) -> Maybe String =\n  if value == "" then\n    Nothing\n  else\n    Something value']
    for entity, members in entities.items():
        declarations = []
        for key, ty in members.items():
            if key == "metadata" and version > 7 and version != 13:
                ty += f' @column("metadata__v{7 if version < 13 else 13}")'
            declarations.append(f"{key}: {ty}")
        result.append(f'entity {entity} table "{entity.lower()}s" primaryKey id {{ ' + ", ".join(declarations) + " }")
    result += ["fn makeMetadata(text: String) -> Metadata = Metadata { " + ", ".join(f"{key}: {value}" for key, value in meta_values.items()) + " }",
               f'fn metadataText(value: Metadata) -> String = value.{"text" if version < 13 else "body"}',
               'fn metadataKind(value: Metadata) -> String = ' + ('"legacy"' if version < 7 else "value.kind"),
               'fn metadataRevision(value: Metadata) -> Int = ' + ("0" if version < 13 else "value.revision")]
    for entity, members in entities.items():
        values = {key: "Nothing" if ty.startswith("Maybe") else '"memo-kept"' for key, ty in members.items()}
        values["id"] = "id"
        if entity in ("Task", "Member"):
            values["projectId"] = "projectId"
        if entity == "Task":
            values.update(title="title", metadata="makeMetadata content")
            result += ["fn makeTask(id: String, projectId: String, rawTitle: String, content: String) -> Maybe Task =",
                       "  case tryTitle rawTitle of", "    Nothing -> Nothing",
                       "    Something title -> Something (Task { " + ", ".join(f"{key}: {value}" for key, value in values.items()) + " })"]
        else:
            name = next(key for key in members if key in ("name", "title", "label", "displayName", "event", "message"))
            values[name] = "text"
            params = "id: String, " + ("projectId: String, " if entity == "Member" else "") + "text: String"
            result.append(f"fn make{entity}({params}) -> {entity} = {entity} {{ " + ", ".join(f"{key}: {value}" for key, value in values.items()) + " }")
    return "\n".join(result) + "\n"


def migration(version):
    previous, current = f"Schema.Tracker.V{version-1}", "Schema.Tracker.VCurrent"
    before, after = fields(version-1), fields(version)
    rules = {
        5: {"Project": ["Rename name title"]}, 7: {"Task": ["Retype metadata", "WriteBack metadata metadata backward"]},
        9: {"Project": ['Legacy memo "legacy-default"']}, 11: {"Member": ["Rename name displayName"]},
        13: {"Task": ["Retype metadata", "WriteBack metadata metadata backward"]},
        15: {"Task": ["Revalidate title Schema.Tracker.VCurrent.tryTitle"]}, 17: {"Project": ["Rename timezone zone"]},
        18: {"Audit": ["Rename event message"]}, 20: {"Project": ["Rename title label"], "Member": ["LegacyWith role legacyRole"]},
    }.get(version, {})
    decisions, functions, fixtures = [], [], []
    for entity in after:
        if entity in rules:
            decisions.append(f"{entity}: Migrate convert{entity} [" + ", ".join(rules[entity]) + "]")
            values = {key: "old." + key for key in after[entity]}
            renames = {5: ("title", "name"), 11: ("displayName", "name"), 17: ("zone", "timezone"), 18: ("message", "event"), 20: ("label", "title")}
            if version in renames:
                new, old = renames[version]
                if new in values:
                    values[new] = "old." + old
            if entity == "Task" and version == 7:
                values["metadata"] = current + '.Metadata { text: old.metadata.text, kind: "migrated-v7" }'
            if entity == "Task" and version == 13:
                values["metadata"] = current + ".Metadata { body: old.metadata.text, kind: old.metadata.kind, revision: 13 }"
            if version == 15:
                values["title"] = "title"
            row = f"Row ({current}.{entity} {{ " + ", ".join(f"{key}: {value}" for key, value in values.items()) + " })"
            functions.append(f"fn convert{entity}(old: {previous}.{entity}) -> Migrated {current}.{entity} =")
            if version in (7, 13):
                functions.append('  if old.metadata.text == "blocked" then\n    Reject "metadata policy"\n  else\n    ' + row)
            elif version == 15:
                functions += ["  case Schema.Tracker.VCurrent.tryTitle old.title of", '    Nothing -> Reject "title policy"', "    Something title -> " + row]
            else:
                functions.append("  " + row)
            fixture_type = f"Maybe {previous}.{entity}" if entity == "Task" else f"{previous}.{entity}"
            args = '"fixture" "seed-project" "kept" "kept"' if entity == "Task" else '"fixture" "seed-project" "kept"' if entity == "Member" else '"fixture" "kept"'
            functions.append(f"fn fixture{entity}() -> {fixture_type} = {previous}.make{entity} {args}")
            fixtures.append("fixture" + entity)
        elif entity not in before:
            decisions.append(entity + ": New")
        else:
            added = [key for key in after[entity] if key not in before[entity]]
            if added:
                decisions.append(entity + ": Additive []")
    if version in (7, 13):
        body = f'{previous}.Metadata {{ text: row.metadata.{"text" if version == 7 else "body"}' + (", kind: row.metadata.kind" if version == 13 else "") + " }"
        functions += [f"fn backward(row: {current}.Task) -> {previous}.Metadata = {body}"]
    same = [] if version in (7, 13) else [f"Same {previous}.Metadata {current}.Metadata"]
    if version > 15:
        same.append(f"Same {previous}.AllowedTitle {current}.AllowedTitle")
    if version == 20:
        functions.append(f"fn legacyRole(row: {current}.Member) -> Maybe String = Nothing")
    return f'''module Schema.Tracker.Migrate.V{version} exposing [migration]
import Tesl.Prelude exposing [String, Int, Bool(..)]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Migration exposing [Migration, Entity(..), Rule(..), Same(..), Migrated(..)]
import {previous}
import {current}
migration = Migration {{
 from: {previous}
 to: {current}
 same: [{", ".join(same)}]
 entities: {{ {", ".join(decisions)} }}
 fixtures: [{", ".join(fixtures)}]
}}
''' + "\n".join(functions) + "\n"


def application(version):
    entities = fields(version)
    pn = "name" if version < 5 else "title" if version < 20 else "label"
    mn = "name" if version < 11 else "displayName"
    caps = ", ".join(f"dbRead {entity}, dbWrite {entity}" for entity in entities)
    exports = ", ".join(list(entities) + ["make"+entity for entity in entities] + ["makeMetadata", "tryTitle", "metadataText", "metadataKind", "metadataRevision"])
    result = f'''module App exposing [Main, TrackerServer]
import Tesl.Prelude exposing [String, Int, Bool(..), List]
import Tesl.Maybe exposing [Maybe(..)]
import Tesl.Env exposing [env, envInt, envString, envRead]
import Tesl.DB exposing [dbRead, dbWrite]
import Tesl.Database exposing [Database, Postgres, PostgresConfig, TcpConnection, MigrationConfig, Worker]
import Tesl.App exposing [App]
import Tesl.ApiTest exposing [statusOk]
import Tesl.Json exposing [stringCodec, intCodec]
import Schema.Tracker.VCurrent exposing [{exports}]
database Main = Database {{ schema: Schema.Tracker.VCurrent, migrations: Schema.Tracker.Migrate,
 backend: Postgres (PostgresConfig {{ namespace: "tracker", dbName: env "LIVED_DB", user: env "LIVED_USER", password: "",
 connection: TcpConnection {{ host: env "LIVED_HOST", port: envInt "LIVED_PORT" 5432 }},
 migrations: MigrationConfig {{ topology: Worker, controlOwner: env "LIVED_OWNER", requestRole: env "LIVED_REQUEST", workerRole: env "LIVED_WORKER", ddlConnection: env "LIVED_DDL" }} }}) }}
record NameBody {{ name: String }}
codec NameBody {{ toJson_forbidden fromJson [ {{ name <- "name" with_codec stringCodec }} ] }}
record TaskBody {{ projectId: String, title: String, content: String }}
codec TaskBody {{ toJson_forbidden fromJson [ {{ projectId <- "projectId" with_codec stringCodec, title <- "title" with_codec stringCodec, content <- "content" with_codec stringCodec }} ] }}
record ItemReply {{ id: String, name: String }}
codec ItemReply {{ toJson {{ id -> "id" with_codec stringCodec, name -> "name" with_codec stringCodec }} fromJson_forbidden }}
record TaskReply {{ id: String, projectId: String, title: String, content: String, flavor: String, revision: Int }}
codec TaskReply {{ toJson {{ id -> "id" with_codec stringCodec, projectId -> "projectId" with_codec stringCodec, title -> "title" with_codec stringCodec, content -> "content" with_codec stringCodec, flavor -> "flavor" with_codec stringCodec, revision -> "revision" with_codec intCodec }} fromJson_forbidden }}
capturer idCapture: id: String using stringCodec
fn taskReply(item: Task) -> TaskReply = TaskReply {{ id: item.id, projectId: item.projectId, title: item.title, content: metadataText item.metadata, flavor: metadataKind item.metadata, revision: metadataRevision item.metadata }}
handler get health() -> String = "ready-v{version}"
handler get project(id: String) -> ItemReply requires [dbRead Project] =
 case selectOne p from Project where p.id == id of
  Nothing -> fail 404 "project missing"
  Something p -> ItemReply {{ id: p.id, name: p.{pn} }}
handler post createProject(id: String, body: NameBody) -> ItemReply requires [dbRead Project, dbWrite Project] =
 case selectOne p from Project where p.id == id of
  Something _ -> fail 409 "project exists"
  Nothing ->
   let rows = [makeProject id body.name]
   let _ = insertMany rows in Project
   ItemReply {{ id: id, name: body.name }}
handler get member(id: String) -> ItemReply requires [dbRead Member] =
 case selectOne m from Member where m.id == id of
  Nothing -> fail 404 "member missing"
  Something m -> ItemReply {{ id: m.id, name: m.{mn} }}
handler post createMember(id: String, body: NameBody) -> ItemReply requires [dbRead Member, dbWrite Member] =
 case selectOne m from Member where m.id == id of
  Something _ -> fail 409 "member exists"
  Nothing ->
   let rows = [makeMember id "seed-project" body.name]
   let _ = insertMany rows in Member
   ItemReply {{ id: id, name: body.name }}
handler get task(id: String) -> TaskReply requires [dbRead Task] =
 case selectOne t from Task where t.id == id of
  Nothing -> fail 404 "task missing"
  Something t -> taskReply t
handler post createTask(id: String, body: TaskBody) -> TaskReply requires [dbRead Project, dbRead Task, dbWrite Task] =
 case selectOne p from Project where p.id == body.projectId of
  Nothing -> fail 404 "project missing"
  Something _ ->
   case selectOne t from Task where t.id == id of
    Something _ -> fail 409 "task exists"
    Nothing ->
     case makeTask id body.projectId body.title body.content of
      Nothing -> fail 400 "invalid title"
      Something t ->
       let rows = [t]
       let _ = insertMany rows in Task
       taskReply t
handler put editTask(id: String, body: TaskBody) -> TaskReply requires [dbRead Task, dbWrite Task] =
 case selectOne t from Task where t.id == id of
  Nothing -> fail 404 "task missing"
  Something t ->
   case tryTitle body.title of
    Nothing -> fail 400 "invalid title"
    Something title ->
     update row in Task
       where row.id == id
       set row.title = title
       set row.metadata = makeMetadata body.content
     case selectOne row from Task where row.id == id of
      Nothing -> fail 404 "task missing"
      Something row -> taskReply row
handler delete removeTask(id: String) -> String requires [dbWrite Task] =
 delete t from Task where t.id == id
 "deleted"
'''
    routes = ['get "/health" -> String']
    handlers = ["health", "project", "createProject", "member", "createMember", "task", "createTask", "editTask", "removeTask"]
    for noun, reply in (("projects", "ItemReply"), ("members", "ItemReply"), ("tasks", "TaskReply")):
        for verb in ("get", "post"):
            body = (" body body: " + ("TaskBody" if noun == "tasks" else "NameBody")) if verb == "post" else ""
            routes.append(f'{verb} "/{noun}/:id" capture id: String via idCapture{body} -> {reply}')
    routes += ['put "/tasks/:id" capture id: String via idCapture body body: TaskBody -> TaskReply', 'delete "/tasks/:id" capture id: String via idCapture -> String']
    if version >= 6:
        event = "event" if version < 18 else "message"
        result += f'''handler post createAudit(id: String, body: NameBody) -> ItemReply requires [dbWrite Audit] =
 let rows = [makeAudit id body.name]
 let _ = insertMany rows in Audit
 ItemReply {{ id: id, name: body.name }}
handler get audit(id: String) -> ItemReply requires [dbRead Audit] =
 case selectOne a from Audit where a.id == id of
  Nothing -> fail 404 "audit missing"
  Something a -> ItemReply {{ id: a.id, name: a.{event} }}
'''
        routes += ['post "/audits/:id" capture id: String via idCapture body body: NameBody -> ItemReply', 'get "/audits/:id" capture id: String via idCapture -> ItemReply']
        handlers += ["createAudit", "audit"]
    result += "api TrackerApi {\n" + "\n".join(routes) + "\n}\nserver TrackerServer for TrackerApi { " + ", ".join(handlers) + ", listenAddress Loopback }\n"
    result += f'main() -> App requires [{caps}, envRead] = App {{ database: Main, api: TrackerServer, port: envInt "LIVED_HTTP_PORT" 8098 }}\n'
    result += f'''
api-test "V{version}: retained historical data remains readable" for TrackerServer requires [{caps}, envRead] {{
 let p = get "/projects/seed-project"
 expect p.body == {{ "id": "seed-project", "name": "Original project" }}
 let m = get "/members/seed-member"
 expect m.body == {{ "id": "seed-member", "name": "Original member" }}
 let t = get "/tasks/seed-task"
 expect t.status == 200
 expect t.body.projectId == "seed-project"
 expect t.body.title == "Seed task"
 let expected = envString "LIVED_EXPECT_CONTENT" "missing-test-input"
 expect t.body.content == expected
}}
api-test "V{version}: create a new multi-table cohort through HTTP" for TrackerServer requires [{caps}] {{
 let p = post "/projects/api-v{version}" body {{ "name": "Project v{version}" }}
 expect p.status == 200
 let m = post "/members/api-v{version}" body {{ "name": "Member v{version}" }}
 expect m.status == 200
 let t = post "/tasks/api-v{version}" body {{ "projectId": "api-v{version}", "title": "Task v{version}", "content": "cohort-v{version}" }}
 expect t.status == 200
 let duplicate = post "/tasks/api-v{version}" body {{ "projectId": "api-v{version}", "title": "replacement", "content": "wrong" }}
 expect duplicate.status == 409
 let edited = put "/tasks/api-v{version}" body {{ "projectId": "api-v{version}", "title": "Updated v{version}", "content": "updated-v{version}" }}
 expect edited.status == 200
 expect edited.body.content == "updated-v{version}"
}}
api-test "V{version}: invalid requests do not mutate retained data" for TrackerServer requires [{caps}, envRead] {{
 let missing = post "/tasks/absent-v{version}" body {{ "projectId": "absent", "title": "missing project", "content": "none" }}
 expect missing.status == 404
 let bad = put "/tasks/seed-task" body {{ "projectId": "seed-project", "title": "", "content": "wrong" }}
 expect bad.status == 400
 let malformed = put "/tasks/seed-task" body {{ "projectId": "seed-project", "title": 42, "content": "wrong" }}
 expect malformed.status == 400
 let t = get "/tasks/seed-task"
 let expected = envString "LIVED_EXPECT_CONTENT" "missing-test-input"
 expect t.body.content == expected
}}
api-test "V{version}: deletion is selective and readiness reports this release" for TrackerServer requires [{caps}] {{
 let h = get "/health"
 expect h.body == "ready-v{version}"
 let made = post "/tasks/delete-v{version}" body {{ "projectId": "seed-project", "title": "temporary", "content": "temporary" }}
 expect made.status == 200
 let removed = delete "/tasks/delete-v{version}"
 expect removed.status == 200
 let missing = get "/tasks/delete-v{version}"
 expect missing.status == 404
 let retained = get "/tasks/seed-task"
 expect retained.status == 200
}}
'''
    if version >= 6:
        result += f'''api-test "V{version}: audit history and current writes coexist" for TrackerServer requires [{caps}] {{
 let old = get "/audits/seed-audit"
 expect old.body == {{ "id": "seed-audit", "name": "Original audit" }}
 let made = post "/audits/api-v{version}" body {{ "name": "Audit v{version}" }}
 expect made.status == 200
 let current = get "/audits/api-v{version}"
 expect current.body == {{ "id": "api-v{version}", "name": "Audit v{version}" }}
}}
'''
    return result
