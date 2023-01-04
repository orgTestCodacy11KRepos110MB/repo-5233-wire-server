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

module API.OAuth where

import Bilge
import Bilge.Assert
import Brig.Effects.Jwk (readJwk)
import Brig.Options
import qualified Brig.Options as Opt
import Control.Lens
import Control.Monad.Catch (MonadCatch)
import Crypto.JOSE (JWK, bestJWSAlg, newJWSHeader, runJOSE)
import Crypto.JWT (Audience (Audience), JWTError, NumericDate (NumericDate), SignedJWT, claimAud, claimExp, claimIat, claimIss, claimSub, signJWT, stringOrUri)
import qualified Data.Aeson as A
import Data.ByteString.Conversion (fromByteString, fromByteString', toByteString')
import Data.Domain (domainText)
import Data.Id (OAuthClientId, UserId, idToText, randomId)
import Data.Range (unsafeRange)
import Data.Set as Set
import Data.String.Conversions (cs)
import Data.Text.Ascii (encodeBase16)
import Data.Time
import Imports
import Network.HTTP.Types (HeaderName)
import qualified Network.Wai.Utilities as Error
import Servant.API (ToHttpApiData (toHeader))
import Test.Tasty
import Test.Tasty.HUnit
import URI.ByteString
import Util
import Web.FormUrlEncoded
import Wire.API.OAuth
import Wire.API.Routes.Bearer (Bearer (Bearer))
import Wire.API.User (SelfProfile, User (userId), userEmail)
import Wire.API.User.Auth (CookieType (PersistentCookie))

tests :: Manager -> Brig -> Nginz -> Opts -> TestTree
tests m b n o = do
  testGroup "oauth" $
    [ test m "register new oauth client" $ testRegisterNewOAuthClient b,
      testGroup "create oauth code" $
        [ test m "success" $ testCreateOAuthCodeSuccess b,
          test m "oauth client not found" $ testCreateOAuthCodeClientNotFound b,
          test m "redirect url mismatch" $ testCreateOAuthCodeRedirectUrlMismatch b
        ],
      testGroup "create access token" $
        [ test m "success" $ testCreateAccessTokenSuccess o b,
          test m "wrong client id fail" $ testCreateAccessTokenWrongClientId b,
          test m "wrong client secret fail" $ testCreateAccessTokenWrongClientSecret b,
          test m "wrong code fail" $ testCreateAccessTokenWrongAuthCode b,
          test m "wrong redirect url fail" $ testCreateAccessTokenWrongUrl b,
          test m "expired code fail" $ testCreateAccessTokenExpiredCode o b
        ],
      testGroup "access denied when disabled" $
        [ test m "register" $ testRegisterOAuthClientAccessDeniedWhenDisabled o b,
          test m "get client info" $ testGetOAuthClientInfoAccessDeniedWhenDisabled o b,
          test m "create code" $ testCreateCodeOAuthClientAccessDeniedWhenDisabled o b,
          test m "create token" $ testCreateAccessTokenAccessDeniedWhenDisabled o b
        ],
      testGroup "accessing a resource" $
        [ test m "success (internal," $ testAccessResourceSuccessInternal b,
          test m "success (nginz)" $ testAccessResourceSuccessNginz b n,
          test m "insufficient scope" $ testAccessResourceInsufficientScope b,
          test m "expired token" $ testAccessResourceExpiredToken o b,
          test m "nonsense token" $ testAccessResourceNonsenseToken b,
          test m "no token" $ testAccessResourceNoToken b,
          test m "invalid signature" $ testAccessResourceInvalidSignature o b
        ]
    ]

testRegisterNewOAuthClient :: Brig -> Http ()
testRegisterNewOAuthClient brig = do
  let newOAuthClient@(NewOAuthClient expectedAppName expectedUrl) = newOAuthClientRequestBody "E Corp" "https://example.com"
  cid <- occClientId <$> registerNewOAuthClient brig newOAuthClient
  uid <- randomId
  oauthClientInfo <- getOAuthClientInfo brig uid cid
  liftIO $ do
    expectedAppName @?= ocName oauthClientInfo
    expectedUrl @?= ocRedirectUrl oauthClientInfo

