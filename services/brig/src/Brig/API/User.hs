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

-- TODO: Move to Brig.User.Account
module Brig.API.User
  ( -- * User Accounts / Profiles
    createUser,
    createUserSpar,
    createUserInviteViaScim,
    checkRestrictedUserCreation,
    Brig.API.User.updateUser,
    changeLocale,
    changeSelfEmail,
    changeEmail,
    changePhone,
    changeHandle,
    CheckHandleResp (..),
    checkHandle,
    Brig.Effects.UserHandleStore.lookupHandle,
    changeManagedBy,
    changeAccountStatus,
    changeSingleAccountStatus,
    Data.lookupAccounts,
    Data.lookupAccount,
    Data.lookupStatus,
    lookupAccountsByIdentity,
    lookupProfile,
    lookupProfiles,
    lookupLocalProfiles,
    getLegalHoldStatus,
    Data.getName,
    Data.lookupLocale,
    Data.lookupUser,
    Data.lookupRichInfo,
    Data.lookupRichInfoMultiUsers,
    removeEmail,
    removePhone,
    revokeIdentity,
    deleteUserNoVerify,
    deleteUsersNoVerify,
    deleteSelfUser,
    verifyDeleteUser,
    ensureAccountDeleted,
    deleteAccount,
    checkHandles,
    isBlacklistedHandle,
    Data.reauthenticate,
    AllowSCIMUpdates (..),

    -- * Activation
    sendActivationCode,
    preverify,
    activate,
    Brig.API.User.lookupActivationCode,
    Data.isActivated,

    -- * Password Management
    changePassword,
    beginPasswordReset,
    completePasswordReset,
    lookupPasswordResetCode,
    Data.lookupPassword,

    -- * Blacklisting
    isBlacklisted,
    blacklistDelete,
    blacklistInsert,

    -- * Phone Prefix blocking
    phonePrefixGet,
    phonePrefixDelete,
    phonePrefixInsert,

    -- * Utilities
    fetchUserIdentity,
  )
where

import qualified Brig.API.Error as Error
import qualified Brig.API.Handler as API (Handler, UserNotAllowedToJoinTeam (..))
import Brig.API.Types
import Brig.API.Util
import Brig.App
import qualified Brig.Code as Code
import Brig.Data.Activation (ActivationEvent (..), activationErrorToRegisterError)
import qualified Brig.Data.Activation as Data
import qualified Brig.Data.Client as Data
import Brig.Data.Connection (countConnections)
import qualified Brig.Data.Connection as Data
import qualified Brig.Data.Properties as Data
import Brig.Data.User
import qualified Brig.Data.User as Data
import Brig.Data.UserKey
import qualified Brig.Data.UserKey as Data
import Brig.Effects.ActivationKeyStore (ActivationKeyStore)
import Brig.Effects.ActivationSupply (ActivationSupply)
import Brig.Effects.BlacklistPhonePrefixStore (BlacklistPhonePrefixStore)
import qualified Brig.Effects.BlacklistPhonePrefixStore as BlacklistPhonePrefixStore
import Brig.Effects.BlacklistStore (BlacklistStore)
import qualified Brig.Effects.BlacklistStore as BlacklistStore
import Brig.Effects.ClientStore
import Brig.Effects.GalleyAccess
import Brig.Effects.GundeckAccess
import Brig.Effects.PasswordResetStore (PasswordResetStore)
import qualified Brig.Effects.PasswordResetStore as E
import Brig.Effects.PasswordResetSupply (PasswordResetSupply)
import qualified Brig.Effects.PasswordResetSupply as E
import Brig.Effects.Twilio (Twilio)
import Brig.Effects.UniqueClaimsStore
import Brig.Effects.UserHandleStore
import Brig.Effects.UserKeyStore (UserKeyStore)
import Brig.Effects.UserPendingActivationStore (UserPendingActivation (..), UserPendingActivationStore)
import qualified Brig.Effects.UserPendingActivationStore as UserPendingActivationStore
import Brig.Effects.UserQuery (UserQuery)
import Brig.Effects.VerificationCodeStore
import qualified Brig.Federation.Client as Federation
import qualified Brig.IO.Intra as Intra
import qualified Brig.InternalEvent.Types as Internal
import Brig.Options hiding (Timeout, internalEvents)
import qualified Brig.Options as Opt
import Brig.Password
import qualified Brig.Queue as Queue
import qualified Brig.Team.DB as Team
import Brig.Team.Types (ShowOrHideInvitationUrl (..))
import Brig.Types.Activation (ActivationPair)
import Brig.Types.Connection
import Brig.Types.Intra
import Brig.Types.User (HavePendingInvitations (..), ManagedByUpdate (..), PasswordResetPair)
import Brig.Types.User.Event
import Brig.User.Auth.Cookie (listCookies, revokeAllCookies)
import Brig.User.Email
import Brig.User.Handle hiding (lookupHandle)
import Brig.User.Handle.Blacklist
import Brig.User.Phone
import Brig.User.Search.Index (reindex)
import qualified Brig.User.Search.TeamSize as TeamSize
import Cassandra
import Control.Arrow ((&&&))
import Control.Error
import Control.Lens (view, (^.))
import Control.Monad.Catch
import Data.ByteString.Conversion
import Data.Code
import qualified Data.Currency as Currency
import Data.Handle (Handle (fromHandle), parseHandle)
import Data.Id as Id
import Data.Json.Util
import Data.LegalHold (UserLegalHoldStatus (..), defUserLegalHoldStatus)
import Data.List.Extra
import Data.List.NonEmpty (NonEmpty)
import qualified Data.Map.Strict as Map
import qualified Data.Metrics as Metrics
import Data.Misc (PlainTextPassword (..))
import Data.Qualified
import Data.Time.Clock (addUTCTime, diffUTCTime)
import Data.UUID.V4 (nextRandom)
import qualified Galley.Types.Teams as Team
import qualified Galley.Types.Teams.Intra as Team
import Imports
import Network.Wai.Utilities
import Polysemy
import Polysemy.Async
import Polysemy.Conc.Effect.Race (Race)
import qualified Polysemy.Error as P
import Polysemy.Input
import Polysemy.Resource hiding (onException)
import qualified Polysemy.TinyLog as P
import qualified Ropes.Twilio as Twilio
import System.Logger.Class (MonadLogger)
import qualified System.Logger.Class as Log
import System.Logger.Message
import Wire.API.Connection
import Wire.API.Error
import qualified Wire.API.Error.Brig as E
import Wire.API.Federation.Error
import Wire.API.Routes.Internal.Brig.Connection
import Wire.API.Team hiding (newTeam)
import Wire.API.Team.Feature (forgetLock)
import Wire.API.Team.Invitation
import qualified Wire.API.Team.Invitation as Team
import Wire.API.Team.Member (TeamMember, legalHoldStatus)
import Wire.API.Team.Role
import Wire.API.Team.Size
import Wire.API.User
import Wire.API.User.Activation
import Wire.API.User.Client
import Wire.API.User.Password
import Wire.API.User.RichInfo

data AllowSCIMUpdates
  = AllowSCIMUpdates
  | ForbidSCIMUpdates
  deriving (Show, Eq, Ord)

-------------------------------------------------------------------------------
-- Create User

data IdentityError
  = IdentityErrorBlacklistedEmail
  | IdentityErrorBlacklistedPhone
  | IdentityErrorUserKeyExists

identityErrorToRegisterError :: IdentityError -> RegisterError
identityErrorToRegisterError = \case
  IdentityErrorBlacklistedEmail -> RegisterErrorBlacklistedEmail
  IdentityErrorBlacklistedPhone -> RegisterErrorBlacklistedPhone
  IdentityErrorUserKeyExists -> RegisterErrorUserKeyExists

identityErrorToBrigError :: IdentityError -> Error.Error
identityErrorToBrigError = \case
  IdentityErrorBlacklistedEmail -> Error.StdError $ errorToWai @'E.BlacklistedEmail
  IdentityErrorBlacklistedPhone -> Error.StdError $ errorToWai @'E.BlacklistedPhone
  IdentityErrorUserKeyExists -> Error.StdError $ errorToWai @'E.UserKeyExists

verifyUniquenessAndCheckBlacklist ::
  Members
    '[ BlacklistStore,
       UserKeyStore,
       UserQuery p
     ]
    r =>
  UserKey ->
  ExceptT IdentityError (AppT r) ()
verifyUniquenessAndCheckBlacklist uk = do
  liftSemE $ checkKey Nothing uk
  blacklisted <- lift $ liftSem $ BlacklistStore.exists uk
  when blacklisted $
    throwE (foldKey (const IdentityErrorBlacklistedEmail) (const IdentityErrorBlacklistedPhone) uk)
  where
    checkKey u k = do
      av <- lift $ Data.keyAvailable k u
      unless av $
        throwE IdentityErrorUserKeyExists

createUserSpar ::
  forall r p.
  Members
    '[ Async,
       GalleyAccess,
       GundeckAccess,
       Race,
       Resource,
       UniqueClaimsStore,
       UserHandleStore,
       UserQuery p
     ]
    r =>
  NewUserSpar ->
  ExceptT CreateUserSparError (AppT r) CreateUserResult
