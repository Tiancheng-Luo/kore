{-|
Description : Parsing axiom patterns into rules (and unparsing)
Copyright   : (c) Runtime Verification, 2019
License     : NCSA

-}
module Kore.Step.Rule
    ( AxiomPatternError (..)
    , allPathGlobally
    , axiomPatternToTerm
    , QualifiedAxiomPattern (..)
    , fromSentenceAxiom
    , extractRewriteAxioms
    , extractImplicationClaims
    , mkRewriteAxiom
    , mkEqualityAxiom
    , mkCeilAxiom
    , onePathRuleToTerm
    -- only for testing
    , termToAxiomPattern
    , fromSentence
    , simpleRewriteTermToRule
    , complexRewriteTermToRule
    ) where

import Prelude.Kore

import Control.DeepSeq
    ( NFData
    )
import qualified Data.Bifunctor as Bifunctor
import qualified Data.Functor.Foldable as Recursive
import Data.List.Extra
    ( groupSortOn
    )
import qualified Generics.SOP as SOP
import qualified GHC.Generics as GHC

import qualified Kore.Attribute.Axiom as Attribute
import Kore.Attribute.Axiom.Constructor
    ( isConstructor
    )
import Kore.Attribute.Functional
    ( isDeclaredFunctional
    )
import Kore.Attribute.Subsort
    ( getSubsorts
    )
import Kore.Debug
import Kore.Error
import Kore.IndexedModule.IndexedModule
import Kore.Internal.Alias
    ( Alias (..)
    )
import qualified Kore.Internal.OrPattern as OrPattern
import qualified Kore.Internal.Pattern as Pattern
import qualified Kore.Internal.Predicate as Predicate
import qualified Kore.Internal.Symbol as Internal.Symbol
import Kore.Internal.TermLike
    ( weakAlwaysFinally
    , weakExistsFinally
    )
import qualified Kore.Internal.TermLike as TermLike
import Kore.Internal.Variable
    ( InternalVariable
    , VariableName
    )
import Kore.Rewriting.RewritingVariable
    ( mkRuleVariable
    )
import Kore.Sort
    ( Sort (..)
    , SortVariable (SortVariable)
    )
import qualified Kore.Step.AntiLeft as AntiLeft
    ( parse
    )
import Kore.Step.ClaimPattern
    ( AllPathRule (..)
    , ClaimPattern (ClaimPattern)
    , OnePathRule (..)
    , allPathRuleToTerm
    , onePathRuleToTerm
    )
import qualified Kore.Step.ClaimPattern as ClaimPattern
import Kore.Step.RulePattern
    ( ImplicationRule (..)
    , RewriteRule (..)
    , RulePattern (..)
    , allPathGlobally
    , implicationRuleToTerm
    , injectTermIntoRHS
    , rewriteRuleToTerm
    , termToRHS
    )
import qualified Kore.Step.RulePattern as OLD
import Kore.Step.Simplification.ExpandAlias
    ( substituteInAlias
    )
import qualified Kore.Syntax.Definition as Syntax
import Kore.Syntax.Id
    ( Id (..)
    )
import Kore.Unparser
    ( unparse
    )
import qualified Kore.Verified as Verified
import qualified Pretty

{-| Error encountered when parsing patterns
-}
newtype AxiomPatternError = AxiomPatternError ()
    deriving (GHC.Generic)

instance NFData AxiomPatternError

reachabilityModalityToConstructor
    :: Alias (TermLike.TermLike VariableName)
    -> Maybe (ClaimPattern -> QualifiedAxiomPattern VariableName)
reachabilityModalityToConstructor patternHead
    | headName == weakExistsFinally = Just $ OnePathClaimPatternNEW . OnePathRule
    | headName == weakAlwaysFinally = Just $ AllPathClaimPatternNEW . AllPathRule
    | otherwise = Nothing
  where
    headName = getId (aliasConstructor patternHead)

qualifiedAxiomOpToConstructor
    :: Alias (TermLike.TermLike VariableName)
    -> Maybe (RulePattern VariableName -> QualifiedAxiomPattern VariableName)
qualifiedAxiomOpToConstructor patternHead
    | headName == weakExistsFinally = Just $ OnePathClaimPattern . OLD.OnePathRule
    | headName == weakAlwaysFinally = Just $ AllPathClaimPattern . OLD.AllPathRule
    | otherwise = Nothing
  where
    headName = getId (aliasConstructor patternHead)

