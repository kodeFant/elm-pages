module Pages.Internal.Platform exposing (Content, Flags, Model, Msg, Page, Parser, Program, application, cliApplication)

import Browser
import Browser.Navigation
import Dict exposing (Dict)
import Head
import Html exposing (Html)
import Html.Attributes
import Http
import Json.Decode as Decode
import Json.Encode
import List.Extra
import Mark
import Pages.ContentCache as ContentCache exposing (ContentCache)
import Pages.Document
import Pages.Internal.Platform.Cli
import Pages.Manifest as Manifest
import Pages.PagePath as PagePath exposing (PagePath)
import Pages.StaticHttp as StaticHttp
import Pages.StaticHttpRequest as StaticHttpRequest
import Result.Extra
import Task exposing (Task)
import Url exposing (Url)


dropTrailingSlash path =
    if path |> String.endsWith "/" then
        String.dropRight 1 path

    else
        path


type alias Page metadata view pathKey =
    { metadata : metadata
    , path : PagePath pathKey
    , view : view
    }


type alias Content =
    List ( List String, { extension : String, frontMatter : String, body : Maybe String } )


type alias Program userModel userMsg metadata view =
    Platform.Program Flags (Model userModel userMsg metadata view) (Msg userMsg metadata view)


mainView :
    pathKey
    ->
        (List ( PagePath pathKey, metadata )
         ->
            { path : PagePath pathKey
            , frontmatter : metadata
            }
         ->
            StaticHttp.Request
                { view :
                    userModel
                    -> view
                    ->
                        { title : String
                        , body : Html userMsg
                        }
                , head : List (Head.Tag pathKey)
                }
        )
    -> ModelDetails userModel metadata view
    -> { title : String, body : Html userMsg }
mainView pathKey pageView model =
    case model.contentCache of
        Ok site ->
            pageViewOrError pathKey pageView model model.contentCache

        -- TODO these lookup helpers should not need it to be a Result
        Err errors ->
            { title = "Error parsing"
            , body = ContentCache.errorView errors
            }


urlToPagePath : pathKey -> Url -> PagePath pathKey
urlToPagePath pathKey url =
    url.path
        |> dropTrailingSlash
        |> String.split "/"
        |> List.drop 1
        |> PagePath.build pathKey


pageViewOrError :
    pathKey
    ->
        (List ( PagePath pathKey, metadata )
         ->
            { path : PagePath pathKey
            , frontmatter : metadata
            }
         ->
            StaticHttp.Request
                { view : userModel -> view -> { title : String, body : Html userMsg }
                , head : List (Head.Tag pathKey)
                }
        )
    -> ModelDetails userModel metadata view
    -> ContentCache metadata view
    -> { title : String, body : Html userMsg }
pageViewOrError pathKey viewFn model cache =
    case ContentCache.lookup pathKey cache model.url of
        Just ( pagePath, entry ) ->
            case entry of
                ContentCache.Parsed metadata viewResult ->
                    let
                        viewFnResult =
                            viewFn
                                (cache
                                    |> Result.map (ContentCache.extractMetadata pathKey)
                                    |> Result.withDefault []
                                 -- TODO handle error better
                                )
                                { path = pagePath, frontmatter = metadata }
                                |> (\request ->
                                        StaticHttpRequest.resolve request viewResult.staticData
                                   )
                    in
                    case viewResult.body of
                        Ok viewList ->
                            case viewFnResult of
                                Ok okViewFn ->
                                    okViewFn.view model.userModel viewList

                                Err error ->
                                    { title = "Parsing error"
                                    , body =
                                        case error of
                                            StaticHttpRequest.DecoderError decoderError ->
                                                Html.div []
                                                    [ Html.text "Could not parse static data. I encountered this decoder problem."
                                                    , Html.pre [] [ Html.text decoderError ]
                                                    ]

                                            StaticHttpRequest.MissingHttpResponse missingKey ->
                                                Html.div []
                                                    [ Html.text "I'm missing some StaticHttp data for this page:"
                                                    , Html.pre [] [ Html.text missingKey ]
                                                    ]
                                    }

                        Err error ->
                            { title = "Parsing error"
                            , body = Html.text error
                            }

                ContentCache.NeedContent extension a ->
                    { title = "elm-pages error", body = Html.text "Missing content" }

                ContentCache.Unparsed extension a b ->
                    { title = "elm-pages error", body = Html.text "Unparsed content" }

        Nothing ->
            { title = "Page not found"
            , body =
                Html.div []
                    [ Html.text "Page not found. Valid routes:\n\n"
                    , cache
                        |> ContentCache.routesForCache
                        |> String.join ", "
                        |> Html.text
                    ]
            }


