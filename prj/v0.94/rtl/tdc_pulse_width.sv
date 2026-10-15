`timescale 1ns/1ps
// PCB pulse-width acquisition. A small raw-frame ring feeds an online encoder;
// compact results remain in BRAM for the whole 16384-pulse finite burst.
// First release: <= 1 MHz trigger, 250 MHz sampler, >= 8 ns HIGH/LOW for
// reliable coarse edge detection. Shorter pulses/gaps are not guaranteed.
// Carry codes are diagnostic until separate rise/fall LUTs are calibrated.
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
  localparam logic [31:0] TICK_PS=4000, MIN_PERIOD=500; // 1 MHz maximum
  localparam int unsigned RECORD_W=96+2*INDEX_W;

  logic [31:0] requested_count, timeout_cfg;
  logic [AW-1:0] read_index;
  logic [INDEX_W:0] lut_addr;
  logic [2*NUM_TAPS-1:0] lut_written;
  logic lut_enabled, previous_input;
  (* RAM_STYLE="DISTRIBUTED" *) logic [15:0] rise_lut [0:NUM_TAPS-1];
  (* RAM_STYLE="DISTRIBUTED" *) logic [15:0] fall_lut [0:NUM_TAPS-1];
  logic request_toggle, abort_toggle, clear_request, ack_toggle, ack_seen;
  (* ASYNC_REG="TRUE" *) logic [1:0] request_sync, abort_sync, ack_sync;
  (* ASYNC_REG="TRUE" *) logic [1:0] capture_sync, process_sync;
  (* ASYNC_REG="TRUE" *) logic [2:0] fast_reset_pipe;
  wire fast_rstn=fast_reset_pipe[2];
  logic abort_seen;
  logic capturing, processing;
  logic [31:0] completed_fast, flags_fast, completed_bus, flags_bus;
  wire lut_ready=&lut_written;
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
  (* RAM_STYLE="DISTRIBUTED" *) logic [63:0] meta_memory [0:STAGING_DEPTH-1];
  // Store flags, coarse ticks, full raw indices, and computed width. Cycle ID
  // is implicit in the address. The external five-word register ABI is intact.
  (* RAM_STYLE="BLOCK" *) logic [RECORD_W-1:0] record_memory [0:DEPTH-1];
  logic [RECORD_W-1:0] record_bus_q;
  always_ff @(posedge bus_clk_i) record_bus_q<=record_memory[read_index];

  logic valid_read, valid_write;
  wire [7:0] offset=sys_addr_i[7:0];
  wire sys_en=sys_wen_i|sys_ren_i;
  always_comb begin
    valid_read=1;
    case(offset)
      8'h00,8'h08,8'h0c,8'h10,8'h14,8'h18,8'h2c,8'h30,
      8'h38,8'h3c,8'h40,8'h44: begin end
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
      requested_count<=16; timeout_cfg<=250000; read_index<='0;
      lut_addr<='0; lut_written<='0; lut_enabled<=0; previous_input<=0;
      request_toggle<=0; abort_toggle<=0; clear_request<=0;
      sys_ack_o<=0; sys_err_o<=0; sys_rdata_o<=0;
    end else begin
      sys_ack_o<=sys_en;
      sys_err_o<=sys_en && ((sys_addr_i[1:0]!=0) ||
        (sys_wen_i&&!valid_write) || (sys_ren_i&&!valid_read));
      previous_input<=input_select_i;
      if (previous_input!=input_select_i) begin
        lut_enabled<=0; lut_written<='0;
      end
      if (sys_wen_i && !sys_ack_o && valid_write && sys_addr_i[1:0]==0) begin
        case(offset)
          8'h04: if (sys_wdata_i==2) abort_toggle<=~abort_toggle;
            else begin
              clear_request<=sys_wdata_i==4;
              request_toggle<=~request_toggle;
              read_index<='0;
            end
          8'h0c: requested_count<=sys_wdata_i;
          8'h18: read_index<=sys_wdata_i[AW-1:0];
          8'h30: timeout_cfg<=sys_wdata_i;
          8'h38: lut_addr<=sys_wdata_i[INDEX_W:0];
          8'h3c: begin
            if (lut_addr[INDEX_W]) fall_lut[lut_addr[INDEX_W-1:0]]<=sys_wdata_i[15:0];
            else rise_lut[lut_addr[INDEX_W-1:0]]<=sys_wdata_i[15:0];
            lut_written[lut_addr]<=1;
            // Editing an active table requires explicit activation afterward.
            lut_enabled<=0;
          end
          8'h40: case(sys_wdata_i)
            1: begin lut_written<='0; lut_enabled<=0; end
            2: lut_enabled<=1;
            4: lut_enabled<=0;
            default: begin end
          endcase
          default: begin end
        endcase
      end
      // Hold response after request release for the existing sys_bus CDC.
      if (sys_en) case(offset)
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
        8'h34: sys_rdata_o<=record_bus_q[64+2*INDEX_W +: 32];
        8'h2c: sys_rdata_o<=TICK_PS;
        8'h30: sys_rdata_o<=timeout_cfg;
        8'h38: sys_rdata_o<=32'(lut_addr);
        8'h3c: sys_rdata_o<=lut_addr[INDEX_W] ?
          {16'd0,fall_lut[lut_addr[INDEX_W-1:0]]} : {16'd0,rise_lut[lut_addr[INDEX_W-1:0]]};
        8'h40: sys_rdata_o<={29'd0,lut_ready,1'b0,lut_enabled};
        8'h44: sys_rdata_o<=MIN_PERIOD*2; // minimum pulse period, ns
        default: sys_rdata_o<=0;
      endcase
    end
  end

  logic [NUM_TAPS-1:0] sampled_taps;
  tdc_carry_chain #(.NUM_CARRY4(NUM_CARRY4),.NUM_TAPS(NUM_TAPS)) i_carry (
    .clk_i(fast_clk_i),.rstn_i(fast_rstn),.event_i(event_i),.sampled_taps_o(sampled_taps));
  // Tap bank and marker each have one fast-clock register latency.
  logic marker_d, previous_level;
  wire rising=sampled_taps[0] && !previous_level;
  wire falling=!sampled_taps[0] && previous_level;
  logic [31:0] ticks;
  always_ff @(posedge fast_clk_i or negedge fast_rstn) begin
    if (!fast_rstn) begin
      request_sync<=0; abort_sync<=0; marker_d<=0; previous_level<=0; ticks<=0;
    end else begin
      request_sync<={request_sync[0],request_toggle};
      abort_sync<={abort_sync[0],abort_toggle};
      marker_d<=cycle_start_i; previous_level<=sampled_taps[0]; ticks<=ticks+1'b1;
    end
  end

  typedef enum logic [1:0] {IDLE,WAIT_TRIGGER,CAPTURE,DRAIN} state_t;
  state_t state;
  typedef enum logic [3:0] {P_IDLE,FETCH,R_START,R_WAIT,F_START,F_WAIT,
                            SCALE,CORRECT,CALCULATE} process_state_t;
  process_state_t process_state;
  assign capturing=(state==WAIT_TRIGGER)||(state==CAPTURE);
  assign processing=(process_state!=P_IDLE);
  logic request_seen, use_lut;
  logic [31:0] target_count, watchdog, timeout_active, captured_count;
  logic [31:0] processed_count;
  logic [AW-1:0] capture_index, process_index;
  wire [SAW-1:0] capture_slot=SAW'(capture_index);
  wire [SAW-1:0] process_slot=SAW'(process_index);
  wire staging_full=(captured_count-processed_count >= STAGING_DEPTH-1);
  wire start_request=(state==IDLE && request_sync[1]!=request_seen);
  wire abort_pending=(abort_sync[1]!=abort_seen);
  logic have_rise, have_fall;
  logic [31:0] rise_tick, frame_width, frame_flags;
  logic [NUM_TAPS-1:0] rise_q, fall_q, encoder_raw;
  logic [63:0] meta_q;

  logic encoder_start, encoder_done, encoder_busy;
  logic [INDEX_W-1:0] encoder_index, rise_index, fall_index;
  logic [7:0] encoder_status, rise_status, fall_status;
  tdc_thermometer_encoder #(.NUM_TAPS(NUM_TAPS),.INDEX_W(INDEX_W),
    .TAPS_PER_CYCLE(ENCODER_TAPS_PER_CYCLE)) i_encoder (
    .clk_i(fast_clk_i),.rstn_i(fast_rstn && state!=IDLE && !abort_pending && !start_request),.start_i(encoder_start),
    .raw_taps_i(encoder_raw),.busy_o(encoder_busy),.done_o(encoder_done),
    .fine_index_o(encoder_index),.status_o(encoder_status));

  function automatic logic [31:0] finish_flags(
    input logic seen_rise, seen_fall, level,
    input logic [31:0] extra);
    logic [31:0] value;
    value=extra | (seen_rise ? 0 : NO_RISE) | (seen_fall ? 0 : NO_FALL);
    if (!seen_fall && level) value=value|SATURATED;
    if (seen_rise && seen_fall && extra==0) value=value|VALID;
    return value;
  endfunction
  logic [31:0] end_flags, end_width, result_flags, result_width;
  logic [63:0] coarse_ps;
  logic signed [16:0] fine_delta;
  logic signed [63:0] fine_width;
  always_comb begin
    // A falling edge exactly at the boundary closes the preceding frame but
    // is flagged: the coarse sampling cannot establish a strictly positive gap.
    end_flags=finish_flags(have_rise,have_fall || (falling&&have_rise),
      sampled_taps[0],frame_flags | ((falling&&have_rise&&!have_fall) ? BOUNDARY : 0));
    end_width=(falling&&have_rise&&!have_fall) ? ticks-rise_tick : frame_width;
    result_flags=meta_q[63:32] | (32'(rise_status)<<16) | (32'(fall_status)<<24);
    result_width=coarse_ps[31:0];
    if (meta_q[32]) begin
      if (!rise_status[0] || !fall_status[0]) result_flags=result_flags|FINE_INVALID;
      if (use_lut && rise_status[0] && fall_status[0] &&
          fine_width>=0 && fine_width<=64'shffff_ffff) begin
        result_width=fine_width[31:0]; result_flags=result_flags|CAL_USED;
      end else result_flags=result_flags|COARSE_ONLY;
    end else result_width=0;
    if (meta_q[32] && coarse_ps>64'hffff_ffff) begin
      result_flags=(result_flags|OUT_OF_RANGE)&~VALID; result_width=0;
    end
  end

  // Select each RAM's single write port before the clocked memory process.
  // Multiple conditional array assignments, particularly to capture_index and
  // capture_index+1, are not a supported Vivado 2020.1 BRAM inference pattern.
  logic rise_write_en, fall_write_en, meta_write_en;
  logic [SAW-1:0] rise_write_addr;
  logic [63:0] meta_write_data;
  always_comb begin
    rise_write_en=0; fall_write_en=0; meta_write_en=0;
    rise_write_addr=capture_slot;
    meta_write_data=0;
    if (fast_rstn) begin
      if (state==WAIT_TRIGGER) begin
        rise_write_en=marker_d && pulse_period_i>=MIN_PERIOD && rising;
      end else if (state==CAPTURE) begin
        if (marker_d) begin
          meta_write_en=1;
          meta_write_data={end_flags,end_width};
          fall_write_en=falling&&have_rise&&!have_fall;
          rise_write_en=(captured_count+1'b1<target_count) && !staging_full && rising;
          rise_write_addr=capture_slot+1'b1;
        end else if (watchdog>=timeout_active-1'b1) begin
          meta_write_en=1;
          meta_write_data={finish_flags(have_rise,have_fall,
            sampled_taps[0],frame_flags|TRIGGER_TIMEOUT),frame_width};
        end else begin
          rise_write_en=rising&&!have_rise;
          fall_write_en=falling&&have_rise&&!have_fall;
        end
      end
    end
  end

  // Reset-free, synchronous simple-dual-port RAM templates: exactly one write
  // statement and one registered read per array. Metadata/counts validate the
  // contents, so reset/clear never needs to touch the memory storage itself.
  always_ff @(posedge fast_clk_i) begin
    if (rise_write_en) rise_memory[rise_write_addr]<=sampled_taps;
    rise_q<=rise_memory[process_slot];
  end
  always_ff @(posedge fast_clk_i) begin
    if (fall_write_en) fall_memory[capture_slot]<=~sampled_taps;
    fall_q<=fall_memory[process_slot];
  end
  always_ff @(posedge fast_clk_i) begin
    if (meta_write_en) meta_memory[capture_slot]<=meta_write_data;
    meta_q<=meta_memory[process_slot];
  end
  // Record RAM has one fast-clock write port and one bus-clock read port.
  always_ff @(posedge fast_clk_i) begin
    if (fast_rstn && state!=IDLE && !start_request && !abort_pending && process_state==CALCULATE)
      record_memory[process_index]<={result_width,
        fall_index,rise_index,meta_q[31:0],result_flags};
  end

  always_ff @(posedge fast_clk_i or negedge fast_rstn) begin
    if (!fast_rstn) begin
      state<=IDLE; request_seen<=0; abort_seen<=0; ack_toggle<=0;
      completed_fast<=0; flags_fast<=0; target_count<=0; timeout_active<=1;
      watchdog<=0; captured_count<=0; capture_index<=0;
      have_rise<=0; have_fall<=0; rise_tick<=0; frame_width<=0; frame_flags<=0;
      use_lut<=0;
    end else begin
      if (start_request) begin
        request_seen<=request_sync[1];
        completed_fast<=0; flags_fast<=0; capture_index<=0;
        captured_count<=0; have_rise<=0; have_fall<=0; watchdog<=0;
        target_count<=requested_count; timeout_active<=timeout_cfg; use_lut<=lut_enabled;
        if (clear_request) ack_toggle<=request_sync[1];
        else state<=WAIT_TRIGGER;
      end
      case(state)
        WAIT_TRIGGER: begin
          watchdog<=watchdog+1'b1;
          if (marker_d) begin
            if (pulse_period_i<MIN_PERIOD) begin
              flags_fast<=DONE|RATE_ERROR; ack_toggle<=request_seen; state<=IDLE;
            end else begin
              state<=CAPTURE; watchdog<=0; have_rise<=rising; have_fall<=0;
              frame_flags<=(sampled_taps[0]&&!rising) ? HIGH_START : 0;
              frame_width<=0; rise_tick<=ticks;
            end
          end else if (watchdog>=timeout_active-1'b1) begin
            flags_fast<=DONE|TIMEOUT; ack_toggle<=request_seen; state<=IDLE;
          end
        end
        CAPTURE: begin
          watchdog<=watchdog+1'b1;
          if (marker_d) begin
            captured_count<=captured_count+1'b1; watchdog<=0;
            if (pulse_period_i<MIN_PERIOD) begin
              completed_fast<=0; flags_fast<=DONE|RATE_ERROR;
              ack_toggle<=request_seen; state<=IDLE;
            end else if (captured_count+1'b1>=target_count) state<=DRAIN;
            else if (staging_full) begin
              completed_fast<=0; flags_fast<=DONE|OVERFLOW;
              ack_toggle<=request_seen; state<=IDLE;
            end
            else begin
              capture_index<=capture_index+1'b1;
              have_rise<=rising; have_fall<=0; rise_tick<=ticks; frame_width<=0;
              frame_flags<=(sampled_taps[0]&&!rising) ? HIGH_START : 0;
            end
          end else if (watchdog>=timeout_active-1'b1) begin
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
                have_fall<=1; frame_width<=ticks-rise_tick;
              end
            end
          end
        end
        DRAIN: begin
          if (processed_count==captured_count && process_state==P_IDLE) begin
            completed_fast<=captured_count; flags_fast<=flags_fast|DONE;
            ack_toggle<=request_seen; state<=IDLE;
          end
        end
        default: begin end
      endcase
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
  // At 512 taps / 8 taps per clock, both edge codes and arithmetic take less
  // than 1 us. A ring-overrun guard prevents silently overwriting an old frame.
  always_ff @(posedge fast_clk_i or negedge fast_rstn) begin
    if (!fast_rstn) begin
      process_state<=P_IDLE; process_index<=0; processed_count<=0;
      encoder_start<=0; encoder_raw<=0; rise_index<=0; fall_index<=0;
      rise_status<=0; fall_status<=0;
      coarse_ps<=0; fine_delta<=0; fine_width<=0;
    end else if (start_request || abort_pending || state==IDLE) begin
      process_state<=P_IDLE; process_index<=0; processed_count<=0;
      encoder_start<=0; encoder_raw<=0; rise_index<=0; fall_index<=0;
      rise_status<=0; fall_status<=0;
      coarse_ps<=0; fine_delta<=0; fine_width<=0;
    end else begin
      encoder_start<=0;
      case(process_state)
        P_IDLE: if (processed_count<captured_count) process_state<=FETCH;
        FETCH: begin
          rise_status<=0; fall_status<=0; rise_index<=0; fall_index<=0;
          process_state<=R_START;
        end
        R_START: if (!meta_q[32]) process_state<=SCALE;
          else begin encoder_raw<=rise_q; encoder_start<=1; process_state<=R_WAIT; end
        R_WAIT: if (encoder_done) begin
          rise_index<=encoder_index; rise_status<=encoder_status; process_state<=F_START; end
        F_START: begin encoder_raw<=fall_q; encoder_start<=1; process_state<=F_WAIT; end
        F_WAIT: if (encoder_done) begin
          fall_index<=encoder_index; fall_status<=encoder_status; process_state<=SCALE; end
        SCALE: begin
          coarse_ps<=64'(meta_q[31:0])*64'(TICK_PS);
          fine_delta<=$signed({1'b0,rise_lut[rise_index]})-$signed({1'b0,fall_lut[fall_index]});
          process_state<=CORRECT;
        end
        CORRECT: begin fine_width<=$signed(coarse_ps)+64'(fine_delta); process_state<=CALCULATE; end
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
