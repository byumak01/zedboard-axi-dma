`timescale 1ns / 1ps
module simplified_neuron(clk, rst, en, current, spike_result, v_e_result);
`include "params.vh"

input clk, rst, en;
input  [WIDTH-1:0] current;
output             spike_result;
output [WIDTH-1:0] v_e_result;

reg [WIDTH-1:0]     v_e, v_e_decayed, v_e_next;
reg [WIDTH:0]       v_e_temp_wide;
reg [(2*WIDTH)-1:0] decay_temp;
reg spike, spike_next;

assign spike_result = spike;
assign v_e_result   = v_e;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        v_e   <= 0;
        spike <= 0;
    end else if (en) begin
        v_e   <= v_e_next;
        spike <= spike_next;
    end
end

always @(*) begin
    decay_temp   = v_e * DECAY_LIF;
    v_e_decayed  = decay_temp[MUL_RESULT_HIGH:MUL_RESULT_LOW];

    v_e_temp_wide = {1'b0, current} + {1'b0, v_e_decayed};

    if (v_e_temp_wide >= V_TH) begin
        v_e_next   = V_RESET;
        spike_next = 1;
    end else begin
        v_e_next   = v_e_temp_wide[WIDTH-1:0];
        spike_next = 0;
    end
end

endmodule
