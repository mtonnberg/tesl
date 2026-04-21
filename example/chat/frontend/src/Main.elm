port module Main exposing (main)

import Browser
import Html exposing (..)
import Html.Attributes exposing (..)
import Html.Events exposing (..)
import Http
import Json.Decode as Decode exposing (Decoder)
import Json.Encode as Encode



-- ── Ports ──────────────────────────────────────────────────────────────────


port connectWs : String -> Cmd msg


port receiveWsMsg : (String -> msg) -> Sub msg


port setCookie : String -> Cmd msg


port wsStatus : (String -> msg) -> Sub msg


port detectInstance : () -> Cmd msg


port instanceDetected : (String -> msg) -> Sub msg



-- ── Types ──────────────────────────────────────────────────────────────────


type alias User =
    { id : String
    , username : String
    }


type alias Room =
    { id : String
    , name : String
    , createdAt : Int
    }


type alias Message =
    { id : String
    , roomId : String
    , userId : String
    , username : String
    , content : String
    , createdAt : Int
    }


type alias RoomEvent =
    { variant : String
    , userId : String
    , username : String
    , content : String
    , createdAt : Int
    }



-- ── Model ──────────────────────────────────────────────────────────────────


type Page
    = LoginPage
    | RoomsPage
    | ChatPage Room


type alias Model =
    { page : Page
    , user : Maybe User
    , username : String
    , loginError : Maybe String
    , rooms : List Room
    , newRoomName : String
    , messages : List Message
    , newMessage : String
    , wsConnected : Bool
    , baseUrl : String
    , backendInstance : String
    }


init : () -> ( Model, Cmd Msg )
init _ =
    ( { page = LoginPage
      , user = Nothing
      , username = ""
      , loginError = Nothing
      , rooms = []
      , newRoomName = ""
      , messages = []
      , newMessage = ""
      , wsConnected = False
      , baseUrl = ""
      , backendInstance = ""
      }
    , Cmd.none
    )



-- ── Msg ────────────────────────────────────────────────────────────────────


type Msg
    = UsernameChanged String
    | LoginClicked
    | SeedClicked
    | LoginDone (Result Http.Error User)
    | SeedDone (Result Http.Error User)
    | RoomsLoaded (Result Http.Error (List Room))
    | NewRoomNameChanged String
    | CreateRoomClicked
    | RoomCreated (Result Http.Error Room)
    | EnterRoom Room
    | MessagesLoaded (Result Http.Error (List Message))
    | MessageChanged String
    | SendMessage
    | MessageSent (Result Http.Error Message)
    | WsMsg String
    | WsStatus String
    | BackToRooms
    | InstanceInfo String



-- ── Update ─────────────────────────────────────────────────────────────────


