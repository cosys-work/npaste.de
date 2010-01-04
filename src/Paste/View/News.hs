{-# LANGUAGE FlexibleInstances, FlexibleContexts, MultiParamTypeClasses, UndecidableInstances #-}
{-# OPTIONS_GHC -F -pgmFtrhsx #-}

module Paste.View.News
    ( showNews
    ) where

import Data.List                        (sortBy)
import qualified Data.Set as S

import HSP
import Happstack.Server
import Happstack.State                  (query, update)

import System.Time              (ClockTime (..), toUTCTime, calendarTimeToString)

import App.View                         (xmlResponse)
import Paste.View                       (htmlBody, getLogin)
import Paste.State
import Users.State                      (UserOfLogin (..))

showNews :: ServerPart Response
showNews = do

    login    <- getLogin
    rootUser <- query $ UserOfLogin "root" -- root always exists :O
    pastes   <- query $ GetPastesByUser rootUser

    xmlResponse $ htmlBody login [newsHsp . sortDesc . S.toAscList $ S.filter (("news" `elem`) . unPTags . tags) pastes]

  where sortDesc = sortBy $ flip compare

newsHsp :: [PasteEntry] -> HSP XML
newsHsp news =
    <div id="main">
        <h1>News</h1>
        <% news %>
    </div>

--------------------------------------------------------------------------------
-- XML instances
--------------------------------------------------------------------------------

instance (XMLGenerator m, EmbedAsChild m XML) => (EmbedAsChild m [PasteEntry]) where
    asChild [] = <% <p>No news yet.</p> %>
    asChild pe =
        <%
            map `flip` pe $ \entry -> <p class="date">Date: <% calendarTimeToString . toUTCTime . unPDate $ date entry %></p>
        %>