createUserSpar new = do
  let handle' = newUserSparHandle new
      new' = newUserFromSpar new
      ident = newUserSparSSOId new
      tid = newUserSparTeamId new

  -- Create account
  account <- lift $ do
    (account, pw) <- wrapClient $ newAccount new' Nothing (Just tid) handle'

    let uid = userId (accountUser account)

    -- FUTUREWORK: make this transactional if possible
    liftSem $ Data.insertAccount account Nothing pw False
    case unRichInfo <$> newUserSparRichInfo new of
      Just richInfo -> wrapClient $ Data.updateRichInfo uid richInfo
      Nothing -> pure () -- Nothing to do
    wrapHttp $ Intra.createSelfConv uid
    Intra.onUserEvent uid Nothing (UserCreated (accountUser account))

    pure account

  -- Add to team
  userTeam <- withExceptT CreateUserSparRegistrationError $ addUserToTeamSSO account tid (SSOIdentity ident Nothing Nothing)

  -- Set up feature flags
  let uid = userId (accountUser account)
  lift $ initAccountFeatureConfig uid

  -- Set handle
  updateHandle' uid handle'

  pure $! CreateUserResult account Nothing Nothing (Just userTeam)
  where
    updateHandle' :: UserId -> Maybe Handle -> ExceptT CreateUserSparError (AppT r) ()
    updateHandle' _ Nothing = pure ()
    updateHandle' uid (Just h) = do
      case parseHandle . fromHandle $ h of
        Just handl -> withExceptT CreateUserSparHandleError $ changeHandle uid Nothing handl AllowSCIMUpdates
        Nothing -> throwE $ CreateUserSparHandleError ChangeHandleInvalid

    addUserToTeamSSO :: UserAccount -> TeamId -> UserIdentity -> ExceptT RegisterError (AppT r) CreateUserTeam
    addUserToTeamSSO account tid ident = do
      let uid = userId (accountUser account)
      added <- lift $ wrapHttp $ Intra.addTeamMember uid tid (Nothing, defaultRole)
      unless added $
        throwE RegisterErrorTooManyTeamMembers
      lift $ do
        liftSem $ activateUser uid ident
        void $ onActivated (AccountActivated account)
        Log.info $
          field "user" (toByteString uid)
            . field "team" (toByteString tid)
            . msg (val "Added via SSO")
      Team.TeamName nm <- lift $ wrapHttp $ Intra.getTeamName tid
      pure $ CreateUserTeam tid nm

-- docs/reference/user/registration.md {#RefRegistration}
createUser ::
  forall r p.
  Members
    '[ ActivationKeyStore,
       ActivationSupply,
       BlacklistStore,
       GalleyAccess,
       GundeckAccess,
       Input (Local ()),
       P.Error Twilio.ErrorResponse,
       PasswordResetSupply,
       PasswordResetStore,
       Twilio,
       UserKeyStore,
       UserPendingActivationStore p,
       UserQuery p
     ]
    r =>
  NewUser ->
  ExceptT RegisterError (AppT r) CreateUserResult
