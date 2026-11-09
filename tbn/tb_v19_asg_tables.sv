`timescale 1ns/1ps
// Uses the real v19 ASG register and waveform-memory logic. The inactive DDR
// reader is replaced in the simulation driver; local-table playback is retained.
module tb_v19_asg_tables;
  reg clk=0,rstn=0,wen=0,ren=0;
  always #4 clk=~clk;
  reg [31:0] addr=0,wdata=0;
  wire [31:0] rdata;
  wire [13:0] a,b;
  wire ack,err,trig;
  red_pitaya_asg_v19 dut(.dac_a_o(a),.dac_b_o(b),.dac_clk_i(clk),.dac_rstn_i(rstn),
    .trig_a_i(1'b0),.trig_b_i(1'b0),.trig_out_o(trig),
    .sys_addr(addr),.sys_wdata(wdata),.sys_wen(wen),.sys_ren(ren),
    .sys_rdata(rdata),.sys_err(err),.sys_ack(ack));
  task automatic write_word(input [31:0] address,input [31:0] value);
    @(negedge clk);addr=address;wdata=value;wen=1;
    repeat(5) @(negedge clk);
    if(!ack || err) $fatal(1,"ASG write response %h",address);
    wen=0;repeat(4) @(negedge clk);
  endtask
  task automatic check_word(input [31:0] address,input [31:0] expected);
    @(negedge clk);addr=address;ren=1;
    repeat(8) @(negedge clk);
    if(!ack || err || rdata!==expected) $fatal(1,"ASG %h got %h expected %h",address,rdata,expected);
    ren=0;repeat(4) @(negedge clk);
  endtask
  integer i,index;
  initial begin
    repeat(5) @(negedge clk);rstn=1;repeat(5) @(negedge clk);
    for(i=0;i<12;i=i+1) begin
      case(i) 0:index=0;1:index=1;2:index=8191;3:index=8192;4:index=16382;5:index=16383;
              default:index=100+i;endcase
      write_word(32'h40210000+4*index,14'h0100+i);
      write_word(32'h40220000+4*index,14'h2100+i);
    end
    for(i=0;i<12;i=i+1) begin
      case(i) 0:index=0;1:index=1;2:index=8191;3:index=8192;4:index=16382;5:index=16383;
              default:index=100+i;endcase
      check_word(32'h40210000+4*index,14'h0100+i);
      check_word(32'h40220000+4*index,14'h2100+i);
    end
    write_word(32'h40210000,14'h1357);
    check_word(32'h40210000,14'h1357);check_word(32'h40220000,14'h2100);
    write_word(32'h40220000+4*16383,14'h2468);
    check_word(32'h40210000+4*16383,14'h0105);check_word(32'h40220000+4*16383,14'h2468);
    // Verify separate amplitude/DC configuration remains independently writable.
    write_word(32'h40200004,32'h01231000);write_word(32'h40200024,32'h03212000);
    check_word(32'h40200004,32'h01231000);check_word(32'h40200024,32'h03212000);
    $display("PASS v19 ASG: independent A/B tables, low/high/boundary addresses, overwrite isolation and configuration");
    $finish;
  end
  initial begin #100000;$fatal(1,"ASG timeout");end
endmodule