testCreateOAuthCodeSuccess :: Brig -> Http ()
testCreateOAuthCodeSuccess brig = do
  let newOAuthClient@(NewOAuthClient _ redirectUrl) = newOAuthClientRequestBody "E Corp" "https://example.com"
  cid <- occClientId <$> registerNewOAuthClient brig newOAuthClient
  uid <- randomId
  let scope = OAuthScopes $ Set.fromList [ConversationCreate, ConversationCodeCreate]
  let state = "foobar"
  createOAuthCode brig uid (NewOAuthAuthCode cid scope OAuthResponseTypeCode redirectUrl state) !!! do
    const 302 === statusCode
    const (Just $ unRedirectUrl redirectUrl ^. pathL) === (fmap getPath . getLocation)
    const (Just $ ["code", "state"]) === (fmap (fmap fst . getQueryParams) . getLocation)
    const (Just $ cs state) === (getLocation >=> getQueryParamValue "state")
  where
    getLocation :: ResponseLBS -> Maybe RedirectUrl
    getLocation = getHeader "Location" >=> fromByteString

    getPath :: RedirectUrl -> ByteString
    getPath (RedirectUrl uri) = uri ^. pathL

    getQueryParams :: RedirectUrl -> [(ByteString, ByteString)]
    getQueryParams (RedirectUrl uri) = uri ^. (queryL . queryPairsL)

    getQueryParamValue :: ByteString -> RedirectUrl -> Maybe ByteString
    getQueryParamValue key uri = snd <$> find ((== key) . fst) (getQueryParams uri)

testCreateOAuthCodeRedirectUrlMismatch :: Brig -> Http ()
testCreateOAuthCodeRedirectUrlMismatch brig = do
  cid <- occClientId <$> registerNewOAuthClient brig (newOAuthClientRequestBody "E Corp" "https://example.com")
  uid <- randomId
  let differentUrl = fromMaybe (error "invalid url") $ fromByteString' "https://wire.com"
  createOAuthCode brig uid (NewOAuthAuthCode cid (OAuthScopes Set.empty) OAuthResponseTypeCode differentUrl "") !!! do
    const 400 === statusCode
    const (Just "redirect-url-miss-match") === fmap Error.label . responseJsonMaybe

testCreateOAuthCodeClientNotFound :: Brig -> Http ()
testCreateOAuthCodeClientNotFound brig = do
  cid <- randomId
  uid <- randomId
  let redirectUrl = fromMaybe (error "invalid url") $ fromByteString' "https://example.com"
  createOAuthCode brig uid (NewOAuthAuthCode cid (OAuthScopes Set.empty) OAuthResponseTypeCode redirectUrl "") !!! do
    const 404 === statusCode
    const (Just "not-found") === fmap Error.label . responseJsonMaybe