view :
    pathKey
    -> Content
    ->
        (List ( PagePath pathKey, metadata )
         ->
            { path : PagePath pathKey
            , frontmatter : metadata
            }
         ->
            StaticHttp.Request
                { view : userModel -> view -> { title : String, body : Html userMsg }
                , head : List (Head.Tag pathKey)
                }
        )
    -> ModelDetails userModel metadata view
    -> Browser.Document (Msg userMsg metadata view)
view pathKey content viewFn model =
    let
        { title, body } =
            mainView pathKey viewFn model
    in
    { title = title
    , body =
        [ onViewChangeElement model.url
        , body |> Html.map UserMsg |> Html.map AppMsg
        ]
    }


onViewChangeElement currentUrl =
    -- this is a hidden tag
    -- it is used from the JS-side to reliably
    -- check when Elm has changed pages
    -- (and completed rendering the view)
    Html.div
        [ Html.Attributes.attribute "data-url" (Url.toString currentUrl)
        , Html.Attributes.attribute "display" "none"
        ]
        []


type alias Flags =
    Decode.Value


type alias ContentJson =
    { body : String
    , staticData : Dict String String
    }


init :
    pathKey
    -> String
    -> Pages.Document.Document metadata view
    -> (Json.Encode.Value -> Cmd Never)
    ->
        (List ( PagePath pathKey, metadata )
         ->
            { path : PagePath pathKey
            , frontmatter : metadata
            }
         ->
            StaticHttp.Request
                { view :
                    userModel
                    -> view
                    ->
                        { title : String
                        , body : Html userMsg
                        }
                , head : List (Head.Tag pathKey)
                }
        )
    -> Content
    -> (Maybe (PagePath pathKey) -> ( userModel, Cmd userMsg ))
    -> Flags
    -> Url
    -> Browser.Navigation.Key
    -> ( ModelDetails userModel metadata view, Cmd (AppMsg userMsg metadata view) )
init pathKey canonicalSiteUrl document toJsPort viewFn content initUserModel flags url key =
    let
        contentCache =
            ContentCache.init document content (Maybe.map (\cj -> { contentJson = cj, initialUrl = url }) contentJson)

        contentJson =
            flags
                |> Decode.decodeValue (Decode.field "contentJson" contentJsonDecoder)
                |> Result.toMaybe

        contentJsonDecoder : Decode.Decoder ContentJson
        contentJsonDecoder =
            Decode.map2 ContentJson
                (Decode.field "body" Decode.string)
                (Decode.field "staticData" (Decode.dict Decode.string))
    in
    case contentCache of
        Ok okCache ->
            let
                phase =
                    case Decode.decodeValue (Decode.field "isPrerendering" Decode.bool) flags of
                        Ok True ->
                            Prerender

                        Ok False ->
                            Client

                        Err _ ->
                            Client

                ( userModel, userCmd ) =
                    initUserModel maybePagePath

                cmd =
                    case ( maybePagePath, maybeMetadata ) of
                        ( Just pagePath, Just frontmatter ) ->
                            [ userCmd |> Cmd.map UserMsg |> Just
                            , contentCache
                                |> ContentCache.lazyLoad document url
                                |> Task.attempt UpdateCache
                                |> Just
                            ]
                                |> List.filterMap identity
                                |> Cmd.batch

                        _ ->
                            Cmd.none

                ( maybePagePath, maybeMetadata ) =
                    case ContentCache.lookupMetadata pathKey (Ok okCache) url of
                        Just ( pagePath, metadata ) ->
                            ( Just pagePath, Just metadata )

                        Nothing ->
                            ( Nothing, Nothing )
            in
            ( { key = key
              , url = url
              , userModel = userModel
              , contentCache = contentCache
              , phase = phase
              }
            , cmd
            )

        Err _ ->
            let
                ( userModel, userCmd ) =
                    initUserModel Nothing
            in
            ( { key = key
              , url = url
              , userModel = userModel
              , contentCache = contentCache
              , phase = Client
              }
            , Cmd.batch
                [ userCmd |> Cmd.map UserMsg
                ]
              -- TODO handle errors better
            )


encodeHeads : String -> String -> List (Head.Tag pathKey) -> Json.Encode.Value
encodeHeads canonicalSiteUrl currentPagePath head =
    Json.Encode.list (Head.toJson canonicalSiteUrl currentPagePath) head


