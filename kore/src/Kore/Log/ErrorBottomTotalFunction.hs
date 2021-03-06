{- |
Copyright   : (c) Runtime Verification, 2020
License     : NCSA

-}

module Kore.Log.ErrorBottomTotalFunction
    ( ErrorBottomTotalFunction (..)
    , errorBottomTotalFunction
    ) where

import Prelude.Kore

import qualified Generics.SOP as SOP
import qualified GHC.Generics as GHC

import Kore.Internal.TermLike
import Kore.Unparser
    ( unparse
    )
import Pretty
    ( Pretty
    )
import qualified Pretty

import Log
import qualified SQL

newtype ErrorBottomTotalFunction =
    ErrorBottomTotalFunction
        { term :: TermLike VariableName
        }
    deriving (Show)
    deriving (GHC.Generic)

instance SOP.Generic ErrorBottomTotalFunction

instance SOP.HasDatatypeInfo ErrorBottomTotalFunction

instance Pretty ErrorBottomTotalFunction where
    pretty ErrorBottomTotalFunction { term } =
        Pretty.vsep
            [ "Evaluating total function"
            , Pretty.indent 4 (unparse term)
            , "has resulted in \\bottom."
            ]

instance Entry ErrorBottomTotalFunction where
    entrySeverity _ = Error
    helpDoc _ = "errors raised when a total function is undefined"

instance SQL.Table ErrorBottomTotalFunction

errorBottomTotalFunction
    :: MonadLog logger
    => InternalVariable variable
    => TermLike variable
    -> logger ()
errorBottomTotalFunction (mapVariables (pure toVariableName) -> term) =
    logEntry ErrorBottomTotalFunction { term }
