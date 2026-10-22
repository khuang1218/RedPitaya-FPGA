`timescale 1ns/1ps
// Single GPIO pulse generator. Bus: 125 MHz; ODDR clock: 250 MHz.
// Nominal timing unit is 2 ns. Period must be an even number of units
// (4 ns steps); HIGH may be any integer from 1 to PERIOD-1.
// No DDR-memory traffic, additional PLL, or TDC resources are used.
module pulse_gen #(
  parameter integer GPIO_INDEX = 1
)(
  input  logic        bus_clk_i,
  input  logic        fast_clk_i,
  input  logic        arstn_i,
  input  logic [31:0] sys_addr_i,
  input  logic [31:0] sys_wdata_i,
  input  logic        sys_wen_i,
  input  logic        sys_ren_i,
  output logic [31:0] sys_rdata_o,
  output logic        sys_err_o,
  output logic        sys_ack_o,
  input  logic        gpio_data_i,
  input  logic        gpio_dir_i,
  output logic        pin_data_o,
  output logic        pin_dir_o,
  output logic        cycle_start_o,
  output logic [31:0] active_period_o
);
  localparam logic [31:0] ID_VERSION = 32'h50554c01;
  localparam logic [31:0] DEFAULT_PERIOD = 32'd500000; // 1 ms
  localparam logic [31:0] DEFAULT_HIGH = 32'd250000;   // 500 us

  // Both domains reset together. Assertion works even after clock loss;
  // deassertion is synchronized independently into each domain.
  (* ASYNC_REG = "TRUE" *) logic [2:0] bus_reset_pipe, fast_reset_pipe;
  always_ff @(posedge bus_clk_i or negedge arstn_i)
    if (!arstn_i) bus_reset_pipe <= '0;
    else bus_reset_pipe <= {bus_reset_pipe[1:0], 1'b1};
  always_ff @(posedge fast_clk_i or negedge arstn_i)
    if (!arstn_i) fast_reset_pipe <= '0;
    else fast_reset_pipe <= {fast_reset_pipe[1:0], 1'b1};
  wire bus_rstn = bus_reset_pipe[2];
  wire fast_rstn = fast_reset_pipe[2];
  // Give the ODDR reset its own final stage rather than routing the reset
  // shared by the counter/mailbox to the IOB. Assertion still works without
  // a running fast clock; release remains timed to that clock.
  (* ASYNC_REG = "TRUE" *) logic oddr_rstn;
  always_ff @(posedge fast_clk_i or negedge arstn_i)
    if (!arstn_i) oddr_rstn <= 1'b0;
    else oddr_rstn <= fast_rstn;

  logic [31:0] shadow_period, shadow_high;
  logic shadow_enable, claimed, error_sticky;
  logic bus_request_seen;
  // Bundled-data mailbox: immutable from request until returned ACK.
  // Only the toggles cross through synchronizers; the data stays stable.
  logic [31:0] mailbox_period, mailbox_high;
  logic [31:0] mailbox_last, active_last;
  logic [31:0] mailbox_prelast, active_prelast;
  logic mailbox_enable, request_toggle, ack_toggle;
  (* ASYNC_REG = "TRUE" *) logic [1:0] ack_sync, request_sync;
  (* ASYNC_REG = "TRUE" *) logic [1:0] claim_sync, enable_sync, ready_sync;
  logic [31:0] active_period, active_high, readback_period, readback_high;
  logic active_enable;
  wire busy = request_toggle != ack_sync[1];
  wire valid_timing = (shadow_period >= 2) && !shadow_period[0] &&
                      (shadow_high >= 1) && (shadow_high < shadow_period);

  always_ff @(posedge bus_clk_i or negedge bus_rstn) begin
    if (!bus_rstn) begin
      ack_sync <= '0;
      enable_sync <= '0;
      ready_sync <= '0;
      readback_period <= DEFAULT_PERIOD;
      readback_high <= DEFAULT_HIGH;
    end else begin
      ack_sync <= {ack_sync[0], ack_toggle};
      enable_sync <= {enable_sync[0], active_enable};
      ready_sync <= {ready_sync[0], fast_rstn};
      // At this point the active values have settled for multiple bus clocks.
      if (!busy) begin
        readback_period <= active_period;
        readback_high <= active_high;
      end
    end
  end

  always_ff @(posedge bus_clk_i or negedge bus_rstn) begin
    if (!bus_rstn) begin
      shadow_period <= DEFAULT_PERIOD;
      shadow_high <= DEFAULT_HIGH;
      shadow_enable <= 1'b0;
      claimed <= 1'b0;
      error_sticky <= 1'b0;
      mailbox_period <= DEFAULT_PERIOD;
      mailbox_high <= DEFAULT_HIGH;
      mailbox_last <= DEFAULT_PERIOD - 32'd2;
      mailbox_prelast <= DEFAULT_PERIOD - 32'd4;
      mailbox_enable <= 1'b0;
      request_toggle <= 1'b0;
      sys_rdata_o <= '0;
      sys_err_o <= 1'b0;
      sys_ack_o <= 1'b0;
      bus_request_seen <= 1'b0;
    end else begin
      sys_ack_o <= sys_wen_i | sys_ren_i;
      if (!(sys_wen_i || sys_ren_i)) begin
        bus_request_seen <= 1'b0;
        sys_err_o <= 1'b0;
      end else if (!bus_request_seen) begin
        // The CDC bridge holds WEN/REN until it samples our registered ACK.
        // Accept once, then hold ACK/ERR/data until the request deasserts.
        // Replaying APPLY while WEN stays high would set ERROR on BUSY.
        bus_request_seen <= 1'b1;
        sys_err_o <= 1'b0;
        // The system-bus CDC returns data to the PS after this local request
        // deasserts. Hold the last response until another request arrives.
        sys_rdata_o <= '0;
        case (sys_addr_i[15:0])
          16'h0000: begin
            sys_rdata_o <= ID_VERSION;
            if (sys_wen_i) sys_err_o <= 1'b1;
          end
          16'h0004: begin
            sys_rdata_o <= {31'd0, shadow_enable};
            if (sys_wen_i) shadow_enable <= sys_wdata_i[0];
          end
          16'h0008: begin
            sys_rdata_o <= {27'd0, ready_sync[1], error_sticky,
                           claimed, enable_sync[1], busy};
            if (sys_wen_i) sys_err_o <= 1'b1;
          end
          16'h000c: begin
            sys_rdata_o <= shadow_period;
            if (sys_wen_i) shadow_period <= sys_wdata_i;
          end
          16'h0010: begin
            sys_rdata_o <= shadow_high;
            if (sys_wen_i) shadow_high <= sys_wdata_i;
          end
          16'h0014: if (sys_wen_i) begin
            // One command per write: APPLY=1, RESET/RELEASE=2, CLEAR_ERROR=4.
            case (sys_wdata_i)
              32'd1: begin
                if (busy || !ready_sync[1] || !valid_timing ||
                    // The last accepted command is authoritative while idle;
                    // synchronized status can settle a cycle after the ACK.
                    (mailbox_enable && shadow_enable)) begin
                  error_sticky <= 1'b1;
                  sys_err_o <= 1'b1;
                end else begin
                  mailbox_period <= shadow_period;
                  mailbox_high <= shadow_high;
                  mailbox_last <= shadow_period - 32'd2;
                  mailbox_prelast <= shadow_period - 32'd4;
                  mailbox_enable <= shadow_enable;
                  request_toggle <= ~request_toggle;
                  if (shadow_enable) claimed <= 1'b1;
                end
              end
              32'd2: begin
                if (busy || !ready_sync[1]) begin
                  error_sticky <= 1'b1;
                  sys_err_o <= 1'b1;
                end else begin
                  shadow_period <= DEFAULT_PERIOD;
                  shadow_high <= DEFAULT_HIGH;
                  shadow_enable <= 1'b0;
                  mailbox_period <= DEFAULT_PERIOD;
                  mailbox_high <= DEFAULT_HIGH;
                  mailbox_last <= DEFAULT_PERIOD - 32'd2;
                  mailbox_prelast <= DEFAULT_PERIOD - 32'd4;
                  mailbox_enable <= 1'b0;
                  request_toggle <= ~request_toggle;
                  claimed <= 1'b0;
                  error_sticky <= 1'b0;
                end
              end
              32'd4: error_sticky <= 1'b0;
              default: begin error_sticky <= 1'b1; sys_err_o <= 1'b1; end
            endcase
          end
          16'h0018: begin
            sys_rdata_o <= 32'd2; // nominal ns per half-cycle
            if (sys_wen_i) sys_err_o <= 1'b1;
          end
          16'h001c: begin
            sys_rdata_o <= $unsigned(GPIO_INDEX); // positive-bank GPIO index
            if (sys_wen_i) sys_err_o <= 1'b1;
          end
          16'h0020: begin
            sys_rdata_o <= readback_period;
            if (sys_wen_i) sys_err_o <= 1'b1;
          end
          16'h0024: begin
            sys_rdata_o <= readback_high;
            if (sys_wen_i) sys_err_o <= 1'b1;
          end
          default: sys_err_o <= 1'b1;
        endcase
      end
    end
  end

  logic [31:0] phase;
  logic phase_carry8, phase_carry16, phase_carry24;
  logic phase_last;
  logic previous_d2;
  logic [1:0] ddr_data;
  // Final pair registers keep the ownership/GPIO mux off the register-to-ODDR
  // path. The extra pipeline clock is matched by the marker and drive guard.
  (* DONT_TOUCH="TRUE" *) logic [1:0] oddr_data;
  logic [2:0] claim_drive_delay;
  (* ASYNC_REG = "TRUE" *) logic [1:0] gpio_data_sync;
  // phase is always even; the two bits represent successive 2 ns intervals.
  // Periods are even, so the pair never straddles a period boundary.
  always_ff @(posedge fast_clk_i or negedge fast_rstn) begin
    if (!fast_rstn) begin
      request_sync <= '0;
      claim_sync <= '0;
      claim_drive_delay <= '0;
      ack_toggle <= 1'b0;
      active_period <= DEFAULT_PERIOD;
      active_high <= DEFAULT_HIGH;
      active_last <= DEFAULT_PERIOD - 32'd2;
      active_prelast <= DEFAULT_PERIOD - 32'd4;
      phase_last <= 1'b0;
      active_enable <= 1'b0;
      phase <= '0;
      phase_carry8<=0; phase_carry16<=0; phase_carry24<=0;
      ddr_data <= '0;
      gpio_data_sync <= '0;
      previous_d2 <= 1'b0;
    end else begin
      previous_d2 <= oddr_data[1];
      gpio_data_sync <= {gpio_data_sync[0], gpio_data_i};
      request_sync <= {request_sync[0], request_toggle};
      claim_sync <= {claim_sync[0], claimed};
      claim_drive_delay <= {claim_drive_delay[1:0], claim_sync[1]};
      if (request_sync[1] != ack_toggle) begin
        active_period <= mailbox_period;
        active_high <= mailbox_high;
        active_last <= mailbox_last;
        active_prelast <= mailbox_prelast;
        phase_last <= mailbox_last==0;
        active_enable <= mailbox_enable;
        ack_toggle <= request_sync[1];
        phase <= '0;
        phase_carry8<=0; phase_carry16<=0; phase_carry24<=0;
        ddr_data <= '0;
      // Request and ownership use separate synchronizers and can settle on
      // different cycles. Keep phase at zero and ODDR data LOW until the
      // driver guard is complete, so the first physical pulse is a full one.
      end else if (active_enable && claim_sync[1] && claim_drive_delay[2]) begin
        ddr_data[0] <= phase < active_high;
        // phase is even: (phase+1)<HIGH is exactly phase/2 < floor(HIGH/2).
        // This removes the adder before the second-half comparator.
        ddr_data[1] <= phase[31:1] < active_high[31:1];
        // Terminal subtraction is done on the 125 MHz bus side, outside
        // this 4 ns counter feedback path.
        // The wide equality is registered one pair early. Keep it out of
        // the phase-counter increment/reset feedback mux at 250 MHz.
        if (phase_last) begin
          phase<='0;
          phase_last<=active_last==0;
          phase_carry8<=0; phase_carry16<=0; phase_carry24<=0;
        end else begin
          phase_last<=phase==active_prelast;
          // Prepare byte carries one pair early (FC -> FE -> 00). Avoid a
          // full 31-bit increment in the 250 MHz phase feedback path.
          phase_carry8<=phase[7:0]==8'hfc;
          phase_carry16<=phase[15:0]==16'hfffc;
          phase_carry24<=phase[23:0]==24'hfffffc;
          phase[7:0]<=phase[7:0]+8'd2;
          phase[15:8]<=phase[15:8]+phase_carry8;
          phase[23:16]<=phase[23:16]+phase_carry16;
          phase[31:24]<=phase[31:24]+phase_carry24;
        end
      end else begin
        phase <= '0;
        phase_last<=active_last==0;
        phase_carry8<=0; phase_carry16<=0; phase_carry24<=0;
        ddr_data <= '0;
      end
    end
  end

  always_ff @(posedge fast_clk_i or negedge fast_rstn) begin
    if (!fast_rstn) oddr_data<='0;
    else oddr_data<=claim_sync[1] ? ddr_data : {2{gpio_data_sync[1]}};
  end

  // GPIO/pulse selection is BEFORE ODDR. Its Q must connect directly to the
  // selected pin's IOBUF; a LUT mux after ODDR would prevent IOB placement.
  ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .INIT(1'b0), .SRTYPE("ASYNC")) i_oddr (
    .Q(pin_data_o), .C(fast_clk_i), .CE(1'b1),
    .D1(oddr_data[0]),
    .D2(oddr_data[1]),
    .R(!oddr_rstn), .S(1'b0)
  );
  // Let ODDR load LOW for a full fast clock before claiming an input pin.
  // Otherwise a saved HIGH GPIO data bit could leak out during first ON.
  // Release immediately when claim_sync clears, before GPIO passthrough resumes.
  assign pin_dir_o = (claim_sync[1] && claim_drive_delay[2]) ? 1'b1 : gpio_dir_i;
  // Sampled at fast_clk_i: exactly the D1 edge presented to ODDR on this
  // clock, after the ddr_data pipeline and ownership guard. No pin loopback.
  assign cycle_start_o = active_enable && claim_sync[1] && claim_drive_delay[2] &&
                         oddr_data[0] && !previous_d2;
  assign active_period_o = active_period;
endmodule