type Msg userMsg metadata view
    = AppMsg (AppMsg userMsg metadata view)
    | CliMsg Pages.Internal.Platform.Cli.Msg


type AppMsg userMsg metadata view
    = LinkClicked Browser.UrlRequest
    | UrlChanged Url.Url
    | UserMsg userMsg
    | UpdateCache (Result Http.Error (ContentCache metadata view))
    | UpdateCacheAndUrl Url (Result Http.Error (ContentCache metadata view))


type Model userModel userMsg metadata view
    = Model (ModelDetails userModel metadata view)
    | CliModel Pages.Internal.Platform.Cli.Model


type alias ModelDetails userModel metadata view =
    { key : Browser.Navigation.Key
    , url : Url.Url
    , contentCache : ContentCache metadata view
    , userModel : userModel
    , phase : Phase
    }


type Phase
    = Prerender
    | Client


update :
    String
    ->
        (List ( PagePath pathKey, metadata )
         ->
            { path : PagePath pathKey
            , frontmatter : metadata
            }
         ->
            StaticHttp.Request
                { view : userModel -> view -> { title : String, body : Html userMsg }
                , head : List (Head.Tag pathKey)
                }
        )
    -> pathKey
    -> (PagePath pathKey -> userMsg)
    -> (Json.Encode.Value -> Cmd Never)
    -> Pages.Document.Document metadata view
    -> (userMsg -> userModel -> ( userModel, Cmd userMsg ))
    -> Msg userMsg metadata view
    -> ModelDetails userModel metadata view
    -> ( ModelDetails userModel metadata view, Cmd (AppMsg userMsg metadata view) )
update canonicalSiteUrl viewFunction pathKey onPageChangeMsg toJsPort document userUpdate msg model =
    case msg of
        AppMsg appMsg ->
            case appMsg of
                LinkClicked urlRequest ->
                    case urlRequest of
                        Browser.Internal url ->
                            let
                                navigatingToSamePage =
                                    url.path
                                        == model.url.path
                                        && url
                                        /= model.url
                            in
                            if navigatingToSamePage then
                                -- this is a workaround for an issue with anchor fragment navigation
                                -- see https://github.com/elm/browser/issues/39
                                ( model, Browser.Navigation.load (Url.toString url) )

                            else
                                ( model, Browser.Navigation.pushUrl model.key (Url.toString url) )

                        Browser.External href ->
                            ( model, Browser.Navigation.load href )

                UrlChanged url ->
                    ( model
                    , model.contentCache
                        |> ContentCache.lazyLoad document url
                        |> Task.attempt (UpdateCacheAndUrl url)
                    )

                UserMsg userMsg ->
                    let
                        ( userModel, userCmd ) =
                            userUpdate userMsg model.userModel
                    in
                    ( { model | userModel = userModel }, userCmd |> Cmd.map UserMsg )

                UpdateCache cacheUpdateResult ->
                    case cacheUpdateResult of
                        -- TODO can there be race conditions here? Might need to set something in the model
                        -- to keep track of the last url change
                        Ok updatedCache ->
                            let
                                maybeCmd =
                                    case ContentCache.lookup pathKey updatedCache model.url of
                                        Just ( pagePath, entry ) ->
                                            case entry of
                                                ContentCache.Parsed frontmatter viewResult ->
                                                    headFn pagePath frontmatter viewResult.staticData
                                                        |> Result.map .head
                                                        |> Result.toMaybe
                                                        |> Maybe.map (encodeHeads canonicalSiteUrl model.url.path)
                                                        |> Maybe.map toJsPort

                                                ContentCache.NeedContent string metadata ->
                                                    Nothing

                                                ContentCache.Unparsed string metadata contentJson ->
                                                    Nothing

                                        Nothing ->
                                            Nothing

                                headFn pagePath frontmatter staticDataThing =
                                    viewFunction
                                        (updatedCache
                                            |> Result.map (ContentCache.extractMetadata pathKey)
                                            |> Result.withDefault []
                                        )
                                        { path = pagePath, frontmatter = frontmatter }
                                        |> (\request ->
                                                StaticHttpRequest.resolve request staticDataThing
                                           )
                            in
                            ( { model | contentCache = updatedCache }
                            , maybeCmd
                                |> Maybe.map (Cmd.map never)
                                |> Maybe.withDefault Cmd.none
                            )

                        Err _ ->
                            -- TODO handle error
                            ( model, Cmd.none )

                UpdateCacheAndUrl url cacheUpdateResult ->
                    case cacheUpdateResult of
                        -- TODO can there be race conditions here? Might need to set something in the model
                        -- to keep track of the last url change
                        Ok updatedCache ->
                            let
                                ( userModel, userCmd ) =
                                    userUpdate
                                        (onPageChangeMsg (url |> urlToPagePath pathKey))
                                        model.userModel
                            in
                            ( { model
                                | url = url
                                , contentCache = updatedCache
                                , userModel = userModel
                              }
                            , userCmd |> Cmd.map UserMsg
                            )

                        Err _ ->
                            -- TODO handle error
                            ( { model | url = url }, Cmd.none )

        CliMsg _ ->
            ( model, Cmd.none )


