module Types exposing (..)

{-| Kanel shared types — mirrors the Tesl backend data model.

All PosixMillis fields are Int (ms since epoch).  The Tesl type system ensures
timestamps are always PosixMillis on the backend; the Elm side stores them as
Int for simplicity and formats them for display.
-}

import Json.Decode as D
import Json.Encode as E


-- ── Auth ─────────────────────────────────────────────────────────────────────


type alias Session =
    { userId : String
    , displayName : String
    , email : String
    }


type alias LoginRequest =
    { email : String
    , password : String
    }


type alias RegisterRequest =
    { email : String
    , password : String
    , displayName : String
    }


-- ── Organizations ─────────────────────────────────────────────────────────────


type alias Org =
    { id : String
    , name : String
    , slug : String
    , createdAt : Int
    }


type alias OrgMembership =
    { id : String
    , orgId : String
    , userId : String
    , role : OrgRole
    , joinedAt : Int
    }


type OrgRole
    = RoleAdmin
    | RoleMember
    | RoleViewer


-- ── Projects ─────────────────────────────────────────────────────────────────


type alias Project =
    { id : String
    , orgId : String
    , name : String
    , description : String
    , archived : Bool
    , createdAt : Int
    }


-- ── Issues ───────────────────────────────────────────────────────────────────


type alias Issue =
    { id : String
    , projectId : String
    , orgId : String
    , title : String
    , description : String
    , status : IssueStatus
    , assigneeId : Maybe String
    , reporterId : String
    , estimate : Int
    , dueAt : Maybe Int
    , createdAt : Int
    , updatedAt : Int
    }


type IssueStatus
    = Backlog
    | Todo
    | InProgress
    | InReview
    | Done
    | Cancelled


type alias IssueComment =
    { id : String
    , issueId : String
    , authorId : String
    , body : String
    , createdAt : Int
    }


type alias TimeEntry =
    { id : String
    , issueId : String
    , userId : String
    , orgId : String
    , minutes : Int
    , description : String
    , invoiceId : String
    , loggedAt : Int
    }


-- ── Invoices ─────────────────────────────────────────────────────────────────


type alias Invoice =
    { id : String
    , orgId : String
    , status : InvoiceStatus
    , totalMinutes : Int
    , notes : String
    , createdAt : Int
    , approvedAt : Int
    }


type InvoiceStatus
    = Draft
    | Approved
    | Sent
    | Paid
    | Overdue


-- ── Decoders ─────────────────────────────────────────────────────────────────


decodeOrg : D.Decoder Org
decodeOrg =
    D.map4 Org
        (D.field "id" D.string)
        (D.field "name" D.string)
        (D.field "slug" D.string)
        (D.field "createdAt" D.int)


decodeOrgRole : D.Decoder OrgRole
decodeOrgRole =
    D.field "tag" D.string
        |> D.andThen
            (\tag ->
                case tag of
                    "RoleAdmin" ->
                        D.succeed RoleAdmin

                    "RoleMember" ->
                        D.succeed RoleMember

                    "RoleViewer" ->
                        D.succeed RoleViewer

                    _ ->
                        D.fail ("unknown role: " ++ tag)
            )


decodeOrgMembership : D.Decoder OrgMembership
decodeOrgMembership =
    D.map5 OrgMembership
        (D.field "id" D.string)
        (D.field "orgId" D.string)
        (D.field "userId" D.string)
        (D.field "role" decodeOrgRole)
        (D.field "joinedAt" D.int)


decodeProject : D.Decoder Project
decodeProject =
    D.map6 Project
        (D.field "id" D.string)
        (D.field "orgId" D.string)
        (D.field "name" D.string)
        (D.field "description" D.string)
        (D.field "archived" D.bool)
        (D.field "createdAt" D.int)


decodeIssueStatus : D.Decoder IssueStatus
decodeIssueStatus =
    D.field "tag" D.string
        |> D.andThen
            (\tag ->
                case tag of
                    "Backlog" ->
                        D.succeed Backlog

                    "Todo" ->
                        D.succeed Todo

                    "InProgress" ->
                        D.succeed InProgress

                    "InReview" ->
                        D.succeed InReview

                    "Done" ->
                        D.succeed Done

                    "Cancelled" ->
                        D.succeed Cancelled

                    _ ->
                        D.fail ("unknown status: " ++ tag)
            )


decodeIssue : D.Decoder Issue
decodeIssue =
    D.succeed Issue
        |> andMap (D.field "id" D.string)
        |> andMap (D.field "projectId" D.string)
        |> andMap (D.field "orgId" D.string)
        |> andMap (D.field "title" D.string)
        |> andMap (D.field "description" D.string)
        |> andMap (D.field "status" decodeIssueStatus)
        |> andMap (D.field "assigneeId" decodeMaybeString)
        |> andMap (D.field "reporterId" D.string)
        |> andMap (D.field "estimate" D.int)
        |> andMap (D.field "dueAt" decodeMaybeInt)
        |> andMap (D.field "createdAt" D.int)
        |> andMap (D.field "updatedAt" D.int)


