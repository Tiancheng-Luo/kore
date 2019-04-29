{- |
Copyright   : (c) Runtime Verification, 2018
License     : NCSA

-}
module Kore.Step.Merging.Pattern
    ( mergeWithPredicateAssumesEvaluated
    , mergeWithPredicate
    ) where

import Data.Reflection

import           Kore.AST.Common
                 ( SortedVariable )
import           Kore.AST.MetaOrObject
import           Kore.Attribute.Symbol
                 ( StepperAttributes )
import           Kore.IndexedModule.MetadataTools
                 ( SmtMetadataTools )
import           Kore.Step.Axiom.Data
                 ( BuiltinAndAxiomSimplifierMap )
import qualified Kore.Step.Condition.Evaluator as Predicate
                 ( evaluate )
import           Kore.Step.Pattern
                 ( Conditional (..), Pattern, Predicate )
import           Kore.Step.Simplification.Data
                 ( PredicateSimplifier,
                 SimplificationProof (SimplificationProof), Simplifier,
                 TermLikeSimplifier )
import           Kore.Step.Substitution
                 ( PredicateMerger (PredicateMerger),
                 mergePredicatesAndSubstitutions )
import           Kore.Unparser
import           Kore.Variables.Fresh

{-| 'mergeWithPredicate' ands the given predicate-substitution
with the given pattern.
-}
mergeWithPredicate
    ::  ( MetaOrObject level
        , Ord (variable level)
        , Show (variable level)
        , Unparse (variable level)
        , OrdMetaOrObject variable
        , ShowMetaOrObject variable
        , FreshVariable variable
        , SortedVariable variable
        , Given (SmtMetadataTools StepperAttributes)
        )
    => SmtMetadataTools StepperAttributes
    -- ^ Tools for finding additional information about patterns
    -- such as their sorts, whether they are constructors or hooked.
    -> PredicateSimplifier level
    -> TermLikeSimplifier level
    -- ^ Evaluates functions in a pattern.
    -> BuiltinAndAxiomSimplifierMap level
    -- ^ Map from axiom IDs to axiom evaluators
    -> Predicate level variable
    -- ^ Condition and substitution to add.
    -> Pattern level variable
    -- ^ pattern to which the above should be added.
    -> Simplifier (Pattern level variable, SimplificationProof level)
mergeWithPredicate
    tools
    substitutionSimplifier
    simplifier
    axiomIdToSimplifier
    Conditional
        { predicate = conditionToMerge
        , substitution = substitutionToMerge
        }
    patt@Conditional
        { predicate = pattPredicate
        , substitution = pattSubstitution
        }
  = do
    (   Conditional
            { predicate = mergedCondition
            , substitution = mergedSubstitution
            }
        , _proof ) <-
            mergePredicatesAndSubstitutions
                tools
                substitutionSimplifier
                simplifier
                axiomIdToSimplifier
                [pattPredicate, conditionToMerge]
                [pattSubstitution, substitutionToMerge]
    (evaluatedCondition, _) <-
        Predicate.evaluate
            substitutionSimplifier simplifier mergedCondition
    mergeWithEvaluatedCondition
        tools
        substitutionSimplifier
        simplifier
        axiomIdToSimplifier
        patt {substitution = mergedSubstitution}
        evaluatedCondition

mergeWithEvaluatedCondition
    ::  ( MetaOrObject level
        , Ord (variable level)
        , Show (variable level)
        , Unparse (variable level)
        , OrdMetaOrObject variable
        , ShowMetaOrObject variable
        , FreshVariable variable
        , SortedVariable variable
        )
    => SmtMetadataTools StepperAttributes
    -> PredicateSimplifier level
    -> TermLikeSimplifier level
    -- ^ Evaluates functions.
    -> BuiltinAndAxiomSimplifierMap level
    -- ^ Map from axiom IDs to axiom evaluators
    -> Pattern level variable
    -> Predicate level variable
    -> Simplifier (Pattern level variable, SimplificationProof level)
mergeWithEvaluatedCondition
    tools
    substitutionSimplifier
    simplifier
    axiomIdToSimplifier
    Conditional
        { term = pattTerm
        , substitution = pattSubstitution
        }  -- The predicate was already included in the Predicate
    Conditional
        { predicate = predPredicate, substitution = predSubstitution }
  = do
    (   Conditional
            { predicate = mergedPredicate
            , substitution = mergedSubstitution
            }
        , _proof
        ) <- mergePredicatesAndSubstitutions
            tools
            substitutionSimplifier
            simplifier
            axiomIdToSimplifier
            [predPredicate]
            [pattSubstitution, predSubstitution]
    return
        ( Conditional
            { term = pattTerm
            , predicate = mergedPredicate
            , substitution = mergedSubstitution
            }
        , SimplificationProof
        )

{-| Ands the given predicate/substitution with the given pattern.

Assumes that the initial patterns are simplified, so it does not attempt
to re-simplify them.
-}
mergeWithPredicateAssumesEvaluated
    ::  ( FreshVariable variable
        , MetaOrObject level
        , Monad m
        , Ord (variable level)
        , OrdMetaOrObject variable
        , Show (variable level)
        , ShowMetaOrObject variable
        , SortedVariable variable
        , Unparse (variable level)
        )
    => PredicateMerger level variable m
    -> Predicate level variable
    -> Conditional level variable term
    -> m (Conditional level variable term, SimplificationProof level)
mergeWithPredicateAssumesEvaluated
    (PredicateMerger substitutionMerger)
    Conditional
        { term = ()
        , predicate = predPredicate
        , substitution = predSubstitution
        }
    Conditional
        { term = pattTerm
        , predicate = pattPredicate
        , substitution = pattSubstitution
        }  -- The predicate was already included in the Predicate
  = do
    Conditional
        { term = ()
        , predicate = mergedPredicate
        , substitution = mergedSubstitution
        } <-
            substitutionMerger
                [pattPredicate, predPredicate]
                [pattSubstitution, predSubstitution]
    return
        ( Conditional
            { term = pattTerm
            , predicate = mergedPredicate
            , substitution = mergedSubstitution
            }
        , SimplificationProof
        )