type alias Parser metadata view =
    Dict String String
    -> List String
    -> List ( List String, metadata )
    -> Mark.Document view


application :
    { init : Maybe (PagePath pathKey) -> ( userModel, Cmd userMsg )
    , update : userMsg -> userModel -> ( userModel, Cmd userMsg )
    , subscriptions : userModel -> Sub userMsg
    , view :
        List ( PagePath pathKey, metadata )
        ->
            { path : PagePath pathKey
            , frontmatter : metadata
            }
        ->
            StaticHttp.Request
                { view : userModel -> view -> { title : String, body : Html userMsg }
                , head : List (Head.Tag pathKey)
                }
    , document : Pages.Document.Document metadata view
    , content : Content
    , toJsPort : Json.Encode.Value -> Cmd Never
    , manifest : Manifest.Config pathKey
    , canonicalSiteUrl : String
    , pathKey : pathKey
    , onPageChange : PagePath pathKey -> userMsg
    }
    --    -> Program userModel userMsg metadata view
    -> Platform.Program Flags (Model userModel userMsg metadata view) (Msg userMsg metadata view)
application config =
    Browser.application
        { init =
            \flags url key ->
                init config.pathKey config.canonicalSiteUrl config.document config.toJsPort config.view config.content config.init flags url key
                    |> Tuple.mapFirst Model
                    |> Tuple.mapSecond (Cmd.map AppMsg)
        , view =
            \outerModel ->
                case outerModel of
                    Model model ->
                        view config.pathKey config.content config.view model

                    CliModel _ ->
                        { title = "Error"
                        , body = [ Html.text "Unexpected state" ]
                        }
        , update =
            \msg outerModel ->
                case outerModel of
                    Model model ->
                        let
                            userUpdate =
                                case model.phase of
                                    Prerender ->
                                        noOpUpdate

                                    Client ->
                                        config.update

                            noOpUpdate =
                                \userMsg userModel ->
                                    ( userModel, Cmd.none )
                        in
                        update config.canonicalSiteUrl config.view config.pathKey config.onPageChange config.toJsPort config.document userUpdate msg model
                            |> Tuple.mapFirst Model
                            |> Tuple.mapSecond (Cmd.map AppMsg)

                    CliModel _ ->
                        ( outerModel, Cmd.none )
        , subscriptions =
            \outerModel ->
                case outerModel of
                    Model model ->
                        config.subscriptions model.userModel
                            |> Sub.map UserMsg
                            |> Sub.map AppMsg

                    CliModel _ ->
                        Sub.none
        , onUrlChange = UrlChanged >> AppMsg
        , onUrlRequest = LinkClicked >> AppMsg
        }


cliApplication :
    { init : Maybe (PagePath pathKey) -> ( userModel, Cmd userMsg )
    , update : userMsg -> userModel -> ( userModel, Cmd userMsg )
    , subscriptions : userModel -> Sub userMsg
    , view :
        List ( PagePath pathKey, metadata )
        ->
            { path : PagePath pathKey
            , frontmatter : metadata
            }
        ->
            StaticHttp.Request
                { view : userModel -> view -> { title : String, body : Html userMsg }
                , head : List (Head.Tag pathKey)
                }
    , document : Pages.Document.Document metadata view
    , content : Content
    , toJsPort : Json.Encode.Value -> Cmd Never
    , manifest : Manifest.Config pathKey
    , canonicalSiteUrl : String
    , pathKey : pathKey
    , onPageChange : PagePath pathKey -> userMsg
    }
    -> Program userModel userMsg metadata view
cliApplication =
    Pages.Internal.Platform.Cli.cliApplication CliMsg
        (\msg ->
            case msg of
                CliMsg cliMsg ->
                    Just cliMsg

                _ ->
                    Nothing
        )
        CliModel
        (\model ->
            case model of
                CliModel cliModel ->
                    Just cliModel

                _ ->
                    Nothing
        )
