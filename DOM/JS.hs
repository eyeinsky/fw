{-# LANGUAGE UndecidableInstances #-}
module DOM.JS where

import Pr hiding ((.=), Bool, id)
import Prelude2.Has (HasId(..))
import qualified Data.Text.Lazy as TL
import qualified Data.Text as T
import qualified Data.HashMap.Strict as HM
import Control.Monad.Writer (execWriter)

import Web.Browser
import JS
import JS.Syntax (Statement(BareExpr), Expr(Assign, EAttr))
import qualified JS.Render

import qualified DOM.Core as D
import qualified CSS as CSS
import HTML
import DOM.Core
import DOM.Event
import XML
import SVG hiding (onload, id)

-- * Objects

window :: Expr Window
window = ex "window"

document :: Expr Document
document = ex "document"

location :: Expr Location
location = window !. "location"

getAttribute k e = call1 (e !. "getAttribute") k
setAttribute k v e = call (e !. "setAttribute") [k, v]

requestAnimationFrame :: Expr a -> Expr b
requestAnimationFrame f = call1 (window !. "requestAnimationFrame") f

documentWrite what = call1 (document !. "write") what

-- * Finding elements

class JSSelector a where
  jsSelectorFrom :: a -> Expr JS.String
instance JSSelector (Expr JS.String) where
  jsSelectorFrom a = a
instance {-# OVERLAPPABLE #-} CSS.SelectorFrom a => JSSelector a where
  jsSelectorFrom s = ulit $ render' $ CSS.selFrom s

matches :: JSSelector a => a -> Expr D.Tag -> Expr JS.Bool
matches s e = call1 (e !. "matches") (jsSelectorFrom s)

querySelector :: JSSelector a => a -> Expr D.Tag -> Expr D.Tag
querySelector s e = call1 (e !. "querySelector") (jsSelectorFrom s)

querySelectorAll :: JSSelector a => a -> Expr D.Tag -> Expr D.Tag
querySelectorAll s e = call1 (e !. "querySelectorAll") (jsSelectorFrom s)

queryParents :: JSSelector a => a -> Expr D.Tag -> Expr c
queryParents s e = let
  str = jsSelectorFrom s
  in flip call [Cast str, e] $ funcPure $ \(selector :: Expr JS.String) elem -> do
    e' <- new elem
    r <- new Null
    JS.for (e' !. "matches") $ do
      ifelse (matches selector e') (do r .= e'; bare $ ex "break") (e' .= DOM.JS.parentNode e')
    retrn e'

-- | The global find
class    FindBy a where findBy :: a -> Expr Tag
instance FindBy Id where
   findBy (Id id) = valueSelf id (docCall "getElementById")
instance FindBy Class where
   findBy (Class a) = valueSelf a (docCall "getElementsByClassName")

instance FindBy TagName where
   findBy (TagName a) = valueSelf a (docCall "getElementsByTagName")
instance FindBy (Expr Id) where
   findBy a = docCall' "getElementById" a
instance FindBy (Expr Class) where
   findBy a = docCall' "getElementsByClassName" a

valueSelf :: D.Value -> (TL.Text -> Expr b) -> Expr b
valueSelf v f = case v of
  Static a -> f a
  Dynamic a -> Cast a

valueExpr :: D.Value -> Expr ()
valueExpr v = case v of
  Static a -> ulit a
  Dynamic a -> Cast a

docCall' f a = call1 (document !. f) a
docCall f a = docCall' f (ulit a)

--

ea s e = e !. s

offsetHeight = ea "offsetHeight"
scrollHeight = ea "scrollHeight"

scrollTop = ea "scrollTop"
scrollBottom e = scrollTop e + offsetHeight e

offsetTop = ea "offsetTop"
offsetBottom e = ea "offsetTop" e + offsetHeight e

atTop el = scrollTop el .== 0 :: Expr JS.Bool
atBottom el = scrollBottom el .>= scrollHeight el :: Expr JS.Bool

getComputedStyle e = call1 (ex "getComputedStyle") e

childNodes e = e !. "childNodes"

-- * Modify DOM

timeStamp e = e !. "timeStamp"

appendChild :: Expr Tag -> Expr Tag -> Expr ()
appendChild a t = call1 (t !. "appendChild") a

insertBefore a b = call (parentNode b !. "insertBefore") [a, b]

replaceChild old new = call (parentNode old !. "replaceChild") [new, old]

remove' :: Expr Tag -> JS.M r (Expr Tag)
remove' e = JS.browser <&> \b -> case b of
  IE -> removeChild (parentNode e) e
  _ -> call0 (e !. "remove")

remove :: Expr Tag -> JS.M r ()
remove e = remove' e >>= bare

removeChild :: Expr Tag -> Expr Tag -> Expr Tag
removeChild parent child = call1 (parent !. "removeChild") child

parentNode :: Expr Tag -> Expr Tag
parentNode e = e !. "parentNode"

setInnerHTML e x = innerHTML e .= x

innerHTML e = e !. "innerHTML"

createElement :: TagName -> Expr Tag
createElement tn = docCall' "createElement" $ valueExpr $ unTagName tn

createTextNode :: Expr a -> Expr b
createTextNode txt = docCall' "createTextNode" txt

createDocumentFragment :: Expr DocumentFragment
createDocumentFragment = call0 (document !. "createDocumentFragment")

createClasses :: [Class] -> Expr ()
createClasses cs = if null dynamics'
  then statics
  else dynamics
  where
    (statics', dynamics') = partitionEithers $ map (value2either . unClass) cs
    statics = ulit $ TL.unwords statics'
    dynamics = JS.join " " $ ulit dynamics'

-- *** Text input

-- cursorPosition :: Expr Tag -> M JT.Number (Expr JT.Number)
cursorPosition e = do
      start <- new $ e !. "selectionStart"
      end <- new $ e !. "selectionEnd"
      new $ ternary (start .== end) (Cast start) (Cast Null)
   {- ^ Get caret position from textarea/input type=text

      IE not implemented, see here for how:
         http://stackoverflow.com/questions/1891444/cursor-position-in-a-textarea-character-index-not-x-y-coordinates

   -}


-- ** CSS

cssAttr e k v = e !. "style" !. k .= v
addClass cls el = bare $ call1 (el !. "classList" !. "add"   ) $ mkExpr cls
remClass cls el = bare $ call1 (el !. "classList" !. "remove") $ mkExpr cls

mkExpr = Cast . ulit . static . unClass

-- * From JS_API

-- ** XMLHttpRequest (Ajax)

-- Expr URL -> data -> (\ x -> M y z) -> M a b
-- doPost' a b c = call ajaxExpr ["post", a, b, c]
doPost' uri data_ cb = do
   aj <- newf $ ajaxExpr
   bare $ call aj [ulit "POST", uri, data_, cb]
doGet' uri data_ cb = do
   aj <- newf $ ajaxExpr
   bare $ call aj [ulit "GET", uri, data_, cb]

ajaxExpr meth uri data_ callback = do
   xhr <- new $ ex "new XMLHttpRequest()"
   ifonly (callback .!== Undefined) $ do
      wrap <- newf $ \(ret :: Expr ()) -> do
         text <- new $ xhr !. "responseText"
         json <- new $ fromJSON text
         bare $ call1 callback json
      xhr !. "onload" .= Cast wrap
   bare (call (xhr !. "open") [meth, uri, ulit True])
   bare $ call1 (xhr !. "send") data_

xhrRaw :: Expr a -> Expr a -> Expr c -> Expr d -> JS.M r ()
xhrRaw meth uri data_ callback = do
  xhr <- new $ ex "new XMLHttpRequest()"
  ifonly (callback .!== Undefined) $ do
    xhr !. "onload" .= callback
  bare (call (xhr !. "open") [Cast meth, uri, ulit True])
  bare $ call1 (xhr !. "send") data_

xhrJs :: Expr a -> Expr a -> Expr c -> [Expr d] -> JS.M r ()
xhrJs meth uri data_ args = do
  rc :: JS.Render.Conf <- ask <&> (^.renderConf)
  wrap <- newf $ \(resp :: Expr ()) -> do
    let funcText = responseText resp
        argsText = ulit $ runReader (JS.Render.unargs args) rc
    bare $ call1 (ex "eval") $ funcText + argsText
  xhrRaw meth uri data_ wrap

responseText resp = resp !. "target" !. "responseText"

xhrGet uri args = xhrJs "GET" uri Undefined args
xhrPost uri data_ args = xhrJs "POST" uri data_ args

-- ** DOM/Event

-- focus :: Expr Tag -> Expr M r ()
focus e = call0 (e !. "focus")

-- blur :: Expr Tag -> M r ()
blur e = call0 (e !. "blur")

-- | Get char from keyboard event
eventKey event = do -- from: http://unixpapa.com/js/key.html
   retrn $ let
         which = event !. "which" -- :: Expr J.Number
         from arg = call (ex "String" !. "fromCharCode") [ arg ]
         -- from which or keyCode
      in ternary (which .== ex "null")
      (from $ event !. "keyCode" ) -- old IE
      (ternary
         (  (which .!= ulit 0)
        .&& event !. "charCode" .!= ulit 0
        ) (from which {-all others-}) Null)

preventDefault :: Event e => Expr e -> Expr ()
preventDefault e = call0 (e !. "preventDefault")

mkEventListener :: Event e => TL.Text -> Expr Tag -> e -> [Expr b] -> Expr c
mkEventListener a el et li = call (el !. a) (etStr : li)
  where etStr = ulit $ eventString et

addEventListener el et handler = mkEventListener "addEventListener" el et [handler]
removeEventListener el et handler = mkEventListener "removeEventListener" el et handler

alert :: Expr a -> Expr b
alert x = call1 (ex "alert") x

-- * RenderJSM instances

instance RenderJSM (HTML Both) where
  renderJSM html = case html of
    Element tn as children -> do
      t <- new $ createElement tn
      attrsJSM t mkAttr as
      ts :: [Expr Tag] <- mapM renderJSM children
      forM_ ts $ bare . flip appendChild t
      return t
    Text txt -> return $ createTextNode (ulit txt)
    Raw txt -> do
      tmp <- new $ createElement "div"
      innerHTML tmp .= ulit txt
      nodes <- new $ tmp !. "childNodes"
      frag <- fmap Cast $ new $ createDocumentFragment
      i <- new 0
      JS.for (JS.length nodes JS..> 0) $ do
        bare $ appendChild (nodes .! 0) frag
        i .+= 1
      return frag
    Dyn expr -> return (Cast expr)
    Embed a -> renderJSM a
    where
      mkAttr :: Expr a -> TL.Text -> Attribute -> JS.M r ()
      mkAttr e k attr = case attr of
        Data _ v -> (e !. "dataset" !. kebab2camel k) .= ulit v
        OnEvent et expr -> e !. toOn et .= expr
        Custom _ v -> e !. k .= ulit v

createHtml :: HTML Both -> Expr Tag
createHtml html = AnonFunc Nothing [] . snd . fst . runM def def $ renderJSM html >>= retrn

createHtmls' :: Html -> JS.M r (Expr DocumentFragment)
createHtmls' m = do
  f <- new $ createDocumentFragment
  forM_ (execWriter m) $ \ html -> do
    e <- renderJSM html
    bare $ appendChild e (Cast f)
  return f

createHtmls :: Html -> Expr Tag
createHtmls html = AnonFunc Nothing [] . snd . fst . runM def def $ createHtmls' html >>= retrn

domExpr = createHtmls

-- * Svg

instance  RenderJSM (XML SVG AttributeSet Both) where
  renderJSM xml = case xml of
    Element tn as children -> do
      t <- new $ mkElem tn
      attrsJSM t mkAttr as
      ts :: [Expr Tag] <- mapM renderJSM children
      forM_ ts $ bare . flip appendChild t
      return t
    Text txt -> return $ createTextNode (ulit txt)
    Raw txt -> error "XML SVG AttributeSet Both: Raw not implemented"
    -- ^ fix: see implementation for HTML Both, would that work for svg too?
    Dyn expr -> return (Cast expr)
    Embed a -> renderJSM a
    where
      mkAttr :: Expr a -> TL.Text -> Attribute -> JS.M r ()
      mkAttr e k attr = case attr of
        Data _ v -> e & setAttr ("data-" <> k) v & bare
        OnEvent et expr -> e !. toOn et .= expr -- todo: does this work/fire?
        Custom _ v -> e & setAttr k v & bare
        where
          setAttr :: TL.Text -> TL.Text -> Expr a -> Expr b
          setAttr k v e = call (e !. "setAttributeNS") [Null, ulit k, ulit v]
          -- ^ The regular setAttribute supposedly doesn't work in all browsers.
          -- https://stackoverflow.com/questions/7273500/how-to-create-an-attribute-in-svg-using-javascript

      ns = "http://www.w3.org/2000/svg"

      mkElem :: TagName -> Expr Tag
      mkElem tagName = call (document !. "createElementNS") [ns, valueExpr $ unTagName tagName]

attrsJSM :: Expr Tag -> (Expr Tag -> TL.Text -> Attribute -> JS.M r ()) -> AttributeSet -> JS.M r ()
attrsJSM t mkAttr as = do
  maybe (return ()) (\id -> t !. "id" .= valueExpr (unId id)) (as^.id)
  forM_ (HM.toList $ as^.attrs) $ uncurry $ mkAttr t
  when (Pr.not . null $ cls) $
     t !. "className" .= createClasses cls
  where cls = as^.classes

-- * Helpers

onload = window !. "onload"

putOnload :: Code a -> Code b
putOnload code = [BareExpr $ onload =: func]
  where
    func = AnonFunc Nothing [] code :: Expr b

deleteCookie name = do
  document !. "cookie" .= value
  where value = name .+ "=; expires=Thu, 01 Jan 1970 00:00:01 GMT;"