createUser new = do
  (email, phone) <- validateEmailAndPhone new

  -- get invitation and existing account
  (newTeam, teamInvitation, tid) <-
    case newUserTeam new of
      Just (NewTeamMember i) -> do
        mbTeamInv <- findTeamInvitation (userEmailKey <$> email) i
        case mbTeamInv of
          Just (inv, info, tid) ->
            pure (Nothing, Just (inv, info), Just tid)
          Nothing ->
            pure (Nothing, Nothing, Nothing)
      Just (NewTeamCreator t) -> do
        (Just t,Nothing,) <$> (Just . Id <$> liftIO nextRandom)
      Just (NewTeamMemberSSO tid) ->
        pure (Nothing, Nothing, Just tid)
      Nothing ->
        pure (Nothing, Nothing, Nothing)
  let mbInv = Team.inInvitation . fst <$> teamInvitation
  locale <- setDefaultUserLocale <$> view settings
  mbExistingAccount <- lift $ join <$> for mbInv (\(Id uuid) -> liftSem $ Data.lookupAccount locale (Id uuid))

  let (new', mbHandle) = case mbExistingAccount of
        Nothing ->
          ( new {newUserIdentity = newIdentity email phone (newUserSSOId new)},
            Nothing
          )
        Just existingAccount ->
          let existingUser = accountUser existingAccount
              mbSSOid =
                case (teamInvitation, email, userManagedBy existingUser) of
                  -- isJust teamInvitation And ManagedByScim implies that the
                  -- user invitation has been generated by SCIM and there is no IdP
                  (Just _, Just em, ManagedByScim) ->
                    Just $ UserScimExternalId (fromEmail em)
                  _ -> newUserSSOId new
           in ( new
                  { newUserManagedBy = Just (userManagedBy existingUser),
                    newUserIdentity = newIdentity email phone mbSSOid
                  },
                userHandle existingUser
              )

  -- Create account
  account <- lift $ do
    (account, pw) <- wrapClient $ newAccount new' mbInv tid mbHandle

    let uid = userId (accountUser account)
    Log.debug $ field "user" (toByteString uid) . field "action" (Log.val "User.createUser")
    Log.info $ field "user" (toByteString uid) . msg (val "Creating user")

    liftSem $ Data.insertAccount account Nothing pw False
    wrapHttp $ Intra.createSelfConv uid
    Intra.onUserEvent uid Nothing (UserCreated (accountUser account))

    pure account

  let uid = userId (accountUser account)

  createUserTeam <- do
    activatedTeam <- lift $ do
      case (tid, newTeam) of
        (Just tid', Just nt) -> do
          created <- wrapHttp $ Intra.createTeam uid (bnuTeam nt) tid'
          let activating = isJust (newUserEmailCode new)
          pure $
            if activating
              then Just created
              else Nothing
        _ -> pure Nothing

    joinedTeamInvite <- case teamInvitation of
      Just (inv, invInfo) -> do
        let em = Team.inInviteeEmail inv
        acceptTeamInvitation account inv invInfo (userEmailKey em) (EmailIdentity em)
        Team.TeamName nm <- lift $ wrapHttp $ Intra.getTeamName (Team.inTeam inv)
        pure (Just $ CreateUserTeam (Team.inTeam inv) nm)
      Nothing -> pure Nothing

    joinedTeamSSO <- case (newUserIdentity new', tid) of
      (Just ident@(SSOIdentity (UserSSOId _) _ _), Just tid') -> Just <$> addUserToTeamSSO account tid' ident
      _ -> pure Nothing

    pure (activatedTeam <|> joinedTeamInvite <|> joinedTeamSSO)

  edata <-
    if isJust teamInvitation
      then pure Nothing
      else handleEmailActivation email uid newTeam

  pdata <- handlePhoneActivation phone uid

  lift $ initAccountFeatureConfig uid

  pure $! CreateUserResult account edata pdata createUserTeam
  where
    -- NOTE: all functions in the where block don't use any arguments of createUser

    validateEmailAndPhone ::
      NewUser ->
      ExceptT RegisterError (AppT r) (Maybe Email, Maybe Phone)
    validateEmailAndPhone newUser = do
      -- Validate e-mail
      email <- for (newUserEmail newUser) $ \e ->
        either
          (const $ throwE RegisterErrorInvalidEmail)
          pure
          (validateEmail e)

      -- Validate phone
      phone <- for (newUserPhone newUser) $ \p ->
        maybe
          (throwE RegisterErrorInvalidPhone)
          pure
          =<< lift (liftSem $ validatePhone p)

      for_ (catMaybes [userEmailKey <$> email, userPhoneKey <$> phone]) $ \k ->
        verifyUniquenessAndCheckBlacklist k !>> identityErrorToRegisterError

      pure (email, phone)

    findTeamInvitation :: Maybe UserKey -> InvitationCode -> ExceptT RegisterError (AppT r) (Maybe (Team.Invitation, Team.InvitationInfo, TeamId))
    findTeamInvitation Nothing _ = throwE RegisterErrorMissingIdentity
    findTeamInvitation (Just e) c =
      lift (wrapClient $ Team.lookupInvitationInfo c) >>= \case
        Just ii -> do
          inv <- lift . wrapClient $ Team.lookupInvitation HideInvitationUrl (Team.iiTeam ii) (Team.iiInvId ii)
          case (inv, Team.inInviteeEmail <$> inv) of
            (Just invite, Just em)
              | e == userEmailKey em -> do
                _ <- ensureMemberCanJoin (Team.iiTeam ii)
                pure $ Just (invite, ii, Team.iiTeam ii)
            _ -> throwE RegisterErrorInvalidInvitationCode
        Nothing -> throwE RegisterErrorInvalidInvitationCode

    ensureMemberCanJoin :: TeamId -> ExceptT RegisterError (AppT r) ()
    ensureMemberCanJoin tid = do
      maxSize <- fromIntegral . setMaxTeamSize <$> view settings
      (TeamSize teamSize) <- TeamSize.teamSize tid
      when (teamSize >= maxSize) $
        throwE RegisterErrorTooManyTeamMembers
      -- FUTUREWORK: The above can easily be done/tested in the intra call.
      --             Remove after the next release.
      canAdd <- lift $ wrapHttp $ Intra.checkUserCanJoinTeam tid
      case canAdd of
        Just e -> throwM $ API.UserNotAllowedToJoinTeam e
        Nothing -> pure ()

    acceptTeamInvitation ::
      UserAccount ->
      Team.Invitation ->
      Team.InvitationInfo ->
      UserKey ->
      UserIdentity ->
      ExceptT RegisterError (AppT r) ()
    acceptTeamInvitation account inv ii uk ident = do
      let uid = userId (accountUser account)
      d <- view digestSHA256
      ok <- lift . liftSem $ Data.claimKey d uk uid
      unless ok $
        throwE RegisterErrorUserKeyExists
      let minvmeta :: (Maybe (UserId, UTCTimeMillis), Role)
          minvmeta = ((,inCreatedAt inv) <$> inCreatedBy inv, Team.inRole inv)
      added <- lift $ wrapHttp $ Intra.addTeamMember uid (Team.iiTeam ii) minvmeta
      unless added $
        throwE RegisterErrorTooManyTeamMembers
      lift $ do
        liftSem $ activateUser uid ident -- ('insertAccount' sets column activated to False; here it is set to True.)
        void $ onActivated (AccountActivated account)
        Log.info $
          field "user" (toByteString uid)
            . field "team" (toByteString $ Team.iiTeam ii)
            . msg (val "Accepting invitation")
        liftSem $ UserPendingActivationStore.remove uid
        wrapClient $ do
          Team.deleteInvitation (Team.inTeam inv) (Team.inInvitation inv)

    addUserToTeamSSO :: UserAccount -> TeamId -> UserIdentity -> ExceptT RegisterError (AppT r) CreateUserTeam
    addUserToTeamSSO account tid ident = do
      let uid = userId (accountUser account)
      added <- lift $ wrapHttp $ Intra.addTeamMember uid tid (Nothing, defaultRole)
      unless added $
        throwE RegisterErrorTooManyTeamMembers
      lift $ do
        liftSem $ activateUser uid ident
        void $ onActivated (AccountActivated account)
        Log.info $
          field "user" (toByteString uid)
            . field "team" (toByteString tid)
            . msg (val "Added via SSO")
      Team.TeamName nm <- lift $ wrapHttp $ Intra.getTeamName tid
      pure $ CreateUserTeam tid nm

    -- Handle e-mail activation (deprecated, see #RefRegistrationNoPreverification in /docs/reference/user/registration.md)
    handleEmailActivation :: Maybe Email -> UserId -> Maybe BindingNewTeamUser -> ExceptT RegisterError (AppT r) (Maybe Activation)
    handleEmailActivation email uid newTeam = do
      fmap join . for (userEmailKey <$> email) $ \ek -> case newUserEmailCode new of
        Nothing -> do
          timeout <- setActivationTimeout <$> view settings
          edata <- lift . liftSem $ Data.newActivation ek timeout (Just uid)
          lift . Log.info $
            field "user" (toByteString uid)
              . field "activation.key" (toByteString $ activationKey edata)
              . msg (val "Created email activation key/code pair")
          pure $ Just edata
        Just c -> do
          ak <- liftIO $ Data.mkActivationKey ek
          void $
            activateWithCurrency (ActivateKey ak) c (Just uid) (bnuCurrency =<< newTeam)
              !>> activationErrorToRegisterError
          pure Nothing

    -- Handle phone activation (deprecated, see #RefRegistrationNoPreverification in /docs/reference/user/registration.md)
    handlePhoneActivation :: Maybe Phone -> UserId -> ExceptT RegisterError (AppT r) (Maybe Activation)
    handlePhoneActivation phone uid = do
      fmap join . for (userPhoneKey <$> phone) $ \pk -> case newUserPhoneCode new of
        Nothing -> do
          timeout <- setActivationTimeout <$> view settings
          pdata <- lift . liftSem $ Data.newActivation pk timeout (Just uid)
          lift . Log.info $
            field "user" (toByteString uid)
              . field "activation.key" (toByteString $ activationKey pdata)
              . msg (val "Created phone activation key/code pair")
          pure $ Just pdata
        Just c -> do
          ak <- liftIO $ Data.mkActivationKey pk
          void $ activate (ActivateKey ak) c (Just uid) !>> activationErrorToRegisterError
          pure Nothing

initAccountFeatureConfig :: UserId -> (AppT r) ()
initAccountFeatureConfig uid = do
  mbCciDefNew <- view (settings . getAfcConferenceCallingDefNewMaybe)
  forM_ (forgetLock <$> mbCciDefNew) $ wrapClient . Data.updateFeatureConferenceCalling uid . Just

-- | 'createUser' is becoming hard to maintian, and instead of adding more case distinctions
-- all over the place there, we add a new function that handles just the one new flow where
-- users are invited to the team via scim.
createUserInviteViaScim ::
  Members
    '[ BlacklistStore,
       UserKeyStore,
       UserPendingActivationStore p,
       UserQuery p
     ]
    r =>
  UserId ->
  NewUserScimInvitation ->
  ExceptT Error.Error (AppT r) UserAccount
createUserInviteViaScim uid (NewUserScimInvitation tid loc name rawEmail) = do
  email <- either (const . throwE . Error.StdError $ errorToWai @'E.InvalidEmail) pure (validateEmail rawEmail)
  let emKey = userEmailKey email
  verifyUniquenessAndCheckBlacklist emKey !>> identityErrorToBrigError
  account <- lift . wrapClient $ newAccountInviteViaScim uid tid loc name email
  lift . Log.debug $ field "user" (toByteString . userId . accountUser $ account) . field "action" (Log.val "User.createUserInviteViaScim")

  -- add the expiry table entry first!  (if brig creates an account, and then crashes before
  -- creating the expiry table entry, gc will miss user data.)
  expiresAt <- do
    ttl <- setTeamInvitationTimeout <$> view settings
    now <- liftIO =<< view currentTime
    pure $ addUTCTime (realToFrac ttl) now
  lift . liftSem $ UserPendingActivationStore.add (UserPendingActivation uid expiresAt)

  let activated =
        -- treating 'PendingActivation' as 'Active', but then 'Brig.Data.User.toIdentity'
        -- would not produce an identity, and so we won't have the email address to construct
        -- the SCIM user.
        True
  lift . liftSem $ Data.insertAccount account Nothing Nothing activated

  pure account

-- | docs/reference/user/registration.md {#RefRestrictRegistration}.
checkRestrictedUserCreation :: NewUser -> ExceptT RegisterError (AppT r) ()
checkRestrictedUserCreation new = do
  restrictPlease <- lift . asks $ fromMaybe False . setRestrictUserCreation . view settings
  when
    ( restrictPlease
        && not (isNewUserTeamMember new)
        && not (isNewUserEphemeral new)
    )
    $ throwE RegisterErrorUserCreationRestricted

-------------------------------------------------------------------------------
-- Update Profile

updateUser ::
  Members
    '[ GalleyAccess,
       GundeckAccess,
       UserQuery p
     ]
    r =>
  UserId ->
  Maybe ConnId ->
  UserUpdate ->
  AllowSCIMUpdates ->
  ExceptT UpdateProfileError (AppT r) ()
updateUser uid mconn uu allowScim = do
  loc <- fmap (qTagUnsafe @'QLocal) $ Qualified () <$> viewFederationDomain
  locale <- setDefaultUserLocale <$> view settings
  for_ (uupName uu) $ \newName -> do
    mbUser <- lift . liftSem $ Data.lookupUser loc locale WithPendingInvitations uid
    user <- maybe (throwE ProfileNotFound) pure mbUser
    unless
      ( userManagedBy user /= ManagedByScim
          || userDisplayName user == newName
          || allowScim == AllowSCIMUpdates
      )
      $ throwE DisplayNameManagedByScim
  lift $ do
    wrapClient $ Data.updateUser uid uu
    Intra.onUserEvent uid mconn (profileUpdated uid uu)

-------------------------------------------------------------------------------
-- Update Locale

changeLocale ::
  Members
    '[ GalleyAccess,
       GundeckAccess
     ]
    r =>
  UserId ->
  ConnId ->
  LocaleUpdate ->
  AppT r ()
changeLocale uid conn (LocaleUpdate loc) = do
  wrapClient $ Data.updateLocale uid loc
  Intra.onUserEvent uid (Just conn) (localeUpdate uid loc)

-------------------------------------------------------------------------------
-- Update ManagedBy

changeManagedBy ::
  Members
    '[ GalleyAccess,
       GundeckAccess
     ]
    r =>
  UserId ->
  ConnId ->
  ManagedByUpdate ->
  AppT r ()
changeManagedBy uid conn (ManagedByUpdate mb) = do
  wrapClient $ Data.updateManagedBy uid mb
  Intra.onUserEvent uid (Just conn) (managedByUpdate uid mb)

--------------------------------------------------------------------------------
-- Change Handle

changeHandle ::
  Members
    '[ Async,
       GalleyAccess,
       GundeckAccess,
       Race,
       Resource,
       UniqueClaimsStore,
       UserHandleStore,
       UserQuery p
     ]
    r =>
  UserId ->
  Maybe ConnId ->
  Handle ->
  AllowSCIMUpdates ->
  ExceptT ChangeHandleError (AppT r) ()
changeHandle uid mconn hdl allowScim = do
  when (isBlacklistedHandle hdl) $
    throwE ChangeHandleInvalid
  loc <- fmap (qTagUnsafe @'QLocal) $ Qualified () <$> viewFederationDomain
  locale <- setDefaultUserLocale <$> view settings
  usr <- lift . liftSem $ Data.lookupUser loc locale WithPendingInvitations uid
  case usr of
    Nothing -> throwE ChangeHandleNoIdentity
    Just u -> do
      unless
        ( userManagedBy u /= ManagedByScim
            || Just hdl == userHandle u
            || allowScim == AllowSCIMUpdates
        )
        $ throwE ChangeHandleManagedByScim
      claim u
  where
    claim u = do
      unless (isJust (userIdentity u)) $
        throwE ChangeHandleNoIdentity
      claimed <- lift . liftSem $ claimHandle (userId u) (userHandle u) hdl
      unless claimed $
        throwE ChangeHandleExists
      lift $ Intra.onUserEvent uid mconn (handleUpdated uid hdl)

--------------------------------------------------------------------------------
-- Check Handle

data CheckHandleResp
  = CheckHandleInvalid
  | CheckHandleFound
  | CheckHandleNotFound

checkHandle ::
  Members '[UserHandleStore] r =>
  Text ->
  API.Handler r CheckHandleResp
checkHandle uhandle = do
  xhandle <- validateHandle uhandle
  owner <- lift . liftSem $ lookupHandle xhandle
  if
      | isJust owner ->
        -- Handle is taken (=> getHandleInfo will return 200)
        pure CheckHandleFound
      | isBlacklistedHandle xhandle ->
        -- Handle is free but cannot be taken
        --
        -- FUTUREWORK: i wonder if this is correct?  isn't this the error for malformed
        -- handles?  shouldn't we throw not-found here?  or should there be a fourth case
        -- 'CheckHandleBlacklisted'?
        pure CheckHandleInvalid
      | otherwise ->
        -- Handle is free and can be taken
        pure CheckHandleNotFound

--------------------------------------------------------------------------------
-- Check Handles

checkHandles ::
  Member UserHandleStore r =>
  [Handle] ->
  Word ->
  Sem r [Handle]
checkHandles check num = reverse <$> collectFree [] check num
  where
    collectFree free _ 0 = pure free
    collectFree free [] _ = pure free
    collectFree free (h : hs) n =
      if isBlacklistedHandle h
        then collectFree free hs n
        else do
          owner <- glimpseHandle h
          case owner of
            Nothing -> collectFree (h : free) hs (n - 1)
            Just _ -> collectFree free hs n

-------------------------------------------------------------------------------
-- Change Email

-- | Call 'changeEmail' and process result: if email changes to itself, succeed, if not, send
-- validation email.
changeSelfEmail ::
  Members
    '[ ActivationKeyStore,
       ActivationSupply,
       BlacklistStore,
       UserKeyStore,
       UserQuery p
     ]
    r =>
  UserId ->
  Email ->
  AllowSCIMUpdates ->
  ExceptT Error.Error (AppT r) ChangeEmailResponse
changeSelfEmail u email allowScim = do
  changeEmail u email allowScim !>> Error.changeEmailError >>= \case
    ChangeEmailIdempotent ->
      pure ChangeEmailResponseIdempotent
    ChangeEmailNeedsActivation (usr, adata, en) -> lift $ do
      sendOutEmail usr adata en
      wrapClient $ Data.updateEmailUnvalidated u email
      wrapClient $ reindex u
      pure ChangeEmailResponseNeedsActivation
  where
    sendOutEmail usr adata en = do
      sendActivationMail
        en
        (userDisplayName usr)
        (activationKey adata, activationCode adata)
        (Just (userLocale usr))
        (userIdentity usr)

-- | Prepare changing the email (checking a number of invariants).
changeEmail ::
  Members
    '[ ActivationKeyStore,
       ActivationSupply,
       BlacklistStore,
       UserKeyStore,
       UserQuery p
     ]
    r =>
  UserId ->
  Email ->
  AllowSCIMUpdates ->
  ExceptT ChangeEmailError (AppT r) ChangeEmailResult
changeEmail u email allowScim = do
  em <-
    either
      (throwE . InvalidNewEmail email)
      pure
      (validateEmail email)
  let ek = userEmailKey em
  blacklisted <- lift . liftSem $ BlacklistStore.exists ek
  when blacklisted $
    throwE (ChangeBlacklistedEmail email)
  available <- lift . liftSem $ Data.keyAvailable ek (Just u)
  unless available $
    throwE $
      EmailExists email
  loc <- fmap (qTagUnsafe @'QLocal) $ Qualified () <$> viewFederationDomain
  locale <- setDefaultUserLocale <$> view settings
  usr <-
    maybe (throwM $ UserProfileNotFound u) pure
      =<< lift (liftSem $ Data.lookupUser loc locale WithPendingInvitations u)
  case emailIdentity =<< userIdentity usr of
    -- The user already has an email address and the new one is exactly the same
    Just current | current == em -> pure ChangeEmailIdempotent
    _ -> do
      unless
        ( userManagedBy usr /= ManagedByScim
            || allowScim == AllowSCIMUpdates
        )
        $ throwE EmailManagedByScim
      timeout <- setActivationTimeout <$> view settings
      act <- lift . liftSem $ Data.newActivation ek timeout (Just u)
      pure $ ChangeEmailNeedsActivation (usr, act, em)

-------------------------------------------------------------------------------
-- Change Phone

changePhone ::
  Members
    '[ ActivationKeyStore,
       ActivationSupply,
       BlacklistStore,
       BlacklistPhonePrefixStore,
       P.Error Twilio.ErrorResponse,
       Twilio,
       UserKeyStore,
       UserQuery p
     ]
    r =>
  UserId ->
  Phone ->
  ExceptT ChangePhoneError (AppT r) (Activation, Phone)
changePhone u phone = do
  canonical <-
    maybe
      (throwE InvalidNewPhone)
      pure
      =<< lift (liftSem $ validatePhone phone)
  let pk = userPhoneKey canonical
  available <- lift . liftSem $ Data.keyAvailable pk (Just u)
  unless available $
    throwE PhoneExists
  timeout <- setActivationTimeout <$> view settings
  blacklisted <- lift . liftSem $ BlacklistStore.exists pk
  when blacklisted $
    throwE BlacklistedNewPhone
  -- check if any prefixes of this phone number are blocked
  prefixExcluded <- lift . liftSem $ BlacklistPhonePrefixStore.existsAny canonical
  when prefixExcluded $
    throwE BlacklistedNewPhone
  act <- lift . liftSem $ Data.newActivation pk timeout (Just u)
  pure (act, canonical)

-------------------------------------------------------------------------------
-- Remove Email

removeEmail ::
  Members
    '[ GalleyAccess,
       GundeckAccess,
       Input (Local ()),
       UserKeyStore,
       UserQuery p
     ]
    r =>
  UserId ->
  ConnId ->
  ExceptT RemoveIdentityError (AppT r) ()
removeEmail uid conn = do
  ident <- lift $ fetchUserIdentity uid
  d <- view digestSHA256
  case ident of
    Just (FullIdentity e _) -> lift $ do
      liftSem . deleteKey d $ userEmailKey e
      wrapClient $ Data.deleteEmail uid
      Intra.onUserEvent uid (Just conn) (emailRemoved uid e)
    Just _ -> throwE LastIdentity
    Nothing -> throwE NoIdentity

-------------------------------------------------------------------------------
-- Remove Phone

removePhone ::
  Members
    '[ GalleyAccess,
       GundeckAccess,
       Input (Local ()),
       UserKeyStore,
       UserQuery p
     ]
    r =>
  UserId ->
  ConnId ->
  ExceptT RemoveIdentityError (AppT r) ()
removePhone uid conn = do
  ident <- lift $ fetchUserIdentity uid
  d <- view digestSHA256
  case ident of
    Just (FullIdentity _ p) -> do
      pw <- lift . wrapClient $ Data.lookupPassword uid
      unless (isJust pw) $
        throwE NoPassword
      lift $ do
        liftSem . deleteKey d $ userPhoneKey p
        wrapClient $ Data.deletePhone uid
        Intra.onUserEvent uid (Just conn) (phoneRemoved uid p)
    Just _ -> throwE LastIdentity
    Nothing -> throwE NoIdentity

-------------------------------------------------------------------------------
-- Forcefully revoke a verified identity

revokeIdentity ::
  forall r p.
  Members
    '[ GalleyAccess,
       GundeckAccess,
       Input (Local ()),
       UserKeyStore,
       UserQuery p
     ]
    r =>
  Either Email Phone ->
  AppT r ()
