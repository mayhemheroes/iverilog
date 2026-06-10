// Known-good Verilog: a small but non-trivial module exercising ports,
// continuous assign, an always block, and an instantiation. Must parse with
// zero errors through pform_parse.
module counter (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        en,
    output reg  [7:0]  count,
    output wire        carry
);

   assign carry = (count == 8'hFF) & en;

   always @(posedge clk or negedge rst_n) begin
      if (!rst_n)
        count <= 8'h00;
      else if (en)
        count <= count + 8'h01;
   end

endmodule

module top;
   wire        clk, rst_n, en, carry;
   wire [7:0]  count;

   counter u_counter (
       .clk   (clk),
       .rst_n (rst_n),
       .en    (en),
       .count (count),
       .carry (carry)
   );

   initial begin
      $display("count=%0d carry=%b", count, carry);
   end
endmodule
