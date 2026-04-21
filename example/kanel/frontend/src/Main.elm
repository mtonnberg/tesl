port module Main exposing (main)

{-| Kanel board frontend.

Session handling:
  - On init, flags carry the session from cookies (set by index.html on load).
  - After login, we send to the `setSession` port so index.html can set the cookie.
  - The backend reads the `kanel_user_id` cookie for auth on every request.

Board:
  - Shows a Kanban board with columns per IssueStatus.
  - Move buttons respect the same transition rules as the backend
    (nextStatuses mirrors checkTransition in KanelIssues.tesl).
-}

import Api
import Browser
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)

import Json.Decode as D
import Json.Encode as E
import Types exposing (..)


-- ── Ports ─────────────────────────────────────────────────────────────────────


{-| Write session info to cookies after login. -}
port setSession : { userId : String, displayName : String, email : String } -> Cmd msg


{-| Clear session cookies on logout. -}
port clearSession : () -> Cmd msg



-- ── Flags ─────────────────────────────────────────────────────────────────────


type alias Flags =
    { userId : String
    , displayName : String
    , email : String
    }



-- ── Model ─────────────────────────────────────────────────────────────────────


type alias Model =
    { page : Page
    , session : Maybe Session
    , error : Maybe String
    -- Login / register forms
    , loginEmail : String
    , loginPassword : String
    , registerEmail : String
    , registerPassword : String
    , registerName : String
    -- Org / project state
    , orgs : List Org
    , selectedOrg : Maybe Org
    , projects : List Project
    , selectedProject : Maybe Project
    -- Issue state
    , issues : List Issue
    , selectedIssue : Maybe Issue
    -- New org form
    , newOrgName : String
    , newOrgSlug : String
    -- New project form
    , newProjectName : String
    , newProjectDesc : String
    -- New issue form
    , newIssueTitle : String
    , newIssueDesc : String
    , newIssueEstimate : String
    -- Comments
    , comments : List IssueComment
    -- Time entries
    , timeEntries : List TimeEntry
    -- Members / Invites
    , members : List OrgMembership
    , inviteEmail : String
    , inviteRole : OrgRole
    -- Invoices
    , invoices : List Invoice
    , newInvoiceNotes : String
    -- Edit Issue form (shown on issue detail page)
    , editIssueTitle : String
    , editIssueDesc : String
    , editIssueEstimate : String
    , editIssueAssignee : String
    , editIssueActive : Bool
    -- Comment / time-entry forms
    , commentBody : String
    , timeMinutes : String
    , timeDesc : String
    }


type Page
    = LoginPage
    | RegisterPage
    | DashboardPage
    | BoardPage
    | IssuePage



-- ── Init ──────────────────────────────────────────────────────────────────────


init : Flags -> ( Model, Cmd Msg )
init flags =
    let
        session =
            if String.isEmpty flags.userId then
                Nothing

            else
                Just
                    { userId = flags.userId
                    , displayName = flags.displayName
                    , email = flags.email
                    }

        ( page, cmd ) =
            case session of
                Nothing ->
                    ( LoginPage, Cmd.none )

                Just _ ->
                    ( DashboardPage, Api.listOrgs OrgsLoaded )
    in
    ( { page = page
      , session = session
      , error = Nothing
      , loginEmail = ""
      , loginPassword = ""
      , registerEmail = ""
      , registerPassword = ""
      , registerName = ""
      , orgs = []
      , selectedOrg = Nothing
      , projects = []
      , selectedProject = Nothing
      , issues = []
      , selectedIssue = Nothing
      , newOrgName = ""
      , newOrgSlug = ""
      , newProjectName = ""
      , newProjectDesc = ""
      , newIssueTitle = ""
      , newIssueDesc = ""
      , newIssueEstimate = "0"
      , comments = []
      , timeEntries = []
      , members = []
      , inviteEmail = ""
      , inviteRole = RoleMember
      , invoices = []
      , newInvoiceNotes = ""
      , editIssueTitle = ""
      , editIssueDesc = ""
      , editIssueEstimate = ""
      , editIssueAssignee = ""
      , editIssueActive = False
      , commentBody = ""
      , timeMinutes = ""
      , timeDesc = ""
      }
    , cmd
    )



-- ── Messages ──────────────────────────────────────────────────────────────────


