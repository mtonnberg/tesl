module Api exposing (..)

{-| HTTP API client for the Kanel backend.

All endpoints match the KanelApi definition in KanelBackend.tesl.
Timestamps (PosixMillis) are transmitted as integers (ms since epoch).
-}

import Http
import Json.Decode as D
import Json.Encode as E
import Types exposing (..)


baseUrl : String
baseUrl =
    ""  -- Same origin: backend serves both the Elm SPA and the API on port 8080


{-| Like Http.expectJson, but on non-2xx responses tries to extract the
"error" field from the JSON body so callers get the server's message. -}
expectApiJson : (Result String a -> msg) -> D.Decoder a -> Http.Expect msg
expectApiJson toMsg decoder =
    Http.expectStringResponse toMsg <|
        \response ->
            case response of
                Http.BadUrl_ url ->
                    Err ("Bad URL: " ++ url)

                Http.Timeout_ ->
                    Err "Request timed out — is the server running?"

                Http.NetworkError_ ->
                    Err "Network error — is the backend running on port 8080?"

                Http.BadStatus_ meta body ->
                    case D.decodeString (D.field "error" D.string) body of
                        Ok msg ->
                            Err msg

                        Err _ ->
                            Err ("HTTP " ++ String.fromInt meta.statusCode)

                Http.GoodStatus_ _ body ->
                    case D.decodeString decoder body of
                        Ok value ->
                            Ok value

                        Err e ->
                            Err ("Unexpected response: " ++ D.errorToString e)


-- ── Auth ─────────────────────────────────────────────────────────────────────


register : RegisterRequest -> (Result String String -> msg) -> Cmd msg
register req toMsg =
    Http.post
        { url = baseUrl ++ "/auth/register"
        , body =
            Http.jsonBody <|
                E.object
                    [ ( "email", E.string req.email )
                    , ( "password", E.string req.password )
                    , ( "displayName", E.string req.displayName )
                    ]
        -- Register returns a full KanelUser object; extract just the id.
        , expect = expectApiJson toMsg (D.field "id" D.string)
        }


login : LoginRequest -> (Result String String -> msg) -> Cmd msg
login req toMsg =
    Http.post
        { url = baseUrl ++ "/auth/login"
        , body =
            Http.jsonBody <|
                E.object
                    [ ( "email", E.string req.email )
                    , ( "password", E.string req.password )
                    ]
        , expect = expectApiJson toMsg D.string
        }



-- ── Organizations ─────────────────────────────────────────────────────────────


createOrg : { name : String, slug : String } -> (Result String Org -> msg) -> Cmd msg
createOrg req toMsg =
    Http.post
        { url = baseUrl ++ "/orgs"
        , body =
            Http.jsonBody <|
                E.object
                    [ ( "name", E.string req.name )
                    , ( "slug", E.string req.slug )
                    ]
        , expect = expectApiJson toMsg decodeOrg
        }


listOrgs : (Result String (List Org) -> msg) -> Cmd msg
listOrgs toMsg =
    Http.get
        { url = baseUrl ++ "/orgs"
        , expect = expectApiJson toMsg (D.list decodeOrg)
        }


getOrg : String -> (Result String Org -> msg) -> Cmd msg
getOrg orgId toMsg =
    Http.get
        { url = baseUrl ++ "/orgs/" ++ orgId
        , expect = expectApiJson toMsg decodeOrg
        }


listOrgMembers : String -> (Result String (List OrgMembership) -> msg) -> Cmd msg
listOrgMembers orgId toMsg =
    Http.get
        { url = baseUrl ++ "/orgs/" ++ orgId ++ "/members"
        , expect = expectApiJson toMsg (D.list decodeOrgMembership)
        }


inviteMember : String -> { email : String, role : OrgRole } -> (Result String OrgMembership -> msg) -> Cmd msg
inviteMember orgId req toMsg =
    Http.post
        { url = baseUrl ++ "/orgs/" ++ orgId ++ "/members"
        , body =
            Http.jsonBody <|
                E.object
                    [ ( "email", E.string req.email )
                    , ( "role", encodeOrgRole req.role )
                    ]
        , expect = expectApiJson toMsg decodeOrgMembership
        }


changeMemberRole : String -> String -> OrgRole -> (Result String OrgMembership -> msg) -> Cmd msg
changeMemberRole orgId targetUserId role toMsg =
    Http.request
        { method = "PUT"
        , headers = []
        , url = baseUrl ++ "/orgs/" ++ orgId ++ "/members/" ++ targetUserId ++ "/role"
        , body = Http.jsonBody <| E.object [ ( "role", encodeOrgRole role ) ]
        , expect = expectApiJson toMsg decodeOrgMembership
        , timeout = Nothing
        , tracker = Nothing
        }


removeMember : String -> String -> (Result String String -> msg) -> Cmd msg
removeMember orgId targetUserId toMsg =
    Http.request
        { method = "DELETE"
        , headers = []
        , url = baseUrl ++ "/orgs/" ++ orgId ++ "/members/" ++ targetUserId
        , body = Http.emptyBody
        , expect = expectApiJson toMsg D.string
        , timeout = Nothing
        , tracker = Nothing
        }



-- ── Projects ─────────────────────────────────────────────────────────────────


createProject : String -> { name : String, description : String } -> (Result String Project -> msg) -> Cmd msg
createProject orgId req toMsg =
    Http.post
        { url = baseUrl ++ "/orgs/" ++ orgId ++ "/projects"
        , body =
            Http.jsonBody <|
                E.object
                    [ ( "name", E.string req.name )
                    , ( "description", E.string req.description )
                    ]
        , expect = expectApiJson toMsg decodeProject
        }


listProjects : String -> (Result String (List Project) -> msg) -> Cmd msg
listProjects orgId toMsg =
    Http.get
        { url = baseUrl ++ "/orgs/" ++ orgId ++ "/projects"
        , expect = expectApiJson toMsg (D.list decodeProject)
        }


getProject : String -> String -> (Result String Project -> msg) -> Cmd msg
getProject orgId projectId toMsg =
    Http.get
        { url = baseUrl ++ "/orgs/" ++ orgId ++ "/projects/" ++ projectId
        , expect = expectApiJson toMsg decodeProject
        }


archiveProject : String -> String -> (Result String Project -> msg) -> Cmd msg
archiveProject orgId projectId toMsg =
    Http.request
        { method = "PUT"
        , headers = []
        , url = baseUrl ++ "/orgs/" ++ orgId ++ "/projects/" ++ projectId ++ "/archive"
        , body = Http.emptyBody
        , expect = expectApiJson toMsg decodeProject
        , timeout = Nothing
        , tracker = Nothing
        }



-- ── Issues ───────────────────────────────────────────────────────────────────


createIssue : String -> String -> { title : String, description : String, estimate : Int } -> (Result String Issue -> msg) -> Cmd msg
createIssue orgId projectId req toMsg =
    Http.post
        { url = baseUrl ++ "/orgs/" ++ orgId ++ "/projects/" ++ projectId ++ "/issues"
        , body =
            Http.jsonBody <|
                E.object
                    [ ( "title", E.string req.title )
                    , ( "description", E.string req.description )
                    , ( "estimate", E.int req.estimate )
                    ]
        , expect = expectApiJson toMsg decodeIssue
        }


listIssues : String -> String -> (Result String (List Issue) -> msg) -> Cmd msg
listIssues orgId projectId toMsg =
    Http.get
        { url = baseUrl ++ "/orgs/" ++ orgId ++ "/projects/" ++ projectId ++ "/issues"
        , expect = expectApiJson toMsg (D.list decodeIssue)
        }


getIssue : String -> String -> (Result String Issue -> msg) -> Cmd msg
getIssue orgId issueId toMsg =
    Http.get
        { url = baseUrl ++ "/orgs/" ++ orgId ++ "/issues/" ++ issueId
        , expect = expectApiJson toMsg decodeIssue
        }


updateIssue : String -> String -> { title : String, description : String, estimate : Int, assigneeId : String } -> (Result String Issue -> msg) -> Cmd msg
updateIssue orgId issueId req toMsg =
    Http.request
        { method = "PUT"
        , headers = []
        , url = baseUrl ++ "/orgs/" ++ orgId ++ "/issues/" ++ issueId
        , body =
            Http.jsonBody <|
                E.object
                    [ ( "title", E.string req.title )
                    , ( "description", E.string req.description )
                    , ( "estimate", E.int req.estimate )
                    , ( "assigneeId", E.string req.assigneeId )
                    ]
        , expect = expectApiJson toMsg decodeIssue
        , timeout = Nothing
        , tracker = Nothing
        }


updateIssueStatus : String -> String -> IssueStatus -> (Result String Issue -> msg) -> Cmd msg
updateIssueStatus orgId issueId newStatus toMsg =
    Http.request
        { method = "PUT"
        , headers = []
        , url = baseUrl ++ "/orgs/" ++ orgId ++ "/issues/" ++ issueId ++ "/status"
        , body =
            Http.jsonBody <|
                E.object [ ( "newStatus", encodeIssueStatus newStatus ) ]
        , expect = expectApiJson toMsg decodeIssue
        , timeout = Nothing
        , tracker = Nothing
        }


addComment : String -> String -> String -> (Result String IssueComment -> msg) -> Cmd msg
addComment orgId issueId body toMsg =
    Http.post
        { url = baseUrl ++ "/orgs/" ++ orgId ++ "/issues/" ++ issueId ++ "/comments"
        , body = Http.jsonBody <| E.object [ ( "body", E.string body ) ]
        , expect = expectApiJson toMsg decodeIssueComment
        }


listComments : String -> String -> (Result String (List IssueComment) -> msg) -> Cmd msg
listComments orgId issueId toMsg =
    Http.get
        { url = baseUrl ++ "/orgs/" ++ orgId ++ "/issues/" ++ issueId ++ "/comments"
        , expect = expectApiJson toMsg (D.list decodeIssueComment)
        }


logTime : String -> String -> { minutes : Int, description : String } -> (Result String TimeEntry -> msg) -> Cmd msg
logTime orgId issueId req toMsg =
    Http.post
        { url = baseUrl ++ "/orgs/" ++ orgId ++ "/issues/" ++ issueId ++ "/time"
        , body =
            Http.jsonBody <|
                E.object
                    [ ( "minutes", E.int req.minutes )
                    , ( "description", E.string req.description )
                    ]
        , expect = expectApiJson toMsg decodeTimeEntry
        }


listTimeEntries : String -> String -> (Result String (List TimeEntry) -> msg) -> Cmd msg
listTimeEntries orgId issueId toMsg =
    Http.get
        { url = baseUrl ++ "/orgs/" ++ orgId ++ "/issues/" ++ issueId ++ "/time"
        , expect = expectApiJson toMsg (D.list decodeTimeEntry)
        }



-- ── Invoices ─────────────────────────────────────────────────────────────────


createInvoice : String -> String -> (Result String Invoice -> msg) -> Cmd msg
createInvoice orgId notes toMsg =
    Http.post
        { url = baseUrl ++ "/orgs/" ++ orgId ++ "/invoices"
        , body = Http.jsonBody <| E.object [ ( "notes", E.string notes ) ]
        , expect = expectApiJson toMsg decodeInvoice
        }


listInvoices : String -> (Result String (List Invoice) -> msg) -> Cmd msg
listInvoices orgId toMsg =
    Http.get
        { url = baseUrl ++ "/orgs/" ++ orgId ++ "/invoices"
        , expect = expectApiJson toMsg (D.list decodeInvoice)
        }


approveInvoice : String -> String -> (Result String Invoice -> msg) -> Cmd msg
approveInvoice orgId invoiceId toMsg =
    Http.request
        { method = "PUT"
        , headers = []
        , url = baseUrl ++ "/orgs/" ++ orgId ++ "/invoices/" ++ invoiceId ++ "/approve"
        , body = Http.emptyBody
        , expect = expectApiJson toMsg decodeInvoice
        , timeout = Nothing
        , tracker = Nothing
        }


getInvoice : String -> String -> (Result String Invoice -> msg) -> Cmd msg
getInvoice orgId invoiceId toMsg =
    Http.get
        { url = baseUrl ++ "/orgs/" ++ orgId ++ "/invoices/" ++ invoiceId
        , expect = expectApiJson toMsg decodeInvoice
        }


markInvoiceSent : String -> String -> (Result String Invoice -> msg) -> Cmd msg
markInvoiceSent orgId invoiceId toMsg =
    Http.request
        { method = "PUT"
        , headers = []
        , url = baseUrl ++ "/orgs/" ++ orgId ++ "/invoices/" ++ invoiceId ++ "/send"
        , body = Http.emptyBody
        , expect = expectApiJson toMsg decodeInvoice
        , timeout = Nothing
        , tracker = Nothing
        }


markInvoicePaid : String -> String -> (Result String Invoice -> msg) -> Cmd msg
markInvoicePaid orgId invoiceId toMsg =
    Http.request
        { method = "PUT"
        , headers = []
        , url = baseUrl ++ "/orgs/" ++ orgId ++ "/invoices/" ++ invoiceId ++ "/pay"
        , body = Http.emptyBody
        , expect = expectApiJson toMsg decodeInvoice
        , timeout = Nothing
        , tracker = Nothing
        }
