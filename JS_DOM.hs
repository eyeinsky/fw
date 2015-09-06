module JS_DOM where

import Prelude2 hiding ((.=))
import Text.Exts
import qualified Data.Text.Lazy as TL
import qualified Data.Text as T
import qualified Data.HashMap.Strict as HM

import JS_Syntax as JS
import JS_Monad
import qualified JS_Types as JT
import JS_Ops_Untyped
import Web_CSS as CSS
import Web_HTML


-- * Objects

window :: Expr Window
window = ex "window"

document :: Expr Document
document = ex "document"

location :: Expr Location
location = window !. "location"

onloadIs :: Code () -> M r ()
onloadIs code = onload .= FuncDef [] code -- :: Code' -> Statement ()

-- onload :: Expr
onload = ex "window" !. "onload"


on :: (Event event, ToOn event)
   => Expr Tag                       -- When this element
   -> event                          --   .. has this event
   -> Expr (Expr event, Proxy ()) --   .. then do this.
   -> M r ()
on el eventType fident = do
   (el !. Name (toOn eventType)) .= fident

on' el eventType fexpr = do
   fdef <- func fexpr -- (no inermediate variable)
   on el eventType fdef
   -- (el !. Name (toOn eventType)) .= fdef

-- * Finding elements

-- | The global find
class    FindBy a where findBy :: a -> JS.Expr Tag
instance FindBy CSS.Id where
   findBy (CSS.Id t) = docCall "getElementById" t
instance FindBy CSS.Class where
   findBy (CSS.Class a) = docCall "getElementsByClassName" a
instance FindBy CSS.TagName where
   findBy (CSS.TagName a) = docCall "getElementsByTagName" a
instance FindBy (Expr CSS.Id) where
   findBy a = docCall' "getElementById" a
instance FindBy (Expr CSS.Class) where
   findBy a = docCall' "getElementsByClassName" a

docCall' f a = call1 (document !. f) a
docCall f a = docCall' f (ulit a)

-- |
findUnder :: FindBy a => Expr Tag -> a -> Expr Tag
findUnder e a = u



-- * Modify DOM

appendChild :: Expr Tag -> Expr Tag -> Expr ()
appendChild t a = call1 (t !. "appendChild") a -- :: Expr a

remove :: Expr Tag -> M r ()
remove e = bare $ call0 (e !. "remove")

setInnerHTML e x = e !. "innerHTML" .= x

createElement :: TagName -> JS.Expr Tag
createElement tn = docCall "createElement" $ unTagName tn

-- creates the expr to create the tree, returns top
createHtml :: HTML -> JS.Expr Tag
createHtml tr = FuncDef [] . eval $ case tr of
   TagNode tn mid cls attrs children -> do
      t <- new $ createElement tn
      maybe (return ()) (\id -> t !. "id" .= lit (unId id)) mid
      forM_ (HM.toList attrs) $ \ (k,v) -> t !. Name (TL.toStrict k) .= ulit v
      when (not . null $ cls) $
         t !. "className" .= lit (TL.unwords $ map unClass cls)
      mapM_ (bare . appendChild t . call0 . createHtml) children
      retrn t
   TextNode txt -> retrn $ docCall "createTextNode" txt


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
addClass cls el = bare $ call1 (el !. "classList" !. "add"   ) cls
remClass cls el = bare $ call1 (el !. "classList" !. "remove") cls
