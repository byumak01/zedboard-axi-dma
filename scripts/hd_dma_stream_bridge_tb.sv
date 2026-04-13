`timescale 1ns / 1ps

module hd_dma_stream_bridge_tb;

    localparam int STEP_COUNT = 5;
    localparam int HDR_BYTES = 4;
    localparam int INPUT_BYTES_PER_STEP = 9;
    localparam int OUTPUT_BYTES_PER_STEP = 13;
    localparam int REQUEST_BYTES = HDR_BYTES + (STEP_COUNT * INPUT_BYTES_PER_STEP);
    localparam int RESPONSE_BYTES = STEP_COUNT * OUTPUT_BYTES_PER_STEP;

    reg clk = 1'b0;
    reg aresetn = 1'b0;

    reg  [31:0] s_axis_tdata  = 32'h0;
    reg  [3:0]  s_axis_tkeep  = 4'h0;
    reg         s_axis_tvalid = 1'b0;
    wire        s_axis_tready;
    reg         s_axis_tlast  = 1'b0;

    wire [31:0] m_axis_tdata;
    wire [3:0]  m_axis_tkeep;
    wire        m_axis_tvalid;
    reg         m_axis_tready = 1'b1;
    wire        m_axis_tlast;

    reg         ref_rst = 1'b0;
    reg         ref_en = 1'b0;
    reg  [23:0] ref_pre_in1 = 24'h0;
    reg  [23:0] ref_pre_in2 = 24'h0;
    reg  [23:0] ref_post_in = 24'h0;
    wire        ref_pre1_spike;
    wire        ref_pre2_spike;
    wire        ref_post_spike;
    wire [23:0] ref_w1;
    wire [23:0] ref_w2;
    wire [23:0] ref_c1;
    wire [23:0] ref_c2;

    reg [23:0] pre_in1_arr [0:STEP_COUNT-1];
    reg [23:0] pre_in2_arr [0:STEP_COUNT-1];
    reg [23:0] post_in_arr [0:STEP_COUNT-1];
    reg [7:0] request_bytes [0:REQUEST_BYTES-1];
    reg [7:0] expected_bytes [0:RESPONSE_BYTES-1];
    reg [7:0] response_bytes [0:RESPONSE_BYTES-1];

    integer response_count = 0;
    integer i;
    integer valid_bytes;
    integer mismatch_count = 0;

    always #10 clk = ~clk;

    hd_dma_stream_bridge dut (
        .aclk         (clk),
        .aresetn      (aresetn),
        .s_axis_tdata (s_axis_tdata),
        .s_axis_tkeep (s_axis_tkeep),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready),
        .s_axis_tlast (s_axis_tlast),
        .m_axis_tdata (m_axis_tdata),
        .m_axis_tkeep (m_axis_tkeep),
        .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready),
        .m_axis_tlast (m_axis_tlast)
    );

    hd_neuron ref_nn (
        .clk        (clk),
        .rst        (ref_rst),
        .en         (ref_en),
        .pre_in1    (ref_pre_in1),
        .pre_in2    (ref_pre_in2),
        .post_in    (ref_post_in),
        .pre1_spike (ref_pre1_spike),
        .pre2_spike (ref_pre2_spike),
        .post_spike (ref_post_spike),
        .w1         (ref_w1),
        .w2         (ref_w2),
        .c1         (ref_c1),
        .c2         (ref_c2)
    );

    always @(posedge clk) begin
        integer lane;
        integer capture_index;
        if (m_axis_tvalid && m_axis_tready) begin
            capture_index = response_count;
            for (lane = 0; lane < 4; lane = lane + 1) begin
                if (m_axis_tkeep[lane]) begin
                    if (capture_index < RESPONSE_BYTES) begin
                        response_bytes[capture_index] <= m_axis_tdata[(lane*8) +: 8];
                        capture_index = capture_index + 1;
                    end
                end
            end
            response_count <= capture_index;
        end
    end

    task automatic build_request;
        integer req_idx;
        integer step_idx;
        begin
            req_idx = 0;
            request_bytes[req_idx] = 8'hA5; req_idx = req_idx + 1;
            request_bytes[req_idx] = 8'h01; req_idx = req_idx + 1;
            request_bytes[req_idx] = 8'h00; req_idx = req_idx + 1;
            request_bytes[req_idx] = STEP_COUNT[7:0]; req_idx = req_idx + 1;

            for (step_idx = 0; step_idx < STEP_COUNT; step_idx = step_idx + 1) begin
                request_bytes[req_idx] = pre_in1_arr[step_idx][23:16]; req_idx = req_idx + 1;
                request_bytes[req_idx] = pre_in1_arr[step_idx][15:8];  req_idx = req_idx + 1;
                request_bytes[req_idx] = pre_in1_arr[step_idx][7:0];   req_idx = req_idx + 1;
                request_bytes[req_idx] = pre_in2_arr[step_idx][23:16]; req_idx = req_idx + 1;
                request_bytes[req_idx] = pre_in2_arr[step_idx][15:8];  req_idx = req_idx + 1;
                request_bytes[req_idx] = pre_in2_arr[step_idx][7:0];   req_idx = req_idx + 1;
                request_bytes[req_idx] = post_in_arr[step_idx][23:16]; req_idx = req_idx + 1;
                request_bytes[req_idx] = post_in_arr[step_idx][15:8];  req_idx = req_idx + 1;
                request_bytes[req_idx] = post_in_arr[step_idx][7:0];   req_idx = req_idx + 1;
            end
        end
    endtask

    task automatic build_expected;
        integer exp_idx;
        integer step_idx;
        begin
            exp_idx = 0;

            ref_rst = 1'b1;
            ref_en = 1'b0;
            @(posedge clk);
            ref_rst = 1'b0;

            for (step_idx = 0; step_idx < STEP_COUNT; step_idx = step_idx + 1) begin
                ref_pre_in1 = pre_in1_arr[step_idx];
                ref_pre_in2 = pre_in2_arr[step_idx];
                ref_post_in = post_in_arr[step_idx];

                @(posedge clk);
                ref_en = 1'b1;
                @(posedge clk);
                ref_en = 1'b0;
                @(posedge clk);

                expected_bytes[exp_idx + 0]  = ref_w1[23:16];
                expected_bytes[exp_idx + 1]  = ref_w1[15:8];
                expected_bytes[exp_idx + 2]  = ref_w1[7:0];
                expected_bytes[exp_idx + 3]  = ref_w2[23:16];
                expected_bytes[exp_idx + 4]  = ref_w2[15:8];
                expected_bytes[exp_idx + 5]  = ref_w2[7:0];
                expected_bytes[exp_idx + 6]  = ref_c1[23:16];
                expected_bytes[exp_idx + 7]  = ref_c1[15:8];
                expected_bytes[exp_idx + 8]  = ref_c1[7:0];
                expected_bytes[exp_idx + 9]  = ref_c2[23:16];
                expected_bytes[exp_idx + 10] = ref_c2[15:8];
                expected_bytes[exp_idx + 11] = ref_c2[7:0];
                expected_bytes[exp_idx + 12] = {5'b0, ref_post_spike, ref_pre2_spike, ref_pre1_spike};
                exp_idx = exp_idx + OUTPUT_BYTES_PER_STEP;
            end
        end
    endtask

    task automatic send_request;
        integer req_idx;
        integer lane;
        reg [31:0] word_data;
        reg [3:0] word_keep;
        begin
            req_idx = 0;
            while (req_idx < REQUEST_BYTES) begin
                word_data = 32'h0;
                word_keep = 4'h0;
                valid_bytes = 0;

                for (lane = 0; lane < 4; lane = lane + 1) begin
                    if ((req_idx + lane) < REQUEST_BYTES) begin
                        word_data[(lane*8) +: 8] = request_bytes[req_idx + lane];
                        word_keep[lane] = 1'b1;
                        valid_bytes = valid_bytes + 1;
                    end
                end

                @(posedge clk);
                s_axis_tdata  = word_data;
                s_axis_tkeep  = word_keep;
                s_axis_tlast  = ((req_idx + valid_bytes) >= REQUEST_BYTES);
                s_axis_tvalid = 1'b1;
                while (!(s_axis_tvalid && s_axis_tready))
                    @(posedge clk);
                @(posedge clk);
                s_axis_tvalid = 1'b0;
                s_axis_tlast  = 1'b0;
                s_axis_tkeep  = 4'h0;
                s_axis_tdata  = 32'h0;
                req_idx = req_idx + valid_bytes;
            end
        end
    endtask

    initial begin
        pre_in1_arr[0] = 24'd87500;
        pre_in2_arr[0] = 24'd87500;
        post_in_arr[0] = 24'd0;

        pre_in1_arr[1] = 24'd86000;
        pre_in2_arr[1] = 24'd33000;
        post_in_arr[1] = 24'd0;

        pre_in1_arr[2] = 24'd34000;
        pre_in2_arr[2] = 24'd33000;
        post_in_arr[2] = 24'd53000;

        pre_in1_arr[3] = 24'd87500;
        pre_in2_arr[3] = 24'd33000;
        post_in_arr[3] = 24'd54000;

        pre_in1_arr[4] = 24'd34000;
        pre_in2_arr[4] = 24'd87500;
        post_in_arr[4] = 24'd0;

        build_request();

        repeat (6) @(posedge clk);
        aresetn = 1'b1;

        build_expected();
        send_request();

        wait (response_count == RESPONSE_BYTES);
        repeat (4) @(posedge clk);

        for (i = 0; i < RESPONSE_BYTES; i = i + 1) begin
            if (response_bytes[i] !== expected_bytes[i]) begin
                mismatch_count = mismatch_count + 1;
                $display("[TB ERROR] Byte %0d mismatch: got 0x%02x expected 0x%02x",
                         i, response_bytes[i], expected_bytes[i]);
            end
        end

        if (mismatch_count != 0) begin
            $display("[TB ERROR] %0d response byte mismatches detected.", mismatch_count);
            $fatal(1, "[TB ERROR] AXI-stream NN bridge test failed.");
        end

        $display("[TB] AXI-stream NN bridge test passed.");
        $finish;
    end

endmodule
