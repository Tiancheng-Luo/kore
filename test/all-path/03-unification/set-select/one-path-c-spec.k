module VERIFICATION
  imports PATH

endmodule

module ONE-PATH-C-SPEC
  imports VERIFICATION
  imports PATH

  // This should be provable as an one-path claim, but should not be provable as an 
  //all-path claim.
  rule <k> select => b </k>
       <state> SetItem(b) SetItem(c) </state>
    [one-path]

endmodule
