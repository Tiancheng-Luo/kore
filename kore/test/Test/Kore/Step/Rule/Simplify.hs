module Test.Kore.Step.Rule.Simplify
    ( test_simplifyRule_RewriteRule
    , test_simplifyRule_OnePathRule
    , test_simplifyRule_OnePathRuleOLD
    , test_simplifyClaimRuleOLD
    , test_simplifyClaimRule
    ) where

import Prelude.Kore

import Test.Tasty

import qualified Control.Lens as Lens
import Control.Monad.Morph
    ( MFunctor (..)
    )
import Control.Monad.Reader
    ( MonadReader
    , ReaderT
    , runReaderT
    )
import qualified Control.Monad.Reader as Reader
import qualified Data.Bifunctor as Bifunctor
import qualified Data.Foldable as Foldable
import Data.Generics.Product
    ( field
    )

import Kore.Internal.Condition
    ( Condition
    )
import qualified Kore.Internal.Condition as Condition
import qualified Kore.Internal.MultiAnd as MultiAnd
    ( extractPatterns
    )
import qualified Kore.Internal.OrPattern as OrPattern
import qualified Kore.Internal.Pattern as Pattern
import Kore.Internal.Predicate
    ( Predicate
    , makeAndPredicate
    , makeCeilPredicate
    , makeEqualsPredicate
    , makeNotPredicate
    , makeTruePredicate
    )
import qualified Kore.Internal.Predicate as Predicate
import qualified Kore.Internal.SideCondition as SideCondition
import Kore.Internal.TermLike
    ( AdjSomeVariableName
    , InternalVariable
    , TermLike
    , mkAnd
    , mkElemVar
    , mkEquals
    , mkOr
    , termLikeSort
    )
import qualified Kore.Internal.TermLike as TermLike
import Kore.Rewriting.RewritingVariable
    ( RewritingVariableName
    , getRewritingVariable
    )
import Kore.Sort
    ( predicateSort
    )
import Kore.Step.ClaimPattern
    ( ClaimPattern
    , OnePathRule (..)
    , claimPattern
    )
import Kore.Step.Rule.Simplify
import Kore.Step.RulePattern
    ( RewriteRule
    , RulePattern
    , rulePattern
    )
import qualified Kore.Step.RulePattern as OLD
import Kore.Step.Simplification.Data
    ( Env (..)
    , runSimplifier
    )
import Kore.Step.Simplification.Simplify
    ( MonadLog
    , MonadSMT
    , MonadSimplify (..)
    , emptyConditionSimplifier
    )
import qualified Kore.Step.SMT.Declaration.All as SMT.All
import Kore.Syntax.Variable
    ( VariableName
    , fromVariableName
    )

import qualified Test.Kore.Step.MockSymbols as Mock
import Test.Kore.Step.Rule.Common
    ( Pair (..)
    , RuleBase
    )
import qualified Test.Kore.Step.Rule.Common as Common
import Test.SMT
    ( runNoSMT
    )
import Test.Tasty.HUnit.Ext

