port module Main exposing (main)

{-| Application state and every view except the native editing island live here.
Ports carry versioned requests. A reply must match the pending request and, for
source operations, the current revision before it can affect the interface.
-}

import Browser
import Dict exposing (Dict)
import Guide exposing (chapters, exerciseIds, stepExample, repairFor, chapterSteps, stepTitle, nextJourneyStep)
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (on, onClick, onInput)
import Json.Decode as D
import Json.Encode as E

port request : E.Value -> Cmd msg
port response : (D.Value -> msg) -> Sub msg
port ui : E.Value -> Cmd msg
port action : (String -> msg) -> Sub msg
port progress : (D.Value -> msg) -> Sub msg

type alias Example =
    { name : String, src : String }

type alias Highlight =
    { from : Int, to : Int }

type alias Flags =
    { source : String, examples : List Example, defaultExample : Int, theme : String, query : String, linkedQuery : Bool, shared : Bool, introHidden : Bool, journeyDone : List Int, guideKey : Maybe String, highlight : Maybe Highlight, identity : String }

type alias Position =
    { line : Int, col : Int }

type alias Fix =
    { title : String, kind : String, raw : D.Value }

type alias Diagnostic =
    { code : String, severity : String, source : String, message : String, start : Position, end : Position, fix : Maybe Fix, raw : D.Value }

type alias Artifact =
    { kind : String, label : String, content : String, files : List { path : String, content : String } }

type alias Entry =
    { name : String, moduleName : String, kind : String, signature : String, doc : String, importText : Maybe String, structural : String, caps : List String, capsStatus : String }

type alias SearchExample =
    { title : String, fragment : String, symbols : List String, hash : String }

type alias SearchResult =
    { entries : List Entry, total : Int, limit : Int, mode : String, completion : Bool, error : Maybe String, examples : List SearchExample, explanation : Maybe String }

type alias Model =
    { source : String, revision : Int, nextId : Int, pending : Dict String ( Int, Int )
    , examples : List Example, example : String, theme : String, landing : Bool, highlight : Maybe Highlight
    , diagnostics : List Diagnostic, artifacts : List Artifact, activeTab : String, explanations : Dict String String
    , checkStatus : String, checkFailed : Bool, checkedRevision : Maybe Int, timing : String, bridgeError : String
    , query : String, searchOpen : Bool, searchStatus : String, searchFailed : Bool, searchResult : Maybe SearchResult
    , journey : Maybe Int, journeyLast : Int, journeyPaused : Bool, journeyDrafts : Dict Int String, journeyNext : Maybe Int, journeyDone : List Int, journeyOriginal : Maybe { source : String, example : String, highlight : Maybe Highlight }
    , shareStatus : String, copyValue : String, identity : String, editorMode : Bool, editorStatus : String, learning : Maybe { title : String, body : String, link : String }, goFile : String
    }

type Msg
    = Edit String Bool
    | Check
    | ToggleEditor
    | ToggleWelcome
    | OpenJourney
    | JourneyStep Int
    | ProgressChanged D.Value
    | ResetJourney
    | ApplyJourneyRepair
    | RestartJourneyStep
    | CloseJourney Bool
    | Learn
    | CloseLearn
    | ChooseGoFile String
    | Download
    | BuildIntent
    | ChooseExample String
    | SetTheme String
    | SetHighlight (Maybe Highlight)
    | Jump Int Diagnostic
    | Apply Int Fix
    | Explain String
    | SelectTab String
    | OpenSearch
    | CloseSearch
    | Query String
    | Composition Bool
    | RetrySearch
    | Share
    | Copy String String
    | ShareSearch
    | Receive D.Value
    | Action String

encodeHighlight : Maybe Highlight -> E.Value
encodeHighlight =
    Maybe.map (\h -> E.object [ ( "from", E.int h.from ), ( "to", E.int h.to ) ]) >> Maybe.withDefault E.null

send : String -> E.Value -> Model -> ( Model, Cmd Msg )
send operation payload model =
    ( { model | nextId = model.nextId + 1, pending = Dict.insert operation ( model.nextId, model.revision ) model.pending }
    , request (E.object
        [ ( "version", E.int 1 ), ( "request_id", E.int model.nextId ), ( "source_revision", E.int model.revision )
        , ( "operation", E.string operation ), ( "payload", payload )
        ])
    )

uiEffect : String -> E.Value -> Cmd Msg
uiEffect operation payload =
    ui (E.object [ ( "operation", E.string operation ), ( "payload", payload ) ])

check : Bool -> Model -> ( Model, Cmd Msg )
check immediate model =
    send "check" (E.object [ ( "source", E.string model.source ), ( "immediate", E.bool immediate ) ])
        { model | checkStatus = "Checking…", checkFailed = False, bridgeError = "" }

search : Model -> ( Model, Cmd Msg )
search model =
    if String.isEmpty (String.trim model.query) then
        ( { model | searchResult = Nothing, searchStatus = "Search by name, description, module or type. Try an example below.", searchFailed = False, pending = Dict.remove "search" model.pending }, uiEffect "cancel-search" E.null )
    else
        send "search" (E.string model.query) { model | searchResult = Nothing, searchStatus = "Searching…", searchFailed = False, copyValue = "" }

init : Flags -> ( Model, Cmd Msg )
init flags =
    let
        guide = flags.guideKey |> Maybe.andThen Guide.findByKey
        guideStep = Maybe.map .id guide
        exampleIndex = guide |> Maybe.map .example |> Maybe.withDefault flags.defaultExample
        source = if guide == Nothing then flags.source else List.drop exampleIndex flags.examples |> List.head |> Maybe.map .src |> Maybe.withDefault flags.source
        initial =
            { source = source, revision = 0, nextId = 1, pending = Dict.empty
            , examples = flags.examples, example = if flags.shared then "" else String.fromInt exampleIndex, theme = flags.theme, landing = not flags.shared && not flags.introHidden && guideStep == Nothing, highlight = flags.highlight
            , diagnostics = [], artifacts = [], activeTab = "ts", explanations = Dict.empty
            , checkStatus = "Loading the compiler…", checkFailed = False, checkedRevision = Nothing, timing = "", bridgeError = ""
            , query = flags.query, searchOpen = flags.linkedQuery, searchStatus = "", searchFailed = False, searchResult = Nothing
            , journey = guideStep, journeyLast = Maybe.withDefault 0 guideStep, journeyPaused = False, journeyDrafts = Dict.empty, journeyNext = Nothing, journeyDone = List.filter (\id -> List.member id exerciseIds) flags.journeyDone, journeyOriginal = Nothing
            , shareStatus = "Copy share link", copyValue = "", identity = flags.identity, editorMode = False, editorStatus = "", learning = Nothing, goFile = ""
            }
        ( checked, command ) =
            check True initial
        ( searched, searchCommand ) =
            if flags.linkedQuery then search checked else ( checked, Cmd.none )
    in
    ( searched, Cmd.batch [ command, searchCommand, uiEffect "theme" (E.string flags.theme), uiEffect "dialog" (E.bool flags.linkedQuery) ] )

position : D.Decoder Position
position =
    D.map2 Position (D.field "line" D.int) (D.field "col" D.int)

fixDecoder : D.Decoder Fix
fixDecoder =
    D.map3 Fix (D.field "title" D.string) (D.field "kind" D.string) D.value

diagnosticDecoder : D.Decoder Diagnostic
diagnosticDecoder =
    D.map8 Diagnostic (D.field "code" D.string) (D.field "severity" D.string) (D.field "source" D.string)
        (D.field "message" D.string) (D.field "start" position) (D.field "end" position)
        (D.field "fix" (D.nullable fixDecoder)) D.value

