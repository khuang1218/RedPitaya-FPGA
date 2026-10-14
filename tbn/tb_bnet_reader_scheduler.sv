`timescale 1ns/1ps
// Exercises the real reader control logic with a delayed AXI wrapper and an
// empty FIFO model. The runner only adapts the interface port for Icarus.
module tb_bnet_reader_scheduler;
  reg cfg_clk=0, axi_clk=0, rstn=0, start=0, soft_reset=0, enable=1;
  always #4 cfg_clk=~cfg_clk;
  initial begin #0.7; forever #2 axi_clk=~axi_clk; end
  reg [31:0] length=0;
  wire [31:0] debug0,debug1;
  bnet_axi_reader_ch dut (
    .cfg_clk_i(cfg_clk),.cfg_rstn_i(rstn),.axi_clk(axi_clk),.axi_rstn(rstn),
    .soft_reset_i(soft_reset),.start_i(start),.enable_i(enable),
    .active_buf_i(1'b0),.base0_i(32'h10000000),.base1_i(32'h20000000),
    .length_bytes_i(length),.stride_bytes_i(32'd2),.consume_i(1'b0),
    .sample_o(),.valid_o(),.ready_o(),.read_ptr_o(),.underrun_o(),
    .debug0_o(debug0),.debug1_o(debug1)
  );
  integer issued=0, total=0, expected_bytes=0, expected_beats=0;
  always @(posedge axi_clk) if (rstn && dut.ctrl_val) begin
    expected_beats=(length-total+7)/8;
    if(expected_beats>16) expected_beats=16;
    if(expected_beats<=0) $fatal(1,"Extra burst after end");
    if(dut.ctrl_addr!==32'h10000000+total || dut.ctrl_size!==expected_beats-1)
      $fatal(1,"Burst %0d: addr=%h size=%0d expected addr=%h size=%0d",
             issued,dut.ctrl_addr,dut.ctrl_size,32'h10000000+total,expected_beats-1);
    total=total+expected_beats*8;
    issued=issued+1;
  end
  task automatic run_length(input integer bytes);
    integer cycles;
    begin
      @(negedge cfg_clk); length=bytes; issued=0; total=0; start=1;
      @(negedge cfg_clk); start=0;
      cycles=0;
      while((total<bytes || dut.ctrl_req_inflight_axi || issued==0) && cycles<30000) begin
        @(negedge axi_clk); cycles=cycles+1;
      end
      if(cycles==30000) $fatal(1,"Scheduler stalled at length %0d",bytes);
      repeat(30) @(negedge cfg_clk);
      expected_bytes=((bytes+7)/8)*8;
      if(total!=expected_bytes || debug1!==expected_bytes)
        $fatal(1,"Count/snapshot mismatch at length %0d: issued=%0d snapshot=%0d",bytes,total,debug1);
    end
  endtask
  initial begin
    #19; rstn=1;
    repeat(8) @(negedge cfg_clk);
    run_length(1); run_length(7); run_length(8); run_length(9);
    run_length(127); run_length(128); run_length(129); run_length(256);
    force dut.fifo_full=1'b1;
    fork
      begin
        repeat(12) @(negedge cfg_clk);
        if(issued!=0) $fatal(1,"Issued a request while FIFO was full");
        release dut.fifo_full;
      end
      begin run_length(257); end
    join
    run_length(8192); run_length(45056); run_length(98304);
    // A disabled START must not leave a stale burst plan armed.
    @(negedge cfg_clk); enable=0; total=0; issued=0; start=1;
    @(negedge cfg_clk); start=0;
    repeat(30) @(negedge cfg_clk);
    if(issued!=0 || dut.plan_valid_axi) $fatal(1,"Disabled start issued a burst");
    enable=1; run_length(129);
    // Reader reset must clear the planned request and the byte counter.
    @(negedge cfg_clk); soft_reset=1;
    @(negedge cfg_clk); soft_reset=0;
    repeat(30) @(negedge cfg_clk);
    if(dut.running_axi || dut.plan_valid_axi || debug1!==0) $fatal(1,"Soft reset left reader active");
    $display("tb_bnet_reader_scheduler: PASS"); $finish;
  end
  initial begin #1000000; $fatal(1,"Watchdog"); end
endmodule

// Protocol model: ctrl_busy deliberately arrives two cycles after ctrl_val.
module axi_rd_burst #(parameter DW=64,AW=32,LW=4)(
  input axi_clk,axi_rstn,cfg_clk_i,cfg_rstn_i,
  input [AW-1:0] ctrl_addr_i,input [LW-1:0] ctrl_size_i,
  input [2:0] ctrl_rsize_i,input ctrl_val_i,rd_drdy_i,
  output [DW-1:0] rd_data_o,output [AW-1:0] rd_addr_o,
  output rd_dval_o,output [31:0] diags_o,
  output reg ctrl_busy_o=0,output stat_busy_o
);
  integer delay_count=0,busy_count=0;
  assign rd_data_o=0; assign rd_addr_o=0; assign rd_dval_o=0;
  assign diags_o=0; assign stat_busy_o=ctrl_busy_o;
  always @(posedge axi_clk) begin
    if(!axi_rstn) begin delay_count<=0; busy_count<=0; ctrl_busy_o<=0; end
    else if(ctrl_val_i) begin
      if(delay_count!=0 || busy_count!=0) $fatal(1,"Overlapping AXI requests");
      delay_count<=2;
    end else if(delay_count!=0) begin
      delay_count<=delay_count-1;
      if(delay_count==1) begin ctrl_busy_o<=1; busy_count<=5; end
    end else if(busy_count!=0) begin
      busy_count<=busy_count-1;
      if(busy_count==1) ctrl_busy_o<=0;
    end
  end
endmodule
module asg_dat_fifo(input wr_clk,rd_clk,rst,input [95:0] din,input wr_en,rd_en,
  output full,empty,wr_rst_busy,rd_rst_busy,output [95:0] dout,output [8:0] rd_data_count);
  assign full=0; assign empty=1; assign wr_rst_busy=0; assign rd_rst_busy=0;
  assign dout=0; assign rd_data_count=0;
endmodule
