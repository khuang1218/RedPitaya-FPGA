`timescale 1ns/1ps
// Controller integration test ONLY. Never add this model to a Vivado fileset.
// It supplies an ideal half-filled thermometer and does not model carry delay,
// metastability, code density, placement, calibration accuracy, or resolution.
module tdc_carry_chain #(
  parameter integer NUM_CARRY4=4, NUM_TAPS=NUM_CARRY4*4,
  parameter bit INVERT_TAPS=0
)(input clk_i,rstn_i,event_i,output reg [NUM_TAPS-1:0] sampled_taps_o);
  localparam [NUM_TAPS-1:0] HALF = {NUM_TAPS{1'b1}} >> (NUM_TAPS/2);
  always @(posedge clk_i)
    if(!rstn_i) sampled_taps_o <= '0;
    else sampled_taps_o <= event_i ? (INVERT_TAPS ? ~HALF : HALF) : '0;
endmodule
