////////////////////////////////////////////////////////////////////////////////
// Simple 2-input butterfly network.
//
// First milestone behavior:
//   y0 = (x0 + x1) / 2
//   y1 = (x0 - x1) / 2
//
// The divide-by-2 is a fixed normalization step. Adding or subtracting two
// full-scale signed samples needs one extra bit, so scaling the result back
// down by one bit prevents overflow without clipping peaks flat.
//
// This is a small, synchronous building block intended to sit in a sample
// stream path before the DAC output path. In the current top-level integration,
// x0_i and x1_i come from the two ASG waveform streams loaded by software.
// It does not include twiddle factors yet; those can be added later when
// expanding this into an FFT-style butterfly network.
////////////////////////////////////////////////////////////////////////////////

module butterfly_network #(
  parameter int unsigned IN_DW  = 14,
  parameter int unsigned OUT_DW = 14
)(
  input  logic                         clk_i,
  input  logic                         rstn_i,

  input  logic signed [IN_DW-1:0]      x0_i,
  input  logic signed [IN_DW-1:0]      x1_i,

  output logic signed [OUT_DW-1:0]     y0_o,
  output logic signed [OUT_DW-1:0]     y1_o
);

  // Addition/subtraction of two IN_DW-bit signed numbers needs one extra bit.
  logic signed [IN_DW:0] sum;
  logic signed [IN_DW:0] diff;
  logic signed [IN_DW:0] sum_norm;
  logic signed [IN_DW:0] diff_norm;

  always_comb begin
    sum  = {x0_i[IN_DW-1], x0_i} + {x1_i[IN_DW-1], x1_i};
    diff = {x0_i[IN_DW-1], x0_i} - {x1_i[IN_DW-1], x1_i};

    // Arithmetic right shift keeps the sign bit, so negative values divide
    // correctly in two's-complement hardware.
    sum_norm  = sum  >>> 1;
    diff_norm = diff >>> 1;
  end

  always_ff @(posedge clk_i) begin
    if (!rstn_i) begin
      y0_o <= '0;
      y1_o <= '0;
    end else begin
      y0_o <= sum_norm[OUT_DW-1:0];
      y1_o <= diff_norm[OUT_DW-1:0];
    end
  end

endmodule: butterfly_network
