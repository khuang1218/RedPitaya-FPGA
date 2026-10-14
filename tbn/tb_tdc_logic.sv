`timescale 1ns/1ps

module tb_tdc_logic;
  localparam int NUM_TAPS = 16;
  localparam int INDEX_W = 4;

  logic clk = 1'b0;
  logic rstn = 1'b0;
  always #4 clk = ~clk;
  logic stim_clk = 1'b0;
  always #3 stim_clk = ~stim_clk;

  logic encoder_start;
  logic [NUM_TAPS-1:0] raw_taps;
  logic encoder_busy;
  logic encoder_done;
  logic [INDEX_W-1:0] fine_index;
  logic [7:0] encoder_status;

  logic fifo_clear;
  logic fifo_push;
  logic [127:0] fifo_push_data;
  logic fifo_pop;
  logic [127:0] fifo_snapshot;
  logic [2:0] fifo_level;
  logic fifo_full;
  logic fifo_empty;
  logic fifo_overflow;
  logic fifo_underflow;
  logic internal_stimulus_enable;
  logic internal_stimulus_event;

  tdc_internal_stimulus #(
    .DIVIDER_BIT(1)
  ) dut_internal_stimulus (
    .clk_i(stim_clk),
    .rstn_i(rstn),
    .enable_async_i(internal_stimulus_enable),
    .event_o(internal_stimulus_event)
  );

  // This block instantiates the real MMCME2_ADV primitive through the
  // Xilinx UNISIM behavioural simulation model, so it must be run inside
  // Vivado behavioural simulation like the rest of tb_tdc_logic; it checks
  // the PSCLK/PSEN/PSDONE controller protocol, phase-count bookkeeping and
  // one-edge-per-fire behaviour. It cannot and does not claim to verify real
  // picosecond phase-shift accuracy -- see HANDOVER section 2.6.
  logic mmcm_reset;
  logic mmcm_ps_request;
  logic mmcm_ps_incdec;
  logic mmcm_phase_count_clear;
  logic mmcm_timeout_clear;
  logic [15:0] mmcm_coarse_delay;
  logic mmcm_fire;
  logic mmcm_locked;
  logic mmcm_ps_busy;
  logic mmcm_ps_timeout;
  logic signed [31:0] mmcm_phase_count;
  logic mmcm_event;

  tdc_mmcm_stimulus #(
    .STRETCH_CYCLES(4),
    .PS_TIMEOUT_CYCLES(64)
  ) dut_mmcm_stimulus (
    .clk_i               (clk),
    .rstn_i              (rstn),
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

  tdc_thermometer_encoder #(
    .NUM_TAPS(NUM_TAPS),
    .INDEX_W(INDEX_W)
  ) dut_encoder (
    .clk_i(clk),
    .rstn_i(rstn),
    .start_i(encoder_start),
    .raw_taps_i(raw_taps),
    .busy_o(encoder_busy),
    .done_o(encoder_done),
    .fine_index_o(fine_index),
    .status_o(encoder_status)
  );

  tdc_result_fifo #(
    .DATA_W(128),
    .DEPTH(4),
    .ADDR_W(2)
  ) dut_fifo (
    .clk_i(clk),
    .rstn_i(rstn),
    .clear_i(fifo_clear),
    .push_i(fifo_push),
    .push_data_i(fifo_push_data),
    .pop_i(fifo_pop),
    .snapshot_o(fifo_snapshot),
    .level_o(fifo_level),
    .full_o(fifo_full),
    .empty_o(fifo_empty),
    .overflow_o(fifo_overflow),
    .underflow_o(fifo_underflow)
  );

  task automatic encode_and_check(
    input logic [NUM_TAPS-1:0] pattern,
    input logic [INDEX_W-1:0] expected_index,
    input logic [7:0] required_status,
    input logic [7:0] forbidden_status
  );
    begin
      @(negedge clk);
      raw_taps = pattern;
      encoder_start = 1'b1;
      @(posedge clk);
      @(negedge clk);
      encoder_start = 1'b0;
      wait (encoder_done);
      if (fine_index !== expected_index)
        $fatal(1, "index mismatch: pattern=%h expected=%0d actual=%0d",
               pattern, expected_index, fine_index);
      if ((encoder_status & required_status) != required_status)
        $fatal(1, "required status missing: pattern=%h required=%h actual=%h",
               pattern, required_status, encoder_status);
      if ((encoder_status & forbidden_status) != 0)
        $fatal(1, "forbidden status present: pattern=%h forbidden=%h actual=%h",
               pattern, forbidden_status, encoder_status);
      @(posedge clk);
    end
  endtask

  task automatic fifo_push_value(input logic [127:0] value);
    begin
      @(negedge clk);
      fifo_push_data = value;
      fifo_push = 1'b1;
      @(posedge clk);
      @(negedge clk);
      fifo_push = 1'b0;
      @(posedge clk);
      #1;
    end
  endtask

  task automatic fifo_pop_and_check(input logic [127:0] value);
    begin
      @(negedge clk);
      fifo_pop = 1'b1;
      @(posedge clk);
      @(negedge clk);
      fifo_pop = 1'b0;
      @(posedge clk);
      #1;
      if (fifo_snapshot !== value)
        $fatal(1, "FIFO order mismatch: expected=%h actual=%h", value, fifo_snapshot);
    end
  endtask

  initial begin
    encoder_start = 1'b0;
    raw_taps = '0;
    fifo_clear = 1'b0;
    fifo_push = 1'b0;
    fifo_push_data = '0;
    fifo_pop = 1'b0;
    internal_stimulus_enable = 1'b0;

    mmcm_reset               = 1'b0;
    mmcm_ps_request          = 1'b0;
    mmcm_ps_incdec           = 1'b0;
    mmcm_phase_count_clear   = 1'b0;
    mmcm_timeout_clear       = 1'b0;
    mmcm_coarse_delay        = 16'd0;
    mmcm_fire                = 1'b0;

    repeat (3) @(posedge clk);
    rstn = 1'b1;
    @(posedge clk);

    // Eight leading ones: normal transition at tap 8.
    encode_and_check(16'h00ff, 4'd8, 8'h01, 8'h1e);

    // One interior zero is repaired by the three-tap majority filter.
    encode_and_check(16'h00f7, 4'd8, 8'h21, 8'h1e);

    // A stable second run of ones is rejected as multiple transitions.
    encode_and_check(16'h071f, 4'd5, 8'h04, 8'h01);

    encode_and_check(16'h0000, 4'd0, 8'h0a, 8'h01);
    encode_and_check(16'hffff, 4'd15, 8'h12, 8'h01);

    fifo_push_value(128'h1111);
    fifo_push_value(128'h2222);
    if (fifo_level != 2)
      $fatal(1, "FIFO level mismatch after pushes: %0d", fifo_level);
    fifo_pop_and_check(128'h1111);
    fifo_pop_and_check(128'h2222);
    if (!fifo_empty)
      $fatal(1, "FIFO did not return to empty");

    fifo_push_value(128'ha);
    fifo_push_value(128'hb);
    fifo_push_value(128'hc);
    fifo_push_value(128'hd);
    if (!fifo_full)
      $fatal(1, "FIFO did not report full");
    @(negedge clk);
    fifo_push_data = 128'he;
    fifo_push = 1'b1;
    @(posedge clk);
    @(negedge clk);
    if (!fifo_overflow)
      $fatal(1, "FIFO overflow was not reported");
    fifo_push = 1'b0;

    fifo_pop_and_check(128'ha);
    fifo_pop_and_check(128'hb);
    fifo_pop_and_check(128'hc);
    fifo_pop_and_check(128'hd);
    @(negedge clk);
    fifo_pop = 1'b1;
    @(posedge clk);
    @(negedge clk);
    if (!fifo_underflow)
      $fatal(1, "FIFO underflow was not reported");
    fifo_pop = 1'b0;

    // The internal source must remain quiet while disabled, toggle from its
    // independent clock when enabled, and return low after disable.
    repeat (4) @(posedge stim_clk);
    if (internal_stimulus_event !== 1'b0)
      $fatal(1, "Internal TDC stimulus was active while disabled");
    internal_stimulus_enable = 1'b1;
    wait (internal_stimulus_event === 1'b1);
    wait (internal_stimulus_event === 1'b0);
    wait (internal_stimulus_event === 1'b1);
    internal_stimulus_enable = 1'b0;
    repeat (4) @(posedge stim_clk);
    #1;
    if (internal_stimulus_event !== 1'b0)
      $fatal(1, "Internal TDC stimulus did not stop low");

    // Dedicated MMCM phase-sweep controller: wait for LOCKED, request one
    // increment step and confirm PSDONE completes it within the timeout,
    // confirm the accumulated phase count moves by exactly one, fire exactly
    // one measurement edge and confirm it returns low, then confirm a
    // requested decrement and a phase-count clear behave as documented.
    wait (mmcm_locked === 1'b1);

    @(negedge clk);
    mmcm_ps_incdec  = 1'b1;
    mmcm_ps_request = 1'b1;
    @(posedge clk);
    @(negedge clk);
    mmcm_ps_request = 1'b0;
    wait (mmcm_ps_busy === 1'b1);
    wait (mmcm_ps_busy === 1'b0);
    if (mmcm_ps_timeout)
      $fatal(1, "MMCM phase step reported a timeout instead of PSDONE");
    if (mmcm_phase_count !== 32'sd1)
      $fatal(1, "MMCM phase count after one increment: expected=1 actual=%0d", mmcm_phase_count);

    @(negedge clk);
    mmcm_fire = 1'b1;
    @(posedge clk);
    @(negedge clk);
    mmcm_fire = 1'b0;
    wait (mmcm_event === 1'b1);
    wait (mmcm_event === 1'b0);

    @(negedge clk);
    mmcm_ps_incdec  = 1'b0;
    mmcm_ps_request = 1'b1;
    @(posedge clk);
    @(negedge clk);
    mmcm_ps_request = 1'b0;
    wait (mmcm_ps_busy === 1'b1);
    wait (mmcm_ps_busy === 1'b0);
    if (mmcm_phase_count !== 32'sd0)
      $fatal(1, "MMCM phase count after matching decrement: expected=0 actual=%0d", mmcm_phase_count);

    @(negedge clk);
    mmcm_phase_count_clear = 1'b1;
    @(posedge clk);
    @(negedge clk);
    mmcm_phase_count_clear = 1'b0;
    if (mmcm_phase_count !== 32'sd0)
      $fatal(1, "MMCM phase count did not clear: actual=%0d", mmcm_phase_count);

    $display("tb_tdc_logic PASS");
    $finish;
  end

  initial begin
    #200000;
    $fatal(1, "tb_tdc_logic timeout");
  end

endmodule
