`timescale 1ns/1ps
module tb_tdc_top;
  reg clk=0,test_clk=0,rstn=0,wen=0,ren=0;
  always #4 clk=~clk;
  always #3 test_clk=~test_clk;
  reg [31:0] addr=0,wdata=0;
  wire [31:0] rdata;
  wire ack,err,launch_p,launch_n;
  reg return_p=0,respond=1,hold_return=0;
  reg return_single=0,respond_single=0;
  integer launches=0;
  tdc_top #(.NUM_CARRY4(4)) dut(
    .clk_i(clk),.rstn_i(rstn),.test_clk_i(test_clk),.test_rstn_i(rstn),
    .launch_p_o(launch_p),.launch_n_o(launch_n),
    .return_p_i(return_p),.return_n_i(~return_p),
    .return_single_i(return_single),
    .sys_addr_i(addr),.sys_wdata_i(wdata),.sys_wen_i(wen),.sys_ren_i(ren),
    .sys_rdata_o(rdata),.sys_ack_o(ack),.sys_err_o(err)
  );
  always @(posedge launch_p) if(rstn) begin
    launches=launches+1;
    if(respond) begin
      #13;
      if(respond_single) return_single=1; else return_p=1;
      #50; if(!hold_return) begin return_p=0; return_single=0; end
    end
  end
  task automatic wr(input [15:0] offset,input [31:0] value);
    @(negedge clk); addr={16'h4071,offset}; wdata=value; wen=1;
    @(posedge clk); #0.01;
    if(!ack || err) $fatal(1,"Write failed at %h",offset);
    @(negedge clk); wen=0;
    @(negedge clk);
  endtask
  task automatic reject_input(input [31:0] value);
    @(negedge clk); addr=32'h40710090; wdata=value; wen=1;
    @(posedge clk); #0.01;
    if(!ack || !err) $fatal(1,"Unsafe/invalid input write accepted");
    @(negedge clk); wen=0;
    @(negedge clk);
  endtask
  task automatic rd(input [15:0] offset,output [31:0] value);
    @(negedge clk); addr={16'h4071,offset}; ren=1;
    @(posedge clk); #0.01;
    if(!ack || err) $fatal(1,"Read failed at %h",offset);
    value=rdata;
    @(negedge clk); ren=0;
  endtask
  task automatic get_record(input bit timeout_expected,input integer sequence_expected);
    reg [31:0] level,a,b,c,d,coarse,fine,total_lo,total_hi;
    reg [127:0] record_value;
    integer attempts;
    begin
      level=0; attempts=0;
      while(level==0 && attempts<300) begin rd(16'h38,level); attempts=attempts+1; end
      if(level!=1) $fatal(1,"Expected one queued result, level=%0d state=%0d enable=%b pending=%b launches=%0d taps=%h return=%b",level,dut.state,dut.enable,dut.trigger_pending,launches,dut.sampled_taps,return_p);
      wr(16'h4c,1);
      rd(16'h3c,a); rd(16'h40,b); rd(16'h44,c); rd(16'h48,d);
      record_value={d,c,b,a};
      if(record_value[15:0]!=sequence_expected || record_value[22]!=timeout_expected)
        $fatal(1,"Sequence/timeout mismatch: %h",record_value);
      if(!timeout_expected) begin
        if(!record_value[16] || record_value[65:56]!=8 || record_value[81:66]!=4001)
          $fatal(1,"Valid/fine fields or FIFO packing mismatch: %h",record_value);
      end
      rd(16'h20,coarse); rd(16'h28,fine); rd(16'h2c,total_lo); rd(16'h30,total_hi);
      if(record_value[55:24]!=coarse || record_value[81:66]!=fine ||
         record_value[127:82]!={total_hi[13:0],total_lo})
        $fatal(1,"FIFO and last-result registers differ");
      if(!timeout_expected && {total_hi[13:0],total_lo} != 64'(coarse)*8002-4001)
        $fatal(1,"Coarse/fine arithmetic mismatch");
    end
  endtask
  reg [31:0] value;
  integer previous_launches;
  initial begin
    // Exercise an input transition after the UNISIM buffer initializes.
    #1; return_p=1; #1; return_p=0;
    #118; rstn=1; repeat(8) @(negedge clk);
    rd(0,value); if(value!==32'h54444304) $fatal(1,"ID mismatch");
    rd(16'h90,value); if(value!=0) $fatal(1,"Default source is not LVDS");
    reject_input(2);
    rd(16'h18,value); if(value!=16) $fatal(1,"Tap count mismatch");
    wr(16'h1c,8002); // Odd fine value exposes the former 127-bit FIFO bug.
    wr(16'h14,20); wr(16'h04,1); wr(16'h04,3);
    get_record(0,1);
    repeat(10) @(negedge clk);
    respond=0; wr(16'h04,3); get_record(1,2);
    repeat(10) @(negedge clk);
    // A one-shot request while return is HIGH must be retained until LOW.
    return_p=1; repeat(5) @(negedge clk);
    previous_launches=launches; wr(16'h04,3);
    repeat(8) @(negedge clk);
    if(launches!=previous_launches) $fatal(1,"Armed with return stuck HIGH");
    respond=1; return_p=0; get_record(0,3);
    repeat(10) @(negedge clk);
    // After a valid capture, re-arm must again wait for the return to fall.
    hold_return=1; wr(16'h04,3); get_record(0,4);
    previous_launches=launches; wr(16'h04,3);
    repeat(8) @(negedge clk);
    if(launches!=previous_launches) $fatal(1,"Repeated launch while return HIGH");
    hold_return=0; return_p=0; get_record(0,5);
    wr(16'h04,0);
    repeat(10) @(negedge clk);
    // Changing input discards an old queued result and disables its LUT.
    wr(16'h04,1); wr(16'h04,3);
    value=0;
    while(value==0) rd(16'h38,value);
    wr(16'h04,32'h80);
    repeat(10) @(negedge clk);
    wr(16'h90,1);
    rd(16'h90,value); if(value!=1) $fatal(1,"SINGLE selection failed");
    rd(16'h38,value); if(value!=0) $fatal(1,"Source change kept old FIFO");
    rd(16'h04,value); if(value[7]) $fatal(1,"Source change kept LUT enabled");
    rd(16'h64,value); if(value!=0) $fatal(1,"Source change kept old event count");
    // Soft reset must retain the user's external input choice.
    wr(16'h04,8);
    rd(16'h90,value); if(value!=1) $fatal(1,"Soft reset lost SINGLE selection");
    // An idle but enabled core must still reject source changes.
    wr(16'h04,1); reject_input(0);
    rd(16'h90,value); if(value!=1) $fatal(1,"Enabled write changed source");
    // LVDS activity cannot satisfy an acquisition through SINGLE.
    respond_single=0; wr(16'h04,3); get_record(1,1);
    repeat(10) @(negedge clk);
    // SINGLE must work with the inactive LVDS input stuck HIGH.
    return_p=1; respond_single=1; wr(16'h04,3); get_record(0,2);
    repeat(10) @(negedge clk);
    // Even after ENABLE OFF, an outstanding measurement cannot change source.
    respond=0; wr(16'h14,100); wr(16'h04,3); wr(16'h04,0);
    reject_input(0); get_record(1,3);
    repeat(10) @(negedge clk);
    wr(16'h90,0); return_p=0;
    rd(16'h90,value); if(value!=0) $fatal(1,"LVDS reselection failed");
    // Single-ended activity must likewise be ignored when LVDS is selected.
    respond=1; wr(16'h14,20); wr(16'h04,1); wr(16'h04,3); get_record(1,1);
    repeat(10) @(negedge clk);
    return_single=1; respond_single=0;
    wr(16'h04,3); get_record(0,2);
    wr(16'h04,0);
    $display("tb_tdc_top: PASS (LVDS/SINGLE isolation, idle guards, reset/FIFO/LUT; ideal taps)"); $finish;
  end
  initial begin #50000; $fatal(1,"Watchdog"); end
endmodule
