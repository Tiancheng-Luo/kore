{-|
Module      : Kore.Step.Axiom.Matcher
Description : Matches free-form patterns which can be used when applying
              Equals rules.
Copyright   : (c) Runtime Verification, 2018
License     : NCSA
Maintainer  : virgil.serbanuta@runtimeverification.com
Stability   : experimental
Portability : portable
-}
module Kore.Step.Axiom.Matcher
    ( MatchingVariable
    , MatchResult
    , matchIncremental
    ) where

import Prelude.Kore

import qualified Control.Error as Error
import Control.Lens
    ( (%=)
    , (.=)
    , (<>=)
    )
import qualified Control.Lens as Lens
import qualified Control.Monad as Monad
import Control.Monad.State.Strict
    ( MonadState
    , StateT
    )
import qualified Control.Monad.State.Strict as Monad.State
import Control.Monad.Trans.Maybe
    ( MaybeT (..)
    )
import qualified Data.Align as Align
    ( align
    )
import qualified Data.Bifunctor as Bifunctor
import qualified Data.Foldable as Foldable
import qualified Data.Functor.Foldable as Recursive
import Data.Generics.Product
import Data.List
    ( foldl'
    )
import Data.Map.Strict
    ( Map
    )
import qualified Data.Map.Strict as Map
import Data.Sequence
    ( pattern (:|>)
    , Seq
    )
import qualified Data.Sequence as Seq
import Data.Set
    ( Set
    )
import qualified Data.Set as Set
import Data.These
    ( These (..)
    )
import qualified GHC.Generics as GHC

import qualified Kore.Attribute.Pattern as Attribute.Pattern
import qualified Kore.Attribute.Pattern.FreeVariables as FreeVariables
import qualified Kore.Builtin.AssociativeCommutative as Ac
import qualified Kore.Builtin.List as List
import qualified Kore.Domain.Builtin as Builtin
import Kore.Internal.MultiAnd
    ( MultiAnd
    )
import qualified Kore.Internal.MultiAnd as MultiAnd
import Kore.Internal.Predicate
    ( Predicate
    , makeCeilPredicate_
    )
import qualified Kore.Internal.Predicate as Predicate
import qualified Kore.Internal.Symbol as Symbol
import Kore.Internal.TermLike hiding
    ( substitute
    )
import qualified Kore.Internal.TermLike as TermLike
import Kore.Step.Simplification.InjSimplifier as InjSimplifier
import Kore.Step.Simplification.Overloading
    ( matchOverloading
    )
import Kore.Step.Simplification.Simplify
    ( MonadSimplify
    )
import qualified Kore.Step.Simplification.Simplify as Simplifier
import Kore.Variables.Binding
import qualified Kore.Variables.Fresh as Variables
import Pair

-- * Matching

newtype Constraint variable =
    Constraint
        { getConstraint :: Pair (TermLike variable)
        }
    deriving (Eq)

data TermLikeClass =
    Variables
    | ConcreteBuiltins
    | ConstructorAtTop
    | OtherTermLike
    | ListBuiltin
    | AssocCommBuiltin
    deriving (Eq)

termPriority :: TermLikeClass -> Int
termPriority Variables = 1
termPriority ConcreteBuiltins = 2
termPriority ConstructorAtTop = 3
termPriority OtherTermLike = 4
termPriority ListBuiltin = 5
termPriority AssocCommBuiltin = 6

instance Ord TermLikeClass where
    c1 <= c2 = termPriority c1 <= termPriority c2

findClass :: Constraint variable -> TermLikeClass
findClass (Constraint (Pair left _)) = findClassWorker left
  where
    findClassWorker (Var_ _)           = Variables
    findClassWorker (ElemVar_ _)       = Variables
    findClassWorker (SetVar_ _)        = Variables
    findClassWorker (StringLiteral_ _) = ConcreteBuiltins
    findClassWorker (BuiltinInt_ _)    = ConcreteBuiltins
    findClassWorker (BuiltinBool_ _)   = ConcreteBuiltins
    findClassWorker (BuiltinString_ _) = ConcreteBuiltins
    findClassWorker (App_ symbol _) =
        if Symbol.isConstructor symbol
            then ConstructorAtTop
            else OtherTermLike
    findClassWorker (BuiltinList_ _)   = ListBuiltin
    findClassWorker (BuiltinSet_ _)    = AssocCommBuiltin
    findClassWorker (BuiltinMap_ _)    = AssocCommBuiltin
    findClassWorker _                  = OtherTermLike

