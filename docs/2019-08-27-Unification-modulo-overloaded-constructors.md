Unification/matching modulo overloaded constructors
===================================================

Summary
-------

Proposal:

1. Identify overloaded constructors and overloading axioms by collecting and
   structuring the `overload` attributes of axioms
1. Simplify terms using the overloading axioms to push injections towards top
1. Solve most unification/matching problems by using regular constructor
   non-confusion rules, treating overloaded constructors as constructor-like.
1. Use overload attributes to handle the special case of overloaded constructor
   vs. injection

Background
----------

K allows overloading of operators by associating the same label to multiple
productions.  Example (derived from the [K WASM semantics](https://github.com/kframework/wasm-semantics)):

```
    syntax IValType ::= "i32" | "i64"
    syntax FValType ::= "f32" | "f64"
    syntax AValType ::= IValType | FValType
    syntax Number ::= Int | Float
    syntax IVal ::= "<" IValType ">" Int    [klabel(<_>_)]
    syntax FVal ::= "<" FValType ">" Float  [klabel(<_>_)]
    syntax  Val ::= "<" AValType ">" Number [klabel(<_>_)]
                  | IVal | FVal
```

Here the `klabel` annotations allow for the `Val ::= "<" AValType ">" Number`
production to encompass both `IVal` and `FVal` productions and to be used to
construct terms referring to both of them (as well as to proper `Val`s).

This is K's way to deal with overloading.  An additional restriction imposed by
K implementations is that of __SingleOverloadPerSort__:

> Given sort `s` and label `l` there exists at most one production of result
sort `s` annotated with `klabel(l)`.

TODO: check that the above restriction holds

To capture the relation between these constructors, the K to KORE compilation
pipeline, while keeping the associated labels distinct, generates overloading
axioms of the form:

```
< inj{IValType, AValType}(IT:IValType) > inj{Int, Number}(I:Int)
  = inj{IVal,Val}(< IT:IValType > I:Int) 
  [overload('<_>__AValType_Number_Val, '<_>__IValType_Int_IVal)]

< inj{FValType, AValType}(FT:FValType) > inj{Float, Number}(F:Float)
  = inj{FVal,Val}(< FT:FValType > F:Float) 
  [overload('<_>__AValType_Number_Val, '<_>__FValType_Float_FVal)]
```

Note that, given the pair of overloaded symbols, these axioms can be
automatically inferred. To assist tooling, the compilation process
annotates these generated axioms with an `overload` attribute
having the two symbols involved as arguments.

Problems
--------

Although overloading introduces a higher degree of modularization through
some form of subtype-polymorphism, it puts a higher burden on the
unification/matching procedure.

1. Due to axioms like the above being generated, the overloaded constructors
   are no longer proper constructors and therefore are not marked as such,
   which hinders unification/matching, given that usually the lhs of a rule is
   expected to be constructor-based. This is especially bad because it also
   makes disproving of unification harder and thus generates more (im)possible
   constrainted solutions.

2. Unification of these constructs needs to be performed modulo overloading
   axioms like the ones above.

Proposed solution
-----------------

First observation is that although overloaded constructors are not proper
constructors, they behave as such in most instances: they are injective, so
no-confusion-same-constructor applies naturally, but also they are subject to
most no-confusion-different-constructors rules.  Indeed, due to the
__SingleOverloadPerSort__ constraint, the only confusion possible for an
oveloaded operation is that with an injection operation as given by the
overloading axioms.

### Decision 1

Hence, the proposed solution for handling problem (1) specified above is to
detect overloaded constructors from the `overload` annotations associated to the
overloading axioms and to and use that information in the unification/matching
algorithm, handling overloaded constructors as constructor-like symbols.

For the second problem, the issue comes from the fact that the unifying modulo
the overloading axioms might require applying them either way (left-to-right or
right-to-left).

One advantage of left-to-right application of overloading axioms is that it
helps computing the lowest sort for a term.

### Example

For example, consider lists of
expressions overloaded by lists of values as in
[SIMPLE](https://github.com/kframework/k/blob/master/k-distribution/tutorial/2_languages/1_simple/1_untyped/simple-untyped.k):

```
  syntax Exps ::= List{Exp,","}          [strict]  // automatically hybrid now
  syntax Vals ::= List{Val,","}
```

Consider the definition of `Val`ues (including `lambda`), the syntax for
function call, and the function call rule itself:

```
  syntax Exp ::= Exp "(" Exps ")"        [strict]

  syntax Val ::= Int | Bool | String
               | array(Int,Int)
               | lambda(Ids,Stmt)
  syntax Exp ::= Val
  syntax Exps ::= Vals

  rule <k> lambda(Xs,S)(Vs:Vals) ~> K => mkDecls(Xs,Vs) S return; </k>
       <control>
         <fstack> .List => ListItem((Env,K,C)) ...</fstack>
         C
       </control>
       <env> Env => GEnv </env>
       <genv> GEnv </genv>
```

The rule above requires that the second argument of the application expression
(which should be a list of expressions, is actually a list of values).
For example, if overloading axioms are applied left-to-right, then the term

```
(1) inj{Int,Exp}(3), inj{Int,Exp}(7), inj{Val,Exp}(lambda(.Ids, skip)), .Exps
```

would be simplified to

```
inj{Vals, Exps}(inj{Int, Val}(3), inj{Int, Val}(7), lambda(.Ids, skip), .Vals)
```

which would alow for it to be direcly matched by `inj{Vals, Exps}(Vs:Vals)`.

However, if the rules were to be applied from right to left, then the normalized
term would look as the expression (1) above, and it would be much harder to
unify it with `inj{Vals, Exps}(Vs:Vals)`.

### Decision 2

Based on the example presented above, we will keep the term normalized by
applying the overloading axioms in a left-to-right fashion.

### Unification/matching cases

- overloaded constructor vs. same overloaded constructor: works the same as for
  other constructors, as overloaded constructors are injective
- overloaded constructor vs. different (overloaded) constructor: 
  return bottom, similarly to the other constructors
- overloaded constructor vs. injection of (overloaded) constructor 
  + If the two constructors form an `overload` pair, then use the sorting
    information for the two overloaded constructors to directly derive the new
    goals (apply the overload axiom right-to-left on the right and retry)
  + otherwise, return bottom, as the constructors are incompatible
- `\inj{S1,injTo}(firstHead(firstChildren)) ∧ \inj{S2,injTo}(secondHead(secondChildren))` 
  + If there exists a common overloaded constructor `headUnion` overloading both
    constructors, such that 

        \inj{S1,injTo}(firstHead(firstChildren)) =
          \inj{S,injTo}(headUnion(inj1(firstChildren)))

    and 

        inj{S2,injTo}(secondHead(secondChildren)) =
          inj{S,injTo}(headUnion(inj2(secondChildren)))

    then apply the overload axioms right-to-left to get both terms to use
    the common overloaded constructor and retry with

        \inj{S,injTo}(headUnion(inj1(firstChildren)))
        ∧
        \inj{S,injTo}(headUnion(inj2(secondChildren)))

  + otherwise, return bottom, as the constructors are incompatible
- `c1(overloadingChildren) ∧ \inj{s2,injTo}(x2)`
  1. Find a constructor `c2'` overloaded by `c1` whose sort `s2'` is at most
     `s2`, satisfying the overloading equation

         inj{s2',injTo}(c2'(freshVars)) = c1(inj2(freshVars))

     - If there are more, pick the one overloading all the others.
     - If cannot compute one overloading all the others, we cannot decide which
       to choose and decide not to handle the case (ambiguity).
  1. narrow `x2` to `\inj{s2',s2}(c2'(freshVars))` where `freshVars` are
     fresh
  1. apply the right-to-left overloading axiom to transform `c2'` into `c1`
     reducing the unification problem to

         c1(overloadingChildren)  ∧ c1(inj2(freshVars))

  1. hope that the new unification returns bottom; if not build the conjunction
     of the result with the equality for `x2` and existentially quantify them
     using `freshVars`
- `\inj{s1,s}(c1(children1)) ∧ \inj{s2,s}(x2)`

  1. For each constructor `c1'` overloading `c1` whose sort `s1'` is
     at most `s`, find a constructor `c2'` overloaded by `c1'` whose sort `s2'`
     is at most `s2` with overloading equations
     
         \inj{s1,s}(c1(children1)) = \inj{s1',s}(c1'(inj1(children1)))
     
     and

         \inj{s2',s}(c2'(freshVars)) = \inj{s1', s}(c1'(inj2(freshVars)))

     - If there are more such `c2'`, pick the one overloading all the others.
     - If cannot compute one overloading all the others, we cannot decide which
       to choose and decide not to handle the case (ambiguity).
  1. narrow `x2` to `\inj{s2',s2}(c2'(freshVars))` where `freshVars` are fresh
  1. apply the right-to-left overloading axioms to transform `c1` into `c1'` and
     `c2'` into `c1'`, reducing the unification problem to

         \inj{s1',s}(c1'(inj1(children1))) ∧ \inj{s1',s}(c1'(inj2(freshVars)))

  1. hope that the new unification returns bottom; if not build the conjunction
     of the result with the equality for `x2` and existentially quantify them
     using `freshVars`
   
- otherwise, for now, throw an unsupported exception, as this
  would prevent increasing the number of variable and possible decompositions

#### Example 1

Assume we have two subsorted / overloaded lists and a definition of length

```
syntax Exp ::= Int | Exp "+" Exp | ...
syntax Ints ::= List{Int, ","}
syntax Exps ::= List{Exp, ","}
syntax Exps ::= Ints // overloading

syntax Int ::= length(Exps) [function]
rule length(.Exps) => 0
rule length((_:Exp, Es:Exps)) => lenght(Es)
```

Say now we'd like to apply this function on a list of integers, which, after
being normalized using the overloading axioms, would look as:
`length(inj{Ints, Exps}(1,2,.Ints))`.

This reduces to matching `inj{Ints, Exps}(1,2,.Ints)` with the pattern
`(_:Exp, Es:Exps)`. By noting that the list constructor on top of the 
pattern and the list constructor below the inj form an overload pair,
we can transform the pattern to be matched to 
`inj{Int,Exp}(1), inj{Ints, Exps}(2, .Ints)`, after which the matching becomes
possible and generates the substitution In the Name of the Grandfather

```
_:Exp = inj{int,Exp}(1)
Es:Exps = inj{Ints, Exps}(2, .Ints)
```

#### Example 2

Assume we have the following list definitions:

```
  syntax Exp ::= Val
  syntax Exp ::= Exp "+" Exp             [strict]
  syntax Exp ::= "[" Exps "]"            [strict]
  syntax Exps ::= List{Exp,","}          [klabel(_,_), strict]

  syntax Val ::= Int
  syntax Vals ::= List{Val,","}          [klabel(_,_), strict]
  syntax Exps ::= Vals

  syntax KResult ::= Val | Vals
```

and consider the rules for `isKResult`:

```
isKResult(\inj{KResult, KItem}(R:KResult)) => true
isKResult(K:KItem) => false [owise]
```

Suppose now one wants to check whether the list `1, 1 + 1` is a `KResult`.

Its representation in KORE is of the form
`\inj{Exps, KItem}(ExpsCons(\inj{Val, Exp}(1), ExpsCons(1 + 1, \inj{Vals, Exps}(.Vals))))`

In order to apply the `owise` rule for `KResult`, one must compute 

`\not(\ceil(\inj{Exps, KItem}(ExpsCons(\inj{Int, Exp}(1), ExpsCons(1 + 1, \inj{Vals, Exps}(.Vals)))) ∧ \inj{KResult, KItem}(R:KResult)))`

At this moment, the narrowing kicks in (`unifyOverloadingVsOverloadedVariable`),
and it could narrow `R:KResult` to `inj{Vals, KResult}(ValsCons(V:Val, Vs:Vals))`,
then reattempt unification between
  `inj{Exps, KItem}(ExpsCons(inj{Int, Exp}(1), ExpsCons(1 + 1, inj{Vals, Exps}(.Vals))))` and
  `inj{Vals, KItem}(ValsCons(V:Val, Vs:Vals))`,
where the latter can be transformed to 
  `inj{Exps, KItem}(ExpCons(inj{Val,Exp}(V:Val), inj{Vals, Exps}(Vs:Vals)))`
This unification reduces to `V =  \inj{Int, Val}(1)` and with
`ExpsCons(1 + 1, inj{Vals, Exps}(.Vals))` unified to ` inj{Vals, Exps}(Vs:Vals)`

Applying again narrowing (this time `unifyOverloadingInjVsVariable`) we narrow
`Vs:Vals` to `ValsCons(V':Val, Vs':Vals)` and use overloading to attempt
unification  between `ExpsCons(1 + 1, inj{Vals, Exps}(.Vals))` and
`inj{Vals, Exps}(ValsCons(V':Val, Vs':Vals))`, which gets to `1 + 1` being
unified with `\inj{Val, Exp}(V':Val)`, which fails, returning `\bottom`.

Thus, `\not(\ceil(\inj{Exps, KItem}(ExpsCons(\inj{Val, Exp}(1), ExpsCons(1 + 1, \inj{Vals, Exps}(.Vals)))) ∧ \inj{KResult, KItem}(R:KResult)))`
simplifies to `\not(\ceil(\bottom))`, which is `\top`, thus making `isKresult`
evaluate to `false`.
