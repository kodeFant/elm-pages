module Secrets exposing (..)

import BuildError exposing (BuildError)
import Dict exposing (Dict)
import Fuzzy
import Json.Decode as Decode exposing (Decoder)
import TerminalText as Terminal


type alias UrlWithSecrets =
    Secrets -> Result BuildError String


type Secrets
    = Secrets (Dict String String)
    | Protected


protected : Secrets
protected =
    Protected


useFakeSecrets : (Secrets -> Result BuildError String) -> String
useFakeSecrets urlWithSecrets =
    urlWithSecrets protected
        |> Result.withDefault ""


empty =
    Secrets Dict.empty


get : String -> Secrets -> Result BuildError String
get name secretsData =
    case secretsData of
        Protected ->
            Ok ("<" ++ name ++ ">")

        Secrets secrets ->
            case Dict.get name secrets of
                Just secret ->
                    Ok secret

                Nothing ->
                    Err <| buildError name (Dict.keys secrets)


buildError : String -> List String -> BuildError
buildError secretName availableEnvironmentVariables =
    { message =
        [ Terminal.text "I expected to find this Secret in your environment variables but didn't find a match:\nSecrets.get \""
        , Terminal.red (Terminal.text secretName)
        , Terminal.text "\"\n\n"
        , Terminal.text "So maybe "
        , Terminal.yellow <| Terminal.text (sortMatches secretName availableEnvironmentVariables |> List.head |> Maybe.withDefault "")
        , Terminal.text " should be "
        , Terminal.green <| Terminal.text secretName
        ]
    }


sortMatches missingSecret availableSecrets =
    let
        simpleMatch config separators needle hay =
            Fuzzy.match config separators needle hay |> .score
    in
    List.sortBy (simpleMatch [] [] missingSecret) availableSecrets


decoder : Decoder Secrets
decoder =
    Decode.dict Decode.string
        |> Decode.map Secrets
