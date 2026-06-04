////////////////////////////////////////////////////////////////////////////////
// RAM-backed staged fixed-point butterfly network.
//
// The engine is intentionally serial and testable:
//   1. Capture VECTOR_LEN input samples.
//   2. Capture STAGE_COUNT * VECTOR_LEN packed weight words.
//   3. Run all butterfly stages from RAM bank to RAM bank.
//   4. Play the final vector to DAC A/B two samples at a time.
//
// For each stage and each butterfly pair (a,b), the packed weight beside each
// input sample contains two signed fixed-point weights:
//
//   weight[2*WEIGHT_DW-1:WEIGHT_DW] = contribution to output a'
//   weight[WEIGHT_DW-1:0]           = contribution to output b'
//
// The butterfly computes:
//
//   a' = a * wa_a + b * wb_a
//   b' = a * wa_b + b * wb_b
//
// Default weights are Q1.6 and samples/results are signed 14-bit.
////////////////////////////////////////////////////////////////////////////////

module butterfly_network #(
  parameter int unsigned IN_DW       = 14,
  parameter int unsigned OUT_DW      = 14,
  parameter int unsigned WEIGHT_DW   = 7,
  parameter int unsigned WEIGHT_FRAC = 6,
  parameter int unsigned VECTOR_LEN  = 1024
)(
  input  logic                          clk_i,
  input  logic                          rstn_i,
  input  logic                          start_i,

  input  logic                          sample_valid_i,
  output logic                          sample_ready_o,
  input  logic signed [IN_DW-1:0]       sample_i,

  input  logic                          weight_valid_i,
  output logic                          weight_ready_o,
  input  logic signed [2*WEIGHT_DW-1:0] weight_i,

  output logic signed [OUT_DW-1:0]      y0_o,
  output logic signed [OUT_DW-1:0]      y1_o,
  output logic                          output_valid_o,
  output logic                          busy_o,
  output logic                          done_o
);

  localparam int unsigned STAGE_COUNT = (VECTOR_LEN <= 1) ? 1 : $clog2(VECTOR_LEN);
  localparam int unsigned PAIR_COUNT = VECTOR_LEN / 2;
  localparam int unsigned TOTAL_WEIGHTS = STAGE_COUNT * VECTOR_LEN;
  localparam int unsigned ADDR_W = (VECTOR_LEN <= 2) ? 1 : $clog2(VECTOR_LEN);
  localparam int unsigned STAGE_W = (STAGE_COUNT <= 1) ? 1 : $clog2(STAGE_COUNT);
  localparam int unsigned PAIR_W = (PAIR_COUNT <= 1) ? 1 : $clog2(PAIR_COUNT);
  localparam int unsigned WEIGHT_ADDR_W = (TOTAL_WEIGHTS <= 2) ? 1 : $clog2(TOTAL_WEIGHTS);
  localparam int unsigned PROD_DW = IN_DW + WEIGHT_DW;
  localparam int unsigned ACC_DW = PROD_DW + 1;

  localparam logic [ADDR_W-1:0] LAST_SAMPLE_ADDR = VECTOR_LEN - 1;
  localparam logic [WEIGHT_ADDR_W-1:0] LAST_WEIGHT_ADDR = TOTAL_WEIGHTS - 1;
  localparam logic [STAGE_W-1:0] LAST_STAGE = STAGE_COUNT - 1;
  localparam logic [PAIR_W-1:0] LAST_PAIR = PAIR_COUNT - 1;

  typedef enum logic [2:0] {
    ST_IDLE,
    ST_LOAD,
    ST_READ,
    ST_WRITE,
    ST_PLAYBACK
  } state_t;

  state_t state;

  (* ram_style = "block" *) logic signed [IN_DW-1:0]       bank0_ram  [0:VECTOR_LEN-1];
  (* ram_style = "block" *) logic signed [IN_DW-1:0]       bank1_ram  [0:VECTOR_LEN-1];
  (* ram_style = "block" *) logic signed [2*WEIGHT_DW-1:0] weight_ram [0:TOTAL_WEIGHTS-1];

  logic [ADDR_W-1:0]                    sample_wr_addr;
  logic [WEIGHT_ADDR_W-1:0]             weight_wr_addr;
  logic                                 samples_loaded;
  logic                                 weights_loaded;

  logic [STAGE_W-1:0]                   stage_idx;
  logic [PAIR_W-1:0]                    pair_idx;
  logic                                 read_bank;
  logic [ADDR_W-1:0]                    addr_a;
  logic [ADDR_W-1:0]                    addr_b;
  logic [WEIGHT_ADDR_W-1:0]             weight_addr_a;
  logic [WEIGHT_ADDR_W-1:0]             weight_addr_b;
  logic [ADDR_W-1:0]                    playback_addr;

  logic signed [IN_DW-1:0]              sample_a;
  logic signed [IN_DW-1:0]              sample_b;
  logic signed [2*WEIGHT_DW-1:0]        weight_a;
  logic signed [2*WEIGHT_DW-1:0]        weight_b;

  logic signed [WEIGHT_DW-1:0]          weight_a_y0;
  logic signed [WEIGHT_DW-1:0]          weight_a_y1;
  logic signed [WEIGHT_DW-1:0]          weight_b_y0;
  logic signed [WEIGHT_DW-1:0]          weight_b_y1;
  logic signed [PROD_DW-1:0]            prod_a_y0;
  logic signed [PROD_DW-1:0]            prod_a_y1;
  logic signed [PROD_DW-1:0]            prod_b_y0;
  logic signed [PROD_DW-1:0]            prod_b_y1;
  logic signed [ACC_DW-1:0]             acc_y0;
  logic signed [ACC_DW-1:0]             acc_y1;
  logic signed [ACC_DW-1:0]             scaled_y0;
  logic signed [ACC_DW-1:0]             scaled_y1;
  logic signed [OUT_DW-1:0]             result_y0;
  logic signed [OUT_DW-1:0]             result_y1;

  function automatic logic signed [PROD_DW-1:0] mul_sample_weight;
    input logic signed [IN_DW-1:0] sample;
    input logic signed [WEIGHT_DW-1:0] weight;
    logic signed [PROD_DW-1:0] sample_ext;
    logic signed [PROD_DW-1:0] weight_ext;
    logic signed [2*PROD_DW-1:0] product_ext;
    begin
      sample_ext = {{WEIGHT_DW{sample[IN_DW-1]}}, sample};
      weight_ext = {{IN_DW{weight[WEIGHT_DW-1]}}, weight};
      product_ext = sample_ext * weight_ext;
      mul_sample_weight = product_ext[PROD_DW-1:0];
    end
  endfunction

  function automatic logic signed [ACC_DW-1:0] round_shift;
    input logic signed [ACC_DW-1:0] value;
    logic signed [ACC_DW-1:0] bias;
    begin
      if (WEIGHT_FRAC == 0) begin
        round_shift = value;
      end else begin
        bias = '0;
        bias[WEIGHT_FRAC-1] = 1'b1;
        round_shift = (value + (value[ACC_DW-1] ? -bias : bias)) >>> WEIGHT_FRAC;
      end
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
    logic [ADDR_W-1:0] half_span;
    logic [ADDR_W-1:0] group_base;
    logic [ADDR_W-1:0] pair_in_group;
    logic [ADDR_W-1:0] pair_idx_addr;
    logic [WEIGHT_ADDR_W-1:0] stage_weight_base;

    half_span = {{(ADDR_W-1){1'b0}}, 1'b1} << stage_idx;
    pair_idx_addr = {{(ADDR_W-PAIR_W){1'b0}}, pair_idx};
    pair_in_group = pair_idx_addr & (half_span - 1'b1);
    group_base = (pair_idx_addr - pair_in_group) << 1;
    addr_a = group_base + pair_in_group;
    addr_b = addr_a + half_span;

    stage_weight_base = {{(WEIGHT_ADDR_W-STAGE_W){1'b0}}, stage_idx} * VECTOR_LEN;
    weight_addr_a = stage_weight_base + {{(WEIGHT_ADDR_W-ADDR_W){1'b0}}, addr_a};
    weight_addr_b = stage_weight_base + {{(WEIGHT_ADDR_W-ADDR_W){1'b0}}, addr_b};

    weight_a_y0 = weight_a[(2*WEIGHT_DW)-1 -: WEIGHT_DW];
    weight_a_y1 = weight_a[WEIGHT_DW-1:0];
    weight_b_y0 = weight_b[(2*WEIGHT_DW)-1 -: WEIGHT_DW];
    weight_b_y1 = weight_b[WEIGHT_DW-1:0];

    prod_a_y0 = mul_sample_weight(sample_a, weight_a_y0);
    prod_a_y1 = mul_sample_weight(sample_a, weight_a_y1);
    prod_b_y0 = mul_sample_weight(sample_b, weight_b_y0);
    prod_b_y1 = mul_sample_weight(sample_b, weight_b_y1);

    acc_y0 = {prod_a_y0[PROD_DW-1], prod_a_y0}
           + {prod_b_y0[PROD_DW-1], prod_b_y0};
    acc_y1 = {prod_a_y1[PROD_DW-1], prod_a_y1}
           + {prod_b_y1[PROD_DW-1], prod_b_y1};

    scaled_y0 = round_shift(acc_y0);
    scaled_y1 = round_shift(acc_y1);
    result_y0 = sat_to_out(scaled_y0);
    result_y1 = sat_to_out(scaled_y1);
  end

  assign sample_ready_o = (state == ST_LOAD) && !samples_loaded;
  assign weight_ready_o = (state == ST_LOAD) && !weights_loaded;
  assign busy_o = (state != ST_IDLE) && (state != ST_PLAYBACK);
  assign output_valid_o = (state == ST_PLAYBACK);

  always_ff @(posedge clk_i) begin
    if (!rstn_i) begin
      state <= ST_IDLE;
      sample_wr_addr <= '0;
      weight_wr_addr <= '0;
      samples_loaded <= 1'b0;
      weights_loaded <= 1'b0;
      stage_idx <= '0;
      pair_idx <= '0;
      read_bank <= 1'b0;
      playback_addr <= '0;
      sample_a <= '0;
      sample_b <= '0;
      weight_a <= '0;
      weight_b <= '0;
      y0_o <= '0;
      y1_o <= '0;
      done_o <= 1'b0;
    end else begin
      done_o <= 1'b0;

      case (state)
        ST_IDLE: begin
          if (start_i) begin
            sample_wr_addr <= '0;
            weight_wr_addr <= '0;
            samples_loaded <= 1'b0;
            weights_loaded <= 1'b0;
            stage_idx <= '0;
            pair_idx <= '0;
            read_bank <= 1'b0;
            playback_addr <= '0;
            state <= ST_LOAD;
          end
        end

        ST_LOAD: begin
          if (!samples_loaded && sample_valid_i) begin
            bank0_ram[sample_wr_addr] <= sample_i;
            if (sample_wr_addr == LAST_SAMPLE_ADDR) begin
              samples_loaded <= 1'b1;
            end else begin
              sample_wr_addr <= sample_wr_addr + 1'b1;
            end
          end

          if (!weights_loaded && weight_valid_i) begin
            weight_ram[weight_wr_addr] <= weight_i;
            if (weight_wr_addr == LAST_WEIGHT_ADDR) begin
              weights_loaded <= 1'b1;
            end else begin
              weight_wr_addr <= weight_wr_addr + 1'b1;
            end
          end

          if ((samples_loaded || (sample_valid_i && (sample_wr_addr == LAST_SAMPLE_ADDR))) &&
              (weights_loaded || (weight_valid_i && (weight_wr_addr == LAST_WEIGHT_ADDR)))) begin
            stage_idx <= '0;
            pair_idx <= '0;
            read_bank <= 1'b0;
            state <= ST_READ;
          end
        end

        ST_READ: begin
          if (!read_bank) begin
            sample_a <= bank0_ram[addr_a];
            sample_b <= bank0_ram[addr_b];
          end else begin
            sample_a <= bank1_ram[addr_a];
            sample_b <= bank1_ram[addr_b];
          end
          weight_a <= weight_ram[weight_addr_a];
          weight_b <= weight_ram[weight_addr_b];
          state <= ST_WRITE;
        end

        ST_WRITE: begin
          if (!read_bank) begin
            bank1_ram[addr_a] <= result_y0;
            bank1_ram[addr_b] <= result_y1;
          end else begin
            bank0_ram[addr_a] <= result_y0;
            bank0_ram[addr_b] <= result_y1;
          end

          if (pair_idx == LAST_PAIR) begin
            pair_idx <= '0;
            if (stage_idx == LAST_STAGE) begin
              playback_addr <= '0;
              read_bank <= ~read_bank;
              done_o <= 1'b1;
              state <= ST_PLAYBACK;
            end else begin
              stage_idx <= stage_idx + 1'b1;
              read_bank <= ~read_bank;
              state <= ST_READ;
            end
          end else begin
            pair_idx <= pair_idx + 1'b1;
            state <= ST_READ;
          end
        end

        ST_PLAYBACK: begin
          if (start_i) begin
            sample_wr_addr <= '0;
            weight_wr_addr <= '0;
            samples_loaded <= 1'b0;
            weights_loaded <= 1'b0;
            stage_idx <= '0;
            pair_idx <= '0;
            read_bank <= 1'b0;
            playback_addr <= '0;
            state <= ST_LOAD;
          end else begin
            if (!read_bank) begin
              y0_o <= bank0_ram[playback_addr];
              y1_o <= bank0_ram[playback_addr + 1'b1];
            end else begin
              y0_o <= bank1_ram[playback_addr];
              y1_o <= bank1_ram[playback_addr + 1'b1];
            end

            if (playback_addr >= LAST_SAMPLE_ADDR - 1'b1) begin
              playback_addr <= '0;
            end else begin
              playback_addr <= playback_addr + 2'd2;
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
