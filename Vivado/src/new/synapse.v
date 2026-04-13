`timescale 1ns / 1ps
module synapse(clk, rst, en, pre1_spike, pre2_spike, post_spike, w1, w2, c1, c2);
`include "params.vh"

input             clk, rst, en;
input             pre1_spike, pre2_spike, post_spike;
output [WIDTH-1:0] w1, w2;
output [WIDTH-1:0] c1, c2;

wire [WIDTH-1:0] _c1, _c2;
wire [WIDTH-1:0] _w1, _w2;
reg              is_ltd1, is_ltd2;
reg              is_ltp1, is_ltp2;
wire             is_protein;

calcium_update c1_update(.clk(clk), .rst(rst), .en(en), .pre_spike(pre1_spike), .post_spike(post_spike), .c_result(_c1));
calcium_update c2_update(.clk(clk), .rst(rst), .en(en), .pre_spike(pre2_spike), .post_spike(post_spike), .c_result(_c2));

weight_update _wu1(.clk(clk), .rst(rst), .en(en), .pre_spike(pre1_spike), .is_ltd(is_ltd1), .is_ltp(is_ltp1), .is_protein(is_protein), .w_result(_w1));
weight_update _wu2(.clk(clk), .rst(rst), .en(en), .pre_spike(pre2_spike), .is_ltd(is_ltd2), .is_ltp(is_ltp2), .is_protein(is_protein), .w_result(_w2));

assign is_protein = (({1'b0, _c1} + {1'b0, _c2}) > {1'b0, THETA_C}) ? 1'b1 : 1'b0;

assign c1 = _c1;
assign c2 = _c2;
assign w1 = _w1;
assign w2 = _w2;

always @(*) begin
    is_ltp1 = (_c1 >= THETA_P);
    is_ltd1 = (_c1 >= THETA_D) && (_c1 < THETA_P);
    is_ltp2 = (_c2 >= THETA_P);
    is_ltd2 = (_c2 >= THETA_D) && (_c2 < THETA_P);
end

endmodule
