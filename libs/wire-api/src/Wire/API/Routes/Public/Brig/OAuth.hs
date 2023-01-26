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

module Wire.API.Routes.Public.Brig.OAuth where

import Data.Id as Id
import Data.SOP
import Data.Swagger (Swagger)
import Imports hiding (exp, head)
import Servant (JSON)
import Servant hiding (Handler, JSON, Tagged, addHeader, respond)
import Servant.Swagger
import Servant.Swagger.Internal.Orphans ()
import Wire.API.Error
import Wire.API.OAuth
import Wire.API.Routes.MultiVerb
import Wire.API.Routes.Named (Named (..))
import Wire.API.Routes.Public

type OAuthAPI =
  Named
    "get-oauth-client"
    ( Summary "Get OAuth client information"
        :> CanThrow 'OAuthFeatureDisabled
        :> CanThrow 'OAuthClientNotFound
        :> ZUser
        :> "oauth"
        :> "clients"
        :> Capture' '[Description "The ID of the OAuth client"] "OAuthClientId" OAuthClientId
        :> MultiVerb
             'GET
             '[JSON]
             '[ ErrorResponse 'OAuthClientNotFound,
                Respond 200 "OAuth client found" OAuthClient
              ]
             (Maybe OAuthClient)
    )
    :<|> Named
           "create-oauth-auth-code"
           ( Summary "Create an OAuth authorization code"
               :> Description "Currently only supports the 'code' response type, which corresponds to the authorization code flow."
               :> ZUser
               :> "oauth"
               :> "authorization"
               :> "codes"
               :> ReqBody '[JSON] NewOAuthAuthCode
               :> MultiVerb
                    'POST
                    '[JSON]
                    CreateOAuthAuthCodeResponses
                    (RedirectUrl, Maybe CreateOAuthCodeError)
           )
    :<|> Named
           "create-oauth-access-token"
           ( Summary "Create an OAuth access token"
               :> Description "Obtain a new access token from an authorization code or a refresh token."
               :> CanThrow 'OAuthJwtError
               :> CanThrow 'OAuthAuthCodeNotFound
               :> CanThrow 'OAuthClientNotFound
               :> CanThrow 'OAuthFeatureDisabled
               :> CanThrow 'OAuthInvalidRefreshToken
               :> CanThrow 'OAuthInvalidGrantType
               :> CanThrow 'OAuthInvalidClientCredentials
               :> "oauth"
               :> "token"
               :> ReqBody '[FormUrlEncoded] (Either OAuthAccessTokenRequest OAuthRefreshAccessTokenRequest)
               :> Post '[JSON] OAuthAccessTokenResponse
           )
    :<|> Named
           "revoke-refresh-token"
           ( Summary "Revoke an OAuth refresh token"
               :> Description "Revoke an access token."
               :> CanThrow 'OAuthJwtError
               :> CanThrow 'OAuthInvalidRefreshToken
               :> CanThrow 'OAuthClientNotFound
               :> CanThrow 'OAuthInvalidClientCredentials
               :> "oauth"
               :> "revoke"
               :> ReqBody '[JSON] OAuthRevokeRefreshTokenRequest
               :> Post '[JSON] ()
           )

type CreateOAuthAuthCodeHeaders = '[Header "Location" RedirectUrl]

type CreateOAuthAuthCodeResponses =
  '[ -- success
     WithHeaders CreateOAuthAuthCodeHeaders RedirectUrl (RespondEmpty 302 "Found"),
     -- feature disabled
     WithHeaders CreateOAuthAuthCodeHeaders RedirectUrl (RespondEmpty 403 "Forbidden"),
     -- unsupported response type
     WithHeaders CreateOAuthAuthCodeHeaders RedirectUrl (RespondEmpty 400 "Bad Request"),
     -- client not found
     WithHeaders CreateOAuthAuthCodeHeaders RedirectUrl (RespondEmpty 404 "Not Found"),
     -- redirect url mismatch
     WithHeaders CreateOAuthAuthCodeHeaders RedirectUrl (RespondEmpty 400 "Bad Request")
   ]

data CreateOAuthCodeError
  = CreateOAuthCodeFeatureDisabled
  | CreateOAuthCodeUnsupportedResponseType
  | CreateOAuthCodeClientNotFound
  | CreateOAuthCodeRedirectUrlMissMatch

instance AsUnion CreateOAuthAuthCodeResponses (RedirectUrl, Maybe CreateOAuthCodeError) where
  toUnion :: (RedirectUrl, Maybe CreateOAuthCodeError) -> Union (ResponseTypes CreateOAuthAuthCodeResponses)
  toUnion (url, Nothing) = Z (I url)
  toUnion (url, Just CreateOAuthCodeFeatureDisabled) = S (Z (I url))
  toUnion (url, Just CreateOAuthCodeUnsupportedResponseType) = S (S (Z (I url)))
  toUnion (url, Just CreateOAuthCodeClientNotFound) = S (S (S (Z (I url))))
  toUnion (url, Just CreateOAuthCodeRedirectUrlMissMatch) = S (S (S (S (Z (I url)))))
  fromUnion :: Union (ResponseTypes CreateOAuthAuthCodeResponses) -> (RedirectUrl, Maybe CreateOAuthCodeError)
  fromUnion (Z (I url)) = (url, Nothing)
  fromUnion (S (Z (I url))) = (url, Just CreateOAuthCodeFeatureDisabled)
  fromUnion (S (S (Z (I url)))) = (url, Just CreateOAuthCodeUnsupportedResponseType)
  fromUnion (S (S (S (Z (I url))))) = (url, Just CreateOAuthCodeClientNotFound)
  fromUnion (S (S (S (S (Z (I url)))))) = (url, Just CreateOAuthCodeRedirectUrlMissMatch)
  fromUnion (S (S (S (S (S x))))) = case x of {}

swaggerDoc :: Swagger
swaggerDoc = toSwagger (Proxy @OAuthAPI)