revokeIdentity key = do
  let uk = either userEmailKey userPhoneKey key
  mu <- liftSem $ Data.getKey uk
  case mu of
    Nothing -> pure ()
    Just u ->
      fetchUserIdentity u >>= \case
        Just (FullIdentity _ _) -> revokeKey u uk
        Just (EmailIdentity e) | Left e == key -> do
          revokeKey u uk
          wrapClient $ Data.deactivateUser u
        Just (PhoneIdentity p) | Right p == key -> do
          revokeKey u uk
          wrapClient $ Data.deactivateUser u
        _ -> pure ()
  where
    revokeKey :: UserId -> UserKey -> AppT r ()
    revokeKey u uk = do
      d <- view digestSHA256
      liftSem $ deleteKey d uk
      wrapClient $
        foldKey
          (\(_ :: Email) -> Data.deleteEmail u)
          (\(_ :: Phone) -> Data.deletePhone u)
          uk
      Intra.onUserEvent u Nothing $
        foldKey
          (emailRemoved u)
          (phoneRemoved u)
          uk

-------------------------------------------------------------------------------
-- Change Account Status

changeAccountStatus ::
  forall r p.
  Members
    '[ GalleyAccess,
       GundeckAccess,
       UserQuery p
     ]
    r =>
  NonEmpty UserId ->
  AccountStatus ->
  ExceptT AccountStatusError (AppT r) ()
