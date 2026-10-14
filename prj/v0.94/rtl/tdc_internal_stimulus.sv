////////////////////////////////////////////////////////////////////////////////
// Hardware-only asynchronous stimulus for CARRY4 TDC self-test.
//
// The source clock is the PS fabric clock, while the TDC sampler uses adc_clk.
// A divided square wave therefore exercises the real placed carry chain without
// requiring an E3 cable or external PCB.  It is not an LVDS electrical test.
////////////////////////////////////////////////////////////////////////////////

(* KEEP_HIERARCHY = "TRUE" *)
module tdc_internal_stimulus #(
  parameter int unsigned DIVIDER_BIT = 10
)(
  input  logic clk_i,
  input  logic rstn_i,
  input  logic enable_async_i,
  output logic event_o
);

  (* ASYNC_REG = "TRUE" *) logic enable_meta;
  (* ASYNC_REG = "TRUE" *) logic enable_sync;
  (* KEEP = "TRUE" *) logic [DIVIDER_BIT:0] divider_counter;

  // Only the enable crosses into this clock domain through a conventional
  // synchronizer. event_o deliberately remains asynchronous to adc_clk.
  always_ff @(posedge clk_i) begin
    if (!rstn_i) begin
      enable_meta <= 1'b0;
      enable_sync <= 1'b0;
    end else begin
      enable_meta <= enable_async_i;
      enable_sync <= enable_meta;
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rstn_i || !enable_sync)
      divider_counter <= '0;
    else
      divider_counter <= divider_counter + 1'b1;
  end

  assign event_o = enable_sync & divider_counter[DIVIDER_BIT];

endmodule: tdc_internal_stimulus