instance Ord variable => Ord (Constraint variable) where
    compare constraint1@(Constraint pair1) constraint2@(Constraint pair2) =
        compare (findClass constraint1) (findClass constraint2)
        <> compare pair1 pair2

type MatchResult variable =
    ( Predicate variable
    , Map.Map (SomeVariableName variable) (TermLike variable)
    )

{- | Dispatch a single matching constraint.

@matchOne@ is the heart of the matching algorithm. Each matcher is applied to
the constraint in sequence, until one accepts the pair. The matchers may
introduce substitutions and new constraints. If none of the matchers accepts the
pair, it is deferred until we have more information.

 -}
matchOne
    :: (MatchingVariable variable, MonadSimplify simplifier)
    => Pair (TermLike variable)
    -> MatcherT variable simplifier ()
matchOne pair =
    (   matchVariable    pair
    <|> matchEqualHeads  pair
    <|> matchExists      pair
    <|> matchForall      pair
    <|> matchApplication pair
    <|> matchBuiltinList pair
    <|> matchBuiltinMap  pair
    <|> matchBuiltinSet  pair
    <|> matchInj         pair
    <|> matchOverload    pair
    <|> matchDefined     pair
    )
    & Error.maybeT (defer pair) return

{- | Drive @matchOne@ until it cannot continue.

Matching ends when all constraints have been dispatched. If there are remaining
deferred constraints, then matching fails.

 -}
matchIncremental
    :: forall variable simplifier
    .  (MatchingVariable variable, MonadSimplify simplifier)
    => TermLike variable
    -> TermLike variable
    -> simplifier (Maybe (MatchResult variable))
