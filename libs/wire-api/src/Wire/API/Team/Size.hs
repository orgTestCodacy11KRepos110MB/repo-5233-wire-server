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

module Wire.API.Team.Size
  ( TeamSize (TeamSize),
    modelTeamSize,
  )
where

import Data.Aeson
import qualified Data.Swagger.Build.Api as Doc
import Imports
import Numeric.Natural

newtype TeamSize = TeamSize Natural
  deriving (Show, Eq)

instance ToJSON TeamSize where
  toJSON (TeamSize s) = object ["teamSize" .= s]

instance FromJSON TeamSize where
  parseJSON =
    withObject "TeamSize" $ \o -> TeamSize <$> o .: "teamSize"

modelTeamSize :: Doc.Model
modelTeamSize = Doc.defineModel "TeamSize" $ do
  Doc.description "A simple object with a total number of team members."
  Doc.property "teamSize" Doc.int32' $ do
    Doc.description "Team size."
