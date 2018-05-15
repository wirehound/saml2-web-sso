{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE QuasiQuotes           #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TupleSections         #-}
{-# LANGUAGE TypeApplications      #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE ViewPatterns          #-}

{-# OPTIONS_GHC -Wno-orphans #-}

-- | This is a partial implementation of Web SSO using the HTTP Post Binding [2/3.5].
--
-- The default API offers 3 end-points: one for retrieving the 'AuthnRequest' in a redirect to the
-- IdP; one for delivering the 'AuthnResponse' that will re-direct to some fixed landing page; and
-- one for retrieving the SP's metadata.
--
-- There are other scenarios, e.g. all resources on the page could be guarded with an authentication
-- check and redirect the client to the IdP, and make sure that the client lands on the initally
-- requested resource after successful authentication.  With the building blocks provided by this
-- module, it should be straight-forward to implemented all of these scenarios.
--
-- This module works best if imported qualified.
--
-- FUTUREWORK: servant-server is quite heavy.  we should have a cabal flag to exclude it.
module SAML.WebSSO.API where

import Control.Monad.Except hiding (ap)
import Data.Binary.Builder (toLazyByteString)
import Data.EitherR
import Data.Function
import Data.List
import Data.Proxy
import Data.String.Conversions
import Lens.Micro
import Network.HTTP.Media ((//))
import Network.Wai hiding (Response)
import Network.Wai.Internal as Wai
import Servant.API.ContentTypes
import Servant.API hiding (URI)
import Servant.Multipart
import Servant.Server
import Text.Hamlet.XML
import Text.Show.Pretty (ppShow)
import Text.XML
import URI.ByteString
import Web.Cookie

import qualified Crypto.PubKey.RSA as RSA
import qualified Data.ByteString.Base64.Lazy as EL
import qualified Data.Map as Map
import qualified Data.Text as ST
import qualified Network.HTTP.Types.Header as HttpTypes
import qualified SAML.WebSSO.XML.Meta as Meta

import SAML.WebSSO.Config
import SAML.WebSSO.SP
import SAML.WebSSO.Types
import SAML.WebSSO.XML
import Text.XML.DSig


----------------------------------------------------------------------
-- saml web-sso api

type API = APIMeta :<|> APIAuthReq :<|> APIAuthResp

type APIMeta     = "meta" :> Get '[XML] Meta.SPDesc
type APIAuthReq  = "authreq" :> Capture "idp" ST :> Get '[HTML] (FormRedirect AuthnRequest)
type APIAuthResp = "authresp" :> MultipartForm Mem AuthnResponseBody :> PostVoid

-- FUTUREWORK: respond with redirect in case of success, instead of responding with Void and
-- handling all cases with exceptions: https://github.com/haskell-servant/servant/issues/117

api :: (SP m, SPNT m) => ST -> ServerT API m
api appName = meta appName :<|> authreq :<|> authresp


----------------------------------------------------------------------
-- servant, wai plumbing

type GetVoid  = Get  '[HTML, JSON, XML] Void
type PostVoid = Post '[HTML, JSON, XML] Void

data XML

instance Accept XML where
  contentType Proxy = "application" // "xml"

instance {-# OVERLAPPABLE #-} HasXMLRoot a => MimeRender XML a where
  mimeRender Proxy = cs . encode

instance {-# OVERLAPPABLE #-} HasXMLRoot a => MimeUnrender XML a where
  mimeUnrender Proxy = fmapL show . decode . cs


data Void

instance MimeRender HTML Void where
  mimeRender Proxy = error "absurd"

instance {-# OVERLAPS #-} MimeRender JSON Void where
  mimeRender Proxy = error "absurd"

instance {-# OVERLAPS #-} MimeRender XML Void where
  mimeRender Proxy = error "absurd"


data HTML

instance  Accept HTML where
  contentType Proxy = "text" // "html"


-- | An 'AuthnResponseBody' contains a 'AuthnResponse', but you need to give it a trust base forn
-- signature verification first, and you may get an error when you're looking at it.
newtype AuthnResponseBody = AuthnResponseBody ((ST -> Maybe RSA.PublicKey) -> Either ServantErr AuthnResponse)

instance FromMultipart Mem AuthnResponseBody where
  fromMultipart resp = Just . AuthnResponseBody $ \lookupPublicKey -> do
    base64 <- maybe (throwError err400 { errBody = "no SAMLResponse in the body" }) pure $
              lookupInput "SAMLResponse" resp
    xmltxt <- either (const $ throwError err400 { errBody = "bad base64 encoding in SAMLResponse" }) pure $
              EL.decode (cs base64)
    either (\ex -> throwError err400 { errBody = "invalid signature: " <> cs ex }) pure $
      simpleVerifyAuthnResponse lookupPublicKey xmltxt
    either (\ex -> throwError err400 { errBody = cs $ show ex }) pure $
      decode (cs xmltxt)


-- | [2/3.5.4]
data FormRedirect xml = FormRedirect URI xml
  deriving (Eq, Show)

class HasXML xml => HasFormRedirect xml where
  formRedirectFieldName :: xml -> ST

instance HasFormRedirect AuthnRequest where
  formRedirectFieldName _ = "SAMLRequest"

instance HasXMLRoot xml => MimeRender HTML (FormRedirect xml) where
  mimeRender (Proxy :: Proxy HTML)
             (FormRedirect (cs . serializeURIRef' -> uri) (cs . EL.encode . cs . encode -> value))
    = mkHtml [xml|
                 <body onload="document.forms[0].submit()">
                   <noscript>
                     <p>
                       <strong>
                         Note:
                       Since your browser does not support JavaScript, you must press the Continue button once to proceed.
                   <form action=#{uri} method="post">
                     <input type="hidden" name="SAMLRequest" value=#{value}>
                     <noscript>
                       <input type="submit" value="Continue">
             |]

mkHtml :: [Node] -> LBS
mkHtml nodes = renderLBS def doc
  where
    doc      = Document (Prologue [] (Just doctyp) []) root []
    doctyp   = Doctype "html" (Just $ PublicID "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd")
    root     = Element "html" rootattr nodes
    rootattr = Map.fromList [("xmlns", "http://www.w3.org/1999/xhtml"), ("xml:lang", "en")]


-- | [3.5.5.1] Caching
setHttpCachePolicy :: Middleware
setHttpCachePolicy ap rq respond = ap rq $ respond . addHeadersToResponse httpCachePolicy
  where
    httpCachePolicy :: HttpTypes.ResponseHeaders
    httpCachePolicy = [("Cache-Control", "no-cache, no-store"), ("Pragma", "no-cache")]

    addHeadersToResponse :: HttpTypes.ResponseHeaders -> Wai.Response -> Wai.Response
    addHeadersToResponse extraHeaders resp = case resp of
      ResponseFile status hdrs filepath part -> ResponseFile status (updH hdrs) filepath part
      ResponseBuilder status hdrs builder    -> ResponseBuilder status (updH hdrs) builder
      ResponseStream status hdrs body        -> ResponseStream status (updH hdrs) body
      ResponseRaw action resp'               -> ResponseRaw action $
                                                    addHeadersToResponse extraHeaders resp'
      where
        updH hdrs = nubBy ((==) `on` fst) $ extraHeaders ++ hdrs


----------------------------------------------------------------------
-- handlers

meta :: SP m => ST -> m Meta.SPDesc
meta appName = do
  enterH "meta"
  desc :: Meta.SPDescPre <- do
    hom <- getPath SpPathHome
    rsp <- getPath SsoPathAuthnResp
    Meta.spDesc appName hom rsp
  pure . Meta.spMeta $ desc

authreq :: (SPNT m) => ST -> m (FormRedirect AuthnRequest)
authreq idpname = do
  enterH "authreq"
  uri <- (^. idpRequestUri) <$> getIdPConfig idpname
  req <- createAuthnRequest
  leaveH $ FormRedirect uri req

-- | Get config and pass the missing idp credentials to the response constructor.
resolveBody :: (SPNT m) => AuthnResponseBody -> m AuthnResponse
resolveBody (AuthnResponseBody mkbody) = do
  idps <- (^. cfgIdps) <$> getConfig
  pubkeys <- forM idps $ \idp -> do
    let path = renderURI $ idp ^. idpIssuerID
    creds <- either crash pure $ keyInfoToCreds (idp ^. idpPublicKey)
    case creds of
      SignCreds SignDigestSha256 (SignKeyRSA pubkey) -> pure (path, pubkey)
  either throwError pure $ mkbody (`Map.lookup` Map.fromList pubkeys)

authresp :: (SPNT m) => AuthnResponseBody -> m Void
authresp body = do
  enterH "authresp: entering"
  resp <- resolveBody body
  enterH $ "authresp: " <> ppShow resp
  verdict <- judge resp
  logger $ show verdict
  case verdict of
    AccessDenied reasons
      -> logger (show reasons) >> reject (cs $ ST.intercalate ", " reasons)
    AccessGranted uid
      -> getPath SpPathHome >>=
         \sphome -> redirect sphome [cookieToHeader . togglecookie . Just . cs . show $ uid]


----------------------------------------------------------------------
-- handler combinators

crash :: (SP m, MonadError ServantErr m) => String -> m a
crash msg = do
  logger msg
  throwError err500 { errBody = "internal error: consult server logs." }

enterH :: SP m => String -> m ()
enterH msg =
  logger $ "entering handler: " <> msg

leaveH :: (Show a, SP m) => a -> m a
leaveH x = do
  logger $ "leaving handler: " <> show x
  pure x


----------------------------------------------------------------------
-- cookies

cookiename :: SBS
cookiename = "saml2-web-sso_sp_credentials"

togglecookie :: Maybe ST -> SetCookie
togglecookie = \case
  Just nick -> cookie
    { setCookieValue = cs nick
    }
  Nothing -> cookie
    { setCookieValue = ""
    , setCookieExpires = Just . fromTime $ unsafeReadTime "1970-01-01T00:00:00Z"
    , setCookieMaxAge = Just (-1)
    }
  where
    cookie = defaultSetCookie
      { setCookieName = cookiename
      , setCookieSecure = True
      , setCookiePath = Just "/"
      }

cookieToHeader :: SetCookie -> HttpTypes.Header
cookieToHeader = ("set-cookie",) . cs . toLazyByteString . renderSetCookie

headerValueToCookie :: ST -> Either ST SetCookie
headerValueToCookie txt = do
  let cookie = parseSetCookie $ cs txt
  case ["missing cookie name"  | setCookieName cookie == ""] <>
       ["wrong cookie name"    | setCookieName cookie /= cookiename] <>
       ["missing cookie value" | setCookieValue cookie == ""]
    of errs@(_:_) -> throwError $ ST.intercalate ", " errs
       []         -> pure cookie