type Msg
    = GoTo Page
    | SetLoginEmail String
    | SetLoginPassword String
    | SubmitLogin
    | LoginResult (Result String String)
    | SetRegisterEmail String
    | SetRegisterPassword String
    | SetRegisterName String
    | SubmitRegister
    | RegisterResult (Result String String)
    | Logout
    | LoadOrgs
    | OrgsLoaded (Result String (List Org))
    | SelectOrg Org
    | SetNewOrgName String
    | SetNewOrgSlug String
    | SubmitNewOrg
    | NewOrgCreated (Result String Org)
    | ProjectsLoaded (Result String (List Project))
    | SelectProject Project
    | SetNewProjectName String
    | SetNewProjectDesc String
    | SubmitNewProject
    | NewProjectCreated (Result String Project)
    | IssuesLoaded (Result String (List Issue))
    | SelectIssue Issue
    | SetNewIssueTitle String
    | SetNewIssueDesc String
    | SetNewIssueEstimate String
    | SubmitNewIssue
    | NewIssueCreated (Result String Issue)
    | MoveIssueTo Issue IssueStatus
    | IssueStatusUpdated (Result String Issue)
    | SetCommentBody String
    | SubmitComment
    | CommentAdded (Result String IssueComment)
    | CommentsLoaded (Result String (List IssueComment))
    | TimeEntriesLoaded (Result String (List TimeEntry))
    | SetTimeMinutes String
    | SetTimeDesc String
    | SubmitTimeEntry
    | TimeEntryAdded (Result String TimeEntry)
    | DismissError
    -- Members
    | MembersLoaded (Result String (List OrgMembership))
    | SetInviteEmail String
    | SetInviteRole OrgRole
    | SubmitInviteMember
    | MemberInvited (Result String OrgMembership)
    | ChangeMemberRole String OrgRole
    | MemberRoleChanged (Result String OrgMembership)
    | RemoveMember String
    | MemberRemoved (Result String String)
    -- Invoices
    | InvoicesLoaded (Result String (List Invoice))
    | SetNewInvoiceNotes String
    | SubmitCreateInvoice
    | InvoiceCreated (Result String Invoice)
    | ApproveInvoice String
    | InvoiceApproved (Result String Invoice)
    | MarkInvoiceSent String
    | InvoiceSent (Result String Invoice)
    | MarkInvoicePaid String
    | InvoicePaid (Result String Invoice)
    -- Archive project
    | ArchiveProject Project
    | ProjectArchived (Result String Project)
    -- Edit issue
    | StartEditIssue Issue
    | CancelEditIssue
    | SetEditIssueTitle String
    | SetEditIssueDesc String
    | SetEditIssueEstimate String
    | SetEditIssueAssignee String
    | SubmitUpdateIssue
    | IssueUpdated (Result String Issue)