artifactDecoder : D.Decoder Artifact
artifactDecoder =
    D.map4 Artifact (D.field "kind" D.string) (D.field "label" D.string) (D.field "content" D.string)
        (D.oneOf [ D.field "files" (D.list (D.map2 (\a b -> { path = a, content = b }) (D.field "path" D.string) (D.field "content" D.string))), D.succeed [] ])

entryDecoder : D.Decoder Entry
entryDecoder =
    D.map8 (\name moduleName kind signature doc importText structural ( caps, capsStatus ) -> Entry name moduleName kind signature doc importText structural caps capsStatus)
        (D.field "name" D.string) (D.field "module" D.string) (D.field "kind" D.string) (D.field "signature" D.string)
        (D.field "doc" D.string) (D.field "import" (D.nullable D.string)) (D.field "structural_status" D.string)
        (D.field "requirements" (D.map2 Tuple.pair (D.field "capabilities" (D.list D.string)) (D.field "capabilities_status" D.string)))

searchDecoder : D.Decoder SearchResult
searchDecoder =
    D.map8 (\entries total limit mode completion error examples explanation -> SearchResult entries total limit mode completion error examples explanation)
        (D.field "results" (D.list entryDecoder)) (D.field "total" D.int) (D.field "limit" D.int) (D.field "mode" D.string)
        (D.field "completion" D.bool) (D.field "error" (D.nullable D.string))
        (D.field "examples" (D.list (D.map4 SearchExample (D.field "title" D.string) (D.field "fragment" D.string) (D.field "symbols" (D.list D.string)) (D.field "source_sha256" D.string))))
        (D.field "explanation" (D.nullable D.string))

type alias Envelope =
    { version : Int, requestId : Int, revision : Int, operation : String, payload : D.Value, error : Maybe String }

envelopeDecoder : D.Decoder Envelope
envelopeDecoder =
    D.map6 Envelope (D.field "version" D.int) (D.field "request_id" D.int) (D.field "source_revision" D.int)
        (D.field "operation" D.string) (D.field "payload" D.value) (D.field "error" (D.nullable D.string))

receive : Envelope -> Model -> ( Model, Cmd Msg )
receive reply model =
    if reply.version /= 1 then
        ( { model | bridgeError = "Compiler bridge version mismatch. Your source is preserved; retry Check or search." }, Cmd.none )
    else if Dict.get reply.operation model.pending /= Just ( reply.requestId, reply.revision ) then
        ( model, Cmd.none )
    else if List.member reply.operation [ "check", "fix", "share", "learn" ] && reply.revision /= model.revision then
        ( model, Cmd.none )
    else
        let
            current = { model | pending = Dict.remove reply.operation model.pending }
            fail message =
                ( if reply.operation == "check" then { current | checkStatus = message, checkFailed = True }
                  else if reply.operation == "search" then { current | searchStatus = message, searchFailed = True }
                  else { current | bridgeError = message, editorStatus = "" }
                , Cmd.none )
        in
        case reply.error of
            Just message -> fail message
            Nothing ->
                case reply.operation of
                    "check" ->
                        case D.decodeValue (D.map3 (\a b c -> ( a, b, c )) (D.field "diagnostics" (D.list diagnosticDecoder)) (D.field "artifacts" (D.list artifactDecoder)) (D.field "timing" D.string)) reply.payload of
                            Err error -> fail ("Invalid compiler output: " ++ D.errorToString error)
                            Ok ( diagnostics, artifacts, timing ) ->
                                let
                                    progressed = journeyProgress diagnostics { current | checkedRevision = Just current.revision, diagnostics = diagnostics, artifacts = artifacts, timing = timing, checkStatus = diagnosticStatus diagnostics, checkFailed = False
                                        , activeTab = if List.any (\a -> a.kind == model.activeTab) artifacts then model.activeTab else Maybe.withDefault "ts" (List.head artifacts |> Maybe.map .kind)
                                        }
                                    ( moved, moveCommand ) = case progressed.journeyNext of
                                        Just step -> enterJourneyStep step progressed
                                        Nothing -> ( progressed, Cmd.none )
                                    saveStars = if progressed.journeyDone /= current.journeyDone then uiEffect "journey-progress" (E.list E.int (List.filter (\step -> not (List.member step current.journeyDone)) progressed.journeyDone)) else Cmd.none
                                in
                                ( moved, Cmd.batch [moveCommand, saveStars] )
                    "learn" ->
                        case D.decodeValue (D.map3 (\a b c -> { title = a, body = b, link = c }) (D.field "title" D.string) (D.field "body" D.string) (D.field "link" D.string)) reply.payload of
                            Err error -> fail (D.errorToString error)
                            Ok explanation -> ( { current | learning = Just explanation }, uiEffect "focus" (E.string "learning") )
                    "search" ->
                        case D.decodeValue searchDecoder reply.payload of
                            Err error -> fail ("Invalid search output: " ++ D.errorToString error)
                            Ok result ->
                                ( { current | searchResult = Just result, searchStatus = searchStatus result, searchFailed = False }, Cmd.none )
                    "editor" ->
                        case D.decodeValue D.bool reply.payload of
                            Err error -> fail (D.errorToString error)
                            Ok enabled -> ( { current | editorMode = enabled, editorStatus = "", bridgeError = "" }, Cmd.none )
                    "fix" ->
                        case D.decodeValue D.string reply.payload of
                            Err error -> fail (D.errorToString error)
                            Ok source -> check True { current | source = source, revision = current.revision + 1, diagnostics = [], artifacts = [], landing = False }
                    "share" ->
                        case D.decodeValue D.string reply.payload of
                            Err error -> fail (D.errorToString error)
                            Ok message -> ( { current | shareStatus = message }, Cmd.none )
                    "copy" ->
                        case D.decodeValue (D.map2 Tuple.pair (D.field "message" D.string) (D.field "fallback" D.string)) reply.payload of
                            Err error -> fail (D.errorToString error)
                            Ok ( message, fallback ) -> ( { current | searchStatus = message, copyValue = fallback }, if fallback == "" then Cmd.none else uiEffect "select-copy" E.null )
                    _ ->
                        if String.startsWith "explain:" reply.operation then
                            case D.decodeValue D.string reply.payload of
                                Ok prose -> ( { current | explanations = Dict.insert (String.dropLeft 8 reply.operation) prose current.explanations }, Cmd.none )
                                Err error -> fail (D.errorToString error)
                        else fail "Unknown compiler bridge operation."

-- Stars recognize these bounded edits to the teaching examples, not arbitrary
-- programs or runtime behavior. Keep the requirement and its caller intact.
compactSource : String -> String
compactSource source =
    let
        relevant line =
            let trimmed = String.trim line in
            String.startsWith "#>" trimmed || String.startsWith "#=" trimmed || (not (String.startsWith "#" trimmed) && not (String.startsWith "import " trimmed))
    in
    String.lines source |> List.filter relevant |> String.join "" |> String.words |> String.join ""

exampleSource : Int -> Model -> String
exampleSource index model = List.drop index model.examples |> List.head |> Maybe.map .src |> Maybe.withDefault ""

repairApplicable : Int -> String -> Bool
repairApplicable step source =
    let repair = repairFor step in
    repair.before /= "" && List.length (String.indexes repair.before source) == 1 && (step /= 1 || not (String.contains repair.after source))

saveJourneyDraft : Model -> Model
saveJourneyDraft model =
    case model.journey of
        Just step -> { model | journeyDrafts = Dict.insert step model.source model.journeyDrafts }
        Nothing -> model

