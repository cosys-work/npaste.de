{-# LANGUAGE FlexibleInstances, FlexibleContexts, MultiParamTypeClasses, UndecidableInstances #-}
{-# OPTIONS_GHC -F -pgmFtrhsx #-}

module Paste.View.Info
    ( showInfo
    ) where

import Control.Monad.Trans      (liftIO)

import HSP
import Happstack.Server
import Happstack.State          (query)

import System.Time              (ClockTime (..), toUTCTime, calendarTimeToString, getClockTime)

import Paste.View               (htmlBody, getLogin, xmlResponse)
import Paste.State              (GetAllEntries (..))

import Users.State              (GetAllUsers (..), User (..))

showInfo :: ServerPart Response
showInfo = do
    login       <- getLogin
    now         <- liftIO getClockTime
    pentries    <- query $ GetAllEntries
    users       <- query $ GetAllUsers

    let info = [ Info "Total number of pastes"  $ show (length pentries)
               , Info "Registered users"        $ show (length users)
               , Info "All user names"          $ foldr (\user rest -> (show $ userLogin user) ++ if null rest then rest else (", " ++ rest)) "" users
               ]

    xmlResponse $ htmlBody login [infoHsp now info]


data Info = Info { infoKey :: String
                 , infoVal :: String
                 }

--------------------------------------------------------------------------------
-- HSP definition
--------------------------------------------------------------------------------

infoHsp :: ClockTime -> [Info] -> HSP XML
infoHsp date infos =
    <div id="main">
        <h1>Status information</h1>
        <p>Current status:</p>
        <%
            if null infos
               then <p class="error">No information available.</p>
               else <ul id="info"><% infos %></ul>
        %>
        <p>State: <% calendarTimeToString . toUTCTime $ date %></p>
    </div>


--------------------------------------------------------------------------------
-- XML instances
--------------------------------------------------------------------------------

instance (XMLGenerator m, EmbedAsChild m XML) => (EmbedAsChild m Info) where
    asChild info = <% <li><p><span class="info-key"><% infoKey info %>:</span> <% infoVal info %></p></li> %>