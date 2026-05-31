////////////////////////////////////////////////////////////////////////////////
// Weighted first-stage neighboring-pair butterfly network.
//
// This module treats one incoming sample stream as a sequence of neighboring
// pairs:
//   pair 0: sample[0], sample[1]
//   pair 1: sample[2], sample[3]
//   pair 2: sample[4], sample[5]
//   ...
//
// It also consumes one packed weight word beside every input sample. The upper
// half of weight_i is that sample's contribution weight for y0, and the lower
// half is that sample's contribution weight for y1.
//
// For each pair, it computes:
//   y0 = sample[even] * weight[even].y0 + sample[odd] * weight[odd].y0
//   y1 = sample[even] * weight[even].y1 + sample[odd] * weight[odd].y1
//
// With the default parameters, weight_i is a 14-bit ASG sample containing two
// signed 7-bit Q1.6 weights:
//   weight_i[13:7] = y0 weight
//   weight_i[ 6:0] = y1 weight
//
// Outputs update when the second sample of each pair arrives, then hold until
// the next pair is complete. In the current top-level integration, sample_i
// comes from ASG channel A and weight_i comes from ASG channel B.
////////////////////////////////////////////////////////////////////////////////

module butterfly_network #(
  parameter int unsigned IN_DW  = 14,
  parameter int unsigned OUT_DW = 14,
  parameter int unsigned WEIGHT_DW   = 7,
  parameter int unsigned WEIGHT_FRAC = 6
)(
  input  logic                         clk_i,
  input  logic                         rstn_i,

  input  logic signed [IN_DW-1:0]      sample_i,
  input  logic signed [2*WEIGHT_DW-1:0] weight_i,

  output logic signed [OUT_DW-1:0]     y0_o,
  output logic signed [OUT_DW-1:0]     y1_o
);

  localparam int unsigned PROD_DW = IN_DW + WEIGHT_DW;
  localparam int unsigned ACC_DW  = PROD_DW + 1;

  // first_sample stores the even-indexed sample in each pair. The matching
  // first_weight_* registers store the packed weights that arrived with it.
  logic                            pair_phase;
  logic signed [IN_DW-1:0]         first_sample;
  logic signed [WEIGHT_DW-1:0]     first_weight_y0;
  logic signed [WEIGHT_DW-1:0]     first_weight_y1;

  logic signed [WEIGHT_DW-1:0]     weight_y0;
  logic signed [WEIGHT_DW-1:0]     weight_y1;
  logic signed [PROD_DW-1:0]       prod_first_y0;
  logic signed [PROD_DW-1:0]       prod_second_y0;
  logic signed [PROD_DW-1:0]       prod_first_y1;
  logic signed [PROD_DW-1:0]       prod_second_y1;
  logic signed [ACC_DW-1:0]        acc_y0;
  logic signed [ACC_DW-1:0]        acc_y1;
  logic signed [ACC_DW-1:0]        scaled_y0;
  logic signed [ACC_DW-1:0]        scaled_y1;

  function automatic logic signed [PROD_DW-1:0] mul_sample_weight;
    input logic signed [IN_DW-1:0]     sample;
    input logic signed [WEIGHT_DW-1:0] weight;
    logic signed [PROD_DW-1:0]         sample_ext;
    logic signed [PROD_DW-1:0]         weight_ext;
    logic signed [2*PROD_DW-1:0]       product_ext;
    begin
      sample_ext  = {{WEIGHT_DW{sample[IN_DW-1]}}, sample};
      weight_ext  = {{IN_DW{weight[WEIGHT_DW-1]}}, weight};
      product_ext = sample_ext * weight_ext;
      mul_sample_weight = product_ext[PROD_DW-1:0];
    end
  endfunction

  function automatic logic signed [OUT_DW-1:0] sat_to_out;
    input logic signed [ACC_DW-1:0] value;
    logic signed [ACC_DW-1:0] max_value;
    logic signed [ACC_DW-1:0] min_value;
    begin
      max_value = $signed({1'b0, {(OUT_DW-1){1'b1}}});
      min_value = $signed({1'b1, {(OUT_DW-1){1'b0}}});

      if (value > max_value) begin
        sat_to_out = max_value[OUT_DW-1:0];
      end else if (value < min_value) begin
        sat_to_out = min_value[OUT_DW-1:0];
      end else begin
        sat_to_out = value[OUT_DW-1:0];
      end
    end
  endfunction

  always_comb begin
    weight_y0 = weight_i[(2*WEIGHT_DW)-1 -: WEIGHT_DW];
    weight_y1 = weight_i[WEIGHT_DW-1:0];

    prod_first_y0  = mul_sample_weight(first_sample, first_weight_y0);
    prod_second_y0 = mul_sample_weight(sample_i,      weight_y0);
    prod_first_y1  = mul_sample_weight(first_sample, first_weight_y1);
    prod_second_y1 = mul_sample_weight(sample_i,      weight_y1);

    acc_y0 = {prod_first_y0[PROD_DW-1], prod_first_y0}
           + {prod_second_y0[PROD_DW-1], prod_second_y0};
    acc_y1 = {prod_first_y1[PROD_DW-1], prod_first_y1}
           + {prod_second_y1[PROD_DW-1], prod_second_y1};

    // Arithmetic right shift converts the Q1.6 products back to sample scale.
    scaled_y0 = acc_y0 >>> WEIGHT_FRAC;
    scaled_y1 = acc_y1 >>> WEIGHT_FRAC;
  end

  always_ff @(posedge clk_i) begin
    if (!rstn_i) begin
      pair_phase     <= 1'b0;
      first_sample   <= '0;
      first_weight_y0 <= '0;
      first_weight_y1 <= '0;
      y0_o           <= '0;
      y1_o           <= '0;
    end else begin
      if (!pair_phase) begin
        first_sample    <= sample_i;
        first_weight_y0 <= weight_y0;
        first_weight_y1 <= weight_y1;
        pair_phase      <= 1'b1;
      end else begin
        y0_o       <= sat_to_out(scaled_y0);
        y1_o       <= sat_to_out(scaled_y1);
        pair_phase <= 1'b0;
      end
    end
  end

endmodule: butterfly_network