enterJourneyStep : Int -> Model -> ( Model, Cmd Msg )
enterJourneyStep step model =
    let
        saved = saveJourneyDraft model
        source = Dict.get step saved.journeyDrafts |> Maybe.withDefault (exampleSource (stepExample step) model)
        ( changed, command ) = check True { saved | journey = Just step, journeyLast = step, journeyNext = Nothing, journeyPaused = False, landing = False, source = source, example = String.fromInt (stepExample step), revision = model.revision + 1, diagnostics = [], artifacts = [], learning = Nothing, highlight = Nothing }
    in
    ( changed, Cmd.batch [ command, uiEffect "clear-fragment" E.null, uiEffect "focus" (E.string "journey-title") ] )

exerciseMatches : Int -> Model -> Bool
exerciseMatches step model =
    let
        matches index before after = compactSource model.source == compactSource (String.replace before after (exampleSource index model))
        binding fallback =
            String.lines model.source |> List.filterMap (\line -> case String.words line of
                "let" :: name :: "=" :: "check" :: _ -> Just name
                _ -> Nothing) |> List.head |> Maybe.withDefault fallback
        greetingParts = String.split "HellofromTesl!" (compactSource (exampleSource 4 model))
        greetingChanged = case greetingParts of
            [ before, after ] -> String.startsWith before (compactSource model.source) && String.endsWith after (compactSource model.source) && String.length (compactSource model.source) > String.length before + String.length after && compactSource model.source /= compactSource (exampleSource 4 model)
            _ -> False
    in
    case step of
        0 -> greetingChanged
        1 -> matches 2 "import Tesl.Prelude exposing [Int, String]" "import Tesl.Prelude exposing [Int, String]\nimport Tesl.String exposing [String.length]"
        2 -> matches 1 "invoiceLabel raw customer" ("let " ++ binding "invoice" ++ " = check checkCustomer raw customer\n  invoiceLabel " ++ binding "invoice" ++ " customer")
        4 -> List.any (\caps -> matches 5 "requires [dbRead Note]" ("requires [" ++ caps ++ "]")) ["dbWrite Note", "dbRead Note, dbWrite Note", "dbWrite Note, dbRead Note"]
        5 -> matches 6 "Money.add price shipping" ("let " ++ binding "checked" ++ " = check Money.requireSameCurrency price shipping\n  Money.add price " ++ binding "checked")
        6 -> matches 7 "speed + elapsed" "speed * elapsed"
        _ ->
            if Guide.testCommand step /= Nothing then
                let repair = repairFor step in matches (stepExample step) repair.before repair.after
            else False

journeyProgress : List Diagnostic -> Model -> Model
journeyProgress diagnostics model =
    let
        activity = if model.journeyPaused then Just model.journeyLast else model.journey
        clean = not (List.any (\d -> d.severity == "error") diagnostics)
        earned = clean && (activity |> Maybe.map (\step -> exerciseMatches step model) |> Maybe.withDefault False)
        done = if earned then Maybe.map (\step -> if List.member step model.journeyDone then model.journeyDone else step :: model.journeyDone) activity |> Maybe.withDefault model.journeyDone else model.journeyDone
    in
    { model | journeyDone = done }

update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Edit source composing ->
            let edited = { model | source = source, revision = model.revision + 1, diagnostics = [], artifacts = [], timing = "", landing = False, learning = Nothing, bridgeError = "", pending = Dict.remove "check" model.pending } in
            if composing then ( { edited | checkStatus = "Composing…" }, uiEffect "cancel-check" E.null ) else check False edited
        Check -> check True model
        OpenJourney ->
            if model.journey /= Nothing then
                ( { model | landing = False }, uiEffect "focus" (E.string "journey") )
            else if model.journeyPaused then
                ( { model | journey = Just model.journeyLast, journeyPaused = False, landing = False }, uiEffect "focus" (E.string "journey") )
            else
                enterJourneyStep model.journeyLast { model | journeyOriginal = case model.journeyOriginal of
                    Just original -> Just original
                    Nothing -> Just { source = model.source, example = model.example, highlight = model.highlight } }
        JourneyStep step ->
            if model.journey == Just step then ( model, Cmd.none )
            else if (Dict.get "fix" model.pending |> Maybe.map (Tuple.second >> (==) model.revision)) == Just True then ( { model | journeyNext = Just step }, Cmd.none )
            else if Dict.member "check" model.pending then check True { model | journeyNext = Just step }
            else enterJourneyStep step model
        ApplyJourneyRepair ->
            case model.journey of
                Nothing -> ( model, Cmd.none )
                Just step ->
                    let repair = repairFor step in
                    if not (repairApplicable step model.source) then ( model, Cmd.none )
                    else check True { model | source = String.replace repair.before repair.after model.source, revision = model.revision + 1, diagnostics = [], artifacts = [] }
        RestartJourneyStep ->
            case model.journey of
                Nothing -> ( model, Cmd.none )
                Just step -> enterJourneyStep step { model | journey = Nothing, journeyDrafts = Dict.remove step model.journeyDrafts }
        ProgressChanged raw ->
            case D.decodeValue (D.list D.int) raw of
                Ok steps -> ( { model | journeyDone = List.filter (\step -> List.member step steps) exerciseIds }, Cmd.none )
                Err _ -> ( model, Cmd.none )
        ResetJourney -> ( { model | journeyDone = [] }, uiEffect "journey-reset" E.null )
        CloseJourney restore ->
            case ( restore, model.journeyOriginal ) of
                ( True, Just original ) -> check True { model | source = original.source, example = original.example, highlight = original.highlight, revision = model.revision + 1, diagnostics = [], artifacts = [], learning = Nothing, journey = Nothing, journeyPaused = False, journeyNext = Nothing, journeyDrafts = Dict.empty, journeyOriginal = Nothing }
                _ ->
                    let saved = saveJourneyDraft model in
                    ( { saved | journey = Nothing, journeyPaused = True, journeyNext = Nothing }, uiEffect "focus" (E.string "journey-resume") )
        ToggleWelcome -> ( { model | landing = not model.landing }, uiEffect "welcome" (E.bool (not model.landing)) )
        Download -> ( model, uiEffect "download" (E.string model.source) )
        BuildIntent -> ( model, uiEffect "milestone" (E.string "install_intent") )
        Learn -> send "learn" (E.string model.source) model
        CloseLearn -> ( { model | learning = Nothing }, uiEffect "focus" (E.string "learn-selection") )
        ChooseGoFile path -> ( { model | goFile = path }, Cmd.none )
        ToggleEditor -> send "editor" (E.bool (not model.editorMode)) { model | editorStatus = "Switching editor…", bridgeError = "" }
        ChooseExample selected ->
            case String.toInt selected |> Maybe.andThen (\index -> List.head (List.drop index model.examples)) of
                Nothing -> ( model, Cmd.none )
                Just example ->
                    let saved = saveJourneyDraft model
                        ( changed, command ) = check True { saved | journey = Nothing, journeyPaused = False, journeyNext = Nothing, source = example.src, revision = model.revision + 1, example = selected, learning = Nothing, landing = False, highlight = Nothing, diagnostics = [], artifacts = [] } in
                    ( changed, Cmd.batch [ command, uiEffect "clear-fragment" E.null ] )
        SetTheme theme -> ( { model | theme = theme }, uiEffect "theme" (E.string theme) )
        SetHighlight highlight -> ( { model | highlight = highlight }, Cmd.none )
        Jump index diagnostic -> ( model, uiEffect "jump" (E.object [ ( "start", encodePosition diagnostic.start ), ( "end", encodePosition diagnostic.end ), ( "index", E.int index ) ]) )
        Apply revision fix ->
            if revision /= model.revision then ( model, Cmd.none ) else send "fix" (E.object [ ( "source", E.string model.source ), ( "fix", fix.raw ) ]) model
        Explain code ->
            if Dict.member code model.explanations then ( model, Cmd.none ) else send ("explain:" ++ code) (E.string code) model
        SelectTab kind -> ( { model | activeTab = kind }, uiEffect "focus" (E.string ("tab-" ++ kind)) )
        OpenSearch ->
            let ( changed, command ) = search { model | searchOpen = True } in
            ( changed, Cmd.batch [ command, uiEffect "dialog" (E.bool True) ] )
        CloseSearch ->
            ( { model | searchOpen = False, pending = Dict.remove "search" model.pending }, Cmd.batch [ uiEffect "cancel-search" E.null, uiEffect "dialog" (E.bool False) ] )
        Query query -> search { model | query = query }
        Composition composing ->
            if composing then ( { model | pending = Dict.remove "search" model.pending }, uiEffect "cancel-search" E.null ) else search model
        RetrySearch -> search model
        Share -> send "share" (E.object [ ( "source", E.string model.source ), ( "highlight", encodeHighlight model.highlight ) ]) { model | shareStatus = "Preparing link…" }
        ShareSearch -> send "copy" (E.object [ ( "query", E.string model.query ) ]) model
        Copy value message -> send "copy" (E.object [ ( "text", E.string value ), ( "message", E.string message ) ]) model
        Receive raw ->
            case D.decodeValue envelopeDecoder raw of
                Err error -> ( { model | bridgeError = "Could not decode a compiler message: " ++ D.errorToString error }, Cmd.none )
                Ok reply -> receive reply model
        Action command ->
            case command of
                "search" -> update OpenSearch model
                "close-search" -> update CloseSearch model
                "check" -> update Check model
                "learn" -> update Learn model
                _ -> ( model, Cmd.none )

