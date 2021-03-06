{-|
Copyright   : (c) Runtime Verification, 2019
License     : NCSA
-}

module Kore.Step.Rule.Simplify
    ( SimplifyRuleLHS (..)
    ) where

import Prelude.Kore

import qualified Control.Lens as Lens
import Control.Monad
    ( (>=>)
    )

import qualified Kore.Internal.Condition as Condition
import Kore.Internal.Conditional
    ( Conditional (Conditional)
    )
import Kore.Internal.MultiAnd
    ( MultiAnd
    )
import qualified Kore.Internal.MultiAnd as MultiAnd
    ( make
    )
import qualified Kore.Internal.MultiOr as MultiOr
import qualified Kore.Internal.OrPattern as OrPattern
import Kore.Internal.Pattern
    ( Pattern
    )
import qualified Kore.Internal.Pattern as Pattern
import Kore.Internal.Predicate
    ( makeAndPredicate
    )
import qualified Kore.Internal.Predicate as Predicate
    ( coerceSort
    )
import Kore.Internal.TermLike
    ( termLikeSort
    )
import Kore.Rewriting.RewritingVariable
    ( RewritingVariableName
    )
import Kore.Step.ClaimPattern
    ( AllPathRule (..)
    , ClaimPattern (ClaimPattern)
    , OnePathRule (..)
    , ReachabilityRule (..)
    )
import qualified Kore.Step.ClaimPattern as ClaimPattern
import Kore.Step.RulePattern
    ( RewriteRule (..)
    , RulePattern (RulePattern)
    )
import qualified Kore.Step.RulePattern as OLD
import qualified Kore.Step.RulePattern as RulePattern
    ( RulePattern (..)
    , applySubstitution
    , leftPattern
    )
import qualified Kore.Step.Simplification.Pattern as Pattern
import Kore.Step.Simplification.Simplify
    ( InternalVariable
    , MonadSimplify
    )
import qualified Kore.Step.SMT.Evaluator as SMT.Evaluator
import Kore.Syntax.Variable
    ( VariableName
    )
import Logic
    ( LogicT
    )
import qualified Logic

-- | Simplifies the left-hand-side of a rewrite rule (claim or axiom)
class SimplifyRuleLHS rule where
    simplifyRuleLhs
        :: forall simplifier
        .  MonadSimplify simplifier
        => rule
        -> simplifier (MultiAnd rule)

