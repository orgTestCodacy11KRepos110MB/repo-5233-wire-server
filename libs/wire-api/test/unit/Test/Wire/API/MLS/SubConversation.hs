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

module Test.Wire.API.MLS.SubConversation where

import Data.Domain
import Data.Id
import Data.Qualified
import Imports
import Test.QuickCheck
import Test.Tasty
import Test.Tasty.QuickCheck
import Wire.API.MLS.SubConversation

tests :: TestTree
tests =
  testGroup
    "Subconversation"
    [ testProperty "injectivity of the initial group ID mapping" $
        forAll genIds injectiveInitialGroupId
    ]
  where
    genIds :: Gen (ConvId, SubConvId, SubConvId)
    genIds = do
      s1 <- arbitrary
      (,,) <$> arbitrary <*> pure s1 <*> arbitrary `suchThat` (/= s1)

injectiveInitialGroupId :: (ConvId, SubConvId, SubConvId) -> Property
injectiveInitialGroupId (cnv, scnv1, scnv2) = do
  let domain = Domain "group.example.com"
      lcnv = toLocalUnsafe domain cnv
  initialGroupId lcnv scnv1 =/= initialGroupId lcnv scnv2