module Main exposing (main)

import Browser
import Html exposing (Html, button, div, footer, form, h1, h2, header, input, label, li, main_, p, section, span, text, ul)
import Html.Attributes exposing (attribute, checked, class, disabled, for, id, placeholder, type_, value)
import Html.Events exposing (onCheck, onClick, onInput, onSubmit)
import Http
import Json.Decode as Decode
import Json.Encode as Encode
import Time


type alias Todo =
    { id : String, title : String, completed : Bool }


type alias Model =
    { todos : List Todo
    , title : String
    , editing : Maybe Todo
    , filter : String
    , busy : Bool
    , error : Maybe String
    , connected : Bool
    , session : String
    , sequence : Int
    }


type Msg
    = Refreshed (Result Http.Error (List Todo))
    | Refresh
    | TitleChanged String
    | Add
    | Edit Todo
    | EditTitle String
    | Save
    | Cancel
    | Toggle Todo Bool
    | Delete Todo
    | Changed ChangeKind (Result Http.Error ())
    | Filter String


type ChangeKind
    = Created
    | Edited
    | OtherChange


main : Program String Model Msg
main =
    Browser.element
        { init = \session -> ( Model [] "" Nothing "all" False Nothing False session 0, fetch )
        , update = update
        , view = view
        , subscriptions = \_ -> Time.every 2500 (\_ -> Refresh)
        }


todoDecoder : Decode.Decoder Todo
todoDecoder =
    Decode.map3 Todo
        (Decode.field "id" Decode.string)
        (Decode.field "title" Decode.string)
        (Decode.field "completed" Decode.bool)


fetch : Cmd Msg
fetch =
    Http.get { url = "/api/todos", expect = Http.expectJson Refreshed (Decode.list todoDecoder) }


change : ChangeKind -> String -> String -> Http.Body -> Cmd Msg
change kind method todoId body =
    Http.request
        { method = method
        , headers = []
        , url = "/api/todos/" ++ todoId
        , body = body
        , expect = Http.expectWhatever (Changed kind)
        , timeout = Just 10000
        , tracker = Nothing
        }


saveTodo : ChangeKind -> Todo -> Cmd Msg
saveTodo kind todo =
    change kind "PUT" todo.id
        (Http.jsonBody (Encode.object [ ( "title", Encode.string todo.title ), ( "completed", Encode.bool todo.completed ) ]))


errorMessage : Http.Error -> String
errorMessage problem =
    case problem of
        Http.BadStatus 400 ->
            "Use a title between 1 and 120 characters. Your existing todo was kept."

        Http.BadStatus 404 ->
            "This todo was removed in another tab. Refresh and try again."

        Http.BadStatus 409 ->
            "That todo already exists. Refresh and try again."

        Http.BadStatus code ->
            "The server returned " ++ String.fromInt code ++ ". Your input is still here; try again."

        Http.Timeout ->
            "The request timed out. Check the list before retrying."

        _ ->
            "Cannot reach the app. Check that the cluster is running."


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        Refreshed (Ok todos) ->
            ( { model | todos = todos, connected = True }, Cmd.none )

        Refreshed (Err _) ->
            ( { model | connected = False }, Cmd.none )

        Refresh ->
            ( model, fetch )

        TitleChanged title ->
            ( { model | title = title }, Cmd.none )

        Add ->
            if model.busy || String.trim model.title == "" then
                ( model, Cmd.none )

            else
                ( { model | busy = True, error = Nothing, sequence = model.sequence + 1 }
                , change Created "POST" (model.session ++ "-" ++ String.fromInt model.sequence)
                    (Http.jsonBody (Encode.object [ ( "title", Encode.string model.title ) ]))
                )

        Edit todo ->
            ( { model | editing = Just todo, error = Nothing }, Cmd.none )

        EditTitle title ->
            ( { model | editing = Maybe.map (\todo -> { todo | title = title }) model.editing }, Cmd.none )

        Save ->
            case model.editing of
                Just todo ->
                    ( { model | busy = True, error = Nothing }, saveTodo Edited todo )

                Nothing ->
                    ( model, Cmd.none )

        Cancel ->
            ( { model | editing = Nothing }, Cmd.none )

        Toggle todo completed ->
            ( { model | busy = True, error = Nothing }, saveTodo OtherChange { todo | completed = completed } )

        Delete todo ->
            ( { model | busy = True, error = Nothing }, change OtherChange "DELETE" todo.id Http.emptyBody )

        Changed kind (Ok _) ->
            let
                next =
                    { model | busy = False, error = Nothing }
            in
            case kind of
                Created ->
                    ( { next | title = "" }, fetch )

                Edited ->
                    ( { next | editing = Nothing }, fetch )

                OtherChange ->
                    ( next, fetch )

        Changed _ (Err problem) ->
            ( { model | busy = False, error = Just (errorMessage problem) }, fetch )

        Filter name ->
            ( { model | filter = name }, Cmd.none )