testCreateAccessTokenSuccess :: Opt.Opts -> Brig -> Http ()
testCreateAccessTokenSuccess opts brig = do
  now <- liftIO getCurrentTime
  uid <- userId <$> createUser "alice" brig
  let redirectUrl = fromMaybe (error "invalid url") $ fromByteString' "https://example.com"
  let scopes = OAuthScopes $ Set.fromList [SelfRead]
  (cid, secret, code) <- generateOAuthClientAndAuthCode brig uid scopes redirectUrl
  let accessTokenRequest = OAuthAccessTokenRequest OAuthGrantTypeAuthorizationCode cid secret code redirectUrl
  accessToken <- createOAuthAccessToken brig accessTokenRequest
  -- authorization code should be deleted and can only be used once
  createOAuthAccessToken' brig accessTokenRequest !!! do
    const 404 === statusCode
    const (Just "not-found") === fmap Error.label . responseJsonMaybe
  k <- liftIO $ readJwk (fromMaybe "path to jwk not set" (Opt.setOAuthJwkKeyPair $ Opt.optSettings opts)) <&> fromMaybe (error "invalid key")
  verifiedOrError <- liftIO $ verify k (unOAuthAccessToken $ oatAccessToken accessToken)
  verifiedOrErrorWithWrongKey <- liftIO $ verify wrongKey (unOAuthAccessToken $ oatAccessToken accessToken)
  let expectedDomain = domainText $ Opt.setFederationDomain $ Opt.optSettings opts
  liftIO $ do
    isRight verifiedOrError @?= True
    isLeft verifiedOrErrorWithWrongKey @?= True
    let claims = either (error "invalid token") id verifiedOrError
    scope claims @?= scopes
    (view claimIss $ claims) @?= (expectedDomain ^? stringOrUri @Text)
    (view claimAud $ claims) @?= (Audience . (: []) <$> expectedDomain ^? stringOrUri @Text)
    (view claimSub $ claims) @?= (idToText uid ^? stringOrUri)
    let expTime = (\(NumericDate x) -> x) . fromMaybe (error "exp claim missing") . view claimExp $ claims
    diffUTCTime expTime now > 0 @?= True
    let issuingTime = (\(NumericDate x) -> x) . fromMaybe (error "iat claim missing") . view claimIat $ claims
    abs (diffUTCTime issuingTime now) < 5 @?= True -- allow for some generous clock skew

testCreateAccessTokenWrongClientId :: Brig -> Http ()
testCreateAccessTokenWrongClientId brig = do
  uid <- randomId
  let redirectUrl = fromMaybe (error "invalid url") $ fromByteString' "https://example.com"
  let scopes = OAuthScopes $ Set.fromList [ConversationCreate, ConversationCodeCreate]
  (_, secret, code) <- generateOAuthClientAndAuthCode brig uid scopes redirectUrl
  cid <- randomId
  let accessTokenRequest = OAuthAccessTokenRequest OAuthGrantTypeAuthorizationCode cid secret code redirectUrl
  createOAuthAccessToken' brig accessTokenRequest !!! do
    const 404 === statusCode
    const (Just "not-found") === fmap Error.label . responseJsonMaybe

testCreateAccessTokenWrongClientSecret :: Brig -> Http ()
testCreateAccessTokenWrongClientSecret brig = do
  uid <- randomId
  let redirectUrl = fromMaybe (error "invalid url") $ fromByteString' "https://example.com"
  let scopes = OAuthScopes $ Set.fromList [ConversationCreate, ConversationCodeCreate]
  (cid, _, code) <- generateOAuthClientAndAuthCode brig uid scopes redirectUrl
  let secret = OAuthClientPlainTextSecret $ encodeBase16 "ee2316e304f5c318e4607d86748018eb9c66dc4f391c31bcccd9291d24b4c7e"
  let accessTokenRequest = OAuthAccessTokenRequest OAuthGrantTypeAuthorizationCode cid secret code redirectUrl
  createOAuthAccessToken' brig accessTokenRequest !!! do
    const 403 === statusCode
    const (Just "forbidden") === fmap Error.label . responseJsonMaybe

testCreateAccessTokenWrongAuthCode :: Brig -> Http ()
testCreateAccessTokenWrongAuthCode brig = do
  uid <- randomId
  let redirectUrl = fromMaybe (error "invalid url") $ fromByteString' "https://example.com"
  let scopes = OAuthScopes $ Set.fromList [ConversationCreate, ConversationCodeCreate]
  (cid, secret, _) <- generateOAuthClientAndAuthCode brig uid scopes redirectUrl
  let code = OAuthAuthCode $ encodeBase16 "eb32eb9e2aa36c081c89067dddf81bce83c1c57e0b74cfb14c9f026f145f2b1f"
  let accessTokenRequest = OAuthAccessTokenRequest OAuthGrantTypeAuthorizationCode cid secret code redirectUrl
  createOAuthAccessToken' brig accessTokenRequest !!! do
    const 404 === statusCode
    const (Just "not-found") === fmap Error.label . responseJsonMaybe