changeAccountStatus usrs status = do
  ev <- wrapClientE $ mkUserEvent usrs status
  lift $ do
    -- mapConcurrently_ (update ev) usrs
    -- TODO(md): do this updating concurrently, perhaps in an effect
    traverse_ (update ev) usrs
  where
    update ::
      (UserId -> UserEvent) ->
      UserId ->
      AppT r ()
    update ev u = do
      liftSem $ Data.updateStatus u status
      Intra.onUserEvent u Nothing (ev u)

changeSingleAccountStatus ::
  Members
    '[ GalleyAccess,
       GundeckAccess,
       UserQuery p
     ]
    r =>
  UserId ->
  AccountStatus ->
  ExceptT AccountStatusError (AppT r) ()
changeSingleAccountStatus uid status = do
  unlessM (lift . liftSem $ Data.userExists uid) $ throwE AccountNotFound
  ev <- wrapClientE $ mkUserEvent [uid] status
  lift . liftSem $ Data.updateStatus uid status
  lift $ Intra.onUserEvent uid Nothing (ev uid)

mkUserEvent ::
  (Traversable t, MonadClient m) =>
  t UserId ->
  AccountStatus ->
  ExceptT AccountStatusError m (UserId -> UserEvent)
mkUserEvent usrs status =
  case status of
    Active -> pure UserResumed
    Suspended ->
      lift $
        -- mapConcurrently revokeAllCookies usrs >> pure UserSuspended
        -- TODO(md): implement concurrently traversing this as an effect
        traverse revokeAllCookies usrs >> pure UserSuspended
    Deleted -> throwE InvalidAccountStatus
    Ephemeral -> throwE InvalidAccountStatus
    PendingInvitation -> throwE InvalidAccountStatus

-------------------------------------------------------------------------------
-- Activation

activate ::
  Members
    '[ ActivationKeyStore,
       ActivationSupply,
       GalleyAccess,
       GundeckAccess,
       Input (Local ()),
       P.Error Twilio.ErrorResponse,
       PasswordResetSupply,
       PasswordResetStore,
       Twilio,
       UserKeyStore,
       UserQuery p
     ]
    r =>
  ActivationTarget ->
  ActivationCode ->
  -- | The user for whom to activate the key.
  Maybe UserId ->
  ExceptT ActivationError (AppT r) ActivationResult
activate tgt code usr = activateWithCurrency tgt code usr Nothing

activateWithCurrency ::
  Members
    '[ ActivationKeyStore,
       ActivationSupply,
       GalleyAccess,
       GundeckAccess,
       Input (Local ()),
       P.Error Twilio.ErrorResponse,
       PasswordResetSupply,
       PasswordResetStore,
       Twilio,
       UserKeyStore,
       UserQuery p
     ]
    r =>
  ActivationTarget ->
  ActivationCode ->
  -- | The user for whom to activate the key.
  Maybe UserId ->
  -- | Potential currency update.
  -- ^ TODO: to be removed once billing supports currency changes after team creation
  Maybe Currency.Alpha ->
  ExceptT ActivationError (AppT r) ActivationResult
activateWithCurrency tgt code usr cur = do
  key <- liftSemE $ mkActivationKey tgt
  lift . Log.info $
    field "activation.key" (toByteString key)
      . field "activation.code" (toByteString code)
      . msg (val "Activating")
  d <- view digestSHA256
  locale <- setDefaultUserLocale <$> view settings
  event <- liftSemE $ Data.activateKey locale d key code usr
  case event of
    Nothing -> pure ActivationPass
    Just e -> do
      (uid, ident, first) <- lift $ onActivated e
      when first $
        lift $
          activateTeam uid
      pure $ ActivationSuccess ident first
  where
    activateTeam uid = do
      tid <- wrapHttp $ Intra.getTeamId uid
      for_ tid $ \t -> wrapHttp $ Intra.changeTeamStatus t Team.Active cur

preverify ::
  Members
    '[ ActivationKeyStore,
       ActivationSupply,
       P.Error Twilio.ErrorResponse,
       Twilio
     ]
    r =>
  ActivationTarget ->
  ActivationCode ->
  ExceptT ActivationError (Sem r) ()
preverify tgt code = do
  key <- mkActivationKey tgt
  void $ Data.verifyCode key code

onActivated ::
  Members
    '[ GalleyAccess,
       GundeckAccess,
       UserQuery p
     ]
    r =>
  ActivationEvent ->
  AppT r (UserId, Maybe UserIdentity, Bool)
onActivated (AccountActivated account) = do
  let uid = userId (accountUser account)
  Log.debug $ field "user" (toByteString uid) . field "action" (Log.val "User.onActivated")
  Log.info $ field "user" (toByteString uid) . msg (val "User activated")
  Intra.onUserEvent uid Nothing $ UserActivated (accountUser account)
  pure (uid, userIdentity (accountUser account), True)
onActivated (EmailActivated uid email) = do
  Intra.onUserEvent uid Nothing (emailUpdated uid email)
  liftSem $ Data.deleteEmailUnvalidated uid
  pure (uid, Just (EmailIdentity email), False)
onActivated (PhoneActivated uid phone) = do
  Intra.onUserEvent uid Nothing (phoneUpdated uid phone)
  pure (uid, Just (PhoneIdentity phone), False)

-- docs/reference/user/activation.md {#RefActivationRequest}
sendActivationCode ::
  Members
    '[ ActivationKeyStore,
       ActivationSupply,
       BlacklistStore,
       BlacklistPhonePrefixStore,
       P.Error Twilio.ErrorResponse,
       Twilio,
       UserKeyStore,
       UserQuery p
     ]
    r =>
  Either Email Phone ->
  Maybe Locale ->
  Bool ->
  ExceptT SendActivationCodeError (AppT r) ()
