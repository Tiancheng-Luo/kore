{- |
Copyright   : (c) Runtime Verification, 2020
License     : NCSA

-}

module Kore.Log.WarnTrivialClaim
    ( WarnTrivialClaim (..)
    , warnProvenClaimZeroDepth
    , warnTrivialClaimRemoved
    ) where

import Prelude.Kore

import Kore.Attribute.SourceLocation
import Kore.Log.InfoProofDepth
import Kore.Step.RulePattern
import Log
import Pretty
    ( Pretty
    )
import qualified Pretty

data WarnTrivialClaim
    = WarnProvenClaimZeroDepth ReachabilityRule
    -- ^ Warning when a claim is proved without rewriting.
    | WarnTrivialClaimRemoved ReachabilityRule
    -- ^ Warning when a claim is proved during initialization.
    deriving Show

instance Pretty WarnTrivialClaim where
    pretty (WarnProvenClaimZeroDepth rule) =
        Pretty.hsep
            [ "Claim proven without rewriting at:"
            , Pretty.pretty (from rule :: SourceLocation)
            ]
    pretty (WarnTrivialClaimRemoved rule) =
        Pretty.vsep
            [ Pretty.hsep
                [ "Claim proven during initialization:"
                , Pretty.pretty (from rule :: SourceLocation)
                ]
            , "The left-hand side of the claim may be undefined."
            ]


instance Entry WarnTrivialClaim where
    entrySeverity _ = Warning
    helpDoc _ = "warn when a claim is proven without taking any steps"

warnProvenClaimZeroDepth
    :: MonadLog log
    => ProofDepth
    -> ReachabilityRule
    -> log ()
warnProvenClaimZeroDepth (ProofDepth depth) rule =
    when (depth == 0) $ logEntry (WarnProvenClaimZeroDepth rule)

warnTrivialClaimRemoved
    :: MonadLog log
    => ReachabilityRule
    -> log ()
warnTrivialClaimRemoved rule =
    logEntry (WarnTrivialClaimRemoved rule)