update : Msg -> Model -> ( Model, Cmd Msg )
update msg model =
    case msg of
        UsernameChanged s ->
            ( { model | username = s }, Cmd.none )

        LoginClicked ->
            ( { model | loginError = Nothing }
            , postLogin model.baseUrl model.username
            )

        SeedClicked ->
            ( { model | loginError = Nothing }
            , postSeedUser model.baseUrl model.username
            )

        LoginDone (Ok user) ->
            ( { model | user = Just user, loginError = Nothing, page = RoomsPage }
            , Cmd.batch
                [ setCookie ("chatUserId=" ++ user.id)
                , loadRooms model.baseUrl
                , detectInstance ()
                ]
            )

        LoginDone (Err _) ->
            ( { model | loginError = Just "Login failed. Try seeding the user first." }
            , Cmd.none
            )

        SeedDone (Ok user) ->
            ( { model | user = Just user, loginError = Nothing, page = RoomsPage }
            , Cmd.batch
                [ setCookie ("chatUserId=" ++ user.id)
                , loadRooms model.baseUrl
                , detectInstance ()
                ]
            )

        SeedDone (Err _) ->
            ( { model | loginError = Just "Could not create user. Is the backend running?" }
            , Cmd.none
            )

        RoomsLoaded (Ok rooms) ->
            ( { model | rooms = rooms }, Cmd.none )

        RoomsLoaded (Err _) ->
            ( model, Cmd.none )

        NewRoomNameChanged s ->
            ( { model | newRoomName = s }, Cmd.none )

        CreateRoomClicked ->
            if String.isEmpty model.newRoomName then
                ( model, Cmd.none )

            else
                ( model, createRoom model.baseUrl model.newRoomName )

        RoomCreated (Ok room) ->
            ( { model | rooms = model.rooms ++ [ room ], newRoomName = "" }
            , Cmd.none
            )

        RoomCreated (Err _) ->
            ( model, Cmd.none )

        EnterRoom room ->
            ( { model | page = ChatPage room, messages = [], wsConnected = False }
            , Cmd.batch
                [ loadMessages model.baseUrl room.id
                , connectWs (model.baseUrl ++ "/events/rooms/" ++ room.id)
                ]
            )

        MessagesLoaded (Ok msgs) ->
            ( { model | messages = msgs }, Cmd.none )

        MessagesLoaded (Err _) ->
            ( model, Cmd.none )

        MessageChanged s ->
            ( { model | newMessage = s }, Cmd.none )

        SendMessage ->
            case ( model.page, model.user ) of
                ( ChatPage room, Just _ ) ->
                    if String.isEmpty model.newMessage then
                        ( model, Cmd.none )

                    else
                        ( { model | newMessage = "" }
                        , postMessage model.baseUrl room.id model.newMessage
                        )

                _ ->
                    ( model, Cmd.none )

        MessageSent (Ok _) ->
            -- The POST response confirms the server accepted the message.
            -- UI update comes exclusively via the SSE stream, which delivers
            -- to ALL subscribers (sender included) through one consistent path.
            --
            -- Why not also add here with deduplication?
            -- The HTTP response and SSE onmessage can fire in the same JavaScript
            -- event-loop turn.  Elm may call update() for both before either
            -- model update is visible, making deduplication silently fail.
            -- SSE-only avoids the race entirely.
            ( model, Cmd.none )

        MessageSent (Err _) ->
            ( model, Cmd.none )

        WsMsg rawJson ->
            case decodeWsMessage rawJson model of
                Just newModel ->
                    ( newModel, Cmd.none )

                Nothing ->
                    ( model, Cmd.none )

        WsStatus status ->
            ( { model | wsConnected = status == "connected" }, Cmd.none )

        BackToRooms ->
            ( { model | page = RoomsPage, messages = [], wsConnected = False }
            , Cmd.none
            )

        InstanceInfo info ->
            ( { model | backendInstance = info }, Cmd.none )


{-| Decode an incoming WebSocket message and append to messages if it is a
NewMessage event for the current room.

The server sends:
{ "channel": "RoomMessages"
, "payload": { "tag": "NewMessage"
             , "fields": { "userId": "..."
                         , "username": "..."
                         , "content": "..."
                         , "createdAt": 1234
                         }
             }
}

-}
decodeWsMessage : String -> Model -> Maybe Model
decodeWsMessage rawJson model =
    case ( model.page, model.user ) of
        ( ChatPage room, Just _ ) ->
            case Decode.decodeString (wsEventDecoder room.id) rawJson of
                Ok message ->
                    Just { model | messages = model.messages ++ [ message ] }

                Err _ ->
                    Nothing

        _ ->
            Nothing


wsEventDecoder : String -> Decoder Message
wsEventDecoder roomId =
    Decode.field "payload"
        (Decode.field "tag" Decode.string
            |> Decode.andThen
                (\tag ->
                    if tag == "NewMessage" then
                        Decode.field "fields"
                            (Decode.map5
                                (\msgId userId username content createdAt ->
                                    { id = msgId
                                    , roomId = roomId
                                    , userId = userId
                                    , username = username
                                    , content = content
                                    , createdAt = createdAt
                                    }
                                )
                                (Decode.field "msgId" Decode.string)
                                (Decode.field "userId" Decode.string)
                                (Decode.field "username" Decode.string)
                                (Decode.field "content" Decode.string)
                                (Decode.field "createdAt" Decode.int)
                            )

                    else if tag == "NotifyFailed" then
                        Decode.field "fields"
                            (Decode.map2
                                (\senderName _ ->
                                    { id = "sys-notifyfail-" ++ senderName
                                    , roomId = roomId
                                    , userId = "system"
                                    , username = "system"
                                    , content = "⚠ Notification failed for " ++ senderName
                                    , createdAt = 0
                                    }
                                )
                                (Decode.field "senderName" Decode.string)
                                (Decode.field "roomName" Decode.string)
                            )

                    else
                        Decode.fail ("unhandled tag: " ++ tag)
                )
        )



-- ── HTTP helpers ───────────────────────────────────────────────────────────


