////////////////////////////////////////////////////////////////////////////////
// BNET scalar register block.
//
// This is the first ARM-to-FPGA custom-channel milestone for the butterfly
// network work. Software can write simple scalar channel registers through one
// Red Pitaya sys_bus region and read back simple computed outputs.
//
// Register map, offsets within this sys_bus slave:
//   0x00  CONTROL   RW  [0] start latch, [1] soft reset write, [2] LED debug en
//                         [3] LED6 heartbeat enable
//   0x04  STATUS    RO  [0] busy, [1] done, [2] error
//   0x08  CH0_DATA  RW
//   0x0c  CH1_DATA  RW
//   0x10  CH2_DATA  RW
//   0x14  CH3_DATA  RW
//   0x18  CH4_DATA  RW
//   0x1c  CH5_DATA  RW
//   0x20  CH6_DATA  RW
//   0x24  CH7_DATA  RW
//   0x28  OUT0_DATA RO  CH0 + CH1
//   0x2c  OUT1_DATA RO  CH2 + CH3
//   0x30  OUT2_DATA RO  CH4 + CH5
//   0x34  OUT3_DATA RO  CH6 + CH7
//   0x38  VECTOR_LEN RW vector length in samples for later DDR engines
//   0x3c  STREAM_COUNT RO number of BNET logical DDR streams
//   0x40  ACTIVE_MASK RO one bit per stream, 1 means buffer 1 active
//   0x44  PENDING_MASK RO one bit per stream, 1 means swap pending
//   0x48  ERROR_MASK RO one bit per stream, 1 means descriptor error
//   0x4c  CONFIG RW [1:0] input source:
//                    0 = ASG test stream, 1 = ADC real-time stream,
//                    2 = DDR stream reserved
//
// Per-stream descriptor window:
//   stream n base = 0x100 + n * 0x40
//   +0x00 BASE0 RW DDR base address for ping buffer
//   +0x04 BASE1 RW DDR base address for pong buffer
//   +0x08 LENGTH_BYTES RW valid bytes in each buffer
//   +0x0c STRIDE_BYTES RW byte stride between samples/words
//   +0x10 FORMAT RW fixed-point/packing format tag
//   +0x14 CONTROL RW bit 0 enable, bit 1 commit buffer 0 pulse,
//                  bit 2 commit buffer 1 pulse, bit 3 force swap pulse,
//                  bit 4 clear descriptor error pulse
//   +0x18 STATUS RO bit 0 active buffer, bit 1 pending valid,
//                 bit 2 enabled, bit 3 address error, bit 4 length error,
//                 bit 5 runtime error
//   +0x1c READ_PTR RO reader byte pointer/status mirror
////////////////////////////////////////////////////////////////////////////////