test_simplifyRule_RewriteRule :: [TestTree]
test_simplifyRule_RewriteRule =
    [ testCase "No simplification needed" $ do
        let rule = Mock.a `rewritesToWithSortRewriteRule` Mock.cf
            expected = [rule]

        actual <- runSimplifyRule rule

        assertEqual "" expected actual

    , testCase "Simplify lhs term" $ do
        let expected = [Mock.a `rewritesToWithSortRewriteRule` Mock.cf]

        actual <- runSimplifyRule
            (   mkAnd Mock.a (mkEquals Mock.testSort Mock.a Mock.a)
                `rewritesToWithSortRewriteRule`
                Mock.cf
            )

        assertEqual "" expected actual

    , testCase "Does not simplify rhs term" $ do
        let rule =
                Mock.a
                `rewritesToWithSortRewriteRule`
                mkAnd Mock.cf (mkEquals Mock.testSort Mock.a Mock.a)
            expected = [rule]

        actual <- runSimplifyRule rule

        assertEqual "" expected actual

    , testCase "Substitution in lhs term" $ do
        let expected = [Mock.a `rewritesToWithSortRewriteRule` Mock.f Mock.b]

        actual <- runSimplifyRule
            (   mkAnd Mock.a (mkEquals Mock.testSort Mock.b x)
                `rewritesToWithSortRewriteRule` Mock.f x
            )

        assertEqual "" expected actual

    , testCase "Does not simplify ensures predicate" $ do
        let rule =
                Pair (Mock.a,  makeTruePredicate Mock.testSort)
                `rewritesToWithSortRewriteRule`
                Pair (Mock.cf, makeEqualsPredicate Mock.testSort Mock.b Mock.b)
            expected = [rule]

        actual <- runSimplifyRule rule

        assertEqual "" expected actual

    , testCase "Splits rule" $ do
        let expected =
                [ Mock.a `rewritesToWithSortRewriteRule` Mock.cf
                , Mock.b `rewritesToWithSortRewriteRule` Mock.cf
                ]

        actual <- runSimplifyRule
            (   mkOr Mock.a Mock.b
                `rewritesToWithSortRewriteRule`
                Mock.cf
            )

        assertEqual "" expected actual
    , testCase "f(x) is always defined" $ do
        let expected =
                [ Mock.functional10 x `rewritesToWithSortRewriteRule` Mock.a
                ]

        actual <- runSimplifyRule
            (   Pair (Mock.functional10 x, makeTruePredicate Mock.testSort)
                `rewritesToWithSortRewriteRule`
                Pair (Mock.a, makeTruePredicate Mock.testSort)
            )

        assertEqual "" expected actual
    ]
  where
    rewritesToWithSortRewriteRule
        :: RuleBase base (RewriteRule VariableName)
        => base VariableName
        -> base VariableName
        -> RewriteRule VariableName
    rewritesToWithSortRewriteRule = Common.rewritesToWithSort

    x = mkElemVar Mock.x

test_simplifyRule_OnePathRuleOLD :: [TestTree]
test_simplifyRule_OnePathRuleOLD =
    [ testCase "Predicate simplification removes trivial claim" $ do
        let expected = []
        actual <- runSimplifyRule
            ( Pair
                ( Mock.b
                , makeAndPredicate
                    (makeNotPredicate
                        (makeEqualsPredicate Mock.testSort x Mock.b)
                    )
                    (makeNotPredicate
                        (makeNotPredicate
                            (makeEqualsPredicate Mock.testSort x Mock.b)
                        )
                    )
                )
              `rewritesToWithSortOLD`
              Pair (Mock.a, makeTruePredicate Mock.testSort)
            )
        assertEqual "" expected actual

    , testCase "Case where f(x) is defined;\
               \ Case where it is not is simplified" $ do
        let expected =
                [   Pair (Mock.f x, makeCeilPredicate Mock.testSort (Mock.f x))
                    `rewritesToWithSortOLD`
                    Pair (Mock.a, makeTruePredicate Mock.testSort)
                ]

        actual <- runSimplifyRule
            (   Pair (Mock.f x, makeTruePredicate Mock.testSort)
                `rewritesToWithSortOLD`
                Pair (Mock.a, makeTruePredicate Mock.testSort)
            )

        assertEqual "" expected actual

    , testCase "Substitution in requires predicate" $ do
        let expected = [Mock.a `rewritesToWithSortOLD` Mock.f Mock.b]

        actual <- runSimplifyRule
            (   Pair (Mock.a,  makeEqualsPredicate Mock.testSort Mock.b x)
                `rewritesToWithSortOLD`
                Pair (Mock.f x, makeTruePredicate Mock.testSort)
            )

        assertEqual "" expected actual

    , testCase "Simplifies requires predicate" $ do
        let expected = [Mock.a `rewritesToWithSortOLD` Mock.cf]

        actual <- runSimplifyRule
            (   Pair (Mock.a,  makeEqualsPredicate Mock.testSort Mock.b Mock.b)
                `rewritesToWithSortOLD`
                Pair (Mock.cf, makeTruePredicate Mock.testSort)
            )

        assertEqual "" expected actual
    ]
  where
    rewritesToWithSortOLD
        :: RuleBase base OLD.OnePathRule
        => base VariableName
        -> base VariableName
        -> OLD.OnePathRule
    rewritesToWithSortOLD = Common.rewritesToWithSort

    x = mkElemVar Mock.x

