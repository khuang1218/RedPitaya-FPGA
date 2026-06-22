////////////////////////////////////////////////////////////////////////////////
// Static-weight frame-pipelined butterfly network.
//
// This module is the first fixed-weight hardware path to sit beside the current
// variable-weight training engine. The current butterfly_network.sv still
// accepts a full weight stream every run. This module preloads weights once into
// per-stage BRAMs, then moves input frames through one hardware worker per
// butterfly stage.
//
// Throughput goal:
//   - each stage owns a datapath and output ping-pong frame buffers
//   - different stages may process different frames at the same time
//   - after fill, steady-state frame throughput is bounded by one stage pass,
//     not by all log2(N) passes in one serial FSM
//
// This is a frame pipeline, not yet the final sample-by-sample SDF pipeline.
////////////////////////////////////////////////////////////////////////////////

module butterfly_network_static_pipeline #(
  parameter int unsigned IN_DW       = 14,
  parameter int unsigned OUT_DW      = 14,
  parameter int unsigned WEIGHT_DW   = 7,
  parameter int unsigned WEIGHT_FRAC = 6,
  parameter int unsigned VECTOR_LEN  = 2048
)(
  input  logic                          clk_i,
  input  logic                          rstn_i,
  input  logic                          soft_reset_i,

  input  logic                          weight_load_valid_i,
  output logic                          weight_load_ready_o,
  input  logic signed [2*WEIGHT_DW-1:0] weight_load_i,
  output logic                          weight_load_done_o,

  input  logic                          sample_valid_i,
  output logic                          sample_ready_o,
  input  logic signed [IN_DW-1:0]       sample_i,

  output logic signed [OUT_DW-1:0]      y0_o,
  output logic signed [OUT_DW-1:0]      y1_o,
  output logic                          output_valid_o,
  input  logic                          output_ready_i,

  output logic                          busy_o,
  output logic                          done_o,
  output logic [32-1:0]                 timing_total_cycles_o,
  output logic [32-1:0]                 timing_weight_load_cycles_o,
  output logic [32-1:0]                 timing_input_load_cycles_o,
  output logic [32-1:0]                 timing_latency_cycles_o,
  output logic [32-1:0]                 timing_output_cycles_o
);

  localparam int unsigned STAGE_COUNT = (VECTOR_LEN <= 1) ? 1 : $clog2(VECTOR_LEN);
  localparam int unsigned ADDR_W = (VECTOR_LEN <= 2) ? 1 : $clog2(VECTOR_LEN);
  localparam int unsigned STAGE_W = (STAGE_COUNT <= 1) ? 1 : $clog2(STAGE_COUNT);
  localparam int unsigned TOTAL_WEIGHTS = STAGE_COUNT * VECTOR_LEN;
  localparam int unsigned WEIGHT_ADDR_W = (TOTAL_WEIGHTS <= 2) ? 1 : $clog2(TOTAL_WEIGHTS);

  localparam logic [ADDR_W-1:0] LAST_SAMPLE_ADDR = VECTOR_LEN - 1;
  localparam logic [WEIGHT_ADDR_W-1:0] LAST_WEIGHT_LOAD_ADDR = TOTAL_WEIGHTS - 1;

  logic [WEIGHT_ADDR_W-1:0] weight_load_addr;
  logic [STAGE_W-1:0]       weight_load_stage;
  logic [ADDR_W-1:0]        weight_load_offset;

  assign weight_load_stage = weight_load_addr[ADDR_W +: STAGE_W];
  assign weight_load_offset = weight_load_addr[0 +: ADDR_W];
  assign weight_load_ready_o = !weight_load_done_o;

  logic [ADDR_W-1:0] sample_wr_addr;
  logic              sample_wr_bank;
  logic [2-1:0]      input_frame_valid;

  logic [ADDR_W-1:0] input_addr_a;
  logic [ADDR_W-1:0] input_addr_b;
  logic signed [IN_DW-1:0] input_din_a;
  logic              input_we_a;
  logic signed [IN_DW-1:0] input_bank0_dout_a;
  logic signed [IN_DW-1:0] input_bank0_dout_b;
  logic signed [IN_DW-1:0] input_bank1_dout_a;
  logic signed [IN_DW-1:0] input_bank1_dout_b;

  logic [STAGE_COUNT-1:0] stage_start;
  logic [STAGE_COUNT-1:0] stage_busy;
  logic [STAGE_COUNT-1:0] stage_done;
  logic [STAGE_COUNT-1:0] stage_in_bank;
  logic [STAGE_COUNT-1:0] stage_out_bank;
  logic [STAGE_COUNT-1:0][2-1:0] stage_frame_valid;

  logic [STAGE_COUNT-1:0][ADDR_W-1:0] stage_src_addr_a;
  logic [STAGE_COUNT-1:0][ADDR_W-1:0] stage_src_addr_b;
  logic signed [STAGE_COUNT-1:0][IN_DW-1:0] stage_src_data_a;
  logic signed [STAGE_COUNT-1:0][IN_DW-1:0] stage_src_data_b;

  logic [STAGE_COUNT-1:0]             stage_out_rd_bank;
  logic [STAGE_COUNT-1:0][ADDR_W-1:0] stage_out_rd_addr_a;
  logic [STAGE_COUNT-1:0][ADDR_W-1:0] stage_out_rd_addr_b;
  logic signed [STAGE_COUNT-1:0][OUT_DW-1:0] stage_out_rd_data_a;
  logic signed [STAGE_COUNT-1:0][OUT_DW-1:0] stage_out_rd_data_b;

  logic output_active;
  logic output_bank;
  logic [ADDR_W-1:0] output_addr;
  logic weight_load_active;
  logic input_load_active;
  logic latency_active;
  logic total_active;
  logic [32-1:0] weight_load_cycle_count;
  logic [32-1:0] input_load_cycle_count;
  logic [32-1:0] latency_cycle_count;
  logic [32-1:0] total_cycle_count;
  logic [32-1:0] output_cycle_count;
  logic accepted_weight;
  logic accepted_sample;
  logic first_output_sample;
  logic final_output_sample;

  assign sample_ready_o = weight_load_done_o && !input_frame_valid[sample_wr_bank];
  assign busy_o = output_active || (|stage_busy) || (input_frame_valid != 2'b00) ||
                  (|stage_frame_valid);
  assign accepted_weight = weight_load_valid_i && weight_load_ready_o;
  assign accepted_sample = sample_valid_i && sample_ready_o;
  assign first_output_sample = output_active && output_ready_i && (output_addr == '0);
  assign final_output_sample = output_active && output_ready_i &&
                               (output_addr >= LAST_SAMPLE_ADDR - 1'b1);

  always_comb begin
    input_addr_a = stage_src_addr_a[0];
    input_addr_b = stage_src_addr_b[0];
    input_din_a = sample_i;
    input_we_a = sample_valid_i && sample_ready_o;
  end

  bnet_tdp_ram #(
    .DW    (IN_DW),
    .DEPTH (VECTOR_LEN),
    .AW    (ADDR_W)
  ) i_input_bank0 (
    .clk_i    (clk_i),
    .addr_a_i ((sample_wr_bank == 1'b0) ? sample_wr_addr : input_addr_a),
    .din_a_i  (input_din_a),
    .we_a_i   ((sample_wr_bank == 1'b0) && input_we_a),
    .dout_a_o (input_bank0_dout_a),
    .addr_b_i (input_addr_b),
    .din_b_i  ('0),
    .we_b_i   (1'b0),
    .dout_b_o (input_bank0_dout_b)
  );

  bnet_tdp_ram #(
    .DW    (IN_DW),
    .DEPTH (VECTOR_LEN),
    .AW    (ADDR_W)
  ) i_input_bank1 (
    .clk_i    (clk_i),
    .addr_a_i ((sample_wr_bank == 1'b1) ? sample_wr_addr : input_addr_a),
    .din_a_i  (input_din_a),
    .we_a_i   ((sample_wr_bank == 1'b1) && input_we_a),
    .dout_a_o (input_bank1_dout_a),
    .addr_b_i (input_addr_b),
    .din_b_i  ('0),
    .we_b_i   (1'b0),
    .dout_b_o (input_bank1_dout_b)
  );

  assign stage_src_data_a[0] = stage_in_bank[0] ? input_bank1_dout_a : input_bank0_dout_a;
  assign stage_src_data_b[0] = stage_in_bank[0] ? input_bank1_dout_b : input_bank0_dout_b;

  generate
    for (genvar ST = 0; ST < STAGE_COUNT; ST++) begin : static_stages
      localparam int unsigned STAGE_INDEX = ST;
      localparam logic [STAGE_W-1:0] STAGE_INDEX_L = ST;

      if (ST > 0) begin : connect_previous_stage
        assign stage_out_rd_bank[ST-1] = stage_in_bank[ST];
        assign stage_out_rd_addr_a[ST-1] = stage_src_addr_a[ST];
        assign stage_out_rd_addr_b[ST-1] = stage_src_addr_b[ST];
        assign stage_src_data_a[ST] = stage_out_rd_data_a[ST-1];
        assign stage_src_data_b[ST] = stage_out_rd_data_b[ST-1];
      end

      butterfly_static_frame_stage #(
        .IN_DW       (IN_DW),
        .OUT_DW      (OUT_DW),
        .WEIGHT_DW   (WEIGHT_DW),
        .WEIGHT_FRAC (WEIGHT_FRAC),
        .VECTOR_LEN  (VECTOR_LEN),
        .STAGE_INDEX (STAGE_INDEX)
      ) i_stage (
        .clk_i               (clk_i),
        .rstn_i              (rstn_i),
        .soft_reset_i        (soft_reset_i),
        .start_i             (stage_start[ST]),
        .out_bank_i          (stage_out_bank[ST]),
        .src_addr_a_o        (stage_src_addr_a[ST]),
        .src_addr_b_o        (stage_src_addr_b[ST]),
        .src_data_a_i        (stage_src_data_a[ST]),
        .src_data_b_i        (stage_src_data_b[ST]),
        .weight_load_valid_i (weight_load_valid_i &&
                              weight_load_ready_o &&
                              (weight_load_stage == STAGE_INDEX_L)),
        .weight_load_addr_i  (weight_load_offset),
        .weight_load_i       (weight_load_i),
        .out_rd_bank_i       (stage_out_rd_bank[ST]),
        .out_rd_addr_a_i     (stage_out_rd_addr_a[ST]),
        .out_rd_addr_b_i     (stage_out_rd_addr_b[ST]),
        .out_rd_data_a_o     (stage_out_rd_data_a[ST]),
        .out_rd_data_b_o     (stage_out_rd_data_b[ST]),
        .busy_o              (stage_busy[ST]),
        .done_o              (stage_done[ST])
      );
    end
  endgenerate

  assign stage_out_rd_bank[STAGE_COUNT-1] = output_bank;
  assign stage_out_rd_addr_a[STAGE_COUNT-1] = output_addr;
  assign stage_out_rd_addr_b[STAGE_COUNT-1] = output_addr + 1'b1;

  always_ff @(posedge clk_i) begin
    if (!rstn_i || soft_reset_i) begin
      weight_load_addr <= '0;
      weight_load_done_o <= 1'b0;
      sample_wr_addr <= '0;
      sample_wr_bank <= 1'b0;
      input_frame_valid <= 2'b00;
      stage_start <= '0;
      stage_in_bank <= '0;
      stage_out_bank <= '0;
      stage_frame_valid <= '0;
      output_active <= 1'b0;
      output_bank <= 1'b0;
      output_addr <= '0;
      output_valid_o <= 1'b0;
      done_o <= 1'b0;
      y0_o <= '0;
      y1_o <= '0;
      weight_load_active <= 1'b0;
      input_load_active <= 1'b0;
      latency_active <= 1'b0;
      total_active <= 1'b0;
      weight_load_cycle_count <= 32'd0;
      input_load_cycle_count <= 32'd0;
      latency_cycle_count <= 32'd0;
      total_cycle_count <= 32'd0;
      output_cycle_count <= 32'd0;
      timing_total_cycles_o <= 32'd0;
      timing_weight_load_cycles_o <= 32'd0;
      timing_input_load_cycles_o <= 32'd0;
      timing_latency_cycles_o <= 32'd0;
      timing_output_cycles_o <= 32'd0;
    end else begin
      stage_start <= '0;
      output_valid_o <= 1'b0;
      done_o <= 1'b0;

      if (!total_active && (accepted_weight || accepted_sample)) begin
        total_active <= 1'b1;
        total_cycle_count <= 32'd1;
      end else if (total_active) begin
        total_cycle_count <= total_cycle_count + 1'b1;
      end

      if (accepted_weight && !weight_load_active) begin
        weight_load_active <= 1'b1;
        weight_load_cycle_count <= 32'd1;
      end else if (weight_load_active) begin
        weight_load_cycle_count <= weight_load_cycle_count + 1'b1;
      end

      if (accepted_sample && !input_load_active) begin
        input_load_active <= 1'b1;
        input_load_cycle_count <= 32'd1;
      end else if (input_load_active) begin
        input_load_cycle_count <= input_load_cycle_count + 1'b1;
      end

      if (latency_active) begin
        latency_cycle_count <= latency_cycle_count + 1'b1;
      end

      if (accepted_weight) begin
        if (weight_load_addr == LAST_WEIGHT_LOAD_ADDR) begin
          weight_load_done_o <= 1'b1;
          weight_load_active <= 1'b0;
          timing_weight_load_cycles_o <= weight_load_active ?
                                         (weight_load_cycle_count + 1'b1) :
                                         32'd1;
        end else begin
          weight_load_addr <= weight_load_addr + 1'b1;
        end
      end

      if (accepted_sample) begin
        if (sample_wr_addr == LAST_SAMPLE_ADDR) begin
          input_frame_valid[sample_wr_bank] <= 1'b1;
          sample_wr_bank <= ~sample_wr_bank;
          sample_wr_addr <= '0;
          input_load_active <= 1'b0;
          latency_active <= 1'b1;
          latency_cycle_count <= 32'd0;
          output_cycle_count <= 32'd0;
          timing_input_load_cycles_o <= input_load_active ?
                                        (input_load_cycle_count + 1'b1) :
                                        32'd1;
        end else begin
          sample_wr_addr <= sample_wr_addr + 1'b1;
        end
      end

      for (int st = 0; st < STAGE_COUNT; st++) begin
        if (stage_done[st]) begin
          stage_frame_valid[st][stage_out_bank[st]] <= 1'b1;
        end
      end

      if (!stage_busy[0] && (input_frame_valid != 2'b00) &&
          (stage_frame_valid[0] != 2'b11)) begin
        stage_start[0] <= 1'b1;
        stage_in_bank[0] <= input_frame_valid[0] ? 1'b0 : 1'b1;
        stage_out_bank[0] <= !stage_frame_valid[0][0] ? 1'b0 : 1'b1;
        input_frame_valid[input_frame_valid[0] ? 1'b0 : 1'b1] <= 1'b0;
      end

      for (int st = 1; st < STAGE_COUNT; st++) begin
        if (!stage_busy[st] && (stage_frame_valid[st-1] != 2'b00) &&
            (stage_frame_valid[st] != 2'b11)) begin
          stage_start[st] <= 1'b1;
          stage_in_bank[st] <= stage_frame_valid[st-1][0] ? 1'b0 : 1'b1;
          stage_out_bank[st] <= !stage_frame_valid[st][0] ? 1'b0 : 1'b1;
          stage_frame_valid[st-1][stage_frame_valid[st-1][0] ? 1'b0 : 1'b1] <= 1'b0;
        end
      end

      if (!output_active && (stage_frame_valid[STAGE_COUNT-1] != 2'b00)) begin
        output_active <= 1'b1;
        output_bank <= stage_frame_valid[STAGE_COUNT-1][0] ? 1'b0 : 1'b1;
        stage_frame_valid[STAGE_COUNT-1][stage_frame_valid[STAGE_COUNT-1][0] ? 1'b0 : 1'b1] <= 1'b0;
        output_addr <= '0;
        output_cycle_count <= 32'd0;
        timing_output_cycles_o <= 32'd0;
      end else if (output_active) begin
        output_cycle_count <= output_cycle_count + 1'b1;

        if (output_ready_i) begin
          y0_o <= stage_out_rd_data_a[STAGE_COUNT-1];
          y1_o <= stage_out_rd_data_b[STAGE_COUNT-1];
          output_valid_o <= 1'b1;

          if (first_output_sample) begin
            latency_active <= 1'b0;
            timing_latency_cycles_o <= latency_active ?
                                       (latency_cycle_count + 1'b1) :
                                       32'd1;
          end

          if (final_output_sample) begin
            output_active <= 1'b0;
            done_o <= 1'b1;
            output_addr <= '0;
            total_active <= 1'b0;
            timing_output_cycles_o <= output_cycle_count + 1'b1;
            timing_total_cycles_o <= total_active ? (total_cycle_count + 1'b1) :
                                                    32'd1;
          end else begin
            output_addr <= output_addr + 2'd2;
          end
        end
      end
    end
  end

endmodule: butterfly_network_static_pipeline

module butterfly_static_frame_stage #(
  parameter int unsigned IN_DW       = 14,
  parameter int unsigned OUT_DW      = 14,
  parameter int unsigned WEIGHT_DW   = 7,
  parameter int unsigned WEIGHT_FRAC = 6,
  parameter int unsigned VECTOR_LEN  = 2048,
  parameter int unsigned STAGE_INDEX = 0,
  parameter int unsigned ADDR_W = (VECTOR_LEN <= 2) ? 1 : $clog2(VECTOR_LEN)
)(
  input  logic                          clk_i,
  input  logic                          rstn_i,
  input  logic                          soft_reset_i,
  input  logic                          start_i,
  input  logic                          out_bank_i,

  output logic [ADDR_W-1:0]             src_addr_a_o,
  output logic [ADDR_W-1:0]             src_addr_b_o,
  input  logic signed [IN_DW-1:0]       src_data_a_i,
  input  logic signed [IN_DW-1:0]       src_data_b_i,

  input  logic                          weight_load_valid_i,
  input  logic [ADDR_W-1:0]             weight_load_addr_i,
  input  logic signed [2*WEIGHT_DW-1:0] weight_load_i,

  input  logic                          out_rd_bank_i,
  input  logic [ADDR_W-1:0]             out_rd_addr_a_i,
  input  logic [ADDR_W-1:0]             out_rd_addr_b_i,
  output logic signed [OUT_DW-1:0]      out_rd_data_a_o,
  output logic signed [OUT_DW-1:0]      out_rd_data_b_o,

  output logic                          busy_o,
  output logic                          done_o
);

  localparam int unsigned PAIR_COUNT = VECTOR_LEN / 2;
  localparam int unsigned PAIR_W = (PAIR_COUNT <= 1) ? 1 : $clog2(PAIR_COUNT);
  localparam int unsigned PROD_DW = IN_DW + WEIGHT_DW;
  localparam int unsigned ACC_DW = PROD_DW + 1;

  localparam logic [PAIR_W-1:0] LAST_PAIR = PAIR_COUNT - 1;

  typedef enum logic [2:0] {
    ST_IDLE,
    ST_READ,
    ST_LATCH,
    ST_MUL_Y0,
    ST_MUL_Y1,
    ST_SCALE,
    ST_WRITE
  } state_t;

  state_t state;

  logic [PAIR_W-1:0] pair_idx;
  logic out_bank;
  logic [ADDR_W-1:0] addr_a;
  logic [ADDR_W-1:0] addr_b;
  logic [ADDR_W-1:0] weight_addr_a;
  logic [ADDR_W-1:0] weight_addr_b;

  logic signed [IN_DW-1:0] sample_a;
  logic signed [IN_DW-1:0] sample_b;
  logic signed [2*WEIGHT_DW-1:0] weight_a;
  logic signed [2*WEIGHT_DW-1:0] weight_b;
  logic signed [ACC_DW-1:0] acc_y0;
  logic signed [ACC_DW-1:0] acc_y1;
  logic signed [OUT_DW-1:0] result_y0;
  logic signed [OUT_DW-1:0] result_y1;

  logic [ADDR_W-1:0] out_addr_a;
  logic [ADDR_W-1:0] out_addr_b;
  logic signed [OUT_DW-1:0] out_din_a;
  logic signed [OUT_DW-1:0] out_din_b;
  logic out_we_a;
  logic out_we_b;
  logic signed [OUT_DW-1:0] out_bank0_dout_a;
  logic signed [OUT_DW-1:0] out_bank0_dout_b;
  logic signed [OUT_DW-1:0] out_bank1_dout_a;
  logic signed [OUT_DW-1:0] out_bank1_dout_b;

  logic [ADDR_W-1:0] weight_addr_port_a;
  logic [ADDR_W-1:0] weight_addr_port_b;
  logic signed [2*WEIGHT_DW-1:0] weight_dout_a;
  logic signed [2*WEIGHT_DW-1:0] weight_dout_b;

  function automatic logic signed [PROD_DW-1:0] mul_sample_weight;
    input logic signed [IN_DW-1:0] sample;
    input logic signed [WEIGHT_DW-1:0] weight;
    logic signed [PROD_DW-1:0] product;
    begin
      product = sample * weight;
      mul_sample_weight = product;
    end
  endfunction

  function automatic logic signed [ACC_DW-1:0] round_shift;
    input logic signed [ACC_DW-1:0] value;
    logic signed [ACC_DW-1:0] rounding;
    begin
      if (WEIGHT_FRAC == 0) begin
        round_shift = value;
      end else begin
        rounding = {{(ACC_DW-WEIGHT_FRAC){1'b0}}, 1'b1, {(WEIGHT_FRAC-1){1'b0}}};
        round_shift = (value + rounding) >>> WEIGHT_FRAC;
      end
    end
  endfunction

  function automatic logic signed [OUT_DW-1:0] sat_to_out;
    input logic signed [ACC_DW-1:0] value;
    localparam logic signed [ACC_DW-1:0] MAX_OUT =
        {{(ACC_DW-OUT_DW){1'b0}}, 1'b0, {(OUT_DW-1){1'b1}}};
    localparam logic signed [ACC_DW-1:0] MIN_OUT =
        {{(ACC_DW-OUT_DW){1'b1}}, 1'b1, {(OUT_DW-1){1'b0}}};
    begin
      if (value > MAX_OUT) begin
        sat_to_out = {1'b0, {(OUT_DW-1){1'b1}}};
      end else if (value < MIN_OUT) begin
        sat_to_out = {1'b1, {(OUT_DW-1){1'b0}}};
      end else begin
        sat_to_out = value[OUT_DW-1:0];
      end
    end
  endfunction

  always_comb begin
    logic [ADDR_W-1:0] half_span;
    logic [ADDR_W-1:0] pair_in_group;
    logic [ADDR_W-1:0] pair_idx_addr;
    logic [ADDR_W-1:0] group_base;

    half_span = {{(ADDR_W-1){1'b0}}, 1'b1} << STAGE_INDEX;
    pair_idx_addr = {{(ADDR_W-PAIR_W){1'b0}}, pair_idx};
    pair_in_group = pair_idx_addr & (half_span - 1'b1);
    group_base = (pair_idx_addr - pair_in_group) << 1;
    addr_a = group_base + pair_in_group;
    addr_b = addr_a + half_span;
    weight_addr_a = addr_a;
    weight_addr_b = addr_b;

    src_addr_a_o = addr_a;
    src_addr_b_o = addr_b;

    weight_addr_port_a = (state == ST_IDLE && weight_load_valid_i) ?
                         weight_load_addr_i : weight_addr_a;
    weight_addr_port_b = weight_addr_b;

    out_addr_a = out_rd_addr_a_i;
    out_addr_b = out_rd_addr_b_i;
    out_din_a = '0;
    out_din_b = '0;
    out_we_a = 1'b0;
    out_we_b = 1'b0;

    if (state == ST_WRITE) begin
      out_addr_a = addr_a;
      out_addr_b = addr_b;
      out_din_a = result_y0;
      out_din_b = result_y1;
      out_we_a = 1'b1;
      out_we_b = 1'b1;
    end

    out_rd_data_a_o = out_rd_bank_i ? out_bank1_dout_a : out_bank0_dout_a;
    out_rd_data_b_o = out_rd_bank_i ? out_bank1_dout_b : out_bank0_dout_b;
  end

  bnet_tdp_ram #(
    .DW    (2*WEIGHT_DW),
    .DEPTH (VECTOR_LEN),
    .AW    (ADDR_W)
  ) i_weight_ram (
    .clk_i    (clk_i),
    .addr_a_i (weight_addr_port_a),
    .din_a_i  (weight_load_i),
    .we_a_i   (weight_load_valid_i && (state == ST_IDLE)),
    .dout_a_o (weight_dout_a),
    .addr_b_i (weight_addr_port_b),
    .din_b_i  ('0),
    .we_b_i   (1'b0),
    .dout_b_o (weight_dout_b)
  );

  bnet_tdp_ram #(
    .DW    (OUT_DW),
    .DEPTH (VECTOR_LEN),
    .AW    (ADDR_W)
  ) i_out_bank0 (
    .clk_i    (clk_i),
    .addr_a_i ((out_bank == 1'b0 && state == ST_WRITE) ? out_addr_a : out_rd_addr_a_i),
    .din_a_i  (out_din_a),
    .we_a_i   ((out_bank == 1'b0) && out_we_a),
    .dout_a_o (out_bank0_dout_a),
    .addr_b_i ((out_bank == 1'b0 && state == ST_WRITE) ? out_addr_b : out_rd_addr_b_i),
    .din_b_i  (out_din_b),
    .we_b_i   ((out_bank == 1'b0) && out_we_b),
    .dout_b_o (out_bank0_dout_b)
  );

  bnet_tdp_ram #(
    .DW    (OUT_DW),
    .DEPTH (VECTOR_LEN),
    .AW    (ADDR_W)
  ) i_out_bank1 (
    .clk_i    (clk_i),
    .addr_a_i ((out_bank == 1'b1 && state == ST_WRITE) ? out_addr_a : out_rd_addr_a_i),
    .din_a_i  (out_din_a),
    .we_a_i   ((out_bank == 1'b1) && out_we_a),
    .dout_a_o (out_bank1_dout_a),
    .addr_b_i ((out_bank == 1'b1 && state == ST_WRITE) ? out_addr_b : out_rd_addr_b_i),
    .din_b_i  (out_din_b),
    .we_b_i   ((out_bank == 1'b1) && out_we_b),
    .dout_b_o (out_bank1_dout_b)
  );

  assign busy_o = (state != ST_IDLE);

  always_ff @(posedge clk_i) begin
    if (!rstn_i || soft_reset_i) begin
      state <= ST_IDLE;
      pair_idx <= '0;
      out_bank <= 1'b0;
      sample_a <= '0;
      sample_b <= '0;
      weight_a <= '0;
      weight_b <= '0;
      acc_y0 <= '0;
      acc_y1 <= '0;
      result_y0 <= '0;
      result_y1 <= '0;
      done_o <= 1'b0;
    end else begin
      done_o <= 1'b0;

      unique case (state)
        ST_IDLE: begin
          if (start_i) begin
            pair_idx <= '0;
            out_bank <= out_bank_i;
            state <= ST_READ;
          end
        end

        ST_READ: begin
          state <= ST_LATCH;
        end

        ST_LATCH: begin
          sample_a <= src_data_a_i;
          sample_b <= src_data_b_i;
          weight_a <= weight_dout_a;
          weight_b <= weight_dout_b;
          state <= ST_MUL_Y0;
        end

        ST_MUL_Y0: begin
          acc_y0 <= $signed(mul_sample_weight(sample_a, weight_a[2*WEIGHT_DW-1:WEIGHT_DW])) +
                    $signed(mul_sample_weight(sample_b, weight_b[2*WEIGHT_DW-1:WEIGHT_DW]));
          state <= ST_MUL_Y1;
        end

        ST_MUL_Y1: begin
          acc_y1 <= $signed(mul_sample_weight(sample_a, weight_a[WEIGHT_DW-1:0])) +
                    $signed(mul_sample_weight(sample_b, weight_b[WEIGHT_DW-1:0]));
          state <= ST_SCALE;
        end

        ST_SCALE: begin
          result_y0 <= sat_to_out(round_shift(acc_y0));
          result_y1 <= sat_to_out(round_shift(acc_y1));
          state <= ST_WRITE;
        end

        ST_WRITE: begin
          if (pair_idx == LAST_PAIR) begin
            done_o <= 1'b1;
            state <= ST_IDLE;
          end else begin
            pair_idx <= pair_idx + 1'b1;
            state <= ST_READ;
          end
        end

        default: begin
          state <= ST_IDLE;
        end
      endcase
    end
  end

endmodule: butterfly_static_frame_stage