-- ── Update ────────────────────────────────────────────────────────────────────


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        GoTo page ->
            ( { model | page = page, error = Nothing }, Cmd.none )

        SetLoginEmail s ->
            ( { model | loginEmail = s }, Cmd.none )

        SetLoginPassword s ->
            ( { model | loginPassword = s }, Cmd.none )

        SubmitLogin ->
            ( { model | error = Nothing }
            , Api.login { email = model.loginEmail, password = model.loginPassword } LoginResult
            )

        LoginResult (Ok userId) ->
            let
                session =
                    { userId = userId
                    , displayName = model.loginEmail
                    , email = model.loginEmail
                    }
            in
            ( { model | session = Just session, page = DashboardPage }
            , Cmd.batch
                [ setSession session
                , Api.listOrgs OrgsLoaded
                ]
            )

        LoginResult (Err e) ->
            ( { model | error = Just e }, Cmd.none )

        SetRegisterEmail s ->
            ( { model | registerEmail = s }, Cmd.none )

        SetRegisterPassword s ->
            ( { model | registerPassword = s }, Cmd.none )

        SetRegisterName s ->
            ( { model | registerName = s }, Cmd.none )

        SubmitRegister ->
            ( { model | error = Nothing }
            , Api.register
                { email = model.registerEmail
                , password = model.registerPassword
                , displayName = model.registerName
                }
                RegisterResult
            )

        RegisterResult (Ok userId) ->
            -- Auto-login after registration: set up a minimal session and load orgs.
            -- The displayName will be refreshed on the next full page load.
            let
                session =
                    { userId = userId
                    , displayName = model.registerName
                    , email = model.registerEmail
                    }
            in
            ( { model
                | session = Just session
                , page = DashboardPage
                , registerEmail = ""
                , registerPassword = ""
                , registerName = ""
              }
            , Cmd.batch
                [ setSession session
                , Api.listOrgs OrgsLoaded
                ]
            )

        RegisterResult (Err e) ->
            ( { model | error = Just e }, Cmd.none )

        Logout ->
            ( { model | session = Nothing, page = LoginPage, orgs = [], selectedOrg = Nothing }
            , clearSession ()
            )

        LoadOrgs ->
            ( model, Api.listOrgs OrgsLoaded )

        OrgsLoaded (Ok orgs) ->
            ( { model | orgs = orgs }, Cmd.none )

        OrgsLoaded (Err e) ->
            ( { model | error = Just e }, Cmd.none )

        SelectOrg org ->
            ( { model | selectedOrg = Just org, selectedProject = Nothing, issues = [] }
            , Cmd.batch
                [ Api.listProjects org.id ProjectsLoaded
                , Api.listOrgMembers org.id MembersLoaded
                , Api.listInvoices org.id InvoicesLoaded
                ]
            )

        SetNewOrgName s ->
            ( { model | newOrgName = s }, Cmd.none )

        SetNewOrgSlug s ->
            ( { model | newOrgSlug = s }, Cmd.none )

        SubmitNewOrg ->
            if String.isEmpty (String.trim model.newOrgName) then
                ( { model | error = Just "Organization name is required" }, Cmd.none )

            else
                let
                    slug =
                        if String.isEmpty (String.trim model.newOrgSlug) then
                            model.newOrgName
                                |> String.toLower
                                |> String.replace " " "-"

                        else
                            model.newOrgSlug
                in
                ( { model | error = Nothing }
                , Api.createOrg { name = model.newOrgName, slug = slug } NewOrgCreated
                )

        NewOrgCreated (Ok org) ->
            ( { model
                | orgs = model.orgs ++ [ org ]
                , selectedOrg = Just org
                , newOrgName = ""
                , newOrgSlug = ""
              }
            , Api.listProjects org.id ProjectsLoaded
            )

        NewOrgCreated (Err e) ->
            ( { model | error = Just e }, Cmd.none )

        ProjectsLoaded (Ok projects) ->
            ( { model | projects = projects }, Cmd.none )

        ProjectsLoaded (Err e) ->
            ( { model | error = Just e }, Cmd.none )

        SelectProject project ->
            case model.selectedOrg of
                Nothing ->
                    ( model, Cmd.none )

                Just org ->
                    ( { model | selectedProject = Just project, page = BoardPage }
                    , Api.listIssues org.id project.id IssuesLoaded
                    )

        SetNewProjectName s ->
            ( { model | newProjectName = s }, Cmd.none )

        SetNewProjectDesc s ->
            ( { model | newProjectDesc = s }, Cmd.none )

        SubmitNewProject ->
            case model.selectedOrg of
                Nothing ->
                    ( model, Cmd.none )

                Just org ->
                    if String.isEmpty (String.trim model.newProjectName) then
                        ( { model | error = Just "Project name is required" }, Cmd.none )

                    else
                        ( { model | error = Nothing }
                        , Api.createProject org.id
                            { name = model.newProjectName
                            , description = model.newProjectDesc
                            }
                            NewProjectCreated
                        )

        NewProjectCreated (Ok project) ->
            ( { model
                | projects = model.projects ++ [ project ]
                , newProjectName = ""
                , newProjectDesc = ""
              }
            , Cmd.none
            )

        NewProjectCreated (Err e) ->
            ( { model | error = Just e }, Cmd.none )

        IssuesLoaded (Ok issues) ->
            ( { model | issues = issues }, Cmd.none )

        IssuesLoaded (Err e) ->
            ( { model | error = Just e }, Cmd.none )

        SelectIssue issue ->
            case model.selectedOrg of
                Nothing ->
                    ( { model | selectedIssue = Just issue, page = IssuePage }, Cmd.none )

                Just org ->
                    ( { model | selectedIssue = Just issue, page = IssuePage, comments = [], timeEntries = [] }
                    , Cmd.batch
                        [ Api.listComments org.id issue.id CommentsLoaded
                        , Api.listTimeEntries org.id issue.id TimeEntriesLoaded
                        ]
                    )

        SetNewIssueTitle s ->
            ( { model | newIssueTitle = s }, Cmd.none )

        SetNewIssueDesc s ->
            ( { model | newIssueDesc = s }, Cmd.none )

        SetNewIssueEstimate s ->
            ( { model | newIssueEstimate = s }, Cmd.none )

        SubmitNewIssue ->
            case ( model.selectedOrg, model.selectedProject ) of
                ( Just org, Just project ) ->
                    let
                        estimate =
                            model.newIssueEstimate |> String.toInt |> Maybe.withDefault 0
                    in
                    ( { model | error = Nothing }
                    , Api.createIssue org.id
                        project.id
                        { title = model.newIssueTitle
                        , description = model.newIssueDesc
                        , estimate = estimate
                        }
                        NewIssueCreated
                    )

                _ ->
                    ( model, Cmd.none )

        NewIssueCreated (Ok issue) ->
            ( { model
                | issues = model.issues ++ [ issue ]
                , newIssueTitle = ""
                , newIssueDesc = ""
                , newIssueEstimate = "0"
              }
            , Cmd.none
            )

        NewIssueCreated (Err e) ->
            ( { model | error = Just e }, Cmd.none )

        MoveIssueTo issue newStatus ->
            case model.selectedOrg of
                Nothing ->
                    ( model, Cmd.none )

                Just org ->
                    ( model
                    , Api.updateIssueStatus org.id issue.id newStatus IssueStatusUpdated
                    )

        IssueStatusUpdated (Ok updated) ->
            ( { model
                | issues =
                    List.map
                        (\i ->
                            if i.id == updated.id then
                                updated

                            else
                                i
                        )
                        model.issues
                , selectedIssue =
                    model.selectedIssue
                        |> Maybe.map
                            (\i ->
                                if i.id == updated.id then
                                    updated

                                else
                                    i
                            )
              }
            , Cmd.none
            )

        IssueStatusUpdated (Err e) ->
            ( { model | error = Just e }, Cmd.none )

        SetCommentBody s ->
            ( { model | commentBody = s }, Cmd.none )

        SubmitComment ->
            case ( model.selectedOrg, model.selectedIssue ) of
                ( Just org, Just issue ) ->
                    ( { model | error = Nothing }
                    , Api.addComment org.id issue.id model.commentBody CommentAdded
                    )

                _ ->
                    ( model, Cmd.none )

        CommentAdded (Ok comment) ->
            ( { model | commentBody = "", comments = model.comments ++ [ comment ] }, Cmd.none )

        CommentAdded (Err e) ->
            ( { model | error = Just e }, Cmd.none )

        CommentsLoaded (Ok comments) ->
            ( { model | comments = comments }, Cmd.none )

        CommentsLoaded (Err _) ->
            ( model, Cmd.none )

        SetTimeMinutes s ->
            ( { model | timeMinutes = s }, Cmd.none )

        SetTimeDesc s ->
            ( { model | timeDesc = s }, Cmd.none )

        SubmitTimeEntry ->
            case ( model.selectedOrg, model.selectedIssue ) of
                ( Just org, Just issue ) ->
                    let
                        minutes =
                            model.timeMinutes |> String.toInt |> Maybe.withDefault 0
                    in
                    ( { model | error = Nothing }
                    , Api.logTime org.id
                        issue.id
                        { minutes = minutes, description = model.timeDesc }
                        TimeEntryAdded
                    )

                _ ->
                    ( model, Cmd.none )

        TimeEntryAdded (Ok _) ->
            case ( model.selectedOrg, model.selectedIssue ) of
                ( Just org, Just issue ) ->
                    ( { model | timeMinutes = "", timeDesc = "" }
                    , Api.listTimeEntries org.id issue.id TimeEntriesLoaded
                    )

                _ ->
                    ( { model | timeMinutes = "", timeDesc = "" }, Cmd.none )

        TimeEntryAdded (Err e) ->
            ( { model | error = Just e }, Cmd.none )

        TimeEntriesLoaded (Ok entries) ->
            ( { model | timeEntries = entries }, Cmd.none )

        TimeEntriesLoaded (Err _) ->
            ( model, Cmd.none )

        DismissError ->
            ( { model | error = Nothing }, Cmd.none )

        MembersLoaded (Ok members) ->
            ( { model | members = members }, Cmd.none )

        MembersLoaded (Err _) ->
            ( model, Cmd.none )

        SetInviteEmail s ->
            ( { model | inviteEmail = s }, Cmd.none )

        SetInviteRole role ->
            ( { model | inviteRole = role }, Cmd.none )

        SubmitInviteMember ->
            case model.selectedOrg of
                Nothing ->
                    ( model, Cmd.none )

                Just org ->
                    ( model, Api.inviteMember org.id { email = model.inviteEmail, role = model.inviteRole } MemberInvited )

        MemberInvited (Ok membership) ->
            case model.selectedOrg of
                Nothing ->
                    ( { model | inviteEmail = "" }, Cmd.none )

                Just org ->
                    ( { model | inviteEmail = "", members = model.members ++ [ membership ] }
                    , Api.listOrgMembers org.id MembersLoaded
                    )

        MemberInvited (Err e) ->
            ( { model | error = Just e }, Cmd.none )

        ChangeMemberRole targetUserId role ->
            case model.selectedOrg of
                Nothing ->
                    ( model, Cmd.none )

                Just org ->
                    ( model, Api.changeMemberRole org.id targetUserId role MemberRoleChanged )

        MemberRoleChanged (Ok membership) ->
            ( { model | members = List.map (\m -> if m.userId == membership.userId then membership else m) model.members }
            , Cmd.none
            )

        MemberRoleChanged (Err e) ->
            ( { model | error = Just e }, Cmd.none )

        RemoveMember targetUserId ->
            case model.selectedOrg of
                Nothing ->
                    ( model, Cmd.none )

                Just org ->
                    ( model, Api.removeMember org.id targetUserId MemberRemoved )

        MemberRemoved (Ok _) ->
            case model.selectedOrg of
                Nothing ->
                    ( model, Cmd.none )

                Just org ->
                    ( model, Api.listOrgMembers org.id MembersLoaded )

        MemberRemoved (Err e) ->
            ( { model | error = Just e }, Cmd.none )

        InvoicesLoaded (Ok invoices) ->
            ( { model | invoices = invoices }, Cmd.none )

        InvoicesLoaded (Err _) ->
            ( model, Cmd.none )

        SetNewInvoiceNotes s ->
            ( { model | newInvoiceNotes = s }, Cmd.none )

        SubmitCreateInvoice ->
            case model.selectedOrg of
                Nothing ->
                    ( model, Cmd.none )

                Just org ->
                    ( model, Api.createInvoice org.id model.newInvoiceNotes InvoiceCreated )

        InvoiceCreated (Ok invoice) ->
            ( { model | invoices = model.invoices ++ [ invoice ], newInvoiceNotes = "" }, Cmd.none )

        InvoiceCreated (Err e) ->
            ( { model | error = Just e }, Cmd.none )

        ApproveInvoice invoiceId ->
            case model.selectedOrg of
                Nothing ->
                    ( model, Cmd.none )

                Just org ->
                    ( model, Api.approveInvoice org.id invoiceId InvoiceApproved )

        InvoiceApproved (Ok invoice) ->
            ( { model | invoices = List.map (\inv -> if inv.id == invoice.id then invoice else inv) model.invoices }, Cmd.none )

        InvoiceApproved (Err e) ->
            ( { model | error = Just e }, Cmd.none )

        MarkInvoiceSent invoiceId ->
            case model.selectedOrg of
                Nothing ->
                    ( model, Cmd.none )

                Just org ->
                    ( model, Api.markInvoiceSent org.id invoiceId InvoiceSent )

        InvoiceSent (Ok invoice) ->
            ( { model | invoices = List.map (\inv -> if inv.id == invoice.id then invoice else inv) model.invoices }, Cmd.none )

        InvoiceSent (Err e) ->
            ( { model | error = Just e }, Cmd.none )

        MarkInvoicePaid invoiceId ->
            case model.selectedOrg of
                Nothing ->
                    ( model, Cmd.none )

                Just org ->
                    ( model, Api.markInvoicePaid org.id invoiceId InvoicePaid )

        InvoicePaid (Ok invoice) ->
            ( { model | invoices = List.map (\inv -> if inv.id == invoice.id then invoice else inv) model.invoices }, Cmd.none )

        InvoicePaid (Err e) ->
            ( { model | error = Just e }, Cmd.none )

        ArchiveProject project ->
            case model.selectedOrg of
                Nothing ->
                    ( model, Cmd.none )

                Just org ->
                    ( model, Api.archiveProject org.id project.id ProjectArchived )

        ProjectArchived (Ok updated) ->
            ( { model
                | projects = List.map (\p -> if p.id == updated.id then updated else p) model.projects
                , selectedProject = Maybe.map (\p -> if p.id == updated.id then updated else p) model.selectedProject
              }
            , Cmd.none
            )

        ProjectArchived (Err e) ->
            ( { model | error = Just e }, Cmd.none )

        StartEditIssue issue ->
            ( { model
                | editIssueActive = True
                , editIssueTitle = issue.title
                , editIssueDesc = issue.description
                , editIssueEstimate = String.fromInt issue.estimate
                , editIssueAssignee = Maybe.withDefault "" issue.assigneeId
              }
            , Cmd.none
            )

        CancelEditIssue ->
            ( { model | editIssueActive = False }, Cmd.none )

        SetEditIssueTitle s ->
            ( { model | editIssueTitle = s }, Cmd.none )

        SetEditIssueDesc s ->
            ( { model | editIssueDesc = s }, Cmd.none )

        SetEditIssueEstimate s ->
            ( { model | editIssueEstimate = s }, Cmd.none )

        SetEditIssueAssignee s ->
            ( { model | editIssueAssignee = s }, Cmd.none )

        SubmitUpdateIssue ->
            case ( model.selectedOrg, model.selectedIssue ) of
                ( Just org, Just issue ) ->
                    let
                        est =
                            Maybe.withDefault issue.estimate (String.toInt model.editIssueEstimate)
                    in
                    ( model
                    , Api.updateIssue org.id
                        issue.id
                        { title = model.editIssueTitle
                        , description = model.editIssueDesc
                        , estimate = est
                        , assigneeId = model.editIssueAssignee
                        }
                        IssueUpdated
                    )

                _ ->
                    ( model, Cmd.none )

        IssueUpdated (Ok updated) ->
            ( { model
                | selectedIssue = Just updated
                , issues = List.map (\i -> if i.id == updated.id then updated else i) model.issues
                , editIssueActive = False
              }
            , Cmd.none
            )

        IssueUpdated (Err e) ->
            ( { model | error = Just e }, Cmd.none )



