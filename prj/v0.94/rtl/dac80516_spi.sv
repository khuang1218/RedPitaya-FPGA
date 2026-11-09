`timescale 1ns/1ps
// DAC80516 mode-1 serial engine: SDI changes on rising SCLK, DAC captures
// falling SCLK. One 125 MHz domain; SCLK is an output, never a fabric clock.
// Commands snapshot all four weights. Held system-bus requests execute once.
(* KEEP_HIERARCHY="yes" *)
module dac80516_spi #(
  parameter int unsigned CLOCK_HZ=125000000,
  parameter int unsigned STARTUP_CYCLES=CLOCK_HZ/100 // >=10 ms after FPGA reset
)(
  input logic clk_i,rstn_i,miso_i,
  output logic sclk_o,mosi_o,cs_n_o,ldac_n_o,
  input logic [31:0] sys_addr_i,sys_wdata_i,
  input logic sys_wen_i,sys_ren_i,
  output logic [31:0] sys_rdata_o,
  output logic sys_ack_o,sys_err_o
);
  typedef enum logic [3:0] {IDLE,PREPARE,SELECT_SETUP,RISE,HIGH_WAIT,
    LOW_WAIT,SELECT_HOLD,SELECT_GAP,ADVANCE,LOAD_LOW,LOAD_WAIT} state_t;
  state_t state;
  logic [3:0][15:0] weights,transaction_weights,loaded_weights,applied_weights;
  // These are observable serial payload state, not interchangeable with the
  // controller state. Preserve them through Vivado's cross-boundary optimization.
  (* DONT_TOUCH="yes" *) logic [23:0] raw_tx,tx_shift;
  // Keep the complete receive/result bank through post-synthesis optimization.
  // Readback must remain a real input-to-MMIO path after OOC IP is linked.
  (* DONT_TOUCH="yes" *) logic [23:0] rx_shift,raw_rx;
  // An explicit, fanout-one data FF drives the MOSI IOBUF. The first v19
  // checkpoint lost the inferred mosi_o register and tied the pin to GND.
  (* DONT_TOUCH="yes", IOB="TRUE" *) logic mosi_pin;
  assign mosi_o=mosi_pin;
  logic [7:0] period_ticks,high_ticks,low_ticks,timer;
  logic [7:0] active_high,active_low;
  logic [7:0] ldac_ticks,active_ldac;
  logic [4:0] bit_number;
  logic [1:0] channel;
  logic group_operation,apply_after,read_operation,read_second;
  logic loaded_valid,applied_valid,done;
  logic [31:0] apply_count,transfer_count;
  localparam int START_W=STARTUP_CYCLES>1 ? $clog2(STARTUP_CYCLES+1) : 1;
  logic [START_W-1:0] startup_count;
  logic startup_ready;
  (* ASYNC_REG="TRUE", SHREG_EXTRACT="NO", DONT_TOUCH="yes" *) logic miso_meta,miso_sync;
  // Slow readback accommodates device delay, traces and two settling stages.
  // Only miso_meta/D is asynchronous; the rest of the engine is fully timed.
  always_ff @(posedge clk_i) begin
    miso_meta<=miso_i;
    miso_sync<=miso_meta;
    if(!rstn_i) begin startup_count<='0;startup_ready<=0;end
    else if(!startup_ready) begin
      if(startup_count==START_W'(STARTUP_CYCLES-1)) startup_ready<=1;
      else startup_count<=startup_count+1'b1;
    end
  end
  wire busy=state!=IDLE;
  wire request=sys_wen_i || sys_ren_i;
  wire accept=request && !sys_ack_o;
  wire [7:0] offset=sys_addr_i[7:0];
  logic valid_write,valid_read;
  always_comb begin
    valid_read=1;
    case(offset)
      8'h00,8'h08,8'h0c,8'h10,8'h14,8'h18,8'h1c,8'h20,8'h24,
      8'h28,8'h2c,8'h30,8'h34,8'h40,8'h44,8'h48,8'h4c: begin end
      default:valid_read=0;
    endcase
    valid_write=0;
    if(!busy) case(offset)
      8'h04: case(sys_wdata_i)
        1,2,8:valid_write=startup_ready; // commit/load four/raw write
        4:valid_write=startup_ready && loaded_valid;
        16:valid_write=startup_ready && period_ticks>=16 && raw_tx[23];
        32:valid_write=1; // clear completion indication
        default:begin end
      endcase
      8'h0c:valid_write=sys_wdata_i>=4 && sys_wdata_i<=250;
      8'h10,8'h14,8'h18,8'h1c:valid_write=sys_wdata_i<=65535;
      // RAW_WRITE must not silently issue an uncollected read transaction.
      8'h20:valid_write=sys_wdata_i<=24'hffffff;
      8'h34:valid_write=sys_wdata_i>=13 && sys_wdata_i<=250;
      default:begin end
    endcase
    if(offset==8'h04 && sys_wdata_i==8 && raw_tx[23]) valid_write=0;
  end
  always_ff @(posedge clk_i) begin
    if(!rstn_i) begin
      state<=IDLE;weights<='0;transaction_weights<='0;
      loaded_weights<='0;applied_weights<='0;loaded_valid<=0;applied_valid<=0;
      period_ticks<=12;high_ticks<=6;low_ticks<=6;ldac_ticks<=16;
      active_high<=6;active_low<=6;active_ldac<=16;timer<=0;
      sclk_o<=0;mosi_pin<=0;cs_n_o<=1;ldac_n_o<=1;
      raw_tx<=0;raw_rx<=0;tx_shift<=0;rx_shift<=0;bit_number<=0;
      channel<=0;group_operation<=0;apply_after<=0;
      read_operation<=0;read_second<=0;done<=0;apply_count<=0;transfer_count<=0;
      sys_ack_o<=0;sys_err_o<=0;sys_rdata_o<=0;
    end else begin
      sys_ack_o<=request;
      if(!request) sys_err_o<=0;
      else if(accept) sys_err_o<=sys_addr_i[1:0]!=0 ||
                         (sys_wen_i && !valid_write) || (sys_ren_i && !valid_read);
      if(accept && sys_ren_i) case(offset)
        8'h00:sys_rdata_o<=32'h44414301; // DAC register interface v1
        8'h08:sys_rdata_o<={26'b0,done,applied_valid,loaded_valid,startup_ready,1'b0,busy};
        8'h0c:sys_rdata_o<={24'b0,period_ticks};
        8'h10:sys_rdata_o<={16'b0,weights[0]};
        8'h14:sys_rdata_o<={16'b0,weights[1]};
        8'h18:sys_rdata_o<={16'b0,weights[2]};
        8'h1c:sys_rdata_o<={16'b0,weights[3]};
        8'h20:sys_rdata_o<={8'b0,raw_tx};
        8'h24:sys_rdata_o<={8'b0,raw_rx};
        8'h28:sys_rdata_o<=apply_count;
        8'h2c:sys_rdata_o<=transfer_count;
        8'h30:sys_rdata_o<=CLOCK_HZ;
        8'h34:sys_rdata_o<={24'b0,ldac_ticks};
        8'h40:sys_rdata_o<={16'b0,applied_weights[0]};
        8'h44:sys_rdata_o<={16'b0,applied_weights[1]};
        8'h48:sys_rdata_o<={16'b0,applied_weights[2]};
        8'h4c:sys_rdata_o<={16'b0,applied_weights[3]};
        default:sys_rdata_o<=0;
      endcase
      if(accept && sys_wen_i && valid_write && sys_addr_i[1:0]==0) case(offset)
        8'h0c:begin
          period_ticks<=sys_wdata_i[7:0];
          high_ticks<=sys_wdata_i[7:0]>>1;
          low_ticks<=sys_wdata_i[7:0]-(sys_wdata_i[7:0]>>1);
        end
        8'h10:weights[0]<=sys_wdata_i[15:0];
        8'h14:weights[1]<=sys_wdata_i[15:0];
        8'h18:weights[2]<=sys_wdata_i[15:0];
        8'h1c:weights[3]<=sys_wdata_i[15:0];
        8'h20:raw_tx<=sys_wdata_i[23:0];
        8'h34:ldac_ticks<=sys_wdata_i[7:0];
        8'h04:begin
          done<=0;
          if(sys_wdata_i!=32) begin
            transaction_weights<=weights;active_high<=high_ticks;active_low<=low_ticks;
            active_ldac<=ldac_ticks;channel<=0;read_second<=0;
            group_operation<=sys_wdata_i==1 || sys_wdata_i==2;
            apply_after<=sys_wdata_i==1;
            read_operation<=sys_wdata_i==16;
            if(sys_wdata_i==4) begin
              transaction_weights<=loaded_weights;state<=LOAD_LOW;
            end else begin
              if(sys_wdata_i==8) begin loaded_valid<=0;applied_valid<=0;end
              state<=PREPARE;
            end
          end
        end
        default:begin end
      endcase
      case(state)
        IDLE:begin end
        PREPARE:begin
          tx_shift<=group_operation ? {6'b000100,channel,transaction_weights[channel]} : raw_tx;
          rx_shift<=0;bit_number<=0;cs_n_o<=0;sclk_o<=0;timer<=2;state<=SELECT_SETUP;
        end
        SELECT_SETUP:if(timer==0) state<=RISE;else timer<=timer-1'b1;
        RISE:begin
          sclk_o<=1;mosi_pin<=tx_shift[23];timer<=active_high-1'b1;state<=HIGH_WAIT;
        end
        HIGH_WAIT:if(timer!=0) timer<=timer-1'b1;
          else begin
            sclk_o<=0;tx_shift<={tx_shift[22:0],1'b0};
            rx_shift<={rx_shift[22:0],miso_sync};
            if(bit_number==23) begin timer<=2;state<=SELECT_HOLD;end
            else begin bit_number<=bit_number+1'b1;timer<=active_low-2;state<=LOW_WAIT;end
          end
        LOW_WAIT:if(timer!=0) timer<=timer-1'b1;else state<=RISE;
        SELECT_HOLD:if(timer!=0) timer<=timer-1'b1;
          else begin cs_n_o<=1;timer<=2;state<=SELECT_GAP;transfer_count<=transfer_count+1'b1;end
        SELECT_GAP:if(timer!=0) timer<=timer-1'b1;else state<=ADVANCE;
        ADVANCE:begin
          if(group_operation && channel!=3) begin channel<=channel+1'b1;state<=PREPARE;end
          else if(read_operation && !read_second) begin
            // Second 24-clock access shifts out the requested register.
            read_second<=1;tx_shift<=0;rx_shift<=0;bit_number<=0;
            cs_n_o<=0;timer<=2;state<=SELECT_SETUP;
          end else begin
            if(group_operation) begin loaded_weights<=transaction_weights;loaded_valid<=1;end
            if(read_operation) raw_rx<=rx_shift;
            if(group_operation && apply_after) state<=LOAD_LOW;
            else begin state<=IDLE;done<=1;end
          end
        end
        LOAD_LOW:begin ldac_n_o<=0;timer<=active_ldac-1'b1;state<=LOAD_WAIT;end
        LOAD_WAIT:if(timer!=0) timer<=timer-1'b1;
          else begin
            ldac_n_o<=1;state<=IDLE;done<=1;apply_count<=apply_count+1'b1;
            applied_weights<=transaction_weights;applied_valid<=1;
          end
        default:state<=IDLE;
      endcase
    end
  end
endmodule
