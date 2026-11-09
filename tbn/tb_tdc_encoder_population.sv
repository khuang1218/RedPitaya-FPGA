`timescale 1ns/1ps
// Independent whole-vector reference for WIDTH population encoding, including
// the V16 span pipeline and 32-lane tree. No timing or physical-jitter model.
module tb_tdc_encoder_population #(parameter integer TAPS=16);
  localparam integer IW=$clog2(TAPS);
  reg clk=0,rstn=0,start=0;
  reg [TAPS-1:0] raw=0;
  always #2 clk=~clk;
  wire done;
  wire [IW-1:0] index_value;
  wire [7:0] status;
  tdc_thermometer_encoder #(.NUM_TAPS(TAPS),.INDEX_W(IW),
    .TAPS_PER_CYCLE(32),.MAX_TRANSITION_SPAN(8)) dut (
    .clk_i(clk),.rstn_i(rstn),.start_i(start),.raw_taps_i(raw),
    .busy_o(),.done_o(done),.fine_index_o(index_value),.status_o(status));
  integer checked=0;
  task automatic check(input reg [TAPS-1:0] sample);
    reg left_bit,right_bit,filtered,zero_seen,multiple,bubble,allowed;
    reg [7:0] expected;
    integer leading,last_end,population,cycles;
    begin
      leading=0;last_end=0;population=0;zero_seen=0;multiple=0;bubble=0;
      for(integer i=0;i<TAPS;i=i+1) begin
        left_bit=sample[(i==0) ? 0 : i-1];
        right_bit=sample[(i==TAPS-1) ? i : i+1];
        filtered=(left_bit&sample[i])|(left_bit&right_bit)|(sample[i]&right_bit);
        population=population+int'(sample[i]);
        if(filtered!=sample[i]) bubble=1;
        if(!filtered) zero_seen=1;
        else begin
          last_end=i+1;
          if(zero_seen) multiple=1; else leading=leading+1;
        end
      end
      allowed=(last_end-leading>=0 && last_end-leading<=8);
      expected=0;
      if(sample=='0) expected=expected|8'h0a;
      if(&sample) expected=expected|8'h12;
      if(multiple && !allowed) expected=expected|8'h04;
      if(bubble || (multiple && allowed)) expected=expected|8'h20;
      if(sample!='0 && !(&sample) && (!multiple || allowed)) expected=expected|8'h01;
      @(negedge clk);raw=sample;start=1;
      @(negedge clk);start=0;cycles=0;
      while(!done) begin
        @(negedge clk);cycles=cycles+1;
        if(cycles>(TAPS+31)/32+4) $fatal(1,"Population encoder throughput regression");
      end
      if(index_value!==IW'((population>=TAPS) ? TAPS-1 : population) || status!==expected)
        $fatal(1,"Population mismatch taps=%d raw=%h index=%d expected=%d status=%h/%h",TAPS,sample,index_value,population,status,expected);
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
        // Shift a two-tap island across chunk boundaries and the 8-tap
        // acceptance limit. Keep out-of-range bits out of the reference.
        for(integer span=7;span<=10;span=span+1) begin
          if(edge_index+span<TAPS && edge_index>1) begin
            sample[edge_index-1]=0;sample[edge_index-2]=0;
            sample[edge_index+span-1]=1;sample[edge_index+span]=1;
            check(sample);
            sample[edge_index-1]=1;sample[edge_index-2]=1;
            sample[edge_index+span-1]=0;sample[edge_index+span]=0;
          end
        end
      end
      for(integer pattern=0;pattern<256;pattern=pattern+1) begin
        for(integer i=0;i<TAPS;i=i+1) sample[i]=1'($urandom);
        check(sample);
      end
    end
    $display("tb_tdc_encoder_population: PASS (%0d taps, %0d patterns, 32 lanes, independent majority/population/span reference)",TAPS,checked);
    $finish;
  end
  initial begin #100000000;$fatal(1,"Watchdog");end
endmodule