-- ── View ──────────────────────────────────────────────────────────────────────


view : Model -> Browser.Document Msg
view model =
    { title = "Kanel"
    , body =
        [ div [ id "app" ]
            [ viewHeader model
            , case model.error of
                Just err ->
                    div [ class "error-banner" ]
                        [ text err
                        , button [ onClick DismissError ] [ text "✕" ]
                        ]

                Nothing ->
                    text ""
            , case model.page of
                LoginPage ->
                    viewLogin model

                RegisterPage ->
                    viewRegister model

                DashboardPage ->
                    viewDashboard model

                BoardPage ->
                    viewBoard model

                IssuePage ->
                    viewIssuePage model
            ]
        ]
    }


viewHeader : Model -> Html Msg
viewHeader model =
    header [ class "app-header" ]
        [ span [ class "logo" ] [ text "Kanel" ]
        , nav []
            [ case model.session of
                Nothing ->
                    text ""

                Just _ ->
                    button
                        [ class "nav-btn"
                        , onClick LoadOrgs
                        , onClick (GoTo DashboardPage)
                        ]
                        [ text "Dashboard" ]
            ]
        , case model.session of
            Nothing ->
                text ""

            Just session ->
                div [ style "display" "flex", style "align-items" "center", style "gap" "12px" ]
                    [ span [ class "user-info" ] [ text session.email ]
                    , button [ class "nav-btn", onClick Logout ] [ text "Log out" ]
                    ]
        ]


