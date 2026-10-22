////////////////////////////////////////////////////////////////////////////////
// LVDS launch, selectable LVDS / single-ended return TDC top level.
////////////////////////////////////////////////////////////////////////////////

(* KEEP_HIERARCHY = "TRUE" *)
module tdc_top #(
  parameter int unsigned NUM_CARRY4 = 128,
  parameter int unsigned NUM_TAPS   = NUM_CARRY4 * 4,
  parameter int unsigned INDEX_W    = $clog2(NUM_TAPS),
  parameter int unsigned FIFO_DEPTH = 256,
  parameter int unsigned FIFO_AW    = $clog2(FIFO_DEPTH),
  parameter bit          INVERT_TAPS = 1'b0,
  parameter bit          RETURN_DIFF_TERM = 1'b1
)(
  input  logic                clk_i,
  input  logic                rstn_i,
  input  logic                test_clk_i,
  input  logic                test_rstn_i,
  input  logic                fast_clk_i,
  input  logic                pulse_cycle_start_i,
  input  logic [31:0]         pulse_period_i,

  output logic                launch_p_o,
  output logic                launch_n_o,
  input  logic                return_p_i,
  input  logic                return_n_i,
  input  logic                return_single_i,

  input  logic [31:0]         sys_addr_i,
  input  logic [31:0]         sys_wdata_i,
  input  logic                sys_wen_i,
  input  logic                sys_ren_i,
  output logic [31:0]         sys_rdata_o,
  output logic                sys_err_o,
  output logic                sys_ack_o
);

  localparam logic [7:0] STATUS_TIMEOUT      = 8'h40;
  localparam logic [7:0] STATUS_FIFO_OVERFLOW = 8'h80;

  typedef enum logic [3:0] {
    ST_IDLE,
    ST_WAIT_RETURN,
    ST_CAPTURE,
    ST_START_ENCODE,
    ST_WAIT_ENCODE,
    ST_MULTIPLY,
    ST_PARTIAL_SUM,
    ST_PRODUCT_SUM,
    ST_SELECT_FINE,
    ST_SUBTRACT_LOW,
    ST_SUBTRACT_HIGH,
    ST_CALCULATE,
    ST_PUSH,
    ST_WAIT_LOW
  } tdc_state_t;

  tdc_state_t state;

  logic launch_internal;
  logic return_event;
  logic single_ended_select;
  logic internal_test_event;
  logic mmcm_event;
  logic measurement_event;
  (* ASYNC_REG = "TRUE" *) logic return_sync_meta;
  (* ASYNC_REG = "TRUE" *) logic return_sync;
  logic [NUM_TAPS-1:0] sampled_taps;
  logic [NUM_TAPS-1:0] captured_taps;
  logic core_rstn;
  // Break the 512-tap event reduction before it reaches controller enables.
  // The two-stage tap delay matches the two-stage reduction, so captured_taps
  // and the timestamp adjustment below still describe the same FDRE sample.
  localparam int unsigned EVENT_GROUP_SIZE=32;
  localparam int unsigned EVENT_GROUPS=(NUM_TAPS+EVENT_GROUP_SIZE-1)/EVENT_GROUP_SIZE;
  logic [EVENT_GROUPS-1:0] event_group_nonzero;
  logic legacy_sample_nonzero;
  logic [1:0] legacy_timeout_pipe;
  (* SHREG_EXTRACT="NO" *) logic [NUM_TAPS-1:0] legacy_taps_d1, legacy_taps_d2;
  always_ff @(posedge clk_i) begin
    legacy_taps_d1<=sampled_taps;
    legacy_taps_d2<=legacy_taps_d1;
    if (!core_rstn) legacy_sample_nonzero<=0;
    else legacy_sample_nonzero<=|event_group_nonzero;
  end
  for (genvar group_index=0; group_index<EVENT_GROUPS; group_index=group_index+1) begin : gen_event_group
    localparam int unsigned GROUP_WIDTH=
      (NUM_TAPS-group_index*EVENT_GROUP_SIZE<EVENT_GROUP_SIZE) ?
       NUM_TAPS-group_index*EVENT_GROUP_SIZE : EVENT_GROUP_SIZE;
    always_ff @(posedge clk_i) begin
      if (!core_rstn) event_group_nonzero[group_index]<=0;
      else event_group_nonzero[group_index]<=
        |sampled_taps[group_index*EVENT_GROUP_SIZE +: GROUP_WIDTH];
    end
  end

  logic enable;
  logic continuous;
  logic raw_capture_enable;
  logic histogram_enable;
  logic use_calibration;
  logic calibration_mode;
  logic internal_test_enable;
  logic mmcm_sweep_enable;
  logic mmcm_reset;
  logic mmcm_ps_request;
  logic mmcm_ps_incdec;
  logic mmcm_phase_count_clear;
  logic mmcm_timeout_clear;
  logic [15:0] mmcm_coarse_delay;
  logic mmcm_locked;
  logic mmcm_ps_busy;
  logic mmcm_ps_timeout;
  logic signed [31:0] mmcm_phase_count;
  logic mmcm_fire;
  logic trigger;
  logic trigger_pending;
  logic soft_reset;
  logic fifo_clear;
  logic [31:0] launch_period;
  logic [31:0] launch_width;
  logic [31:0] timeout_cycles;
  logic [31:0] clock_period_ps;
  logic [31:0] calibration_target;
  logic calibration_complete;
  logic width_busy, width_select;
  logic [31:0] legacy_rdata, width_rdata;
  logic legacy_ack, legacy_err, width_ack, width_err;
  assign width_select=sys_addr_i[15:8]==8'h01;
  assign sys_rdata_o=width_select ? width_rdata : legacy_rdata;
  assign sys_ack_o=width_select ? width_ack : legacy_ack;
  assign sys_err_o=width_select ? width_err : legacy_err;

  tdc_pulse_width #(.NUM_CARRY4(NUM_CARRY4),.NUM_TAPS(NUM_TAPS),.INDEX_W(INDEX_W)) i_width (
    .bus_clk_i(clk_i),.fast_clk_i(fast_clk_i),.rstn_i(rstn_i),
    .event_i(single_ended_select ? return_single_i : return_event),
    .cycle_start_i(pulse_cycle_start_i),.pulse_period_i(pulse_period_i),
    .input_select_i(single_ended_select),
    .legacy_conflict_i(enable || internal_test_enable || mmcm_sweep_enable || state!=ST_IDLE),
    .busy_o(width_busy),.sys_addr_i(sys_addr_i),.sys_wdata_i(sys_wdata_i),
    .sys_wen_i(sys_wen_i && width_select),.sys_ren_i(sys_ren_i && width_select),
    .sys_rdata_o(width_rdata),.sys_ack_o(width_ack),.sys_err_o(width_err));

  logic [31:0] coarse_counter;
  logic [31:0] launch_counter;
  logic [31:0] capture_coarse;
  logic [31:0] wait_counter;
  logic [31:0] idle_period_counter;
  logic [31:0] launch_countdown;
  // Delay timeout by the same two clocks as event detection, preserving
  // acceptance of samples from the last two original observation clocks.
  always_ff @(posedge clk_i) begin
    if (!core_rstn || state!=ST_WAIT_RETURN) legacy_timeout_pipe<=0;
    else legacy_timeout_pipe<={legacy_timeout_pipe[0],
      wait_counter>=timeout_cycles-1'b1};
  end

  logic encoder_start;
  logic encoder_busy;
  logic encoder_done;
  logic [INDEX_W-1:0] encoder_index;
  logic [7:0] encoder_status;

  logic [INDEX_W-1:0] captured_fine_raw;
  logic [7:0] captured_status;
  logic [15:0] selected_fine_ps;
  logic [63:0] approximate_fine_product;
  logic [63:0] coarse_time_product;
  logic [63:0] calculated_total_ps;
  logic [31:0] product00, product01, product10, product11;
  logic [INDEX_W+15:0] fine_product_lo, fine_product_hi;
  logic [63:0] product_sum_a, product_sum_b;
  logic [32:0] total_low;

  logic [31:0] last_coarse;
  logic [INDEX_W-1:0] last_fine_raw;
  logic [15:0] last_fine_ps;
  logic [45:0] last_total_ps;
  logic [7:0] last_status;
  logic [15:0] last_sequence;
  logic [15:0] sequence_counter;
  logic [31:0] event_count;
  logic [31:0] error_count;

  logic fifo_push;
  logic fifo_pop;
  logic [127:0] fifo_push_data;
  logic [127:0] fifo_snapshot;
  logic [FIFO_AW:0] fifo_level;
  logic fifo_full;
  logic fifo_empty;
  logic fifo_overflow;
  logic fifo_underflow;

  logic [INDEX_W-1:0] calibration_addr;
  logic [15:0] calibration_write_data;
  logic calibration_write;
  logic calibration_invalidate;
  logic calibration_activate;
  logic histogram_clear;
  logic [15:0] calibration_read_data;
  logic [31:0] histogram_read_data;
  logic calibration_active_bank;
  logic calibration_inactive_ready;
  logic histogram_clear_busy;
  logic histogram_increment;
  logic [15:0] calibration_lookup_data;

  assign core_rstn = rstn_i & ~soft_reset;
  assign measurement_event = mmcm_sweep_enable ? mmcm_event :
                             (internal_test_enable ? internal_test_event :
                              (single_ended_select ? return_single_i : return_event));
  // The external event goes directly to the delay line. Synchronizing it here
  // would remove the sub-clock arrival information being measured.

  tdc_internal_stimulus #(
    .DIVIDER_BIT(10)
  ) i_internal_stimulus (
    .clk_i          (test_clk_i),
    .rstn_i         (test_rstn_i),
    .enable_async_i (internal_test_enable),
    .event_o        (internal_test_event)
  );

  // Dedicated MMCM phase-sweep self-test source.  Its own reset is rstn_i
  // (not core_rstn) so the MMCM stays locked and the accumulated phase count
  // survives a TDC soft reset, matching the existing internal-source
  // preservation behaviour.
  tdc_mmcm_stimulus i_mmcm_stimulus (
    .clk_i               (clk_i),
    .rstn_i              (rstn_i),
    .mmcm_reset_i        (mmcm_reset),
    .ps_request_i        (mmcm_ps_request),
    .ps_incdec_i         (mmcm_ps_incdec),
    .phase_count_clear_i (mmcm_phase_count_clear),
    .timeout_clear_i     (mmcm_timeout_clear),
    .coarse_delay_i      (mmcm_coarse_delay),
    .fire_i              (mmcm_fire),
    .locked_o            (mmcm_locked),
    .ps_busy_o           (mmcm_ps_busy),
    .ps_timeout_o        (mmcm_ps_timeout),
    .phase_count_o       (mmcm_phase_count),
    .event_o             (mmcm_event)
  );

  tdc_lvds_io #(
    .RETURN_DIFF_TERM(RETURN_DIFF_TERM)
  ) i_lvds (
    .launch_i       (launch_internal && !width_busy),
    .launch_p_o     (launch_p_o),
    .launch_n_o     (launch_n_o),
    .return_p_i     (return_p_i),
    .return_n_i     (return_n_i),
    .return_event_o (return_event)
  );

  tdc_carry_chain #(
    .NUM_CARRY4(NUM_CARRY4),
    .NUM_TAPS(NUM_TAPS),
    .INVERT_TAPS(INVERT_TAPS)
  ) i_carry (
    .clk_i          (clk_i),
    .rstn_i         (core_rstn),
    .event_i        (measurement_event),
    .sampled_taps_o (sampled_taps)
  );

  tdc_thermometer_encoder #(
    .NUM_TAPS(NUM_TAPS),
    .INDEX_W(INDEX_W)
  ) i_encoder (
    .clk_i        (clk_i),
    .rstn_i       (core_rstn),
    .start_i      (encoder_start),
    .raw_taps_i   (captured_taps),
    .busy_o       (encoder_busy),
    .done_o       (encoder_done),
    .fine_index_o (encoder_index),
    .status_o     (encoder_status)
  );

  tdc_calibration_mem #(
    .NUM_TAPS(NUM_TAPS),
    .INDEX_W(INDEX_W)
  ) i_calibration (
    .clk_i                    (clk_i),
    .rstn_i                   (rstn_i),
    .lookup_addr_i            (captured_fine_raw),
    .lookup_data_o            (calibration_lookup_data),
    .sw_addr_i                (calibration_addr),
    .sw_write_data_i          (calibration_write_data),
    .sw_write_i               (calibration_write),
    .sw_read_data_o           (calibration_read_data),
    .invalidate_inactive_i    (calibration_invalidate),
    .activate_i               (calibration_activate),
    .active_bank_o            (calibration_active_bank),
    .inactive_bank_ready_o    (calibration_inactive_ready),
    .histogram_clear_i        (histogram_clear),
    .histogram_increment_i    (histogram_increment),
    .histogram_index_i        (captured_fine_raw),
    .histogram_data_o         (histogram_read_data),
    .histogram_clear_busy_o   (histogram_clear_busy)
  );

  tdc_result_fifo #(
    .DATA_W(128),
    .DEPTH(FIFO_DEPTH),
    .ADDR_W(FIFO_AW)
  ) i_result_fifo (
    .clk_i       (clk_i),
    .rstn_i      (core_rstn),
    .clear_i     (fifo_clear),
    .push_i      (fifo_push),
    .push_data_i (fifo_push_data),
    .pop_i       (fifo_pop),
    .snapshot_o  (fifo_snapshot),
    .level_o     (fifo_level),
    .full_o      (fifo_full),
    .empty_o     (fifo_empty),
    .overflow_o  (fifo_overflow),
    .underflow_o (fifo_underflow)
  );

  tdc_registers #(
    .NUM_TAPS(NUM_TAPS),
    .INDEX_W(INDEX_W),
    .FIFO_AW(FIFO_AW)
  ) i_registers (
    .clk_i                       (clk_i),
    .rstn_i                      (rstn_i),
    .acquisition_lock_i          (width_busy),
    .sys_addr_i                  (sys_addr_i),
    .sys_wdata_i                 (sys_wdata_i),
    .sys_wen_i                   (sys_wen_i && !width_select),
    .sys_ren_i                   (sys_ren_i && !width_select),
    .sys_rdata_o                 (legacy_rdata),
    .sys_err_o                   (legacy_err),
    .sys_ack_o                   (legacy_ack),
    .enable_o                    (enable),
    .continuous_o                (continuous),
    .raw_capture_enable_o        (raw_capture_enable),
    .histogram_enable_o          (histogram_enable),
    .use_calibration_o           (use_calibration),
    .calibration_mode_o          (calibration_mode),
    .internal_test_enable_o      (internal_test_enable),
    .mmcm_sweep_enable_o         (mmcm_sweep_enable),
    .single_ended_select_o       (single_ended_select),
    .mmcm_reset_o                (mmcm_reset),
    .mmcm_ps_request_o           (mmcm_ps_request),
    .mmcm_ps_incdec_o            (mmcm_ps_incdec),
    .mmcm_phase_count_clear_o    (mmcm_phase_count_clear),
    .mmcm_timeout_clear_o        (mmcm_timeout_clear),
    .mmcm_coarse_delay_o         (mmcm_coarse_delay),
    .mmcm_locked_i               (mmcm_locked),
    .mmcm_ps_busy_i              (mmcm_ps_busy),
    .mmcm_ps_timeout_i           (mmcm_ps_timeout),
    .mmcm_phase_count_i          (mmcm_phase_count),
    .trigger_o                   (trigger),
    .soft_reset_o                (soft_reset),
    .fifo_clear_o                (fifo_clear),
    .launch_period_o             (launch_period),
    .launch_width_o              (launch_width),
    .timeout_cycles_o            (timeout_cycles),
    .clock_period_ps_o           (clock_period_ps),
    .calibration_target_o        (calibration_target),
    .busy_i                      (state != ST_IDLE || width_busy),
    .last_coarse_i               (last_coarse),
    .last_fine_raw_i             (last_fine_raw),
    .last_fine_ps_i              (last_fine_ps),
    .last_total_ps_i             (last_total_ps),
    .last_status_i               (last_status),
    .last_sequence_i             (last_sequence),
    .event_count_i               (event_count),
    .error_count_i               (error_count),
    .raw_taps_i                  (captured_taps),
    .fifo_level_i                (fifo_level),
    .fifo_full_i                 (fifo_full),
    .fifo_empty_i                (fifo_empty),
    .fifo_overflow_i             (fifo_overflow),
    .fifo_snapshot_i             (fifo_snapshot),
    .fifo_pop_o                  (fifo_pop),
    .calibration_addr_o          (calibration_addr),
    .calibration_write_data_o    (calibration_write_data),
    .calibration_write_o         (calibration_write),
    .calibration_invalidate_o    (calibration_invalidate),
    .calibration_activate_o      (calibration_activate),
    .histogram_clear_o           (histogram_clear),
    .calibration_read_data_i     (calibration_read_data),
    .histogram_read_data_i       (histogram_read_data),
    .calibration_active_bank_i   (calibration_active_bank),
    .calibration_inactive_ready_i(calibration_inactive_ready),
    .histogram_clear_busy_i      (histogram_clear_busy),
    .calibration_complete_i      (calibration_complete)
  );

  // Arithmetic is sequenced after encoding below. Four independent 16x16
  // products avoid a chained 32x32 multiplier followed by a 64-bit subtract
  // on one bus clock. No changes to the legacy FIFO/result representation.

  always_ff @(posedge clk_i) begin
    if (!core_rstn) begin
      return_sync_meta <= 1'b0;
      return_sync      <= 1'b0;
    end else begin
      return_sync_meta <= measurement_event;
      return_sync      <= return_sync_meta;
    end
  end

  always_ff @(posedge clk_i) begin
    if (!core_rstn) begin
      state               <= ST_IDLE;
      launch_internal     <= 1'b0;
      launch_countdown    <= 32'd0;
      coarse_counter      <= 32'd0;
      launch_counter      <= 32'd0;
      capture_coarse      <= 32'd0;
      wait_counter        <= 32'd0;
      idle_period_counter <= 32'd0;
      captured_taps       <= '0;
      captured_fine_raw   <= '0;
      captured_status     <= '0;
      encoder_start       <= 1'b0;
      trigger_pending     <= 1'b0;
      histogram_increment <= 1'b0;
      fifo_push           <= 1'b0;
      mmcm_fire           <= 1'b0;
      fifo_push_data      <= '0;
      last_coarse         <= 32'd0;
      last_fine_raw       <= '0;
      last_fine_ps        <= 16'd0;
      last_total_ps       <= 46'd0;
      last_status         <= 8'd0;
      last_sequence       <= 16'd0;
      sequence_counter    <= 16'd0;
      event_count         <= 32'd0;
      error_count         <= 32'd0;
      calibration_complete <= 1'b0;
      product00<=0; product01<=0; product10<=0; product11<=0;
      fine_product_lo<=0; fine_product_hi<=0;
      product_sum_a<=0; product_sum_b<=0;
      approximate_fine_product<=0; coarse_time_product<=0;
      selected_fine_ps<=0; calculated_total_ps<=0; total_low<=0;
    end else begin
      coarse_counter      <= coarse_counter + 1'b1;
      encoder_start       <= 1'b0;
      histogram_increment <= 1'b0;
      fifo_push           <= 1'b0;
      mmcm_fire           <= 1'b0;

      // Latch a software SINGLE_TRIGGER pulse that arrives while ST_IDLE's
      // arm condition is not satisfied this cycle (e.g. the internal async
      // source is currently in its high half-period). Without this latch a
      // trigger that misses its instant is silently lost and the FIFO never
      // receives a result, which is what previously made TDC:MEASure? hang
      // until the SCPI server's own poll timeout, and then the SCPI client.
      // A later ST_IDLE arm in the same cycle (below) can still clear this
      // immediately if the condition is met right away.
      if (!enable)
        trigger_pending <= 1'b0;
      else if (trigger)
        trigger_pending <= 1'b1;

      if (launch_internal) begin
        if (launch_countdown <= 1) begin
          launch_internal  <= 1'b0;
          launch_countdown <= 32'd0;
        end else begin
          launch_countdown <= launch_countdown - 1'b1;
        end
      end

      case (state)
        ST_IDLE: begin
          wait_counter <= 32'd0;
          if (idle_period_counter != 32'hffff_ffff)
            idle_period_counter <= idle_period_counter + 1'b1;

          // A short return/encode path may finish before a wide launch.
          // Wait for its countdown to finish before starting another pulse;
          // otherwise re-arming reloads the countdown and stretches HIGH.
          if (enable && !launch_internal && !return_sync && !legacy_sample_nonzero &&
              !(calibration_mode && (histogram_clear_busy || calibration_complete))) begin
            if (calibration_mode || internal_test_enable || mmcm_sweep_enable) begin
              // Internal-test and MMCM-sweep single/continuous mode wait for
              // the next self-test edge and never drive the E3 launch.
              // Calibration mode arms immediately for every source event.
              if (calibration_mode || trigger || trigger_pending ||
                  (continuous && (idle_period_counter >= launch_period-1'b1))) begin
                launch_counter      <= coarse_counter;
                idle_period_counter <= 32'd0;
                trigger_pending     <= 1'b0;
                state               <= ST_WAIT_RETURN;
                // Only the MMCM source needs an explicit request to release
                // its one commanded edge; external/async sources are passive.
                if (mmcm_sweep_enable)
                  mmcm_fire <= 1'b1;
              end
            end else if (trigger || trigger_pending ||
                         (continuous && (idle_period_counter >= launch_period-1'b1))) begin
              launch_counter      <= coarse_counter;
              launch_internal     <= 1'b1;
              launch_countdown    <= launch_width;
              idle_period_counter <= 32'd0;
              trigger_pending     <= 1'b0;
              state               <= ST_WAIT_RETURN;
            end
          end
        end

        ST_WAIT_RETURN: begin
          wait_counter <= wait_counter + 1'b1;
          if (legacy_sample_nonzero) begin
            captured_taps  <= legacy_taps_d2;
            // sampled_taps is an FDRE bank.  The controller observes that
            // bank after its original observation clock plus two matched
            // reduction/data pipeline clocks.
            capture_coarse <= coarse_counter - launch_counter - 32'd3;
            state          <= ST_CAPTURE;
          end else if (legacy_timeout_pipe[1]) begin
            captured_taps     <= sampled_taps;
            captured_fine_raw <= '0;
            capture_coarse    <= coarse_counter - launch_counter - 32'd2;
            captured_status   <= STATUS_TIMEOUT;
            error_count       <= error_count + 1'b1;
            state             <= ST_MULTIPLY;
          end
        end

        ST_CAPTURE: begin
          state <= ST_START_ENCODE;
        end

        ST_START_ENCODE: begin
          encoder_start <= 1'b1;
          state <= ST_WAIT_ENCODE;
        end

        ST_WAIT_ENCODE: begin
          if (encoder_done) begin
            captured_fine_raw <= encoder_index;
            captured_status   <= encoder_status;
            if (encoder_status[0]) begin
              event_count <= event_count + 1'b1;
              if (histogram_enable)
                histogram_increment <= 1'b1;
            end else begin
              error_count <= error_count + 1'b1;
            end
            state <= ST_MULTIPLY;
          end
        end

        ST_MULTIPLY: begin
          product00<=capture_coarse[15:0]*clock_period_ps[15:0];
          product01<=capture_coarse[15:0]*clock_period_ps[31:16];
          product10<=capture_coarse[31:16]*clock_period_ps[15:0];
          product11<=capture_coarse[31:16]*clock_period_ps[31:16];
          fine_product_lo<=captured_fine_raw*clock_period_ps[15:0];
          fine_product_hi<=captured_fine_raw*clock_period_ps[31:16];
          state<=ST_PARTIAL_SUM;
        end
        ST_PARTIAL_SUM: begin
          product_sum_a<=64'(product00)+(64'(product01)<<16);
          product_sum_b<=(64'(product10)<<16)+(64'(product11)<<32);
          approximate_fine_product<=64'(fine_product_lo)+(64'(fine_product_hi)<<16);
          state<=ST_PRODUCT_SUM;
        end
        ST_PRODUCT_SUM: begin
          coarse_time_product<=product_sum_a+product_sum_b;
          state<=ST_SELECT_FINE;
        end
        ST_SELECT_FINE: begin
          selected_fine_ps<=captured_status[6] ? 16'd0 :
            (use_calibration ? calibration_lookup_data : 16'(approximate_fine_product/NUM_TAPS));
          state<=ST_SUBTRACT_LOW;
        end
        ST_SUBTRACT_LOW: begin
          total_low<={1'b0,coarse_time_product[31:0]}-{17'd0,selected_fine_ps};
          state<=ST_SUBTRACT_HIGH;
        end
        ST_SUBTRACT_HIGH: begin
          calculated_total_ps<=(coarse_time_product[63:32]==0 && total_low[32]) ? 64'd0 :
            {32'(coarse_time_product[63:32]-total_low[32]),total_low[31:0]};
          state<=ST_CALCULATE;
        end
        ST_CALCULATE: begin
          // Histogram RMW now has two pipeline stages before its memory write.
          // Publish calibration completion only after the arithmetic states
          // have allowed the final increment to drain (event_count is current).
          if (calibration_mode && (calibration_target != 0) &&
              (event_count >= calibration_target))
            calibration_complete <= 1'b1;
          sequence_counter <= sequence_counter + 1'b1;
          last_sequence    <= sequence_counter + 1'b1;
          last_status      <= captured_status;
          last_coarse      <= capture_coarse;
          last_fine_raw    <= captured_fine_raw;
          last_fine_ps     <= selected_fine_ps;
          last_total_ps    <= calculated_total_ps[45:0];
          // The FIFO record's documented/API-assumed layout (tdc_registers.md)
          // reserves a fixed 10-bit field for the raw fine index (bits
          // 65:56) so the wire format does not depend on INDEX_W, which is
          // only 9 bits for the current 512-tap build. Zero-extend to 10
          // bits explicitly: without this, the concatenation was only 127
          // bits wide and bit 65 (actually fine_ps's LSB) silently aliased
          // into what the API decodes as fine_raw bit 9, producing spurious
          // +512 raw-index values roughly half the time.
          fifo_push_data   <= {calculated_total_ps[45:0], selected_fine_ps,
                               {(10-INDEX_W){1'b0}}, captured_fine_raw,
                               capture_coarse,
                               captured_status, sequence_counter + 1'b1};
          // Calibration can run for millions of asynchronous events.  Those
          // events feed the histogram and last-result diagnostics but must not
          // fill the normal measurement FIFO.
          state <= calibration_mode ? ST_WAIT_LOW : ST_PUSH;
        end

        ST_PUSH: begin
          fifo_push <= 1'b1;
          if (fifo_full) begin
            last_status <= last_status | STATUS_FIFO_OVERFLOW;
            error_count <= error_count + 1'b1;
          end
          state <= ST_WAIT_LOW;
        end

        ST_WAIT_LOW: begin
          if (!return_sync && !legacy_sample_nonzero)
            state <= ST_IDLE;
        end

        default: state <= ST_IDLE;
      endcase
    end
  end

endmodule: tdc_top