testCreateAccessTokenWrongUrl :: Brig -> Http ()
testCreateAccessTokenWrongUrl brig = do
  uid <- randomId
  let redirectUrl = fromMaybe (error "invalid url") $ fromByteString' "https://wire.com"
  let scopes = OAuthScopes $ Set.fromList [ConversationCreate, ConversationCodeCreate]
  (cid, secret, code) <- generateOAuthClientAndAuthCode brig uid scopes redirectUrl
  let wrongUrl = fromMaybe (error "invalid url") $ fromByteString' "https://example.com"
  let accessTokenRequest = OAuthAccessTokenRequest OAuthGrantTypeAuthorizationCode cid secret code wrongUrl
  createOAuthAccessToken' brig accessTokenRequest !!! do
    const 400 === statusCode
    const (Just "redirect-url-miss-match") === fmap Error.label . responseJsonMaybe

testCreateAccessTokenExpiredCode :: Opt.Opts -> Brig -> Http ()
testCreateAccessTokenExpiredCode opts brig =
  withSettingsOverrides (opts & Opt.optionSettings . Opt.oauthAuthCodeExpirationTimeSecsInternal ?~ 1) $ do
    uid <- randomId
    let redirectUrl = fromMaybe (error "invalid url") $ fromByteString' "https://example.com"
    let scopes = OAuthScopes $ Set.fromList [ConversationCreate, ConversationCodeCreate]
    (cid, secret, code) <- generateOAuthClientAndAuthCode brig uid scopes redirectUrl
    liftIO $ threadDelay (1 * 1200 * 1000)
    let accessTokenRequest = OAuthAccessTokenRequest OAuthGrantTypeAuthorizationCode cid secret code redirectUrl
    createOAuthAccessToken' brig accessTokenRequest !!! do
      const 404 === statusCode
      const (Just "not-found") === fmap Error.label . responseJsonMaybe

testGetOAuthClientInfoAccessDeniedWhenDisabled :: Opt.Opts -> Brig -> Http ()
testGetOAuthClientInfoAccessDeniedWhenDisabled opts brig =
  withSettingsOverrides (opts & Opt.optionSettings . Opt.oauthEnabledInternal ?~ False) $ do
    cid <- randomId
    uid <- randomId
    getOAuthClientInfo' brig uid cid !!! assertAccessDenied

testCreateCodeOAuthClientAccessDeniedWhenDisabled :: Opt.Opts -> Brig -> Http ()
testCreateCodeOAuthClientAccessDeniedWhenDisabled opts brig =
  withSettingsOverrides (opts & Opt.optionSettings . Opt.oauthEnabledInternal ?~ False) $ do
    cid <- randomId
    uid <- randomId
    let redirectUrl = fromMaybe (error "invalid url") $ fromByteString' "https://example.com"
    createOAuthCode brig uid (NewOAuthAuthCode cid (OAuthScopes Set.empty) OAuthResponseTypeCode redirectUrl "") !!! assertAccessDenied

testCreateAccessTokenAccessDeniedWhenDisabled :: Opt.Opts -> Brig -> Http ()
testCreateAccessTokenAccessDeniedWhenDisabled opts brig =
  withSettingsOverrides (opts & Opt.optionSettings . Opt.oauthEnabledInternal ?~ False) $ do
    cid <- randomId
    let secret = OAuthClientPlainTextSecret $ encodeBase16 "ee2316e304f5c318e4607d86748018eb9c66dc4f391c31bcccd9291d24b4c7e"
    let code = OAuthAuthCode $ encodeBase16 "eb32eb9e2aa36c081c89067dddf81bce83c1c57e0b74cfb14c9f026f145f2b1f"
    let wrongUrl = fromMaybe (error "invalid url") $ fromByteString' "https://example.com"
    let accessTokenRequest = OAuthAccessTokenRequest OAuthGrantTypeAuthorizationCode cid secret code wrongUrl
    createOAuthAccessToken' brig accessTokenRequest !!! assertAccessDenied

