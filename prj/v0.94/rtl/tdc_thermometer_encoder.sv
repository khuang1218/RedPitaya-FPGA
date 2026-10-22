////////////////////////////////////////////////////////////////////////////////
// Iterative thermometer-code correction and encoding for the TDC.
//
// raw_taps_i[0] is the first carry tap.  A normal rising-edge sample therefore
// contains a run of ones from bit zero followed by a run of zeros.  The encoder
// applies a three-tap majority filter, counts the leading ones, and reports any
// later zero-to-one transition instead of silently accepting a malformed code.
// WIDTH may select bounded population encoding: count RAW ones, allowing a
// small reordered transition region after filtering. This does not assume
// physical tap arrival order and rejects widely separated transition regions.
////////////////////////////////////////////////////////////////////////////////

module tdc_thermometer_encoder #(
  parameter int unsigned NUM_TAPS = 512,
  parameter int unsigned INDEX_W  = $clog2(NUM_TAPS),
  parameter int unsigned TAPS_PER_CYCLE = 1,
  parameter int unsigned MAX_TRANSITION_SPAN = 0 // zero preserves strict legacy decoding
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
  localparam int unsigned LEAVES = 2**$clog2(STEP);
  localparam logic [INDEX_W:0] SPAN_LIMIT = (INDEX_W+1)'(
    (MAX_TRANSITION_SPAN>NUM_TAPS) ? NUM_TAPS : MAX_TRANSITION_SPAN);

  logic [NUM_TAPS-1:0] shift_reg;
  logic [INDEX_W-1:0]  tap_index;
  logic [INDEX_W:0]    leading_ones;
  logic                previous_raw;
  logic                seen_zero;
  logic                multiple_transitions;
  logic                bubble_corrected;
  logic                captured_all_zero;
  logic                captured_all_one;
  logic [INDEX_W:0] population, last_one_end;
  logic decode_pending, transition_span_ok;

  logic [STEP-1:0] filtered_bits;
  logic [STEP-1:0] lane_valid, bubble_bits;
  logic window_left, window_right;
  logic [STEP_W-1:0] chunk_leading;
  logic chunk_zero, chunk_multiple, chunk_bubble, chunk_one;
  logic [INDEX_W:0] leading_ones_next;
  logic seen_zero_next;
  logic multiple_transitions_next;
  logic bubble_corrected_next;
  // Separate the majority/prefix network from the running count and output
  // decode. Chunks still enter every clock; only pipeline fill/drain is added.
  logic [STEP_W-1:0] chunk_leading_q;
  logic chunk_zero_q, chunk_multiple_q, chunk_bubble_q, chunk_one_q;
  logic chunk_valid, chunk_last, scan_complete, finish_pending;
  logic chunk_all_zero_q, chunk_all_one_q;
  logic [STEP_W-1:0] chunk_population_q, chunk_last_one_q;
  logic [INDEX_W-1:0] chunk_base_q;
  wire [STEP_W-1:0] tree_leading [1:2*LEAVES-1];
  wire [STEP_W-1:0] tree_population [1:2*LEAVES-1];
  wire [STEP_W-1:0] tree_last_one [1:2*LEAVES-1];
  wire tree_zero [1:2*LEAVES-1];
  wire tree_one [1:2*LEAVES-1];
  wire tree_multiple [1:2*LEAVES-1];
  wire tree_bubble [1:2*LEAVES-1];

  // A balanced prefix tree replaces eight serial conditional increments and
  // zero/one tests. Padded leaves are empty, rather than artificial zero taps.
  for (genvar lane=0; lane<LEAVES; lane=lane+1) begin : gen_chunk_leaf
    if (lane<STEP) begin : used
      assign tree_leading[LEAVES+lane]=STEP_W'(lane_valid[lane] && filtered_bits[lane]);
      assign tree_population[LEAVES+lane]=STEP_W'(lane_valid[lane] && shift_reg[lane]);
      assign tree_last_one[LEAVES+lane]=STEP_W'(lane);
      assign tree_zero[LEAVES+lane]=lane_valid[lane] && !filtered_bits[lane];
      assign tree_one[LEAVES+lane]=lane_valid[lane] && filtered_bits[lane];
      assign tree_multiple[LEAVES+lane]=0;
      assign tree_bubble[LEAVES+lane]=bubble_bits[lane];
    end else begin : padding
      assign tree_leading[LEAVES+lane]=0;
      assign tree_population[LEAVES+lane]=0;
      assign tree_last_one[LEAVES+lane]=0;
      assign tree_zero[LEAVES+lane]=0;
      assign tree_one[LEAVES+lane]=0;
      assign tree_multiple[LEAVES+lane]=0;
      assign tree_bubble[LEAVES+lane]=0;
    end
  end
  for (genvar node=1; node<LEAVES; node=node+1) begin : gen_chunk_node
    assign tree_leading[node]=tree_zero[2*node] ? tree_leading[2*node] :
      tree_leading[2*node]+tree_leading[2*node+1];
    assign tree_population[node]=tree_population[2*node]+tree_population[2*node+1];
    assign tree_last_one[node]=tree_one[2*node+1] ? tree_last_one[2*node+1] : tree_last_one[2*node];
    assign tree_zero[node]=tree_zero[2*node] | tree_zero[2*node+1];
    assign tree_one[node]=tree_one[2*node] | tree_one[2*node+1];
    assign tree_multiple[node]=tree_multiple[2*node] | tree_multiple[2*node+1] |
      (tree_zero[2*node] && tree_one[2*node+1]);
    assign tree_bubble[node]=tree_bubble[2*node] | tree_bubble[2*node+1];
  end
  assign chunk_leading=tree_leading[1];
  assign chunk_zero=tree_zero[1];
  assign chunk_one=tree_one[1];
  assign chunk_multiple=tree_multiple[1];
  assign chunk_bubble=tree_bubble[1];

  always_comb begin
    filtered_bits='0;
    lane_valid='0; bubble_bits='0;
    window_left=0; window_right=0;
    // Majority filtering is independent for each valid lane.
    for (int lane=0; lane<STEP; lane=lane+1) begin
      if (32'(tap_index)+lane < NUM_TAPS) begin
        lane_valid[lane]=1;
        if (lane==0) window_left=(tap_index==0) ? shift_reg[0] : previous_raw;
        else window_left=shift_reg[lane-1];
        if (32'(tap_index)+lane==NUM_TAPS-1) window_right=shift_reg[lane];
        else if (lane+1<NUM_TAPS) window_right=shift_reg[lane+1];
        else window_right=shift_reg[lane];
        filtered_bits[lane]=(window_left & shift_reg[lane]) |
                            (window_left & window_right) |
                            (shift_reg[lane] & window_right);
        bubble_bits[lane]=(filtered_bits[lane]!=shift_reg[lane]);
      end
    end
    leading_ones_next=leading_ones + (seen_zero ? (INDEX_W+1)'(0) : (INDEX_W+1)'(chunk_leading_q));
    seen_zero_next=seen_zero | chunk_zero_q;
    multiple_transitions_next=multiple_transitions | chunk_multiple_q | (seen_zero && chunk_one_q);
    bubble_corrected_next=bubble_corrected | chunk_bubble_q;
  end

  // The complete raw bank is overwritten at START. Resetting all data bits
  // adds reset fanout and routing pressure without protecting any valid data.
  always_ff @(posedge clk_i) begin
    // Data is irrelevant while reset cancels the control/valid pipeline.
    // Keep reset out of all 512 load/shift muxes and their inferred CE/R pins.
    if (start_i && !busy_o) shift_reg<=raw_taps_i;
    else if (busy_o && !scan_complete) shift_reg<=shift_reg >> STEP;
  end

  always_ff @(posedge clk_i) begin
    if (!rstn_i) begin
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
      chunk_leading_q      <= '0;
      chunk_zero_q         <= 0;
      chunk_multiple_q     <= 0;
      chunk_bubble_q       <= 0;
      chunk_one_q          <= 0;
      chunk_valid          <= 0;
      chunk_last           <= 0;
      scan_complete        <= 0;
      finish_pending       <= 0;
      decode_pending       <= 0;
      transition_span_ok   <= 0;
      population           <= 0;
      last_one_end         <= 0;
      chunk_population_q   <= 0;
      chunk_last_one_q     <= 0;
      chunk_base_q         <= 0;
      chunk_all_zero_q     <= 0;
      chunk_all_one_q      <= 0;
    end else begin
      done_o <= 1'b0;
      chunk_valid <= 0;

      if (start_i && !busy_o) begin
        tap_index            <= '0;
        leading_ones         <= '0;
        previous_raw         <= raw_taps_i[0];
        seen_zero            <= 1'b0;
        multiple_transitions <= 1'b0;
        bubble_corrected     <= 1'b0;
        // Accumulate RAW saturation flags over chunks instead of reducing
        // the entire input bank and its selector in the START clock.
        captured_all_zero    <= 1;
        captured_all_one     <= 1;
        busy_o               <= 1'b1;
        status_o             <= '0;
        scan_complete        <= 0;
        finish_pending       <= 0;
        decode_pending       <= 0;
        transition_span_ok   <= 0;
        population           <= 0;
        last_one_end         <= 0;
      end else if (busy_o) begin
        if (!scan_complete) begin
          chunk_leading_q <= chunk_leading;
          chunk_population_q<=tree_population[1];
          chunk_last_one_q<=tree_last_one[1];
          chunk_base_q<=tap_index;
          chunk_zero_q <= chunk_zero;
          chunk_multiple_q <= chunk_multiple;
          chunk_bubble_q <= chunk_bubble;
          chunk_one_q <= chunk_one;
          chunk_all_zero_q<=~|(shift_reg[STEP-1:0] & lane_valid);
          chunk_all_one_q<=&(shift_reg[STEP-1:0] | ~lane_valid);
          chunk_valid <= 1;
          chunk_last <= (32'(tap_index)+STEP >= NUM_TAPS);
          previous_raw <= shift_reg[STEP-1];
          if (32'(tap_index)+STEP >= NUM_TAPS) scan_complete <= 1;
          else tap_index <= tap_index + INDEX_W'(STEP);
        end
        if (chunk_valid) begin
          leading_ones <= leading_ones_next;
          seen_zero <= seen_zero_next;
          multiple_transitions <= multiple_transitions_next;
          bubble_corrected <= bubble_corrected_next;
          captured_all_zero<=captured_all_zero && chunk_all_zero_q;
          captured_all_one<=captured_all_one && chunk_all_one_q;
          if (MAX_TRANSITION_SPAN>0) begin
            population<=population+(INDEX_W+1)'(chunk_population_q);
            if (chunk_one_q)
              last_one_end<=(INDEX_W+1)'(chunk_base_q)+(INDEX_W+1)'(chunk_last_one_q)+1'b1;
          end
          if (chunk_last) finish_pending <= 1;
        end

        if (finish_pending) begin
          finish_pending <= 0;
          if (MAX_TRANSITION_SPAN>0) begin
            // first filtered zero = leading_ones; last_one_end is exclusive.
            // Register the bounded-span decision before status decoding.
            transition_span_ok<=(last_one_end-leading_ones)<=SPAN_LIMIT;
            decode_pending<=1;
          end else begin
            busy_o <= 1'b0;
            done_o <= 1'b1;

            // NUM_TAPS itself cannot be represented by INDEX_W when NUM_TAPS
            // is a power of two. Saturate the invalid all-one debug index.
            if (leading_ones >= NUM_TAPS)
              fine_index_o <= INDEX_W'(NUM_TAPS-1);
            else
              fine_index_o <= leading_ones[INDEX_W-1:0];

            status_o <= (captured_all_zero ? (STATUS_NO_TRANSITION | STATUS_ALL_ZERO) : 8'h00) |
                        (captured_all_one  ? (STATUS_NO_TRANSITION | STATUS_ALL_ONE)  : 8'h00) |
                        (multiple_transitions ? STATUS_MULTIPLE_TRANSITIONS : 8'h00) |
                        (bubble_corrected ? STATUS_BUBBLE_CORRECTED : 8'h00) |
                        ((!captured_all_zero && !captured_all_one &&
                          !multiple_transitions) ? STATUS_VALID : 8'h00);
          end
        end
        if (decode_pending) begin
          busy_o<=0; done_o<=1; decode_pending<=0;
          // Population rank remains meaningful when adjacent tap thresholds
          // are reordered. Do not majority-filter the count: that would merge
          // distinct fine bins. Calibration must use this new rank directly.
          fine_index_o<=(population>=NUM_TAPS) ? INDEX_W'(NUM_TAPS-1) : population[INDEX_W-1:0];
          status_o <= (captured_all_zero ? (STATUS_NO_TRANSITION | STATUS_ALL_ZERO) : 8'h00) |
                      (captured_all_one ? (STATUS_NO_TRANSITION | STATUS_ALL_ONE) : 8'h00) |
                      ((multiple_transitions && !transition_span_ok) ? STATUS_MULTIPLE_TRANSITIONS : 8'h00) |
                      ((bubble_corrected || (multiple_transitions && transition_span_ok)) ? STATUS_BUBBLE_CORRECTED : 8'h00) |
                      ((!captured_all_zero && !captured_all_one &&
                        (!multiple_transitions || transition_span_ok)) ? STATUS_VALID : 8'h00);
        end
      end
    end
  end

endmodule: tdc_thermometer_encoder