sendActivationCode emailOrPhone loc call = do
  timeout <- setActivationTimeout <$> view settings
  case emailOrPhone of
    Left email -> do
      ek <-
        either
          (const . throwE . InvalidRecipient $ userEmailKey email)
          (pure . userEmailKey)
          (validateEmail email)
      exists <- lift $ isJust <$> liftSem (Data.getKey ek)
      when exists $
        throwE $
          UserKeyInUse ek
      blacklisted <- lift . liftSem $ BlacklistStore.exists ek
      when blacklisted $
        throwE (ActivationBlacklistedUserKey ek)
      uc <- lift . wrapClient $ Data.lookupActivationCode ek
      case uc of
        Nothing -> sendVerificationEmail timeout ek Nothing -- Fresh code request, no user
        Just (Nothing, c) -> sendVerificationEmail timeout ek (Just c) -- Re-requesting existing code
        Just (Just uid, c) -> sendActivationEmail timeout ek c uid -- User re-requesting activation
    Right phone -> do
      -- validatePhone returns the canonical E.164 phone number format
      canonical <-
        maybe
          (throwE $ InvalidRecipient (userPhoneKey phone))
          pure
          =<< lift (liftSem $ validatePhone phone)
      let pk = userPhoneKey canonical
      exists <- lift $ isJust <$> liftSem (Data.getKey pk)
      when exists $
        throwE $
          UserKeyInUse pk
      blacklisted <- lift . liftSem $ BlacklistStore.exists pk
      when blacklisted $
        throwE (ActivationBlacklistedUserKey pk)
      -- check if any prefixes of this phone number are blocked
      prefixExcluded <- lift . liftSem $ BlacklistPhonePrefixStore.existsAny canonical
      when prefixExcluded $
        throwE (ActivationBlacklistedUserKey pk)
      c <- lift . wrapClient $ fmap snd <$> Data.lookupActivationCode pk
      p <- lift . liftSem $ mkPair timeout pk c Nothing
      void . forPhoneKey pk $ \ph ->
        lift $
          if call
            then wrapClient $ sendActivationCall ph p loc
            else wrapClient $ sendActivationSms ph p loc
  where
    notFound = throwM . UserDisplayNameNotFound
    mkPair timeout k c u = do
      case c of
        Just c' -> (,c') <$> Data.makeActivationKey k
        Nothing -> do
          dat <- Data.newActivation k timeout u
          pure (activationKey dat, activationCode dat)
    sendVerificationEmail timeout ek uc = do
      p <- lift . liftSem $ mkPair timeout ek uc Nothing
      void . forEmailKey ek $ \em ->
        lift $
          sendVerificationMail em p loc
    sendActivationEmail timeout ek uc uid = do
      -- FUTUREWORK(fisx): we allow for 'PendingInvitations' here, but I'm not sure this
      -- top-level function isn't another piece of a deprecated onboarding flow?
      locu <- qualifyLocal ()
      locale <- setDefaultUserLocale <$> view settings
      u <-
        maybe (notFound uid) pure
          =<< lift (liftSem $ Data.lookupUser locu locale WithPendingInvitations uid)
      p <- lift . liftSem $ mkPair timeout ek (Just uc) (Just uid)
      let ident = userIdentity u
          name = userDisplayName u
          loc' = loc <|> Just (userLocale u)
      void . forEmailKey ek $ \em -> lift $ do
        -- Get user's team, if any.
        mbTeam <- mapM (fmap Team.tdTeam . wrapHttp . Intra.getTeam) (userTeam u)
        -- Depending on whether the user is a team creator, send either
        -- a team activation email or a regular email. Note that we
        -- don't have to check if the team is binding because if the
        -- user has 'userTeam' set, it must be binding.
        case mbTeam of
          Just team
            | team ^. teamCreator == uid ->
              sendTeamActivationMail em name p loc' (team ^. teamName)
          _otherwise ->
            sendActivationMail em name p loc' ident

mkActivationKey ::
  Members
    '[ ActivationSupply,
       P.Error Twilio.ErrorResponse,
       Twilio
     ]
    r =>
  ActivationTarget ->
  ExceptT ActivationError (Sem r) ActivationKey
mkActivationKey (ActivateKey k) = pure k
mkActivationKey (ActivateEmail e) = do
  ek <-
    either
      (throwE . InvalidActivationEmail e)
      (pure . userEmailKey)
      (validateEmail e)
  lift $ Data.makeActivationKey ek
mkActivationKey (ActivatePhone p) = do
  pk <-
    maybe
      (throwE $ InvalidActivationPhone p)
      (pure . userPhoneKey)
      =<< lift (validatePhone p)
  lift $ Data.makeActivationKey pk

-------------------------------------------------------------------------------
-- Password Management

changePassword ::
  Members '[UserQuery p] r =>
  UserId ->
  PasswordChange ->
  ExceptT ChangePasswordError (AppT r) ()
changePassword uid cp = do
  activated <- lift . liftSem $ Data.isActivated uid
  unless activated $
    throwE ChangePasswordNoIdentity
  currpw <- lift . wrapClient $ Data.lookupPassword uid
  let newpw = cpNewPassword cp
  case (currpw, cpOldPassword cp) of
    (Nothing, _) -> lift . wrapClient $ Data.updatePassword uid newpw
    (Just _, Nothing) -> throwE InvalidCurrentPassword
    (Just pw, Just pw') -> do
      unless (verifyPassword pw' pw) $
        throwE InvalidCurrentPassword
      when (verifyPassword newpw pw) $
        throwE ChangePasswordMustDiffer
      lift $ wrapClient (Data.updatePassword uid newpw) >> wrapClient (revokeAllCookies uid)

beginPasswordReset ::
  Members '[P.TinyLog, PasswordResetStore, UserKeyStore] r =>
  Either Email Phone ->
  ExceptT PasswordResetError (AppT r) (UserId, PasswordResetPair)
beginPasswordReset target = do
  let key = either userEmailKey userPhoneKey target
  user <- lift (liftSem $ Data.getKey key) >>= maybe (throwE InvalidPasswordResetKey) pure
  lift . liftSem . P.debug $
    field "user" (toByteString user) . field "action" (Log.val "User.beginPasswordReset")
  status <- lift . wrapClient $ Data.lookupStatus user
  unless (status == Just Active) $
    throwE InvalidPasswordResetKey
  code <- lift . liftSem $ E.lookupPasswordResetCode user
  when (isJust code) $
    throwE (PasswordResetInProgress Nothing)
  (user,) <$> lift (liftSem $ E.createPasswordResetCode user target)

completePasswordReset ::
  Members '[PasswordResetStore, PasswordResetSupply, UserKeyStore] r =>
  PasswordResetIdentity ->
  PasswordResetCode ->
  PlainTextPassword ->
  ExceptT PasswordResetError (AppT r) ()
completePasswordReset ident code pw = do
  key <- mkPasswordResetKey ident
  muid :: Maybe UserId <- lift . liftSem $ E.verifyPasswordResetCode (key, code)
  case muid of
    Nothing -> throwE InvalidPasswordResetCode
    Just uid -> do
      lift . Log.debug $ field "user" (toByteString uid) . field "action" (Log.val "User.completePasswordReset")
      checkNewIsDifferent uid pw
      lift $ do
        wrapClient $ Data.updatePassword uid pw
        liftSem $ E.deletePasswordResetCode key
        wrapClient $ revokeAllCookies uid

-- | Pull the current password of a user and compare it against the one about to be installed.
-- If the two are the same, throw an error.  If no current password can be found, do nothing.
checkNewIsDifferent :: UserId -> PlainTextPassword -> ExceptT PasswordResetError (AppT r) ()
checkNewIsDifferent uid pw = do
  mcurrpw <- lift . wrapClient $ Data.lookupPassword uid
  case mcurrpw of
    Just currpw | verifyPassword pw currpw -> throwE ResetPasswordMustDiffer
    _ -> pure ()

mkPasswordResetKey ::
  Members '[PasswordResetSupply, UserKeyStore] r =>
  PasswordResetIdentity ->
  ExceptT PasswordResetError (AppT r) PasswordResetKey
mkPasswordResetKey ident = case ident of
  PasswordResetIdentityKey k -> pure k
  PasswordResetEmailIdentity e ->
    user (userEmailKey e)
      >>= lift . liftSem . E.mkPasswordResetKey
  PasswordResetPhoneIdentity p ->
    user (userPhoneKey p)
      >>= lift . liftSem . E.mkPasswordResetKey
  where
    user uk = lift (liftSem $ Data.getKey uk) >>= maybe (throwE InvalidPasswordResetKey) pure

-------------------------------------------------------------------------------
-- User Deletion

-- | Initiate validation of a user's delete request.  Called via @delete /self@.  Users with an
-- 'UserSSOId' can still do this if they also have an 'Email', 'Phone', and/or password.  Otherwise,
-- the team admin has to delete them via the team console on galley.
--
-- Owners are not allowed to delete themselves.  Instead, they must ask a fellow owner to
-- delete them in the team settings.  This protects teams against orphanhood.
--
-- TODO: communicate deletions of SSO users to SSO service.
deleteSelfUser ::
  Members
    '[ ClientStore,
       GalleyAccess,
       GundeckAccess,
       Input (Local ()),
       UniqueClaimsStore,
       UserHandleStore,
       UserKeyStore,
       UserQuery p,
       VerificationCodeStore
     ]
    r =>
  UserId ->
  Maybe PlainTextPassword ->
  ExceptT DeleteUserError (AppT r) (Maybe Timeout)
deleteSelfUser uid pwd = do
  locale <- setDefaultUserLocale <$> view settings
  account <- lift . liftSem $ Data.lookupAccount locale uid
  case account of
    Nothing -> throwE DeleteUserInvalid
    Just a -> case accountStatus a of
      Deleted -> pure Nothing
      Suspended -> ensureNotOwner a >> go a
      Active -> ensureNotOwner a >> go a
      Ephemeral -> go a
      PendingInvitation -> go a
  where
    ensureNotOwner :: UserAccount -> ExceptT DeleteUserError (AppT r) ()
    ensureNotOwner acc = do
      case userTeam $ accountUser acc of
        Nothing -> pure ()
        Just tid -> do
          isOwner <- lift $ wrapHttp $ Intra.memberIsTeamOwner tid uid
          when isOwner $ throwE DeleteUserOwnerDeletingSelf
    go a = maybe (byIdentity a) (byPassword a) pwd
    getEmailOrPhone :: UserIdentity -> Maybe (Either Email Phone)
    getEmailOrPhone (FullIdentity e _) = Just $ Left e
    getEmailOrPhone (EmailIdentity e) = Just $ Left e
    getEmailOrPhone (SSOIdentity _ (Just e) _) = Just $ Left e
    getEmailOrPhone (PhoneIdentity p) = Just $ Right p
    getEmailOrPhone (SSOIdentity _ _ (Just p)) = Just $ Right p
    getEmailOrPhone (SSOIdentity _ Nothing Nothing) = Nothing
    byIdentity a = case getEmailOrPhone =<< userIdentity (accountUser a) of
      Just emailOrPhone -> sendCode a emailOrPhone
      Nothing -> case pwd of
        Just _ -> throwE DeleteUserMissingPassword
        Nothing -> lift $ deleteAccount a >> pure Nothing
    byPassword a pw = do
      lift . Log.info $
        field "user" (toByteString uid)
          . msg (val "Attempting account deletion with a password")
      actual <- lift . wrapClient $ Data.lookupPassword uid
      case actual of
        Nothing -> throwE DeleteUserInvalidPassword
        Just p -> do
          unless (verifyPassword pw p) $
            throwE DeleteUserInvalidPassword
          lift $ deleteAccount a >> pure Nothing
    sendCode a target = do
      gen <- Code.mkGen (either Code.ForEmail Code.ForPhone target)
      pending <- lift . liftSem $ Code.getPendingCode (Code.genKey gen) Code.AccountDeletion
      case pending of
        Just c -> throwE $! DeleteUserPendingCode (Code.codeTTL c)
        Nothing -> do
          lift . Log.info $
            field "user" (toByteString uid)
              . msg (val "Sending verification code for account deletion")
          c <-
            Code.generate
              gen
              Code.AccountDeletion
              (Code.Retries 3)
              (Code.Timeout 600)
              (Just (toUUID uid))
          -- lift . liftSem $ Code.insertCode c
          tryInsertVerificationCode c DeleteUserVerificationCodeThrottled
          let k = Code.codeKey c
          let v = Code.codeValue c
          let l = userLocale (accountUser a)
          let n = userDisplayName (accountUser a)
          either
            (\e -> lift $ sendDeletionEmail n e k v l)
            (\p -> lift $ wrapClient $ sendDeletionSms p k v l)
            target
            `onException` wrapClientE (Code.delete k Code.AccountDeletion)
          pure $! Just $! Code.codeTTL c

-- | Conclude validation and scheduling of user's deletion request that was initiated in
-- 'deleteUser'.  Called via @post /delete@.
verifyDeleteUser ::
  Members
    '[ ClientStore,
       GalleyAccess,
       GundeckAccess,
       Input (Local ()),
       UniqueClaimsStore,
       UserHandleStore,
       UserKeyStore,
       UserQuery p,
       VerificationCodeStore
     ]
    r =>
  VerifyDeleteUser ->
  ExceptT DeleteUserError (AppT r) ()
