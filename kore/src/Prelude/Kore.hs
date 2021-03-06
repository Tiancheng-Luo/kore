{- |
Copyright : (c) 2020 Runtime Verification
License   : NCSA

 -}

module Prelude.Kore
    ( module Prelude
    , module Debug.Trace
    -- * Ord
    , minMax
    -- * Functions
    , (&)
    , on
    -- * Maybe
    , isJust
    , isNothing
    , fromMaybe
    , headMay
    -- * Either
    , either
    , isLeft, isRight
    , partitionEithers
    -- * Filterable
    , Filterable (..)
    -- * Witherable
    , Witherable (..)
    -- * Errors
    , HasCallStack
    , assert
    -- * Applicative and Alternative
    , Applicative (..)
    , Alternative (..)
    , optional
    -- * From
    , module From
    -- * Comonad
    , module Control.Comonad
    , Cofree
    , CofreeF (..)
    -- * Hashable
    , Hashable (..)
    -- * Monad
    , Monad (..)
    , MonadPlus (..)
    , MonadIO (..)
    , MonadTrans (..)
    , unless
    , when
    -- * Typeable
    , Typeable
    -- * Injection
    , module Injection
    -- * Category
    , Category (..)
    , (<<<)
    , (>>>)
    -- * Semigroup
    , Semigroup (..)
    -- * NonEmpty
    , NonEmpty (..)
    ) where

-- TODO (thomas.tuegel): Give an explicit export list so that the generated
-- documentation is complete.

import Control.Applicative
    ( Alternative (..)
    , Applicative (..)
    , optional
    )
import Control.Category
    ( Category (..)
    , (<<<)
    , (>>>)
    )
import Control.Comonad
import Control.Comonad.Trans.Cofree
    ( Cofree
    , CofreeF (..)
    )
import Control.Error
    ( either
    , headMay
    , isLeft
    , isRight
    )
import Control.Exception
    ( assert
    )
import Control.Monad
    ( Monad (..)
    , MonadPlus (..)
    , unless
    , when
    )
import Control.Monad.IO.Class
    ( MonadIO (..)
    )
import Control.Monad.Trans.Class
    ( MonadTrans (..)
    )
import Data.Either
    ( partitionEithers
    )
import Data.Function
    ( on
    , (&)
    )
import Data.Hashable
    ( Hashable (..)
    )
import Data.List.NonEmpty
    ( NonEmpty (..)
    )
import Data.Maybe
    ( fromMaybe
    , isJust
    , isNothing
    )
import Data.Semigroup
    ( Semigroup (..)
    )
import Data.Typeable
    ( Typeable
    )
import Data.Witherable
    ( Filterable (..)
    , Witherable (..)
    )
import Debug.Trace hiding
    ( traceEvent
    , traceEventIO
    )
import GHC.Stack
    ( HasCallStack
    )
import Prelude hiding
    ( Applicative (..)
    , Monad (..)
    , either
    , filter
    , id
    , log
    , (.)
    )

import From
import Injection

{- | Simultaneously compute the (@min@, @max@) of two values.
 -}
minMax :: Ord a => a -> a -> (a, a)
minMax a b
  | a < b     = (a, b)
  | otherwise = (b, a)