postLogin : String -> String -> Cmd Msg
postLogin baseUrl username =
    Http.post
        { url = baseUrl ++ "/login"
        , body = Http.jsonBody (Encode.object [ ( "username", Encode.string username ) ])
        , expect = Http.expectJson LoginDone userDecoder
        }


postSeedUser : String -> String -> Cmd Msg
postSeedUser baseUrl username =
    Http.post
        { url = baseUrl ++ "/users"
        , body = Http.jsonBody (Encode.object [ ( "username", Encode.string username ) ])
        , expect = Http.expectJson SeedDone userDecoder
        }


loadRooms : String -> Cmd Msg
loadRooms baseUrl =
    Http.get
        { url = baseUrl ++ "/rooms"
        , expect = Http.expectJson RoomsLoaded (Decode.list roomDecoder)
        }


createRoom : String -> String -> Cmd Msg
createRoom baseUrl name =
    Http.post
        { url = baseUrl ++ "/rooms"
        , body = Http.jsonBody (Encode.object [ ( "name", Encode.string name ) ])
        , expect = Http.expectJson RoomCreated roomDecoder
        }


loadMessages : String -> String -> Cmd Msg
loadMessages baseUrl roomId =
    Http.get
        { url = baseUrl ++ "/rooms/" ++ roomId ++ "/messages"
        , expect = Http.expectJson MessagesLoaded (Decode.list messageDecoder)
        }


postMessage : String -> String -> String -> Cmd Msg
postMessage baseUrl roomId content =
    Http.post
        { url = baseUrl ++ "/rooms/" ++ roomId ++ "/messages"
        , body = Http.jsonBody (Encode.object [ ( "content", Encode.string content ) ])
        , expect = Http.expectJson MessageSent messageDecoder
        }



-- ── Decoders ───────────────────────────────────────────────────────────────


userDecoder : Decoder User
userDecoder =
    Decode.map2 User
        (Decode.field "id" Decode.string)
        (Decode.field "username" Decode.string)


roomDecoder : Decoder Room
roomDecoder =
    Decode.map3 Room
        (Decode.field "id" Decode.string)
        (Decode.field "name" Decode.string)
        (Decode.field "createdAt" Decode.int)


messageDecoder : Decoder Message
messageDecoder =
    Decode.map6 Message
        (Decode.field "id" Decode.string)
        (Decode.field "roomId" Decode.string)
        (Decode.field "userId" Decode.string)
        (Decode.field "username" Decode.string)
        (Decode.field "content" Decode.string)
        (Decode.field "createdAt" Decode.int)



-- ── View ───────────────────────────────────────────────────────────────────


view : Model -> Browser.Document Msg
view model =
    { title = "Tesl Chat"
    , body =
        [ div [ id "app" ]
            [ case model.page of
                LoginPage ->
                    viewLoginPage model

                RoomsPage ->
                    viewRoomsPage model

                ChatPage room ->
                    viewChatPage model room
            ]
        ]
    }


viewLoginPage : Model -> Html Msg
viewLoginPage model =
    div [ class "login-page" ]
        [ div [ class "login-card" ]
            [ h1 [] [ text "Tesl Chat" ]
            , p [] [ text "Enter your username to start chatting." ]
            , input
                [ type_ "text"
                , placeholder "Username"
                , value model.username
                , onInput UsernameChanged
                , onEnter LoginClicked
                ]
                []
            , div [ style "display" "flex", style "gap" "10px", style "margin-top" "16px" ]
                [ button [ onClick LoginClicked ] [ text "Log in" ]
                , button
                    [ onClick SeedClicked
                    , style "background" "#6b7280"
                    ]
                    [ text "Create user" ]
                ]
            , case model.loginError of
                Just err ->
                    div [ class "error" ] [ text err ]

                Nothing ->
                    text ""
            ]
        ]


viewInstanceBadge : Model -> Html Msg
viewInstanceBadge model =
    if String.isEmpty model.backendInstance then
        text ""

    else
        span [ class "instance-badge" ]
            [ text model.backendInstance ]