view : Model -> Html Msg
view model =
    let
        remaining =
            List.length (List.filter (\todo -> not todo.completed) model.todos)

        visible =
            List.filter
                (\todo -> model.filter == "all" || (model.filter == "done") == todo.completed)
                model.todos
    in
    main_ [ class "workspace" ]
        [ header [ class "masthead" ]
            [ span [ class "brand" ] [ text "TESL / FIELD NOTES" ]
            , span [ class (if model.connected then "connection online" else "connection") ]
                [ text (if model.connected then "Connected" else "Connecting…") ]
            ]
        , section [ class "intro" ]
            [ p [ class "eyebrow" ] [ text "A LITTLE ROOM TO GET THINGS DONE" ]
            , h1 [] [ text "One thing at a time." ]
            , p [ class "subtitle" ] [ text "Your everyday todo list. Same app, even as the database evolves." ]
            ]
        , section [ class "notebook" ]
            [ form [ class "add-form", onSubmit Add ]
                [ label [ for "new-todo", class "sr-only" ] [ text "New todo" ]
                , input [ id "new-todo", placeholder "What would you like to do?", value model.title, onInput TitleChanged, disabled model.busy, attribute "maxlength" "120" ] []
                , button [ type_ "submit", disabled (model.busy || String.trim model.title == "") ] [ text "Add todo" ]
                ]
            , div [ class "toolbar" ]
                [ span [ class "count" ] [ text (String.fromInt remaining ++ " left to do") ]
                , div [ class "filters" ]
                    (List.map (\( key, title ) -> button [ class (if model.filter == key then "selected" else ""), onClick (Filter key) ] [ text title ])
                        [ ( "all", "All" ), ( "active", "Active" ), ( "done", "Done" ) ])
                ]
            , case model.error of
                Nothing -> text ""
                Just message -> p [ class "error", attribute "role" "alert" ] [ text message ]
            , if List.isEmpty visible then
                div [ class "empty" ]
                    [ span [ class "empty-mark" ] [ text "✓" ]
                    , h2 [] [ text (if model.filter == "done" then "Good things take a first step." else "A little breathing room.") ]
                    , p [] [ text "Add a todo above, or enjoy a clear page." ]
                    ]

              else
                ul [ class "todos" ] (List.map (todoView model) visible)
            ]
        , footer []
            [ span [] [ text "Saved in PostgreSQL · Updates appear across tabs" ]
            , button [ onClick Refresh, class "refresh" ] [ text "Refresh now ↻" ]
            ]
        ]


todoView : Model -> Todo -> Html Msg
todoView model todo =
    li [ class (if todo.completed then "todo completed" else "todo") ]
        [ input [ type_ "checkbox", checked todo.completed, onCheck (Toggle todo), disabled model.busy, attribute "aria-label" ("Mark " ++ todo.title ++ " complete") ] []
        , case model.editing of
            Just edited ->
                if edited.id == todo.id then
                    form [ class "edit-form", onSubmit Save ]
                        [ input [ value edited.title, onInput EditTitle, disabled model.busy, attribute "aria-label" "Edit title", attribute "maxlength" "120" ] []
                        , button [ type_ "submit", disabled model.busy ] [ text "Save" ]
                        , button [ type_ "button", onClick Cancel, disabled model.busy, class "subtle" ] [ text "Cancel" ]
                        ]

                else
                    todoText model todo

            Nothing ->
                todoText model todo
        ]


todoText : Model -> Todo -> Html Msg
todoText model todo =
    div [ class "todo-content" ]
        [ span [ class "todo-title" ] [ text todo.title ]
        , div [ class "actions" ]
            [ button [ onClick (Edit todo), disabled model.busy, attribute "aria-label" ("Edit " ++ todo.title) ] [ text "Edit" ]
            , button [ onClick (Delete todo), disabled model.busy, attribute "aria-label" ("Delete " ++ todo.title) ] [ text "Delete" ]
            ]
        ]
