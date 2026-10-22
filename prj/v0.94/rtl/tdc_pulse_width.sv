`timescale 1ns/1ps
// PCB pulse-width acquisition. A small raw-frame ring feeds an online encoder;
// compact results remain in BRAM for the whole 16384-pulse finite burst.
// V14 (v12 capture + programmable frame offset): <= 2 MHz frame trigger, 250 MHz sampler, >= 8 ns HIGH/LOW for
// reliable coarse edge detection. Shorter pulses/gaps are not guaranteed.
// Carry codes are diagnostic until separate rise/fall LUTs are calibrated.
// Operating timing contract: cycle_start_i defines one frame per FPGA launch
// period. A VTC return belongs to that launch after its physical propagation
// and conversion delay. External test sources must use the same nominal period.
// V14 shifts every frame marker by a configured 4 ns offset, preserving
// the launch period. Choose the boundary in the input LOW interval. This is
// fixed phase compensation, not clock locking or cross-frame edge retention.
(* KEEP_HIERARCHY = "TRUE" *)
module tdc_pulse_width #(
  parameter int unsigned NUM_CARRY4 = 128,
  parameter int unsigned NUM_TAPS = NUM_CARRY4 * 4,
  parameter int unsigned INDEX_W = $clog2(NUM_TAPS),
  parameter int unsigned DEPTH = 16384,
  parameter int unsigned AW = $clog2(DEPTH),
  parameter int unsigned STAGING_DEPTH = 4,
  parameter int unsigned SAW = $clog2(STAGING_DEPTH),
  parameter int unsigned ENCODER_TAPS_PER_CYCLE = 8
)(
  input logic bus_clk_i, fast_clk_i, rstn_i,
  input logic event_i, cycle_start_i,
  input logic [31:0] pulse_period_i, // pulse_gen units: 2 ns
  input logic input_select_i, legacy_conflict_i,
  output logic busy_o,
  input logic [31:0] sys_addr_i, sys_wdata_i,
  input logic sys_wen_i, sys_ren_i,
  output logic [31:0] sys_rdata_o,
  output logic sys_ack_o, sys_err_o
);
  localparam logic [31:0] VALID=1, NO_RISE=2, NO_FALL=4, HIGH_START=8,
    EXTRA_EDGES=16, TRIGGER_TIMEOUT=32, FINE_INVALID=128, COARSE_ONLY=256,
    CAL_USED=512, BOUNDARY=1024, SATURATED=2048, OUT_OF_RANGE=4096;
  localparam logic [31:0] DONE=8, TIMEOUT=16, RATE_ERROR=32, ABORTED=64, OVERFLOW=128;
  // Both edges encode concurrently. Reserve 32 clocks beyond the scan for
  // fetch, encoder drain, LUT/arithmetic and retirement. The default 125-clock
  // (500 ns) frame leaves margin; larger parameterized scans lower the limit.
  localparam int unsigned ENCODER_SCAN_CYCLES=
    (NUM_TAPS+ENCODER_TAPS_PER_CYCLE-1)/ENCODER_TAPS_PER_CYCLE;
  localparam int unsigned PROCESS_BUDGET=ENCODER_SCAN_CYCLES+32;
  localparam logic [31:0] TICK_PS=4000,
    MIN_PERIOD=2*((PROCESS_BUDGET>125) ? PROCESS_BUDGET : 125);
  localparam int unsigned RECORD_W=81+2*INDEX_W;

  logic [31:0] requested_count, timeout_cfg, timeout_match_cfg;
  logic timeout_immediate_cfg;
  // Idle-only frame shift in fast-clock ticks. Decode/subtract on the bus
  // side, keeping arithmetic out of the 250 MHz command/state feedback.
  logic [15:0] frame_offset_cfg, frame_match_cfg;
  logic frame_zero_cfg, frame_one_cfg;
  logic [15:0] frame_match_active;
  logic frame_zero_active, frame_one_active, frame_offset_legal;
  logic frame_offset_overrun;
  logic [AW-1:0] read_index;
  logic [INDEX_W:0] lut_addr;
  logic [2*NUM_TAPS-1:0] lut_written;
  localparam int unsigned LUT_GROUP_SIZE=32;
  localparam int unsigned LUT_GROUP_COUNT=(2*NUM_TAPS+LUT_GROUP_SIZE-1)/LUT_GROUP_SIZE;
  logic [LUT_GROUP_COUNT-1:0] lut_group_ready;
  logic lut_ready;
  logic lut_enabled, previous_input;
  (* RAM_STYLE="BLOCK" *) logic [15:0] rise_lut [0:NUM_TAPS-1];
  (* RAM_STYLE="BLOCK" *) logic [15:0] fall_lut [0:NUM_TAPS-1];
  logic [15:0] rise_lut_bus_q, fall_lut_bus_q;
  logic request_toggle, abort_toggle, clear_request, ack_toggle, ack_seen;
  (* ASYNC_REG="TRUE" *) logic [1:0] request_sync, abort_sync, ack_sync;
  (* ASYNC_REG="TRUE" *) logic [1:0] capture_sync, process_sync;
  (* ASYNC_REG="TRUE" *) logic [2:0] fast_reset_pipe;
  wire fast_rstn=fast_reset_pipe[2];
  // Local synchronous reset leaves reduce fanout and avoid asynchronous CLR
  // recovery paths from one reset FF to the complete acquisition datapath.
  (* DONT_TOUCH="TRUE" *) logic capture_rstn, process_rstn;
  (* DONT_TOUCH="TRUE" *) logic rise_sampler_rstn, fall_sampler_rstn;
  always_ff @(posedge fast_clk_i) begin
    capture_rstn<=fast_rstn;
    process_rstn<=fast_rstn;
    rise_sampler_rstn<=fast_rstn;
    fall_sampler_rstn<=fast_rstn;
  end
  logic abort_seen;
  logic capturing, processing;
  logic [31:0] completed_fast, flags_fast, completed_bus, flags_bus;
  assign busy_o=request_toggle != ack_seen;

  // Command payload is held from request through completion acknowledgement.
  // Results and record RAM are frozen before the completion toggle crosses.
  always_ff @(posedge fast_clk_i or negedge rstn_i)
    if (!rstn_i) fast_reset_pipe<='0;
    else fast_reset_pipe<={fast_reset_pipe[1:0],1'b1};
  always_ff @(posedge bus_clk_i) begin
    if (!rstn_i) begin
      ack_sync<='0; capture_sync<='0; process_sync<='0;
      ack_seen<=0; completed_bus<=0; flags_bus<=0;
    end else begin
      ack_sync<={ack_sync[0],ack_toggle};
      capture_sync<={capture_sync[0],capturing};
      process_sync<={process_sync[0],processing};
      if (ack_sync[1]!=ack_seen) begin
        completed_bus<=completed_fast;
        flags_bus<=flags_fast;
        ack_seen<=ack_sync[1];
      end
      if (previous_input!=input_select_i && !busy_o) begin
        completed_bus<=0; flags_bus<=0;
      end
    end
  end

  // Four in-flight frames only. Retaining 512-bit snapshots for all 16384
  // pulses would exceed Z7020 BRAM capacity. These shallow memories use LUTs.
  (* RAM_STYLE="DISTRIBUTED" *) logic [NUM_TAPS-1:0] rise_memory [0:STAGING_DEPTH-1];
  (* RAM_STYLE="DISTRIBUTED" *) logic [NUM_TAPS-1:0] fall_memory [0:STAGING_DEPTH-1];
  // Keep edge timestamps, rather than a subtraction result, on the capture
  // side. Subtraction and scaling run only after a frame has closed.
  (* RAM_STYLE="DISTRIBUTED" *) logic [95:0] meta_memory [0:STAGING_DEPTH-1];
  // Store flags, coarse ticks, both raw indices and the signed 17-bit fine
  // correction. Reconstruct width_ps on readout instead of storing a redundant
  // 32-bit width. At 512 taps this is 99 bits/record, not 114 (30 KiB saved).
  // Cycle ID remains implicit; the external five-word register ABI is intact.
  // Bound each physical bank to 1024 records. Local, preserved address/data
  // registers avoid routing one write address across the entire result BRAM.
  localparam int unsigned BANK_AW=(AW<10) ? AW : 10;
  localparam int unsigned BANK_DEPTH=2**BANK_AW;
  localparam int unsigned BANK_COUNT=(DEPTH+BANK_DEPTH-1)/BANK_DEPTH;
  localparam int unsigned READ_GROUPS=(BANK_COUNT+3)/4;
  logic record_write_en;
  logic [AW-1:0] record_write_addr;
  logic [RECORD_W-1:0] record_write_data;
  wire [RECORD_W-1:0] record_bank_q [0:BANK_COUNT-1];
  logic [RECORD_W-1:0] record_group_q [0:READ_GROUPS-1];
  logic [AW-1:0] read_select_ram, read_select_group;
  logic [RECORD_W-1:0] record_bus_q;
  for (genvar bank=0; bank<BANK_COUNT; bank=bank+1) begin : gen_record_bank
    localparam int unsigned THIS_DEPTH=((bank+1)*BANK_DEPTH<=DEPTH) ?
      BANK_DEPTH : DEPTH-bank*BANK_DEPTH;
    (* RAM_STYLE="BLOCK" *) logic [RECORD_W-1:0] record_memory [0:THIS_DEPTH-1];
    (* DONT_TOUCH="TRUE" *) logic [BANK_AW-1:0] record_write_addr_local;
    (* DONT_TOUCH="TRUE" *) logic [RECORD_W-1:0] record_write_data_local;
    (* DONT_TOUCH="TRUE" *) logic record_write_en_local;
    (* DONT_TOUCH="TRUE" *) logic [BANK_AW-1:0] record_read_addr_local;
    logic [RECORD_W-1:0] bank_q;
    always_ff @(posedge fast_clk_i) begin
      record_write_en_local<=fast_rstn && record_write_en &&
        ((record_write_addr >> BANK_AW)==bank);
      record_write_addr_local<=record_write_addr[BANK_AW-1:0];
      record_write_data_local<=record_write_data;
      if (record_write_en_local)
        record_memory[record_write_addr_local]<=record_write_data_local;
    end
    always_ff @(posedge bus_clk_i) begin
      record_read_addr_local<=read_index[BANK_AW-1:0];
      bank_q<=record_memory[record_read_addr_local];
    end
    assign record_bank_q[bank]=bank_q;
  end
  // Two registered mux levels; no large bank selector on a BRAM-to-arithmetic
  // path. The selection pipeline follows the RAM's registered read address.
  always_ff @(posedge bus_clk_i) begin
    read_select_ram<=read_index;
    read_select_group<=read_select_ram;
    for (int group_index=0; group_index<READ_GROUPS; group_index=group_index+1) begin
      record_group_q[group_index]<='0;
      for (int lane=0; lane<4; lane=lane+1)
        if (group_index*4+lane<BANK_COUNT &&
            ((read_select_group >> BANK_AW)%4)==lane)
          record_group_q[group_index]<=record_bank_q[group_index*4+lane];
    end
  end
  logic [AW-1:0] read_select_final;
  always_ff @(posedge bus_clk_i) begin
    read_select_final<=read_select_group;
    record_bus_q<='0;
    for (int group_index=0; group_index<READ_GROUPS; group_index=group_index+1)
      if ((read_select_final >> (BANK_AW+2))==group_index)
        record_bus_q<=record_group_q[group_index];
  end
  logic [31:0] read_scale_base, read_scale_sub, read_coarse_ps, read_width_ps;
  logic signed [16:0] read_fine_delta_s1, read_fine_delta;
  logic read_width_valid_s1, read_width_valid;
  // 4000 = 4096 - (64+32). Each arithmetic stage contains one 32-bit add or
  // subtract, separated from both RAM clock-to-Q and the bank selection mux.
  // Index-to-width latency is seven bus clocks; the existing API's sixteen
  // settling reads cover it. The buffer stays frozen throughout readout.
  always_ff @(posedge bus_clk_i) begin
    read_scale_base<=record_bus_q[63:32]<<12;
    read_scale_sub<=(record_bus_q[63:32]<<6)+(record_bus_q[63:32]<<5);
    read_fine_delta_s1<=$signed(record_bus_q[64+2*INDEX_W +: 17]);
    read_width_valid_s1<=record_bus_q[0];
    read_coarse_ps<=read_scale_base-read_scale_sub;
    read_fine_delta<=read_fine_delta_s1;
    read_width_valid<=read_width_valid_s1;
    // Extend the stored two's-complement delta explicitly before the unsigned
    // coarse-width addition. Negative corrections must not become +2**17 ps.
    read_width_ps<=read_width_valid ?
      read_coarse_ps+{{15{read_fine_delta[16]}},read_fine_delta} : 32'b0;
  end
  logic valid_read, valid_write;
  wire [7:0] offset=sys_addr_i[7:0];
  wire sys_en=sys_wen_i|sys_ren_i;
  wire sys_accept=sys_en && !sys_ack_o;
  // Keep bitmap updates independent of the shared activation-validity mux.
  // Otherwise the full all-written reduction can feed back to every bit.
  wire lut_data_write=rstn_i && sys_wen_i && sys_accept && sys_addr_i[1:0]==0 &&
    offset==8'h3c && !busy_o && sys_wdata_i<=65535;
  wire lut_clear_write=sys_wen_i && sys_accept && sys_addr_i[1:0]==0 &&
    offset==8'h40 && !busy_o && sys_wdata_i==1;
  wire lut_invalidate=(previous_input!=input_select_i) || lut_clear_write;
  always_ff @(posedge bus_clk_i) begin
    if (!rstn_i || lut_invalidate) begin
      lut_written<='0;
      lut_ready<=0;
    end else begin
      if (lut_data_write) lut_written[lut_addr]<=1'b1;
      lut_ready<=&lut_group_ready;
    end
  end
  for (genvar group_index=0; group_index<LUT_GROUP_COUNT; group_index=group_index+1) begin : gen_lut_ready
    localparam int unsigned GROUP_BITS=((group_index+1)*LUT_GROUP_SIZE<=2*NUM_TAPS) ?
      LUT_GROUP_SIZE : 2*NUM_TAPS-group_index*LUT_GROUP_SIZE;
    always_ff @(posedge bus_clk_i) begin
      if (!rstn_i || lut_invalidate) lut_group_ready[group_index]<=0;
      else lut_group_ready[group_index]<=&lut_written[group_index*LUT_GROUP_SIZE +: GROUP_BITS];
    end
  end

  // Explicit readiness replaces a software guess about pipeline latency.
  // Keep legacy settling reads compatible; v8 software can poll 0x148.
  logic [6:0] read_ready_pipe;
  wire read_index_changed=sys_wen_i && sys_accept && valid_write &&
    sys_addr_i[1:0]==0 && offset==8'h18;
  always_ff @(posedge bus_clk_i) begin
    if (!rstn_i || busy_o || read_index_changed) read_ready_pipe<=0;
    else read_ready_pipe<={read_ready_pipe[5:0],1'b1};
  end

  always_comb begin
    valid_read=1;
    case(offset)
      8'h00,8'h08,8'h0c,8'h10,8'h14,8'h18,8'h2c,8'h30,
      8'h38,8'h3c,8'h40,8'h44,8'h48,8'h58,8'h5c: begin end
      8'h1c,8'h20,8'h24,8'h28,8'h34:
        valid_read=!busy_o && (read_index<completed_bus);
      default: valid_read=0;
    endcase
    valid_write=0;
    case(offset)
      8'h04: valid_write=(sys_wdata_i==2) ||
        (!busy_o && ((sys_wdata_i==4) ||
         ((sys_wdata_i==1) && !legacy_conflict_i && previous_input==input_select_i)));
      8'h0c: valid_write=!busy_o && sys_wdata_i>0 && sys_wdata_i<=DEPTH;
      8'h18: valid_write=!busy_o && sys_wdata_i<completed_bus;
      8'h30: valid_write=!busy_o && sys_wdata_i>0;
      8'h58: valid_write=!busy_o && sys_wdata_i<=262140 && sys_wdata_i[1:0]==0;
      8'h38: valid_write=!busy_o && sys_wdata_i<2*NUM_TAPS;
      8'h3c: valid_write=!busy_o && sys_wdata_i<=65535;
      8'h40: valid_write=!busy_o &&
        ((sys_wdata_i==1) || (sys_wdata_i==4) ||
         ((sys_wdata_i==2) && lut_ready && previous_input==input_select_i));
      default: begin end
    endcase
  end

  always_ff @(posedge bus_clk_i) begin
    if (!rstn_i) begin
      requested_count<=16; timeout_cfg<=250000; timeout_match_cfg<=249998;
      timeout_immediate_cfg<=0; read_index<='0;
      frame_offset_cfg<=0; frame_match_cfg<=0; frame_zero_cfg<=1; frame_one_cfg<=0;
      lut_addr<='0; lut_enabled<=0; previous_input<=0;
      request_toggle<=0; abort_toggle<=0; clear_request<=0;
      sys_ack_o<=0; sys_err_o<=0; sys_rdata_o<=0;
    end else begin
      sys_ack_o<=sys_en;
      if (!sys_en) sys_err_o<=0;
      // ARM makes BUSY true immediately. Do not revalidate an accepted ARM
      // on the following clock while the CDC bridge still holds WEN high.
      else if (sys_accept) sys_err_o<=((sys_addr_i[1:0]!=0) ||
        (sys_wen_i&&!valid_write) || (sys_ren_i&&!valid_read));
      previous_input<=input_select_i;
      if (previous_input!=input_select_i) begin
        lut_enabled<=0;
      end
      if (sys_wen_i && sys_accept && valid_write && sys_addr_i[1:0]==0) begin
        case(offset)
          8'h04: if (sys_wdata_i==2) abort_toggle<=~abort_toggle;
            else begin
              clear_request<=sys_wdata_i==4;
              request_toggle<=~request_toggle;
              read_index<='0;
            end
          8'h0c: requested_count<=sys_wdata_i;
          8'h18: read_index<=sys_wdata_i[AW-1:0];
          8'h30: begin
            timeout_cfg<=sys_wdata_i;
            // Expiry is registered one count ahead. Preserve the previous
            // terminal cycle, including the special one-clock timeout.
            timeout_match_cfg<=sys_wdata_i>1 ? sys_wdata_i-2 : 0;
            timeout_immediate_cfg<=sys_wdata_i==1;
          end
          8'h58: begin
            frame_offset_cfg<=sys_wdata_i[17:2];
            frame_match_cfg<=sys_wdata_i>4 ? sys_wdata_i[17:2]-16'd2 : 16'd0;
            frame_zero_cfg<=sys_wdata_i==0; frame_one_cfg<=sys_wdata_i==4;
          end
          8'h38: lut_addr<=sys_wdata_i[INDEX_W:0];
          8'h3c: begin
            // Editing an active table requires explicit activation afterward.
            lut_enabled<=0;
          end
          8'h40: case(sys_wdata_i)
            1: lut_enabled<=0;
            2: lut_enabled<=1;
            4: lut_enabled<=0;
            default: begin end
          endcase
          default: begin end
        endcase
      end
      // Hold response after request release for the existing sys_bus CDC.
      if (sys_accept) case(offset)
        8'h00: sys_rdata_o<=32'h5057_4201; // PWB v1
        8'h08: sys_rdata_o<=(busy_o ? 32'd0 : flags_bus) |
                              {29'd0,process_sync[1],capture_sync[1],busy_o};
        8'h0c: sys_rdata_o<=requested_count;
        8'h10: sys_rdata_o<=DEPTH;
        8'h14: sys_rdata_o<=busy_o ? 0 : completed_bus;
        8'h18: sys_rdata_o<=32'(read_index);
        8'h1c: sys_rdata_o<=32'(read_index)+1'b1;
        8'h20: sys_rdata_o<=record_bus_q[31:0];
        8'h24: sys_rdata_o<=record_bus_q[63:32];
        8'h28: sys_rdata_o<={16'(record_bus_q[64+INDEX_W +: INDEX_W]),
                                    16'(record_bus_q[64 +: INDEX_W])};
        // VALID was determined using 64-bit range checks at capture time.
        // For valid records, this 32-bit sum is the exact stored result.
        8'h34: sys_rdata_o<=read_width_ps;
        8'h2c: sys_rdata_o<=TICK_PS;
        8'h30: sys_rdata_o<=timeout_cfg;
        8'h38: sys_rdata_o<=32'(lut_addr);
        8'h3c: sys_rdata_o<=lut_addr[INDEX_W] ?
          {16'd0,fall_lut_bus_q} : {16'd0,rise_lut_bus_q};
        8'h40: sys_rdata_o<={29'd0,lut_ready,1'b0,lut_enabled};
        8'h44: sys_rdata_o<=MIN_PERIOD*2; // minimum pulse period, ns
        8'h48: sys_rdata_o<={31'd0,(&read_ready_pipe) && !busy_o};
        8'h58: sys_rdata_o<={14'd0,frame_offset_cfg,2'b0}; // ns
        8'h5c: sys_rdata_o<=32'h4652_4d01; // FRM v1, fixed frame offset
        default: sys_rdata_o<=0;
      endcase
    end
  end

  logic [NUM_TAPS-1:0] sampled_taps, sampled_fall_taps;
  // Only this first timed pipeline stage loads the physical sampler Q pins.
  // Tap zero must not be pulled away from its carry to serve capture control.
  (* KEEP="TRUE", SHREG_EXTRACT="NO" *) logic [NUM_TAPS-1:0] raw_pipe_0, raw_pipe_1, raw_pipe_2;
  (* KEEP="TRUE", SHREG_EXTRACT="NO" *) logic [NUM_TAPS-1:0] fall_raw_pipe_0, fall_raw_pipe_1, fall_raw_pipe_2;
  tdc_carry_chain #(.NUM_CARRY4(NUM_CARRY4),.NUM_TAPS(NUM_TAPS)) i_carry (
    .clk_i(fast_clk_i),.rstn_i(rise_sampler_rstn),.event_i(event_i),.sampled_taps_o(sampled_taps));
  // Invert BEFORE a separate physical delay line. Inverting a captured falling
  // code cannot remove the carry's polarity-dependent tap ordering/skew.
  // Both fine measurements encode a rising transition with bounded population checks.
  tdc_carry_chain #(.NUM_CARRY4(NUM_CARRY4),.NUM_TAPS(NUM_TAPS)) i_fall_carry (
    .clk_i(fast_clk_i),.rstn_i(fall_sampler_rstn),.event_i(~event_i),.sampled_taps_o(sampled_fall_taps));
  // Sampler plus raw_pipe_0 and the two marker registers are matched. Both
  // edge timestamps move by one common clock; their difference is unchanged.
  logic marker_sample, marker_d, previous_level, previous_fall_level;
  wire rising=raw_pipe_0[0] && !previous_level;
  // Timestamp the SAME chain/clock sample as the fine snapshot. Using the
  // rising chain's falling detector here could introduce a one-tick mismatch.
  wire falling=fall_raw_pipe_0[0] && !previous_fall_level;
  logic [31:0] ticks;
  logic tick_carry8, tick_carry16, tick_carry24;
  always_ff @(posedge fast_clk_i) begin
    if (!capture_rstn) begin
      request_sync<=0; abort_sync<=0; marker_sample<=0; previous_level<=0; ticks<=0;
      previous_fall_level<=0;
      tick_carry8<=0; tick_carry16<=0; tick_carry24<=0;
    end else begin
      request_sync<={request_sync[0],request_toggle};
      abort_sync<={abort_sync[0],abort_toggle};
      marker_sample<=cycle_start_i;
      previous_level<=raw_pipe_0[0];
      previous_fall_level<=fall_raw_pipe_0[0];
      // Anticipate carries by one tick. At low-byte FE, prepare the carry
      // that increments the next byte when FF advances to 00. No 32-bit
      // carry chain is left in the 250 MHz timestamp feedback path.
      tick_carry8<=ticks[7:0]==8'hfe;
      tick_carry16<=ticks[15:0]==16'hfffe;
      tick_carry24<=ticks[23:0]==24'hfffffe;
      ticks[7:0]<=ticks[7:0]+1'b1;
      ticks[15:8]<=ticks[15:8]+tick_carry8;
      ticks[23:16]<=ticks[23:16]+tick_carry16;
      ticks[31:24]<=ticks[31:24]+tick_carry24;
    end
  end

  typedef enum logic [1:0] {IDLE,WAIT_TRIGGER,CAPTURE,DRAIN} state_t;
  state_t state;
  typedef enum logic [3:0] {P_IDLE,FETCH,FETCH_WAIT,DIFF_LOW,DIFF_HIGH,
                            R_START,R_WAIT,SCALE,CORRECT,DELTA_LOW,DELTA_HIGH,
                            ADD_FINE,CHECK_RANGE,CALCULATE} process_state_t;
  process_state_t process_state;
  assign capturing=(state==WAIT_TRIGGER)||(state==CAPTURE);
  assign processing=(process_state!=P_IDLE);
  logic request_seen, use_lut;
  // Counts never exceed DEPTH. target_count is the number of frames still
  // to close, so capture enables need only a zero/one comparison, not a
  // 32-bit increment/compare chain on the raw-RAM write-enable path.
  logic [AW:0] target_count, captured_count, processed_count;
  logic last_frame;
  // The source period is committed before a pulse marker reaches capture.
  // Register its legality locally instead of comparing 32 remote period bits
  // in the same cycle as timestamp write-enable generation.
  logic period_ok;
  always_ff @(posedge fast_clk_i) begin
    period_ok<=pulse_period_i>=MIN_PERIOD;
    frame_offset_legal<=32'(frame_offset_cfg)<(pulse_period_i>>1);
  end
  logic [31:0] watchdog, timeout_match_active;
  logic timeout_immediate, watchdog_expired;
  (* DONT_TOUCH="TRUE" *) logic [1:0] watchdog_match;
  assign watchdog_expired=&watchdog_match;
  logic watchdog_carry8, watchdog_carry16, watchdog_carry24;
  logic [AW-1:0] capture_index, process_index;
  wire [SAW-1:0] capture_slot=SAW'(capture_index);
  wire [SAW-1:0] process_slot=SAW'(process_index);
  localparam int unsigned OCC_W=$clog2(STAGING_DEPTH+1);
  logic [OCC_W-1:0] staging_used;
  wire staging_full=(staging_used >= STAGING_DEPTH-1);
  wire start_request=(state==IDLE && request_sync[1]!=request_seen);
  wire abort_pending=(abort_sync[1]!=abort_seen);
  // This output replaces only the original second marker FF. At offset=0
  // its sampling latency is identical; raw edge timestamps are not retimed.
  tdc_frame_delay i_frame_delay (
    .clk_i(fast_clk_i), .rstn_i(capture_rstn), .enable_i(capturing),
    .clear_i(start_request || abort_pending), .marker_i(marker_sample),
    .offset_zero_i(frame_zero_active), .offset_one_i(frame_one_active),
    .match_i(frame_match_active), .marker_o(marker_d),
    .overrun_o(frame_offset_overrun));
  logic have_rise, have_fall;
  logic [31:0] rise_tick, fall_tick, frame_flags;
  logic [NUM_TAPS-1:0] rise_q, fall_q;
  // Independent reset-free inputs remove the 512-bit rise/fall selector and
  // feed two encoders concurrently. Physical tap thresholds can be locally
  // reordered; population rank avoids the strict-prefix missing-code failure.
  // The filtered transition region must still fit within eight taps.
  logic [NUM_TAPS-1:0] rise_encoder_raw, fall_encoder_raw;
  (* DONT_TOUCH="TRUE" *) logic encoder_rstn;
  always_ff @(posedge fast_clk_i) begin
    rise_encoder_raw<=rise_q;
    fall_encoder_raw<=fall_q;
    encoder_rstn<=process_rstn && state!=IDLE && !abort_pending && !start_request;
  end
  logic [95:0] meta_q;
  wire [31:0] meta_flags=meta_q[95:64];
  wire [31:0] meta_rise_tick=meta_q[31:0];
  wire [31:0] meta_fall_tick=meta_q[63:32];
  logic [16:0] coarse_low;
  logic [31:0] coarse_ticks;

  logic encoder_start, rise_encoder_done, fall_encoder_done;
  logic [INDEX_W-1:0] rise_encoder_index, fall_encoder_index, rise_index, fall_index;
  logic [7:0] rise_encoder_status, fall_encoder_status, rise_status, fall_status;
  tdc_thermometer_encoder #(.NUM_TAPS(NUM_TAPS),.INDEX_W(INDEX_W),
    .TAPS_PER_CYCLE(ENCODER_TAPS_PER_CYCLE),.MAX_TRANSITION_SPAN(8)) i_rise_encoder (
    .clk_i(fast_clk_i),.rstn_i(encoder_rstn),.start_i(encoder_start),
    .raw_taps_i(rise_encoder_raw),.busy_o(),.done_o(rise_encoder_done),
    .fine_index_o(rise_encoder_index),.status_o(rise_encoder_status));
  tdc_thermometer_encoder #(.NUM_TAPS(NUM_TAPS),.INDEX_W(INDEX_W),
    .TAPS_PER_CYCLE(ENCODER_TAPS_PER_CYCLE),.MAX_TRANSITION_SPAN(8)) i_fall_encoder (
    .clk_i(fast_clk_i),.rstn_i(encoder_rstn),.start_i(encoder_start),
    .raw_taps_i(fall_encoder_raw),.busy_o(),.done_o(fall_encoder_done),
    .fine_index_o(fall_encoder_index),.status_o(fall_encoder_status));

  function automatic logic [31:0] finish_flags(
    input logic seen_rise, seen_fall, level,
    input logic [31:0] extra);
    logic [31:0] value;
    value=extra | (seen_rise ? 0 : NO_RISE) | (seen_fall ? 0 : NO_FALL);
    if (!seen_fall && level) value=value|SATURATED;
    if (seen_rise && seen_fall && extra==0) value=value|VALID;
    return value;
  endfunction
  logic [31:0] end_flags, end_fall_tick, result_flags;
  logic [43:0] coarse_base, coarse_sub, coarse_ps;
  logic [15:0] rise_lut_q, fall_lut_q;
  // Retain a fabric register after each RAM output, keeping the BRAM clock-to-Q
  // and route off the fine subtractor path (v9 routed WNS -0.862 ns here).
  (* DONT_TOUCH="TRUE" *) logic [15:0] rise_lut_local, fall_lut_local;
  logic [8:0] fine_delta_low;
  // True dual-port RAM: software reads/writes on the bus clock; the encoder
  // reads on the sampler clock. No reset or mux on the RAM output registers.
  // Tables cannot be edited during acquisition. SCALE supplies the existing
  // read-latency clock before CORRECT consumes the registered fine values.
  always_ff @(posedge bus_clk_i) begin
    if (rstn_i && sys_wen_i && sys_accept && valid_write &&
        sys_addr_i[1:0]==0 && offset==8'h3c) begin
      if (lut_addr[INDEX_W]) fall_lut[lut_addr[INDEX_W-1:0]]<=sys_wdata_i[15:0];
      else rise_lut[lut_addr[INDEX_W-1:0]]<=sys_wdata_i[15:0];
    end
    rise_lut_bus_q<=rise_lut[lut_addr[INDEX_W-1:0]];
    fall_lut_bus_q<=fall_lut[lut_addr[INDEX_W-1:0]];
  end
  always_ff @(posedge fast_clk_i) begin
    rise_lut_q<=rise_lut[rise_index];
    fall_lut_q<=fall_lut[fall_index];
    rise_lut_local<=rise_lut_q;
    fall_lut_local<=fall_lut_q;
  end
  logic signed [16:0] fine_delta;
  logic signed [44:0] fine_width;
  logic fine_in_range, coarse_in_range;
  always_comb begin
    // A falling edge exactly at the boundary closes the preceding frame but
    // is flagged: the coarse sampling cannot establish a strictly positive gap.
    end_flags=finish_flags(have_rise,have_fall || (falling&&have_rise),
      raw_pipe_0[0],frame_flags | ((falling&&have_rise&&!have_fall) ? BOUNDARY : 0));
    end_fall_tick=(falling&&have_rise&&!have_fall) ? ticks :
      (have_fall ? fall_tick : rise_tick);
    result_flags=meta_flags | (32'(rise_status)<<16) | (32'(fall_status)<<24);
    if (meta_flags[0]) begin
      if (!rise_status[0] || !fall_status[0]) result_flags=result_flags|FINE_INVALID;
      if (use_lut && rise_status[0] && fall_status[0] && fine_in_range) begin
        result_flags=result_flags|CAL_USED;
      end else result_flags=result_flags|COARSE_ONLY;
    end
    if (meta_flags[0] && !coarse_in_range) begin
      result_flags=(result_flags|OUT_OF_RANGE)&~VALID;
    end
  end

  // Select each RAM's single write port before the clocked memory process.
  // Multiple conditional array assignments, particularly to capture_index and
  // capture_index+1, are not a supported Vivado 2020.1 BRAM inference pattern.
  logic rise_write_en, fall_write_en, meta_write_en;
  logic [SAW-1:0] rise_write_addr;
  logic [95:0] meta_write_data;
  always_comb begin
    rise_write_en=0; fall_write_en=0; meta_write_en=0;
    rise_write_addr=capture_slot;
    // Invalid cycles are suppressed by meta_write_en. Do not force every
    // metadata bit to zero through the timeout/state decode on those cycles.
    meta_write_data={end_flags,end_fall_tick,rise_tick};
    if (fast_rstn) begin
      if (state==WAIT_TRIGGER) begin
        rise_write_en=marker_d && period_ok && rising;
      end else if (state==CAPTURE) begin
        if (marker_d) begin
          meta_write_en=1;
          meta_write_data={end_flags,end_fall_tick,rise_tick};
          fall_write_en=falling&&have_rise&&!have_fall;
          rise_write_en=!last_frame && !staging_full && rising;
          rise_write_addr=capture_slot+1'b1;
        end else if (watchdog_expired) begin
          meta_write_en=1;
          meta_write_data={finish_flags(have_rise,have_fall,
            raw_pipe_0[0],frame_flags|TRIGGER_TIMEOUT),
            have_fall ? fall_tick : rise_tick,rise_tick};
        end else begin
          rise_write_en=rising&&!have_rise;
          fall_write_en=falling&&have_rise&&!have_fall;
        end
      end
    end
  end

  // raw_pipe_0 isolates the sampler from edge/frame control. The next two
  // raw stages match the two enable/address/metadata stages, preserving the
  // thermometer snapshot belonging to the detected edge. No wide data reset.
  logic [1:0] rise_en_pipe, fall_en_pipe, meta_en_pipe;
  logic [SAW-1:0] rise_addr_pipe_0, rise_addr_pipe_1;
  logic [SAW-1:0] slot_pipe_0, slot_pipe_1;
  logic [95:0] meta_pipe_0, meta_pipe_1;
  always_ff @(posedge fast_clk_i) begin
    raw_pipe_0<=sampled_taps;
    raw_pipe_1<=raw_pipe_0;
    raw_pipe_2<=raw_pipe_1;
    fall_raw_pipe_0<=sampled_fall_taps;
    fall_raw_pipe_1<=fall_raw_pipe_0;
    fall_raw_pipe_2<=fall_raw_pipe_1;
    // Flushing enables during reset prevents stale writes without resetting
    // any tap data or inferring resets on the distributed RAM contents.
    if (!fast_rstn) begin
      rise_en_pipe<=0; fall_en_pipe<=0; meta_en_pipe<=0;
    end else begin
      rise_en_pipe<={rise_en_pipe[0],rise_write_en};
      fall_en_pipe<={fall_en_pipe[0],fall_write_en};
      meta_en_pipe<={meta_en_pipe[0],meta_write_en};
    end
    rise_addr_pipe_0<=rise_write_addr; rise_addr_pipe_1<=rise_addr_pipe_0;
    slot_pipe_0<=capture_slot; slot_pipe_1<=slot_pipe_0;
    meta_pipe_0<=meta_write_data; meta_pipe_1<=meta_pipe_0;
  end

  // Reset-free, synchronous simple-dual-port RAM templates: exactly one write
  // statement and one registered read per array. Metadata/counts validate the
  // contents, so reset/clear never needs to touch the memory storage itself.
  always_ff @(posedge fast_clk_i) begin
    if (rise_en_pipe[1]) rise_memory[rise_addr_pipe_1]<=raw_pipe_2;
    rise_q<=rise_memory[process_slot];
  end
  always_ff @(posedge fast_clk_i) begin
    if (fall_en_pipe[1]) fall_memory[slot_pipe_1]<=fall_raw_pipe_2;
    fall_q<=fall_memory[process_slot];
  end
  always_ff @(posedge fast_clk_i) begin
    if (meta_en_pipe[1]) meta_memory[slot_pipe_1]<=meta_pipe_1;
    meta_q<=meta_memory[process_slot];
  end
  // Register the write port using synchronous control, so asynchronously reset
  // state/address registers cannot directly drive BRAM control/address pins.
  // Each bank has one additional local write-port stage. DRAIN explicitly
  // waits for both stages before publishing completion to the bus domain.
  logic record_write_pending;
  logic drain_ready;
  always_ff @(posedge fast_clk_i) begin
    record_write_pending<=fast_rstn && record_write_en;
    record_write_en<=fast_rstn && state!=IDLE && !start_request && !abort_pending && process_state==CALCULATE;
    if (fast_rstn && state!=IDLE && !start_request && !abort_pending && process_state==CALCULATE) begin
      record_write_addr<=process_index;
      record_write_data<={result_flags[9] ? fine_delta : 17'sd0,
        fall_index,rise_index,coarse_ticks,result_flags};
    end
  end

  // Compare the wide counters before the completion-control fanout. DRAIN
  // enters only after capture is closed, and this extra clock also keeps the
  // final bank write ahead of the completion toggle.
  always_ff @(posedge fast_clk_i) begin
    if (!capture_rstn || start_request || abort_pending) drain_ready<=0;
    else drain_ready<=state==DRAIN && processed_count==captured_count &&
      process_state==P_IDLE && !record_write_en && !record_write_pending;
  end

  // Track the small staging occupancy directly instead of subtracting the
  // full acquisition counters in a capture write-enable expression.
  wire close_frame=(state==CAPTURE) && (marker_d || watchdog_expired);
  wire retire_frame=(process_state==CALCULATE);
  always_ff @(posedge fast_clk_i) begin
    if (!capture_rstn) staging_used<=0;
    else if (start_request || abort_pending || state==IDLE) staging_used<=0;
    else case ({close_frame,retire_frame})
      2'b10: staging_used<=staging_used+1'b1;
      2'b01: staging_used<=staging_used-1'b1;
      default: begin end
    endcase
  end

  // Same exact byte-wise counter as timestamps, with all lookahead carries
  // cleared whenever the stopped-trigger interval restarts. Equality is
  // sufficient for expiry: this counter advances once per active clock and
  // the terminal value cannot change during a burst.
  always_ff @(posedge fast_clk_i) begin
    if (!capture_rstn) begin
      watchdog<=0; watchdog_carry8<=0; watchdog_carry16<=0; watchdog_carry24<=0;
    end else if (start_request || state==IDLE || (capturing && marker_d)) begin
      watchdog<=0; watchdog_carry8<=0; watchdog_carry16<=0; watchdog_carry24<=0;
    end else if (capturing) begin
      watchdog_carry8<=watchdog[7:0]==8'hfe;
      watchdog_carry16<=watchdog[15:0]==16'hfffe;
      watchdog_carry24<=watchdog[23:0]==24'hfffffe;
      watchdog[7:0]<=watchdog[7:0]+1'b1;
      watchdog[15:8]<=watchdog[15:8]+watchdog_carry8;
      watchdog[23:16]<=watchdog[23:16]+watchdog_carry16;
      watchdog[31:24]<=watchdog[31:24]+watchdog_carry24;
    end
  end

  // Register the two comparison halves independently. Their AND preserves
  // the existing terminal cycle without the routed 32-bit equality path.
  // The seed on every counter restart preserves TIMEOUT=1 exactly.
  always_ff @(posedge fast_clk_i) begin
    if (!capture_rstn) watchdog_match<=0;
    else if (start_request) watchdog_match<={2{timeout_immediate_cfg}};
    else if (state==IDLE || (capturing && marker_d)) watchdog_match<={2{timeout_immediate}};
    else if (capturing) begin
      watchdog_match[0]<=watchdog[15:0]==timeout_match_active[15:0];
      watchdog_match[1]<=watchdog[31:16]==timeout_match_active[31:16];
    end else watchdog_match<=0;
  end

  always_ff @(posedge fast_clk_i) begin
    if (!capture_rstn) begin
      state<=IDLE; request_seen<=0; abort_seen<=0; ack_toggle<=0;
      completed_fast<=0; flags_fast<=0; target_count<=0; last_frame<=1;
      timeout_match_active<=0; timeout_immediate<=0;
      captured_count<=0; capture_index<=0;
      have_rise<=0; have_fall<=0; rise_tick<=0; fall_tick<=0; frame_flags<=0;
      use_lut<=0;
      frame_match_active<=0; frame_zero_active<=1; frame_one_active<=0;
    end else begin
      if (start_request) begin
        request_seen<=request_sync[1];
        completed_fast<=0; flags_fast<=0; capture_index<=0;
        captured_count<=0; have_rise<=0; have_fall<=0;
        target_count<=(AW+1)'(requested_count); last_frame<=(requested_count<=1);
        timeout_match_active<=timeout_match_cfg; timeout_immediate<=timeout_immediate_cfg;
        use_lut<=lut_enabled;
        frame_match_active<=frame_match_cfg;
        frame_zero_active<=frame_zero_cfg; frame_one_active<=frame_one_cfg;
        if (clear_request) ack_toggle<=request_sync[1];
        else if (!frame_offset_legal) begin
          flags_fast<=DONE|RATE_ERROR; ack_toggle<=request_sync[1];
        end else state<=WAIT_TRIGGER;
      end
      case(state)
        WAIT_TRIGGER: begin
          if (marker_d) begin
            if (!period_ok) begin
              flags_fast<=DONE|RATE_ERROR; ack_toggle<=request_seen; state<=IDLE;
            end else begin
              state<=CAPTURE; have_rise<=rising; have_fall<=0;
              frame_flags<=(raw_pipe_0[0]&&!rising) ? HIGH_START : 0;
              fall_tick<=ticks; rise_tick<=ticks;
            end
          end else if (watchdog_expired) begin
            flags_fast<=DONE|TIMEOUT; ack_toggle<=request_seen; state<=IDLE;
          end
        end
        CAPTURE: begin
          if (marker_d) begin
            captured_count<=captured_count+1'b1;
            target_count<=target_count-1'b1;
            last_frame<=(target_count<=2);
            if (!period_ok) begin
              completed_fast<=0; flags_fast<=DONE|RATE_ERROR;
              ack_toggle<=request_seen; state<=IDLE;
            end else if (last_frame) state<=DRAIN;
            else if (staging_full) begin
              completed_fast<=0; flags_fast<=DONE|OVERFLOW;
              ack_toggle<=request_seen; state<=IDLE;
            end
            else begin
              capture_index<=capture_index+1'b1;
              have_rise<=rising; have_fall<=0; rise_tick<=ticks; fall_tick<=ticks;
              frame_flags<=(raw_pipe_0[0]&&!rising) ? HIGH_START : 0;
            end
          end else if (watchdog_expired) begin
            captured_count<=captured_count+1'b1;
            flags_fast<=TIMEOUT; state<=DRAIN;
          end else begin
            if (rising) begin
              if (have_rise) frame_flags<=frame_flags|EXTRA_EDGES;
              else begin
                have_rise<=1; rise_tick<=ticks;
              end
            end
            if (falling) begin
              if (have_fall || !have_rise) frame_flags<=frame_flags|EXTRA_EDGES;
              else begin
                have_fall<=1; fall_tick<=ticks;
              end
            end
          end
        end
        DRAIN: begin
          if (drain_ready) begin
            completed_fast<=captured_count; flags_fast<=flags_fast|DONE;
            ack_toggle<=request_seen; state<=IDLE;
          end
        end
        default: begin end
      endcase
      if (frame_offset_overrun && capturing) begin
        completed_fast<=0; flags_fast<=DONE|RATE_ERROR;
        state<=IDLE; ack_toggle<=request_seen;
      end
      if (abort_pending) begin
        abort_seen<=abort_sync[1];
        if (state!=IDLE || request_sync[1]!=request_seen) begin
          state<=IDLE; completed_fast<=0; flags_fast<=DONE|ABORTED;
          request_seen<=request_sync[1]; ack_toggle<=request_sync[1];
        end
      end
    end
  end

  // Consume CLOSED frames while the producer captures subsequent pulses.
  // Parallel 512-tap / 8-tap-per-clock encoders fit inside a 500 ns frame.
  // A ring-overrun guard prevents silently overwriting an old frame.
  always_ff @(posedge fast_clk_i) begin
    if (!process_rstn) begin
      process_state<=P_IDLE; process_index<=0; processed_count<=0;
      encoder_start<=0; rise_index<=0; fall_index<=0;
      rise_status<=0; fall_status<=0;
      coarse_ps<=0; fine_delta<=0; fine_delta_low<=0; fine_width<=0;
      fine_in_range<=0; coarse_in_range<=0;
      coarse_low<=0; coarse_ticks<=0; coarse_base<=0; coarse_sub<=0;
    end else if (start_request || abort_pending || state==IDLE) begin
      process_state<=P_IDLE; process_index<=0; processed_count<=0;
      encoder_start<=0; rise_index<=0; fall_index<=0;
      rise_status<=0; fall_status<=0;
      coarse_ps<=0; fine_delta<=0; fine_delta_low<=0; fine_width<=0;
      fine_in_range<=0; coarse_in_range<=0;
      coarse_low<=0; coarse_ticks<=0; coarse_base<=0; coarse_sub<=0;
    end else begin
      encoder_start<=0;
      case(process_state)
        // While idle, the staging occupancy is exactly the queued-frame count.
        // Avoid the wide acquisition-counter comparison on state enables.
        P_IDLE: if (staging_used!=0) process_state<=FETCH;
        FETCH: begin
          rise_status<=0; fall_status<=0; rise_index<=0; fall_index<=0;
          process_state<=FETCH_WAIT;
        end
        FETCH_WAIT: process_state<=DIFF_LOW;
        DIFF_LOW: begin
          coarse_low<={1'b0,meta_fall_tick[15:0]}-{1'b0,meta_rise_tick[15:0]};
          process_state<=DIFF_HIGH;
        end
        DIFF_HIGH: begin
          // The seventeenth low bit is the unsigned borrow. Subtract modulo
          // 2^32 so an interval spanning timestamp wrap is still exact.
          coarse_ticks<={16'(meta_fall_tick[31:16]-meta_rise_tick[31:16]-coarse_low[16]),
                         coarse_low[15:0]};
          process_state<=R_START;
        end
        R_START: if (!meta_flags[0]) process_state<=SCALE;
          else begin encoder_start<=1; process_state<=R_WAIT; end
        // Identical encoder parameters/start/reset give identical completion
        // latency; indices/statuses are captured together for this frame.
        R_WAIT: if (rise_encoder_done && fall_encoder_done) begin
          rise_index<=rise_encoder_index; rise_status<=rise_encoder_status;
          fall_index<=fall_encoder_index; fall_status<=fall_encoder_status;
          process_state<=SCALE;
        end
        SCALE: begin
          coarse_base<=44'(coarse_ticks)<<12;
          coarse_sub<=(44'(coarse_ticks)<<6)+(44'(coarse_ticks)<<5);
          process_state<=CORRECT;
        end
        CORRECT: begin
          coarse_ps<=coarse_base-coarse_sub;
          // Both indices changed at R_WAIT. This extra state also allows the
          // two RAM-read stages to settle before consuming the local outputs.
          process_state<=DELTA_LOW;
        end
        DELTA_LOW: begin
          fine_delta_low<={1'b0,rise_lut_local[7:0]}-{1'b0,fall_lut_local[7:0]};
          process_state<=DELTA_HIGH;
        end
        DELTA_HIGH: begin
          fine_delta<={9'({1'b0,rise_lut_local[15:8]}-
                         {1'b0,fall_lut_local[15:8]}-fine_delta_low[8]),
                       fine_delta_low[7:0]};
          process_state<=ADD_FINE;
        end
        ADD_FINE: begin
          fine_width<=$signed({1'b0,coarse_ps})+
            $signed({{28{fine_delta[16]}},fine_delta});
          process_state<=CHECK_RANGE;
        end
        CHECK_RANGE: begin
          // For a nonnegative 32-bit result all upper bits, including the
          // signed result's sign bit, must be zero. Register these reductions
          // before flag decoding and the result-data write/reset muxes.
          fine_in_range<=~|fine_width[44:32];
          coarse_in_range<=~|coarse_ps[43:32];
          process_state<=CALCULATE;
        end
        CALCULATE: begin
          processed_count<=processed_count+1'b1;
          process_index<=process_index+1'b1;
          process_state<=P_IDLE;
        end
        default: process_state<=P_IDLE;
      endcase
    end
  end
endmodule