viewRoomsPage : Model -> Html Msg
viewRoomsPage model =
    div [ class "chat-layout" ]
        [ div [ class "sidebar" ]
            [ div [ class "sidebar-hdr" ]
                [ text "Tesl Chat"
                , viewInstanceBadge model
                ]
            , div [ class "room-list" ]
                (List.map (viewRoomItem Nothing) model.rooms)
            , div [ class "new-room" ]
                [ input
                    [ type_ "text"
                    , placeholder "New room name"
                    , value model.newRoomName
                    , onInput NewRoomNameChanged
                    , onEnter CreateRoomClicked
                    , style "margin-bottom" "8px"
                    ]
                    []
                , button
                    [ onClick CreateRoomClicked
                    , class "secondary"
                    , style "width" "100%"
                    ]
                    [ text "Create room" ]
                ]
            ]
        , div [ class "chat-area" ]
            [ div [ class "empty-state" ]
                [ text "Select a room to start chatting" ]
            ]
        ]


viewChatPage : Model -> Room -> Html Msg
viewChatPage model room =
    div [ class "chat-layout" ]
        [ div [ class "sidebar" ]
            [ div [ class "sidebar-hdr" ]
                [ text "Tesl Chat"
                , viewInstanceBadge model
                ]
            , div [ class "room-list" ]
                (List.map (viewRoomItem (Just room)) model.rooms)
            , div [ class "new-room" ]
                [ button
                    [ onClick BackToRooms
                    , class "secondary"
                    , style "width" "100%"
                    ]
                    [ text "Back" ]
                ]
            ]
        , div [ class "chat-area" ]
            [ div [ class "chat-header" ]
                [ text ("#" ++ room.name)
                , span
                    [ class
                        (if model.wsConnected then
                            "ws-badge on"

                         else
                            "ws-badge off"
                        )
                    ]
                    [ text
                        (if model.wsConnected then
                            "Live"

                         else
                            "Offline"
                        )
                    ]
                ]
            , div [ class "messages" ]
                (if List.isEmpty model.messages then
                    [ div [ class "empty-state" ] [ text "No messages yet" ] ]

                 else
                    List.map viewMessage model.messages
                )
            , div [ class "msg-input" ]
                [ input
                    [ type_ "text"
                    , placeholder "Type a message…"
                    , value model.newMessage
                    , onInput MessageChanged
                    , onEnter SendMessage
                    ]
                    []
                , button [ onClick SendMessage ] [ text "Send" ]
                ]
            ]
        ]


viewRoomItem : Maybe Room -> Room -> Html Msg
viewRoomItem currentRoom room =
    let
        isActive =
            case currentRoom of
                Just r ->
                    r.id == room.id

                Nothing ->
                    False
    in
    div
        [ class
            (if isActive then
                "room-item active"

             else
                "room-item"
            )
        , onClick (EnterRoom room)
        ]
        [ text room.name ]


viewMessage : Message -> Html Msg
viewMessage message =
    if message.userId == "system" then
        div [ class "msg msg-system" ]
            [ div [ class "msg-body" ] [ text message.content ] ]

    else
        div [ class "msg" ]
            [ div [ class "msg-header" ]
                [ span [ class "msg-user" ] [ text message.username ]
                , span [ class "msg-time" ]
                    [ text (formatTimestamp message.createdAt) ]
                ]
            , div [ class "msg-body" ] [ text message.content ]
            ]


formatTimestamp : Int -> String
formatTimestamp epochSeconds =
    -- Simple formatting: show hours:minutes from epoch seconds
    let
        totalMinutes =
            epochSeconds // 60

        minutes =
            modBy 60 totalMinutes

        totalHours =
            totalMinutes // 60

        hours =
            modBy 24 totalHours

        pad n =
            if n < 10 then
                "0" ++ String.fromInt n

            else
                String.fromInt n
    in
    pad hours ++ ":" ++ pad minutes



-- ── Subscriptions ──────────────────────────────────────────────────────────


subscriptions : Model -> Sub Msg
subscriptions _ =
    Sub.batch
        [ receiveWsMsg WsMsg
        , wsStatus WsStatus
        , instanceDetected InstanceInfo
        ]



-- ── Helpers ────────────────────────────────────────────────────────────────


onEnter : msg -> Attribute msg
onEnter onEnterMsg =
    on "keydown"
        (Decode.field "key" Decode.string
            |> Decode.andThen
                (\key ->
                    if key == "Enter" then
                        Decode.succeed onEnterMsg

                    else
                        Decode.fail "not enter"
                )
        )



-- ── Main ───────────────────────────────────────────────────────────────────


main : Program () Model Msg
main =
    Browser.document
        { init = init
        , update = update
        , view = view
        , subscriptions = subscriptions
        }
