module Web
   ( module CSS
   , module Web.CSS
   , module HTML
   , module Web.Browser
   , module Web.Monad
   , module Render
   , module Web
   ) where

import Pr
import qualified Data.Text.Lazy as TL
import CSS hiding (run, (!), M, id)
import Web.CSS (reset)
import HTML hiding (Value, content, font, em, id)
import Web.Browser
import Web.Monad
import Render

-- * Inline styling

styleAttr :: TL.Text -> Attribute
styleAttr = Custom "style"

decls :: Browser -> DeclM a -> Attribute
decls browser = renderDecls browser ^ styleAttr
