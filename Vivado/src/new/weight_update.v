`timescale 1ns / 1ps
module weight_update(clk, rst, en, pre_spike, is_ltd, is_ltp, is_protein, w_result);
`include "params.vh"

input             clk, rst, en;
input             pre_spike;
input             is_ltd, is_ltp, is_protein;
output [WIDTH-1:0] w_result;

reg [WIDTH-1:0]     w_curr, w_next;
reg [WIDTH:0]       w_next_temp;
reg [WIDTH-1:0]     w_pool_curr, w_pool_next;
reg [WIDTH-1:0]     contrib, contrib_temp3;
reg [(2*WIDTH)-1:0] contrib_temp1, contrib_temp2;

assign w_result = w_curr;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        w_curr      <= W_DEF;
        w_pool_curr <= W_POOL_MAX;
    end else if (en) begin
        w_curr      <= w_next;
        w_pool_curr <= w_pool_next;
    end
end

always @(*) begin
    contrib       = {WIDTH{1'b0}};
    contrib_temp1 = {(2*WIDTH){1'b0}};
    contrib_temp2 = {(2*WIDTH){1'b0}};
    contrib_temp3 = {WIDTH{1'b0}};
    w_next_temp   = {(WIDTH+1){1'b0}};
    w_pool_next   = w_pool_curr;
    w_next        = w_curr;

    if (is_protein && pre_spike) begin
        if (is_ltd) begin
            contrib_temp1 = GAMMA_D * w_curr;
            contrib       = contrib_temp1[MUL_RESULT_HIGH:MUL_RESULT_LOW];
            w_pool_next   = w_pool_curr + contrib;
            w_next        = (contrib > w_curr) ? {WIDTH{1'b0}} : (w_curr - contrib);
        end else if (is_ltp) begin
            contrib_temp1 = w_pool_curr * RECIP_W_POOL_MAX;
            contrib_temp3 = contrib_temp1[MUL_RESULT_HIGH:MUL_RESULT_LOW];
            contrib_temp2 = GAMMA_P * contrib_temp3;
            contrib       = contrib_temp2[MUL_RESULT_HIGH:MUL_RESULT_LOW];
            w_next_temp   = {1'b0, w_curr} + {1'b0, contrib};
            if (w_next_temp > W_MAX) begin
                w_next      = W_MAX;
                w_pool_next = ((w_next_temp - W_MAX) > {1'b0, w_pool_curr})
                              ? {WIDTH{1'b0}}
                              : (w_pool_curr - (w_next_temp[WIDTH-1:0] - W_MAX));
            end else begin
                w_next      = w_next_temp[WIDTH-1:0];
                w_pool_next = (contrib > w_pool_curr) ? {WIDTH{1'b0}} : (w_pool_curr - contrib);
            end
        end
    end
end

endmodule
