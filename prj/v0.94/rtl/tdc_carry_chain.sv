////////////////////////////////////////////////////////////////////////////////
// Physical CARRY4 delay line and local sampling flip-flops.
//
// The hierarchy and instance names in this file are consumed by the TDC XDC.
// Do not flatten or mechanically rename them without updating the constraints.
////////////////////////////////////////////////////////////////////////////////

(* KEEP_HIERARCHY = "TRUE", DONT_TOUCH = "TRUE" *)
module tdc_carry_chain #(
  parameter int unsigned NUM_CARRY4 = 128,
  parameter int unsigned NUM_TAPS   = NUM_CARRY4 * 4,
  parameter bit          INVERT_TAPS = 1'b0
)(
  input  logic                clk_i,
  input  logic                rstn_i,
  input  logic                event_i,
  output logic [NUM_TAPS-1:0] sampled_taps_o
);

  (* KEEP = "TRUE", DONT_TOUCH = "TRUE" *) logic [NUM_TAPS-1:0] carry_taps;
  logic [NUM_TAPS-1:0] sampled_taps_raw;

  genvar carry_index;
  generate
    for (carry_index = 0; carry_index < NUM_CARRY4; carry_index = carry_index + 1) begin : gen_carry
      if (carry_index == 0) begin : gen_first
        (* DONT_TOUCH = "TRUE" *)
        CARRY4 i_carry4 (
          .CO    (carry_taps[3:0]),
          .O     (),
          .CI    (1'b0),
          .CYINIT(event_i),
          .DI    (4'b0000),
          .S     (4'b1111)
        );
      end else begin : gen_next
        (* DONT_TOUCH = "TRUE" *)
        CARRY4 i_carry4 (
          .CO    (carry_taps[carry_index*4 +: 4]),
          .O     (),
          .CI    (carry_taps[carry_index*4-1]),
          .CYINIT(1'b0),
          .DI    (4'b0000),
          .S     (4'b1111)
        );
      end
    end
  endgenerate

  genvar tap_index;
  generate
    for (tap_index = 0; tap_index < NUM_TAPS; tap_index = tap_index + 1) begin : gen_tap
      (* DONT_TOUCH = "TRUE" *)
      FDRE #(
        .INIT(1'b0)
      ) i_tap_ff (
        .Q (sampled_taps_raw[tap_index]),
        .C (clk_i),
        .CE(1'b1),
        .R (~rstn_i),
        .D (carry_taps[tap_index])
      );
    end
  endgenerate

  assign sampled_taps_o = INVERT_TAPS ? ~sampled_taps_raw : sampled_taps_raw;

endmodule: tdc_carry_chain