testRegisterOAuthClientAccessDeniedWhenDisabled :: Opt.Opts -> Brig -> Http ()
testRegisterOAuthClientAccessDeniedWhenDisabled opts brig =
  withSettingsOverrides (opts & Opt.optionSettings . Opt.oauthEnabledInternal ?~ False) $ do
    let newOAuthClient = newOAuthClientRequestBody "E Corp" "https://example.com"
    registerNewOAuthClient' brig newOAuthClient !!! assertAccessDenied

assertAccessDenied :: Assertions ()
assertAccessDenied = do
  const 403 === statusCode
  const (Just "forbidden") === fmap Error.label . responseJsonMaybe

testAccessResourceSuccessInternal :: Brig -> Http ()
testAccessResourceSuccessInternal brig = do
  uid <- userId <$> createUser "alice" brig
  let redirectUrl = fromMaybe (error "invalid url") $ fromByteString' "https://example.com"
  let scopes = OAuthScopes $ Set.fromList [SelfRead]
  (cid, secret, code) <- generateOAuthClientAndAuthCode brig uid scopes redirectUrl
  let accessTokenRequest = OAuthAccessTokenRequest OAuthGrantTypeAuthorizationCode cid secret code redirectUrl
  accessToken <- createOAuthAccessToken brig accessTokenRequest
  -- should succeed with Z-User header
  response :: SelfProfile <- responseJsonError =<< get (brig . paths ["self"] . zUser uid) <!! const 200 === statusCode
  -- should succeed with Z-OAuth header containing an OAuth bearer token
  response' :: SelfProfile <- responseJsonError =<< get (brig . paths ["self"] . zOAuthHeader (oatAccessToken accessToken)) <!! const 200 === statusCode
  liftIO $ response @?= response'

