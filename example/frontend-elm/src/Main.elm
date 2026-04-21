module Main exposing (main)

{-| Demo application for the Tesl Todo API — Elm frontend.

This module demonstrates how `tesl generate elm` bridges Tesl's proof system
to Elm's type system:

  - `TitleSafe` is a refinement proof tag; `titleSafe` returns
    `Maybe (Proven String TitleSafe)`, validating 3 ≤ length ≤ 120
    client-side before any HTTP request.
  - `TodoId` is a refinement proof tag; `todoId` returns
    `Maybe (Proven String TodoId)`, validating the "todo-*" format — the
    same constraint the server's `isTodoId` check enforces.

-}

import Api.TodoApi as Api
import Browser
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Http
import RefinementProofs.Theory as RF



-- ---------------------------------------------------------------------------
-- Model
-- ---------------------------------------------------------------------------


type alias Model =
    { todos : List Api.Todo
    , loadState : LoadState
    , newTitleInput : String
    , titleValidationError : Maybe String
    , createState : CreateState
    }


type LoadState
    = Loading
    | Loaded
    | LoadError String


type CreateState
    = Idle
    | Creating
    | CreateError String


init : () -> ( Model, Cmd Msg )
init _ =
    ( { todos = []
      , loadState = Loading
      , newTitleInput = ""
      , titleValidationError = Nothing
      , createState = Idle
      }
    , Api.getTodosMineOpen GotTodos
    )



-- ---------------------------------------------------------------------------
-- Msg
-- ---------------------------------------------------------------------------


type Msg
    = GotTodos (Result Http.Error (List (RF.Proven Api.Todo Api.IsOpen)))
    | TitleChanged String
    | SubmitNewTodo
    | TodoCreated (Result Http.Error Api.Todo)
    | CompleteClicked Api.Todo
    | TodoCompleted (Result Http.Error Api.Todo)


validateNewTitle : String -> Maybe (RF.Proven String (RF.And (RF.And Api.TitleSafe Api.LengthLessThan30) Api.ContainsAnA))
validateNewTitle =
    RF.makeAnd (RF.makeAnd Api.titleSafe Api.lengthLessThan30) Api.containsAnA



