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

module Galley.API.MLS.Removal
  ( removeClientsWithClientMap,
    removeClient,
    removeUser,
  )
where

import Data.Id
import qualified Data.Map as Map
import Data.Qualified
import Data.Time
import Galley.API.Error
import Galley.API.MLS.Conversation
import Galley.API.MLS.Keys (getMLSRemovalKey)
import Galley.API.MLS.Propagate
import Galley.API.MLS.Types
import qualified Galley.Data.Conversation.Types as Data
import Galley.Effects
import Galley.Effects.ProposalStore
import Galley.Effects.SubConversationStore
import Galley.Env
import Imports
import Polysemy
import Polysemy.Error
import Polysemy.Input
import Polysemy.TinyLog
import qualified System.Logger as Log
import Wire.API.Conversation.Protocol
import Wire.API.Federation.API
import Wire.API.MLS.Credential
import Wire.API.MLS.KeyPackage
import Wire.API.MLS.Message
import Wire.API.MLS.Proposal
import Wire.API.MLS.Serialisation
import Wire.API.MLS.SubConversation

-- | Send remove proposals for a set of clients to clients in the ClientMap.
removeClientsWithClientMap ::
  ( Members
      '[ Input UTCTime,
         TinyLog,
         ExternalAccess,
         FederatorAccess,
         GundeckAccess,
         ProposalStore,
         Input Env
       ]
      r,
    Foldable t,
    CallsFed 'Galley "on-mls-message-sent"
  ) =>
  Local ConvOrSubConv ->
  t KeyPackageRef ->
  Qualified UserId ->
  Sem r ()
removeClientsWithClientMap lConvOrSubConv kprefs qusr = do
  let meta = mlsMetaConvOrSub (tUnqualified lConvOrSubConv)
  mKeyPair <- getMLSRemovalKey
  case mKeyPair of
    Nothing -> do
      warn $ Log.msg ("No backend removal key is configured (See 'mlsPrivateKeyPaths' in galley's config). Not able to remove client from MLS conversation." :: Text)
    Just (secKey, pubKey) -> do
      for_ kprefs $ \kpref -> do
        let proposal = mkRemoveProposal kpref
            msg = mkSignedMessage secKey pubKey (cnvmlsGroupId meta) (cnvmlsEpoch meta) (ProposalMessage proposal)
            msgEncoded = encodeMLS' msg
        storeProposal
          (cnvmlsGroupId meta)
          (cnvmlsEpoch meta)
          (proposalRef (cnvmlsCipherSuite meta) proposal)
          ProposalOriginBackend
          proposal
        propagateMessage qusr lConvOrSubConv Nothing msgEncoded

removeClientsWithClientMapRecursively ::
  ( Members
      '[ Input UTCTime,
         TinyLog,
         ExternalAccess,
         FederatorAccess,
         GundeckAccess,
         ProposalStore,
         SubConversationStore,
         Input Env
       ]
      r,
    Foldable f,
    CallsFed 'Galley "on-mls-message-sent"
  ) =>
  Local MLSConversation ->
  (ConvOrSubConv -> f KeyPackageRef) ->
  Qualified UserId ->
  Sem r ()
removeClientsWithClientMapRecursively lMlsConv getKPs qusr = do
  let mainConv = fmap Conv lMlsConv
  removeClientsWithClientMap mainConv (getKPs (tUnqualified mainConv)) qusr

  -- remove this client from all subconversations
  subs <- listSubConversations (mcId (tUnqualified lMlsConv))
  for_ subs $ \sub -> do
    let subConv = fmap (flip SubConv sub) lMlsConv

    -- let kpmap = Map.findWithDefault mempty qusr (scMembers sub)
    removeClientsWithClientMap
      subConv
      (getKPs (tUnqualified subConv))
      qusr

-- | Send remove proposals for a single client of a user to the local conversation.
removeClient ::
  ( Members
      '[ Error InternalError,
         ExternalAccess,
         FederatorAccess,
         GundeckAccess,
         Input Env,
         Input UTCTime,
         MemberStore,
         ProposalStore,
         SubConversationStore,
         TinyLog
       ]
      r,
    CallsFed 'Galley "on-mls-message-sent"
  ) =>
  Local Data.Conversation ->
  Qualified UserId ->
  ClientId ->
  Sem r ()
removeClient lc qusr cid = do
  mMlsConv <- mkMLSConversation (tUnqualified lc)
  for_ mMlsConv $ \mlsConv -> do
    let getKPs = cmLookupRef (mkClientIdentity qusr cid) . membersConvOrSub
    removeClientsWithClientMapRecursively (qualifyAs lc mlsConv) getKPs qusr

-- | Send remove proposals for all clients of the user to the local conversation.
removeUser ::
  ( Members
      '[ Error InternalError,
         ExternalAccess,
         FederatorAccess,
         GundeckAccess,
         Input Env,
         Input UTCTime,
         MemberStore,
         ProposalStore,
         SubConversationStore,
         TinyLog
       ]
      r,
    CallsFed 'Galley "on-mls-message-sent"
  ) =>
  Local Data.Conversation ->
  Qualified UserId ->
  Sem r ()
removeUser lc qusr = do
  mMlsConv <- mkMLSConversation (tUnqualified lc)
  for_ mMlsConv $ \mlsConv -> do
    let getKPs = Map.findWithDefault mempty qusr . membersConvOrSub
    removeClientsWithClientMapRecursively (qualifyAs lc mlsConv) getKPs qusr

listSubConversations ::
  Member SubConversationStore r =>
  ConvId ->
  Sem r [SubConversation]
listSubConversations cid =
  fmap catMaybes $
    listSubConversationIds cid
      >>= traverse (getSubConversation cid)
