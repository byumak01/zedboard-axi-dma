`timescale 1ns / 1ps
module hd_neuron(clk, rst, en, pre_in1, pre_in2, post_in,
                 pre1_spike, pre2_spike, post_spike,
                 w1, w2, c1, c2);
`include "params.vh"

input             clk, rst, en;
input  [WIDTH-1:0] pre_in1, pre_in2;
input  [WIDTH-1:0] post_in;
output             pre1_spike, pre2_spike, post_spike;
output [WIDTH-1:0] w1, w2;
output [WIDTH-1:0] c1, c2;

simplified_neuron pre_neuron1(.clk(clk), .rst(rst), .en(en), .current(pre_in1), .spike_result(pre1_spike), .v_e_result());
simplified_neuron pre_neuron2(.clk(clk), .rst(rst), .en(en), .current(pre_in2), .spike_result(pre2_spike), .v_e_result());
simplified_neuron post_neuron(.clk(clk), .rst(rst), .en(en), .current(post_in),  .spike_result(post_spike), .v_e_result());

synapse syn(.clk(clk), .rst(rst), .en(en),
            .pre1_spike(pre1_spike), .pre2_spike(pre2_spike), .post_spike(post_spike),
            .w1(w1), .w2(w2), .c1(c1), .c2(c2));

endmodule
