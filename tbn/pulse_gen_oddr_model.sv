// TEST ONLY: ideal SAME_EDGE ODDR substitute for Icarus/slang.
// Never add this file to Vivado design sources or a bitstream build.
// Vivado simulation must use its actual UNISIM ODDR instead.
`timescale 1ns/1ps
module ODDR #(
  parameter DDR_CLK_EDGE = "SAME_EDGE",
  parameter INIT = 1'b0,
  parameter SRTYPE = "ASYNC"
)(output reg Q = INIT, input C, CE, D1, D2, R, S);
  reg second = INIT;
  initial if (DDR_CLK_EDGE != "SAME_EDGE" || SRTYPE != "ASYNC")
    $fatal(1, "Test model supports only SAME_EDGE/ASYNC");
  always @(posedge C or posedge R or posedge S) begin
    if (R) begin Q <= 0; second <= 0; end
    else if (S) begin Q <= 1; second <= 1; end
    else if (CE) begin Q <= D1; second <= D2; end
  end
  always @(negedge C) begin
    if (R) Q <= 0;
    else if (S) Q <= 1;
    else if (CE) Q <= second;
  end
endmodule
