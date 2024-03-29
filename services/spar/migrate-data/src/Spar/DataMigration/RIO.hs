{-# LANGUAGE GeneralizedNewtypeDeriving #-}

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

module Spar.DataMigration.RIO where

import Imports

newtype RIO env a = RIO {unRIO :: ReaderT env IO a}
  deriving newtype (Functor, Applicative, Monad, MonadIO, MonadReader env)

runRIO :: env -> RIO env a -> IO a
runRIO e f = runReaderT (unRIO f) e

modifyRef :: (env -> IORef a) -> (a -> a) -> RIO env ()
modifyRef get_ mod' = do
  ref <- asks get_
  liftIO (modifyIORef ref mod')

readRef :: (env -> IORef b) -> RIO env b
readRef g = do
  ref <- asks g
  liftIO $ readIORef ref