verifyDeleteUser d = do
  let key = verifyDeleteUserKey d
  let code = verifyDeleteUserCode d
  c <- lift . liftSem $ Code.verifyCode key Code.AccountDeletion code
  a <- maybe (throwE DeleteUserInvalidCode) pure (Code.codeAccount =<< c)
  locale <- setDefaultUserLocale <$> view settings
  account <- lift . liftSem $ Data.lookupAccount locale (Id a)
  for_ account $ lift . deleteAccount
  lift . wrapClient $ Code.delete key Code.AccountDeletion

-- | Check if `deleteAccount` succeeded and run it again if needed.
-- Called via @delete /i/user/:uid@.
ensureAccountDeleted ::
  Members
    '[ ClientStore,
       GalleyAccess,
       GundeckAccess,
       Input (Local ()),
       UniqueClaimsStore,
       UserHandleStore,
       UserKeyStore,
       UserQuery p
     ]
    r =>
  UserId ->
  AppT r DeleteUserResult
ensureAccountDeleted uid = do
  locale <- Opt.setDefaultUserLocale <$> view settings
  mbAcc <- liftSem $ lookupAccount locale uid
  case mbAcc of
    Nothing -> pure NoUser
    Just acc -> do
      probs <- wrapClient $ Data.lookupPropertyKeysAndValues uid

      let accIsDeleted = accountStatus acc == Deleted
      clients <- wrapClient $ Data.lookupClients uid

      localUid <- qualifyLocal uid
      conCount <-
        wrapClient $
          countConnections localUid [(minBound @Relation) .. maxBound]
      cookies <- wrapClient $ listCookies uid []

      if notNull probs
        || not accIsDeleted
        || notNull clients
        || conCount > 0
        || notNull cookies
        then do
          deleteAccount acc
          pure AccountDeleted
        else pure AccountAlreadyDeleted

-- | Internal deletion without validation.
--
-- Called via @delete /i/user/:uid@ (through `ensureAccountDeleted`), or
-- indirectly via deleting self. Team owners can be deleted if the team is not
-- orphaned, i.e. there is at least one other owner left.
--
-- N.B.: As Cassandra doesn't support transactions, the order of database
-- statements matters! Other functions reason upon some states to imply other
-- states. Please change this order only with care!
deleteAccount ::
  forall r p.
  Members
    '[ ClientStore,
       GalleyAccess,
       GundeckAccess,
       UniqueClaimsStore,
       UserHandleStore,
       UserKeyStore,
       UserQuery p
     ]
    r =>
  UserAccount ->
  AppT r ()
deleteAccount account@(accountUser -> user) = do
  let uid = userId user
  Log.info $ field "user" (toByteString uid) . msg (val "Deleting account")
  -- Free unique keys
  d <- view digestSHA256
  for_ (userEmail user) $ liftSem . deleteKeyForUser d uid . userEmailKey
  for_ (userPhone user) $ liftSem . deleteKeyForUser d uid . userPhoneKey
  liftSem $ for_ (userHandle user) $ freeHandle (userId user)
  -- Wipe data
  wrapClient $ Data.clearProperties uid
  tombstone <- mkTombstone
  liftSem $ Data.insertAccount tombstone Nothing Nothing False
  wrapHttp $ Intra.rmUser uid (userAssets user)
  liftSem (lookupClients uid >>= mapM_ (deleteClient uid . clientId))
  luid <- qualifyLocal uid
  Intra.onUserEvent uid Nothing (UserDeleted (qUntagged luid))
  -- Note: Connections can only be deleted afterwards, since
  --       they need to be notified.
  wrapClient $ Data.deleteConnections uid
  wrapClient $ revokeAllCookies uid
  where
    mkTombstone = do
      defLoc <- setDefaultUserLocale <$> view settings
      pure $
        account
          { accountStatus = Deleted,
            accountUser =
              user
                { userDisplayName = Name "default",
                  userAccentId = defaultAccentId,
                  userPict = noPict,
                  userAssets = [],
                  userHandle = Nothing,
                  userLocale = defLoc,
                  userIdentity = Nothing
                }
          }

-------------------------------------------------------------------------------
-- Lookups

lookupActivationCode ::
  (MonadIO m, MonadClient m) =>
  Either Email Phone ->
  m (Maybe ActivationPair)
lookupActivationCode emailOrPhone = do
  let uk = either userEmailKey userPhoneKey emailOrPhone
  k <- liftIO $ Data.mkActivationKey uk
  c <- fmap snd <$> Data.lookupActivationCode uk
  pure $ (k,) <$> c

lookupPasswordResetCode ::
  Members
    '[ PasswordResetStore,
       PasswordResetSupply,
       UserKeyStore
     ]
    r =>
  Either Email Phone ->
  AppT r (Maybe PasswordResetPair)
lookupPasswordResetCode emailOrPhone = do
  let uk = either userEmailKey userPhoneKey emailOrPhone
  usr <- liftSem $ Data.getKey uk
  liftSem $ case usr of
    Nothing -> pure Nothing
    Just u -> do
      k <- E.mkPasswordResetKey u
      c <- E.lookupPasswordResetCode u
      pure $ (k,) <$> c

deleteUserNoVerify ::
  ( MonadReader Env m,
    MonadIO m,
    MonadLogger m,
    MonadThrow m
  ) =>
  UserId ->
  m ()
deleteUserNoVerify uid = do
  queue <- view internalEvents
  Queue.enqueue queue (Internal.DeleteUser uid)

deleteUsersNoVerify :: [UserId] -> (AppT r) ()
deleteUsersNoVerify uids = do
  for_ uids deleteUserNoVerify
  m <- view metrics
  Metrics.counterAdd (fromIntegral . length $ uids) (Metrics.path "user.enqueue_multi_delete_total") m
  Metrics.counterIncr (Metrics.path "user.enqueue_multi_delete_calls_total") m

-- | Garbage collect users if they're ephemeral and they have expired.
-- Always returns the user (deletion itself is delayed)
userGC ::
  ( MonadIO m,
    MonadReader Env m,
    MonadLogger m,
    MonadThrow m
  ) =>
  User ->
  m User
userGC u = case userExpire u of
  Nothing -> pure u
  (Just (fromUTCTimeMillis -> e)) -> do
    now <- liftIO =<< view currentTime
    -- ephemeral users past their expiry date are deleted
    when (diffUTCTime e now < 0) $
      deleteUserNoVerify (userId u)
    pure u

lookupProfile ::
  Members '[Input (Local ()), UserQuery p] r =>
  Local UserId ->
  Qualified UserId ->
  ExceptT FederationError (AppT r) (Maybe UserProfile)
