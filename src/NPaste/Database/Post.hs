{-# LANGUAGE NamedFieldPuns, RankNTypes, ViewPatterns, TupleSections #-}

module NPaste.Database.Post
  ( addPost
  ) where

import Control.Monad.IO.Peel
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.ByteString.Lazy (fromChunks, toChunks)
import Data.Maybe
import Data.Time
import Database.HDBC.PostgreSQL
import Happstack.Crypto.MD5 (md5)
import System.Random

import NPaste.Database.Connection
import NPaste.Database.Post.Info
import NPaste.Database.Post.Content
import NPaste.Database.Post.Replies
import NPaste.Database.Post.Tags
import NPaste.Database.Users

import qualified NPaste.Description as P
import NPaste.Types
import NPaste.Utils


--------------------------------------------------------------------------------
-- Errors

data AddPostError
  = APE_UserRequired
  | APE_InvalidCustomId String
  | APE_AlreadyExists (Maybe User) String
  | APE_Other String
  deriving Show

instance Error AddPostError where
  strMsg = APE_Other

type AddPost a = (MonadPeelIO m, Functor m) => ErrorT AddPostError m a

-- | Convert SQL exceptions to APE errors
sqlErrorToAPE :: Maybe User
              -> ByteString     -- ^ MD5 hash
              -> SqlError
              -> AddPost a
sqlErrorToAPE mu hash e =
  case seState e of
       l | l == uniqueViolation -> do
           mpi <- getPostByMD5 mu hash
           throwError $ maybe
             (APE_Other $ show e)
             (APE_AlreadyExists mu . p_id)
             mpi
         | otherwise            ->
           throwError $ APE_Other (show e)


--------------------------------------------------------------------------------
-- Settings

data IdSetting
  = IdDefault
  | IdRandom
  | IdPrivate
  | IdPrivateCustom String

reservedIds :: [String]
reservedIds =
  [ "user", "filter", "api", "bin" ]


--------------------------------------------------------------------------------
-- Add a new post

addPost :: Maybe User               -- ^ optional user of paste
        -> Maybe String             -- ^ file type
        -> Maybe String             -- ^ description
        -> Bool                     -- ^ hidden?
        -> IdSetting
        -> ByteString               -- ^ content
        -> Update (Either AddPostError ())
addPost muser mtype mdesc hide id_settings content = runErrorT $ do
    
  let hash = B.concat . toChunks . md5 $ fromChunks [content]

  -- aquire new ID
  (pid, pid_is_global, pid_is_custom) <-
    case id_settings of
         IdRandom           -> getRandomId 10
         IdDefault          -> getNextId muser True
         IdPrivate          -> getNextId muser False
         IdPrivateCustom c  -> getCustom muser c

  handleSql (sqlErrorToAPE muser hash) $ do
  
    -- add post info
    now <- liftIO getCurrentTime
    addPostInfo hash $ PostInfo
      { p_id           = pid
      , p_user_id      = maybe (-1) u_id muser
      , p_date         = now
      , p_type         = mtype
      , p_description  = mdesc
      , p_hidden       = hide
      , p_id_is_global = pid_is_global
      , p_id_is_custom = pid_is_custom
      }
  
    -- add post content
    addContent muser pid content
  
    -- Add tags & replies if a description is given
    withJust mdesc $ \(P.parseDesc -> descVals) -> do

      -- add replies
      let rpls = P.idsOnly descVals
      rplsWithUsers <- forM rpls $ \(rpid, mruname) ->
        fmap (, rpid) (maybe (return Nothing) getUserByName mruname)
      addReplies muser pid rplsWithUsers

      -- add tags
      let tags = P.tagsOnly descVals
      addTags muser pid tags


--------------------------------------------------------------------------------
-- ID generation

validChars :: [Char]
validChars = ['0'..'9'] ++ ['A'..'Z'] ++ ['a'..'z']

getRandomId :: Int
            -> AddPost (String, Bool, Bool)
getRandomId m = do

  ids   <- getGlobalIds
  n     <- liftIO $ randomRIO (5,m)
  iList <- rnds n (0,length validChars - 1) []

  let pid = map (validChars !!) iList
  if pid `elem` ids
     then getRandomId (m+1)
     else return (pid, True, False)

 where
  rnds :: Int -> (Int, Int) -> [Int] -> AddPost [Int]
  rnds 0 _ akk = return akk
  rnds n r akk = do
    random' <- liftIO $ randomRIO r
    rnds (n-1) r (akk ++ [random'])

getCustom :: Maybe User
          -> String
          -> AddPost (String, Bool, Bool)
getCustom Nothing _ = throwError APE_UserRequired
getCustom (Just u) c = do
  available <- checkCustomId u c
  unless available $
    throwError (APE_InvalidCustomId c)
  return (c, False, True)

getNextId :: Maybe User
          -> Bool
          -> AddPost (String, Bool, Bool)
getNextId mUser global = do
  let global' = global || isNothing mUser
  ids <- if global'
             then getGlobalIds
             else getPrivateIds (fromJust mUser)
  let pid = head $
        dropWhile (\pid' -> pid' `elem` reservedIds || pid' `elem` ids)
                  everything
  return (pid, global', False)
 where
  everything  = concat $ iterate func chars
  func list   = concatMap (\char -> map (char ++) list) chars
  chars       = map (:[]) validChars
