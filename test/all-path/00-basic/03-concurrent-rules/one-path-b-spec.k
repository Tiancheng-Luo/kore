module VERIFICATION
  imports PATH

endmodule

module ONE-PATH-B-SPEC
  imports VERIFICATION
  imports PATH

  // This should be provable as an one-path claim, but should not be provable as an 
  //all-path claim.
  rule <k> a => c </k> [one-path]

endmodule
