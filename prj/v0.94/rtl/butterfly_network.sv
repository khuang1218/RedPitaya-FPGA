////////////////////////////////////////////////////////////////////////////////
// RAM-backed weighted first-stage neighboring-pair butterfly network.
//
// This module first captures one vector from the incoming ASG streams into
// local FPGA RAM, then runs one complete neighboring-pair butterfly stage from
// RAM to RAM:
//   pair 0: sample[0], sample[1]
//   pair 1: sample[2], sample[3]
//   pair 2: sample[4], sample[5]
//   ...
//
// ASG channel A supplies input vector samples. ASG channel B supplies one packed
// weight word beside every input sample. The upper half of weight_i is that
// sample's contribution weight for y0, and the lower half is that sample's
// contribution weight for y1.
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
// After the vector has been captured and computed, the outputs play back one
// computed pair per clock and loop over the completed first-stage result.
////////////////////////////////////////////////////////////////////////////////

module butterfly_network #(
  parameter int unsigned IN_DW  = 14,
  parameter int unsigned OUT_DW = 14,
  parameter int unsigned WEIGHT_DW   = 7,
  parameter int unsigned WEIGHT_FRAC = 6,
  parameter int unsigned VECTOR_LEN  = 1024
)(
  input  logic                         clk_i,
  input  logic                         rstn_i,
  input  logic                         start_i,
  input  logic                         input_valid_i,

  input  logic signed [IN_DW-1:0]      sample_i,
  input  logic signed [2*WEIGHT_DW-1:0] weight_i,

  output logic signed [OUT_DW-1:0]     y0_o,
  output logic signed [OUT_DW-1:0]     y1_o
);

  localparam int unsigned PROD_DW = IN_DW + WEIGHT_DW;
  localparam int unsigned ACC_DW  = PROD_DW + 1;
  localparam int unsigned PAIR_COUNT = VECTOR_LEN / 2;
  localparam int unsigned ADDR_W = (VECTOR_LEN <= 2) ? 1 : $clog2(VECTOR_LEN);
  localparam int unsigned PAIR_ADDR_W = (PAIR_COUNT <= 1) ? 1 : $clog2(PAIR_COUNT);
  localparam logic [ADDR_W-1:0] LAST_CAPTURE_ADDR = VECTOR_LEN - 1;
  localparam logic [PAIR_ADDR_W-1:0] LAST_PAIR_ADDR = PAIR_COUNT - 1;

  typedef enum logic [2:0] {
    ST_IDLE,
    ST_CAPTURE,
    ST_COMPUTE_READ,
    ST_COMPUTE_WRITE,
    ST_PLAYBACK
  } state_t;

  state_t state;

  logic signed [IN_DW-1:0]          sample_ram [0:VECTOR_LEN-1];
  logic signed [2*WEIGHT_DW-1:0]    weight_ram [0:VECTOR_LEN-1];
  logic signed [OUT_DW-1:0]         y0_ram     [0:PAIR_COUNT-1];
  logic signed [OUT_DW-1:0]         y1_ram     [0:PAIR_COUNT-1];

  logic [ADDR_W-1:0]                capture_addr;
  logic [PAIR_ADDR_W-1:0]           compute_pair_addr;
  logic [PAIR_ADDR_W-1:0]           playback_pair_addr;
  logic [ADDR_W-1:0]                compute_even_addr;
  logic [ADDR_W-1:0]                compute_odd_addr;

  logic signed [IN_DW-1:0]          first_sample;
  logic signed [IN_DW-1:0]          second_sample;
  logic signed [2*WEIGHT_DW-1:0]    first_weight;
  logic signed [2*WEIGHT_DW-1:0]    second_weight;

  logic signed [WEIGHT_DW-1:0]     first_weight_y0;
  logic signed [WEIGHT_DW-1:0]     first_weight_y1;
  logic signed [WEIGHT_DW-1:0]     second_weight_y0;
  logic signed [WEIGHT_DW-1:0]     second_weight_y1;
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
    compute_even_addr = compute_pair_addr << 1;
    compute_odd_addr  = compute_even_addr + 1'b1;

    first_weight_y0  = first_weight[(2*WEIGHT_DW)-1 -: WEIGHT_DW];
    first_weight_y1  = first_weight[WEIGHT_DW-1:0];
    second_weight_y0 = second_weight[(2*WEIGHT_DW)-1 -: WEIGHT_DW];
    second_weight_y1 = second_weight[WEIGHT_DW-1:0];

    prod_first_y0  = mul_sample_weight(first_sample, first_weight_y0);
    prod_second_y0 = mul_sample_weight(second_sample, second_weight_y0);
    prod_first_y1  = mul_sample_weight(first_sample, first_weight_y1);
    prod_second_y1 = mul_sample_weight(second_sample, second_weight_y1);

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
      state              <= ST_IDLE;
      capture_addr       <= '0;
      compute_pair_addr  <= '0;
      playback_pair_addr <= '0;
      first_sample       <= '0;
      second_sample      <= '0;
      first_weight       <= '0;
      second_weight      <= '0;
      y0_o               <= '0;
      y1_o               <= '0;
    end else begin
      case (state)
        ST_IDLE: begin
          if (start_i) begin
            capture_addr       <= '0;
            compute_pair_addr  <= '0;
            playback_pair_addr <= '0;
            state              <= ST_CAPTURE;
          end
        end

        ST_CAPTURE: begin
          if (input_valid_i) begin
            sample_ram[capture_addr] <= sample_i;
            weight_ram[capture_addr] <= weight_i;

            if (capture_addr == LAST_CAPTURE_ADDR) begin
              capture_addr      <= '0;
              compute_pair_addr <= '0;
              state             <= ST_COMPUTE_READ;
            end else begin
              capture_addr <= capture_addr + 1'b1;
            end
          end
        end

        ST_COMPUTE_READ: begin
          first_sample  <= sample_ram[compute_even_addr];
          second_sample <= sample_ram[compute_odd_addr];
          first_weight  <= weight_ram[compute_even_addr];
          second_weight <= weight_ram[compute_odd_addr];
          state         <= ST_COMPUTE_WRITE;
        end

        ST_COMPUTE_WRITE: begin
          y0_ram[compute_pair_addr] <= sat_to_out(scaled_y0);
          y1_ram[compute_pair_addr] <= sat_to_out(scaled_y1);

          if (compute_pair_addr == LAST_PAIR_ADDR) begin
            compute_pair_addr  <= '0;
            playback_pair_addr <= '0;
            state              <= ST_PLAYBACK;
          end else begin
            compute_pair_addr <= compute_pair_addr + 1'b1;
            state             <= ST_COMPUTE_READ;
          end
        end

        ST_PLAYBACK: begin
          if (start_i) begin
            capture_addr       <= '0;
            compute_pair_addr  <= '0;
            playback_pair_addr <= '0;
            state              <= ST_CAPTURE;
          end else begin
          y0_o <= y0_ram[playback_pair_addr];
          y1_o <= y1_ram[playback_pair_addr];

          if (playback_pair_addr == LAST_PAIR_ADDR) begin
            playback_pair_addr <= '0;
          end else begin
            playback_pair_addr <= playback_pair_addr + 1'b1;
          end
          end
        end

        default: begin
          state <= ST_IDLE;
        end
      endcase
      end
  end

endmodule: butterfly_network
