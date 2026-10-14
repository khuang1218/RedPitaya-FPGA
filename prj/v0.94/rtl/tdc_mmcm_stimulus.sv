////////////////////////////////////////////////////////////////////////////////
// Dedicated MMCM phase-sweep self-test source for the LVDS CARRY4 TDC.
//
// This block belongs only to the TDC self-test. It does not touch
// red_pitaya_pll (the shared PLLE2_ADV that clocks the ADC/DAC/serial/PWM
// paths) and must not be used to imply that PLL's phase c46an move.
//
// A dedicated MMCME2_ADV is fed from the same adc_clk reference used
// elsewhere in the TDC (clk_i) and regenerates a same-frequency output
// (CLKOUT0) whose phase relative to clk_i can be stepped one dynamic
// phase-shift increment at a time through PSCLK/PSEN/PSINCDEC/PSDONE.  A
// software-issued "fire" request is translated into exactly one rising edge
// on that phase-shifted clock, after an optional extra whole-clk_i-cycle
// coarse delay, and that single edge feeds the existing CARRY4 measurement
// input. This produces a commanded nominal coarse+fine phase for boundary,
// monotonicity and repeatability testing without external hardware.  It does
// not calibrate absolute picoseconds and does not exercise the E3 electrical
// path -- see doc/tdc_registers.md.
//
// With CLKIN1_PERIOD = 8.000 ns (125 MHz), CLKFBOUT_MULT_F = 8 and
// DIVCLK_DIVIDE = 1, the VCO runs at 1000 MHz and the nominal dynamic
// phase-shift step is 1 / (56 * 1000 MHz) = ~17.86 ps, matching the
// handover's worked example.  CLKOUT0_DIVIDE_F = 8 regenerates 125 MHz.
////////////////////////////////////////////////////////////////////////////////