viewLogin : Model -> Html Msg
viewLogin model =
    div [ class "auth-page" ]
        [ div [ class "auth-card" ]
            [ h1 [] [ text "Sign in to Kanel" ]
            , p [] [ text "Track issues. Ship projects." ]
            , div [ class "form" ]
                [ input
                    [ type_ "email"
                    , placeholder "Email"
                    , value model.loginEmail
                    , onInput SetLoginEmail
                    ]
                    []
                , input
                    [ type_ "password"
                    , placeholder "Password"
                    , value model.loginPassword
                    , onInput SetLoginPassword
                    ]
                    []
                , button [ class "primary", onClick SubmitLogin ] [ text "Sign In" ]
                , p [ class "hint" ]
                    [ text "No account? "
                    , button
                        [ style "background" "none"
                        , style "border" "none"
                        , style "color" "#0052cc"
                        , style "cursor" "pointer"
                        , style "padding" "0"
                        , style "font-size" "13px"
                        , onClick (GoTo RegisterPage)
                        ]
                        [ text "Register" ]
                    ]
                ]
            ]
        ]


viewRegister : Model -> Html Msg
viewRegister model =
    div [ class "auth-page" ]
        [ div [ class "auth-card" ]
            [ h1 [] [ text "Create account" ]
            , p [] [ text "Get started with Kanel." ]
            , div [ class "form" ]
                [ input [ type_ "text", placeholder "Display name", value model.registerName, onInput SetRegisterName ] []
                , input [ type_ "email", placeholder "Email", value model.registerEmail, onInput SetRegisterEmail ] []
                , input [ type_ "password", placeholder "Password (min 8 chars)", value model.registerPassword, onInput SetRegisterPassword ] []
                , button [ class "primary", onClick SubmitRegister ] [ text "Create Account" ]
                , p [ class "hint" ]
                    [ text "Already have an account? "
                    , button
                        [ style "background" "none"
                        , style "border" "none"
                        , style "color" "#0052cc"
                        , style "cursor" "pointer"
                        , style "padding" "0"
                        , style "font-size" "13px"
                        , onClick (GoTo LoginPage)
                        ]
                        [ text "Sign in" ]
                    ]
                ]
            ]
        ]


