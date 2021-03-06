module Test.Kore.Step.Simplification.Application
    ( test_applicationSimplification
    ) where

import Prelude.Kore

import Test.Tasty

import qualified Control.Lens as Lens
import Data.Generics.Product
    ( field
    )
import qualified Data.List as List
import qualified Data.Map.Strict as Map

import Data.Sup
import Kore.Internal.OrPattern
    ( OrPattern
    )
import qualified Kore.Internal.OrPattern as OrPattern
import Kore.Internal.Pattern as Pattern
import Kore.Internal.Predicate
    ( makeAndPredicate
    , makeEqualsPredicate
    , makeEqualsPredicate_
    , makeTruePredicate
    , makeTruePredicate_
    )
import qualified Kore.Internal.SideCondition as SideCondition
    ( top
    )
import qualified Kore.Internal.Substitution as Substitution
import Kore.Internal.TermLike as TermLike
import Kore.Step.Axiom.EvaluationStrategy
    ( firstFullEvaluation
    )
import qualified Kore.Step.Axiom.Identifier as AxiomIdentifier
    ( AxiomIdentifier (..)
    )
import Kore.Step.Simplification.Application
import Kore.Step.Simplification.Simplify
import qualified Kore.Step.Simplification.Simplify as AttemptedAxiom
    ( AttemptedAxiom (..)
    )

import qualified Test.Kore.Step.MockSymbols as Mock
import Test.Kore.Step.Simplification
import Test.Tasty.HUnit.Ext

