////////////////////////////////////////////////////////////////////////////////
// BNET DDR-to-sample AXI reader channel.
//
// This is the first BNET-owned DDR reader. It reads one ping-pong-selected DDR
// buffer through an existing Red Pitaya axi_sys_if HP-port wrapper, transfers
// 64-bit AXI beats through the existing async FIFO IP, then emits one signed
// 14-bit sample per valid output cycle in the BNET/ADC clock domain.
////////////////////////////////////////////////////////////////////////////////

module bnet_axi_reader_ch #(
  parameter int unsigned SAMPLE_DW = 14,
  parameter int unsigned AXI_DW = 64,
  parameter int unsigned AXI_BURST_LEN = 16
)(
  input  logic                         cfg_clk_i,
  input  logic                         cfg_rstn_i,
  input  logic                         start_i,

  input  logic                         enable_i,
  input  logic                         active_buf_i,
  input  logic [32-1:0]                base0_i,
  input  logic [32-1:0]                base1_i,
  input  logic [32-1:0]                length_bytes_i,
  input  logic [32-1:0]                stride_bytes_i,
  input  logic                         consume_i,

  axi_sys_if.s                         axi_sys,

  output logic signed [SAMPLE_DW-1:0]  sample_o,
  output logic                         valid_o,
  output logic                         ready_o,
  output logic [32-1:0]                read_ptr_o,
  output logic                         underrun_o
);

  localparam int unsigned AXI_BYTE_W = AXI_DW / 8;
  localparam int unsigned SAMPLES_PER_BEAT = AXI_DW / 16;
  localparam int unsigned LANE_W = (SAMPLES_PER_BEAT <= 1) ? 1 : $clog2(SAMPLES_PER_BEAT);
  localparam logic [5-1:0] AXI_BURST_BEATS = AXI_BURST_LEN;

  logic start_cfg_d;
  logic start_toggle_cfg;
  logic start_toggle_axi_meta;
  logic start_toggle_axi;
  logic start_toggle_axi_d;
  logic start_axi_pulse;

  logic [32-1:0] length_bytes_axi;
  logic [32-1:0] rd_addr_axi;
  logic [32-1:0] bytes_requested_axi;
  logic          running_axi;

  logic [32-1:0] remaining_bytes_axi;
  logic [32-1:0] next_burst_bytes_axi;
  logic [5-1:0]  next_burst_beats_axi;
  logic          can_request_axi;

  logic [32-1:0] ctrl_addr;
  logic [4-1:0]  ctrl_size;
  logic [3-1:0]  ctrl_rsize;
  logic          ctrl_val;
  logic          ctrl_busy;

  logic [AXI_DW-1:0] rd_data;
  logic [32-1:0]     rd_addr;
  logic              rd_dval;

  logic [96-1:0] fifo_din;
  logic [96-1:0] fifo_dout;
  logic          fifo_wr;
  logic          fifo_full;
  logic          fifo_empty;
  logic          fifo_rd;
  logic          fifo_rst_cfg;
  logic          fifo_rst_axi;

  logic          fifo_rd_pending;
  logic [AXI_DW-1:0] word_data;
  logic          word_valid;
  logic [LANE_W-1:0] lane_index;

  assign ready_o = !fifo_empty || word_valid;
  assign underrun_o = consume_i && !word_valid;
  assign ctrl_rsize = 3'h3;
  assign fifo_wr = rd_dval;
  assign fifo_din = {rd_addr, rd_data};
  assign fifo_rst_cfg = !cfg_rstn_i || start_i;

  always_ff @(posedge cfg_clk_i) begin
    if (!cfg_rstn_i) begin
      start_cfg_d <= 1'b0;
      start_toggle_cfg <= 1'b0;
    end else begin
      start_cfg_d <= start_i;
      if (start_i && !start_cfg_d) begin
        start_toggle_cfg <= ~start_toggle_cfg;
      end
    end
  end

  always_ff @(posedge axi_sys.clk) begin
    if (!axi_sys.rstn) begin
      start_toggle_axi_meta <= 1'b0;
      start_toggle_axi <= 1'b0;
      start_toggle_axi_d <= 1'b0;
    end else begin
      start_toggle_axi_meta <= start_toggle_cfg;
      start_toggle_axi <= start_toggle_axi_meta;
      start_toggle_axi_d <= start_toggle_axi;
    end
  end

  assign start_axi_pulse = start_toggle_axi ^ start_toggle_axi_d;
  assign fifo_rst_axi = !axi_sys.rstn || start_axi_pulse;

  always_comb begin
    remaining_bytes_axi = (bytes_requested_axi < length_bytes_axi) ?
                          (length_bytes_axi - bytes_requested_axi) :
                          32'd0;
    next_burst_beats_axi = AXI_BURST_BEATS;

    if (remaining_bytes_axi < (AXI_BURST_LEN * AXI_BYTE_W)) begin
      next_burst_beats_axi = {1'b0, remaining_bytes_axi[6:3]};
      if (remaining_bytes_axi[2:0] != 3'b000) begin
        next_burst_beats_axi = {1'b0, remaining_bytes_axi[6:3]} + 1'b1;
      end
    end

    next_burst_bytes_axi = {27'd0, next_burst_beats_axi} * AXI_BYTE_W;
    can_request_axi = running_axi &&
                      (remaining_bytes_axi != 32'd0) &&
                      (next_burst_beats_axi != 5'd0) &&
                      !ctrl_busy &&
                      !fifo_full &&
                      !ctrl_val;
  end

  always_ff @(posedge axi_sys.clk) begin
    if (!axi_sys.rstn) begin
      length_bytes_axi <= 32'd0;
      rd_addr_axi <= 32'd0;
      bytes_requested_axi <= 32'd0;
      running_axi <= 1'b0;
      ctrl_addr <= 32'd0;
      ctrl_size <= 4'd0;
      ctrl_val <= 1'b0;
    end else begin
      ctrl_val <= 1'b0;

      if (start_axi_pulse) begin
        length_bytes_axi <= length_bytes_i;
        rd_addr_axi <= active_buf_i ? base1_i : base0_i;
        bytes_requested_axi <= 32'd0;
        running_axi <= enable_i && (length_bytes_i != 32'd0);
      end else if (can_request_axi) begin
        ctrl_addr <= rd_addr_axi;
        ctrl_size <= next_burst_beats_axi[3:0] - 1'b1;
        ctrl_val <= 1'b1;
        rd_addr_axi <= rd_addr_axi + next_burst_bytes_axi;
        bytes_requested_axi <= bytes_requested_axi + next_burst_bytes_axi;

        if (next_burst_bytes_axi >= remaining_bytes_axi) begin
          running_axi <= 1'b0;
        end
      end
    end
  end

  always_ff @(posedge cfg_clk_i) begin
    if (!cfg_rstn_i) begin
      fifo_rd <= 1'b0;
      fifo_rd_pending <= 1'b0;
      word_data <= '0;
      word_valid <= 1'b0;
      lane_index <= '0;
      sample_o <= '0;
      valid_o <= 1'b0;
      read_ptr_o <= 32'd0;
    end else begin
      fifo_rd <= 1'b0;

      if (start_i) begin
        fifo_rd_pending <= 1'b0;
        word_valid <= 1'b0;
        lane_index <= '0;
        read_ptr_o <= 32'd0;
        valid_o <= 1'b0;
      end else begin
        if (!word_valid && !fifo_empty && !fifo_rd_pending) begin
          fifo_rd <= 1'b1;
          fifo_rd_pending <= 1'b1;
        end

        if (fifo_rd_pending) begin
          word_data <= fifo_dout[AXI_DW-1:0];
          word_valid <= 1'b1;
          lane_index <= '0;
          fifo_rd_pending <= 1'b0;
        end

        if (word_valid) begin
          valid_o <= 1'b1;
        end else begin
          valid_o <= 1'b0;
        end

        if (word_valid) begin
          sample_o <= word_data[(lane_index * 16) +: SAMPLE_DW];

          if (consume_i) begin
            read_ptr_o <= read_ptr_o + stride_bytes_i;

            if (lane_index == SAMPLES_PER_BEAT-1) begin
              word_valid <= 1'b0;
              lane_index <= '0;
            end else begin
              lane_index <= lane_index + 1'b1;
            end
          end
        end
      end
    end
  end

  asg_dat_fifo inst_bnet_dat_fifo (
    .wr_clk        (axi_sys.clk),
    .rd_clk        (cfg_clk_i),
    .rst           (fifo_rst_axi || fifo_rst_cfg),
    .din           (fifo_din),
    .wr_en         (fifo_wr),
    .full          (fifo_full),
    .dout          (fifo_dout),
    .rd_en         (fifo_rd),
    .rd_data_count (),
    .empty         (fifo_empty),
    .wr_rst_busy   (),
    .rd_rst_busy   ()
  );

  axi_rd_burst #(
    .DW (AXI_DW),
    .AW (32),
    .LW (4)
  ) i_axi_rd_burst (
    .axi_sys      (axi_sys),
    .cfg_clk_i    (cfg_clk_i),
    .cfg_rstn_i   (cfg_rstn_i),
    .ctrl_addr_i  (ctrl_addr),
    .ctrl_size_i  (ctrl_size),
    .ctrl_rsize_i (ctrl_rsize),
    .ctrl_val_i   (ctrl_val),
    .rd_data_o    (rd_data),
    .rd_addr_o    (rd_addr),
    .rd_dval_o    (rd_dval),
    .rd_drdy_i    (!fifo_full),
    .diags_o      (),
    .ctrl_busy_o  (ctrl_busy),
    .stat_busy_o  ()
  );

endmodule: bnet_axi_reader_ch