lookupProfile self other =
  listToMaybe
    <$> lookupProfilesFromDomain
      self
      (fmap pure other)

-- | Obtain user profiles for a list of users as they can be seen by
-- a given user 'self'. User 'self' can see the 'FullProfile' of any other user 'other',
-- if the reverse relation (other -> self) is either 'Accepted' or 'Sent'.
-- Otherwise only the 'PublicProfile' is accessible for user 'self'.
-- If 'self' is an unknown 'UserId', return '[]'.
lookupProfiles ::
  Members '[Input (Local ()), UserQuery p] r =>
  -- ( MonadUnliftIO m,
  --   MonadClient m,
  --   MonadReader Env m,
  --   MonadLogger m,
  --   MonadMask m,
  --   MonadHttp m,
  --   HasRequestId m
  -- ) =>

  -- | User 'self' on whose behalf the profiles are requested.
  Local UserId ->
  -- | The users ('others') for which to obtain the profiles.
  [Qualified UserId] ->
  ExceptT FederationError (AppT r) [UserProfile]
lookupProfiles self others =
  concat
    <$>
    -- <$> traverseConcurrentlyWithErrors
    --   (lookupProfilesFromDomain self)
    --   (bucketQualified others)
    -- TODO(md): Use an effect with error handling for this
    traverse
      (lookupProfilesFromDomain self)
      (bucketQualified others)

lookupProfilesFromDomain ::
  Members '[Input (Local ()), UserQuery p] r =>
  Local UserId ->
  Qualified [UserId] ->
  ExceptT FederationError (AppT r) [UserProfile]
lookupProfilesFromDomain self =
  foldQualified
    self
    (lift . lookupLocalProfiles (Just (tUnqualified self)) . tUnqualified)
    lookupRemoteProfiles

lookupRemoteProfiles ::
  Remote [UserId] ->
  ExceptT FederationError (AppT r) [UserProfile]
lookupRemoteProfiles (qUntagged -> Qualified uids domain) =
  Federation.getUsersByIds domain uids

-- FUTUREWORK: This function encodes a few business rules about exposing email
-- ids, but it is also very complex. Maybe this can be made easy by extracting a
-- pure function and writing tests for that.
lookupLocalProfiles ::
  forall r p.
  Members '[Input (Local ()), UserQuery p] r =>
  -- | This is present only when an authenticated user is requesting access.
  Maybe UserId ->
  -- | The users ('others') for which to obtain the profiles.
  [UserId] ->
  AppT r [UserProfile]
lookupLocalProfiles requestingUser others = do
  loc <- fmap (qTagUnsafe @'QLocal) $ Qualified () <$> viewFederationDomain
  locale <- setDefaultUserLocale <$> view settings
  users <-
    liftSem (Data.lookupUsers loc locale NoPendingInvitations others)
      >>= mapM userGC
  css <- case requestingUser of
    Just localReqUser ->
      toMap
        <$> wrapClient (Data.lookupConnectionStatus (map userId users) [localReqUser])
    Nothing -> pure mempty
  emailVisibility' <- view (settings . emailVisibility)
  emailVisibility'' <- case emailVisibility' of
    EmailVisibleIfOnTeam -> pure EmailVisibleIfOnTeam'
    EmailVisibleIfOnSameTeam -> case requestingUser of
      Just localReqUser -> EmailVisibleIfOnSameTeam' <$> getSelfInfo loc locale localReqUser
      Nothing -> pure EmailVisibleToSelf'
    EmailVisibleToSelf -> pure EmailVisibleToSelf'
  usersAndStatus <- for users $ \u -> (u,) <$> getLegalHoldStatus' u
  pure $ map (toProfile emailVisibility'' css) usersAndStatus
  where
    toMap :: [ConnectionStatus] -> Map UserId Relation
    toMap = Map.fromList . map (csFrom &&& csStatus)

    getSelfInfo :: Local x -> Locale -> UserId -> AppT r (Maybe (TeamId, TeamMember))
    getSelfInfo loc locale selfId = do
      -- FUTUREWORK: it is an internal error for the two lookups (for 'User' and 'TeamMember')
      -- to return 'Nothing'.  we could throw errors here if that happens, rather than just
      -- returning an empty profile list from 'lookupProfiles'.
      mUser <-
        liftSem (Data.lookupUser loc locale NoPendingInvitations selfId)
      case userTeam =<< mUser of
        Nothing -> pure Nothing
        Just tid -> (tid,) <$$> wrapHttp (Intra.getTeamMember selfId tid)

    toProfile :: EmailVisibility' -> Map UserId Relation -> (User, UserLegalHoldStatus) -> UserProfile
    toProfile emailVisibility'' css (u, userLegalHold) =
      let cs = Map.lookup (userId u) css
          profileEmail' = getEmailForProfile u emailVisibility''
          baseProfile =
            if Just (userId u) == requestingUser || cs == Just Accepted || cs == Just Sent
              then connectedProfile u userLegalHold
              else publicProfile u userLegalHold
       in baseProfile {profileEmail = profileEmail'}

getLegalHoldStatus ::
  Members '[Input (Local ()), UserQuery p] r =>
  UserId ->
  AppT r (Maybe UserLegalHoldStatus)
getLegalHoldStatus uid = do
  locale <- setDefaultUserLocale <$> view settings
  traverse (getLegalHoldStatus' . accountUser)
    =<< liftSem (lookupAccount locale uid)

getLegalHoldStatus' ::
  forall r p.
  Members '[Input (Local ()), UserQuery p] r =>
  User ->
  AppT r UserLegalHoldStatus
getLegalHoldStatus' user =
  case userTeam user of
    Nothing -> pure defUserLegalHoldStatus
    Just tid -> do
      teamMember <- wrapHttp $ Intra.getTeamMember (userId user) tid
      pure $ maybe defUserLegalHoldStatus (^. legalHoldStatus) teamMember

data EmailVisibility'
  = EmailVisibleIfOnTeam'
  | EmailVisibleIfOnSameTeam' (Maybe (TeamId, TeamMember))
  | EmailVisibleToSelf'

-- | Gets the email if it's visible to the requester according to configured settings
getEmailForProfile ::
  User ->
  EmailVisibility' ->
  Maybe Email
getEmailForProfile profileOwner EmailVisibleIfOnTeam' =
  if isJust (userTeam profileOwner)
    then userEmail profileOwner
    else Nothing
getEmailForProfile profileOwner (EmailVisibleIfOnSameTeam' (Just (viewerTeamId, viewerTeamMember))) =
  if Just viewerTeamId == userTeam profileOwner
    && Team.hasPermission viewerTeamMember Team.ViewSameTeamEmails
    then userEmail profileOwner
    else Nothing
getEmailForProfile _ (EmailVisibleIfOnSameTeam' Nothing) = Nothing
getEmailForProfile _ EmailVisibleToSelf' = Nothing

-- | Find user accounts for a given identity, both activated and those
-- currently pending activation.
lookupAccountsByIdentity ::
  Members '[Input (Local ()), UserKeyStore, UserQuery p] r =>
  Either Email Phone ->
  Bool ->
  AppT r [UserAccount]
lookupAccountsByIdentity emailOrPhone includePendingInvitations = do
  let uk = either userEmailKey userPhoneKey emailOrPhone
  activeUid <- liftSem $ Data.getKey uk
  uidFromKey <- (>>= fst) <$> wrapClient (Data.lookupActivationCode uk)
  locale <- setDefaultUserLocale <$> view settings
  result <- liftSem $ Data.lookupAccounts locale (nub $ catMaybes [activeUid, uidFromKey])
  if includePendingInvitations
    then pure result
    else pure $ filter ((/= PendingInvitation) . accountStatus) result

isBlacklisted :: Member BlacklistStore r => Either Email Phone -> AppT r Bool
isBlacklisted emailOrPhone = do
  let uk = either userEmailKey userPhoneKey emailOrPhone
  liftSem $ BlacklistStore.exists uk

blacklistInsert :: Member BlacklistStore r => Either Email Phone -> AppT r ()
blacklistInsert emailOrPhone = do
  let uk = either userEmailKey userPhoneKey emailOrPhone
  liftSem $ BlacklistStore.insert uk

blacklistDelete :: Member BlacklistStore r => Either Email Phone -> AppT r ()
blacklistDelete emailOrPhone = do
  let uk = either userEmailKey userPhoneKey emailOrPhone
  liftSem $ BlacklistStore.delete uk

phonePrefixGet :: Member BlacklistPhonePrefixStore r => PhonePrefix -> (AppT r) [ExcludedPrefix]
phonePrefixGet = liftSem . BlacklistPhonePrefixStore.getAll

phonePrefixDelete :: Member BlacklistPhonePrefixStore r => PhonePrefix -> (AppT r) ()
phonePrefixDelete = liftSem . BlacklistPhonePrefixStore.delete

phonePrefixInsert :: Member BlacklistPhonePrefixStore r => ExcludedPrefix -> (AppT r) ()
phonePrefixInsert = liftSem . BlacklistPhonePrefixStore.insert
