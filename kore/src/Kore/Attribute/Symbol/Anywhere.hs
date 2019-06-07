{- |
Copyright   : (c) Runtime Verification, 2018
License     : NCSA

 -}

module Kore.Attribute.Symbol.Anywhere
    ( Anywhere (..)
    , anywhereId, anywhereSymbol, anywhereAttribute
    ) where

import qualified Control.Monad as Monad

import Kore.Attribute.Parser as Parser

-- | @Anywhere@ represents the @anywhere@ attribute for symbols.
newtype Anywhere = Anywhere { isAnywhere :: Bool }
    deriving (Generic, Eq, Ord, Show)

instance Semigroup Anywhere where
    (<>) (Anywhere a) (Anywhere b) = Anywhere (a || b)

instance Monoid Anywhere where
    mempty = Anywhere False

instance Default Anywhere where
    def = mempty

instance NFData Anywhere

-- | Kore identifier representing the @anywhere@ attribute symbol.
anywhereId :: Id
anywhereId = "anywhere"

-- | Kore symbol representing the @anywhere@ attribute.
anywhereSymbol :: SymbolOrAlias
anywhereSymbol =
    SymbolOrAlias
        { symbolOrAliasConstructor = anywhereId
        , symbolOrAliasParams = []
        }

-- | Kore pattern representing the @anywhere@ attribute.
anywhereAttribute :: AttributePattern
anywhereAttribute = attributePattern_ anywhereSymbol

instance ParseAttributes Anywhere where
    parseAttribute = withApplication' parseApplication
      where
        parseApplication params args Anywhere { isAnywhere } = do
            Parser.getZeroParams params
            Parser.getZeroArguments args
            Monad.when isAnywhere failDuplicate'
            return Anywhere { isAnywhere = True }
        withApplication' = Parser.withApplication anywhereId
        failDuplicate' = Parser.failDuplicate anywhereId