test_applicationSimplification :: [TestTree]
test_applicationSimplification =
    [ testCase "Application - or distribution" $ do
        -- sigma(a or b, c or d) =
        --     sigma(b, d) or sigma(b, c) or sigma(a, d) or sigma(a, c)
        let expect =
                OrPattern.fromPatterns
                    [ Conditional
                        { term = Mock.sigma Mock.a Mock.c
                        , predicate = makeTruePredicate Mock.testSort
                        , substitution = mempty
                        }
                    , Conditional
                        { term = Mock.sigma Mock.a Mock.d
                        , predicate = makeTruePredicate Mock.testSort
                        , substitution = mempty
                        }
                    , Conditional
                        { term = Mock.sigma Mock.b Mock.c
                        , predicate = makeTruePredicate Mock.testSort
                        , substitution = mempty
                        }
                    ,  Conditional
                        { term = Mock.sigma Mock.b Mock.d
                        , predicate = makeTruePredicate Mock.testSort
                        , substitution = mempty
                        }
                    ]
        actual <-
            evaluate
                Map.empty
                (makeApplication
                    Mock.sigmaSymbol
                    [ [aExpanded, bExpanded]
                    , [cExpanded, dExpanded]
                    ]
                )
        assertEqual "" expect actual

    , testCase "Application - bottom child makes everything bottom" $ do
        -- sigma(a or b, bottom) = bottom
        let expect = OrPattern.fromPatterns [ Pattern.bottom ]
        actual <-
            evaluate
                Map.empty
                (makeApplication
                    Mock.sigmaSymbol
                    [ [aExpanded, bExpanded]
                    , []
                    ]
                )
        assertEqual "" expect actual

    , testCase "Application - preserves sort for top child" $ do
        -- sigma(a, top) = top
        let expect = OrPattern.fromPatterns
                [ Pattern.fromTermLike (Mock.sigma Mock.a (mkTop Mock.testSort))
                ]
        actual <-
            evaluate
                Map.empty
                (makeApplication
                    Mock.sigmaSymbol
                    [ [aExpanded]
                    , [Pattern.top]
                    ]
                )
        assertEqual "" expect actual

    , testCase "Applies functions" $ do
        -- f(a) evaluated to g(a).
        let expect = OrPattern.fromPatterns [ gOfAExpanded ]
        actual <-
            evaluate
                (Map.singleton
                    (AxiomIdentifier.Application Mock.fId)
                    (simplificationEvaluator
                        [ BuiltinAndAxiomSimplifier $ \_ _ ->
                            return $ AttemptedAxiom.Applied
                                AttemptedAxiomResults
                                    { results =
                                        OrPattern.fromPattern gOfAExpanded
                                    , remainders = OrPattern.bottom
                                    }
                        ]
                    )
                )
                (makeApplication Mock.fSymbol [[aExpanded]])
        assertEqual "" expect actual

    , testGroup "Combines child predicates and substitutions"
        [ testCase "When not applying functions" $ do
            -- sigma(a and f(a)=f(b) and [x=f(a)], b and g(a)=g(b) and [y=g(a)])
            --    = sigma(a, b)
            --        and (f(a)=f(b) and g(a)=g(b))
            --        and [x=f(a), y=g(a)]
            let expect =
                    OrPattern.fromPatterns
                        [ Conditional
                            { term = Mock.sigma Mock.a Mock.b
                            , predicate =
                                makeAndPredicate
                                    (makeEqualsPredicate Mock.testSort
                                        fOfA
                                        fOfB
                                    )
                                    (makeEqualsPredicate_ gOfA gOfB)
                            , substitution = Substitution.unsafeWrap
                                [ (inject Mock.x, fOfA)
                                , (inject Mock.y, gOfA)
                                ]
                            }
                        ]
            actual <-
                evaluate
                    Map.empty
                    (makeApplication
                        Mock.sigmaSymbol
                        [   [ Conditional
                                { term = Mock.a
                                , predicate = makeEqualsPredicate_ fOfA fOfB
                                , substitution =
                                    Substitution.wrap
                                    $ Substitution.mkUnwrappedSubstitution
                                    [ (inject Mock.x, fOfA) ]
                                }
                            ]
                        ,   [ Conditional
                                { term = Mock.b
                                , predicate = makeEqualsPredicate_ gOfA gOfB
                                , substitution =
                                    Substitution.wrap
                                    $ Substitution.mkUnwrappedSubstitution
                                    [ (inject Mock.y, gOfA) ]
                                }
                            ]
                        ]
                    )
            assertEqual "" expect actual

        , testCase "When applying functions" $ do
            -- sigma(a and f(a)=f(b) and [x=f(a)], b and g(a)=g(b) and [y=g(a)])
            --    =
            --        f(a) and
            --        (f(a)=f(b) and g(a)=g(b) and f(a)=g(a)) and
            --        [x=f(a), y=g(a), z=f(b)]
            -- if sigma(a, b) => f(a) and f(a)=g(a) and [z=f(b)]
            let z' =
                    Lens.set
                        ( field @"variableName"
                        . Lens.mapped
                        . field @"counter"
                        )
                        (Just (Element 1))
                        Mock.z
                expect =
                    OrPattern.fromPatterns
                        [ Conditional
                            { term = fOfA
                            , predicate =
                                makeAndPredicate
                                    (makeAndPredicate
                                        (makeEqualsPredicate Mock.testSort
                                            fOfA
                                            fOfB
                                        )
                                        (makeEqualsPredicate_ fOfA gOfA)
                                    )
                                    (makeEqualsPredicate_ gOfA gOfB)
                            , substitution =
                                Substitution.unsafeWrap $ List.sortOn fst
                                    [ (inject z', gOfB)
                                    , (inject Mock.x, fOfA)
                                    , (inject Mock.y, gOfA)
                                    ]
                            }
                        ]
            actual <-
                let
                    result
                        :: forall variable
                        .  InternalVariable variable
                        => AttemptedAxiom variable
                    result = AttemptedAxiom.Applied AttemptedAxiomResults
                        { results = OrPattern.fromPatterns
                            [ Conditional
                                { term = fOfA
                                , predicate = makeEqualsPredicate_ fOfA gOfA
                                , substitution =
                                    Substitution.wrap
                                    $ Substitution.mkUnwrappedSubstitution
                                    [ (inject zvar, gOfB) ]
                                }
                            ]
                        , remainders = OrPattern.fromPatterns []
                        }
                      where
                        zvar :: ElementVariable variable
                        zvar = fmap from <$> z'
                in
                    evaluate
                        (Map.singleton
                            (AxiomIdentifier.Application Mock.sigmaId)
                            (simplificationEvaluator
                                [ BuiltinAndAxiomSimplifier $ \_ _ ->
                                    return result
                                ]
                            )
                        )
                    (makeApplication
                        Mock.sigmaSymbol
                        [   [ Conditional
                                { term = Mock.a
                                , predicate = makeEqualsPredicate_ fOfA fOfB
                                , substitution =
                                    Substitution.wrap
                                    $ Substitution.mkUnwrappedSubstitution
                                    [ (inject Mock.x, fOfA) ]
                                }
                            ]
                        ,   [ Conditional
                                { term = Mock.b
                                , predicate = makeEqualsPredicate_ gOfA gOfB
                                , substitution =
                                    Substitution.wrap
                                    $ Substitution.mkUnwrappedSubstitution
                                    [ (inject Mock.y, gOfA) ]
                                }
                            ]
                        ]
                    )
            assertEqual "" expect actual
        ]
    ]
  where
    fOfA, fOfB, gOfA, gOfB :: InternalVariable variable => TermLike variable
    fOfA = Mock.f Mock.a
    fOfB = Mock.f Mock.b
    gOfA = Mock.g Mock.a
    gOfB = Mock.g Mock.b

    aExpanded = Conditional
        { term = Mock.a
        , predicate = makeTruePredicate_
        , substitution = mempty
        }
    bExpanded = Conditional
        { term = Mock.b
        , predicate = makeTruePredicate_
        , substitution = mempty
        }
    cExpanded = Conditional
        { term = Mock.c
        , predicate = makeTruePredicate_
        , substitution = mempty
        }
    dExpanded = Conditional
        { term = Mock.d
        , predicate = makeTruePredicate_
        , substitution = mempty
        }

    gOfAExpanded :: InternalVariable variable => Pattern variable
    gOfAExpanded = Conditional
        { term = gOfA
        , predicate = makeTruePredicate Mock.testSort
        , substitution = mempty
        }

simplificationEvaluator
    :: [BuiltinAndAxiomSimplifier]
    -> BuiltinAndAxiomSimplifier
simplificationEvaluator = firstFullEvaluation

makeApplication
    :: InternalVariable variable
    => Symbol
    -> [[Pattern variable]]
    -> Application Symbol (OrPattern variable)
makeApplication symbol patterns =
    Application
        { applicationSymbolOrAlias = symbol
        , applicationChildren = map OrPattern.fromPatterns patterns
        }

evaluate
    :: BuiltinAndAxiomSimplifierMap
    -- ^ Map from axiom IDs to axiom evaluators
    -> Application Symbol (OrPattern VariableName)
    -> IO (OrPattern VariableName)
evaluate simplifierAxioms = runSimplifier mockEnv . simplify SideCondition.top
  where
    mockEnv = Mock.env { simplifierAxioms }