-- ---------------------------------------------------------------------------
-- Update
-- ---------------------------------------------------------------------------


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        GotTodos result ->
            case result of
                Ok todos ->
                    ( { model | todos = List.map RF.exorcise todos, loadState = Loaded }, Cmd.none )

                Err err ->
                    ( { model | loadState = LoadError (httpErrorToString err) }, Cmd.none )

        TitleChanged raw ->
            -- Validate client-side using the same constraint as `isSafeTitle`.
            -- If `titleSafe` returns Nothing, the string fails the Tesl proof
            -- constraint and we show an error without calling the API.
            let
                validationError =
                    if String.isEmpty raw then
                        Nothing

                    else
                        case validateNewTitle raw of
                            Just _ ->
                                Nothing

                            Nothing ->
                                Just "Title must be between 3 and 120 characters and less than 10"
            in
            ( { model | newTitleInput = raw, titleValidationError = validationError }, Cmd.none )

        SubmitNewTodo ->
            -- Call titleSafe again to get the validated TitleSafe value.
            -- The type system guarantees we cannot pass a plain String to
            -- createTodo — it requires a NewTodo with a TitleSafe title.
            case validateNewTitle model.newTitleInput of
            -- case Api.titleSafe model.newTitleInput of
                Nothing ->
                    ( { model
                        | titleValidationError =
                            Just "Title must be between 3 and 120 characters, shorter than 30, and contain an a"
                      }
                    , Cmd.none
                    )

                Just safeTitle ->
                    -- let

                    --     x : RF.Proven String (RF.And Api.TitleSafe Api.LengthLessThan30)
                    --     x  = safeTile
                    -- in
                    ( { model | createState = Creating }
                    , Api.postTodos { title = safeTitle } TodoCreated
                    )

        TodoCreated result ->
            case result of
                Ok newTodo ->
                    ( { model
                        | todos = newTodo :: model.todos
                        , newTitleInput = ""
                        , titleValidationError = Nothing
                        , createState = Idle
                      }
                    , Cmd.none
                    )

                Err err ->
                    ( { model | createState = CreateError (httpErrorToString err) }, Cmd.none )

        CompleteClicked todo ->
            -- `todo.id` is a plain `String` from the server response.
            -- We use `todoId` to parse it into a `TodoId` value — this is safe
            -- because the ID came from the server's own `todoDecoder`, which
            -- guarantees it satisfies the "todo-*" format.
            -- (The server's `isTodoId` check ensures this before storing it.)
            case Api.todoId todo.id of
                Nothing ->
                    -- Should never happen: the server guarantees "todo-*" IDs.
                    ( model, Cmd.none )

                Just tid ->
                    ( model, Api.putTodosComplete tid TodoCompleted )

        TodoCompleted result ->
            case result of
                Ok updated ->
                    ( { model
                        | todos =
                            List.map
                                (\t ->
                                    if t.id == updated.id then
                                        updated

                                    else
                                        t
                                )
                                model.todos
                      }
                    , Cmd.none
                    )

                Err err ->
                    ( { model | loadState = LoadError (httpErrorToString err) }, Cmd.none )


httpErrorToString : Http.Error -> String
httpErrorToString err =
    case err of
        Http.BadUrl url ->
            "Bad URL: " ++ url

        Http.Timeout ->
            "Request timed out"

        Http.NetworkError ->
            "Network error"

        Http.BadStatus status ->
            "Server error: " ++ String.fromInt status

        Http.BadBody body ->
            "Unexpected response: " ++ body



-- ---------------------------------------------------------------------------
-- View
-- ---------------------------------------------------------------------------


view : Model -> Html Msg
view model =
    div [ style "max-width" "600px"
        , style "margin" "40px auto"
        , style "font-family" "'Segoe UI', system-ui, sans-serif"
        , style "color" "#1a1a1a"
        , style "padding" "0 16px"
        ]
        [ h1 [ style "font-size" "24px"
             , style "font-weight" "700"
             , style "margin-bottom" "4px"
             ]
            [ text "Tesl Todo" ]
        , p [ style "font-size" "13px"
            , style "color" "#6b7280"
            , style "margin-bottom" "32px"
            ]
            [ text "Elm client — generated by "
            , code [] [ text "tesl generate elm todo-api.tesl" ]
            ]
        , viewCreateForm model
        , viewTodoList model
        ]


viewCreateForm : Model -> Html Msg
viewCreateForm model =
    let
        isSubmitting =
            model.createState == Creating

        inputBorderColor =
            case model.titleValidationError of
                Just _ ->
                    "#ef4444"

                Nothing ->
                    "#d1d5db"

        canSubmit =
            not isSubmitting
                && not (String.isEmpty model.newTitleInput)
                && model.titleValidationError == Nothing
    in
    div [ style "margin-bottom" "32px" ]
        [ div [ style "font-size" "13px"
              , style "font-weight" "600"
              , style "text-transform" "uppercase"
              , style "letter-spacing" "0.05em"
              , style "color" "#6b7280"
              , style "margin-bottom" "12px"
              ]
            [ text "New todo" ]
        , div [ style "display" "flex"
              , style "gap" "8px"
              , style "margin-bottom" "4px"
              ]
            [ input
                [ type_ "text"
                , placeholder "What needs doing? (3–120 chars)"
                , value model.newTitleInput
                , onInput TitleChanged
                , disabled isSubmitting
                , style "flex" "1"
                , style "padding" "8px 12px"
                , style "border" ("1px solid " ++ inputBorderColor)
                , style "border-radius" "6px"
                , style "font-size" "14px"
                , style "outline" "none"
                ]
                []
            , button
                [ onClick SubmitNewTodo
                , disabled (not canSubmit)
                , style "padding" "8px 16px"
                , style "background"
                    (if canSubmit then
                        "#2563eb"

                     else
                        "#93c5fd"
                    )
                , style "color" "#fff"
                , style "border" "none"
                , style "border-radius" "6px"
                , style "font-size" "14px"
                , style "cursor"
                    (if canSubmit then
                        "pointer"

                     else
                        "not-allowed"
                    )
                ]
                [ text
                    (if isSubmitting then
                        "Adding…"

                     else
                        "Add"
                    )
                ]
            ]

        -- Client-side validation error — no API call made
        , case model.titleValidationError of
            Just err ->
                p [ style "color" "#ef4444", style "font-size" "12px", style "margin" "0" ]
                    [ text err ]

            Nothing ->
                text ""
        , case model.createState of
            CreateError err ->
                div [ style "margin-top" "8px"
                    , style "padding" "10px 14px"
                    , style "background" "#fef2f2"
                    , style "border" "1px solid #fecaca"
                    , style "border-radius" "6px"
                    , style "color" "#dc2626"
                    , style "font-size" "13px"
                    ]
                    [ text err ]

            _ ->
                text ""
        , div [ style "font-size" "12px"
              , style "color" "#6b7280"
              , style "background" "#f9fafb"
              , style "border" "1px solid #e5e7eb"
              , style "border-radius" "6px"
              , style "padding" "8px 12px"
              , style "margin-top" "16px"
              , style "font-family" "monospace"
              , style "line-height" "1.6"
              ]
            [ text "-- titleSafe rawInput runs before any HTTP request"
            , br [] []
            , text "-- returns Nothing → show error, no fetch"
            , br [] []
            , text "-- returns Just safeTile → createTodo { title = safeTile }"
            ]
        ]


viewTodoList : Model -> Html Msg
viewTodoList model =
    div []
        [ div [ style "font-size" "13px"
              , style "font-weight" "600"
              , style "text-transform" "uppercase"
              , style "letter-spacing" "0.05em"
              , style "color" "#6b7280"
              , style "margin-bottom" "12px"
              ]
            [ text "Open todos" ]
        , case model.loadState of
            Loading ->
                p [ style "color" "#9ca3af", style "text-align" "center" ]
                    [ text "Loading…" ]

            LoadError err ->
                div [ style "padding" "10px 14px"
                    , style "background" "#fef2f2"
                    , style "border" "1px solid #fecaca"
                    , style "border-radius" "6px"
                    , style "color" "#dc2626"
                    , style "font-size" "13px"
                    ]
                    [ text err ]

            Loaded ->
                if List.isEmpty model.todos then
                    p [ style "color" "#9ca3af"
                      , style "text-align" "center"
                      , style "padding" "16px 0"
                      ]
                        [ text "No open todos." ]

                else
                    div [] (List.map viewTodoItem model.todos)
        , div [ style "font-size" "12px"
              , style "color" "#6b7280"
              , style "background" "#f9fafb"
              , style "border" "1px solid #e5e7eb"
              , style "border-radius" "6px"
              , style "padding" "8px 12px"
              , style "margin-top" "16px"
              , style "font-family" "monospace"
              , style "line-height" "1.6"
              ]
            [ text "-- todo.id : String (from server decoder)"
            , br [] []
            , text "-- todoId todo.id : Maybe TodoId"
            , br [] []
            , text "-- completeTodo requires TodoId, not String"
            ]
        ]


viewTodoItem : Api.Todo -> Html Msg
viewTodoItem todo =
    let
        isDone =
            todo.status == Api.Done
    in
    div [ style "display" "flex"
        , style "align-items" "center"
        , style "justify-content" "space-between"
        , style "padding" "10px 14px"
        , style "border" "1px solid #e5e7eb"
        , style "border-radius" "8px"
        , style "margin-bottom" "8px"
        , style "background" "#fff"
        ]
        [ div []
            [ span
                [ style "font-size" "14px"
                , style "text-decoration"
                    (if isDone then
                        "line-through"

                     else
                        "none"
                    )
                , style "color"
                    (if isDone then
                        "#9ca3af"

                     else
                        "#111827"
                    )
                ]
                [ text todo.title ]
            , span
                [ style "font-size" "11px"
                , style "padding" "2px 8px"
                , style "border-radius" "12px"
                , style "margin-left" "8px"
                , style "background"
                    (if isDone then
                        "#f3f4f6"

                     else
                        "#dcfce7"
                    )
                , style "color"
                    (if isDone then
                        "#6b7280"

                     else
                        "#16a34a"
                    )
                ]
                [ text
                    (if isDone then
                        "Done"

                     else
                        "Open"
                    )
                ]
            , div [ style "font-size" "11px", style "color" "#9ca3af", style "margin-top" "2px" ]
                [ text (todo.id ++ " · owner: " ++ todo.ownerId) ]
            ]
        , if isDone then
            text ""

          else
            button
                [ onClick (CompleteClicked todo)
                , style "padding" "4px 10px"
                , style "background" "#16a34a"
                , style "color" "#fff"
                , style "border" "none"
                , style "border-radius" "4px"
                , style "font-size" "12px"
                , style "cursor" "pointer"
                ]
                [ text "Complete" ]
        ]



-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------


main : Program () Model Msg
main =
    Browser.element
        { init = init
        , update = update
        , view = view
        , subscriptions = \_ -> Sub.none
        }
