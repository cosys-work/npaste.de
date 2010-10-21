module Paste.Post.NewPaste
    ( newPasteHandler
    ) where

import Happstack.Server
import Happstack.State
import qualified Happstack.Auth.Internal      as Auth
import qualified Happstack.Auth.Internal.Data as AuthD

import Control.Monad.Error
import Control.Applicative                          (optional)

import Codec.Binary.UTF8.Light
import qualified Data.ByteString.UTF8 as BU

import Data.Char                                    (isSpace, toLower)
import Data.Maybe                                   (isJust, isNothing, fromMaybe, catMaybes)
import qualified Data.Map as M

import Text.ParserCombinators.Parsec         hiding (optional)

import System.Directory                             (createDirectoryIfMissing)
import System.FilePath                              (pathSeparator)
import System.Time

import Text.Highlighting.Kate                       (languagesByExtension, languages)

import qualified Paste.Parser.Description as PPD
import Paste.View.Index (showIndex')
import Paste.State
import Paste.Types
import Users.State
import Util.Control

getBody :: RqData a -> ErrorT PostError (ServerPartT IO) (Maybe a)
getBody = fmap (either (const Nothing) Just) . lift . getDataFn . body

-- | Handle incoming post data
newPasteHandler :: ServerPart Response
newPasteHandler = do
    methodM POST
    decodeBody postPolicy
    -- check if we want to reply
    reply  <- body . optional $ look "reply"
    guard $ isNothing reply
    errorT <- runErrorT post

    -- check if we used the html form
    mSubmit <- body . optional $ look "submit"
    -- mFiletype <- getDataBodyFn $ look "filetype"
    let submit = not . null $ fromMaybe "" mSubmit
        -- isTiny | (fromMaybe "" mFiletype) `elem` tinyIds = True
               -- | otherwise = False

    case errorT of
         Left e | submit    -> showIndex' $ Just (show e)
                | otherwise -> badRequest . toResponse $ show e ++ "\n"
         Right url -- | submit && isTiny -> seeOther ("/" ++ url ++ "/plain") $ toResponse ("http://npaste.de/" ++ url ++ "/plain")
                   | submit           -> seeOther ("/" ++ url ++ "/")      $ toResponse ("http://npaste.de/" ++ url ++ "/")
                   | otherwise        -> ok . toResponse $ "http://npaste.de/" ++ url ++ "/\n"

type Url = String

-- | Try to post data, throw PostError if anything goes wrong.
post :: ErrorT PostError (ServerPartT IO) Url
post = do

    decodeBody postPolicy

    -- simple check for spam
    mSpam <- getBody $ look "email" -- email field = spam!
    unless (null $ fromMaybe "" mSpam) (throwError IsSpam)

    -- check if host is allowed to post
    update $ ClearKnownHosts 10
    rq      <- askRq
    let peer = fromMaybe (fst $ rqPeer rq) $
            (\HeaderPair { hValue = (ip:_) } -> BU.toString ip) `fmap` M.lookup (BU.fromString "x-forwarded-for") (rqHeaders rq)
    ctime   <- liftIO getClockTime
    htime   <- query $ GetClockTimeByHost 50 peer
    case htime of
         Just time -> throwError . MaxPastes $ let time' = addToClockTime noTimeDiff { tdHour = 1 } time
                                               in normalizeTimeDiff $ diffClockTimes time' ctime
         _ -> return ()

    -- get and validate our content
    mContent <- getBody $ look "content"
    let content     = stripSpaces $ fromMaybe "" mContent
        maxSize     = 200
        md5content  = md5string content
    when   (null content || all isSpace content)  (throwError NoContent)
    unless (null $ drop (maxSize * 1000) content) (throwError $ ContentTooBig maxSize)

    -- get filetype
    mFiletype <- getBody $ look "filetype"

    let validFiletype f = map toLower f `elem` map (map toLower) languages || not (null $ languagesByExtension f)
        filetype' = msum [ mFiletype >>= \f -> if null f then Nothing else Just f
                         , case parse bangParser "filetype" (head $ lines content) of
                                Right e | validFiletype e -> Just e
                                _ -> Nothing
                         ]
            

    -- get description
    mDescription <- getBody $ look "description"
    let desc = case mDescription of
                    d@(Just a) | not (null a) -> d
                    _ -> Nothing
    unless (null $ drop 300 (fromMaybe "" desc)) (throwError $ DescriptionTooBig 300)

    -- get and validate user
    login <- lift getLogin
    uid   <- case login of

                  LoggedInAs skey -> do
                      sdata <- query $ Auth.GetSession skey
                      case sdata of
                           Just (AuthD.SessionData uid _ _ _) -> return $ Just uid
                           _                              -> return Nothing

                  NotLoggedIn -> do
                      user       <- fmap (fromMaybe "") . getBody $ look "user"
                      password   <- fmap (fromMaybe "") . getBody $ look "password"
                      muser      <- query $ Auth.AuthUser user password
                      case muser of
                           Just AuthD.User { AuthD.userid = uid } -> return $ Just uid
                           _ | null user && null password         -> return Nothing
                             | otherwise                          -> throwError WrongLogin

    -- check if the content is already posted by our user
    peByMd5 <- query $ GetPasteEntryByMd5sum {- validUser -} md5content
    case peByMd5 of
         Just pe -> throwError $ MD5Exists pe
         _       -> return ()

    -- get ids
    mId       <- getBody $ look "id"
    mIdType   <- getBody $ look "id-type"
    mHide     <- getBody $ look "hide"

    -- get default paste settings
    pastesettings <- maybe (return Nothing)
                           (\uid -> fmap defaultPasteSettings `fmap` query (UserDataByUserId uid))
                           uid

    let
        -- make life easier for clients
        idT' | null (fromMaybe "" mIdType) = map toLower $ fromMaybe "" mId
             | otherwise                   = map toLower $ fromMaybe "" mIdType

        -- see if this is supposed to be a non public paste, hide if mId is "rand" or similar
        hide = isJust mHide
            || fmap (map toLower) mId `elem` map Just randomIds
            || pastesettings == Just HideNewPastes
            || pastesettings == Just HideAndRandom

        idT | idT' `elem` randomIds                             = RandomID 10
            | null idT' && pastesettings == Just HideAndRandom  = RandomID 10
            | idT' `elem` defaultIds                            = DefaultID
            | otherwise                                         = CustomID . ID $ fromMaybe "" mId

    id <- query $ GenerateId {- validUser -} idT
    when (NoID == id) (throwError InvalidID)

    -- save to file
    let dir      = "pastes" ++ (maybe "" (([pathSeparator] ++) . ("@" ++) . show . AuthD.unUid) uid)
        filepath = dir ++ [pathSeparator] ++ unId id
    liftIO $ do createDirectoryIfMissing True dir
                writeUTF8File filepath $ encode content

    -- description stuff, tags, responses, TODO: notify users
    let unpackTag (PPD.Tag t) = Just t
        unpackTag _           = Nothing
        unpackId (PPD.ID i) = Just $ ID i
        unpackId _          = Nothing
        -- get tags
        tagList = case desc of
                       Just desc -> catMaybes . map unpackTag $ PPD.parseDesc desc
                       _ -> []
        -- see if we have any links to other pastes
        linkList = case desc of
                        Just desc -> catMaybes . map unpackId $ PPD.parseDesc desc
                        _ -> []

    mapM_ (update . AddResponse id) linkList

    update $ AddPaste PasteEntry { date          = PDate         $ ctime
                                 , content       = PContent      $ File filepath
                                 , user          = PUser         $ uid
                                 , pId           = PId           $ id
                                 , filetype      = PFileType     $ filetype'
                                 , md5hash       = PHash         $ md5content
                                 , description   = PDescription  $ desc
                                 , hide          = PHide         $ hide
                                 , tags          = PTags         $ tagList
                                 }

    -- add to known hosts
    update $ AddKnownHost peer

    -- return url
    return $ unId id

-- | Parse a \"#!/usr/bin...\" string
bangParser :: Parser String
bangParser = do
    string "#!"
    try' $ string "/usr"
    string "/bin/"
    try' $ string "env" >> many1 space
    many letter

  where try' p = try p <|> return ""
