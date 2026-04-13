`timescale 1ns / 1ps
module calcium_update(clk, rst, en, pre_spike, post_spike, c_result);
`include "params.vh"

input             clk, rst, en;
input             pre_spike, post_spike;
output [WIDTH-1:0] c_result;

reg [(2*WIDTH)-1:0] c_decayed_temp;
reg [WIDTH-1:0]     c_decayed;
reg [WIDTH-1:0]     pre_spike_contribution;
reg [WIDTH-1:0]     post_spike_contribution;
reg [WIDTH-1:0]     c, next_c;
reg [WIDTH+1:0]     next_c_wide;

always @(posedge clk or posedge rst) begin
    if (rst)
        c <= 0;
    else if (en)
        c <= next_c;
end

always @(*) begin
    c_decayed_temp = c * DECAY_C;
    c_decayed      = c_decayed_temp[MUL_RESULT_HIGH:MUL_RESULT_LOW];

    pre_spike_contribution  = pre_spike  ? C_PRE  : {WIDTH{1'b0}};
    post_spike_contribution = post_spike ? C_POST : {WIDTH{1'b0}};

    next_c_wide = {2'b00, c_decayed} + {2'b00, pre_spike_contribution}
                                      + {2'b00, post_spike_contribution};
    next_c = (|next_c_wide[WIDTH+1:WIDTH]) ? {WIDTH{1'b1}} : next_c_wide[WIDTH-1:0];
end

assign c_result = c;

endmodule
