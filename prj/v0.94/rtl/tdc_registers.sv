////////////////////////////////////////////////////////////////////////////////
// TDC system-bus registers.  This slave is routed only for slot-7 subregion
// 0x10000 by the local decoder in red_pitaya_top_LED7_mod.sv.
////////////////////////////////////////////////////////////////////////////////

module tdc_registers #(
  parameter int unsigned NUM_TAPS = 512,
  parameter int unsigned INDEX_W  = $clog2(NUM_TAPS),
  parameter int unsigned FIFO_AW  = 8
)(
  input  logic                    clk_i,
  input  logic                    rstn_i,
  input  logic                    acquisition_lock_i,
  input  logic [31:0]             sys_addr_i,
  input  logic [31:0]             sys_wdata_i,
  input  logic                    sys_wen_i,
  input  logic                    sys_ren_i,
  output logic [31:0]             sys_rdata_o,
  output logic                    sys_err_o,
  output logic                    sys_ack_o,

  output logic                    enable_o,
  output logic                    continuous_o,
  output logic                    raw_capture_enable_o,
  output logic                    histogram_enable_o,
  output logic                    use_calibration_o,
  output logic                    calibration_mode_o,
  output logic                    internal_test_enable_o,
  output logic                    mmcm_sweep_enable_o,
  output logic                    single_ended_select_o,
  output logic                    mmcm_reset_o,
  output logic                    mmcm_ps_request_o,
  output logic                    mmcm_ps_incdec_o,
  output logic                    mmcm_phase_count_clear_o,
  output logic                    mmcm_timeout_clear_o,
  output logic [15:0]             mmcm_coarse_delay_o,
  input  logic                    mmcm_locked_i,
  input  logic                    mmcm_ps_busy_i,
  input  logic                    mmcm_ps_timeout_i,
  input  logic signed [31:0]      mmcm_phase_count_i,
  output logic                    trigger_o,
  output logic                    soft_reset_o,
  output logic                    fifo_clear_o,
  output logic [31:0]             launch_period_o,
  output logic [31:0]             launch_width_o,
  output logic [31:0]             timeout_cycles_o,
  output logic [31:0]             clock_period_ps_o,
  output logic [31:0]             calibration_target_o,

  input  logic                    busy_i,
  input  logic [31:0]             last_coarse_i,
  input  logic [INDEX_W-1:0]      last_fine_raw_i,
  input  logic [15:0]             last_fine_ps_i,
  input  logic [45:0]             last_total_ps_i,
  input  logic [7:0]              last_status_i,
  input  logic [15:0]             last_sequence_i,
  input  logic [31:0]             event_count_i,
  input  logic [31:0]             error_count_i,
  input  logic [NUM_TAPS-1:0]     raw_taps_i,

  input  logic [FIFO_AW:0]        fifo_level_i,
  input  logic                    fifo_full_i,
  input  logic                    fifo_empty_i,
  input  logic                    fifo_overflow_i,
  input  logic [127:0]            fifo_snapshot_i,
  output logic                    fifo_pop_o,

  output logic [INDEX_W-1:0]      calibration_addr_o,
  output logic [15:0]             calibration_write_data_o,
  output logic                    calibration_write_o,
  output logic                    calibration_invalidate_o,
  output logic                    calibration_activate_o,
  output logic                    histogram_clear_o,
  input  logic [15:0]             calibration_read_data_i,
  input  logic [31:0]             histogram_read_data_i,
  input  logic                    calibration_active_bank_i,
  input  logic                    calibration_inactive_ready_i,
  input  logic                    histogram_clear_busy_i,
  input  logic                    calibration_complete_i
);

  localparam logic [31:0] TDC_ID_VERSION = 32'h5444_4306; // "TDC", v6: compact 16384-width bursts

  localparam logic [15:0] REG_ID_VERSION       = 16'h0000;
  localparam logic [15:0] REG_CONTROL          = 16'h0004;
  localparam logic [15:0] REG_STATUS           = 16'h0008;
  localparam logic [15:0] REG_LAUNCH_PERIOD    = 16'h000c;
  localparam logic [15:0] REG_LAUNCH_WIDTH     = 16'h0010;
  localparam logic [15:0] REG_TIMEOUT_CYCLES   = 16'h0014;
  localparam logic [15:0] REG_NUM_TAPS         = 16'h0018;
  localparam logic [15:0] REG_CLOCK_PERIOD_PS  = 16'h001c;
  localparam logic [15:0] REG_LAST_COARSE      = 16'h0020;
  localparam logic [15:0] REG_LAST_FINE_RAW    = 16'h0024;
  localparam logic [15:0] REG_LAST_FINE_PS     = 16'h0028;
  localparam logic [15:0] REG_LAST_TOTAL_LO    = 16'h002c;
  localparam logic [15:0] REG_LAST_TOTAL_HI    = 16'h0030;
  localparam logic [15:0] REG_LAST_STATUS_SEQ  = 16'h0034;
  localparam logic [15:0] REG_FIFO_LEVEL       = 16'h0038;
  localparam logic [15:0] REG_FIFO_SNAPSHOT0   = 16'h003c;
  localparam logic [15:0] REG_FIFO_SNAPSHOT1   = 16'h0040;
  localparam logic [15:0] REG_FIFO_SNAPSHOT2   = 16'h0044;
  localparam logic [15:0] REG_FIFO_SNAPSHOT3   = 16'h0048;
  localparam logic [15:0] REG_FIFO_CONTROL     = 16'h004c;
  localparam logic [15:0] REG_CAL_ADDR         = 16'h0050;
  localparam logic [15:0] REG_CAL_DATA         = 16'h0054;
  localparam logic [15:0] REG_CAL_CONTROL      = 16'h0058;
  localparam logic [15:0] REG_HIST_ADDR        = 16'h005c;
  localparam logic [15:0] REG_HIST_DATA        = 16'h0060;
  localparam logic [15:0] REG_EVENT_COUNT      = 16'h0064;
  localparam logic [15:0] REG_ERROR_COUNT      = 16'h0068;
  localparam logic [15:0] REG_RAW_WORD_ADDR    = 16'h006c;
  localparam logic [15:0] REG_RAW_WORD_DATA    = 16'h0070;
  localparam logic [15:0] REG_IRQ_MASK         = 16'h0074;
  localparam logic [15:0] REG_IRQ_STATUS       = 16'h0078;
  localparam logic [15:0] REG_CAL_TARGET       = 16'h007c;
  localparam logic [15:0] REG_MMCM_CONTROL     = 16'h0080;
  localparam logic [15:0] REG_MMCM_STATUS      = 16'h0084;
  localparam logic [15:0] REG_MMCM_COARSE_DLY  = 16'h0088;
  localparam logic [15:0] REG_MMCM_PHASE_CNT   = 16'h008c;
  localparam logic [15:0] REG_INPUT_SELECT     = 16'h0090;

  localparam int unsigned RAW_WORDS = (NUM_TAPS + 31) / 32;

  logic [31:0] control_reg;
  logic [31:0] launch_period_reg;
  logic [31:0] launch_width_reg;
  logic [31:0] timeout_cycles_reg;
  logic [31:0] clock_period_ps_reg;
  logic [31:0] raw_word_addr_reg;
  logic [31:0] irq_mask_reg;
  logic [31:0] irq_status_reg;
  logic        mmcm_incdec_reg;
  logic [15:0] register_offset;
  logic        sys_en;
  logic        valid_read;
  logic        valid_write;

  assign register_offset = sys_addr_i[15:0];
  assign sys_en = sys_wen_i | sys_ren_i;

  assign enable_o             = control_reg[0];
  assign continuous_o         = control_reg[2];
  assign raw_capture_enable_o = control_reg[5];
  assign histogram_enable_o   = control_reg[6];
  assign use_calibration_o    = control_reg[7];
  assign calibration_mode_o   = control_reg[9];
  assign internal_test_enable_o = control_reg[10];
  assign mmcm_sweep_enable_o  = control_reg[11];
  assign mmcm_ps_incdec_o     = mmcm_incdec_reg;
  assign launch_period_o      = launch_period_reg;
  assign launch_width_o       = launch_width_reg;
  assign timeout_cycles_o     = timeout_cycles_reg;
  assign clock_period_ps_o    = clock_period_ps_reg;

  always_comb begin
    valid_read = 1'b1;
    case (register_offset)
      REG_ID_VERSION, REG_CONTROL, REG_STATUS, REG_LAUNCH_PERIOD,
      REG_LAUNCH_WIDTH, REG_TIMEOUT_CYCLES, REG_NUM_TAPS,
      REG_CLOCK_PERIOD_PS, REG_LAST_COARSE, REG_LAST_FINE_RAW,
      REG_LAST_FINE_PS, REG_LAST_TOTAL_LO, REG_LAST_TOTAL_HI,
      REG_LAST_STATUS_SEQ, REG_FIFO_LEVEL, REG_FIFO_SNAPSHOT0,
      REG_FIFO_SNAPSHOT1, REG_FIFO_SNAPSHOT2, REG_FIFO_SNAPSHOT3,
      REG_CAL_ADDR, REG_CAL_DATA, REG_CAL_CONTROL, REG_HIST_ADDR,
      REG_HIST_DATA, REG_EVENT_COUNT, REG_ERROR_COUNT,
      REG_RAW_WORD_ADDR, REG_RAW_WORD_DATA, REG_IRQ_MASK,
      REG_IRQ_STATUS: valid_read = 1'b1;
      REG_CAL_TARGET: valid_read = 1'b1;
      REG_MMCM_CONTROL, REG_MMCM_STATUS, REG_MMCM_COARSE_DLY,
      REG_MMCM_PHASE_CNT: valid_read = 1'b1;
      REG_INPUT_SELECT: valid_read = 1'b1;
      default: valid_read = 1'b0;
    endcase

    valid_write = 1'b1;
    case (register_offset)
      REG_CONTROL: valid_write = !acquisition_lock_i || sys_wdata_i==0;
      REG_LAUNCH_PERIOD, REG_LAUNCH_WIDTH,
      REG_TIMEOUT_CYCLES, REG_CLOCK_PERIOD_PS, REG_FIFO_CONTROL,
      REG_CAL_ADDR, REG_CAL_DATA, REG_CAL_CONTROL, REG_HIST_ADDR,
      REG_RAW_WORD_ADDR, REG_IRQ_MASK, REG_IRQ_STATUS:
        valid_write = 1'b1;
      REG_CAL_TARGET: valid_write = 1'b1;
      REG_MMCM_CONTROL, REG_MMCM_COARSE_DLY: valid_write = 1'b1;
      // Do not let a source change create a measurement edge mid-acquisition.
      REG_INPUT_SELECT: valid_write = !enable_o && !busy_i &&
                                      (sys_wdata_i[31:1] == 31'd0);
      default: valid_write = 1'b0;
    endcase
  end

  always_ff @(posedge clk_i) begin
    if (!rstn_i) begin
      control_reg                 <= 32'd0;
      single_ended_select_o       <= 1'b0;
      launch_period_reg           <= 32'd125000;
      launch_width_reg            <= 32'd2;
      timeout_cycles_reg          <= 32'd125000;
      clock_period_ps_reg         <= 32'd8000;
      calibration_target_o        <= 32'd0;
      raw_word_addr_reg           <= 32'd0;
      calibration_addr_o          <= '0;
      calibration_write_data_o    <= 16'd0;
      irq_mask_reg                <= 32'd0;
      irq_status_reg              <= 32'd0;
      trigger_o                   <= 1'b0;
      soft_reset_o                <= 1'b0;
      fifo_clear_o                <= 1'b0;
      fifo_pop_o                  <= 1'b0;
      calibration_write_o         <= 1'b0;
      calibration_invalidate_o    <= 1'b0;
      calibration_activate_o      <= 1'b0;
      histogram_clear_o           <= 1'b0;
      mmcm_incdec_reg              <= 1'b0;
      mmcm_reset_o                 <= 1'b0;
      mmcm_ps_request_o            <= 1'b0;
      mmcm_phase_count_clear_o     <= 1'b0;
      mmcm_timeout_clear_o         <= 1'b0;
      mmcm_coarse_delay_o          <= 16'd0;
    end else begin
      trigger_o              <= 1'b0;
      soft_reset_o           <= 1'b0;
      fifo_clear_o           <= 1'b0;
      fifo_pop_o             <= 1'b0;
      calibration_write_o    <= 1'b0;
      calibration_invalidate_o <= 1'b0;
      calibration_activate_o <= 1'b0;
      histogram_clear_o      <= 1'b0;
      mmcm_reset_o             <= 1'b0;
      mmcm_ps_request_o        <= 1'b0;
      mmcm_phase_count_clear_o <= 1'b0;
      mmcm_timeout_clear_o     <= 1'b0;

      if (fifo_overflow_i)
        irq_status_reg[0] <= 1'b1;
      if (!fifo_empty_i)
        irq_status_reg[1] <= 1'b1;

      // Requests remain asserted until ack.  Execute a write only once.
      if (sys_wen_i && !sys_ack_o && valid_write) begin
        case (register_offset)
          REG_CONTROL: begin
            control_reg[0] <= sys_wdata_i[0];
            control_reg[2] <= sys_wdata_i[2];
            control_reg[5] <= sys_wdata_i[5];
            control_reg[6] <= sys_wdata_i[6];
            control_reg[7] <= sys_wdata_i[7];
            control_reg[9] <= sys_wdata_i[9];
            control_reg[10] <= sys_wdata_i[10];
            control_reg[11] <= sys_wdata_i[11];
            trigger_o      <= sys_wdata_i[1];
            soft_reset_o   <= sys_wdata_i[3];
            fifo_clear_o   <= sys_wdata_i[4];
            if (sys_wdata_i[3])
              // Preserve the selected hardware stimulus across a core reset,
              // allowing TEST:INTERNAL ON / MMCM sweep ON followed by
              // CAL:START.
              control_reg <= {20'd0, sys_wdata_i[11], sys_wdata_i[10], 10'd0};
          end
          REG_LAUNCH_PERIOD:   launch_period_reg <= (sys_wdata_i == 0) ? 32'd1 : sys_wdata_i;
          REG_LAUNCH_WIDTH:    launch_width_reg <= (sys_wdata_i == 0) ? 32'd1 : sys_wdata_i;
          REG_TIMEOUT_CYCLES:  timeout_cycles_reg <= (sys_wdata_i == 0) ? 32'd1 : sys_wdata_i;
          REG_CLOCK_PERIOD_PS: clock_period_ps_reg <= (sys_wdata_i == 0) ? 32'd1 : sys_wdata_i;
          REG_CAL_TARGET:      calibration_target_o <= sys_wdata_i;
          REG_FIFO_CONTROL: begin
            fifo_pop_o   <= sys_wdata_i[0];
            fifo_clear_o <= sys_wdata_i[1];
          end
          REG_MMCM_CONTROL: begin
            mmcm_ps_request_o        <= sys_wdata_i[0];
            mmcm_incdec_reg           <= sys_wdata_i[1];
            mmcm_phase_count_clear_o <= sys_wdata_i[2];
            mmcm_reset_o              <= sys_wdata_i[3];
            mmcm_timeout_clear_o      <= sys_wdata_i[4];
          end
          REG_MMCM_COARSE_DLY: mmcm_coarse_delay_o <= sys_wdata_i[15:0];
          REG_INPUT_SELECT: begin
            single_ended_select_o <= sys_wdata_i[0];
            if (single_ended_select_o != sys_wdata_i[0]) begin
              // Results and calibration collected through another input path
              // must not silently carry over. Keep the source across soft reset.
              soft_reset_o  <= 1'b1;
              fifo_clear_o  <= 1'b1;
              histogram_clear_o <= 1'b1;
              control_reg[7] <= 1'b0;
            end
          end
          REG_CAL_ADDR, REG_HIST_ADDR:
            calibration_addr_o <= sys_wdata_i[INDEX_W-1:0];
          REG_CAL_DATA:
            calibration_write_data_o <= sys_wdata_i[15:0];
          REG_CAL_CONTROL: begin
            calibration_write_o    <= sys_wdata_i[0];
            calibration_activate_o <= sys_wdata_i[1];
            histogram_clear_o      <= sys_wdata_i[2];
            calibration_invalidate_o <= sys_wdata_i[3];
          end
          REG_RAW_WORD_ADDR: raw_word_addr_reg <= sys_wdata_i;
          REG_IRQ_MASK: irq_mask_reg <= sys_wdata_i;
          REG_IRQ_STATUS: irq_status_reg <= irq_status_reg & ~sys_wdata_i;
          default: begin end
        endcase
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rstn_i) begin
      sys_ack_o   <= 1'b0;
      sys_err_o   <= 1'b0;
      sys_rdata_o <= 32'd0;
    end else begin
      sys_ack_o <= sys_en;
      sys_err_o <= sys_en && ((sys_ren_i && !valid_read) ||
                              (sys_wen_i && !valid_write) ||
                              (sys_addr_i[1:0] != 2'b00));

      case (register_offset)
        REG_ID_VERSION:      sys_rdata_o <= TDC_ID_VERSION;
        REG_CONTROL:         sys_rdata_o <= control_reg;
        REG_STATUS:          sys_rdata_o <= {10'd0, mmcm_ps_busy_i, mmcm_locked_i,
                                             mmcm_sweep_enable_o,
                                             internal_test_enable_o,
                                             calibration_complete_i, fifo_level_i,
                                             fifo_overflow_i,
                                             histogram_clear_busy_i,
                                             calibration_active_bank_i,
                                             ~last_status_i[0],
                                             last_status_i[6],
                                             fifo_full_i,
                                             ~fifo_empty_i,
                                             busy_i};
        REG_LAUNCH_PERIOD:   sys_rdata_o <= launch_period_reg;
        REG_LAUNCH_WIDTH:    sys_rdata_o <= launch_width_reg;
        REG_TIMEOUT_CYCLES:  sys_rdata_o <= timeout_cycles_reg;
        REG_NUM_TAPS:        sys_rdata_o <= NUM_TAPS;
        REG_CLOCK_PERIOD_PS: sys_rdata_o <= clock_period_ps_reg;
        REG_LAST_COARSE:     sys_rdata_o <= last_coarse_i;
        REG_LAST_FINE_RAW:   sys_rdata_o <= {{(32-INDEX_W){1'b0}}, last_fine_raw_i};
        REG_LAST_FINE_PS:    sys_rdata_o <= {16'd0, last_fine_ps_i};
        REG_LAST_TOTAL_LO:   sys_rdata_o <= last_total_ps_i[31:0];
        REG_LAST_TOTAL_HI:   sys_rdata_o <= {18'd0, last_total_ps_i[45:32]};
        REG_LAST_STATUS_SEQ: sys_rdata_o <= {last_sequence_i, 8'd0, last_status_i};
        REG_FIFO_LEVEL:      sys_rdata_o <= {{(31-FIFO_AW){1'b0}}, fifo_level_i};
        REG_FIFO_SNAPSHOT0:  sys_rdata_o <= fifo_snapshot_i[31:0];
        REG_FIFO_SNAPSHOT1:  sys_rdata_o <= fifo_snapshot_i[63:32];
        REG_FIFO_SNAPSHOT2:  sys_rdata_o <= fifo_snapshot_i[95:64];
        REG_FIFO_SNAPSHOT3:  sys_rdata_o <= fifo_snapshot_i[127:96];
        REG_CAL_ADDR, REG_HIST_ADDR:
                              sys_rdata_o <= {{(32-INDEX_W){1'b0}}, calibration_addr_o};
        REG_CAL_DATA:         sys_rdata_o <= {16'd0, calibration_read_data_i};
        REG_CAL_CONTROL:      sys_rdata_o <= {28'd0, calibration_inactive_ready_i,
                                              histogram_clear_busy_i,
                                              calibration_active_bank_i, 1'b0};
        REG_HIST_DATA:        sys_rdata_o <= histogram_read_data_i;
        REG_EVENT_COUNT:      sys_rdata_o <= event_count_i;
        REG_ERROR_COUNT:      sys_rdata_o <= error_count_i;
        REG_RAW_WORD_ADDR:    sys_rdata_o <= raw_word_addr_reg;
        REG_RAW_WORD_DATA: begin
          if (raw_word_addr_reg < RAW_WORDS)
            sys_rdata_o <= (raw_taps_i >> (raw_word_addr_reg * 32));
          else
            sys_rdata_o <= 32'd0;
        end
        REG_IRQ_MASK:         sys_rdata_o <= irq_mask_reg;
        REG_IRQ_STATUS:       sys_rdata_o <= irq_status_reg;
        REG_CAL_TARGET:       sys_rdata_o <= calibration_target_o;
        REG_MMCM_CONTROL:     sys_rdata_o <= {30'd0, mmcm_incdec_reg, 1'b0};
        REG_MMCM_STATUS:      sys_rdata_o <= {29'd0, mmcm_ps_timeout_i,
                                              mmcm_ps_busy_i, mmcm_locked_i};
        REG_MMCM_COARSE_DLY:  sys_rdata_o <= {16'd0, mmcm_coarse_delay_o};
        REG_MMCM_PHASE_CNT:   sys_rdata_o <= mmcm_phase_count_i;
        REG_INPUT_SELECT:     sys_rdata_o <= {31'd0, single_ended_select_o};
        default:              sys_rdata_o <= 32'd0;
      endcase
    end
  end

endmodule: tdc_registers