encodePosition : Position -> E.Value
encodePosition pos = E.object [ ( "line", E.int pos.line ), ( "col", E.int pos.col ) ]

diagnosticStatus : List Diagnostic -> String
diagnosticStatus diagnostics =
    let
        count severity = List.filter (\d -> d.severity == severity) diagnostics |> List.length
        label severity = String.fromInt (count severity) ++ " " ++ severity ++ (if count severity == 1 then "" else "s")
    in
    if List.isEmpty diagnostics then "All checks passed"
    else if count "error" + count "warning" == 0 then String.fromInt (List.length diagnostics) ++ " notes"
    else List.filter (\severity -> count severity > 0) [ "error", "warning" ] |> List.map label |> String.join ", "

searchStatus : SearchResult -> String
searchStatus result =
    case result.error of
        Just error -> error
        Nothing ->
            if result.explanation /= Nothing then "Diagnostic explanation from this compiler."
            else if result.total == 0 then "No results yet. Try a few words about what you want to do, or shorten the name. For a type query, keep the argument order. Some entries are only searchable by name."
            else String.fromInt result.total ++ " results" ++ (if result.total > result.limit then "; showing the first " ++ String.fromInt result.limit else "") ++ ". "
                ++ (if result.completion then "Completions for an unfinished type; keep typing to narrow the results. Requirements still apply."
                    else if result.mode == "type" then "Exact type shapes; requirements still apply." else "Matches by name or description.")

btn : String -> String -> Msg -> Html Msg
btn identifier caption message = button [ id identifier, class "btn", onClick message ] [ text caption ]

diagnosticSummary : Diagnostic -> String
diagnosticSummary diagnostic =
    if diagnostic.code == "V001" && String.contains "uses privileged operations and callees requiring [" diagnostic.message && String.contains "but does not declare them" diagnostic.message then
        let
            capabilities = String.split "requiring [" diagnostic.message |> List.drop 1 |> List.head |> Maybe.map (String.split "]" >> List.head >> Maybe.withDefault "") |> Maybe.withDefault ""
        in
        "Missing capability: declare [" ++ capabilities ++ "] in the requires clause."
    else if diagnostic.code == "V001" && String.contains "does not statically satisfy declared proof" diagnostic.message then
        "This value needs a check before it can be used here."
    else
        Maybe.map .title diagnostic.fix |> Maybe.withDefault diagnostic.message

viewDiagnostic : Model -> Int -> Diagnostic -> Html Msg
viewDiagnostic model index diagnostic =
    let
        location = String.fromInt (diagnostic.start.line + 1) ++ ":" ++ String.fromInt (diagnostic.start.col + 1) ++ "–" ++ String.fromInt (diagnostic.end.line + 1) ++ ":" ++ String.fromInt (diagnostic.end.col + 1)
    in
    li [ class ("diag " ++ diagnostic.severity) ]
        [ button [ class "diag-jump", onClick (Jump index diagnostic), attribute "aria-label" (diagnostic.severity ++ " " ++ diagnostic.code ++ " at line " ++ String.fromInt (diagnostic.start.line + 1) ++ ", column " ++ String.fromInt (diagnostic.start.col + 1) ++ ": " ++ diagnostic.message) ]
            [ span [ class "sev" ] [ text diagnostic.severity ], code [ class "code" ] [ text diagnostic.code ], span [ class "loc" ] [ text location ], span [ class "src-tag" ] [ text diagnostic.source ] ]
        , p [ class "diagnostic-guide" ] [ text (diagnosticSummary diagnostic) ]
        , if diagnostic.code == "V001" || diagnostic.fix /= Nothing then
            details [ class "diagnostic-details" ] [ summary [] [ text "Compiler details" ], p [ class "msg" ] [ text diagnostic.message ] ]
          else text ""
        , details [ class "explain", on "toggle" (D.field "target" (D.field "open" D.bool) |> D.andThen (\opened -> if opened then D.succeed (Explain diagnostic.code) else D.fail "closed")) ]
            [ summary [] [ text ("Explain " ++ diagnostic.code) ], pre [] [ text (Dict.get diagnostic.code model.explanations |> Maybe.withDefault "Loading explanation…") ] ]
        , case diagnostic.fix of
            Nothing -> text ""
            Just fix -> div [ class "fix" ] [ span [ class "title" ] [ text fix.title ], span [ class "kind" ] [ text fix.kind ], button [ class "btn", onClick (Apply model.revision fix), attribute "aria-label" ("Apply fix: " ++ fix.title) ] [ text "Apply" ] ]
        ]

