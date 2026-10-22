`timescale 1ns/1ps
// Delay each launch marker by a fixed integer number of fast clocks. The
// caller supplies offset-2 and the zero/one decodes from an idle-only mailbox.
// marker_o occupies the original second marker-register stage at offset=0.
// No combinational timer/compare path enters the acquisition controller.
(* KEEP_HIERARCHY="TRUE" *)
module tdc_frame_delay (
  input logic clk_i, rstn_i, enable_i, clear_i,
  input logic marker_i,
  input logic offset_zero_i, offset_one_i,
  input logic [15:0] match_i,
  output logic marker_o,
  output logic overrun_o
);
  logic pending;
  logic [15:0] count;
  logic carry8;
  (* DONT_TOUCH="TRUE" *) logic [1:0] match_q;
  always_ff @(posedge clk_i) begin
    if (!rstn_i || clear_i || !enable_i) begin
      marker_o<=0; overrun_o<=0; pending<=0;
      count<=0; carry8<=0; match_q<=0;
    end else begin
      marker_o<=0;
      if (marker_i) begin
        // Valid configuration requires offset < period: no two markers can
        // share this timer. Fail explicitly if the launch cadence changes.
        if (pending) overrun_o<=1;
        marker_o<=offset_zero_i;
        pending<=!offset_zero_i;
        count<=0; carry8<=0;
        match_q<={2{offset_one_i}};
      end else if (pending) begin
        if (&match_q) begin
          marker_o<=1; pending<=0;
        end else begin
          count[7:0]<=count[7:0]+1'b1;
          count[15:8]<=count[15:8]+carry8;
          carry8<=count[7:0]==8'hfe;
          match_q[0]<=count[7:0]==match_i[7:0];
          match_q[1]<=count[15:8]==match_i[15:8];
        end
      end
    end
  end
endmodule