{- | Sum type to distinguish rewrite axioms (used for stepping)
from function axioms (used for functional simplification).
--}
data QualifiedAxiomPattern variable
    = RewriteAxiomPattern (RewriteRule variable)
    | OnePathClaimPattern OLD.OnePathRule
    | AllPathClaimPattern OLD.AllPathRule
    | OnePathClaimPatternNEW OnePathRule
    | AllPathClaimPatternNEW AllPathRule
    | ImplicationAxiomPattern (ImplicationRule variable)
    deriving (Eq, GHC.Generic, Ord, Show)
    -- TODO(virgil): Rename the above since it applies to all sorts of axioms,
    -- not only to function-related ones.

instance NFData variable => NFData (QualifiedAxiomPattern variable)

instance SOP.Generic (QualifiedAxiomPattern variable)

instance SOP.HasDatatypeInfo (QualifiedAxiomPattern variable)

instance (Debug variable) => Debug (QualifiedAxiomPattern variable)

instance (Debug variable, Diff variable) => Diff (QualifiedAxiomPattern variable)

-- | Extracts all 'RewriteRule' axioms from a 'VerifiedModule'.
extractRewriteAxioms
    :: VerifiedModule declAtts
    -> [RewriteRule VariableName]
extractRewriteAxioms idxMod =
    extractRewrites
    . groupSortOn (Attribute.getPriorityOfAxiom . fst)
    . filterRewrites
    . fmap
        (Bifunctor.second
            (Recursive.project . stripForall . Syntax.sentenceAxiomPattern)
        )
    $ indexedModuleAxioms idxMod
  where
    extractRewrites [] = []
    extractRewrites (simple:complex) =
        map (uncurry simpleRewriteTermToRule) simple
        ++ map (uncurry complexRewriteTermToRule) (concat complex)

    stripForall (TermLike.Forall_ _ _ child) = stripForall child
    stripForall child = child

    filterRewrites xys =
        [(a,x) | (a, _ TermLike.:< TermLike.RewritesF x) <- xys]

-- | Extract all 'ImplicationRule' claims matching a given @level@ from
-- a verified definition.
extractImplicationClaims
    :: VerifiedModule declAtts
    -- ^'IndexedModule' containing the definition
    ->  [   ( Attribute.Axiom Internal.Symbol.Symbol VariableName
            , ImplicationRule VariableName
            )
        ]
extractImplicationClaims =
    mapMaybe extractImplicationClaimFrom . indexedModuleClaims

extractImplicationClaimFrom
    ::  ( Attribute.Axiom Internal.Symbol.Symbol VariableName
        , Verified.SentenceClaim
        )
    -- ^ Sentence to extract axiom pattern from
    -> Maybe
        ( Attribute.Axiom Internal.Symbol.Symbol VariableName
        , ImplicationRule VariableName
        )
extractImplicationClaimFrom (attrs, sentence) =
    case fromSentenceAxiom (attrs, Syntax.getSentenceClaim sentence) of
        Right (ImplicationAxiomPattern axiomPat) -> Just (attrs, axiomPat)
        _ -> Nothing

-- | Attempts to extract a rule from the 'Verified.Sentence'.
fromSentence
    ::  ( Attribute.Axiom Internal.Symbol.Symbol VariableName
        , Verified.Sentence
        )
    -> Either (Error AxiomPatternError) (QualifiedAxiomPattern VariableName)
fromSentence (attrs, Syntax.SentenceAxiomSentence sentenceAxiom) =
    fromSentenceAxiom (attrs, sentenceAxiom)
fromSentence _ =
    koreFail "Only axiom sentences can be translated to rules"

-- | Attempts to extract a rule from the 'Verified.SentenceAxiom'.
fromSentenceAxiom
    ::  ( Attribute.Axiom Internal.Symbol.Symbol VariableName
        , Verified.SentenceAxiom
        )
    -> Either (Error AxiomPatternError) (QualifiedAxiomPattern VariableName)
fromSentenceAxiom (attributes, sentenceAxiom) =
    termToAxiomPattern attributes (Syntax.sentenceAxiomPattern sentenceAxiom)

simpleRewriteTermToRule
    :: InternalVariable variable
    => Attribute.Axiom Internal.Symbol.Symbol variable
    -> TermLike.Rewrites TermLike.Sort (TermLike.TermLike variable)
    -> RewriteRule variable