decodeIssueComment : D.Decoder IssueComment
decodeIssueComment =
    D.map5 IssueComment
        (D.field "id" D.string)
        (D.field "issueId" D.string)
        (D.field "authorId" D.string)
        (D.field "body" D.string)
        (D.field "createdAt" D.int)


decodeTimeEntry : D.Decoder TimeEntry
decodeTimeEntry =
    D.succeed TimeEntry
        |> andMap (D.field "id" D.string)
        |> andMap (D.field "issueId" D.string)
        |> andMap (D.field "userId" D.string)
        |> andMap (D.field "orgId" D.string)
        |> andMap (D.field "minutes" D.int)
        |> andMap (D.field "description" D.string)
        |> andMap (D.field "invoiceId" D.string)
        |> andMap (D.field "loggedAt" D.int)


decodeInvoiceStatus : D.Decoder InvoiceStatus
decodeInvoiceStatus =
    D.field "tag" D.string
        |> D.andThen
            (\tag ->
                case tag of
                    "Draft" -> D.succeed Draft
                    "Approved" -> D.succeed Approved
                    "Sent" -> D.succeed Sent
                    "Paid" -> D.succeed Paid
                    "Overdue" -> D.succeed Overdue
                    _ -> D.fail ("unknown invoice status: " ++ tag)
            )


decodeInvoice : D.Decoder Invoice
decodeInvoice =
    D.succeed Invoice
        |> andMap (D.field "id" D.string)
        |> andMap (D.field "orgId" D.string)
        |> andMap (D.field "status" decodeInvoiceStatus)
        |> andMap (D.field "totalMinutes" D.int)
        |> andMap (D.field "notes" D.string)
        |> andMap (D.field "createdAt" D.int)
        |> andMap (D.field "approvedAt" D.int)


-- ── Encoders ─────────────────────────────────────────────────────────────────


encodeIssueStatus : IssueStatus -> E.Value
encodeIssueStatus status =
    -- Tesl ADTs serialize as {"tag": "ConstructorName"}
    E.object [ ( "tag", E.string <|
        case status of
            Backlog -> "Backlog"
            Todo -> "Todo"
            InProgress -> "InProgress"
            InReview -> "InReview"
            Done -> "Done"
            Cancelled -> "Cancelled"
        ) ]


encodeOrgRole : OrgRole -> E.Value
encodeOrgRole role =
    E.object [ ( "tag", E.string <|
        case role of
            RoleAdmin -> "RoleAdmin"
            RoleMember -> "RoleMember"
            RoleViewer -> "RoleViewer"
        ) ]


-- ── Helpers ──────────────────────────────────────────────────────────────────


andMap : D.Decoder a -> D.Decoder (a -> b) -> D.Decoder b
andMap da df =
    D.map2 (\f a -> f a) df da


decodeMaybeString : D.Decoder (Maybe String)
decodeMaybeString =
    D.field "tag" D.string
        |> D.andThen
            (\tag ->
                case tag of
                    "Nothing" ->
                        D.succeed Nothing

                    "Something" ->
                        D.field "fields" (D.field "value" D.string)
                            |> D.map Just

                    _ ->
                        D.fail ("unknown Maybe tag: " ++ tag)
            )


decodeMaybeInt : D.Decoder (Maybe Int)
decodeMaybeInt =
    D.field "tag" D.string
        |> D.andThen
            (\tag ->
                case tag of
                    "Nothing" ->
                        D.succeed Nothing

                    "Something" ->
                        D.field "fields" (D.field "value" D.int)
                            |> D.map Just

                    _ ->
                        D.fail ("unknown Maybe tag: " ++ tag)
            )


issueStatusLabel : IssueStatus -> String
issueStatusLabel status =
    case status of
        Backlog -> "Backlog"
        Todo -> "Todo"
        InProgress -> "In Progress"
        InReview -> "In Review"
        Done -> "Done"
        Cancelled -> "Cancelled"


nextStatuses : IssueStatus -> List IssueStatus
nextStatuses status =
    case status of
        Backlog -> [ Todo, Cancelled ]
        Todo -> [ InProgress, Backlog, Cancelled ]
        InProgress -> [ InReview, Todo ]
        InReview -> [ Done, InProgress ]
        Done -> []
        Cancelled -> [ Backlog ]


minutesToHours : Int -> String
minutesToHours minutes =
    let
        h = minutes // 60
        m = modBy 60 minutes
    in
    if h == 0 then
        String.fromInt m ++ "m"
    else if m == 0 then
        String.fromInt h ++ "h"
    else
        String.fromInt h ++ "h " ++ String.fromInt m ++ "m"
