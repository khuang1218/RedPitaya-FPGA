`timescale 1ns/1ps
// Compare the original one-tap mode and the width path's eight-tap mode
// against an independent whole-vector majority/prefix reference.
module tb_tdc_encoder_grouped #(parameter integer TAPS=16);
  localparam integer IW=$clog2(TAPS);
  reg clk=0,rstn=0,start=0;
  reg [TAPS-1:0] raw=0;
  always #2 clk=~clk;
  wire serial_done,group_done;
  wire [IW-1:0] serial_index,group_index;
  wire [7:0] serial_status,group_status;
  tdc_thermometer_encoder #(.NUM_TAPS(TAPS),.INDEX_W(IW)) i_serial (
    .clk_i(clk),.rstn_i(rstn),.start_i(start),.raw_taps_i(raw),
    .busy_o(),.done_o(serial_done),.fine_index_o(serial_index),.status_o(serial_status));
  tdc_thermometer_encoder #(.NUM_TAPS(TAPS),.INDEX_W(IW),.TAPS_PER_CYCLE(8)) i_group (
    .clk_i(clk),.rstn_i(rstn),.start_i(start),.raw_taps_i(raw),
    .busy_o(),.done_o(group_done),.fine_index_o(group_index),.status_o(group_status));
  integer checked=0;
  task automatic check(input reg [TAPS-1:0] sample);
    reg [TAPS-1:0] filtered;
    reg left_bit,right_bit,zero_seen,multiple,bubble,got_serial,got_group;
    reg [7:0] status;
    reg [IW-1:0] index_value;
    integer leading,cycles;
    begin
      leading=0;zero_seen=0;multiple=0;bubble=0;
      for(integer i=0;i<TAPS;i=i+1) begin
        left_bit=sample[(i==0) ? 0 : i-1];
        right_bit=sample[(i==TAPS-1) ? i : i+1];
        filtered[i]=(left_bit&sample[i])|(left_bit&right_bit)|(sample[i]&right_bit);
        if(filtered[i]!=sample[i]) bubble=1;
        if(!filtered[i]) zero_seen=1;
        else if(zero_seen) multiple=1;
        else leading=leading+1;
      end
      status=0;
      if(sample=='0) status=status|8'h0a;
      if(&sample) status=status|8'h12;
      if(multiple) status=status|8'h04;
      if(bubble) status=status|8'h20;
      if(sample!='0 && !(&sample) && !multiple) status=status|8'h01;
      index_value=IW'((leading>=TAPS) ? TAPS-1 : leading);
      @(negedge clk);raw=sample;start=1;
      @(negedge clk);start=0;
      got_serial=0;got_group=0;cycles=0;
      while(!got_serial || !got_group) begin
        @(negedge clk);cycles=cycles+1;
        if(group_done) begin
          if(group_index!==index_value || group_status!==status)
            $fatal(1,"Grouped mismatch taps=%d raw=%h index=%d/%d status=%h/%h",TAPS,sample,group_index,index_value,group_status,status);
          if(cycles>(TAPS+7)/8+2) $fatal(1,"Grouped encoder throughput regression");
          got_group=1;
        end
        if(serial_done) begin
          if(serial_index!==index_value || serial_status!==status)
            $fatal(1,"Legacy encoder mismatch taps=%d raw=%h",TAPS,sample);
          got_serial=1;
        end
        if(cycles>TAPS+4) $fatal(1,"Encoder timeout");
      end
      checked=checked+1;
    end
  endtask
  reg [TAPS-1:0] sample;
  initial begin
    repeat(4) @(negedge clk);rstn=1;
    if(TAPS==16) begin
      for(integer pattern=0;pattern<65536;pattern=pattern+1) check(TAPS'(pattern));
    end else begin
      for(integer edge_index=0;edge_index<=TAPS;edge_index=edge_index+1) begin
        sample='0;
        for(integer i=0;i<edge_index;i=i+1) sample[i]=1;
        check(sample);
      end
      for(integer pattern=0;pattern<256;pattern=pattern+1) begin
        for(integer i=0;i<TAPS;i=i+1) sample[i]=1'($urandom);
        check(sample);
      end
    end
    $display("tb_tdc_encoder_grouped: PASS (%d taps, %d patterns, 1/8-tap modes and independent reference)",TAPS,checked);
    $finish;
  end
  initial begin #100000000; $fatal(1,"Watchdog");end
endmodule