module bnet_regs #(
  parameter int unsigned STREAM_COUNT = 8
)(
  input  logic          clk_i,
  input  logic          rstn_i,

  input  logic [32-1:0] sys_addr_i,
  input  logic [32-1:0] sys_wdata_i,
  input  logic          sys_wen_i,
  input  logic          sys_ren_i,
  output logic [32-1:0] sys_rdata_o,
  output logic          sys_err_o,
  output logic          sys_ack_o,

  output logic [ 8-1:0] led_debug_o,
  output logic          led_debug_en_o,
  output logic          led6_heartbeat_en_o,
  output logic [ 2-1:0] input_sel_o,
  output logic          start_pulse_o,
  output logic [STREAM_COUNT-1:0][32-1:0] stream_base0_o,
  output logic [STREAM_COUNT-1:0][32-1:0] stream_base1_o,
  output logic [STREAM_COUNT-1:0][32-1:0] stream_length_o,
  output logic [STREAM_COUNT-1:0][32-1:0] stream_stride_o,
  output logic [STREAM_COUNT-1:0][32-1:0] stream_format_o,
  output logic [STREAM_COUNT-1:0] stream_enable_o,
  output logic [STREAM_COUNT-1:0] stream_active_buf_o,
  input  logic [STREAM_COUNT-1:0][32-1:0] stream_read_ptr_i,
  input  logic [STREAM_COUNT-1:0] stream_runtime_error_i
);

  localparam logic [20-1:0] REG_CONTROL = 20'h00000;
  localparam logic [20-1:0] REG_STATUS  = 20'h00004;
  localparam logic [20-1:0] REG_CH0     = 20'h00008;
  localparam logic [20-1:0] REG_CH1     = 20'h0000c;
  localparam logic [20-1:0] REG_CH2     = 20'h00010;
  localparam logic [20-1:0] REG_CH3     = 20'h00014;
  localparam logic [20-1:0] REG_CH4     = 20'h00018;
  localparam logic [20-1:0] REG_CH5     = 20'h0001c;
  localparam logic [20-1:0] REG_CH6     = 20'h00020;
  localparam logic [20-1:0] REG_CH7     = 20'h00024;
  localparam logic [20-1:0] REG_OUT0    = 20'h00028;
  localparam logic [20-1:0] REG_OUT1    = 20'h0002c;
  localparam logic [20-1:0] REG_OUT2    = 20'h00030;
  localparam logic [20-1:0] REG_OUT3    = 20'h00034;
  localparam logic [20-1:0] REG_VECTOR_LEN   = 20'h00038;
  localparam logic [20-1:0] REG_STREAM_COUNT = 20'h0003c;
  localparam logic [20-1:0] REG_ACTIVE_MASK  = 20'h00040;
  localparam logic [20-1:0] REG_PENDING_MASK = 20'h00044;
  localparam logic [20-1:0] REG_ERROR_MASK   = 20'h00048;
  localparam logic [20-1:0] REG_CONFIG       = 20'h0004c;

  localparam logic [20-1:0] STREAM_BASE   = 20'h00100;
  localparam logic [20-1:0] STREAM_STRIDE = 20'h00040;
  localparam logic [20-1:0] STREAM_LAST =
      STREAM_BASE + (STREAM_COUNT * STREAM_STRIDE) - 20'h00004;
  localparam int unsigned STREAM_INDEX_W = $clog2(STREAM_COUNT);

  localparam logic [6-1:0] STREAM_REG_BASE0  = 6'h00;
  localparam logic [6-1:0] STREAM_REG_BASE1  = 6'h04;
  localparam logic [6-1:0] STREAM_REG_LENGTH = 6'h08;
  localparam logic [6-1:0] STREAM_REG_STRIDE = 6'h0c;
  localparam logic [6-1:0] STREAM_REG_FORMAT = 6'h10;
  localparam logic [6-1:0] STREAM_REG_CTRL   = 6'h14;
  localparam logic [6-1:0] STREAM_REG_STATUS = 6'h18;
  localparam logic [6-1:0] STREAM_REG_RPTR   = 6'h1c;

  logic [32-1:0] control_reg;
  logic [32-1:0] status_reg;
  logic [32-1:0] config_reg;
  logic [32-1:0] vector_len_reg;
  logic [32-1:0] ch_data [0:7];
  logic [32-1:0] out_data [0:3];
  logic [32-1:0] stream_base0 [0:STREAM_COUNT-1];
  logic [32-1:0] stream_base1 [0:STREAM_COUNT-1];
  logic [32-1:0] stream_length [0:STREAM_COUNT-1];
  logic [32-1:0] stream_stride [0:STREAM_COUNT-1];
  logic [32-1:0] stream_format [0:STREAM_COUNT-1];
  logic [STREAM_COUNT-1:0] stream_enable;
  logic [STREAM_COUNT-1:0] stream_active_buf;
  logic [STREAM_COUNT-1:0] stream_pending_valid;
  logic [STREAM_COUNT-1:0] stream_pending_buf;
  logic [STREAM_COUNT-1:0] stream_addr_error;
  logic [STREAM_COUNT-1:0] stream_len_error;
  logic          sys_en;
  logic          stream_access;
  logic [6-1:0] stream_slot;
  logic [STREAM_INDEX_W-1:0] stream_index;
  logic [6-1:0] stream_reg_offset;

  assign sys_en = sys_wen_i | sys_ren_i;
  assign stream_access = (sys_addr_i[19:0] >= STREAM_BASE) &&
                         (sys_addr_i[19:0] <= STREAM_LAST);
  assign stream_slot = sys_addr_i[11:6] - STREAM_BASE[11:6];
  assign stream_index = stream_slot[0 +: STREAM_INDEX_W];
  assign stream_reg_offset = sys_addr_i[5:0];

  assign out_data[0] = ch_data[0] + ch_data[1];
  assign out_data[1] = ch_data[2] + ch_data[3];
  assign out_data[2] = ch_data[4] + ch_data[5];
  assign out_data[3] = ch_data[6] + ch_data[7];

  assign led_debug_o    = ch_data[0][7:0];
  assign led_debug_en_o = control_reg[2];
  assign led6_heartbeat_en_o = control_reg[3];
  assign input_sel_o = config_reg[1:0];
  assign stream_enable_o = stream_enable;
  assign stream_active_buf_o = stream_active_buf;

  generate
    for (genvar g = 0; g < STREAM_COUNT; g++) begin : stream_descriptor_outputs
      assign stream_base0_o[g] = stream_base0[g];
      assign stream_base1_o[g] = stream_base1[g];
      assign stream_length_o[g] = stream_length[g];
      assign stream_stride_o[g] = stream_stride[g];
      assign stream_format_o[g] = stream_format[g];
    end
  endgenerate

  always_ff @(posedge clk_i) begin
    if (!rstn_i) begin
      control_reg <= 32'd0;
      status_reg  <= 32'd0;
      config_reg  <= 32'd0;
      start_pulse_o <= 1'b0;
      vector_len_reg <= 32'd1024;
      for (int i = 0; i < 8; i++) begin
        ch_data[i] <= 32'd0;
      end
      for (int i = 0; i < STREAM_COUNT; i++) begin
        stream_base0[i] <= 32'd0;
        stream_base1[i] <= 32'd0;
        stream_length[i] <= 32'd0;
        stream_stride[i] <= 32'd2;
        stream_format[i] <= 32'd0;
        stream_enable[i] <= 1'b0;
        stream_active_buf[i] <= 1'b0;
        stream_pending_valid[i] <= 1'b0;
        stream_pending_buf[i] <= 1'b0;
        stream_addr_error[i] <= 1'b0;
        stream_len_error[i] <= 1'b0;
      end
    end else begin
      start_pulse_o <= 1'b0;
      status_reg[0] <= 1'b0; // busy: this scalar test completes immediately.
      status_reg[2] <= 1'b0; // error: reserved for later buffer/controller work.
      status_reg[3] <= |stream_pending_valid;
      status_reg[4] <= control_reg[4];

      if (sys_wen_i) begin
        case (sys_addr_i[19:0])
          REG_CONTROL: begin
            if (sys_wdata_i[1]) begin
              control_reg <= 32'd0;
              status_reg  <= 32'd0;
              config_reg  <= 32'd0;
              vector_len_reg <= 32'd1024;
              for (int i = 0; i < 8; i++) begin
                ch_data[i] <= 32'd0;
              end
              for (int i = 0; i < STREAM_COUNT; i++) begin
                stream_base0[i] <= 32'd0;
                stream_base1[i] <= 32'd0;
                stream_length[i] <= 32'd0;
                stream_stride[i] <= 32'd2;
                stream_format[i] <= 32'd0;
                stream_enable[i] <= 1'b0;
                stream_active_buf[i] <= 1'b0;
                stream_pending_valid[i] <= 1'b0;
                stream_pending_buf[i] <= 1'b0;
                stream_addr_error[i] <= 1'b0;
                stream_len_error[i] <= 1'b0;
              end
            end else begin
              control_reg <= sys_wdata_i;
              if (sys_wdata_i[0]) begin
                start_pulse_o <= 1'b1;
                status_reg[1] <= 1'b1;
                for (int i = 0; i < STREAM_COUNT; i++) begin
                  if (stream_pending_valid[i]) begin
                    stream_active_buf[i] <= stream_pending_buf[i];
                    stream_pending_valid[i] <= 1'b0;
                  end
                end
              end
              if (sys_wdata_i[5]) begin
                for (int i = 0; i < STREAM_COUNT; i++) begin
                  if (stream_enable[i]) begin
                    stream_pending_buf[i] <= ~stream_active_buf[i];
                    stream_pending_valid[i] <= 1'b1;
                  end
                end
              end
            end
          end
          REG_CH0: ch_data[0] <= sys_wdata_i;
          REG_CH1: ch_data[1] <= sys_wdata_i;
          REG_CH2: ch_data[2] <= sys_wdata_i;
          REG_CH3: ch_data[3] <= sys_wdata_i;
          REG_CH4: ch_data[4] <= sys_wdata_i;
          REG_CH5: ch_data[5] <= sys_wdata_i;
          REG_CH6: ch_data[6] <= sys_wdata_i;
          REG_CH7: ch_data[7] <= sys_wdata_i;
          REG_VECTOR_LEN: vector_len_reg <= sys_wdata_i;
          REG_CONFIG: config_reg <= sys_wdata_i;
          default: begin
            if (stream_access) begin
              case (stream_reg_offset)
                STREAM_REG_BASE0: stream_base0[stream_index] <= sys_wdata_i;
                STREAM_REG_BASE1: stream_base1[stream_index] <= sys_wdata_i;
                STREAM_REG_LENGTH: begin
                  stream_length[stream_index] <= sys_wdata_i;
                  stream_len_error[stream_index] <= (sys_wdata_i == 32'd0) ||
                                                    (sys_wdata_i[0] != 1'b0);
                end
                STREAM_REG_STRIDE: begin
                  stream_stride[stream_index] <= sys_wdata_i;
                  stream_len_error[stream_index] <= (sys_wdata_i == 32'd0);
                end
                STREAM_REG_FORMAT: stream_format[stream_index] <= sys_wdata_i;
                STREAM_REG_CTRL: begin
                  stream_enable[stream_index] <= sys_wdata_i[0];

                  if (sys_wdata_i[1]) begin
                    stream_pending_buf[stream_index] <= 1'b0;
                    stream_pending_valid[stream_index] <= 1'b1;
                  end

                  if (sys_wdata_i[2]) begin
                    stream_pending_buf[stream_index] <= 1'b1;
                    stream_pending_valid[stream_index] <= 1'b1;
                  end

                  if (sys_wdata_i[3]) begin
                    stream_active_buf[stream_index] <= stream_pending_valid[stream_index] ?
                                                       stream_pending_buf[stream_index] :
                                                       ~stream_active_buf[stream_index];
                    stream_pending_valid[stream_index] <= 1'b0;
                  end

                  if (sys_wdata_i[4]) begin
                    stream_addr_error[stream_index] <= 1'b0;
                    stream_len_error[stream_index] <= 1'b0;
                  end

                  if ((stream_base0[stream_index][1:0] != 2'b00) ||
                      (stream_base1[stream_index][1:0] != 2'b00)) begin
                    stream_addr_error[stream_index] <= 1'b1;
                  end
                end
                default: begin
                end
              endcase
            end
          end
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
      sys_err_o <= 1'b0;

      case (sys_addr_i[19:0])
        REG_CONTROL: sys_rdata_o <= control_reg;
        REG_STATUS:  sys_rdata_o <= status_reg;
        REG_CH0:     sys_rdata_o <= ch_data[0];
        REG_CH1:     sys_rdata_o <= ch_data[1];
        REG_CH2:     sys_rdata_o <= ch_data[2];
        REG_CH3:     sys_rdata_o <= ch_data[3];
        REG_CH4:     sys_rdata_o <= ch_data[4];
        REG_CH5:     sys_rdata_o <= ch_data[5];
        REG_CH6:     sys_rdata_o <= ch_data[6];
        REG_CH7:     sys_rdata_o <= ch_data[7];
        REG_OUT0:    sys_rdata_o <= out_data[0];
        REG_OUT1:    sys_rdata_o <= out_data[1];
        REG_OUT2:    sys_rdata_o <= out_data[2];
        REG_OUT3:    sys_rdata_o <= out_data[3];
        REG_VECTOR_LEN:   sys_rdata_o <= vector_len_reg;
        REG_STREAM_COUNT: sys_rdata_o <= STREAM_COUNT;
        REG_ACTIVE_MASK:  sys_rdata_o <= {{(32-STREAM_COUNT){1'b0}}, stream_active_buf};
        REG_PENDING_MASK: sys_rdata_o <= {{(32-STREAM_COUNT){1'b0}}, stream_pending_valid};
        REG_ERROR_MASK:   sys_rdata_o <= {{(32-STREAM_COUNT){1'b0}},
                                          (stream_addr_error | stream_len_error | stream_runtime_error_i)};
        REG_CONFIG:       sys_rdata_o <= config_reg;
        default: begin
          if (stream_access) begin
            case (stream_reg_offset)
              STREAM_REG_BASE0:  sys_rdata_o <= stream_base0[stream_index];
              STREAM_REG_BASE1:  sys_rdata_o <= stream_base1[stream_index];
              STREAM_REG_LENGTH: sys_rdata_o <= stream_length[stream_index];
              STREAM_REG_STRIDE: sys_rdata_o <= stream_stride[stream_index];
              STREAM_REG_FORMAT: sys_rdata_o <= stream_format[stream_index];
              STREAM_REG_CTRL:   sys_rdata_o <= {{31{1'b0}}, stream_enable[stream_index]};
              STREAM_REG_STATUS: sys_rdata_o <= {26'd0,
                                                 stream_runtime_error_i[stream_index],
                                                 stream_len_error[stream_index],
                                                 stream_addr_error[stream_index],
                                                 stream_enable[stream_index],
                                                 stream_pending_valid[stream_index],
                                                 stream_active_buf[stream_index]};
              STREAM_REG_RPTR:   sys_rdata_o <= stream_read_ptr_i[stream_index];
              default:           sys_rdata_o <= 32'd0;
            endcase
          end else begin
            sys_rdata_o <= 32'd0;
          end
        end
      endcase
    end
  end

endmodule: bnet_regs