simpleRewriteTermToRule attributes pat =
    case pat of
        TermLike.Rewrites sort (TermLike.ApplyAlias_ alias params) rhs ->
            case substituteInAlias alias params of
                TermLike.And_ _ requires lhs ->
                    simpleRewriteTermToRule
                        attributes
                        (TermLike.Rewrites sort (TermLike.mkAnd requires lhs) rhs)
                _ -> (error . show. Pretty.vsep)
                        [ "LHS alias of rule is ill-formed."
                        , Pretty.indent 4 $ unparse pat
                        ]
        -- normal rewrite axioms
        TermLike.Rewrites _ (TermLike.And_ _ requires lhs) rhs ->
                RewriteRule RulePattern
                    { left = lhs
                    , antiLeft = Nothing
                    , requires = Predicate.wrapPredicate requires
                    , rhs = termToRHS rhs
                    , attributes
                    }
        _ -> (error . show. Pretty.vsep)
                    [ "Expected simple rewrite rule form, but got"
                    , Pretty.indent 4 $ unparse pat
                    ]

complexRewriteTermToRule
    :: InternalVariable variable
    => Attribute.Axiom Internal.Symbol.Symbol variable
    -> TermLike.Rewrites TermLike.Sort (TermLike.TermLike variable)
    -> RewriteRule variable
complexRewriteTermToRule attributes pat =
    case pat of
        TermLike.Rewrites sort
            (TermLike.And_ _
                (TermLike.Not_ _ antiLeft)
                (TermLike.ApplyAlias_ alias params)
            )
            rhs ->
                case substituteInAlias alias params of
                    TermLike.And_ _ requires lhs ->
                        complexRewriteTermToRule
                            attributes
                            (TermLike.Rewrites
                                sort
                                (TermLike.mkAnd
                                    (TermLike.mkNot antiLeft)
                                    (TermLike.mkAnd requires lhs)
                                )
                                rhs
                            )
                    _ -> (error . show. Pretty.vsep)
                            [ "LHS alias of rule is ill-formed."
                            , Pretty.indent 4 $ unparse pat
                            ]
        TermLike.Rewrites _
            (TermLike.And_ _
                (TermLike.Not_ _ antiLeft)
                (TermLike.And_ _ requires lhs))
            rhs -> case AntiLeft.parse antiLeft of
                Nothing -> (error . show. Pretty.vsep)
                    [ "Could not parse antileft term"
                    , Pretty.indent 4 $ unparse antiLeft
                    , "from pattern"
                    , Pretty.indent 4 $ unparse pat
                    ]
                Just parsedAntiLeft ->
                    RewriteRule RulePattern
                        { left = lhs
                        , antiLeft = Just parsedAntiLeft
                        , requires = makePredicate "requires" requires
                        , rhs = termToRHS rhs
                        , attributes
                        }
        _ -> (error . show. Pretty.vsep)
            [ "Expected complex rewrite rule form, but got"
            , Pretty.indent 4 $ unparse pat
            ]
  where
    makePredicate
        :: InternalVariable variable
        => String -> TermLike.TermLike variable -> Predicate.Predicate variable
    makePredicate name term = case Predicate.makePredicate term of
        Left err ->
            (error . show . Pretty.vsep)
                [ Pretty.sep ["Error for ", Pretty.pretty name]
                , unparse term
                , Pretty.pretty err
                ]
        Right predicate -> predicate

{- | Match a term encoding an 'QualifiedAxiomPattern'.

@patternToAxiomPattern@ returns an error if the given 'TermLike' does
not encode a normal rewrite or function axiom.
-}
termToAxiomPattern
    :: Attribute.Axiom Internal.Symbol.Symbol VariableName
    -> TermLike.TermLike VariableName
    -> Either (Error AxiomPatternError) (QualifiedAxiomPattern VariableName)
