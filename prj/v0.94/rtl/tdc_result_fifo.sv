////////////////////////////////////////////////////////////////////////////////
// Small inferred-BRAM result FIFO with pop-to-snapshot semantics.
////////////////////////////////////////////////////////////////////////////////

module tdc_result_fifo #(
  parameter int unsigned DATA_W = 128,
  parameter int unsigned DEPTH  = 256,
  parameter int unsigned ADDR_W = $clog2(DEPTH)
)(
  input  logic               clk_i,
  input  logic               rstn_i,
  input  logic               clear_i,
  input  logic               push_i,
  input  logic [DATA_W-1:0]  push_data_i,
  input  logic               pop_i,
  output logic [DATA_W-1:0]  snapshot_o,
  output logic [ADDR_W:0]    level_o,
  output logic               full_o,
  output logic               empty_o,
  output logic               overflow_o,
  output logic               underflow_o
);

  (* RAM_STYLE = "BLOCK" *) logic [DATA_W-1:0] memory [0:DEPTH-1];
  logic [ADDR_W-1:0] write_ptr;
  logic [ADDR_W-1:0] read_ptr;
  logic push_accept;
  logic pop_accept;

  assign full_o  = (level_o == DEPTH);
  assign empty_o = (level_o == 0);
  assign push_accept = push_i && !full_o;
  assign pop_accept  = pop_i && !empty_o;

  always_ff @(posedge clk_i) begin
    if (!rstn_i || clear_i) begin
      write_ptr   <= '0;
      read_ptr    <= '0;
      level_o     <= '0;
      snapshot_o  <= '0;
      overflow_o  <= 1'b0;
      underflow_o <= 1'b0;
    end else begin
      overflow_o  <= push_i && full_o;
      underflow_o <= pop_i && empty_o;

      if (push_accept) begin
        memory[write_ptr] <= push_data_i;
        write_ptr <= write_ptr + 1'b1;
      end

      if (pop_accept) begin
        snapshot_o <= memory[read_ptr];
        read_ptr <= read_ptr + 1'b1;
      end

      case ({push_accept, pop_accept})
        2'b10: level_o <= level_o + 1'b1;
        2'b01: level_o <= level_o - 1'b1;
        default: level_o <= level_o;
      endcase
    end
  end

endmodule: tdc_result_fifo

