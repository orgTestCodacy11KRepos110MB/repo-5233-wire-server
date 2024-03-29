{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

-- This file is part of the Wire Server implementation.
--
-- Copyright (C) 2022 Wire Swiss GmbH <opensource@wire.com>
--
-- This program is free software: you can redistribute it and/or modify it under
-- the terms of the GNU Affero General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option) any
-- later version.
--
-- This program is distributed in the hope that it will be useful, but WITHOUT
-- ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
-- FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
-- details.
--
-- You should have received a copy of the GNU Affero General Public License along
-- with this program. If not, see <https://www.gnu.org/licenses/>.

module Bonanza.Parser.Socklog
  ( SockLogRecord (..),
    sockLogRecordWith,

    -- * re-exports
    Host (..),
  )
where

import Bonanza.Parser.IP
import Bonanza.Parser.Internal
import Bonanza.Parser.Svlogd
import Bonanza.Types
import Control.Applicative (optional)
import Control.Lens ((.~), (?~))
import Data.Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Attoparsec.ByteString.Char8
import Data.Bifunctor
import Data.Text.Lazy (toStrict)
import Data.Text.Lazy.Builder (toLazyText)
import qualified Data.Text.Lazy.Builder.Int as T
import Data.Time (UTCTime)
import Imports

data SockLogRecord a = SockLogRecord
  { sockTime :: !UTCTime,
    sockOrigin :: Maybe Host,
    sockTags :: [(Text, Text)],
    sockMessage :: !a
  }
  deriving (Eq, Show)

instance ToLogEvent a => ToLogEvent (SockLogRecord a) where
  toLogEvent SockLogRecord {..} =
    ( mempty & logTime ?~ sockTime
        & logOrigin .~ sockOrigin
        & logTags .~ tgs
    )
      <> toLogEvent sockMessage
    where
      tgs = Tags . KeyMap.fromList . map (bimap Key.fromText String) $ sockTags

sockLogRecordWith :: Parser a -> Parser (SockLogRecord a)
sockLogRecordWith p =
  SockLogRecord
    <$> svTimestamp <* skipSpace
    <*> optional ((ipv4Host <|> ec2InternalHostname) <* char ':' <* skipSpace)
    <*> option [] (try svTags')
    <*> p
  where
    ipv4Host = Host . showIPv4Text <$> ipv4

ec2InternalHostname :: Parser Host
ec2InternalHostname = do
  pre <- string "ip-"
  a <- octet <* char '-'
  b <- octet <* char '-'
  c <- octet <* char '-'
  d <- octet
  reg <- char '.' *> ec2Region
  _ <- string ".compute.internal"
  pure . Host . mconcat $
    [ toText pre,
      toStrict . toLazyText . mconcat . intersperse "-" $
        map T.decimal [a, b, c, d],
      ".",
      reg,
      ".compute.internal"
    ]

ec2Region :: Parser Text
ec2Region = toText <$> go
  where
    go =
      string "ap-northeast-1"
        <|> string "ap-southeast-1"
        <|> string "ap-southeast-2"
        <|> string "eu-west-1"
        <|> string "sa-east-1"
        <|> string "us-east-1"
        <|> string "us-west-1"
        <|> string "us-west-2"
