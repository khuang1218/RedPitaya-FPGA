////////////////////////////////////////////////////////////////////////////////
// Iterative thermometer-code correction and encoding for the TDC.
//
// raw_taps_i[0] is the first carry tap.  A normal rising-edge sample therefore
// contains a run of ones from bit zero followed by a run of zeros.  The encoder
// applies a three-tap majority filter, counts the leading ones, and reports any
// later zero-to-one transition instead of silently accepting a malformed code.
////////////////////////////////////////////////////////////////////////////////

module tdc_thermometer_encoder #(
  parameter int unsigned NUM_TAPS = 512,
  parameter int unsigned INDEX_W  = $clog2(NUM_TAPS),
  parameter int unsigned TAPS_PER_CYCLE = 1
)(
  input  logic                  clk_i,
  input  logic                  rstn_i,
  input  logic                  start_i,
  input  logic [NUM_TAPS-1:0]   raw_taps_i,
  output logic                  busy_o,
  output logic                  done_o,
  output logic [INDEX_W-1:0]    fine_index_o,
  output logic [7:0]            status_o
);

  localparam logic [7:0] STATUS_VALID               = 8'h01;
  localparam logic [7:0] STATUS_NO_TRANSITION       = 8'h02;
  localparam logic [7:0] STATUS_MULTIPLE_TRANSITIONS = 8'h04;
  localparam logic [7:0] STATUS_ALL_ZERO            = 8'h08;
  localparam logic [7:0] STATUS_ALL_ONE             = 8'h10;
  localparam logic [7:0] STATUS_BUBBLE_CORRECTED    = 8'h20;
  localparam int unsigned STEP = (TAPS_PER_CYCLE < NUM_TAPS) ? TAPS_PER_CYCLE : NUM_TAPS;
  localparam int unsigned STEP_W = $clog2(STEP+1);

  logic [NUM_TAPS-1:0] shift_reg;
  logic [INDEX_W-1:0]  tap_index;
  logic [INDEX_W:0]    leading_ones;
  logic                previous_raw;
  logic                seen_zero;
  logic                multiple_transitions;
  logic                bubble_corrected;
  logic                captured_all_zero;
  logic                captured_all_one;

  logic [STEP-1:0] filtered_bits;
  logic window_left, window_right;
  logic [STEP_W-1:0] chunk_leading;
  logic chunk_zero, chunk_multiple, chunk_bubble, chunk_one;
  logic [INDEX_W:0] leading_ones_next;
  logic seen_zero_next;
  logic multiple_transitions_next;
  logic bubble_corrected_next;

  always_comb begin
    filtered_bits='0;
    window_left=0; window_right=0;
    chunk_leading=0; chunk_zero=0; chunk_multiple=0; chunk_bubble=0; chunk_one=0;
    // Filter independent lanes, then summarize this small group. The global
    // leading-count accumulator has one addition per clock, not one per lane.
    for (int lane=0; lane<STEP; lane=lane+1) begin
      if (32'(tap_index)+lane < NUM_TAPS) begin
        if (lane==0) window_left=(tap_index==0) ? shift_reg[0] : previous_raw;
        else window_left=shift_reg[lane-1];
        if (32'(tap_index)+lane==NUM_TAPS-1) window_right=shift_reg[lane];
        else if (lane+1<NUM_TAPS) window_right=shift_reg[lane+1];
        else window_right=shift_reg[lane];
        filtered_bits[lane]=(window_left & shift_reg[lane]) |
                            (window_left & window_right) |
                            (shift_reg[lane] & window_right);
        chunk_bubble=chunk_bubble | (filtered_bits[lane]!=shift_reg[lane]);
        if (filtered_bits[lane]) begin
          chunk_one=1;
          if (chunk_zero) chunk_multiple=1;
          else chunk_leading=chunk_leading+1'b1;
        end else chunk_zero=1;
      end
    end
    leading_ones_next=leading_ones + (seen_zero ? (INDEX_W+1)'(0) : (INDEX_W+1)'(chunk_leading));
    seen_zero_next=seen_zero | chunk_zero;
    multiple_transitions_next=multiple_transitions | chunk_multiple | (seen_zero && chunk_one);
    bubble_corrected_next=bubble_corrected | chunk_bubble;
  end

  always_ff @(posedge clk_i) begin
    if (!rstn_i) begin
      shift_reg            <= '0;
      tap_index            <= '0;
      leading_ones         <= '0;
      previous_raw         <= 1'b0;
      seen_zero            <= 1'b0;
      multiple_transitions <= 1'b0;
      bubble_corrected     <= 1'b0;
      captured_all_zero    <= 1'b0;
      captured_all_one     <= 1'b0;
      busy_o               <= 1'b0;
      done_o               <= 1'b0;
      fine_index_o         <= '0;
      status_o             <= '0;
    end else begin
      done_o <= 1'b0;

      if (start_i && !busy_o) begin
        shift_reg            <= raw_taps_i;
        tap_index            <= '0;
        leading_ones         <= '0;
        previous_raw         <= raw_taps_i[0];
        seen_zero            <= 1'b0;
        multiple_transitions <= 1'b0;
        bubble_corrected     <= 1'b0;
        captured_all_zero    <= ~(|raw_taps_i);
        captured_all_one     <= &(raw_taps_i);
        busy_o               <= 1'b1;
        status_o             <= '0;
      end else if (busy_o) begin
        previous_raw         <= shift_reg[STEP-1];
        shift_reg            <= shift_reg >> STEP;
        leading_ones         <= leading_ones_next;
        seen_zero            <= seen_zero_next;
        multiple_transitions <= multiple_transitions_next;
        bubble_corrected     <= bubble_corrected_next;

        if (32'(tap_index)+STEP >= NUM_TAPS) begin
          busy_o <= 1'b0;
          done_o <= 1'b1;

          // NUM_TAPS itself cannot be represented by INDEX_W when NUM_TAPS is
          // a power of two.  All-one is invalid, so saturating its debug index
          // is preferable to wrapping it to zero.
          if (leading_ones_next >= NUM_TAPS)
            fine_index_o <= INDEX_W'(NUM_TAPS-1);
          else
            fine_index_o <= leading_ones_next[INDEX_W-1:0];

          status_o <= (captured_all_zero ? (STATUS_NO_TRANSITION | STATUS_ALL_ZERO) : 8'h00) |
                      (captured_all_one  ? (STATUS_NO_TRANSITION | STATUS_ALL_ONE)  : 8'h00) |
                      (multiple_transitions_next ? STATUS_MULTIPLE_TRANSITIONS : 8'h00) |
                      (bubble_corrected_next ? STATUS_BUBBLE_CORRECTED : 8'h00) |
                      ((!captured_all_zero && !captured_all_one &&
                        !multiple_transitions_next) ? STATUS_VALID : 8'h00);
        end else begin
          tap_index <= tap_index + INDEX_W'(STEP);
        end
      end
    end
  end

endmodule: tdc_thermometer_encoder