viewArtifacts : Model -> Html Msg
viewArtifacts model =
    let
        kinds = List.map .kind model.artifacts
        neighbor kind delta =
            let index = List.indexedMap Tuple.pair kinds |> List.filter (Tuple.second >> (==) kind) |> List.head |> Maybe.map Tuple.first |> Maybe.withDefault 0 in
            List.drop (modBy (Basics.max 1 (List.length kinds)) (index + delta)) kinds |> List.head |> Maybe.withDefault kind
        tab artifact =
            button [ id ("tab-" ++ artifact.kind), attribute "role" "tab", attribute "aria-controls" ("panel-" ++ artifact.kind), attribute "aria-selected" (if artifact.kind == model.activeTab then "true" else "false"), tabindex (if artifact.kind == model.activeTab then 0 else -1), onClick (SelectTab artifact.kind)
                , on "keydown" (D.field "key" D.string |> D.andThen (\key -> if List.member key [ "ArrowLeft", "ArrowRight" ] then D.succeed (SelectTab (neighbor artifact.kind (if key == "ArrowLeft" then -1 else 1))) else D.fail "other key")) ] [ text artifact.label ]
        panel artifact =
            let chosen = List.filter (\file -> file.path == model.goFile) artifact.files |> List.head |> Maybe.withDefault (List.head artifact.files |> Maybe.withDefault { path = "", content = artifact.content }) in
            div [ id ("panel-" ++ artifact.kind), attribute "role" "tabpanel", attribute "aria-labelledby" ("tab-" ++ artifact.kind), hidden (artifact.kind /= model.activeTab) ]
                [ if artifact.kind == "go" then div [ class "go-project" ]
                    [ p [] [ text "These are the generated project files. The CLI also supplies the Go runtime, then builds and runs the project. Runtime library sources are not included in this preview." ]
                    , label [ for "go-file" ] [ text "Project file" ]
                    , select [ id "go-file", value chosen.path, onInput ChooseGoFile ] (List.map (\file -> option [ value file.path ] [ text file.path ]) artifact.files)
                    ] else text ""
                , pre [] [ text (if artifact.kind == "go" then chosen.content else artifact.content) ]
                ]
    in
    div [ id "artifacts" ]
        (if List.isEmpty model.artifacts then [] else
            [ details [ class "generated-details" ]
                [ summary [] [ text "See generated code" ]
                , div [ class "tabs" ] (div [ class "tablist", attribute "role" "tablist", attribute "aria-label" "Generated code" ] (List.map tab model.artifacts) :: List.map panel model.artifacts)
                ]
            ])

viewLearning : Model -> Html Msg
viewLearning model =
    case model.learning of
        Nothing -> text ""
        Just explanation ->
            aside [ id "learning", class "learning-card", tabindex -1, attribute "aria-label" "Explain this" ]
                [ div [ class "next-actions" ] [ h2 [] [ text explanation.title ], btn "close-learning" "Close" CloseLearn ]
                , p [] [ text explanation.body ]
                , a [ href explanation.link, target "_blank", rel "noopener" ] [ text "Learn more in the guide ↗" ]
                , p [ class "success-next" ] [ text "Local language guide, chosen from your selection or current line. No AI request is sent." ]
                ]

viewEntry : List SearchExample -> Entry -> Html Msg
viewEntry examples entry =
    let
        matchingExamples = List.filter (\example -> List.member entry.name example.symbols) examples
        link example = a [ class "search-example", href ("index.html#" ++ example.fragment), target "_blank", rel "noopener", title ("Open checked source in a new tab. Source SHA-256: " ++ example.hash) ] [ text (example.title ++ " ↗") ]
    in
    li [ class "search-card", tabindex -1 ]
        [ h3 [] [ text entry.name ]
        , p [ class "search-meta" ] [ text ((if entry.moduleName == "" then "Always available" else entry.moduleName) ++ " · " ++ entry.kind) ]
        , pre [] [ text entry.signature ], p [] [ text entry.doc ]
        , details [ class "search-requirements" ] [ summary [] [ text "Requirements & safety details" ], p [] [ text ("Direct capabilities: " ++ (if List.isEmpty entry.caps then "none listed" else String.join ", " entry.caps) ++ (if entry.capsStatus == "unavailable" then " (metadata incomplete; see signature)" else "") ++ ". Proof requirements: not indexed.") ] ]
        , p [ class "search-meta" ] [ text (if entry.structural == "text-only" then "Signature sketch. Available through text lookup; no structured type scheme yet." else if entry.structural == "incomplete-scheme" then "Available through text lookup. This compiler scheme has incomplete generic-variable metadata, so type matching is unavailable." else "") ]
        , case entry.importText of
            Just recipe -> pre [ class "search-import" ] [ text recipe ]
            Nothing -> p [ class "search-meta" ] [ text (if entry.moduleName == "" then "No import required." else "Import recipe unavailable; consult the signature and lessons.") ]
        , div [ class "search-actions" ]
            ((case entry.importText of
                Nothing -> []
                Just recipe -> [ button [ class "btn", onClick (Copy recipe "Import copied.") ] [ text "Copy import" ] ])
             ++ (if List.isEmpty matchingExamples then [ a [ href "lessons.html", target "_blank", rel "noopener" ] [ text "Browse lessons ↗" ] ] else List.map link matchingExamples))
        ]

viewSearch : Model -> Html Msg
viewSearch model =
    node "dialog" [ id "search-dialog", attribute "aria-labelledby" "search-title" ]
        [ div [ class "search-heading" ] [ h2 [ id "search-title" ] [ text "Find your next building block" ], btn "search-close" "Close" CloseSearch ]
        , label [ for "search-query" ] [ text "A name, a few words, or a type" ]
        , input [ id "search-query", type_ "search", autocomplete False, spellcheck False, attribute "aria-describedby" "search-help", value model.query
                , on "input" (D.map2 Tuple.pair (D.at [ "target", "value" ] D.string) (D.oneOf [ D.field "isComposing" D.bool, D.succeed False ]) |> D.map (\( query, composing ) -> if composing then Composition True else Query query))
                , on "compositionstart" (D.succeed (Composition True)), on "compositionend" (D.at [ "target", "value" ] D.string |> D.map Query) ] []
        , p [ id "search-help", class "search-help" ] [ text "Try “leading whitespace”, String.length, or Float -> Float. You can also look up a diagnostic code such as V001." ]
        , div [ class "search-suggestions" ] (List.map (\query -> button [ class "btn", attribute "data-query" query, onClick (Query query) ] [ text query ]) [ "String -> Int", "Float ->", "Dict k v -> List k", "leading whitespace", "V001" ])
        , details [ class "search-help" ]
            [ summary [] [ text "Type syntax and keyboard shortcuts" ]
            , p [] [ text "Complete types match exact shape with consistent variable renaming. Unfinished suffixes such as Float -> or Float -> F show labelled completions. Application binds before →; arrows associate right. No specialization, proof or capability filters. Proof and callback requirements are not fully indexed." ]
            , p [] [ text "Arrow Down/Up browses results; Tab reaches actions; Escape closes. Ctrl/Cmd + K opens search." ] ]
        , p [ id "search-status", attribute "role" "status", attribute "aria-live" "polite", attribute "aria-atomic" "true" ] [ text model.searchStatus ]
        , button [ id "search-retry", class "btn", hidden (not model.searchFailed), onClick RetrySearch ] [ text "Retry search" ]
        , btn "search-share" "Copy search link" ShareSearch
        , input [ id "search-copy-value", readonly True, hidden (model.copyValue == ""), value model.copyValue, attribute "aria-label" "Text to copy" ] []
        , p [ class "search-help" ] [ text "Queries stay local. Search links include your query and any source already in the URL. Examples open in a new tab." ]
        , ul [ id "search-results", attribute "aria-label" "Search results" ]
            (case model.searchResult of
                Nothing -> []
                Just result ->
                    case result.explanation of
                        Just prose -> [ li [ class "search-card", tabindex -1 ] [ h3 [] [ text (String.trim model.query) ], pre [] [ text prose ] ] ]
                        Nothing -> List.map (viewEntry result.examples) result.entries)
        , p [ id "search-version" ] [ text model.identity ]
        ]

runtimeDeclarations : String -> String
runtimeDeclarations source =
    let
        lines = String.lines source |> List.map String.trimLeft
        declares prefix = List.any (String.startsWith (prefix ++ " ")) lines
    in
    if List.any (\line -> String.startsWith "api-test " line || String.startsWith "load-test " line) lines && not (List.any (String.startsWith "main(") lines) then ""
    else
    [ ( "server", "a server" ), ( "api", "an API" ), ( "handler", "HTTP handlers" ), ( "queue", "queue workers" ), ( "worker", "queue workers" ), ( "channel", "an SSE channel" ), ( "sseChannel", "an SSE channel" ) ]
        |> List.filter (Tuple.first >> declares) |> List.map Tuple.second |> String.join ", "

