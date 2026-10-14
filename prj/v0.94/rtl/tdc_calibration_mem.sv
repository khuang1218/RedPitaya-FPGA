////////////////////////////////////////////////////////////////////////////////
// Double-buffered tap-to-time LUT and code-density histogram memory.
////////////////////////////////////////////////////////////////////////////////

module tdc_calibration_mem #(
  parameter int unsigned NUM_TAPS = 512,
  parameter int unsigned INDEX_W  = $clog2(NUM_TAPS)
)(
  input  logic                 clk_i,
  input  logic                 rstn_i,

  input  logic [INDEX_W-1:0]   lookup_addr_i,
  output logic [15:0]          lookup_data_o,

  input  logic [INDEX_W-1:0]   sw_addr_i,
  input  logic [15:0]          sw_write_data_i,
  input  logic                 sw_write_i,
  output logic [15:0]          sw_read_data_o,
  input  logic                 invalidate_inactive_i,
  input  logic                 activate_i,
  output logic                 active_bank_o,
  output logic                 inactive_bank_ready_o,

  input  logic                 histogram_clear_i,
  input  logic                 histogram_increment_i,
  input  logic [INDEX_W-1:0]   histogram_index_i,
  output logic [31:0]          histogram_data_o,
  output logic                 histogram_clear_busy_o
);

  // Asynchronous lookup/indexed debug reads keep the controller and sys_bus
  // interfaces simple and deterministic.  Request distributed RAM explicitly;
  // the result FIFO remains the BRAM-backed bulk storage in this first build.
  (* RAM_STYLE = "DISTRIBUTED" *) logic [15:0] lut_bank0 [0:NUM_TAPS-1];
  (* RAM_STYLE = "DISTRIBUTED" *) logic [15:0] lut_bank1 [0:NUM_TAPS-1];
  (* RAM_STYLE = "DISTRIBUTED" *) logic [31:0] histogram [0:NUM_TAPS-1];

  logic [INDEX_W-1:0] clear_index;
  logic [NUM_TAPS-1:0] inactive_bank_written;

  assign inactive_bank_ready_o = &inactive_bank_written;

  always_comb begin
    lookup_data_o  = active_bank_o ? lut_bank1[lookup_addr_i] : lut_bank0[lookup_addr_i];
    sw_read_data_o = active_bank_o ? lut_bank0[sw_addr_i] : lut_bank1[sw_addr_i];
    histogram_data_o = histogram[sw_addr_i];
  end

  always_ff @(posedge clk_i) begin
    if (!rstn_i) begin
      active_bank_o          <= 1'b0;
      inactive_bank_written  <= '0;
      histogram_clear_busy_o <= 1'b0;
      clear_index            <= '0;
    end else begin
      if (invalidate_inactive_i)
        inactive_bank_written <= '0;

      if (activate_i)
        if (inactive_bank_ready_o) begin
          active_bank_o         <= ~active_bank_o;
          inactive_bank_written <= '0;
        end

      if (sw_write_i && !invalidate_inactive_i) begin
        if (active_bank_o)
          lut_bank0[sw_addr_i] <= sw_write_data_i;
        else
          lut_bank1[sw_addr_i] <= sw_write_data_i;
        inactive_bank_written[sw_addr_i] <= 1'b1;
      end

      if (histogram_clear_i && !histogram_clear_busy_o) begin
        histogram_clear_busy_o <= 1'b1;
        clear_index <= '0;
      end else if (histogram_clear_busy_o) begin
        histogram[clear_index] <= 32'd0;
        if (clear_index == NUM_TAPS-1) begin
          histogram_clear_busy_o <= 1'b0;
          clear_index <= '0;
        end else begin
          clear_index <= clear_index + 1'b1;
        end
      end else if (histogram_increment_i) begin
        histogram[histogram_index_i] <= histogram[histogram_index_i] + 1'b1;
      end
    end
  end

endmodule: tdc_calibration_mem