test_simplifyRule_OnePathRule :: [TestTree]
test_simplifyRule_OnePathRule =
    [ testCase "No simplification needed" $ do
        let rule = Mock.a `rewritesToWithSort` Mock.cf
            expected = [rule]

        actual <- runSimplifyRule rule

        assertEqual "" expected actual

    , testCase "Simplify lhs term" $ do
        let expected = [Mock.a `rewritesToWithSort` Mock.cf]

        actual <- runSimplifyRule
            (   mkAnd Mock.a (mkEquals Mock.testSort Mock.a Mock.a)
                `rewritesToWithSort`
                Mock.cf
            )

        assertEqual "" expected actual

    , testCase "Does not simplify rhs term" $ do
        let rule =
                Mock.a
                `rewritesToWithSort`
                mkAnd Mock.cf (mkEquals Mock.testSort Mock.a Mock.a)
            expected = [rule]

        actual <- runSimplifyRule rule

        assertEqual "" expected actual

    , testCase "Substitution in lhs term" $ do
        let expected = [Mock.a `rewritesToWithSort` Mock.f Mock.b]

        actual <- runSimplifyRule
            (   mkAnd Mock.a (mkEquals Mock.testSort Mock.b x)
                `rewritesToWithSort` Mock.f x
            )

        assertEqual "" expected actual

    , testCase "Simplifies requires predicate" $ do
        let expected = [Mock.a `rewritesToWithSort` Mock.cf]

        actual <- runSimplifyRule
            (   Pair (Mock.a,  makeEqualsPredicate Mock.testSort Mock.b Mock.b)
                `rewritesToWithSort`
                Pair (Mock.cf, makeTruePredicate Mock.testSort)
            )

        assertEqual "" expected actual

    , testCase "Does not simplify ensures predicate" $ do
        let rule =
                Pair (Mock.a,  makeTruePredicate Mock.testSort)
                `rewritesToWithSort`
                Pair (Mock.cf, makeEqualsPredicate Mock.testSort Mock.b Mock.b)
            expected = [rule]

        actual <- runSimplifyRule rule

        assertEqual "" expected actual

    , testCase "Substitution in requires predicate" $ do
        let expected = [Mock.a `rewritesToWithSort` Mock.f Mock.b]

        actual <- runSimplifyRule
            (   Pair (Mock.a,  makeEqualsPredicate Mock.testSort Mock.b x)
                `rewritesToWithSort`
                Pair (Mock.f x, makeTruePredicate Mock.testSort)
            )

        assertEqual "" expected actual

    , testCase "Splits rule" $ do
        let expected =
                [ Mock.a `rewritesToWithSort` Mock.cf
                , Mock.b `rewritesToWithSort` Mock.cf
                ]

        actual <- runSimplifyRule
            (   mkOr Mock.a Mock.b
                `rewritesToWithSort`
                Mock.cf
            )

        assertEqual "" expected actual
    , testCase "Case where f(x) is defined;\
               \ Case where it is not is simplified" $ do
        let expected =
                [   Pair (Mock.f x, makeCeilPredicate Mock.testSort (Mock.f x))
                    `rewritesToWithSort`
                    Pair (Mock.a, makeTruePredicate Mock.testSort)
                ]

        actual <- runSimplifyRule
            (   Pair (Mock.f x, makeTruePredicate Mock.testSort)
                `rewritesToWithSort`
                Pair (Mock.a, makeTruePredicate Mock.testSort)
            )

        assertEqual "" expected actual
    , testCase "f(x) is always defined" $ do
        let expected =
                [ Mock.functional10 x `rewritesToWithSort` Mock.a
                ]

        actual <- runSimplifyRule
            (   Pair (Mock.functional10 x, makeTruePredicate Mock.testSort)
                `rewritesToWithSort`
                Pair (Mock.a, makeTruePredicate Mock.testSort)
            )

        assertEqual "" expected actual
    , testCase "Predicate simplification removes trivial claim" $ do
        let expected = []
        actual <- runSimplifyRule
            ( Pair
                ( Mock.b
                , makeAndPredicate
                    (makeNotPredicate
                        (makeEqualsPredicate Mock.testSort x Mock.b)
                    )
                    (makeNotPredicate
                        (makeNotPredicate
                            (makeEqualsPredicate Mock.testSort x Mock.b)
                        )
                    )
                )
              `rewritesToWithSort`
              Pair (Mock.a, makeTruePredicate Mock.testSort)
            )
        assertEqual "" expected actual
    ]
  where
    rewritesToWithSort
        :: RuleBase base OnePathRule
        => base VariableName
        -> base VariableName
        -> OnePathRule
    rewritesToWithSort = Common.rewritesToWithSort

    x = mkElemVar Mock.x

