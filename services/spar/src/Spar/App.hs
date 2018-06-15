{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE TypeFamilies               #-}

module Spar.App where

import Bilge
import Cassandra
import Control.Exception (SomeException(SomeException))
import Control.Monad.Except
import Control.Monad.Reader
import Data.Id
import SAML2.WebSSO hiding (UserId(..))
import Servant
import Spar.Options as Options

import qualified Cassandra as Cas
import qualified Control.Monad.Catch as Catch
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified SAML2.WebSSO as SAML
import qualified Spar.Intra.Brig as Brig
import qualified Spar.Data as Data
import qualified System.Logger as Log


newtype Spar a = Spar { fromSpar :: ReaderT Env Handler a }
  deriving (Functor, Applicative, Monad, MonadIO, MonadReader Env, MonadError ServantErr)

data Env = Env
  { sparCtxOpts         :: Opts
  , sparCtxLogger       :: Log.Logger
  , sparCtxCas          :: Cas.ClientState
  , sparCtxHttpManager  :: Bilge.Manager
  , sparCtxHttpBrig     :: Bilge.Request
  }

instance HasConfig Spar where
  type ConfigExtra Spar = TeamId
  getConfig = asks (saml . sparCtxOpts)

instance SP Spar where
  logger lv mg = asks sparCtxLogger >>= \lg -> Spar $ Log.log lg (toLevel lv) mg'
    where
      mg' = Log.msg mg  -- TODO: there is probably more we should do to get the SAML log messages
                        -- into the right form?

toLevel :: SAML.LogLevel -> Log.Level
toLevel = \case
  SILENT   -> Log.Fatal
  CRITICAL -> Log.Fatal
  ERROR    -> Log.Error
  WARN     -> Log.Warn
  INFO     -> Log.Info
  DEBUG    -> Log.Debug

fromLevel :: Log.Level -> SAML.LogLevel
fromLevel = \case
  Log.Fatal -> CRITICAL
  Log.Error -> ERROR
  Log.Warn  -> WARN
  Log.Info  -> INFO
  Log.Debug -> DEBUG
  Log.Trace -> DEBUG

instance SPStore Spar where
  storeRequest i r      = wrapMonadClient' $ \env -> Data.storeRequest env i r
  checkAgainstRequest r = wrapMonadClient' $ \env -> Data.checkAgainstRequest env r
  storeAssertion i r    = wrapMonadClient' $ \env -> Data.storeAssertion env i r

-- | Call a cassandra command in the 'Spar' monad.  Catch all exceptions and re-throw them as 500 in
-- Handler.
wrapMonadClient' :: (Data.Env -> Cas.Client a) -> Spar a
wrapMonadClient' action = do
  denv <- Data.Env <$> (fromTime <$> getNow) <*> pure (8 * 60 * 60)  -- TODO: make this yaml-configurable.
  Spar $ do
    ctx <- asks sparCtxCas
    runClient ctx (action denv) `Catch.catch`
      \e@(SomeException _) -> throwError err500 { errBody = LBS.pack $ show e }

wrapMonadClient :: Cas.Client a -> Spar a
wrapMonadClient = wrapMonadClient' . const

insertUser :: SAML.UserId -> UserId -> Spar ()
insertUser suid buid = wrapMonadClient $ Data.insertUser suid buid

getUser :: SAML.UserId -> Spar (Maybe UserId)
getUser suid = wrapMonadClient $ Data.getUser suid

deleteUser :: SAML.UserId -> Spar ()
deleteUser suid = wrapMonadClient $ Data.deleteUser suid


-- | Create user in both brig and C*.
createUser :: SAML.UserId -> Spar UserId
createUser suid = do
  buid <- Brig.createUser suid
  -- TODO: if we crash here, the next attempt at login will attempt to create an already-created
  -- user.  and crash again.  this should be idempotent.
  insertUser suid buid
  pure buid

forwardBrigLogin :: UserId -> Spar SAML.Void
forwardBrigLogin = Brig.forwardBrigLogin


instance SPHandler Spar where
  type NTCTX Spar = Env
  nt ctx (Spar action) = runReaderT action ctx

instance MonadHttp Spar where
  getManager = asks sparCtxHttpManager

instance Brig.MonadSparToBrig Spar where
  call modreq = do
    req <- asks sparCtxHttpBrig
    httpLbs req modreq
