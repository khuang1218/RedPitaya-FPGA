////////////////////////////////////////////////////////////////////////////////
// Static-weight SDF butterfly stream.
//
// Experimental 4096-point streaming path for the BNET work. Unlike
// butterfly_network_static_pipeline.sv, this architecture does not hand a whole
// frame from one full-frame RAM bank to the next. Each stage is an SDF-style
// streaming worker:
//   - first half of a butterfly span is stored in a delay line
//   - second half is combined with the delayed sample
//   - y0 is emitted immediately
//   - y1 is fed back through a second delay line and emitted in the next
//     first-half slot
//
// This keeps one sample stream flowing through all log2(N) stages. The final
// scalar stream is repacked into the existing two-output BNET interface.
//
// Notes:
//   - Static weights use the same per-stage, per-sample packed format as the
//     frame pipeline.
//   - The top-level single-DAC serializer backpressures every other output
//     clock while it emits the saved odd scalar. This is safe for the packed
//     two-scalar output cadence used here; deeper/irregular stalls would need
//     an output skid buffer.
////////////////////////////////////////////////////////////////////////////////

module butterfly_network_static_sdf #(
  parameter int unsigned IN_DW       = 14,
  parameter int unsigned OUT_DW      = 14,
  parameter int unsigned WEIGHT_DW   = 7,
  parameter int unsigned WEIGHT_FRAC = 6,
  parameter int unsigned VECTOR_LEN  = 4096
)(
  input  logic                          clk_i,
  input  logic                          rstn_i,
  input  logic                          soft_reset_i,
  input  logic                          start_i,
  input  logic [32-1:0]                 vector_len_i,
  input  logic [2-1:0]                  weight_bank_i,

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
  logic [ADDR_W:0]           configured_vector_len;
  logic [ADDR_W:0]           run_vector_len;
  logic [ADDR_W-1:0]         configured_last_sample_addr;
  logic [ADDR_W-1:0]         run_last_sample_addr;
  logic [ADDR_W-1:0]         run_last_pair_start_addr;
  logic [STAGE_W-1:0]        configured_stage_count;
  logic [STAGE_W-1:0]        run_stage_count;
  logic [3-1:0]              configured_bank_count;
  logic [2-1:0]              run_weight_bank;
  logic [2-1:0]              weight_load_bank;
  logic [STAGE_W-1:0]       weight_load_stage;
  logic [ADDR_W-1:0]        weight_load_offset;
  logic [ADDR_W-1:0]        weight_load_full_addr;
  logic                     accepted_weight;
  logic                     accepted_sample;

  logic [ADDR_W-1:0] input_count;
  logic              input_active;
  logic              input_done;

  logic [STAGE_COUNT-1:0] stage_weight_load_valid;
  logic [STAGE_COUNT-1:0] stage_busy;
  logic [STAGE_COUNT-1:0] stage_done;
  logic signed [STAGE_COUNT:0][OUT_DW-1:0] stage_data;
  logic [STAGE_COUNT:0] stage_valid;
  logic signed [OUT_DW-1:0] final_stage_data;
  logic                     final_stage_valid;

  // The SDF stage chain has no ready/backpressure signal between stages, while
  // the single-DAC serializer only accepts one two-scalar pair every other
  // clock. Buffer the full final scalar frame so bursty SDF output cannot drop
  // samples before the serializer drains them.
  localparam int unsigned OUTPUT_FIFO_DEPTH = VECTOR_LEN;
  localparam int unsigned OUTPUT_FIFO_AW = ADDR_W;

  logic signed [OUT_DW-1:0] output_fifo [0:OUTPUT_FIFO_DEPTH-1];
  // The SDF schedule presents the final frame as a right rotation by eight
  // scalars. Preserve those first eight values and append them after the rest
  // so the external frame starts at logical sample zero without losing data.
  localparam int unsigned OUTPUT_ROTATE = 8;
  logic signed [OUT_DW-1:0] output_prefix [0:OUTPUT_ROTATE-1];
  logic [ADDR_W-1:0]        final_scalar_ingress_count;
  logic [3-1:0]             output_prefix_flush_index;
  logic                     output_prefix_flush_active;
  logic signed [OUT_DW-1:0] output_fifo_push_data;
  logic                     output_fifo_source_valid;
  logic [OUTPUT_FIFO_AW-1:0] output_fifo_wr_addr;
  logic [OUTPUT_FIFO_AW-1:0] output_fifo_rd_addr;
  logic [OUTPUT_FIFO_AW-1:0] output_fifo_rd_addr1;
  logic [OUTPUT_FIFO_AW:0]   output_fifo_count;
  logic                      output_fifo_push;
  logic                      output_pair_accept;
  logic                      output_pair_load;
  logic                      output_pair_last_accept;
  logic [ADDR_W-1:0]        output_scalar_count;

  logic weight_load_active;
  logic input_load_active;
  logic latency_active;
  logic total_active;
  logic output_active;
  logic [32-1:0] weight_load_cycle_count;
  logic [32-1:0] input_load_cycle_count;
  logic [32-1:0] latency_cycle_count;
  logic [32-1:0] total_cycle_count;
  logic [32-1:0] output_cycle_count;

  always_comb begin
    configured_vector_len = 13'd4096;
    configured_last_sample_addr = 12'd4095;
    configured_stage_count = 4'd12;
    configured_bank_count = 3'd1;
    case (vector_len_i)
      32'd1024: begin
        configured_vector_len = 13'd1024;
        configured_last_sample_addr = 12'd1023;
        configured_stage_count = 4'd10;
        configured_bank_count = 3'd4;
      end
      32'd2048: begin
        configured_vector_len = 13'd2048;
        configured_last_sample_addr = 12'd2047;
        configured_stage_count = 4'd11;
        configured_bank_count = 3'd2;
      end
      default: begin
      end
    endcase

    weight_load_full_addr = weight_load_offset;
    case (configured_vector_len)
      13'd1024: weight_load_full_addr[11:10] = weight_load_bank;
      13'd2048: weight_load_full_addr[11] = weight_load_bank[0];
      default: begin
      end
    endcase

    final_stage_data = stage_data[STAGE_COUNT];
    final_stage_valid = stage_valid[STAGE_COUNT];
    case (run_stage_count)
      4'd10: begin
        final_stage_data = stage_data[10];
        final_stage_valid = stage_valid[10];
      end
      4'd11: begin
        final_stage_data = stage_data[11];
        final_stage_valid = stage_valid[11];
      end
      default: begin
      end
    endcase
  end

  assign run_last_sample_addr = run_vector_len - 1'b1;
  assign run_last_pair_start_addr = run_vector_len - 2'd2;
  assign weight_load_ready_o = !weight_load_done_o && !(|stage_busy);
  assign accepted_weight = weight_load_valid_i && weight_load_ready_o;

  assign sample_ready_o = weight_load_done_o && !input_done;
  assign accepted_sample = sample_valid_i && sample_ready_o;
  assign busy_o = total_active || weight_load_active || input_load_active ||
                  latency_active || output_active || input_active ||
                  (|stage_busy) || (|stage_valid[STAGE_COUNT:1]) ||
                  output_prefix_flush_active || (output_fifo_count != '0);

  assign stage_data[0] = $signed(sample_i);
  assign stage_valid[0] = accepted_sample;
  assign output_fifo_rd_addr1 = output_fifo_rd_addr + 1'b1;
  assign output_pair_accept = output_valid_o && output_ready_i;
  assign output_pair_last_accept = output_pair_accept &&
                                   (output_scalar_count >= run_last_pair_start_addr);
  assign output_pair_load = !output_pair_last_accept &&
                            (!output_valid_o || output_pair_accept) &&
                            (output_fifo_count >= 2);
  assign output_fifo_source_valid = output_prefix_flush_active ||
                                    (final_stage_valid &&
                                     (final_scalar_ingress_count >= OUTPUT_ROTATE));
  assign output_fifo_push_data = output_prefix_flush_active ?
                                 output_prefix[output_prefix_flush_index] :
                                 final_stage_data;
  assign output_fifo_push = output_fifo_source_valid &&
                            ((output_fifo_count < OUTPUT_FIFO_DEPTH) ||
                             output_pair_load);

  generate
    for (genvar ST = 0; ST < STAGE_COUNT; ST++) begin : sdf_stages
      localparam int unsigned STAGE_INDEX = ST;
      localparam logic [STAGE_W-1:0] STAGE_INDEX_L = ST;

      assign stage_weight_load_valid[ST] = weight_load_valid_i &&
                                           weight_load_ready_o &&
                                           (weight_load_stage == STAGE_INDEX_L);

      butterfly_static_sdf_stage #(
        .IN_DW       (OUT_DW),
        .OUT_DW      (OUT_DW),
        .WEIGHT_DW   (WEIGHT_DW),
        .WEIGHT_FRAC (WEIGHT_FRAC),
        .VECTOR_LEN  (VECTOR_LEN),
        .STAGE_INDEX (STAGE_INDEX)
      ) i_stage (
        .clk_i               (clk_i),
        .rstn_i              (rstn_i),
        .soft_reset_i        (soft_reset_i),
        .weight_load_valid_i (stage_weight_load_valid[ST]),
        .weight_load_addr_i  (weight_load_full_addr),
        .weight_load_i       (weight_load_i),
        .vector_len_i        (run_vector_len),
        .weight_bank_i       (run_weight_bank),
        .sample_valid_i      (stage_valid[ST] && (STAGE_INDEX < run_stage_count)),
        .sample_i            (stage_data[ST]),
        .sample_o            (stage_data[ST+1]),
        .sample_valid_o      (stage_valid[ST+1]),
        .busy_o              (stage_busy[ST]),
        .done_o              (stage_done[ST])
      );
    end
  endgenerate

  always_ff @(posedge clk_i) begin
    if (!rstn_i || soft_reset_i) begin
      weight_load_bank <= '0;
      weight_load_stage <= '0;
      weight_load_offset <= '0;
      weight_load_done_o <= 1'b0;
      run_vector_len <= 13'd4096;
      run_stage_count <= 4'd12;
      run_weight_bank <= 2'd0;
      input_count <= '0;
      input_active <= 1'b0;
      input_done <= 1'b0;
      output_fifo_wr_addr <= '0;
      output_fifo_rd_addr <= '0;
      output_fifo_count <= '0;
      final_scalar_ingress_count <= '0;
      output_prefix_flush_index <= '0;
      output_prefix_flush_active <= 1'b0;
      output_scalar_count <= '0;
      y0_o <= '0;
      y1_o <= '0;
      output_valid_o <= 1'b0;
      done_o <= 1'b0;
      weight_load_active <= 1'b0;
      input_load_active <= 1'b0;
      latency_active <= 1'b0;
      total_active <= 1'b0;
      output_active <= 1'b0;
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
      done_o <= 1'b0;

      if (start_i) begin
        run_vector_len <= configured_vector_len;
        run_stage_count <= configured_stage_count;
        case (configured_vector_len)
          13'd1024: run_weight_bank <= weight_bank_i;
          13'd2048: run_weight_bank <= {1'b0, weight_bank_i[0]};
          default:  run_weight_bank <= 2'd0;
        endcase
      end

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

      if (output_active) begin
        output_cycle_count <= output_cycle_count + 1'b1;
      end

      if (accepted_weight) begin
        if (weight_load_offset == configured_last_sample_addr) begin
          weight_load_offset <= '0;
          if (weight_load_stage == (configured_stage_count - 1'b1)) begin
            weight_load_stage <= '0;
            if (weight_load_bank == (configured_bank_count - 1'b1)) begin
              weight_load_bank <= '0;
              weight_load_done_o <= 1'b1;
              weight_load_active <= 1'b0;
              timing_weight_load_cycles_o <= weight_load_active ?
                                             (weight_load_cycle_count + 1'b1) :
                                             32'd1;
            end else begin
              weight_load_bank <= weight_load_bank + 1'b1;
            end
          end else begin
            weight_load_stage <= weight_load_stage + 1'b1;
          end
        end else begin
          weight_load_offset <= weight_load_offset + 1'b1;
        end
      end

      if (accepted_sample) begin
        input_active <= 1'b1;
        if (input_count == run_last_sample_addr) begin
          input_done <= 1'b1;
          input_active <= 1'b0;
          input_count <= '0;
          input_load_active <= 1'b0;
          latency_active <= 1'b1;
          latency_cycle_count <= 32'd0;
          timing_input_load_cycles_o <= input_load_active ?
                                        (input_load_cycle_count + 1'b1) :
                                        32'd1;
        end else begin
          input_count <= input_count + 1'b1;
        end
      end

      if (final_stage_valid) begin
        if (final_scalar_ingress_count < OUTPUT_ROTATE) begin
          output_prefix[final_scalar_ingress_count[2:0]] <= final_stage_data;
        end

        if (final_scalar_ingress_count == run_last_sample_addr) begin
          final_scalar_ingress_count <= '0;
          output_prefix_flush_index <= '0;
          output_prefix_flush_active <= 1'b1;
        end else begin
          final_scalar_ingress_count <= final_scalar_ingress_count + 1'b1;
        end
      end

      if (output_fifo_push) begin
        output_fifo[output_fifo_wr_addr] <= output_fifo_push_data;
        output_fifo_wr_addr <= output_fifo_wr_addr + 1'b1;
      end

      if (output_prefix_flush_active && output_fifo_push) begin
        if (output_prefix_flush_index == (OUTPUT_ROTATE - 1)) begin
          output_prefix_flush_index <= '0;
          output_prefix_flush_active <= 1'b0;
        end else begin
          output_prefix_flush_index <= output_prefix_flush_index + 1'b1;
        end
      end

      if (output_pair_load) begin
        y0_o <= output_fifo[output_fifo_rd_addr];
        y1_o <= output_fifo[output_fifo_rd_addr1];
        output_valid_o <= 1'b1;
        output_fifo_rd_addr <= output_fifo_rd_addr + 2'd2;
      end else if (output_pair_accept) begin
        output_valid_o <= 1'b0;
      end

      if (output_pair_load && !output_active) begin
        output_active <= 1'b1;
        output_cycle_count <= 32'd1;
      end

      if (output_pair_load && (output_scalar_count == '0)) begin
        latency_active <= 1'b0;
        timing_latency_cycles_o <= latency_active ?
                                   (latency_cycle_count + 1'b1) :
                                   32'd1;
      end

      if (output_pair_last_accept) begin
        done_o <= 1'b1;
        output_valid_o <= 1'b0;
        output_active <= 1'b0;
        total_active <= 1'b0;
        input_done <= 1'b0;
        output_scalar_count <= '0;
        output_fifo_count <= '0;
        output_fifo_wr_addr <= '0;
        output_fifo_rd_addr <= '0;
        final_scalar_ingress_count <= '0;
        output_prefix_flush_index <= '0;
        output_prefix_flush_active <= 1'b0;
        timing_output_cycles_o <= output_cycle_count + 1'b1;
        timing_total_cycles_o <= total_active ? (total_cycle_count + 1'b1) :
                                                32'd1;
      end else begin
        if (output_pair_accept) begin
          output_scalar_count <= output_scalar_count + 2'd2;
        end

        case ({output_fifo_push, output_pair_load})
          2'b10: output_fifo_count <= output_fifo_count + 1'b1;
          2'b01: output_fifo_count <= output_fifo_count - 2'd2;
          2'b11: output_fifo_count <= output_fifo_count - 1'b1;
          default: output_fifo_count <= output_fifo_count;
        endcase
      end
    end
  end

endmodule: butterfly_network_static_sdf

module butterfly_static_sdf_stage #(
  parameter int unsigned IN_DW       = 14,
  parameter int unsigned OUT_DW      = 14,
  parameter int unsigned WEIGHT_DW   = 7,
  parameter int unsigned WEIGHT_FRAC = 6,
  parameter int unsigned VECTOR_LEN  = 4096,
  parameter int unsigned STAGE_INDEX = 0,
  parameter int unsigned ADDR_W = (VECTOR_LEN <= 2) ? 1 : $clog2(VECTOR_LEN)
)(
  input  logic                          clk_i,
  input  logic                          rstn_i,
  input  logic                          soft_reset_i,

  input  logic                          weight_load_valid_i,
  input  logic [ADDR_W-1:0]             weight_load_addr_i,
  input  logic signed [2*WEIGHT_DW-1:0] weight_load_i,
  input  logic [ADDR_W:0]                vector_len_i,
  input  logic [2-1:0]                   weight_bank_i,

  input  logic                          sample_valid_i,
  input  logic signed [IN_DW-1:0]       sample_i,

  output logic signed [OUT_DW-1:0]      sample_o,
  output logic                          sample_valid_o,
  output logic                          busy_o,
  output logic                          done_o
);

  localparam int unsigned DELAY_LEN = 1 << STAGE_INDEX;
  localparam int unsigned DELAY_AW = (DELAY_LEN <= 1) ? 1 : $clog2(DELAY_LEN);
  localparam int unsigned PROD_DW = IN_DW + WEIGHT_DW;
  localparam int unsigned ACC_DW = PROD_DW + 1;

  localparam logic [ADDR_W-1:0] DELAY_LEN_ADDR = DELAY_LEN;
  localparam logic [ADDR_W:0] GROUP_LEN_ADDR_EXT = 2 * DELAY_LEN;
  localparam logic [DELAY_AW-1:0] LAST_DELAY_ADDR = DELAY_LEN - 1;

  logic [ADDR_W-1:0] sample_idx;
  logic [DELAY_AW-1:0] drain_addr;
  logic draining;
  logic drain_read_valid;
  logic drain_read_last;
  logic frame_seen;

  logic [DELAY_AW-1:0] delay_addr;
  logic second_half;
  logic emit_y1_from_delay;
  logic [ADDR_W-1:0] group_base;
  logic [ADDR_W-1:0] addr_a;
  logic [ADDR_W-1:0] addr_b;

  logic signed [IN_DW-1:0] x_delay_dout;
  logic signed [OUT_DW-1:0] y1_delay_dout;
  logic signed [OUT_DW-1:0] y1_delay_din;
  logic y1_delay_we;
  logic signed [ACC_DW-1:0] calc_acc_y0;
  logic signed [ACC_DW-1:0] calc_acc_y1;
  logic signed [OUT_DW-1:0] calc_y0;
  logic signed [OUT_DW-1:0] calc_y1;

  logic [ADDR_W-1:0] weight_addr_a;
  logic [ADDR_W-1:0] weight_addr_b;
  logic [ADDR_W-1:0] weight_bank_base;
  logic [ADDR_W-1:0] last_sample_addr;
  logic signed [2*WEIGHT_DW-1:0] weight_dout_a;
  logic signed [2*WEIGHT_DW-1:0] weight_dout_b;

  logic p0_valid;
  logic p0_second_half;
  logic p0_emit_y1;
  logic p0_last_input;
  logic [DELAY_AW-1:0] p0_delay_addr;
  logic signed [IN_DW-1:0] p0_sample_b;

  logic p1_valid;
  logic p1_second_half;
  logic p1_emit_y1;
  logic p1_last_input;
  logic [DELAY_AW-1:0] p1_delay_addr;
  logic signed [IN_DW-1:0] p1_sample_a;
  logic signed [IN_DW-1:0] p1_sample_b;
  logic signed [2*WEIGHT_DW-1:0] p1_weight_a;
  logic signed [2*WEIGHT_DW-1:0] p1_weight_b;
  logic signed [OUT_DW-1:0] p1_y1_from_delay;

  // DELAY_LEN 1 and 2 can read a y1 address on the same cycle that the
  // read-first delay RAM writes it. Forward those short-delay values directly
  // so a stale value from the previous group is never replayed.
  logic signed [OUT_DW-1:0] y1_short_delay [0:1];

  function automatic logic [DELAY_AW-1:0] delay_addr_from_sample;
    input logic [ADDR_W-1:0] index;
    begin
      if (DELAY_LEN <= 1) begin
        delay_addr_from_sample = '0;
      end else begin
        delay_addr_from_sample = index[0 +: DELAY_AW];
      end
    end
  endfunction

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
    last_sample_addr = vector_len_i - 1'b1;
    weight_bank_base = '0;
    case (vector_len_i)
      13'd1024: weight_bank_base[11:10] = weight_bank_i;
      13'd2048: weight_bank_base[11] = weight_bank_i[0];
      default: begin
      end
    endcase

    delay_addr = delay_addr_from_sample(sample_idx);
    second_half = sample_idx[STAGE_INDEX];
    emit_y1_from_delay = sample_valid_i && !second_half &&
                         ({1'b0, sample_idx} >= GROUP_LEN_ADDR_EXT);
    group_base = (sample_idx >> (STAGE_INDEX + 1)) << (STAGE_INDEX + 1);
    addr_a = group_base + {{(ADDR_W-DELAY_AW){1'b0}}, delay_addr};
    addr_b = addr_a + DELAY_LEN_ADDR;
    weight_addr_a = weight_load_valid_i ? weight_load_addr_i :
                                          (weight_bank_base + addr_a);
    weight_addr_b = weight_bank_base + addr_b;

    calc_acc_y0 = $signed(mul_sample_weight(p1_sample_a, p1_weight_a[2*WEIGHT_DW-1:WEIGHT_DW])) +
                  $signed(mul_sample_weight(p1_sample_b, p1_weight_b[2*WEIGHT_DW-1:WEIGHT_DW]));
    calc_acc_y1 = $signed(mul_sample_weight(p1_sample_a, p1_weight_a[WEIGHT_DW-1:0])) +
                  $signed(mul_sample_weight(p1_sample_b, p1_weight_b[WEIGHT_DW-1:0]));
    calc_y0 = sat_to_out(round_shift(calc_acc_y0));
    calc_y1 = sat_to_out(round_shift(calc_acc_y1));

    y1_delay_we = p1_valid && p1_second_half;
    y1_delay_din = calc_y1;
  end

  generate
    if (DELAY_LEN <= 64) begin : small_delays
      (* ram_style = "distributed" *) logic signed [IN_DW-1:0] x_delay_mem [0:DELAY_LEN-1];
      (* ram_style = "distributed" *) logic signed [OUT_DW-1:0] y1_delay_mem [0:DELAY_LEN-1];

      always_ff @(posedge clk_i) begin
        if (!rstn_i || soft_reset_i) begin
          x_delay_dout <= '0;
          y1_delay_dout <= '0;
          for (int i = 0; i < DELAY_LEN; i++) begin
            x_delay_mem[i] <= '0;
            y1_delay_mem[i] <= '0;
          end
        end else begin
          x_delay_dout <= x_delay_mem[delay_addr];
          y1_delay_dout <= y1_delay_mem[draining ? drain_addr : delay_addr];

          if (sample_valid_i && !second_half) begin
            x_delay_mem[delay_addr] <= sample_i;
          end

          if (y1_delay_we) begin
            y1_delay_mem[p1_delay_addr] <= y1_delay_din;
          end
        end
      end
    end else begin : ram_delays
      bnet_tdp_ram #(
        .DW    (IN_DW),
        .DEPTH (DELAY_LEN),
        .AW    (DELAY_AW)
      ) i_x_delay (
        .clk_i    (clk_i),
        .addr_a_i (delay_addr),
        .din_a_i  (sample_i),
        .we_a_i   (sample_valid_i && !second_half),
        .dout_a_o (x_delay_dout),
        .addr_b_i ('0),
        .din_b_i  ('0),
        .we_b_i   (1'b0),
        .dout_b_o ()
      );

      bnet_tdp_ram #(
        .DW    (OUT_DW),
        .DEPTH (DELAY_LEN),
        .AW    (DELAY_AW)
      ) i_y1_delay (
        .clk_i    (clk_i),
        .addr_a_i (draining ? drain_addr : delay_addr),
        .din_a_i  ('0),
        .we_a_i   (1'b0),
        .dout_a_o (y1_delay_dout),
        .addr_b_i (p1_delay_addr),
        .din_b_i  (y1_delay_din),
        .we_b_i   (y1_delay_we),
        .dout_b_o ()
      );
    end
  endgenerate

  bnet_tdp_ram #(
    .DW    (2*WEIGHT_DW),
    .DEPTH (VECTOR_LEN),
    .AW    (ADDR_W)
  ) i_weight_ram (
    .clk_i    (clk_i),
    .addr_a_i (weight_addr_a),
    .din_a_i  (weight_load_i),
    .we_a_i   (weight_load_valid_i),
    .dout_a_o (weight_dout_a),
    .addr_b_i (weight_addr_b),
    .din_b_i  ('0),
    .we_b_i   (1'b0),
    .dout_b_o (weight_dout_b)
  );

  assign busy_o = frame_seen || p0_valid || p1_valid || draining;

  always_ff @(posedge clk_i) begin
    if (!rstn_i || soft_reset_i) begin
      sample_idx <= '0;
      drain_addr <= '0;
      draining <= 1'b0;
      drain_read_valid <= 1'b0;
      drain_read_last <= 1'b0;
      frame_seen <= 1'b0;
      p0_valid <= 1'b0;
      p0_second_half <= 1'b0;
      p0_emit_y1 <= 1'b0;
      p0_last_input <= 1'b0;
      p0_delay_addr <= '0;
      p0_sample_b <= '0;
      p1_valid <= 1'b0;
      p1_second_half <= 1'b0;
      p1_emit_y1 <= 1'b0;
      p1_last_input <= 1'b0;
      p1_delay_addr <= '0;
      p1_sample_a <= '0;
      p1_sample_b <= '0;
      p1_weight_a <= '0;
      p1_weight_b <= '0;
      p1_y1_from_delay <= '0;
      y1_short_delay[0] <= '0;
      y1_short_delay[1] <= '0;
      sample_o <= '0;
      sample_valid_o <= 1'b0;
      done_o <= 1'b0;
    end else begin
      sample_valid_o <= 1'b0;
      done_o <= 1'b0;
      drain_read_valid <= 1'b0;
      drain_read_last <= 1'b0;

      p0_valid <= sample_valid_i;
      p0_second_half <= second_half;
      p0_emit_y1 <= emit_y1_from_delay;
      p0_last_input <= sample_valid_i && (sample_idx == last_sample_addr);
      p0_delay_addr <= delay_addr;
      p0_sample_b <= sample_i;

      p1_valid <= p0_valid;
      p1_second_half <= p0_second_half;
      p1_emit_y1 <= p0_emit_y1;
      p1_last_input <= p0_last_input;
      p1_delay_addr <= p0_delay_addr;
      p1_sample_a <= x_delay_dout;
      p1_sample_b <= p0_sample_b;
      p1_weight_a <= weight_dout_a;
      p1_weight_b <= weight_dout_b;
      p1_y1_from_delay <= y1_delay_dout;

      if (sample_valid_i) begin
        frame_seen <= 1'b1;
        if (sample_idx == last_sample_addr) begin
          sample_idx <= '0;
        end else begin
          sample_idx <= sample_idx + 1'b1;
        end
      end

      if (p1_valid && p1_second_half) begin
        sample_o <= calc_y0;
        sample_valid_o <= 1'b1;
        if (DELAY_LEN <= 2) begin
          y1_short_delay[p1_delay_addr] <= calc_y1;
        end
      end else if (p1_valid && p1_emit_y1) begin
        if (DELAY_LEN <= 2) begin
          sample_o <= y1_short_delay[p1_delay_addr];
        end else begin
          sample_o <= p1_y1_from_delay;
        end
        sample_valid_o <= 1'b1;
      end

      if (p1_valid && p1_last_input) begin
        draining <= 1'b1;
        drain_addr <= '0;
      end else if (draining) begin
        drain_read_valid <= 1'b1;
        drain_read_last <= (drain_addr == LAST_DELAY_ADDR);
        if (drain_addr == LAST_DELAY_ADDR) begin
          draining <= 1'b0;
          drain_addr <= '0;
        end else begin
          drain_addr <= drain_addr + 1'b1;
        end
      end

      if (drain_read_valid) begin
        sample_o <= y1_delay_dout;
        sample_valid_o <= 1'b1;

        if (drain_read_last) begin
          frame_seen <= 1'b0;
          done_o <= 1'b1;
        end
      end
    end
  end

endmodule: butterfly_static_sdf_stage
