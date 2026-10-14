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
  parameter int unsigned INDEX_W  = $clog2(NUM_TAPS)
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

  logic [NUM_TAPS-1:0] shift_reg;
  logic [INDEX_W-1:0]  tap_index;
  logic [INDEX_W:0]    leading_ones;
  logic                previous_raw;
  logic                seen_zero;
  logic                multiple_transitions;
  logic                bubble_corrected;
  logic                captured_all_zero;
  logic                captured_all_one;

  logic window_left;
  logic window_center;
  logic window_right;
  logic filtered_bit;
  logic [INDEX_W:0] leading_ones_next;
  logic seen_zero_next;
  logic multiple_transitions_next;
  logic bubble_corrected_next;

  always_comb begin
    window_center = shift_reg[0];
    window_left   = (tap_index == 0) ? shift_reg[0] : previous_raw;
    window_right  = (tap_index == NUM_TAPS-1) ? shift_reg[0] : shift_reg[1];
    filtered_bit  = (window_left & window_center) |
                    (window_left & window_right)  |
                    (window_center & window_right);

    leading_ones_next = leading_ones;
    seen_zero_next = seen_zero;
    multiple_transitions_next = multiple_transitions;
    bubble_corrected_next = bubble_corrected | (filtered_bit != window_center);

    if (!seen_zero) begin
      if (filtered_bit)
        leading_ones_next = leading_ones + 1'b1;
      else
        seen_zero_next = 1'b1;
    end else if (filtered_bit) begin
      multiple_transitions_next = 1'b1;
    end
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
        previous_raw         <= window_center;
        shift_reg            <= {1'b0, shift_reg[NUM_TAPS-1:1]};
        leading_ones         <= leading_ones_next;
        seen_zero            <= seen_zero_next;
        multiple_transitions <= multiple_transitions_next;
        bubble_corrected     <= bubble_corrected_next;

        if (tap_index == NUM_TAPS-1) begin
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
          tap_index <= tap_index + 1'b1;
        end
      end
    end
  end

endmodule: tdc_thermometer_encoder

