`timescale 1ns/1ps
module tb_asg_pointer_add #(parameter integer WIDTH=63,GROUP=8);
  reg [WIDTH-1:0] a=0,b=0;
  wire [WIDTH-1:0] sum;
  rp_asg_pointer_add #(.WIDTH(WIDTH),.GROUP(GROUP)) dut(.a_i(a),.b_i(b),.sum_o(sum));
  integer checked=0;
  task automatic check(input reg [WIDTH-1:0] av,bv);
    a=av;b=bv;#1;
    if(sum!==WIDTH'(av+bv)) $fatal(1,"ASG add mismatch WIDTH=%d GROUP=%d a=%h b=%h got=%h",WIDTH,GROUP,a,b,sum);
    checked=checked+1;
  endtask
  initial begin
    check(0,0);check('1,1);check('1,'1);
    for(integer bit_index=0;bit_index<WIDTH;bit_index=bit_index+1) begin
      check(WIDTH'(1)<<bit_index,(WIDTH'(1)<<bit_index)-1'b1);
      check((WIDTH'(1)<<bit_index)-1'b1,1);
    end
    if(WIDTH==8) begin
      for(integer av=0;av<256;av=av+1)
        for(integer bv=0;bv<256;bv=bv+1) check(WIDTH'(av),WIDTH'(bv));
    end else begin
      for(integer i=0;i<50000;i=i+1)
        check({$urandom,$urandom,$urandom},{$urandom,$urandom,$urandom});
    end
    $display("tb_asg_pointer_add: PASS (WIDTH=%0d GROUP=%0d %0d cases)",WIDTH,GROUP,checked);
    $finish;
  end
endmodule
