////////////////////////////////////////////////////////////////////////////////
// Basic neighboring-pair butterfly network.
//
// This module treats one incoming sample stream as a sequence of neighboring
// pairs:
//   pair 0: sample[0], sample[1]
//   pair 1: sample[2], sample[3]
//   pair 2: sample[4], sample[5]
//   ...
//
// For each pair, it computes:
//   y0 = (even_sample + odd_sample) / 2
//   y1 = (even_sample - odd_sample) / 2
//
// The divide-by-2 is fixed normalization. A butterfly add/subtract can grow by
// one bit, so scaling down by one bit keeps the result in the original 14-bit
// DAC-friendly range without clipping peaks flat.
//
// Outputs update when the second sample of each pair arrives, then hold until
// the next pair is complete. In the current top-level integration, sample_i
// comes from ASG channel A, which software fills through SCPI/API.
////////////////////////////////////////////////////////////////////////////////

module butterfly_network #(
  parameter int unsigned IN_DW  = 14,
  parameter int unsigned OUT_DW = 14
)(
  input  logic                     clk_i,
  input  logic                     rstn_i,

  input  logic signed [IN_DW-1:0]  sample_i,

  output logic signed [OUT_DW-1:0] y0_o,
  output logic signed [OUT_DW-1:0] y1_o
);

  // first_sample stores the even-indexed sample in each pair. pair_phase tells
  // us whether the next input sample should be stored as the first sample or
  // combined as the second sample.
  logic                         pair_phase;
  logic signed [IN_DW-1:0]      first_sample;
  logic signed [IN_DW:0] sum;
  logic signed [IN_DW:0] diff;
  logic signed [IN_DW:0] sum_norm;
  logic signed [IN_DW:0] diff_norm;

  always_comb begin
    sum  = {first_sample[IN_DW-1], first_sample} + {sample_i[IN_DW-1], sample_i};
    diff = {first_sample[IN_DW-1], first_sample} - {sample_i[IN_DW-1], sample_i};

    // Arithmetic right shift keeps the sign bit, so negative values divide
    // correctly in two's-complement hardware.
    sum_norm  = sum  >>> 1;
    diff_norm = diff >>> 1;
  end

  always_ff @(posedge clk_i) begin
    if (!rstn_i) begin
      pair_phase   <= 1'b0;
      first_sample <= '0;
      y0_o <= '0;
      y1_o <= '0;
    end else begin
      if (!pair_phase) begin
        first_sample <= sample_i;
        pair_phase   <= 1'b1;
      end else begin
        y0_o      <= sum_norm[OUT_DW-1:0];
        y1_o      <= diff_norm[OUT_DW-1:0];
        pair_phase <= 1'b0;
      end
    end
  end

endmodule: butterfly_network