viewDashboard : Model -> Html Msg
viewDashboard model =
    div [ class "dashboard" ]
        [ div [ class "sidebar" ]
            [ div [ class "sidebar-section" ] [ text "Organizations" ]
            , div []
                (List.map
                    (\org ->
                        div
                            [ class
                                (if model.selectedOrg == Just org then
                                    "sidebar-item active"

                                 else
                                    "sidebar-item"
                                )
                            , onClick (SelectOrg org)
                            ]
                            [ text org.name ]
                    )
                    model.orgs
                )
            , case model.selectedOrg of
                Nothing ->
                    text ""

                Just _ ->
                    div []
                        [ hr [ class "separator", style "margin" "8px 16px" ] []
                        , div [ class "sidebar-section" ] [ text "Projects" ]
                        , div []
                            (List.map
                                (\p ->
                                    div
                                        [ class "sidebar-item project"
                                        , onClick (SelectProject p)
                                        ]
                                        [ text p.name ]
                                )
                                model.projects
                            )
                        ]
            ]
        , div [ class "main-content" ]
            [ case model.selectedOrg of
                Nothing ->
                    div []
                        [ if List.isEmpty model.orgs then
                            div []
                                [ h2 [ style "margin-bottom" "8px" ] [ text "Welcome to Kanel" ]
                                , p [ class "hint", style "margin-bottom" "20px" ]
                                    [ text "Create your first organization to get started." ]
                                ]

                          else
                            p [ class "hint", style "margin-bottom" "20px" ]
                                [ text "← Select an organization, or create a new one below." ]
                        , viewNewOrgForm model
                        ]

                Just org ->
                    div []
                        [ div [ style "display" "flex", style "align-items" "center", style "justify-content" "space-between", style "margin-bottom" "20px" ]
                            [ h2 [] [ text org.name ] ]
                        , if List.isEmpty model.projects then
                            div []
                                [ p [ class "hint", style "margin-bottom" "16px" ]
                                    [ text "No projects yet. Create your first project." ]
                                , viewNewProjectForm model
                                ]

                          else
                            div []
                                [ p [ class "hint", style "margin-bottom" "16px" ]
                                    [ text "Select a project from the sidebar, or create a new one." ]
                                , viewNewProjectForm model
                                ]
                        , div [ class "action-card", style "margin-top" "24px" ]
                            [ h3 [] [ text "Members" ]
                            , div []
                                (List.map
                                    (\m ->
                                        div [ class "member-row", style "display" "flex", style "align-items" "center", style "gap" "8px", style "margin-bottom" "6px" ]
                                            [ span [] [ text (m.userId ++ " (" ++ orgRoleLabel m.role ++ ")") ]
                                            , if m.role /= RoleAdmin then
                                                button [ class "secondary", onClick (ChangeMemberRole m.userId RoleAdmin) ] [ text "Make Admin" ]
                                              else
                                                text ""
                                            , if m.role /= RoleMember then
                                                button [ class "secondary", onClick (ChangeMemberRole m.userId RoleMember) ] [ text "Make Member" ]
                                              else
                                                text ""
                                            , button [ class "secondary", onClick (RemoveMember m.userId) ] [ text "Remove" ]
                                            ]
                                    )
                                    model.members
                                )
                            , div [ class "form", style "margin-top" "12px" ]
                                [ input
                                    [ type_ "email"
                                    , placeholder "Email to invite"
                                    , value model.inviteEmail
                                    , onInput SetInviteEmail
                                    ]
                                    []
                                , select [ onInput (\s -> SetInviteRole (if s == "admin" then RoleAdmin else RoleMember)) ]
                                    [ option [ value "member" ] [ text "Member" ]
                                    , option [ value "admin" ] [ text "Admin" ]
                                    ]
                                , button [ class "primary", onClick SubmitInviteMember ] [ text "Invite" ]
                                ]
                            ]
                        , div [ class "action-card", style "margin-top" "24px" ]
                            [ h3 [] [ text "Invoices" ]
                            , div []
                                (List.map
                                    (\inv ->
                                        div [ class "invoice-row", style "display" "flex", style "align-items" "center", style "gap" "8px", style "margin-bottom" "6px" ]
                                            [ span [] [ text (inv.id ++ " — " ++ invoiceStatusLabel inv.status ++ " — " ++ inv.notes) ]
                                            , case inv.status of
                                                Draft ->
                                                    div [ style "display" "flex", style "gap" "4px" ]
                                                        [ button [ class "secondary", onClick (ApproveInvoice inv.id) ] [ text "Approve" ]
                                                        , button [ class "secondary", onClick (MarkInvoiceSent inv.id) ] [ text "Send" ]
                                                        ]

                                                Approved ->
                                                    button [ class "secondary", onClick (MarkInvoiceSent inv.id) ] [ text "Send" ]

                                                Sent ->
                                                    button [ class "secondary", onClick (MarkInvoicePaid inv.id) ] [ text "Mark Paid" ]

                                                _ ->
                                                    text ""
                                            ]
                                    )
                                    model.invoices
                                )
                            , div [ class "form", style "margin-top" "12px" ]
                                [ textarea
                                    [ placeholder "Invoice notes"
                                    , value model.newInvoiceNotes
                                    , onInput SetNewInvoiceNotes
                                    ]
                                    []
                                , button [ class "primary", onClick SubmitCreateInvoice ] [ text "Create Invoice" ]
                                ]
                            ]
                        ]
            ]
        ]


