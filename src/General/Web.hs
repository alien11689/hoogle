{-# LANGUAGE ScopedTypeVariables, OverloadedStrings, CPP, ViewPatterns #-}

module General.Web(
    Input(..), Output(..), readInput, server
    ) where

-- #define PROFILE

-- For some reason, profiling stops working if I import warp
-- Tracked as https://github.com/yesodweb/wai/issues/311
#ifndef PROFILE
import Network.Wai.Handler.Warp hiding (Port, Handle)
#endif

import Network.Wai.Logger
import Network.Wai
import Control.DeepSeq
import Network.HTTP.Types.Status
import qualified Data.Text as Text
import General.Str
import qualified Data.ByteString.Char8 as BS
import qualified Data.ByteString.Lazy.Char8 as LBS
import Data.List.Extra
import Data.Tuple.Extra
import Data.Monoid
import System.FilePath
import Control.Exception.Extra
import System.Time.Extra
import General.Log
import Network.URI


data Input = Input
    {inputURL :: [String]
    ,inputArgs :: [(String, String)]
    } deriving Show

readInput :: String -> Input
readInput (breakOn "?" -> (a,b)) = Input (dropWhile null $ splitOn "/" a) $
    map (second (unEscapeString . drop1) . breakOn "=") $ splitOn "&" $ drop1 b

data Output
    = OutputString LBS.ByteString
    | OutputHTML LBS.ByteString
    | OutputFail LBS.ByteString
    | OutputFile FilePath
      deriving Show

instance NFData Output where
    rnf (OutputString x) = rnf x
    rnf (OutputHTML x) = rnf x
    rnf (OutputFail x) = rnf x
    rnf (OutputFile x) = rnf x


server :: Log -> Bool -> Int -> (Input -> IO Output) -> IO ()
#ifdef PROFILE
server log local port act = return ()
#else
server log local port act = do
    logAddMessage log $ "Server started on port " ++ show port
    let set = setOnExceptionResponse exceptionResponseForDebug
            . setPort port
            . (if local then setHost "127.0.0.1" else id)
    runSettings (set defaultSettings) $ \req reply -> do
        putStrLn $ BS.unpack $ rawPathInfo req <> rawQueryString req
        let pay = Input (map Text.unpack $ pathInfo req)
                        [(strUnpack a, maybe "" strUnpack b) | (a,b) <- queryString req]
        (time,res) <- duration $ try_ $ do s <- act pay; evaluate $ rnf s; return s
        res <- either (fmap Left . showException) (return . Right) res
        logAddEntry log (showSockAddr $ remoteHost req)
            (BS.unpack $ rawPathInfo req <> rawQueryString req) time (either Just (const Nothing) res)
        case res of
            Left s -> reply $ responseLBS status500 [] $ LBS.pack s
            Right v -> reply $ case v of
                OutputFile file -> responseFile status200
                    [("content-type",c) | Just c <- [lookup (takeExtension file) contentType]] file Nothing
                OutputString msg -> responseLBS status200 [] msg
                OutputFail msg -> responseLBS status500 [] msg
                OutputHTML msg -> responseLBS status200 [("content-type","text/html")] msg

contentType = [(".html","text/html"),(".css","text/css"),(".js","text/javascript")]
#endif
