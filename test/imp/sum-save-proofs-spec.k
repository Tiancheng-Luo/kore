// Copyright (c) 2016-2018 K Team. All Rights Reserved.


module VERIFICATION
  imports IMP

// verification ids
  syntax Id ::= "n"     [token]
              | "sum"   [token]
endmodule


module SUM-SAVE-PROOFS-SPEC
  imports IMP
  imports VERIFICATION


rule
    <k>
      while (!(n <= 0)) {
        sum = sum + n + n;
        n = n + -1;
      }
    =>
      .K
    ...</k>
  <state>
      n   |-> (N:Int => 0)
      sum |-> (S:Int => S +Int ((N +Int 1) *Int N))
  </state>
requires N >=Int 0

rule
    <k>
      int n, sum;
      n = N:Int;
      sum = 0;
      while (!(n <= 0)) {
        sum = sum + n + n;
        n = n + -1;
      }
    =>
      .K
    </k>
  <state>
    .Map
  =>
      n   |-> 0
      // Broken, it should be sum |-> ((N +Int 1) *Int N)
      sum |-> ((N +Int 2) *Int N)
  </state>
requires N >=Int 0
endmodule
