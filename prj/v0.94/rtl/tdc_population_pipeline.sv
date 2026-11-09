`timescale 1ns/1ps
// WIDTH-only streaming population encoder. One registered binary-tree level
// per clock replaces the V16 32-lane combinational chunk/shift feedback path.
// A new snapshot may enter every clock; latency is $clog2(NUM_TAPS)+3 clocks.
// The raw population, three-tap majority validator, <=8 transition span and
// status ABI match the bounded-population iterative encoder exactly.
// No reset or global enable on the tree's data registers: only validity resets.
(* KEEP_HIERARCHY="TRUE" *)
module tdc_population_pipeline #(
  parameter int unsigned NUM_TAPS=512,
  parameter int unsigned INDEX_W=$clog2(NUM_TAPS),
  parameter int unsigned MAX_TRANSITION_SPAN=8
)(
  input logic clk_i,rstn_i,start_i,
  input logic [NUM_TAPS-1:0] raw_taps_i,
  output wire done_o,
  output logic [INDEX_W-1:0] fine_index_o,
  output logic [7:0] status_o
);
  localparam int LEVELS=$clog2(NUM_TAPS);
  localparam int LEAVES=2**LEVELS;
  localparam int LATENCY=LEVELS+3;
  wire [LEAVES-1:0] filtered,bubble;
  for(genvar tap=0;tap<LEAVES;tap=tap+1) begin:gen_filter
    if(tap<NUM_TAPS) begin:used
      wire a=raw_taps_i[(tap==0) ? 0 : tap-1];
      wire b=raw_taps_i[tap];
      wire c=raw_taps_i[(tap==NUM_TAPS-1) ? tap : tap+1];
      assign filtered[tap]=(a&b)|(a&c)|(b&c);
      assign bubble[tap]=filtered[tap]^b;
    end else begin:padding
      assign filtered[tap]=0;
      assign bubble[tap]=0;
    end
  end
  // Summary offsets are relative to each subtree. Empty padded leaves carry
  // neither a zero nor a one and cannot create a spurious late transition.
  for(genvar level=0;level<LEVELS;level=level+1) begin:gen_level
    localparam int COUNT=LEAVES>>(level+1);
    localparam int W=level+2;
    localparam int HALF=1<<level;
    logic [W-1:0] population[0:COUNT-1],leading[0:COUNT-1],last_end[0:COUNT-1];
    logic [COUNT-1:0] has_zero,has_one,multiple,corrected;
    for(genvar node=0;node<COUNT;node=node+1) begin:gen_node
      if(level==0) begin:leaf_pair
        wire lv=(2*node<NUM_TAPS),rv=(2*node+1<NUM_TAPS);
        wire l=filtered[2*node],r=filtered[2*node+1];
        wire lp,rp;
        if(2*node<NUM_TAPS) assign lp=raw_taps_i[2*node];
        else assign lp=0;
        if(2*node+1<NUM_TAPS) assign rp=raw_taps_i[2*node+1];
        else assign rp=0;
        always_ff @(posedge clk_i) begin
          population[node]<={1'b0,lp}+{1'b0,rp};
          leading[node]<=lv && !l ? 0 : {1'b0,l}+{1'b0,r};
          last_end[node]<=r ? 2 : (l ? 1 : 0);
          has_zero[node]<=(lv&&!l)||(rv&&!r);
          has_one[node]<=l||r;
          multiple[node]<=lv&&!l&&r;
          corrected[node]<=bubble[2*node]||bubble[2*node+1];
        end
      end else begin:merge
        always_ff @(posedge clk_i) begin
          population[node]<={1'b0,gen_level[level-1].population[2*node]}+
                            {1'b0,gen_level[level-1].population[2*node+1]};
          // Left length is constant. When it contains no zero it is either
          // entirely one or empty; right data only matters for a real left.
          leading[node]<=gen_level[level-1].has_zero[2*node] ?
            W'(gen_level[level-1].leading[2*node]) :
            W'(gen_level[level-1].leading[2*node])+W'(gen_level[level-1].leading[2*node+1]);
          last_end[node]<=gen_level[level-1].has_one[2*node+1] ?
            W'(HALF)+W'(gen_level[level-1].last_end[2*node+1]) :
            W'(gen_level[level-1].last_end[2*node]);
          has_zero[node]<=gen_level[level-1].has_zero[2*node]||gen_level[level-1].has_zero[2*node+1];
          has_one[node]<=gen_level[level-1].has_one[2*node]||gen_level[level-1].has_one[2*node+1];
          multiple[node]<=gen_level[level-1].multiple[2*node]||gen_level[level-1].multiple[2*node+1]||
            (gen_level[level-1].has_zero[2*node]&&gen_level[level-1].has_one[2*node+1]);
          corrected[node]<=gen_level[level-1].corrected[2*node]||gen_level[level-1].corrected[2*node+1];
        end
      end
    end
  end
  logic [LATENCY-1:0] valid;
  always_ff @(posedge clk_i)
    if(!rstn_i) valid<=0;
    else valid<={valid[LATENCY-2:0],start_i};
  assign done_o=valid[LATENCY-1];
  logic [INDEX_W:0] span,pop0,pop1;
  logic multi0,multi1,bubble0,bubble1,span_ok;
  always_ff @(posedge clk_i) begin
    span<=gen_level[LEVELS-1].last_end[0]-gen_level[LEVELS-1].leading[0];
    pop0<=gen_level[LEVELS-1].population[0];
    multi0<=gen_level[LEVELS-1].multiple[0];
    bubble0<=gen_level[LEVELS-1].corrected[0];
    span_ok<=span<=(INDEX_W+1)'(MAX_TRANSITION_SPAN);
    pop1<=pop0;multi1<=multi0;bubble1<=bubble0;
    fine_index_o<=(pop1>=NUM_TAPS) ? INDEX_W'(NUM_TAPS-1) : pop1[INDEX_W-1:0];
    status_o<=((pop1==0) ? 8'h0a : 0) | ((pop1==NUM_TAPS) ? 8'h12 : 0) |
      ((multi1&&!span_ok) ? 8'h04 : 0) |
      ((bubble1||(multi1&&span_ok)) ? 8'h20 : 0) |
      ((pop1!=0 && pop1!=NUM_TAPS && (!multi1||span_ok)) ? 8'h01 : 0);
  end
endmodule
