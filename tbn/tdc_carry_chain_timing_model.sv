`timescale 1ns/1ps
// Standalone simulation ONLY. Uniform ideal delays are not physical calibration.
// Never add this replacement module to any Vivado fileset.
module tdc_carry_chain #(
  parameter integer NUM_CARRY4=4, NUM_TAPS=NUM_CARRY4*4,
  parameter bit INVERT_TAPS=0
)(input clk_i,rstn_i,event_i,output reg [NUM_TAPS-1:0] sampled_taps_o);
  wire [NUM_TAPS-1:0] taps;
  for(genvar i=0;i<NUM_TAPS;i=i+1) begin:g
    assign #(0.5*(i+1)) taps[i]=event_i;
  end
  always @(posedge clk_i)
    if(!rstn_i) sampled_taps_o<='0;
    else sampled_taps_o<=INVERT_TAPS ? ~taps : taps;
endmodule