viewNewOrgForm : Model -> Html Msg
viewNewOrgForm model =
    div [ class "new-issue-form" ]
        [ h3 [] [ text "New Organization" ]
        , div [ class "form" ]
            [ input
                [ type_ "text"
                , placeholder "Name  (e.g. Acme Corp)"
                , value model.newOrgName
                , onInput SetNewOrgName
                ]
                []
            , input
                [ type_ "text"
                , placeholder "Slug  (e.g. acme-corp — optional, auto-generated)"
                , value model.newOrgSlug
                , onInput SetNewOrgSlug
                ]
                []
            , button [ class "primary", onClick SubmitNewOrg ] [ text "Create Organization" ]
            ]
        ]


viewNewProjectForm : Model -> Html Msg
viewNewProjectForm model =
    div [ class "new-issue-form" ]
        [ h3 [] [ text "New Project" ]
        , div [ class "form" ]
            [ input
                [ type_ "text"
                , placeholder "Project name"
                , value model.newProjectName
                , onInput SetNewProjectName
                ]
                []
            , input
                [ type_ "text"
                , placeholder "Description (optional)"
                , value model.newProjectDesc
                , onInput SetNewProjectDesc
                ]
                []
            , button [ class "primary", onClick SubmitNewProject ] [ text "Create Project" ]
            ]
        ]


viewBoard : Model -> Html Msg
viewBoard model =
    let
        columns =
            [ Backlog, Todo, InProgress, InReview, Done ]

        issuesIn status =
            List.filter (\i -> i.status == status) model.issues
    in
    div [ class "main-content" ]
        [ div [ class "board-header" ]
            [ button [ class "back-btn", onClick (GoTo DashboardPage) ] [ text "← Projects" ]
            , h2 []
                [ text
                    (model.selectedProject
                        |> Maybe.map .name
                        |> Maybe.withDefault "Board"
                    )
                ]
            ]
        , div [ class "board-columns" ]
            (List.map
                (\status ->
                    div [ class "column" ]
                        [ div [ class "column-header" ]
                            [ text (issueStatusLabel status)
                            , span [ class "count" ]
                                [ text (String.fromInt (List.length (issuesIn status))) ]
                            ]
                        , div [ class "column-issues" ]
                            (List.map (viewIssueCard model) (issuesIn status))
                        ]
                )
                columns
            )
        , hr [ class "separator" ] []
        , div [ class "new-issue-form" ]
            [ h3 [] [ text "Create Issue" ]
            , div [ class "form" ]
                [ input
                    [ type_ "text"
                    , placeholder "Issue title"
                    , value model.newIssueTitle
                    , onInput SetNewIssueTitle
                    ]
                    []
                , input
                    [ type_ "text"
                    , placeholder "Description (optional)"
                    , value model.newIssueDesc
                    , onInput SetNewIssueDesc
                    ]
                    []
                , div [ class "form-row" ]
                    [ input
                        [ type_ "number"
                        , placeholder "Estimate (minutes)"
                        , value model.newIssueEstimate
                        , onInput SetNewIssueEstimate
                        , style "width" "160px"
                        ]
                        []
                    , button [ class "primary", onClick SubmitNewIssue ] [ text "Create" ]
                    ]
                ]
            ]
        ]


viewIssueCard : Model -> Issue -> Html Msg
viewIssueCard _ issue =
    div [ class "issue-card", onClick (SelectIssue issue) ]
        [ div [ class "issue-title" ] [ text issue.title ]
        , div [ class "issue-meta" ]
            [ span [ class "estimate" ]
                [ text (minutesToHours issue.estimate) ]
            ]
        , if List.isEmpty (nextStatuses issue.status) then
            text ""

          else
            div
                [ class "issue-actions"
                , stopPropagationOn "click" (D.succeed ( SelectIssue issue, False ))
                ]
                (List.map
                    (\ns ->
                        button
                            [ class "move-btn"
                            , stopPropagationOn "click"
                                (D.succeed ( MoveIssueTo issue ns, True ))
                            ]
                            [ text ("→ " ++ issueStatusLabel ns) ]
                    )
                    (nextStatuses issue.status)
                )
        ]