view : Model -> Html Msg
view model =
    let
        runtime = runtimeDeclarations model.source
        moduleName = String.lines model.source |> List.map String.words |> List.filter (\words -> List.head words == Just "module") |> List.head |> Maybe.andThen (List.drop 1 >> List.head) |> Maybe.map (\name -> name ++ ".tesl") |> Maybe.withDefault "source"
    in
    div [ id "workbench" ]
        [ a [ class "skip", href "#results" ] [ text "Skip to the diagnostics" ]
        , header []
            [ div [ class "brand" ] [ span [ class "mark", attribute "aria-hidden" "true" ] [ text ":::" ], h1 [] [ text "Tesl ", span [ class "sub" ] [ text "playground" ] ] ]
            , p [ class "tagline" ] [ text "A place to explore what you can build with Tesl. ", span [ class "privacy-badge" ] [ text "Private by default · checked in your browser" ] ]
            , div [ class "controls" ]
                [ label [ class "visually-hidden", for "examples" ] [ text "Example" ]
                , select [ id "examples", value model.example, onInput ChooseExample ] (option [ value "", disabled True, selected (model.example == "") ] [ text "Shared source" ] :: (List.indexedMap Tuple.pair model.examples |> List.sortBy (\( index, _ ) -> if index == 4 then -1 else index) |> List.map (\( index, example ) -> option [ value (String.fromInt index), selected (model.example == String.fromInt index) ] [ text example.name ])))
                , btn "search-open" "Search builtins" OpenSearch
                , button [ id "share", class "btn share-primary", onClick Share ] [ text model.shareStatus ]
                , a [ class "btn", id "run-locally", href "start.html#install", target "_blank", rel "noopener", onClick BuildIntent ] [ text "Install Tesl" ]
                , details [ id "tools", class "tools-menu" ]
                    [ summary [ class "btn" ] [ text "More" ]
                    , div [ class "tools-content" ]
                        [ btn "download" "Save .tesl" Download
                        , btn "editor-mode" (if model.editorMode then "Use simple editor" else "Use IDE editor") ToggleEditor
                        , btn "welcome-toggle" (if model.landing then "Hide introduction" else "Show introduction") ToggleWelcome
                        , button [ id "journey-menu", class "btn", disabled (model.journey /= Nothing), onClick OpenJourney ] [ text "Explore with a guide" ]
                        , a [ id "lessons-link", href "lessons.html", target "_blank", rel "noopener" ] [ text "All lessons →" ]
                        , fieldset [ class "seg", id "theme" ] (legend [] [ text "Theme" ] :: List.map (\theme -> label [] [ input [ type_ "radio", name "theme", value theme, checked (model.theme == theme), onClick (SetTheme theme) ] [], span [] [ text (String.toUpper (String.left 1 theme) ++ String.dropLeft 1 theme) ] ]) [ "system", "light", "dark" ])
                        ]
                    ]
                , button [ id "compiler-retry", class "btn", hidden (not model.checkFailed), onClick Check ] [ text "Retry compiler load" ]
                ]
            ]
        , p [ id "editor-status", attribute "role" "status", hidden (model.editorStatus == "") ] [ text model.editorStatus ]
        , p [ id "bridge-error", attribute "role" "alert", hidden (model.bridgeError == "") ] [ text model.bridgeError ]
        , viewSearch model
        , viewWelcome model
        , main_ []
            [ section [ class "pane pane-editor", attribute "aria-label" "Editor" ]
                [ div [ class "pane-head" ] [ span [ id "modname" ] [ text moduleName ], span [ class "grow" ] [], btn "learn-selection" "Explain this" Learn, btn "check" "Check" Check, span [ id "linecount" ] [ text (String.fromInt (List.length (String.lines model.source)) ++ " lines") ] ]
                , node "tesl-editor"
                    [ property "state" (E.object [ ( "source", E.string model.source ), ( "diagnostics", E.list .raw model.diagnostics ), ( "highlight", encodeHighlight model.highlight ) ])
                    , on "source-edit" (D.field "detail" (D.map2 Edit (D.field "source" D.string) (D.field "composing" D.bool)))
                    , on "check-now" (D.succeed Check)
                    , on "learn-this" (D.succeed Learn)
                    , on "apply-fix" (D.field "detail" fixDecoder |> D.map (Apply model.revision))
                    , on "highlight-lines" (D.field "detail" (D.nullable (D.map2 Highlight (D.field "from" D.int) (D.field "to" D.int))) |> D.map SetHighlight)
                    ] []
                , p [ id "editor-hint", class "visually-hidden" ] [ text "Plain text editor. The program is re-checked as you type; results appear in the diagnostics panel. Tab moves focus." ]
                ]
            , section [ class "pane pane-results", id "results", attribute "aria-label" "Diagnostics and generated code", tabindex -1 ]
                [ div [ class "pane-head" ] [ span [] [ text "Your feedback" ], span [ class "grow" ] [], if model.journey == Nothing then btn "journey-resume" (if model.journeyPaused then "Resume guide" else "Explore with a guide") OpenJourney else text "", span [ id "timing", class "timing" ] [ text model.timing ] ]
                , div [ class "results-body" ]
                    [ viewJourney model
                    , viewLearning model
                    , div [ class "statusbar", attribute "aria-live" "polite", classList [ ( "is-clean", model.checkStatus == "All checks passed" ), ( "has-errors", not (List.isEmpty model.diagnostics) ) ] ] [ span [ id "status" ] [ text model.checkStatus ] ]
                    , if model.journey == Nothing && List.isEmpty model.diagnostics && model.checkStatus == "All checks passed" then
                        div [ class "success-card" ]
                            [ span [ class "success-icon", attribute "aria-hidden" "true" ] [ text "✓" ]
                            , h2 [] [ text "Your code passes the compiler’s checks" ]
                            , p [] [ text "You can keep exploring here, share what you’ve made, or save the source to try it on your own machine." ]
                            , div [ class "next-actions" ]
                                [ a [ class "btn build-cta", id "build-tesl", href "start.html", target "_blank", rel "noopener", onClick BuildIntent ] [ text "Build with Tesl →" ]
                                , btn "success-share" "Share this example" Share
                                ]
                            , p [ class "success-next" ] [ text "Still exploring? ", a [ href "lessons.html", target "_blank", rel "noopener" ] [ text "Pick a short lesson" ], text ", ", a [ id "random-lesson", href "random.html", target "_blank", rel "noopener" ] [ text "surprise me with one" ], text ", or ", button [ class "text-button", id "success-search", onClick OpenSearch ] [ text "find a useful function" ], text "." ]
                            ]
                      else text ""
                    , aside [ id "runnote", class "banner note", attribute "role" "note", hidden (runtime == "") ]
                        [ p [] [ strong [] [ text "To run this locally" ], text " — this source declares ", span [ id "runnote-what" ] [ text runtime ], text ", which this browser checks without starting. After saving the file, run ", code [] [ text ("tesl run " ++ moduleName) ], text ". ", a [ href "start.html", target "_blank", rel "noopener" ] [ text "Installation and run guide →" ] ] ]
                    , ul [ id "diags", class "diags" ] (List.indexedMap (viewDiagnostic model) model.diagnostics)
                    , p [ class "community-help" ] [ text "Stuck on something? ", a [ href "https://github.com/mtonnberg/tesl/discussions", target "_blank", rel "noopener" ] [ text "Ask us in Discussions" ], text " — questions from newcomers are welcome." ]
                    , viewArtifacts model
                    , p [ class "cannot" ] [ text "This page runs the real Tesl compiler compiled to JavaScript. It checks one buffer: other local modules cannot resolve; Tesl.* imports are compiled in. Nothing you type leaves the browser. Share links carry source in the URL fragment, which is never sent to a server." ]
                    ]
                ]
            ]
        ]

