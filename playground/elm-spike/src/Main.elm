port module Main exposing (main)

import Browser
import Html exposing (Html, button, div, h1, h2, h3, input, label, li, p, pre, text, textarea, ul)
import Html.Attributes exposing (attribute, for, id, rows, spellcheck, type_, value)
import Html.Events exposing (onClick, onInput)
import Json.Decode as D
import Json.Encode as E


port request : E.Value -> Cmd msg


port response : (D.Value -> msg) -> Sub msg


type alias Flags =
    { source : String }


type alias Model =
    { source : String
    , revision : Int
    , nextId : Int
    , checkId : Int
    , searchId : Int
    , searchRevision : Int
    , shareId : Int
    , query : String
    , diagnostics : List String
    , results : List Entry
    , checkStatus : String
    , searchStatus : String
    , shareStatus : String
    , error : String
    }


type alias Entry =
    { name : String, signature : String, doc : String }


type Msg
    = Edit String
    | Search String
    | Check
    | Share
    | Receive D.Value


type alias Envelope =
    { version : Int, requestId : Int, sourceRevision : Int, operation : String, payload : D.Value }


send : Int -> Int -> String -> E.Value -> Cmd Msg
send requestId revision operation payload =
    request
        (E.object
            [ ( "version", E.int 1 )
            , ( "request_id", E.int requestId )
            , ( "source_revision", E.int revision )
            , ( "operation", E.string operation )
            , ( "payload", payload )
            ]
        )


init : Flags -> ( Model, Cmd Msg )
init flags =
    ( { source = flags.source, revision = 0, nextId = 2, checkId = 1, searchId = 0, searchRevision = 0, shareId = 0
      , query = "", diagnostics = [], results = [], checkStatus = "Checking…", searchStatus = "Enter a name or type."
      , shareStatus = "", error = ""
      }
    , send 1 0 "check" (E.string flags.source)
    )


envelope : D.Decoder Envelope
envelope =
    D.map5 Envelope
        (D.field "version" D.int)
        (D.field "request_id" D.int)
        (D.field "source_revision" D.int)
        (D.field "operation" D.string)
        (D.field "payload" D.value)


diagnostic : D.Decoder String
diagnostic =
    D.map3 (\code line message -> code ++ " · line " ++ String.fromInt (line + 1) ++ ": " ++ message)
        (D.field "code" D.string)
        (D.at [ "start", "line" ] D.int)
        (D.field "message" D.string)


entry : D.Decoder Entry
entry =
    D.map3 Entry (D.field "name" D.string) (D.field "signature" D.string) (D.field "doc" D.string)


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Edit source ->
            let
                revision = model.revision + 1
            in
            ( { model | source = source, revision = revision, checkId = model.nextId, nextId = model.nextId + 1, checkStatus = "Checking…", error = "" }
            , send model.nextId revision "check" (E.string source)
            )

        Check ->
            ( { model | checkId = model.nextId, nextId = model.nextId + 1, checkStatus = "Checking…", error = "" }
            , send model.nextId model.revision "check" (E.string model.source)
            )

        Search query ->
            ( { model | query = query, searchId = model.nextId, searchRevision = model.revision, nextId = model.nextId + 1, searchStatus = "Searching…", error = "" }
            , send model.nextId model.revision "search" (E.string query)
            )

        Share ->
            ( { model | shareId = model.nextId, nextId = model.nextId + 1, shareStatus = "Preparing link…", error = "" }
            , send model.nextId model.revision "share" (E.string model.source)
            )

        Receive raw ->
            case D.decodeValue envelope raw of
                Err problem ->
                    ( { model | error = "Could not decode a compiler message: " ++ D.errorToString problem }, Cmd.none )

                Ok reply ->
                    if reply.version /= 1 then
                        ( { model | error = "Compiler bridge version mismatch. Your source is preserved." }, Cmd.none )

                    else if reply.operation == "check" && reply.requestId == model.checkId && reply.sourceRevision == model.revision then
                        case D.decodeValue (D.field "diagnostics" (D.list diagnostic)) reply.payload of
                            Ok diagnostics ->
                                ( { model | diagnostics = diagnostics, checkStatus = if List.isEmpty diagnostics then "No diagnostics." else "Compiler diagnostics", error = "" }, Cmd.none )

                            Err problem ->
                                ( { model | error = "Check failed: " ++ D.errorToString problem, checkStatus = "Check failed; retry with Check." }, Cmd.none )

                    else if reply.operation == "search" && reply.requestId == model.searchId && reply.sourceRevision == model.searchRevision then
                        case D.decodeValue (D.map2 Tuple.pair (D.field "results" (D.list entry)) (D.field "error" (D.nullable D.string))) reply.payload of
                            Ok ( results, error ) ->
                                ( { model | results = results, searchStatus = Maybe.withDefault (String.fromInt (List.length results) ++ " results shown. Proof and further capability requirements may apply.") error }, Cmd.none )

                            Err problem ->
                                ( { model | error = "Search failed: " ++ D.errorToString problem, searchStatus = "Search failed; edit the query to retry." }, Cmd.none )

                    else if reply.operation == "share" && reply.requestId == model.shareId && reply.sourceRevision == model.revision then
                        case D.decodeValue D.string reply.payload of
                            Ok url ->
                                ( { model | shareStatus = url }, Cmd.none )

                            Err problem ->
                                ( { model | error = "Share failed: " ++ D.errorToString problem }, Cmd.none )

                    else
                        -- An old reply can never rewrite the source or diagnostics.
                        ( model, Cmd.none )


view : Model -> Html Msg
view model =
    div []
        [ h1 [] [ text "Tesl · Elm feasibility screen" ]
        , p [] [ text "Experimental decision aid. The complete playground remains the supported interface." ]
        , p [ id "spike-error", attribute "role" "alert" ] [ text model.error ]
        , label [ for "spike-source" ] [ text "Tesl source" ]
        , textarea [ id "spike-source", value model.source, onInput Edit, spellcheck False, rows 14 ] []
        , button [ onClick Check ] [ text "Check" ]
        , button [ onClick Share ] [ text "Make share link" ]
        , pre [ id "spike-share", attribute "aria-live" "polite" ] [ text model.shareStatus ]
        , h2 [] [ text "Diagnostics" ]
        , p [ id "spike-check-status", attribute "role" "status" ] [ text model.checkStatus ]
        , ul [ id "spike-diagnostics" ] (List.map (\message -> li [] [ text message ]) model.diagnostics)
        , label [ for "spike-query" ] [ text "Search by name or type" ]
        , input [ id "spike-query", type_ "search", value model.query, onInput Search ] []
        , p [ id "spike-search-status", attribute "role" "status" ] [ text model.searchStatus ]
        , ul [ id "spike-results" ] (List.map (\item -> li [] [ h3 [] [ text item.name ], pre [] [ text item.signature ], p [] [ text item.doc ] ]) model.results)
        ]


main : Program Flags Model Msg
main =
    Browser.element { init = init, update = update, subscriptions = always (response Receive), view = view }