matchIncremental termLike1 termLike2 =
    Monad.State.evalStateT matcher initial
  where
    matcher :: MatcherT variable simplifier (Maybe (MatchResult variable))
    matcher = pop >>= maybe done (\pair -> matchOne pair >> matcher)

    initial =
        MatcherState
            { queued = Set.singleton (Constraint (Pair termLike1 termLike2))
            , deferred = empty
            , predicate = empty
            , substitution = mempty
            , bound = mempty
            , targets = free1
            , avoiding = free1 <> free2
            }
    free1 = (FreeVariables.toNames . freeVariables) termLike1
    free2 = (FreeVariables.toNames . freeVariables) termLike2

    -- | Check that matching is finished and construct the result.
    done :: MatcherT variable simplifier (Maybe (MatchResult variable))
    done = do
        MatcherState { queued, deferred } <- Monad.State.get
        let isDone = null queued && null deferred
        if isDone
            then Just <$> assembleResult
            else return Nothing

    assembleResult :: MatcherT variable simplifier (MatchResult variable)
    assembleResult = do
        final <- Monad.State.get
        let MatcherState { predicate, substitution } = final
            predicate' = MultiAnd.toPredicate predicate
        return (predicate', substitution)

matchEqualHeads
    :: Ord variable
    => Monad simplifier
    => Pair (TermLike variable)
    -> MaybeT (MatcherT variable simplifier) ()
-- Terminal patterns
matchEqualHeads (Pair (StringLiteral_ string1) (StringLiteral_ string2)) =
    Monad.guard (string1 == string2)
matchEqualHeads (Pair (BuiltinInt_ int1) (BuiltinInt_ int2)) =
    Monad.guard (int1 == int2)
matchEqualHeads (Pair (BuiltinBool_ bool1) (BuiltinBool_ bool2)) =
    Monad.guard (bool1 == bool2)
matchEqualHeads (Pair (BuiltinString_ string1) (BuiltinString_ string2)) =
    Monad.guard (string1 == string2)
matchEqualHeads (Pair (Bottom_ _) (Bottom_ _)) =
    return ()
matchEqualHeads (Pair (Top_ _) (Top_ _)) =
    return ()
matchEqualHeads (Pair (Endianness_ symbol1) (Endianness_ symbol2)) =
    Monad.guard (symbol1 == symbol2)
matchEqualHeads (Pair (Signedness_ symbol1) (Signedness_ symbol2)) =
    Monad.guard (symbol1 == symbol2)
matchEqualHeads
    ( Pair
        (InternalBytes_ sort1 byteString1)
        (InternalBytes_ sort2 byteString2)
    )
  =
    Monad.guard (sort1 == sort2 && byteString1 == byteString2)
-- Non-terminal patterns
matchEqualHeads (Pair (Ceil_ _ _ term1) (Ceil_ _ _ term2)) =
    push (Pair term1 term2)
matchEqualHeads (Pair (DV_ sort1 dv1) (DV_ sort2 dv2)) = do
    Monad.guard (sort1 == sort2)
    push (Pair dv1 dv2)
matchEqualHeads (Pair (Equals_ _ _ term11 term12) (Equals_ _ _ term21 term22)) =
    push (Pair term11 term21) >> push (Pair term12 term22)
matchEqualHeads _ = empty

matchExists
    :: (MatchingVariable variable, Monad simplifier)
    => Pair (TermLike variable)
    -> MaybeT (MatcherT variable simplifier) ()
matchExists (Pair (Exists_ _ variable1 term1) (Exists_ _ variable2 term2)) =
    matchBinder (Binder variable1 term1) (Binder variable2 term2)
matchExists _ = empty

matchForall
    :: (MatchingVariable variable, Monad simplifier)
    => Pair (TermLike variable)
    -> MaybeT (MatcherT variable simplifier) ()
matchForall (Pair (Forall_ _ variable1 term1) (Forall_ _ variable2 term2)) =
    matchBinder (Binder variable1 term1) (Binder variable2 term2)
matchForall _ = empty

matchBinder
    :: (MatchingVariable variable, Monad simplifier)
    => Binder (ElementVariable variable) (TermLike variable)
    -> Binder (ElementVariable variable) (TermLike variable)
    -> MaybeT (MatcherT variable simplifier) ()
matchBinder (Binder variable1 term1) (Binder variable2 term2) = do
    Monad.guard (on (==) variableSort variable1 variable2)
    -- Lift the bound variable to the top level.
    lifted1 <- liftVariable someVariable1
    let term1' = fromMaybe term1 $ do
            subst1 <- Map.singleton someVariableName1 . mkVar <$> lifted1
            return $ substituteTermLike subst1 term1
    let variable1' = fromMaybe someVariable1 lifted1
        subst2 = Map.singleton someVariableName2 (mkVar variable1')
        term2' = substituteTermLike subst2 term2
    -- Record the uniquely-named variable so it will not be shadowed later.
    bindVariable variable1'
    push (Pair term1' term2')
  where
    someVariable1 = inject variable1
    someVariable2 = inject variable2
    someVariableName1 = variableName someVariable1
    someVariableName2 = variableName someVariable2

matchVariable
    :: (MatchingVariable variable, MonadSimplify simplifier)
    => Pair (TermLike variable)
    -> MaybeT (MatcherT variable simplifier) ()
matchVariable (Pair (Var_ variable1) (Var_ variable2))
  | variable1 == variable2 = return ()
matchVariable (Pair (ElemVar_ variable1) term2) = do
    targetCheck (inject variable1)
    Monad.guard (isFunctionPattern term2)
    substitute variable1 term2
matchVariable (Pair (SetVar_ variable1) term2) = do
    targetCheck (inject variable1)
    setSubstitute variable1 term2
matchVariable _ = empty

matchApplication
    :: Ord variable
    => Monad simplifier
    => Pair (TermLike variable)
    -> MaybeT (MatcherT variable simplifier) ()
matchApplication (Pair (App_ symbol1 children1) (App_ symbol2 children2)) = do
    Monad.guard (symbol1 == symbol2)
    Foldable.traverse_ push (zipWith Pair children1 children2)
matchApplication _ = empty

matchBuiltinList
    :: (MatchingVariable variable, Monad simplifier)
    => Pair (TermLike variable)
    -> MaybeT (MatcherT variable simplifier) ()
matchBuiltinList (Pair (BuiltinList_ list1) (BuiltinList_ list2)) = do
    (aligned, tail2) <- leftAlignLists list1 list2 & Error.hoistMaybe
    Monad.guard (null tail2)
    Foldable.traverse_ push aligned
matchBuiltinList (Pair (App_ symbol1 children1) (BuiltinList_ list2))
  | List.isSymbolConcat symbol1 = matchBuiltinListConcat children1 list2
matchBuiltinList _ = empty

matchBuiltinListConcat
    :: (MatchingVariable variable, Monad simplifier)
    => [TermLike variable]
    -> Builtin.InternalList (TermLike variable)
    -> MaybeT (MatcherT variable simplifier) ()

matchBuiltinListConcat [BuiltinList_ list1, frame1] list2 = do
    (aligned, tail2) <- leftAlignLists list1 list2 & Error.hoistMaybe
    Foldable.traverse_ push aligned
    push (Pair frame1 (mkBuiltinList tail2))

matchBuiltinListConcat [frame1, BuiltinList_ list1] list2 = do
    (head2, aligned) <- rightAlignLists list1 list2 & Error.hoistMaybe
    push (Pair frame1 (mkBuiltinList head2))
    Foldable.traverse_ push aligned

matchBuiltinListConcat _ _ = empty

matchBuiltinSet
    :: (MatchingVariable variable, Monad simplifier)
    => Pair (TermLike variable)
    -> MaybeT (MatcherT variable simplifier) ()
matchBuiltinSet (Pair (BuiltinSet_ set1) (BuiltinSet_ set2)) =
    matchNormalizedAc pushSetElement pushSetValue wrapTermLike normalized1 normalized2
  where
    normalized1 = Builtin.unwrapAc $ Builtin.builtinAcChild set1
    normalized2 = Builtin.unwrapAc $ Builtin.builtinAcChild set2
    pushSetValue _ = return ()
    pushSetElement = push . fmap Builtin.getSetElement
    wrapTermLike unwrapped =
        set2
        & Lens.set (field @"builtinAcChild") (Builtin.wrapAc unwrapped)
        & mkBuiltinSet
matchBuiltinSet _ = empty

matchBuiltinMap
    :: (MatchingVariable variable, Monad simplifier)
    => Pair (TermLike variable)
    -> MaybeT (MatcherT variable simplifier) ()
matchBuiltinMap (Pair (BuiltinMap_ map1) (BuiltinMap_ map2)) =
    matchNormalizedAc pushMapElement pushMapValue wrapTermLike normalized1 normalized2
  where
    normalized1 = Builtin.unwrapAc $ Builtin.builtinAcChild map1
    normalized2 = Builtin.unwrapAc $ Builtin.builtinAcChild map2
    pushMapValue = push . fmap Builtin.getMapValue
    pushMapElement (Pair element1 element2) = do
        let (key1, value1) = Builtin.getMapElement element1
            (key2, value2) = Builtin.getMapElement element2
        push (Pair key1 key2)
        push (Pair value1 value2)
    wrapTermLike unwrapped =
        map2
        & Lens.set (field @"builtinAcChild") (Builtin.wrapAc unwrapped)
        & mkBuiltinMap
matchBuiltinMap _ = empty

matchInj
    :: (MatchingVariable variable, MonadSimplify simplifier)
    => Pair (TermLike variable)
    -> MaybeT (MatcherT variable simplifier) ()
matchInj (Pair (Inj_ inj1) (Inj_ inj2)) = do
    InjSimplifier { unifyInj } <- Simplifier.askInjSimplifier
    unifyInj inj1 inj2 & either (const empty) (push . injChild)
matchInj _ = empty

matchOverload
    :: (MatchingVariable variable, MonadSimplify simplifier)
    => Pair (TermLike variable)
    -> MaybeT (MatcherT variable simplifier) ()
matchOverload termPair = Error.hushT (matchOverloading termPair) >>= push

matchDefined
    :: (MatchingVariable variable, MonadSimplify simplifier)
    => Pair (TermLike variable)
    -> MaybeT (MatcherT variable simplifier) ()
matchDefined (Pair term1 term2)
  | Defined_ def1 <- term1 = push (Pair def1 term2)
  | Defined_ def2 <- term2 = push (Pair term1 def2)
  | otherwise = empty

-- * Implementation

type MatchingVariable variable = InternalVariable variable

{- | The internal state of the matching algorithm.
 -}
data MatcherState variable =
    MatcherState
        { queued :: !(Set (Constraint variable))
        -- ^ Solvable matching constraints.
        , deferred :: !(Seq (Pair (TermLike variable)))
        -- ^ Unsolvable matching constraints; may become solvable with more
        -- information.
        , substitution :: !(Map (SomeVariableName variable) (TermLike variable))
        -- ^ Matching solution: Substitutions for target variables.
        , predicate :: !(MultiAnd (Predicate variable))
        -- ^ Matching solution: Additional constraints.
        , bound :: !(Set (SomeVariableName variable))
        -- ^ Bound variable that must not escape in the solution.
        , targets :: !(Set (SomeVariableName variable))
        -- ^ Target variables that may be substituted.
        , avoiding :: !(Set (SomeVariableName variable))
        -- ^ Variables that must not be shadowed.
        }
    deriving (GHC.Generic)

type MatcherT variable simplifier = StateT (MatcherState variable) simplifier

{- | Pop the next constraint from the matching queue.
 -}
pop
    :: MonadState (MatcherState variable) matcher
    => matcher (Maybe (Pair (TermLike variable)))
pop = do
    queued <- Lens.use (field @"queued")
    case Set.minView queued of
        Just (next, queued') -> do
            field @"queued" .= queued'
            return . Just . getConstraint $ next
        _ ->
            return Nothing

{- | Push a new constraint onto the matching queue.
 -}
push
    :: Ord variable
    => MonadState (MatcherState variable) matcher
    => Pair (TermLike variable)
    -> matcher ()
push pair = field @"queued" %= Set.insert (Constraint pair)

{- | Defer a constraint until more information is available.

The constraint will be retried after the next substitution which affects it.

 -}
defer
    :: MonadState (MatcherState variable) matcher
    => Pair (TermLike variable)
    -> matcher ()
defer pair = field @"deferred" %= (:|> pair)

{- | Record an element substitution in the matching solution.

The substitution is applied to the remaining constraints and to the partial
matching solution (so that it is always normalized). @substitute@ ensures that:

1. The variable does not occur on the right-hand side.
2. No bound variable would escape through the right-hand side.
3. The right-hand side is defined (through a constraint, if necessary).

 -}
substitute
    :: forall simplifier variable
    .  (MatchingVariable variable, MonadSimplify simplifier)
    => ElementVariable variable
    -> TermLike variable
    -> MaybeT (MatcherT variable simplifier) ()
substitute eVariable termLike = do
    -- Ensure that the variable does not occur free in the TermLike.
    occursCheck variable termLike
    -- Ensure that no bound variable would escape.
    escapeCheck termLike
    -- Ensure that the TermLike is defined.
    definedTerm termLike
    -- Record the substitution.
    field @"substitution" <>= subst

    -- Isolate the deferred pairs which depend on the variable.
    -- After substitution, the dependent pairs go to the front of the queue.
    MatcherState { deferred } <- Monad.State.get
    let (indep, dep) = Seq.partition isIndependent deferred
    field @"deferred" .= indep

    -- Push the dependent deferred pairs to the front of the queue.
    Foldable.traverse_ push dep

    Monad.State.get
        -- Apply the substitution to the queued pairs.
        >>= (field @"queued" . transformQueue traverse) substitute2
        -- Apply the substitution to the accumulated matching solution.
        >>= (field @"substitution" . traverse) substitute1
        >>= Monad.State.put
    field @"predicate" . Lens.mapped %= Predicate.substitute subst

    return ()
  where
    variable = inject eVariable
    Variable { variableName } = variable
    isIndependent = not . any (hasFreeVariable variableName)
    subst = Map.singleton variableName termLike

    substitute2
        :: Constraint variable
        -> MaybeT (MatcherT variable simplifier) (Constraint variable)
    substitute2 (Constraint pair) =
        Constraint <$> traverse substitute1 pair

    substitute1
        :: TermLike variable
        -> MaybeT (MatcherT variable simplifier) (TermLike variable)
    substitute1 termLike' = do
        injSimplifier <- Simplifier.askInjSimplifier
        termLike'
            & TermLike.substitute subst
            -- Injected Map and Set keys must be properly normalized before
            -- calling Builtin.renormalize.
            & InjSimplifier.normalize injSimplifier
            & renormalizeBuiltins
            & return

{- | Record a set substitution in the matching solution.

The substitution is applied to the remaining constraints and to the partial
matching solution (so that it is always normalized). @substitute@ ensures that
the variable does not occur on the right-hand side of the substitution.

 -}
setSubstitute
    :: forall variable simplifier
    .  (MatchingVariable variable, MonadSimplify simplifier)
    => SetVariable variable
    -> TermLike variable
    -> MaybeT (MatcherT variable simplifier) ()
setSubstitute sVariable termLike = do
    -- Ensure that the variable does not occur free in the TermLike.
    occursCheck variable termLike
    -- Record the substitution.
    field @"substitution" <>= subst

    -- Isolate the deferred pairs which depend on the variable.
    -- After substitution, the dependent pairs go to the front of the queue.
    MatcherState { deferred } <- Monad.State.get
    let (indep, dep) = Seq.partition isIndependent deferred
    field @"deferred" .= indep

    -- Push the dependent deferred pairs to the front of the queue.
    Foldable.traverse_ push dep
    -- Apply the substitution to the queued pairs.
    field @"queued" . transformQueue Lens.mapped %= substitute2

    -- Apply the substitution to the accumulated matching solution.
    field @"substitution" . Lens.mapped %= substitute1
    field @"predicate" . Lens.mapped %= Predicate.substitute subst

    return ()
  where
    variable = inject sVariable
    Variable { variableName } = variable
    isIndependent = not . any (hasFreeVariable variableName)
    subst = Map.singleton variableName termLike
    substitute2 :: Constraint variable -> Constraint variable
    substitute2 (Constraint pair) = Constraint $ fmap substitute1 pair
    substitute1 = substituteTermLike subst

transformQueue
    :: Functor f
    => Ord a
    => ((a -> f a) -> [a] -> f [a])
    -> (a -> f a)
    -> Set a
    -> f (Set a)
transformQueue trans f x = Set.fromList <$> trans f (Set.toAscList x)

substituteTermLike
    :: MatchingVariable variable
    => Map (SomeVariableName variable) (TermLike variable)
    -> TermLike variable
    -> TermLike variable
substituteTermLike subst = renormalizeBuiltins . TermLike.substitute subst

occursCheck
    :: (MatchingVariable variable, Monad simplifier)
    => SomeVariable variable
    -> TermLike variable
    -> MaybeT (MatcherT variable simplifier) ()
occursCheck Variable { variableName } termLike =
    (Monad.guard . not) (hasFreeVariable variableName termLike)

definedTerm
    :: (MatchingVariable variable, MonadState (MatcherState variable) matcher)
    => TermLike variable
    -> matcher ()
definedTerm termLike
  | isDefinedPattern termLike = return ()
  | otherwise = field @"predicate" <>= definedTermLike
  where
    definedTermLike = MultiAnd.make [makeCeilPredicate_ termLike]

{- | Ensure that the given variable is a target variable.

Matching should only produce substitutions for variables in one argument; these
are the "target" variables. After one or more substitutions, the first argument
can also contain non-target variables and this guard is used to ensure that we
do not attempt to match on them.

 -}
targetCheck
    :: (MatchingVariable variable, Monad simplifier)
    => SomeVariable variable
    -> MaybeT (MatcherT variable simplifier) ()
targetCheck Variable { variableName } = do
    MatcherState { targets } <- Monad.State.get
    Monad.guard (Set.member variableName targets)

{- | Ensure that no bound variables occur free in the pattern.

We must not produce a matching solution which would allow a bound variable to
escape.

 -}
escapeCheck
    :: forall simplifier variable
    .  (MatchingVariable variable, Monad simplifier)
    => TermLike variable
    -> MaybeT (MatcherT variable simplifier) ()
escapeCheck termLike = do
    let free = FreeVariables.toNames (freeVariables termLike)
    MatcherState { bound } <- Monad.State.get
    Monad.guard (Set.disjoint bound free)

{- | Record the bound variable.

The bound variable will not escape, nor will it be shadowed.

 -}
bindVariable
    :: Ord variable
    => MonadState (MatcherState variable) matcher
    => SomeVariable variable
    -> matcher ()
bindVariable Variable { variableName } = do
    field @"bound" %= Set.insert variableName
    field @"avoiding" %= Set.insert variableName

{- | Lift a (bound) variable to the top level by with a globally-unique name.

Returns 'Nothing' if the variable name is already globally-unique.

 -}
liftVariable
    :: (FreshPartialOrd variable)
    => MonadState (MatcherState variable) matcher
    => SomeVariable variable
    -> matcher (Maybe (SomeVariable variable))
liftVariable variable =
    flip Variables.refreshVariable variable <$> Lens.use (field @"avoiding")

leftAlignLists
    ::  Builtin.InternalList (TermLike variable)
    ->  Builtin.InternalList (TermLike variable)
    ->  Maybe
            ( Builtin.InternalList (Pair (TermLike variable))
            , Builtin.InternalList (TermLike variable)
            )
leftAlignLists internal1 internal2
  | length list2 < length list1 = empty
  | otherwise =
    return
        ( internal1 { Builtin.builtinListChild = list12 }
        , internal1 { Builtin.builtinListChild = tail2 }
        )
  where
    list1 = Builtin.builtinListChild internal1
    list2 = Builtin.builtinListChild internal2
    list12 = Seq.zipWith Pair list1 head2
    (head2, tail2) = Seq.splitAt (length list1) list2

rightAlignLists
    ::  Builtin.InternalList (TermLike variable)
    ->  Builtin.InternalList (TermLike variable)
    ->  Maybe
            ( Builtin.InternalList (TermLike variable)
            , Builtin.InternalList (Pair (TermLike variable))
            )
rightAlignLists internal1 internal2
  | length list2 < length list1 = empty
  | otherwise =
    return
        ( internal1 { Builtin.builtinListChild = head2 }
        , internal1 { Builtin.builtinListChild = list12 }
        )
  where
    list1 = Builtin.builtinListChild internal1
    list2 = Builtin.builtinListChild internal2
    list12 = Seq.zipWith Pair list1 tail2
    (head2, tail2) = Seq.splitAt (length list2 - length list1) list2

type Push variable simplifier a = Pair a -> MatcherT variable simplifier ()

type Element normalized variable =
    Builtin.Element normalized (TermLike variable)

type Value normalized variable =
    Builtin.Value normalized (TermLike variable)

type NormalizedAc normalized variable =
    Builtin.NormalizedAc normalized (TermLike Concrete) (TermLike variable)

matchNormalizedAc
    :: forall normalized simplifier variable
    .   ( Builtin.AcWrapper normalized
        , MatchingVariable variable
        , Monad simplifier
        )
    =>  Push variable simplifier (Element normalized variable)
    ->  Push variable simplifier (Value normalized variable)
    ->  (NormalizedAc normalized variable -> TermLike variable)
    ->  NormalizedAc normalized variable
    ->  NormalizedAc normalized variable
    ->  MaybeT (MatcherT variable simplifier) ()
matchNormalizedAc pushElement pushValue wrapTermLike normalized1 normalized2
    | [] <- excessAbstract1
    = do
      Monad.guard (null excessConcrete1)
      case opaque1 of
          [] -> do
              Monad.guard (null opaque2)
              Monad.guard (null excessConcrete2)
              Monad.guard (null excessAbstract2)
          [frame1]
            | null excessAbstract2
            , null excessConcrete2
            , [frame2] <- opaque2 ->
                push (Pair frame1 frame2)
            | otherwise ->
                let normalized2' =
                        wrapTermLike normalized2
                            { Builtin.concreteElements = excessConcrete2
                            , Builtin.elementsWithVariables = excessAbstract2
                            }
                 in push (Pair frame1 normalized2')
          _ -> empty
      lift $ Foldable.traverse_ pushValue concrete12
      lift $ Foldable.traverse_ pushValue abstractMerge
    | [element1] <- abstract1
    , [frame1] <- opaque1
    , null concrete1 = do
        let (key1, value1) = Builtin.unwrapElement element1
        case Builtin.lookupSymbolicKeyOfAc key1 normalized2 of
            Just value2 -> lift $ do
                pushValue (Pair value1 value2)
                let normalized2' =
                        wrapTermLike
                        $ Builtin.removeSymbolicKeyOfAc key1 normalized2
                push (Pair frame1 normalized2')
            Nothing ->
                case (headMay . Map.toList $ concrete2, headMay abstract2) of
                    (Just concreteElement2, _) -> lift $ do
                        let liftedConcreteElement2 =
                                Builtin.wrapElement
                                $ Bifunctor.first TermLike.fromConcrete concreteElement2
                        pushElement (Pair element1 liftedConcreteElement2)
                        let (key2, _) = concreteElement2
                            normalized2' =
                                wrapTermLike
                                $ Builtin.removeConcreteKeyOfAc key2 normalized2
                        push (Pair frame1 normalized2')
                    (_, Just abstractElement2) -> lift $ do
                        pushElement (Pair element1 abstractElement2)
                        let (key2, _) = Builtin.unwrapElement abstractElement2
                            normalized2' =
                                wrapTermLike
                                $ Builtin.removeSymbolicKeyOfAc key2 normalized2
                        push (Pair frame1 normalized2')
                    _ -> empty
    | otherwise = empty
  where
    abstract1 = Builtin.elementsWithVariables normalized1
    concrete1 = Builtin.concreteElements normalized1
    opaque1 = Builtin.opaque normalized1
    abstract2 = Builtin.elementsWithVariables normalized2
    concrete2 = Builtin.concreteElements normalized2
    opaque2 = Builtin.opaque normalized2

    excessConcrete1 = Map.difference concrete1 concrete2
    excessConcrete2 = Map.difference concrete2 concrete1
    concrete12 = Map.intersectionWith Pair concrete1 concrete2

    IntersectionDifference
        { intersection = abstractMerge
        , excessFirst = excessAbstract1
        , excessSecond = excessAbstract2
        } = abstractIntersectionMerge abstract1 abstract2

    abstractIntersectionMerge
        :: [Builtin.Element normalized (TermLike variable)]
        -> [Builtin.Element normalized (TermLike variable)]
        -> IntersectionDifference
            (Builtin.Element normalized (TermLike variable))
            (Pair (Builtin.Value normalized (TermLike variable)))
    abstractIntersectionMerge first second =
        keyBasedIntersectionDifference
            elementMerger
            (toMap first)
            (toMap second)
      where
        toMap
            :: [Builtin.Element normalized (TermLike variable)]
            -> Map
                (TermLike variable)
                (Builtin.Element normalized (TermLike variable))
        toMap elements =
            let elementMap =
                    Map.fromList
                        (map
                            (\ value -> (elementKey value, value))
                            elements
                        )
            in if length elementMap == length elements
                then elementMap
                else error "Invalid map: duplicated keys."
        elementKey
            :: Builtin.Element normalized (TermLike variable)
            -> TermLike variable
        elementKey = fst . Builtin.unwrapElement
        elementMerger
            :: Builtin.Element normalized (TermLike variable)
            -> Builtin.Element normalized (TermLike variable)
            -> Pair (Builtin.Value normalized (TermLike variable))
        elementMerger = Pair `on` (snd . Builtin.unwrapElement)

data IntersectionDifference a b
    = IntersectionDifference
        { intersection :: ![b]
        , excessFirst :: ![a]
        , excessSecond :: ![a]
        }

emptyIntersectionDifference :: IntersectionDifference a b
emptyIntersectionDifference = IntersectionDifference
    {intersection = [], excessFirst = [], excessSecond = []}

keyBasedIntersectionDifference
    :: forall a b k
    .  Ord k
    => (a -> a -> b)
    -> Map k a
    -> Map k a
    -> IntersectionDifference a b
keyBasedIntersectionDifference merger firsts seconds =
    foldl'
        helper
        emptyIntersectionDifference
        (Map.elems $ Align.align firsts seconds)
  where
    helper
        :: IntersectionDifference a b
        -> These a a
        -> IntersectionDifference a b
    helper
        result@IntersectionDifference {excessFirst}
        (This first)
      = result {excessFirst = first : excessFirst}
    helper
        result@IntersectionDifference {excessSecond}
        (That second)
      = result {excessSecond = second : excessSecond}
    helper
        result@IntersectionDifference{intersection}
        (These first second)
      = result {intersection = merger first second : intersection}

{- | Renormalize builtin types after substitution.
 -}
renormalizeBuiltins
    :: InternalVariable variable
    => TermLike variable -> TermLike variable
renormalizeBuiltins =
    Recursive.fold $ \base@(attrs :< termLikeF) ->
    let bottom' = mkBottom (Attribute.Pattern.patternSort attrs) in
    case termLikeF of
        BuiltinF (Builtin.BuiltinMap internalMap) ->
            Lens.traverseOf (field @"builtinAcChild") Ac.renormalize internalMap
            & maybe bottom' mkBuiltinMap
        BuiltinF (Builtin.BuiltinSet internalSet) ->
            Lens.traverseOf (field @"builtinAcChild") Ac.renormalize internalSet
            & maybe bottom' mkBuiltinSet
        _ -> Recursive.embed base
