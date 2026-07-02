// Known-malformed Verilog: unterminated module / dangling operator / missing
// endmodule. pform_parse MUST report at least one error (non-zero error_count).
module broken (input wire a, output reg b
   assign b = a +++ ;
   always @(* begin
      b <=
   end