viewIssuePage : Model -> Html Msg
viewIssuePage model =
    case model.selectedIssue of
        Nothing ->
            div [ class "main-content" ] [ text "No issue selected." ]

        Just issue ->
            div [ class "issue-page" ]
                [ button [ class "secondary", onClick (GoTo BoardPage) ] [ text "← Back to board" ]
                , div [ class "issue-header" ]
                    [ h1 [] [ text issue.title ]
                    , span [ class "status-badge" ] [ text (issueStatusLabel issue.status) ]
                    ]
                , if String.isEmpty issue.description then
                    text ""

                  else
                    p [ class "issue-description" ] [ text issue.description ]
                , div [ class "issue-stats" ]
                    [ span [] [ text ("Estimate: " ++ minutesToHours issue.estimate) ]
                    , span [] [ text ("Reported by: " ++ issue.reporterId) ]
                    ]
                , if List.isEmpty (nextStatuses issue.status) then
                    p [ class "hint" ] [ text "This issue is closed — no further transitions." ]

                  else
                    div [ style "margin-bottom" "20px" ]
                        [ p [ class "section-title" ] [ text "Move to" ]
                        , div [ style "display" "flex", style "gap" "8px" ]
                            (List.map
                                (\ns ->
                                    button
                                        [ class "secondary"
                                        , onClick (MoveIssueTo issue ns)
                                        ]
                                        [ text (issueStatusLabel ns) ]
                                )
                                (nextStatuses issue.status)
                            )
                        ]
                , if List.isEmpty model.comments then
                    text ""

                  else
                    div [ class "action-card" ]
                        [ h3 [] [ text "Comments" ]
                        , div []
                            (List.map
                                (\c ->
                                    div [ class "comment" ]
                                        [ div [ class "comment-author" ] [ text c.authorId ]
                                        , div [ class "comment-body" ] [ text c.body ]
                                        ]
                                )
                                model.comments
                            )
                        ]
                , div [ class "action-card" ]
                    [ h3 [] [ text "Add Comment" ]
                    , div [ class "form" ]
                        [ textarea
                            [ placeholder "Write a comment…"
                            , value model.commentBody
                            , onInput SetCommentBody
                            ]
                            []
                        , button [ class "primary", onClick SubmitComment ] [ text "Post" ]
                        ]
                    ]
                , div [ class "action-card" ]
                    [ h3 [] [ text "Log Time" ]
                    , if List.isEmpty model.timeEntries then
                        text ""

                      else
                        div [ style "margin-bottom" "12px" ]
                            (List.map
                                (\te ->
                                    div [ class "comment" ]
                                        [ div [ class "comment-author" ] [ text (minutesToHours te.minutes) ]
                                        , div [ class "comment-body" ] [ text te.description ]
                                        ]
                                )
                                model.timeEntries
                            )
                    , div [ class "form" ]
                        [ div [ class "form-row" ]
                            [ input
                                [ type_ "number"
                                , placeholder "Minutes"
                                , value model.timeMinutes
                                , onInput SetTimeMinutes
                                , style "width" "120px"
                                ]
                                []
                            , input
                                [ type_ "text"
                                , placeholder "What did you work on?"
                                , value model.timeDesc
                                , onInput SetTimeDesc
                                ]
                                []
                            ]
                        , button [ class "primary", onClick SubmitTimeEntry ] [ text "Log Time" ]
                        ]
                    ]
                , div [ class "action-card" ]
                    [ h3 [] [ text "Edit Issue" ]
                    , if model.editIssueActive then
                        div [ class "form" ]
                            [ input
                                [ type_ "text"
                                , placeholder "Title"
                                , value model.editIssueTitle
                                , onInput SetEditIssueTitle
                                ]
                                []
                            , textarea
                                [ placeholder "Description"
                                , value model.editIssueDesc
                                , onInput SetEditIssueDesc
                                ]
                                []
                            , input
                                [ type_ "number"
                                , placeholder "Estimate (minutes)"
                                , value model.editIssueEstimate
                                , onInput SetEditIssueEstimate
                                ]
                                []
                            , input
                                [ type_ "text"
                                , placeholder "Assignee user ID (optional)"
                                , value model.editIssueAssignee
                                , onInput SetEditIssueAssignee
                                ]
                                []
                            , div [ style "display" "flex", style "gap" "8px" ]
                                [ button [ class "primary", onClick SubmitUpdateIssue ] [ text "Save" ]
                                , button [ class "secondary", onClick CancelEditIssue ] [ text "Cancel" ]
                                ]
                            ]

                      else
                        button [ class "secondary", onClick (StartEditIssue issue) ] [ text "Edit" ]
                    ]
                ]



-- ── Helpers ───────────────────────────────────────────────────────────────────


orgRoleLabel : OrgRole -> String
orgRoleLabel role =
    case role of
        RoleAdmin ->
            "Admin"

        RoleMember ->
            "Member"

        RoleViewer ->
            "Viewer"


invoiceStatusLabel : InvoiceStatus -> String
invoiceStatusLabel status =
    case status of
        Draft ->
            "Draft"

        Approved ->
            "Approved"

        Sent ->
            "Sent"

        Paid ->
            "Paid"

        Overdue ->
            "Overdue"




-- ── Main ──────────────────────────────────────────────────────────────────────


main : Program Flags Model Msg
main =
    Browser.document
        { init = init
        , update = update
        , view = view
        , subscriptions = \_ -> Sub.none
        }