viewJourney : Model -> Html Msg
viewJourney model =
    case model.journey of
        Nothing -> text ""
        Just step ->
            let
                steps = chapterSteps step
                completed = List.member step model.journeyDone
                checking = Dict.member "check" model.pending
                currentComplete = model.checkedRevision == Just model.revision && not model.checkFailed && not (List.any (\d -> d.severity == "error") model.diagnostics) && exerciseMatches step model
                progressText =
                    if step == 3 then String.fromInt (List.length model.journeyDone) ++ " of " ++ String.fromInt (List.length exerciseIds) ++ " steps completed"
                    else if checking then "Checking your edit…"
                    else if completed && currentComplete then
                        if Guide.testCommand step /= Nothing then "★ Test added and compiler-checked · run it locally below" else "★ Step completed"
                    else if completed then "★ Completed earlier; your star is saved."
                    else "Apply the suggested edit, or try your own change in the editor."
                stepNumber = List.indexedMap Tuple.pair steps |> List.filter (\( _, index ) -> index == step) |> List.head |> Maybe.map (Tuple.first >> (+) 1) |> Maybe.withDefault 1
                diagram labels = div [ class "journey-flow", attribute "aria-label" "How the pieces connect" ] (List.intersperse (span [ attribute "aria-hidden" "true", class "flow-arrow" ] [ text "→" ]) (List.map (\( label, explanation ) -> details [ class "flow-detail" ] [ summary [ class "flow-node", title explanation ] [ text label, span [ class "flow-help", attribute "aria-hidden" "true" ] [ text " ⓘ" ] ], p [] [ text explanation ] ]) labels))
                content =
                    case step of
                        0 ->
                            [ p [] [ text "Change the greeting in hello. The route connects a request to that handler; its result becomes the response." ]
                            , diagram [ ( "GET /hello", "The api declaration describes the public route and response type. Client generation can use that contract without reading the implementation." ), ( "hello()", "Why separate the handler from the API? The API says what callers can ask for; the handler says how to answer. The server declaration connects them and the compiler checks that they fit. You can change the implementation while keeping the public contract." ), ( "A greeting", "The handler returns a String. The server turns that result into an HTTP response when you run it locally." ) ]
                            ]
                        1 ->
                            [ p [] [ text "String.length is missing an import. The compiler finds the right module and offers an edit to bring it into scope." ]
                            , diagram [ ( "Missing import", "The name exists in the standard library but is not in scope here." ), ( "Useful diagnostic", "A source location and stable diagnostic code identify the problem; this diagnostic also includes an edit." ), ( "Apply the fix", "Apply changes the source and asks the compiler to check it again. You can undo the edit." ) ]
                            ]
                        2 ->
                            [ p [] [ text "An invoice can belong to another customer. Add the check that invoiceLabel requires before it will accept this value." ]
                            , diagram [ ( "Invoice + customer", "A valid invoice identifier does not establish that it belongs to the requested customer." ), ( "checkCustomer", "This function compares the customer and returns evidence tied to these values. Its implementation still needs correct logic and tests." ), ( "invoiceLabel", "The function requires that evidence. A caller passing an unchecked invoice is rejected by the compiler." ) ]
                            ]
                        4 ->
                            [ p [] [ text "publishNote declares read access, but its helper writes. Give the caller the write capability its helper requires." ]
                            , diagram [ ( "publishNote", "This caller currently declares only dbRead Note. Calling another function does not bypass its capability boundary." ), ( "saveNote", "The helper declares dbWrite Note. Its callers must provide that capability, even when they do not use insert directly." ), ( "insert Note", "A write to Note requires dbWrite Note. Capabilities can distinguish operations and resources; they do not replace authentication or your access policy." ) ]
                            , details [] [ summary [] [ text "What does this unlock?" ], p [] [ text "You can keep read-only paths read-only as helpers evolve, inspect a function’s required privileges at its boundary, and narrow access to particular resources. An innocent-looking helper call cannot silently expand the caller’s declared privileges." ] ]
                            ]
                        5 ->
                            [ p [] [ text "Price and shipping may use different currencies. Check that they match before adding them." ]
                            , diagram [ ( "Two amounts", "Money stores exact integer minor units and carries its currency. An amount is more than a number." ), ( "Check currency", "Money.requireSameCurrency checks these particular values at runtime and returns evidence when they match." ), ( "Add safely", "The compiler requires that evidence at Money.add. A currency conversion is a separate, explicit operation." ) ]
                            ]
                        6 ->
                            [ p [] [ text "How far did you travel? Multiply speed by elapsed time; the compiler checks that the result is a length." ]
                            , diagram [ ( "Speed", "Speed has the dimension length divided by time. Unit constructors convert to the standard internal representation." ), ( "× Duration", "Multiplying by time cancels the time dimension. The compiler checks this relationship in the expression." ), ( "Length", "The result matches the declared return type. The dimension checks happen at compile time." ) ]
                            ]
                        7 ->
                            [ p [] [ text "Use an ordinary test when you know the input and expected result. Add a lower-boundary case beside the existing in-range example." ]
                            , diagram [ ( "Input: −3", "Choose a concrete edge case, not only a typical input." ), ( "clamp", "The same function used by the application is called by the test." ), ( "Expect 0", "The assertion is evaluated when tesl test runs locally. Type-checking alone does not prove it passes." ) ]
                            ]
                        11 ->
                            [ p [] [ text "Keep runnable examples beside the function they explain. Add a zero case to double’s documentation; tesl test checks that each example produces its expected result." ]
                            , diagram [ ( "#> double 0", "A #> line above a function gives an expression for the test runner to evaluate." ), ( "#= 0", "The following #= line gives the expected result. Together these two documentation lines form a doctest." ), ( "Run with tests", "tesl test runs doctests alongside ordinary tests, so an outdated documentation example can fail the test run." ) ]
                            ]
                        8 ->
                            [ p [] [ text "Fuzz / property tests explore generated inputs. Tesl expresses them as property blocks inside a test with a run count. Add the rule that clamping twice gives the same result." ]
                            , diagram [ ( "Generated Int", "The test runner generates integer inputs for n. You can also use filters or custom generators." ), ( "Apply a property", "Idempotence means repeating the operation changes nothing: clamp (clamp n) equals clamp n." ), ( "100 runs", "A passing sample increases confidence; it is not a proof about every possible input." ) ]
                            ]
                        9 ->
                            [ p [] [ text "API tests exercise routing and HTTP responses through a local harness. Add a request for an unknown route and check that it returns 404." ]
                            , diagram [ ( "GET /missing", "The test harness sends a request to GreetingServer. No deployed server is needed." ), ( "Route dispatch", "API tests exercise the request/response boundary, beyond a direct function call." ), ( "Expect 404", "Assertions can inspect response status and body; larger examples can also seed database state." ) ]
                            ]
                        10 ->
                            [ p [] [ text "Load tests ask how the service behaves under a steady workload. Add a p95 latency budget alongside the error-rate check." ]
                            , diagram [ ( "10 requests/s", "The load harness schedules a steady arrival rate while earlier requests may still be running." ), ( "Measure locally", "Warm-up happens before the measurement window and can take up to 30 seconds. These are in-process measurements, not a production capacity estimate." ), ( "p95 < 500 ms", "At least 95% of measured latencies must be below the budget. Choose realistic budgets for your own application." ) ]
                            ]
                        _ ->
                            [ p [] [ text "Run this greeting server on your computer and send a request to /hello. The run guide walks you through it." ]
                            , diagram [ ( "Save .tesl", "Download the source currently in your editor." ), ( "tesl run", "The installed CLI builds and starts the application using the Go runtime." ), ( "GET /hello", "Send an HTTP request to your local server to see the greeting. Browser compiler checks alone do not verify a running server." ) ]
                            , div [ class "next-actions" ] [ btn "journey-download" "Save this source" Download, a [ class "btn build-cta", href "start.html", target "_blank", rel "noopener", onClick BuildIntent ] [ text "Open the run guide" ] ]
                            , p [] [ text "Local execution happens on your machine, so this page won’t mark it complete from a download or a click." ]
                            ]
            in
            aside [ id "journey", class "journey-card", tabindex -1, attribute "aria-label" "Guided introduction" ]
                [ div [ class "journey-heading" ] [ p [ class "eyebrow" ] [ text "Explore with a guide" ], btn "journey-close" "Keep editing" (CloseJourney False) ]
                , label [ class "chapter-picker" ] [ text "Chapter ", select [ id "journey-chapter", onInput (String.toInt >> Maybe.withDefault 0 >> JourneyStep), value (String.fromInt (List.head steps |> Maybe.withDefault 0)) ]
                    (List.map (\( index, name ) -> option [ value (String.fromInt index), selected (List.member step (chapterSteps index)) ] [ text (name ++ (if index == 3 then "" else " · ★ " ++ String.fromInt (List.length (List.filter (\n -> List.member n model.journeyDone) (chapterSteps index))) ++ "/" ++ String.fromInt (List.length (chapterSteps index)))) ]) chapters) ]
                , p [ class "steps-heading", id "steps-heading" ] [ text ("Step " ++ String.fromInt stepNumber ++ " of " ++ String.fromInt (List.length steps)) ]
                , nav [ class "journey-stops", attribute "aria-labelledby" "steps-heading" ]
                    (List.indexedMap (\ordinal index -> button [ onClick (JourneyStep index), attribute "aria-current" (if index == step then "step" else "false"), attribute "aria-label" (stepTitle index ++ (if List.member index model.journeyDone then " — checked" else "")) ] [ span [ class "stop-number" ] [ text (if List.member index model.journeyDone then "★" else String.fromInt (ordinal + 1)) ], text (stepTitle index) ]) steps)
                , p [ class "journey-legend" ] [ text "Stars mark completed edits, saved in this browser. Explore the steps in any order." ]
                , h2 [ id "journey-title", tabindex -1 ] [ text (stepTitle step) ]
                , div [ class "journey-content" ] (content ++
                    (if step == 3 then [] else
                        let
                            repair = repairFor step
                        in
                        [ section [ class "journey-repair", id ("repair-" ++ String.fromInt step), attribute "aria-label" "Suggested edit" ]
                            [ h3 [] [ text "Suggested edit" ]
                            , p [] [ text repair.why ]
                            , pre [] [ code [] [ text repair.after ] ]
                            , if repairApplicable step model.source then button [ class "btn build-cta", id "journey-apply", onClick ApplyJourneyRepair ] [ text "Apply edit" ] else text ""
                            ]
                        ]))
                , p [ id "journey-progress", attribute "role" "status" ] [ text progressText ]
                , div [ class "next-actions" ]
                    [ if step /= 3 then button [ id "journey-next", class (if completed && not (repairApplicable step model.source) then "btn build-cta" else "text-button"), onClick (JourneyStep (nextJourneyStep step)) ] [ text (if List.reverse steps |> List.head |> (==) (Just step) then "Next chapter →" else "Next step →") ] else btn "journey-share" "Copy share link" Share
                    ]
                , case Guide.testCommand step of
                    Nothing -> text ""
                    Just command -> aside [ class "testing-run" ]
                        [ p [] [ text "The browser checks test code; it does not run these tests." ]
                        , div [ class "next-actions" ] [ btn "journey-download" "Save this source" Download, code [] [ text command ] ]
                        ]
                , details [ class "journey-options" ]
                    [ summary [] [ text "Guide options" ]
                    , p [] [ text "Steps open with their examples. Your edits to each step stay here during this visit. Each finished edit earns one star; skipping does not. Stars are saved in this browser when storage is available." ]
                    , div [ class "next-actions" ]
                        [ btn "journey-load" "Restart this step" RestartJourneyStep
                        , if model.journeyOriginal /= Nothing then btn "journey-restore" "Back to my original code" (CloseJourney True) else text ""
                        , button [ class "text-button", id "journey-reset", onClick ResetJourney ] [ text "Reset stars" ]
                        ]
                    , p [] [ text "Missing a guide? ", a [ href "https://github.com/mtonnberg/tesl/discussions", target "_blank", rel "noopener" ] [ text "Suggest one in Discussions →" ] ]
                    ]
                ]