instance InternalVariable variable => SimplifyRuleLHS (RulePattern variable)
  where
    simplifyRuleLhs rule@(RulePattern _ _ _ _ _) = do
        let lhsWithPredicate = Pattern.fromTermLike left
        simplifiedTerms <-
            Pattern.simplifyTopConfiguration lhsWithPredicate
        fullySimplified <- SMT.Evaluator.filterMultiOr simplifiedTerms
        let rules =
                map (setRuleLeft rule) (MultiOr.extractPatterns fullySimplified)
        return (MultiAnd.make rules)
      where
        RulePattern {left} = rule

        setRuleLeft
            :: RulePattern variable
            -> Pattern variable
            -> RulePattern variable
        setRuleLeft
            rulePattern@RulePattern {requires = requires'}
            Conditional {term, predicate, substitution}
          =
            RulePattern.applySubstitution
                substitution
                rulePattern
                    { RulePattern.left = term
                    , RulePattern.requires =
                        Predicate.coerceSort (termLikeSort term)
                        $ makeAndPredicate predicate requires'
                    }

instance SimplifyRuleLHS ClaimPattern
  where
    simplifyRuleLhs rule@(ClaimPattern _ _ _ _) = do
        simplifiedTerms <-
            Pattern.simplifyTopConfiguration left
        fullySimplified <-
            SMT.Evaluator.filterMultiOr simplifiedTerms
        let rules =
                setRuleLeft rule
                <$> OrPattern.toPatterns fullySimplified
        return (MultiAnd.make rules)
      where
        ClaimPattern { left } = rule

        setRuleLeft
            :: ClaimPattern
            -> Pattern RewritingVariableName
            -> ClaimPattern
        setRuleLeft
            claimPattern@ClaimPattern { left = left' }
            patt@Conditional { substitution }
          =
            ClaimPattern.applySubstitution
                substitution
                claimPattern
                    { ClaimPattern.left =
                        Condition.andCondition
                            patt
                            (Condition.eraseConditionalTerm left')
                    }

instance SimplifyRuleLHS (RewriteRule VariableName) where
    simplifyRuleLhs =
        fmap (fmap RewriteRule) . simplifyRuleLhs . getRewriteRule

instance SimplifyRuleLHS OLD.OnePathRule where
    simplifyRuleLhs =
        fmap (fmap OLD.OnePathRule) . simplifyClaimRuleOLD . OLD.getOnePathRule

instance SimplifyRuleLHS OLD.AllPathRule where
    simplifyRuleLhs =
        fmap (fmap OLD.AllPathRule) . simplifyClaimRuleOLD . OLD.getAllPathRule

instance SimplifyRuleLHS OLD.ReachabilityRule where
    simplifyRuleLhs (OLD.OnePath rule) =
        (fmap . fmap) OLD.OnePath $ simplifyRuleLhs rule
    simplifyRuleLhs (OLD.AllPath rule) =
        (fmap . fmap) OLD.AllPath $ simplifyRuleLhs rule

instance SimplifyRuleLHS OnePathRule where
    simplifyRuleLhs =
        fmap (fmap OnePathRule) . simplifyClaimRule . getOnePathRule

instance SimplifyRuleLHS AllPathRule where
    simplifyRuleLhs =
        fmap (fmap AllPathRule) . simplifyClaimRule . getAllPathRule

instance SimplifyRuleLHS ReachabilityRule where
    simplifyRuleLhs (OnePath rule) =
        (fmap . fmap) OnePath $ simplifyRuleLhs rule
    simplifyRuleLhs (AllPath rule) =
        (fmap . fmap) AllPath $ simplifyRuleLhs rule

simplifyClaimRuleOLD
    :: forall simplifier variable
    .  MonadSimplify simplifier
    => InternalVariable variable
    => RulePattern variable
    -> simplifier (MultiAnd (RulePattern variable))
simplifyClaimRuleOLD =
    fmap MultiAnd.make . Logic.observeAllT . worker
  where
    simplify, filterWithSolver
        :: Pattern variable
        -> LogicT simplifier (Pattern variable)
    simplify =
        (return . Pattern.requireDefined)
        >=> Pattern.simplifyTopConfiguration
        >=> Logic.scatter
        >=> filterWithSolver
    filterWithSolver = SMT.Evaluator.filterBranch

    worker :: RulePattern variable -> LogicT simplifier (RulePattern variable)
    worker rulePattern = do
        let lhs = Lens.view RulePattern.leftPattern rulePattern
        simplified <- simplify lhs
        let substitution = Pattern.substitution simplified
            lhs' = simplified { Pattern.substitution = mempty }
        rulePattern
            & Lens.set RulePattern.leftPattern lhs'
            & RulePattern.applySubstitution substitution
            & return

simplifyClaimRule
    :: forall simplifier
    .  MonadSimplify simplifier
    => ClaimPattern
    -> simplifier (MultiAnd ClaimPattern)
simplifyClaimRule =
    fmap MultiAnd.make . Logic.observeAllT . worker
  where
    simplify, filterWithSolver
        :: Pattern RewritingVariableName
        -> LogicT simplifier (Pattern RewritingVariableName)
    simplify =
        (return . Pattern.requireDefined)
        >=> Pattern.simplifyTopConfiguration
        >=> Logic.scatter
        >=> filterWithSolver
    filterWithSolver = SMT.Evaluator.filterBranch

    worker :: ClaimPattern -> LogicT simplifier ClaimPattern
    worker claimPattern = do
        let lhs = ClaimPattern.left claimPattern
        simplified <- simplify lhs
        let substitution = Pattern.substitution simplified
            lhs' = simplified { Pattern.substitution = mempty }
        claimPattern
            { ClaimPattern.left = lhs'
            }
            & ClaimPattern.applySubstitution substitution
            & return