testAccessResourceSuccessNginz :: Brig -> Nginz -> Http ()
testAccessResourceSuccessNginz brig nginz = do
  -- with ZAuth header
  user <- createUser "alice" brig
  let email = fromMaybe (error "no email") $ userEmail user
  zauthToken <- decodeToken <$> (login nginz (defEmailLogin email) PersistentCookie <!! const 200 === statusCode)
  get (nginz . path "/self" . header "Authorization" ("Bearer " <> toByteString' zauthToken)) !!! const 200 === statusCode

  -- with Authorization header containing an OAuth bearer token
  let redirectUrl = fromMaybe (error "invalid url") $ fromByteString' "https://example.com"
  let scopes = OAuthScopes $ Set.fromList [SelfRead]
  (cid, secret, code) <- generateOAuthClientAndAuthCode brig (userId user) scopes redirectUrl
  let accessTokenRequest = OAuthAccessTokenRequest OAuthGrantTypeAuthorizationCode cid secret code redirectUrl
  oauthToken <- oatAccessToken <$> createOAuthAccessToken brig accessTokenRequest
  get (nginz . paths ["self"] . authHeader oauthToken) !!! const 200 === statusCode

testAccessResourceInsufficientScope :: Brig -> Http ()
testAccessResourceInsufficientScope brig = do
  uid <- userId <$> createUser "alice" brig
  let redirectUrl = fromMaybe (error "invalid url") $ fromByteString' "https://example.com"
  let scopes = OAuthScopes $ Set.fromList [ConversationCreate]
  (cid, secret, code) <- generateOAuthClientAndAuthCode brig uid scopes redirectUrl
  let accessTokenRequest = OAuthAccessTokenRequest OAuthGrantTypeAuthorizationCode cid secret code redirectUrl
  accessToken <- createOAuthAccessToken brig accessTokenRequest
  get (brig . paths ["self"] . zOAuthHeader (oatAccessToken accessToken)) !!! do
    const 403 === statusCode
    const "Access denied" === statusMessage
    const (Just "Insufficient scope") === responseBody

testAccessResourceExpiredToken :: Opt.Opts -> Brig -> Http ()
testAccessResourceExpiredToken opts brig =
  withSettingsOverrides (opts & Opt.optionSettings . Opt.oauthAccessTokenExpirationTimeSecsInternal ?~ 1) $ do
    uid <- userId <$> createUser "alice" brig
    let redirectUrl = fromMaybe (error "invalid url") $ fromByteString' "https://example.com"
    let scopes = OAuthScopes $ Set.fromList [SelfRead]
    (cid, secret, code) <- generateOAuthClientAndAuthCode brig uid scopes redirectUrl
    let accessTokenRequest = OAuthAccessTokenRequest OAuthGrantTypeAuthorizationCode cid secret code redirectUrl
    accessToken <- createOAuthAccessToken brig accessTokenRequest
    liftIO $ threadDelay (1 * 1200 * 1000)
    get (brig . paths ["self"] . zOAuthHeader (oatAccessToken accessToken)) !!! do
      const 403 === statusCode
      const "Access denied" === statusMessage
      const (Just "Invalid token: JWTExpired") === responseBody

testAccessResourceNonsenseToken :: Brig -> Http ()
testAccessResourceNonsenseToken brig = do
  get (brig . paths ["self"] . zOAuthHeader @Text "foo") !!! do
    const 403 === statusCode
    const "Access denied" === statusMessage
    const (Just "Invalid token: Failed reading: JWSError") =~= responseBody

testAccessResourceNoToken :: Brig -> Http ()
testAccessResourceNoToken brig =
  get (brig . paths ["self"]) !!! do
    const 403 === statusCode
    const "Access denied" === statusMessage

testAccessResourceInvalidSignature :: Opt.Opts -> Brig -> Http ()
testAccessResourceInvalidSignature opts brig = do
  uid <- userId <$> createUser "alice" brig
  let redirectUrl = fromMaybe (error "invalid url") $ fromByteString' "https://example.com"
  let scopes = OAuthScopes $ Set.fromList [SelfRead]
  (cid, secret, code) <- generateOAuthClientAndAuthCode brig uid scopes redirectUrl
  let accessTokenRequest = OAuthAccessTokenRequest OAuthGrantTypeAuthorizationCode cid secret code redirectUrl
  accessToken <- createOAuthAccessToken brig accessTokenRequest
  key <- liftIO $ readJwk (fromMaybe "path to jwk not set" (Opt.setOAuthJwkKeyPair $ Opt.optSettings opts)) <&> fromMaybe (error "invalid key")
  claimSet <- fromRight (error "token invalid") <$> liftIO (verify key (unOAuthAccessToken $ oatAccessToken accessToken))
  tokenSignedWithWrongKey <- signJwtToken wrongKey claimSet
  get (brig . paths ["self"] . zOAuthHeader (OAuthAccessToken tokenSignedWithWrongKey)) !!! do
    const 403 === statusCode
    const "Access denied" === statusMessage
    const (Just "Invalid token: JWSError JWSInvalidSignature") === responseBody

-------------------------------------------------------------------------------
-- Util

authHeader :: ToHttpApiData a => a -> Request -> Request
authHeader = bearer "Authorization"

zOAuthHeader :: ToHttpApiData a => a -> Request -> Request
zOAuthHeader = bearer "Z-OAuth"

bearer :: ToHttpApiData a => HeaderName -> a -> Request -> Request
bearer name = header name . toHeader . Bearer

newOAuthClientRequestBody :: Text -> Text -> NewOAuthClient
newOAuthClientRequestBody name url =
  let redirectUrl = fromMaybe (error "invalid url") $ fromByteString' (cs url)
      applicationName = OAuthApplicationName (unsafeRange name)
   in NewOAuthClient applicationName redirectUrl

registerNewOAuthClient :: (MonadIO m, MonadHttp m, MonadCatch m, HasCallStack) => Brig -> NewOAuthClient -> m OAuthClientCredentials
registerNewOAuthClient brig reqBody =
  responseJsonError =<< registerNewOAuthClient' brig reqBody <!! const 200 === statusCode

registerNewOAuthClient' :: (MonadIO m, MonadHttp m, HasCallStack) => Brig -> NewOAuthClient -> m ResponseLBS
registerNewOAuthClient' brig reqBody =
  post (brig . paths ["i", "oauth", "clients"] . json reqBody)

getOAuthClientInfo :: (MonadIO m, MonadHttp m, MonadCatch m, HasCallStack) => Brig -> UserId -> OAuthClientId -> m OAuthClient
getOAuthClientInfo brig uid cid =
  responseJsonError =<< getOAuthClientInfo' brig uid cid <!! const 200 === statusCode

getOAuthClientInfo' :: (MonadIO m, MonadHttp m, HasCallStack) => Brig -> UserId -> OAuthClientId -> m ResponseLBS
getOAuthClientInfo' brig uid cid =
  get (brig . paths ["oauth", "clients", toByteString' cid] . zUser uid)

createOAuthCode :: (MonadIO m, MonadHttp m, HasCallStack) => Brig -> UserId -> NewOAuthAuthCode -> m ResponseLBS
createOAuthCode brig uid reqBody = post (brig . paths ["oauth", "authorization", "codes"] . zUser uid . json reqBody . noRedirect)

createOAuthAccessToken :: (MonadIO m, MonadHttp m, MonadCatch m, HasCallStack) => Brig -> OAuthAccessTokenRequest -> m OAuthAccessTokenResponse
createOAuthAccessToken brig reqBody = responseJsonError =<< createOAuthAccessToken' brig reqBody <!! const 200 === statusCode

createOAuthAccessToken' :: (MonadIO m, MonadHttp m, HasCallStack) => Brig -> OAuthAccessTokenRequest -> m ResponseLBS
createOAuthAccessToken' brig reqBody = do
  post (brig . paths ["oauth", "token"] . content "application/x-www-form-urlencoded" . body (RequestBodyLBS $ urlEncodeAsForm reqBody))

generateOAuthClientAndAuthCode :: (MonadIO m, MonadHttp m, MonadCatch m, HasCallStack) => Brig -> UserId -> OAuthScopes -> RedirectUrl -> m (OAuthClientId, OAuthClientPlainTextSecret, OAuthAuthCode)
generateOAuthClientAndAuthCode brig uid scope url = do
  let newOAuthClient = NewOAuthClient (OAuthApplicationName (unsafeRange "E Corp")) url
  OAuthClientCredentials cid secret <- registerNewOAuthClient brig newOAuthClient
  let state = "foobar"
  response <-
    createOAuthCode brig uid (NewOAuthAuthCode cid scope OAuthResponseTypeCode url state) <!! do
      const 302 === statusCode
  maybe (error "generating code failed") (pure . (,,) cid secret) $ (getHeader "Location" >=> fromByteString >=> getQueryParamValue "code" >=> fromByteString) response
  where
    getQueryParams :: RedirectUrl -> [(ByteString, ByteString)]
    getQueryParams (RedirectUrl uri) = uri ^. (queryL . queryPairsL)

    getQueryParamValue :: ByteString -> RedirectUrl -> Maybe ByteString
    getQueryParamValue key uri = snd <$> find ((== key) . fst) (getQueryParams uri)

signJwtToken :: JWK -> OAuthClaimSet -> Http SignedJWT
signJwtToken key claims = do
  jwtOrError <- liftIO $ doSignClaims
  either (const $ error "jwt error") pure jwtOrError
  where
    doSignClaims :: IO (Either JWTError SignedJWT)
    doSignClaims = runJOSE $ do
      algo <- bestJWSAlg key
      signJWT key (newJWSHeader ((), algo)) claims

wrongKey :: JWK
wrongKey = fromMaybe (error "invalid jwk") $ A.decode "{\"p\":\"-Ahl1aNMOqXLUtJHVO1OLGt92EOrjzcNlwB5AL9hp8-GykJIK6BIfDvCCJgDUX-8ZZ-1R485XFVtUiI5W72MKbJ-qicTB7Smzd7St_zO6PZUbkgQoJiosAOMjP_8DBs9CbMl9FqUfE1pNo4O0gYHslUoCKwS5IsAB9HjuHGEQ38\",\"kty\":\"RSA\",\"q\":\"qRih0wBK2xg2wyJcBN6dDpUHTBxNEt8jxmvy33oMU-_Vx0hFLVeAqDYK-awlHGtJQJKp1mXdURXocKXKPukVitnfEH8nvl6vQIr4-uXyENe3yLgADi8VRDZCbWuDVWYAlYlFgdNODZ_A_fIqCmGAw27bwXyZZ3IRusnipyFN6iM\",\"d\":\"L0uBKJrI4I-_X9KPQawrLDEnPT7msevOH5Rf264CPZgwe8B9M0mbGmhIzYFIThNSaEzGoEtyJdTf27zoawh3O3KQO0aJr2HKSCTMZUh7fpqIjYlu5jA_dT3k7yHHMIR4lRLQV0vb936Mu09kTkRqMZ0jSo46dJ5iw0wnuSF0dAiqVG0rSJK-gVBdIbzZYxhSBW4ZF3n4CqtFb6lc1stfZHcnzWHyF6Cofzup6pJumeFe7xXF9-aGU-3UcTSzTnMa21NVP-vT2CXkH8dSfwLI-PuJwlW6tcpBwT2PXrCGyAGqQ3h5cdAmwcgfbla8wqrzj1A08SlkKHvTDixVvnnzpQ\",\"e\":\"AQAB\",\"use\":\"sig\",\"kid\":\"0makAydOdX3vNv4YTToO45ccQUCOoLisvAFVyhiKA4c\",\"qi\":\"phNbA_tiDLQq1omVgM1dHtOe6Dd7J_ZoRdz1Rmc4uaSQyJe-yn88DxXlX10DJkM9uqyzcojOtD5awBUXgYSzmasZvcZ0e2XNi7iXmSwsggTux3lUVVqKWV8HreaSywJ-HqitxjitooWSWOyD9o8yq9RS4r2QdXyuCfthwnEZdpc\",\"dp\":\"q0IJJmjZYolFiYsdq5sq5erWerPGyl0l6gRuiECcqiTVmeQINu81_Wm5gPuNFwHO0JBkt-NBpOprUFHHLvwCwmu3n77ZGfH3VqCq-FT7fMlQ5NCngmvF1bqtmlHJ84X_MCpdY4oDioxcwEl4HDYDrHO17774UItVWxDmXl0rCPs\",\"alg\":\"PS512\",\"dq\":\"NznQQDVsPTofSIPEQeLisIyDoZvsoCk4ael_nPUjaZZ-32L_FNvrLQTZeMl8JVf0yJ4d0ePa8EyTaZb8AqflXT_i1mRw-n-6BP5earMG5_FMGMXfXsKJ04lVEJ94eT-jGTOH--qjJ1fxk_6vNEy73RgrtXmYMGzU1Yhx-duqsrk\",\"n\":\"o9VozUwUc1mQMrAH2fEna_ihmNa3CVRzK7MUgDHEbfY0T71wREpK4f4fOkDysKIqnmMdxRzJhsXTDpxX8_8AlKcimPgR8Qb2z7GwDsnDZOdgAYrZ7l7gj0nX02IX35MBk7a7tWr0nILFLV9SxEu6UFcZo0bL2Rhck81TRqLbomJpIzAq8VCS8uMQeg6hEMarl9tGvSKyFuMdTCV3JE9dSv_NErAWx7uBIgkai3Imjs4ufatvRsi9ZHaUV5V3NtrFbYDulg-GOH1eXZwnO6UrKgcAdB3nS1WKL-vcxqupceAHeFHRjARm6AV07hJyXVOVHxdffv6BFX5GihFPFvpQXQ\"}"