runSimplifyRule
    :: SimplifyRuleLHS rule
    => rule
    -> IO [rule]
runSimplifyRule rule =
    fmap MultiAnd.extractPatterns
    $ runNoSMT
    $ runSimplifier Mock.env $ do
        SMT.All.declare Mock.smtDeclarations
        simplifyRuleLhs rule

test_simplifyClaimRuleOLD :: [TestTree]
test_simplifyClaimRuleOLD =
    [ test "infers definedness" []
        rule1
        [rule1']
    , test "includes side condition" [(Mock.g Mock.a, Mock.f Mock.a)]
        rule2
        [rule2']
    ]
  where
    rule1, rule2, rule2' :: RulePattern VariableName
    rule1 = rulePattern (Mock.f Mock.a) Mock.b
    rule1' = rule1 & requireDefined
    rule2 =
        rulePattern @VariableName (Mock.g Mock.a) Mock.b
        & Lens.set (field @"requires") requiresOLD
    rule2' =
        rule2
        & requireDefined
        & Lens.set (field @"left") (Mock.f Mock.a)

    requiresOLD :: Predicate VariableName
    requiresOLD = makeEqualsPredicate Mock.testSort Mock.a Mock.b

    requireDefined rule =
        Lens.over
            (field @"requires")
            (flip makeAndPredicate
                (makeCeilPredicate sort left)
            )
            rule
      where
        left = Lens.view (field @"left") rule
        sort = termLikeSort left

    test
        :: HasCallStack
        => TestName
        -> [(TermLike VariableName, TermLike VariableName)]  -- ^ replacements
        -> RulePattern VariableName
        -> [RulePattern VariableName]
        -> TestTree
    test name replacementsOLD (OLD.OnePathRule -> inputOLD) (map OLD.OnePathRule -> expect) =
        -- Test simplifyClaimRule through the OnePathRule instance.
        testCase name $ do
            actual <- run $ simplifyRuleLhs inputOLD
            assertEqual "" expect (MultiAnd.extractPatterns actual)
      where
        run =
            runNoSMT
            . runSimplifier env
            . flip runReaderT TestEnvOLD { replacementsOLD, inputOLD, requiresOLD }
            . runTestSimplifierTOLD
        env =
            Mock.env
                { simplifierCondition = emptyConditionSimplifier
                , simplifierAxioms = mempty
                }

test_simplifyClaimRule :: [TestTree]
test_simplifyClaimRule =
    [ test "infers definedness" []
        rule1
        [rule1']
    , test "includes side condition" [(Mock.g Mock.a, Mock.f Mock.a)]
        rule2
        [rule2']
    ]
  where
    rule1, rule2, rule2' :: ClaimPattern
    rule1 =
        claimPattern
            (Pattern.fromTermLike (Mock.f Mock.a))
            (OrPattern.fromPatterns [Pattern.fromTermLike Mock.b])
            []
    rule1' = rule1 & requireDefined
    rule2 =
        claimPattern
            (Pattern.fromTermLike (Mock.g Mock.a))
            (OrPattern.fromPatterns [Pattern.fromTermLike Mock.b])
            []
        & require aEqualsb
    rule2' =
        rule2
        & requireDefined
        & Lens.over
            (field @"left")
            ( Pattern.andCondition
                (Mock.f Mock.a & Pattern.fromTermLike)
            . Pattern.withoutTerm
            )

    require condition =
        Lens.over
            (field @"left")
            (flip Pattern.andCondition condition)

    aEqualsb =
        makeEqualsPredicate Mock.testSort Mock.a Mock.b
        & Condition.fromPredicate

    requireDefined =
        Lens.over
            (field @"left")
            (\left' ->
                let leftTerm = Pattern.term left'
                    leftSort = TermLike.termLikeSort leftTerm
                 in Pattern.andCondition
                        left'
                        ( makeCeilPredicate leftSort leftTerm
                        & Condition.fromPredicate
                        )
            )

    test
        :: HasCallStack
        => TestName
        -> [(TermLike RewritingVariableName, TermLike RewritingVariableName)]
        -- ^ replacements
        -> ClaimPattern
        -> [ClaimPattern]
        -> TestTree
    test name replacements (OnePathRule -> input) (map OnePathRule -> expect) =
        -- Test simplifyClaimRule through the OnePathRule instance.
        testCase name $ do
            actual <- run $ simplifyRuleLhs input
            assertEqual "" expect (MultiAnd.extractPatterns actual)
      where
        run =
            runNoSMT
            . runSimplifier env
            . flip runReaderT TestEnv
                { replacements, input, requires = aEqualsb }
            . runTestSimplifierT
        env =
            Mock.env
                { simplifierCondition = emptyConditionSimplifier
                , simplifierAxioms = mempty
                }

data TestEnvOLD =
    TestEnvOLD
    { replacementsOLD :: ![(TermLike VariableName, TermLike VariableName)]
    , inputOLD :: !OLD.OnePathRule
    , requiresOLD :: !(Predicate VariableName)
    }

newtype TestSimplifierTOLD m a =
    TestSimplifierTOLD { runTestSimplifierTOLD :: ReaderT TestEnvOLD m a }
    deriving (Functor, Applicative, Monad)
    deriving (MonadReader TestEnvOLD)
    deriving (MonadLog, MonadSMT)

instance MonadTrans TestSimplifierTOLD where
    lift = TestSimplifierTOLD . lift

instance MFunctor TestSimplifierTOLD where
    hoist f = TestSimplifierTOLD . hoist f . runTestSimplifierTOLD

instance MonadSimplify m => MonadSimplify (TestSimplifierTOLD m) where
    simplifyTermLike sideCondition termLike = do
        TestEnvOLD { replacementsOLD, inputOLD, requiresOLD } <- Reader.ask
        let rule = OLD.getOnePathRule inputOLD
            left = Lens.view (field @"left") rule
            sort = termLikeSort left
            expectSideCondition =
                makeAndPredicate requiresOLD (makeCeilPredicate sort left)
                & liftPredicate
                & Predicate.coerceSort predicateSort
                & Condition.fromPredicate
                & SideCondition.fromCondition
            satisfied = sideCondition == expectSideCondition
        return
            . OrPattern.fromTermLike
            . (if satisfied then applyReplacements replacementsOLD else id)
            $ termLike
      where
        applyReplacements
            :: InternalVariable variable
            => [(TermLike VariableName, TermLike VariableName)]
            -> TermLike variable
            -> TermLike variable
        applyReplacements replacements zero =
            Foldable.foldl' applyReplacement zero
            $ map liftReplacement replacements

        applyReplacement orig (ini, fin)
          | orig == ini = fin
          | otherwise   = orig

        liftPredicate
            :: InternalVariable variable
            => Predicate VariableName
            -> Predicate variable
        liftPredicate = Predicate.mapVariables (pure fromVariableName)

        liftTermLike
            :: InternalVariable variable
            => TermLike VariableName
            -> TermLike variable
        liftTermLike = TermLike.mapVariables (pure fromVariableName)

        liftReplacement
            :: InternalVariable variable
            => (TermLike VariableName, TermLike VariableName)
            -> (TermLike variable, TermLike variable)
        liftReplacement = Bifunctor.bimap liftTermLike liftTermLike

data TestEnv =
    TestEnv
    { replacements
        :: ![(TermLike RewritingVariableName, TermLike RewritingVariableName)]
    , input :: !OnePathRule
    , requires :: !(Condition RewritingVariableName)
    }

newtype TestSimplifierT m a =
    TestSimplifierT { runTestSimplifierT :: ReaderT TestEnv m a }
    deriving (Functor, Applicative, Monad)
    deriving (MonadReader TestEnv)
    deriving (MonadLog, MonadSMT)

instance MonadTrans TestSimplifierT where
    lift = TestSimplifierT . lift

instance MFunctor TestSimplifierT where
    hoist f = TestSimplifierT . hoist f . runTestSimplifierT

instance MonadSimplify m => MonadSimplify (TestSimplifierT m) where
    simplifyTermLike sideCondition termLike = do
        TestEnv { replacements, input, requires } <- Reader.ask
        let rule = getOnePathRule input
            leftTerm =
                Lens.view (field @"left") rule
                & Pattern.term
            sort = termLikeSort leftTerm
            expectSideCondition =
                makeAndPredicate
                    (Condition.toPredicate requires)
                    (makeCeilPredicate sort leftTerm)
                & liftPredicate
                & Predicate.coerceSort predicateSort
                & Condition.fromPredicate
                & SideCondition.fromCondition
            satisfied = sideCondition == expectSideCondition
        return
            . OrPattern.fromTermLike
            . (if satisfied then applyReplacements replacements else id)
            $ termLike
      where
        applyReplacements
            :: InternalVariable variable
            => [(TermLike RewritingVariableName, TermLike RewritingVariableName)]
            -> TermLike variable
            -> TermLike variable
        applyReplacements replacements zero =
            Foldable.foldl' applyReplacement zero
            $ fmap liftReplacement replacements

        applyReplacement orig (ini, fin)
          | orig == ini = fin
          | otherwise   = orig

        liftPredicate
            :: InternalVariable variable
            => Predicate RewritingVariableName
            -> Predicate variable
        liftPredicate =
            Predicate.mapVariables liftRewritingVariable

        liftTermLike
            :: InternalVariable variable
            => TermLike RewritingVariableName
            -> TermLike variable
        liftTermLike =
            TermLike.mapVariables liftRewritingVariable

        liftReplacement
            :: InternalVariable variable
            => (TermLike RewritingVariableName, TermLike RewritingVariableName)
            -> (TermLike variable, TermLike variable)
        liftReplacement = Bifunctor.bimap liftTermLike liftTermLike

        liftRewritingVariable
            :: InternalVariable variable
            => AdjSomeVariableName (RewritingVariableName -> variable)
        liftRewritingVariable =
            pure (.) <*> pure fromVariableName <*> getRewritingVariable
