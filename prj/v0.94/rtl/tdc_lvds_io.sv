////////////////////////////////////////////////////////////////////////////////
// Dedicated LVDS I/O for the E3 TDC link.
////////////////////////////////////////////////////////////////////////////////

(* KEEP_HIERARCHY = "TRUE" *)
module tdc_lvds_io #(
  parameter bit RETURN_DIFF_TERM = 1'b0
)(
  input  logic launch_i,
  output logic launch_p_o,
  output logic launch_n_o,
  input  logic return_p_i,
  input  logic return_n_i,
  output logic return_event_o
);

  OBUFDS #(
    .IOSTANDARD("LVDS_25"),
    .SLEW("FAST")
  ) i_launch_obufds (
    .I (launch_i),
    .O (launch_p_o),
    .OB(launch_n_o)
  );

  generate
    if (RETURN_DIFF_TERM) begin : gen_internal_termination
      IBUFDS #(
        .DIFF_TERM("TRUE"),
        .IBUF_LOW_PWR("FALSE"),
        .IOSTANDARD("LVDS_25")
      ) i_return_ibufds (
        .I (return_p_i),
        .IB(return_n_i),
        .O (return_event_o)
      );
    end else begin : gen_external_termination
      IBUFDS #(
        .DIFF_TERM("FALSE"),
        .IBUF_LOW_PWR("FALSE"),
        .IOSTANDARD("LVDS_25")
      ) i_return_ibufds (
        .I (return_p_i),
        .IB(return_n_i),
        .O (return_event_o)
      );
    end
  endgenerate

endmodule: tdc_lvds_io