termToAxiomPattern attributes pat =
    case pat of
        -- OLD: Reachability claims
        TermLike.Implies_ _
            (TermLike.And_ _ requires lhs)
            (TermLike.ApplyAlias_ op [rhs])
          | Just constructor <- qualifiedAxiomOpToConstructor op ->
            pure $ constructor RulePattern
                { left = lhs
                , antiLeft = Nothing
                , requires = Predicate.wrapPredicate requires
                , rhs = termToRHS rhs
                , attributes
                }
        -- NEW: Reachability claims
        TermLike.Implies_ _
            (TermLike.And_ _ requires lhs)
            (TermLike.ApplyAlias_ op [rhs])
          | Just constructor <- reachabilityModalityToConstructor op ->
            let rhs' = TermLike.mapVariables (pure mkRuleVariable) rhs
                attributes' = Attribute.mapAxiomVariables (pure mkRuleVariable) attributes
             in pure $ constructor ClaimPattern
                { ClaimPattern.left =
                    Pattern.fromTermAndPredicate
                        lhs
                        (Predicate.wrapPredicate requires)
                    & Pattern.mapVariables (pure mkRuleVariable)
                , ClaimPattern.right = OrPattern.parseFromTermLike rhs'
                , ClaimPattern.existentials = ClaimPattern.termToExistentials rhs'
                , ClaimPattern.attributes = attributes'
                }
        TermLike.Forall_ _ _ child -> termToAxiomPattern attributes child
        -- implication axioms:
        -- init -> modal_op ( prop )
        TermLike.Implies_ _ lhs rhs@(TermLike.ApplyAlias_ op _)
            | isModalSymbol op ->
                pure $ ImplicationAxiomPattern $ ImplicationRule RulePattern
                    { left = lhs
                    , antiLeft = Nothing
                    , requires = Predicate.makeTruePredicate_
                    , rhs = injectTermIntoRHS rhs
                    , attributes
                    }
        (TermLike.Rewrites_ _ _ _) ->
            koreFail "Rewrite patterns should not be parsed through this"
        _
            | (isDeclaredFunctional . Attribute.functional $ attributes)
            || (isConstructor . Attribute.constructor $ attributes)
            || (not . null . getSubsorts . Attribute.subsorts $ attributes)
            -> koreFail "Patterns of this type do not represent rules"
            | otherwise -> (error . show. Pretty.vsep)
                    [ "Unsupported pattern type in axiom"
                    , Pretty.indent 4 $ unparse pat
                    ]
      where
        isModalSymbol symbol
            | headName == allPathGlobally = True
            | otherwise = False
          where
            headName = getId (aliasConstructor symbol)

{-| Reverses an 'QualifiedAxiomPattern' back into its 'Pattern' representation.
  Should be the inverse of 'termToAxiomPattern'.
-}

axiomPatternToTerm
    :: QualifiedAxiomPattern VariableName
    -> TermLike.TermLike VariableName
axiomPatternToTerm = \case
    RewriteAxiomPattern rule -> rewriteRuleToTerm rule
    OnePathClaimPattern rule -> OLD.onePathRuleToTerm rule
    AllPathClaimPattern rule -> OLD.allPathRuleToTerm rule
    OnePathClaimPatternNEW rule -> onePathRuleToTerm rule
    AllPathClaimPatternNEW rule -> allPathRuleToTerm rule
    ImplicationAxiomPattern rule -> implicationRuleToTerm rule

-- TODO(Ana): are these three functions used anywhere anymore?
{- | Construct a 'VerifiedKoreSentence' corresponding to 'RewriteRule'.

The requires clause must be a predicate, i.e. it can occur in any sort.

 -}
mkRewriteAxiom
    :: TermLike.TermLike VariableName  -- ^ left-hand side
    -> TermLike.TermLike VariableName  -- ^ right-hand side
    -> Maybe (Sort -> TermLike.TermLike VariableName)  -- ^ requires clause
    -> Verified.Sentence
mkRewriteAxiom lhs rhs requires =
    (Syntax.SentenceAxiomSentence . TermLike.mkAxiom_)
        (TermLike.mkRewrites
            (TermLike.mkAnd (fromMaybe TermLike.mkTop requires patternSort) lhs)
            (TermLike.mkAnd (TermLike.mkTop patternSort) rhs)
        )
  where
    patternSort = TermLike.termLikeSort lhs

{- | Construct a 'VerifiedKoreSentence' corresponding to 'EqualityRule'.

The requires clause must be a predicate, i.e. it can occur in any sort.

 -}
mkEqualityAxiom
    :: TermLike.TermLike VariableName  -- ^ left-hand side
    -> TermLike.TermLike VariableName  -- ^ right-hand side
    -> Maybe (Sort -> TermLike.TermLike VariableName)  -- ^ requires clause
    -> Verified.Sentence
mkEqualityAxiom lhs rhs requires =
    Syntax.SentenceAxiomSentence
    $ TermLike.mkAxiom [sortVariableR]
    $ case requires of
        Just requires' ->
            TermLike.mkImplies
                (requires' sortR)
                (TermLike.mkAnd function TermLike.mkTop_)
        Nothing -> function
  where
    sortVariableR = SortVariable "R"
    sortR = SortVariableSort sortVariableR
    function = TermLike.mkEquals sortR lhs rhs

{- | Construct a 'VerifiedKoreSentence' corresponding to a 'Ceil' axiom.

 -}
mkCeilAxiom
    :: TermLike.TermLike VariableName  -- ^ the child of 'Ceil'
    -> Verified.Sentence
mkCeilAxiom child =
    Syntax.SentenceAxiomSentence
    $ TermLike.mkAxiom [sortVariableR]
    $ TermLike.mkCeil sortR child
  where
    sortVariableR = SortVariable "R"
    sortR = SortVariableSort sortVariableR
