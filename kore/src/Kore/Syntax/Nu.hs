{-|
Copyright   : (c) Runtime Verification, 2019
License     : NCSA

-}

module Kore.Syntax.Nu
    ( Nu (..)
    ) where

import Prelude.Kore

import Control.DeepSeq
    ( NFData (..)
    )
import qualified Generics.SOP as SOP
import qualified GHC.Generics as GHC

import Kore.Attribute.Pattern.FreeVariables
import Kore.Attribute.Synthetic
import Kore.Debug
import Kore.Sort
import Kore.Syntax.Variable
import Kore.Unparser
import qualified Pretty

{-|'Nu' corresponds to the @ν@ syntactic category from the
 Syntax of the MμL

The sort of the variable is the same as the sort of the result.

-}
data Nu variable child = Nu
    { nuVariable :: !(SetVariable variable)
    , nuChild    :: child
    }
    deriving (Eq, Functor, Foldable, GHC.Generic, Ord, Show, Traversable)

instance (Hashable variable, Hashable child) => Hashable (Nu variable child)

instance (NFData variable, NFData child) => NFData (Nu variable child)

instance SOP.Generic (Nu variable child)

instance SOP.HasDatatypeInfo (Nu variable child)

instance (Debug variable, Debug child) => Debug (Nu variable child)

instance
    ( Debug variable, Debug child, Diff variable, Diff child )
    => Diff (Nu variable child)

instance
    (Unparse variable, Unparse child) => Unparse (Nu variable child)
  where
    unparse Nu {nuVariable, nuChild } =
        "\\nu"
        <> parameters ([] :: [Sort])
        <> arguments' [unparse nuVariable, unparse nuChild]

    unparse2 Nu {nuVariable, nuChild } =
        Pretty.parens (Pretty.fillSep
            [ "\\nu"
            , unparse2SortedVariable nuVariable
            , unparse2 nuChild
            ])

instance
    Ord variable =>
    Synthetic (FreeVariables variable) (Nu variable)
  where
    synthetic Nu { nuVariable, nuChild } =
        bindVariable (inject nuVariable) nuChild
    {-# INLINE synthetic #-}

instance Synthetic Sort (Nu variable) where
    synthetic Nu { nuVariable, nuChild } =
        nuSort
        & seq (matchSort nuSort nuChild)
      where
        Variable { variableSort = nuSort } = nuVariable
    {-# INLINE synthetic #-}