viewWelcome : Model -> Html Msg
viewWelcome model =
    section [ id "landing", class "welcome", hidden (not model.landing), attribute "aria-labelledby" "welcome-title" ]
        [ button [ id "welcome-close", class "welcome-close", onClick ToggleWelcome, attribute "aria-label" "Close introduction", title "Hide introduction" ] [ span [ attribute "aria-hidden" "true" ] [ text "×" ] ]
        , div [ class "welcome-copy" ]
            [ p [ class "eyebrow" ] [ text "Get to know Tesl" ]
            , h2 [ id "welcome-title" ] [ text "There’s a small API here with your name on it" ]
            , p [] [ text "Start by changing the greeting in this server, or follow the guide to see how Tesl helps with the details as your application grows." ]
            , p [ class "why-link" ] [ a [ href "why.html", target "_blank", rel "noopener" ] [ text "Why Tesl? Explore what makes it different →" ] ]
            , btn "journey-start" "Explore with a guide" OpenJourney
            , button [ class "welcome-dismiss", onClick ToggleWelcome, attribute "aria-label" "Hide getting started" ] [ text "Hide introduction" ]
            ]
        , div [ class "welcome-paths" ]
            [ a [ class "path-card", id "welcome-edit", href "start.html", target "_blank", rel "noopener", onClick BuildIntent ]
                [ span [ class "path-number" ] [ text "01" ], div [] [ strong [] [ text "Run your first API" ], p [] [ text "Get this server running on your computer." ] ], span [ attribute "aria-hidden" "true" ] [ text "↗" ] ]
            , button [ class "path-card", id "landing-next", onClick (ChooseExample "1") ]
                [ span [ class "path-number" ] [ text "02" ], div [] [ strong [] [ text "Meet your compiler" ], p [] [ text "See it catch a missing customer check before the code runs." ] ], span [ attribute "aria-hidden" "true" ] [ text "↗" ] ]
            , button [ class "path-card", id "welcome-search", onClick OpenSearch ]
                [ span [ class "path-number" ] [ text "03" ], div [] [ strong [] [ text "Find a useful function" ], p [] [ text "Describe what you need or search by a function’s type." ] ], span [ attribute "aria-hidden" "true" ] [ text "↗" ] ]
            ]
        ]


main : Program Flags Model Msg
main =
    Browser.element { init = init, update = update, subscriptions = \_ -> Sub.batch [ response Receive, action Action, progress ProgressChanged ], view = view }
