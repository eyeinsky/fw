module PWA where

import qualified Prelude2 as P
import qualified JS.Syntax
import JS hiding (last, Name, Bool, not, replace, (.=))
import qualified JS
import qualified DOM
import URL
-- import Web
import Web.Response hiding (js)
import Web.Endpoint hiding (M)

import Apps.Lib as Lib hiding ((.=), M)
import Apps.Upstream hiding (clone)


data Request

-- * Web Worker

data Worker

self :: Expr a
self = ex "self"

-- ** Internal

-- | Receive dato on 'message' event, apply the provided function and
-- use 'postMessage' to send the result back
pipe :: Function f => f -> M r ()
pipe f = do
  f' <- newf f
  wrap <- newf $ \msg -> send self (call1 f' msg)
  bare $ DOM.addEventListener self DOM.Message wrap

-- ** External

createWorker :: URL -> Expr Worker
createWorker path = call1 (ex "new Worker") (lit $ renderURL path)

postMessage :: Expr a -> Expr b -> Expr ()
postMessage obj msg = call1 (obj !. "postMessage") msg

send :: Expr a -> Expr b -> M r ()
send o m = bare $ postMessage o m

receive :: Expr a -> Expr f -> M r ()
receive worker handler = do
  bare $ DOM.addEventListener (Cast worker) DOM.Message handler

-- * Caches API

-- ** CacheStorage

data Caches

caches :: Expr Caches
caches = ex "caches"

open :: Expr String -> Expr Caches -> Promise Cache
open name caches = call1 (caches !. "open" ) name

keys :: Expr caches -> Promise ()
keys caches = call0 (caches !. "keys")

-- ** Cache

data Cache

match :: Expr Request -> Expr Cache -> Promise Response
match req cache = call1 (cache !. "match") req

put :: Expr Request -> Expr Response -> Expr Cache -> Promise ()
put req resp cache = call (cache !. "put") [req, Cast resp]

delete :: Expr Request -> Expr Cache -> Promise Bool
delete req cache = call1 (cache !. "delete") req

-- * Fetch API

fetch :: Expr Request -> Promise Response
fetch req = call1 (ex "fetch") req

request :: Expr DOM.ServiceWorkerEvent -> Expr Request
request fetchEvent = fetchEvent !. "request"

clone :: Expr Response -> Expr Response
clone req = call0 (req !. "clone")

url :: Expr Request -> Expr URL
url req = req !. "url"

-- * Service Worker

-- | ExtendableEvent method, available in service workers
waitUntil :: Promise () -> Expr () -> Promise ()
waitUntil promise installEvent = call1 (installEvent !. "waitUntil") promise

-- ** Register

register :: URL -> M r ()
register url = let
  cond = "serviceWorker" `JS.Syntax.In` ex "navigator"
  urlStr = lit $ renderURL url
  reg = call1 (ex "navigator" !. "serviceWorker" !. "register") urlStr
  in ifonly cond $ do
  success <- newf $ consoleLog ["service worker registered"]
  fail <- newf $ consoleLog ["service worker failed"]
  bare $ (reg `then_` success) `catch` fail

then_ promise handler = call1 (promise !. "then") handler
catch promise handler = call1 (promise !. "catch") handler


-- ** Install

-- | Cache all argument URLs
addAll :: Expr Cache -> [Lib.String] -> Promise ()
addAll cache paths = call1 (cache !. "addAll") arr
  where
    arr = lit (map lit paths) :: Expr [String]

-- *** Install handlers

addAll' :: [URL] -> M r1 (Expr (Expr (), Proxy ()))
addAll' urls = let
  strs = urls & map (renderURL ^ view (from packed))
  in newf $ \event -> do
  consoleLog ["install handler"]
  f <- async $ do
    let li = lit $ P.intercalate ", " strs
    consoleLog ["install handler: add all: ", li]
    cache <- await $ open "cache" caches
    await $ addAll cache strs
  bare $ waitUntil (call0 f) event

-- *** Fetch

respondWith :: DOM.Event e => Promise () -> Expr e -> Expr ()
respondWith promise fetchEvent = call1 (fetchEvent !. "respondWith") promise

-- ** Generation

declareFields [d|
  data Gen = Gen
    { genInstallCache :: [URL]
    , genCacheNetworkFallback :: [URL]
    , genNetworkCacheFallback :: [URL]
    , genCacheOnly :: [URL]
    , genNetworkOnly :: [URL]
    , genCacheNetworkRace :: [URL]
    }
   |]

instance Default Gen where
  def = Gen mempty mempty mempty mempty mempty mempty

generate :: Gen -> M r ()
generate gen = do
  installHandler <- addAll' $ gen^.installCache
  fetchHandler <- newf $ \(event :: Expr ServiceWorkerEvent) -> do
    genCode event defaultFetch
       $ map (cacheNetwork event) (gen^.cacheNetworkFallback)
      <> map (cacheOnly event) (gen^.installCache)

  bare $ DOM.addEventListener self DOM.Install installHandler
  bare $ DOM.addEventListener self DOM.Fetch fetchHandler
  where
    genCode :: Expr ServiceWorkerEvent -> (Expr ServiceWorkerEvent -> JS.M r ()) -> [(Expr Bool, M r ())] -> JS.M r ()
    genCode event defaultFetch li = foldl f (defaultFetch event) li
      where f rest (cond, code) = ifelse cond code rest

    mkCond :: Expr ServiceWorkerEvent -> URL -> Expr Bool
    mkCond event url' = url (request event) .=== lit (renderURL url')

    cacheOnly :: Expr ServiceWorkerEvent -> URL -> (Expr Bool, JS.M r ())
    cacheOnly event url' = let
      code = do
        req <- new $ request event
        p <- promise $ do
          cache <- await $ open "cache" caches
          resp <- await $ match req cache
          consoleLog ["fetch: cache only:", url req]
          retrn resp
        bare $ respondWith p event
      in (mkCond event url', code)

    cacheNetwork :: Expr ServiceWorkerEvent -> URL -> (Expr Bool, JS.M r ())
    cacheNetwork event url' = let
      code = do
        req <- new $ request event
        p <- promise $ do
          cache :: Expr Cache <- await $ open "cache" caches
          resp :: Expr Response <- await $ match req cache
          ifelse (Cast resp) (
            do consoleLog ["fetch: cache hit:", url req]
               retrn resp
            ) (
            do consoleLog ["fetch: cache miss:", url req]
               networkResponse :: Expr Response <- await $ fetch req
               putCache <- async $ do -- created to see that it happens async
                 await $ put req (clone networkResponse) cache
                 consoleLog ["fetch: cache put clone:", url req]
               bare $ call0 putCache
               consoleLog ["fetch: return network response:", url req]
               retrn networkResponse
            )
        bare $ respondWith p event
      in (mkCond event url', code)

    defaultFetch :: Expr ServiceWorkerEvent -> JS.M r ()
    defaultFetch event = consoleLog ["fetch: url(", url $ request event, ")", "no conditions"]

pwaDiagnostics = do
  listCaches <- api $ return $ \req -> do
    cssRule Lib.body $ do
      whiteSpace "pre"
    js $ do
      mklink <- newf $ \url -> do
        retrn $ "<a href='" .+ url .+ "'>" .+ url .+ "</a>"
      withCache <- async $ \cacheName -> do
        cache <- await $ open cacheName caches
        requests <- await $ keys cache
        g <- newf $ \req -> retrn $ url req
        urls <- new $ call1 (requests !. "map") g
        let links = call1 (urls !. "map") mklink
        retrn $ cacheName .+ ":<br/>- " .+ (JS.join "<br/>- " links)
      main <- async $ do
        keys <- await $ keys caches
        str <- await $ call1 (ex "Promise" !. "all") $ call1 (keys !. "map") withCache

        bare $ DOM.documentWrite str
      bare $ DOM.addEventListener (Cast DOM.window) DOM.Load (Cast main)

    dest <- newId
    return $ htmlDoc (pure ()) $ do
      div ! dest $ ""

  pin "pwa-diag" $ return $ \req -> do
    return $ htmlDoc (pure ()) $ a ! href listCaches $ "list caches"

  return ()