(* KEEP_HIERARCHY = "TRUE" *)
module tdc_mmcm_stimulus #(
  parameter int unsigned STRETCH_CYCLES    = 4,   // event_o hold time, in CLKOUT0 cycles
  parameter int unsigned PS_TIMEOUT_CYCLES = 256   // PSDONE watchdog, in clk_i cycles
)(
  input  logic        clk_i,               // adc_clk reference; also drives PSCLK
  input  logic        rstn_i,

  // Register-driven control, all on clk_i
  input  logic         mmcm_reset_i,        // pulse: reinitialize the MMCM
  input  logic         ps_request_i,        // pulse: request one phase step
  input  logic         ps_incdec_i,         // 1 = increase delay, 0 = decrease
  input  logic         phase_count_clear_i, // pulse: zero the accumulated step count
  input  logic         timeout_clear_i,     // pulse: clear the sticky PS timeout flag
  input  logic [15:0]  coarse_delay_i,      // extra whole clk_i cycles before firing
  input  logic         fire_i,              // pulse: request exactly one measurement edge

  output logic              locked_o,
  output logic              ps_busy_o,
  output logic              ps_timeout_o,
  output logic signed [31:0] phase_count_o,
  output logic              event_o          // feeds the carry-chain measurement input
);

  logic clk_fb;
  logic clk_fb_buf;
  logic clkout0_raw;
  logic test_edge_clk;
  logic mmcm_locked_raw;
  logic psdone_raw;
  logic mmcm_rst;
  logic psen_r;
  logic psincdec_r;

  logic [3:0] mmcm_rst_stretch;

  // Hold RST for a few clk_i cycles on either the global reset or a software
  // reinitialize request; MMCME2_ADV requires RST to be held, not pulsed for
  // a single cycle.
  always_ff @(posedge clk_i) begin
    if (!rstn_i)
      mmcm_rst_stretch <= 4'hf;
    else if (mmcm_reset_i)
      mmcm_rst_stretch <= 4'hf;
    else if (mmcm_rst_stretch != 4'h0)
      mmcm_rst_stretch <= mmcm_rst_stretch - 1'b1;
  end
  assign mmcm_rst = (mmcm_rst_stretch != 4'h0);

  MMCME2_ADV #(
    .BANDWIDTH            ("OPTIMIZED"),
    .CLKIN1_PERIOD        (8.000),
    .CLKIN2_PERIOD        (8.000),
    .REF_JITTER1          (0.010),
    .DIVCLK_DIVIDE        (1),
    .CLKFBOUT_MULT_F      (8.000),
    .CLKFBOUT_PHASE       (0.000),
    .CLKFBOUT_USE_FINE_PS ("FALSE"),
    .CLKOUT0_DIVIDE_F     (8.000),
    .CLKOUT0_PHASE        (0.000),
    .CLKOUT0_DUTY_CYCLE   (0.500),
    .CLKOUT0_USE_FINE_PS  ("TRUE"),
    .COMPENSATION         ("ZHOLD"),
    .STARTUP_WAIT         ("FALSE")
  ) u_mmcm (
    .CLKFBOUT     (clk_fb),
    .CLKFBOUTB    (),
    .CLKOUT0      (clkout0_raw),
    .CLKOUT0B     (),
    .CLKOUT1      (),
    .CLKOUT1B     (),
    .CLKOUT2      (),
    .CLKOUT2B     (),
    .CLKOUT3      (),
    .CLKOUT3B     (),
    .CLKOUT4      (),
    .CLKOUT5      (),
    .CLKOUT6      (),
    .CLKFBIN      (clk_fb_buf),
    .CLKIN1       (clk_i),
    .CLKIN2       (1'b0),
    .CLKINSEL     (1'b1),
    .DADDR        (7'h0),
    .DCLK         (1'b0),
    .DEN          (1'b0),
    .DI           (16'h0),
    .DO           (),
    .DRDY         (),
    .DWE          (1'b0),
    .PSCLK        (clk_i),
    .PSEN         (psen_r),
    .PSINCDEC     (psincdec_r),
    .PSDONE       (psdone_raw),
    .LOCKED       (mmcm_locked_raw),
    .CLKINSTOPPED (),
    .CLKFBSTOPPED (),
    .PWRDWN       (1'b0),
    .RST          (mmcm_rst)
  );

  BUFG u_bufg_fb  (.I(clk_fb),      .O(clk_fb_buf));
  BUFG u_bufg_out (.I(clkout0_raw), .O(test_edge_clk));

  // --- LOCKED synchronization into clk_i -----------------------------------
  (* ASYNC_REG = "TRUE" *) logic locked_meta, locked_sync;
  always_ff @(posedge clk_i) begin
    if (!rstn_i) begin
      locked_meta <= 1'b0;
      locked_sync <= 1'b0;
    end else begin
      locked_meta <= mmcm_locked_raw;
      locked_sync <= locked_meta;
    end
  end
  assign locked_o = locked_sync;

  // --- Dynamic phase-shift controller, entirely on clk_i (== PSCLK) -------
  typedef enum logic [1:0] {PS_IDLE, PS_ASSERT, PS_WAIT} ps_state_t;
  ps_state_t ps_state;
  logic [$clog2(PS_TIMEOUT_CYCLES+1)-1:0] ps_timeout_counter;

  always_ff @(posedge clk_i) begin
    if (!rstn_i) begin
      ps_state            <= PS_IDLE;
      psen_r               <= 1'b0;
      psincdec_r           <= 1'b0;
      ps_busy_o            <= 1'b0;
      ps_timeout_o         <= 1'b0;
      ps_timeout_counter   <= '0;
      phase_count_o        <= 32'sd0;
    end else begin
      psen_r <= 1'b0;

      if (phase_count_clear_i)
        phase_count_o <= 32'sd0;
      if (timeout_clear_i)
        ps_timeout_o <= 1'b0;

      case (ps_state)
        PS_IDLE: begin
          ps_busy_o <= 1'b0;
          if (ps_request_i && locked_sync) begin
            psen_r             <= 1'b1;
            psincdec_r         <= ps_incdec_i;
            ps_busy_o          <= 1'b1;
            ps_timeout_counter <= '0;
            ps_state           <= PS_WAIT;
          end
        end

        PS_WAIT: begin
          ps_timeout_counter <= ps_timeout_counter + 1'b1;
          if (psdone_raw) begin
            phase_count_o <= psincdec_r ? phase_count_o + 32'sd1 : phase_count_o - 32'sd1;
            ps_busy_o     <= 1'b0;
            ps_state      <= PS_IDLE;
          end else if (ps_timeout_counter >= PS_TIMEOUT_CYCLES - 1) begin
            ps_timeout_o <= 1'b1;
            ps_busy_o    <= 1'b0;
            ps_state     <= PS_IDLE;
          end
        end

        default: ps_state <= PS_IDLE;
      endcase
    end
  end

  // --- Fire request: optional whole-cycle coarse delay, then a single
  //     clk_i-domain toggle that is handed to the phase-shifted clock domain.
  logic [15:0] fire_delay_counter;
  logic        fire_pending;
  logic        fire_toggle;

  always_ff @(posedge clk_i) begin
    if (!rstn_i) begin
      fire_pending       <= 1'b0;
      fire_delay_counter <= 16'd0;
      fire_toggle        <= 1'b0;
    end else begin
      if (fire_i && !fire_pending) begin
        fire_pending       <= 1'b1;
        fire_delay_counter <= coarse_delay_i;
      end else if (fire_pending) begin
        if (fire_delay_counter == 16'd0) begin
          fire_toggle  <= ~fire_toggle;
          fire_pending <= 1'b0;
        end else begin
          fire_delay_counter <= fire_delay_counter - 1'b1;
        end
      end
    end
  end

  // --- Toggle handed into the MMCM-phase-shifted clock domain. Only the
  //     within-one-period position is meaningful for the TDC; the extra
  //     +/-1 CLKOUT0-cycle synchronizer uncertainty is absorbed by the
  //     coarse counter exactly like the other measurement sources.
  (* ASYNC_REG = "TRUE" *) logic test_rstn_meta, test_rstn_sync;
  always_ff @(posedge test_edge_clk or negedge rstn_i) begin
    if (!rstn_i) begin
      test_rstn_meta <= 1'b0;
      test_rstn_sync <= 1'b0;
    end else begin
      test_rstn_meta <= 1'b1;
      test_rstn_sync <= test_rstn_meta;
    end
  end

  // Three synchronizing stages rather than the conventional minimum of two.
  // This specific crossing is unavoidably at risk of landing close to a
  // test_edge_clk sampling edge, because CLKOUT0's phase relative to clk_i
  // is intentionally swept through every possible offset by design (that
  // is the entire point of the phase sweep) -- for some commanded phase,
  // the fire_toggle transition WILL sit close to a test_edge_clk edge, no
  // matter where the risk window happens to fall. A third stage only gives
  // the signal one additional test_edge_clk period to finish resolving
  // before anything downstream (the stretch counter / event_reg) acts on
  // it, narrowing that risk window; it cannot eliminate it, and a random-
  // delay closed-loop test (scpi-tests/tdc_mmcm_random_delay_test.py) at a
  // dense phase sweep near any observed instability is the way to check
  // whether the window actually narrowed. Where it does not fully resolve
  // the ambiguity, that must be handled as a documented, excluded phase
  // range on the software side (like the carry-column dead zone), not by
  // trying to infer the correct coarse count from the captured (coarse,
  // fine) result after the fact -- the fine reading is identical whichever
  // way the crossing resolves, so it carries no information to disambiguate.
  (* ASYNC_REG = "TRUE" *) logic toggle_meta, toggle_sync;
  logic toggle_settled, toggle_settled_d;
  logic [$clog2(STRETCH_CYCLES+1)-1:0] stretch_counter;
  logic event_reg;

  always_ff @(posedge test_edge_clk) begin
    if (!test_rstn_sync) begin
      toggle_meta      <= 1'b0;
      toggle_sync      <= 1'b0;
      toggle_settled   <= 1'b0;
      toggle_settled_d <= 1'b0;
      stretch_counter  <= '0;
      event_reg        <= 1'b0;
    end else begin
      toggle_meta      <= fire_toggle;
      toggle_sync      <= toggle_meta;
      toggle_settled   <= toggle_sync;
      toggle_settled_d <= toggle_settled;

      if (toggle_settled ^ toggle_settled_d) begin
        event_reg       <= 1'b1;
        stretch_counter <= STRETCH_CYCLES[$bits(stretch_counter)-1:0];
      end else if (stretch_counter != 0) begin
        stretch_counter <= stretch_counter - 1'b1;
        if (stretch_counter == 1)
          event_reg <= 1'b0;
      end
    end
  end

  assign event_o = event_reg;

endmodule: tdc_mmcm_stimulus
