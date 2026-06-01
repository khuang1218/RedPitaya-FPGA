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
////////////////////////////////////////////////////////////////////////////////

module bnet_regs (
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
  output logic          led6_heartbeat_en_o
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

  logic [32-1:0] control_reg;
  logic [32-1:0] status_reg;
  logic [32-1:0] ch_data [0:7];
  logic [32-1:0] out_data [0:3];
  logic          sys_en;

  assign sys_en = sys_wen_i | sys_ren_i;

  assign out_data[0] = ch_data[0] + ch_data[1];
  assign out_data[1] = ch_data[2] + ch_data[3];
  assign out_data[2] = ch_data[4] + ch_data[5];
  assign out_data[3] = ch_data[6] + ch_data[7];

  assign led_debug_o    = ch_data[0][7:0];
  assign led_debug_en_o = control_reg[2];
  assign led6_heartbeat_en_o = control_reg[3];

  always_ff @(posedge clk_i) begin
    if (!rstn_i) begin
      control_reg <= 32'd0;
      status_reg  <= 32'd0;
      for (int i = 0; i < 8; i++) begin
        ch_data[i] <= 32'd0;
      end
    end else begin
      status_reg[0] <= 1'b0; // busy: this scalar test completes immediately.
      status_reg[2] <= 1'b0; // error: reserved for later buffer/controller work.

      if (sys_wen_i) begin
        case (sys_addr_i[19:0])
          REG_CONTROL: begin
            if (sys_wdata_i[1]) begin
              control_reg <= 32'd0;
              status_reg  <= 32'd0;
              for (int i = 0; i < 8; i++) begin
                ch_data[i] <= 32'd0;
              end
            end else begin
              control_reg <= sys_wdata_i;
              if (sys_wdata_i[0]) begin
                status_reg[1] <= 1'b1;
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
          default: begin
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
        default:     sys_rdata_o <= 32'd0;
      endcase
    end
  end

endmodule: bnet_regs
