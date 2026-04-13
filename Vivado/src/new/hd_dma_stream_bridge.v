`timescale 1ns / 1ps

module hd_dma_stream_bridge #(
    parameter integer AXIS_TDATA_WIDTH = 32,
    parameter integer MAX_STEPS = 56
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXIS:M_AXIS, ASSOCIATED_RESET aresetn, FREQ_HZ 100000000" *)
    input  wire                        aclk,

    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                        aresetn,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TDATA" *)
    input  wire [AXIS_TDATA_WIDTH-1:0] s_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TKEEP" *)
    input  wire [(AXIS_TDATA_WIDTH/8)-1:0] s_axis_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TVALID" *)
    input  wire                        s_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TREADY" *)
    output wire                        s_axis_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TLAST" *)
    input  wire                        s_axis_tlast,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TDATA" *)
    output reg  [AXIS_TDATA_WIDTH-1:0] m_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TKEEP" *)
    output reg  [(AXIS_TDATA_WIDTH/8)-1:0] m_axis_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TVALID" *)
    output reg                         m_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TREADY" *)
    input  wire                        m_axis_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TLAST" *)
    output reg                         m_axis_tlast
);

    localparam integer AXIS_KEEP_WIDTH       = AXIS_TDATA_WIDTH / 8;
    localparam integer CMD_RUN_BATCH         = 8'hA5;
    localparam integer HDR_BYTES             = 4;
    localparam integer STEP_INPUT_BYTES      = 9;
    localparam integer STEP_OUTPUT_BYTES     = 13;
    localparam integer MAX_OUTPUT_BYTES      = MAX_STEPS * STEP_OUTPUT_BYTES;

    localparam [3:0] ST_RECV       = 4'd0;
    localparam [3:0] ST_PROC_RESET = 4'd1;
    localparam [3:0] ST_PROC_LOAD  = 4'd2;
    localparam [3:0] ST_PROC_EN    = 4'd3;
    localparam [3:0] ST_PROC_CAP   = 4'd4;
    localparam [3:0] ST_SEND       = 4'd5;

    reg [3:0] state;

    reg [23:0] batch_pre_in1 [0:MAX_STEPS-1];
    reg [23:0] batch_pre_in2 [0:MAX_STEPS-1];
    reg [23:0] batch_post_in [0:MAX_STEPS-1];
    reg [7:0]  out_buf       [0:MAX_OUTPUT_BYTES-1];

    reg [23:0] reg_pre_in1;
    reg [23:0] reg_pre_in2;
    reg [23:0] reg_post_in;
    reg        nn_rst_reg;
    reg        nn_en;

    wire       nn_rst;
    wire       nn_pre1_spike;
    wire       nn_pre2_spike;
    wire       nn_post_spike;
    wire [23:0] nn_w1;
    wire [23:0] nn_w2;
    wire [23:0] nn_c1;
    wire [23:0] nn_c2;

    reg [7:0]  flags_reg;
    reg [15:0] batch_step_count;
    reg [15:0] step_store_index;
    reg [3:0]  header_index;
    reg [3:0]  step_byte_index;
    reg [15:0] proc_step_index;
    reg [15:0] out_write_index;
    reg [15:0] out_send_index;
    reg [15:0] total_output_bytes;

    reg [23:0] assemble_pre_in1;
    reg [23:0] assemble_pre_in2;
    reg [23:0] assemble_post_in;

    reg [AXIS_TDATA_WIDTH-1:0] in_word_data;
    reg [AXIS_KEEP_WIDTH-1:0]  in_word_keep;
    reg                        in_word_last;
    reg                        in_word_valid;
    reg [2:0]                  in_word_index;

    reg                        frame_payload_done;
    reg                        parse_error;

    integer                    remaining_bytes;
    integer                    word_bytes;
    integer                    idx;

    assign nn_rst = nn_rst_reg | ~aresetn;
    assign s_axis_tready = (state == ST_RECV) && !in_word_valid;

    hd_neuron u_nn (
        .clk        (aclk),
        .rst        (nn_rst),
        .en         (nn_en),
        .pre_in1    (reg_pre_in1),
        .pre_in2    (reg_pre_in2),
        .post_in    (reg_post_in),
        .pre1_spike (nn_pre1_spike),
        .pre2_spike (nn_pre2_spike),
        .post_spike (nn_post_spike),
        .w1         (nn_w1),
        .w2         (nn_w2),
        .c1         (nn_c1),
        .c2         (nn_c2)
    );

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            state             <= ST_RECV;
            reg_pre_in1       <= 24'h0;
            reg_pre_in2       <= 24'h0;
            reg_post_in       <= 24'h0;
            nn_rst_reg        <= 1'b0;
            nn_en             <= 1'b0;
            flags_reg         <= 8'h0;
            batch_step_count  <= 16'h0;
            step_store_index  <= 16'h0;
            header_index      <= 4'h0;
            step_byte_index   <= 4'h0;
            proc_step_index   <= 16'h0;
            out_write_index   <= 16'h0;
            out_send_index    <= 16'h0;
            total_output_bytes<= 16'h0;
            assemble_pre_in1  <= 24'h0;
            assemble_pre_in2  <= 24'h0;
            assemble_post_in  <= 24'h0;
            in_word_data      <= {AXIS_TDATA_WIDTH{1'b0}};
            in_word_keep      <= {AXIS_KEEP_WIDTH{1'b0}};
            in_word_last      <= 1'b0;
            in_word_valid     <= 1'b0;
            in_word_index     <= 3'd0;
            frame_payload_done<= 1'b0;
            parse_error       <= 1'b0;
            m_axis_tdata      <= {AXIS_TDATA_WIDTH{1'b0}};
            m_axis_tkeep      <= {AXIS_KEEP_WIDTH{1'b0}};
            m_axis_tvalid     <= 1'b0;
            m_axis_tlast      <= 1'b0;
        end else begin
            if (state == ST_SEND) begin
                if (m_axis_tvalid && m_axis_tready) begin
                    m_axis_tvalid <= 1'b0;
                    m_axis_tlast  <= 1'b0;
                    if (out_send_index >= total_output_bytes) begin
                        state            <= ST_RECV;
                        flags_reg        <= 8'h0;
                        batch_step_count <= 16'h0;
                        step_store_index <= 16'h0;
                        header_index     <= 4'h0;
                        step_byte_index  <= 4'h0;
                        frame_payload_done <= 1'b0;
                        parse_error      <= 1'b0;
                    end
                end

                if (!m_axis_tvalid && (out_send_index < total_output_bytes)) begin
                    remaining_bytes = total_output_bytes - out_send_index;
                    if (remaining_bytes >= AXIS_KEEP_WIDTH)
                        word_bytes = AXIS_KEEP_WIDTH;
                    else
                        word_bytes = remaining_bytes;

                    m_axis_tdata = {AXIS_TDATA_WIDTH{1'b0}};
                    m_axis_tkeep = {AXIS_KEEP_WIDTH{1'b0}};
                    for (idx = 0; idx < word_bytes; idx = idx + 1) begin
                        m_axis_tdata[idx*8 +: 8] = out_buf[out_send_index + idx];
                        m_axis_tkeep[idx] = 1'b1;
                    end

                    out_send_index <= out_send_index + word_bytes[15:0];
                    m_axis_tlast   <= ((out_send_index + word_bytes[15:0]) >= total_output_bytes);
                    m_axis_tvalid  <= 1'b1;
                end
            end else begin
                m_axis_tvalid <= 1'b0;
                m_axis_tlast  <= 1'b0;
                m_axis_tkeep  <= {AXIS_KEEP_WIDTH{1'b0}};
                m_axis_tdata  <= {AXIS_TDATA_WIDTH{1'b0}};
            end

            case (state)
                ST_RECV: begin
                    nn_rst_reg <= 1'b0;
                    nn_en      <= 1'b0;

                    if (!in_word_valid && s_axis_tvalid && s_axis_tready) begin
                        in_word_data  <= s_axis_tdata;
                        in_word_keep  <= s_axis_tkeep;
                        in_word_last  <= s_axis_tlast;
                        in_word_valid <= 1'b1;
                        in_word_index <= 3'd0;
                    end else if (in_word_valid) begin
                        if (in_word_keep[in_word_index]) begin
                            if (header_index < HDR_BYTES) begin
                                case (header_index)
                                    4'd0: begin
                                        if (in_word_data[in_word_index*8 +: 8] != CMD_RUN_BATCH)
                                            parse_error <= 1'b1;
                                    end
                                    4'd1: flags_reg <= in_word_data[in_word_index*8 +: 8];
                                    4'd2: batch_step_count[15:8] <= in_word_data[in_word_index*8 +: 8];
                                    4'd3: begin
                                        batch_step_count[7:0] <= in_word_data[in_word_index*8 +: 8];
                                        if (({batch_step_count[15:8], in_word_data[in_word_index*8 +: 8]} == 16'h0) ||
                                            ({batch_step_count[15:8], in_word_data[in_word_index*8 +: 8]} > MAX_STEPS))
                                            parse_error <= 1'b1;
                                    end
                                    default: ;
                                endcase
                                header_index <= header_index + 1'b1;
                            end else begin
                                case (step_byte_index)
                                    4'd0: assemble_pre_in1[23:16] <= in_word_data[in_word_index*8 +: 8];
                                    4'd1: assemble_pre_in1[15:8]  <= in_word_data[in_word_index*8 +: 8];
                                    4'd2: assemble_pre_in1[7:0]   <= in_word_data[in_word_index*8 +: 8];
                                    4'd3: assemble_pre_in2[23:16] <= in_word_data[in_word_index*8 +: 8];
                                    4'd4: assemble_pre_in2[15:8]  <= in_word_data[in_word_index*8 +: 8];
                                    4'd5: assemble_pre_in2[7:0]   <= in_word_data[in_word_index*8 +: 8];
                                    4'd6: assemble_post_in[23:16] <= in_word_data[in_word_index*8 +: 8];
                                    4'd7: assemble_post_in[15:8]  <= in_word_data[in_word_index*8 +: 8];
                                    4'd8: begin
                                        assemble_post_in[7:0] <= in_word_data[in_word_index*8 +: 8];
                                        if (step_store_index < MAX_STEPS) begin
                                            batch_pre_in1[step_store_index] <= assemble_pre_in1;
                                            batch_pre_in2[step_store_index] <= assemble_pre_in2;
                                            batch_post_in[step_store_index] <= {assemble_post_in[23:8], in_word_data[in_word_index*8 +: 8]};
                                        end else begin
                                            parse_error <= 1'b1;
                                        end

                                        if ((step_store_index + 1'b1) == batch_step_count)
                                            frame_payload_done <= 1'b1;

                                        step_store_index <= step_store_index + 1'b1;
                                    end
                                    default: ;
                                endcase

                                if (step_byte_index == (STEP_INPUT_BYTES - 1)) begin
                                    step_byte_index <= 4'h0;
                                end else begin
                                    step_byte_index <= step_byte_index + 1'b1;
                                end
                            end
                        end

                        if (in_word_index == (AXIS_KEEP_WIDTH - 1)) begin
                            in_word_valid <= 1'b0;
                            in_word_index <= 3'd0;
                            if (in_word_last &&
                                (frame_payload_done ||
                                 ((step_byte_index == (STEP_INPUT_BYTES - 1)) &&
                                  in_word_keep[in_word_index] &&
                                  ((step_store_index + 1'b1) == batch_step_count))) &&
                                !parse_error) begin
                                proc_step_index    <= 16'h0;
                                out_write_index    <= 16'h0;
                                out_send_index     <= 16'h0;
                                total_output_bytes <= batch_step_count * STEP_OUTPUT_BYTES;
                                state              <= flags_reg[0] ? ST_PROC_RESET : ST_PROC_LOAD;
                            end
                        end else begin
                            in_word_index <= in_word_index + 1'b1;
                        end
                    end
                end

                ST_PROC_RESET: begin
                    nn_rst_reg <= 1'b1;
                    nn_en      <= 1'b0;
                    state      <= ST_PROC_LOAD;
                end

                ST_PROC_LOAD: begin
                    nn_rst_reg  <= 1'b0;
                    nn_en       <= 1'b0;
                    reg_pre_in1 <= batch_pre_in1[proc_step_index];
                    reg_pre_in2 <= batch_pre_in2[proc_step_index];
                    reg_post_in <= batch_post_in[proc_step_index];
                    state       <= ST_PROC_EN;
                end

                ST_PROC_EN: begin
                    nn_rst_reg <= 1'b0;
                    nn_en      <= 1'b1;
                    state      <= ST_PROC_CAP;
                end

                ST_PROC_CAP: begin
                    nn_rst_reg <= 1'b0;
                    nn_en      <= 1'b0;

                    out_buf[out_write_index + 0]  <= nn_w1[23:16];
                    out_buf[out_write_index + 1]  <= nn_w1[15:8];
                    out_buf[out_write_index + 2]  <= nn_w1[7:0];
                    out_buf[out_write_index + 3]  <= nn_w2[23:16];
                    out_buf[out_write_index + 4]  <= nn_w2[15:8];
                    out_buf[out_write_index + 5]  <= nn_w2[7:0];
                    out_buf[out_write_index + 6]  <= nn_c1[23:16];
                    out_buf[out_write_index + 7]  <= nn_c1[15:8];
                    out_buf[out_write_index + 8]  <= nn_c1[7:0];
                    out_buf[out_write_index + 9]  <= nn_c2[23:16];
                    out_buf[out_write_index + 10] <= nn_c2[15:8];
                    out_buf[out_write_index + 11] <= nn_c2[7:0];
                    out_buf[out_write_index + 12] <= {5'b0, nn_post_spike, nn_pre2_spike, nn_pre1_spike};

                    out_write_index <= out_write_index + STEP_OUTPUT_BYTES;

                    if ((proc_step_index + 1'b1) >= batch_step_count) begin
                        out_send_index <= 16'h0;
                        state          <= ST_SEND;
                    end else begin
                        proc_step_index <= proc_step_index + 1'b1;
                        state           <= ST_PROC_LOAD;
                    end
                end

                default: begin
                    state <= ST_RECV;
                end
            endcase
        end
    end

endmodule
