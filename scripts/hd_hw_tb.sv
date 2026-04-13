`timescale 1ns / 1ps
//
// hd_hw_tb.sv — Testbench for hd_hw (full PL hardware wrapper).
//
// Drives an AXI4-Lite slave model that mimics PS UART1 (0xE000_102C / 1030).
// Queues the same 2000-step input pattern as top_tb.sv, streams it to the DUT
// via the UART protocol, captures DUT TX output, and writes the results to
// post_implementation_data.txt so uart_test.py can use it as the reference.
//
// Protocol driven by this TB:
//   TB → DUT (via AXI RX FIFO reads):  0xAA + 2000×9 bytes + 0xBB
//   DUT → TB (via AXI TX FIFO writes): 2000×13 bytes + 0xCC
//
// NOTE: This simulation takes ~450 k cycles (~9 ms sim-time, under a minute
//       in xsim for a simple design like this).
//

module hd_hw_tb();

    // -----------------------------------------------------------------------
    // Parameters
    // -----------------------------------------------------------------------
    localparam integer CLK_PERIOD = 20;      // 50 MHz
    localparam integer STEPS      = 2000;
    localparam [31:0]  UART_STAT  = 32'hE000_102C;
    localparam [31:0]  UART_FIFO  = 32'hE000_1030;

    // -----------------------------------------------------------------------
    // Clock & reset
    // -----------------------------------------------------------------------
    reg clk   = 1'b0;
    reg rst_n = 1'b0;

    always #(CLK_PERIOD/2) clk = ~clk;

    initial begin
        rst_n = 1'b0;
        repeat(8) @(posedge clk);
        @(posedge clk);
        rst_n = 1'b1;
    end

    // -----------------------------------------------------------------------
    // AXI4-Lite wires (master-driven = DUT outputs)
    // -----------------------------------------------------------------------
    wire [31:0] m_axi_awaddr;
    wire [2:0]  m_axi_awprot;
    wire        m_axi_awvalid;
    wire [31:0] m_axi_wdata;
    wire [3:0]  m_axi_wstrb;
    wire        m_axi_wvalid;
    wire        m_axi_bready;
    wire [31:0] m_axi_araddr;
    wire [2:0]  m_axi_arprot;
    wire        m_axi_arvalid;
    wire        m_axi_rready;
    wire        done_led;

    // Slave-driven (this testbench)
    reg         m_axi_awready = 1'b0;
    reg         m_axi_wready  = 1'b0;
    reg  [1:0]  m_axi_bresp   = 2'b00;
    reg         m_axi_bvalid  = 1'b0;
    reg         m_axi_arready = 1'b0;
    reg  [31:0] m_axi_rdata   = 32'h0;
    reg  [1:0]  m_axi_rresp   = 2'b00;
    reg         m_axi_rvalid  = 1'b0;

    // -----------------------------------------------------------------------
    // DUT
    // -----------------------------------------------------------------------
    hd_hw dut (
        .clk            (clk),
        .rst_n          (rst_n),
        .m_axi_awaddr   (m_axi_awaddr),
        .m_axi_awprot   (m_axi_awprot),
        .m_axi_awvalid  (m_axi_awvalid),
        .m_axi_awready  (m_axi_awready),
        .m_axi_wdata    (m_axi_wdata),
        .m_axi_wstrb    (m_axi_wstrb),
        .m_axi_wvalid   (m_axi_wvalid),
        .m_axi_wready   (m_axi_wready),
        .m_axi_bresp    (m_axi_bresp),
        .m_axi_bvalid   (m_axi_bvalid),
        .m_axi_bready   (m_axi_bready),
        .m_axi_araddr   (m_axi_araddr),
        .m_axi_arprot   (m_axi_arprot),
        .m_axi_arvalid  (m_axi_arvalid),
        .m_axi_arready  (m_axi_arready),
        .m_axi_rdata    (m_axi_rdata),
        .m_axi_rresp    (m_axi_rresp),
        .m_axi_rvalid   (m_axi_rvalid),
        .m_axi_rready   (m_axi_rready),
        .done_led       (done_led)
    );

    // -----------------------------------------------------------------------
    // Stimulus arrays — same three phases as top_tb.sv
    // -----------------------------------------------------------------------
    reg [23:0] pre_in1_arr [0:STEPS-1];
    reg [23:0] pre_in2_arr [0:STEPS-1];
    reg [23:0] post_in_arr [0:STEPS-1];

    // RX queue: 0xAA + STEPS*9 + 0xBB
    localparam integer RX_SIZE = 1 + STEPS*9 + 1;
    reg [7:0]  rx_q    [0:RX_SIZE-1];
    integer    rx_head = 0;
    integer    rx_tail = 0;

    // TX capture buffer: STEPS*13 bytes + 0xCC
    localparam integer TX_SIZE = STEPS*13 + 1;
    reg [7:0]  tx_buf  [0:TX_SIZE-1];
    integer    tx_cnt  = 0;

    integer qi;
    initial begin
        // Phase 1: 500 steps — high current on both pre-synapses
        for (qi = 0; qi < 500; qi++) begin
            pre_in1_arr[qi] = $urandom_range(87500, 83643);
            pre_in2_arr[qi] = $urandom_range(87500, 83643);
            post_in_arr[qi] = 24'h0;
        end
        // Phase 2: 500 steps — low current on both
        for (qi = 500; qi < 1000; qi++) begin
            pre_in1_arr[qi] = $urandom_range(34000, 32000);
            pre_in2_arr[qi] = $urandom_range(34000, 32000);
            post_in_arr[qi] = 24'h0;
        end
        // Phase 3: 1000 steps — pre1 high, pre2 low, post mid during steps 1250-1450
        for (qi = 1000; qi < 2000; qi++) begin
            pre_in1_arr[qi] = $urandom_range(87500, 83643);
            pre_in2_arr[qi] = $urandom_range(34000, 32000);
            if (qi >= 1249 && qi < 1449)
                post_in_arr[qi] = $urandom_range(56000, 52000);
            else
                post_in_arr[qi] = 24'h0;
        end

        // Build UART RX byte queue (start marker + inputs + readback trigger)
        rx_q[rx_tail] = 8'hAA; rx_tail = rx_tail + 1;
        for (qi = 0; qi < STEPS; qi++) begin
            rx_q[rx_tail] = pre_in1_arr[qi][23:16]; rx_tail = rx_tail + 1;
            rx_q[rx_tail] = pre_in1_arr[qi][15:8];  rx_tail = rx_tail + 1;
            rx_q[rx_tail] = pre_in1_arr[qi][7:0];   rx_tail = rx_tail + 1;
            rx_q[rx_tail] = pre_in2_arr[qi][23:16]; rx_tail = rx_tail + 1;
            rx_q[rx_tail] = pre_in2_arr[qi][15:8];  rx_tail = rx_tail + 1;
            rx_q[rx_tail] = pre_in2_arr[qi][7:0];   rx_tail = rx_tail + 1;
            rx_q[rx_tail] = post_in_arr[qi][23:16]; rx_tail = rx_tail + 1;
            rx_q[rx_tail] = post_in_arr[qi][15:8];  rx_tail = rx_tail + 1;
            rx_q[rx_tail] = post_in_arr[qi][7:0];   rx_tail = rx_tail + 1;
        end
        rx_q[rx_tail] = 8'hBB; rx_tail = rx_tail + 1;
    end

    // -----------------------------------------------------------------------
    // AXI4-Lite slave: read channel
    //
    // Sequence per transaction (3 cycles after ARVALID):
    //   Cycle 0: ARVALID=1 → accept addr, ARREADY=1, ar_pend=1
    //   Cycle 1: ar_pend=1 → drive RVALID=1 + RDATA, ar_pend=0
    //   Cycle 2: RVALID=1 && RREADY=1 → handshake, RVALID=0
    //            (master transitions to RD_DONE, rd_done fires)
    // -----------------------------------------------------------------------
    reg        ar_pend   = 1'b0;
    reg [31:0] ar_addr_r = 32'h0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axi_arready <= 1'b0;
            m_axi_rvalid  <= 1'b0;
            m_axi_rdata   <= 32'h0;
            m_axi_rresp   <= 2'b00;
            ar_pend       <= 1'b0;
            ar_addr_r     <= 32'h0;
        end else begin
            m_axi_arready <= 1'b0;  // default

            // Step 1: accept read address
            if (m_axi_arvalid && !ar_pend && !m_axi_rvalid) begin
                m_axi_arready <= 1'b1;
                ar_addr_r     <= m_axi_araddr;
                ar_pend       <= 1'b1;
            end

            // Step 2: one cycle later provide read data
            if (ar_pend && !m_axi_rvalid) begin
                ar_pend      <= 1'b0;
                m_axi_rvalid <= 1'b1;
                m_axi_rresp  <= 2'b00;
                if (ar_addr_r == UART_STAT) begin
                    // bit[0]=RTRIG (RX data ready), bit[4]=TFUL (TX full, never in sim)
                    m_axi_rdata <= {31'b0, (rx_head < rx_tail) ? 1'b1 : 1'b0};
                end else begin
                    // UART_FIFO: pop and return next RX byte
                    if (rx_head < rx_tail) begin
                        m_axi_rdata <= {24'h0, rx_q[rx_head]};
                        rx_head     <= rx_head + 1;
                    end else begin
                        m_axi_rdata <= 32'h0;
                        $display("[TB WARN] @%0t ns: RX queue empty on unexpected read",
                                 $time/1000);
                    end
                end
            end

            // Step 3: clear after handshake
            if (m_axi_rvalid && m_axi_rready)
                m_axi_rvalid <= 1'b0;
        end
    end

    // -----------------------------------------------------------------------
    // AXI4-Lite slave: write channel
    //
    // The axi4_lite_master sends AWVALID and WVALID simultaneously in WR_ADDR,
    // then keeps WVALID in WR_DATA until WREADY. Both are accepted here; the
    // second WREADY (in WR_DATA) advances to WR_RESP so master sees BVALID.
    //
    // Step 3 fires once (when aw_got && w_got) and issues BVALID + captures byte.
    // The second W acceptance in WR_DATA sets w_got again; it is cleared in
    // Step 4 (BREADY handshake) so the next transaction starts clean.
    // -----------------------------------------------------------------------
    reg        aw_got    = 1'b0;
    reg        w_got     = 1'b0;
    reg [31:0] aw_addr_r = 32'h0;
    reg [7:0]  w_data_r  = 8'h0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_axi_awready <= 1'b0;
            m_axi_wready  <= 1'b0;
            m_axi_bvalid  <= 1'b0;
            m_axi_bresp   <= 2'b00;
            aw_got        <= 1'b0;
            w_got         <= 1'b0;
            aw_addr_r     <= 32'h0;
            w_data_r      <= 8'h0;
        end else begin
            m_axi_awready <= 1'b0;  // defaults
            m_axi_wready  <= 1'b0;

            // Step 1: accept write address (only while not in response phase)
            if (m_axi_awvalid && !aw_got && !m_axi_bvalid) begin
                m_axi_awready <= 1'b1;
                aw_addr_r     <= m_axi_awaddr;
                aw_got        <= 1'b1;
            end

            // Step 2: accept write data
            if (m_axi_wvalid && !w_got) begin
                m_axi_wready <= 1'b1;
                w_data_r     <= m_axi_wdata[7:0];
                w_got        <= 1'b1;
            end

            // Step 3: issue response once both AW and W accepted
            if (aw_got && w_got && !m_axi_bvalid) begin
                m_axi_bvalid <= 1'b1;
                m_axi_bresp  <= 2'b00;
                if (aw_addr_r == UART_FIFO && tx_cnt < TX_SIZE) begin
                    tx_buf[tx_cnt] <= w_data_r;
                    tx_cnt         <= tx_cnt + 1;
                end
                aw_got <= 1'b0;
                w_got  <= 1'b0;
            end

            // Step 4: clear response + any pending w_got from WR_DATA re-acceptance
            if (m_axi_bvalid && m_axi_bready) begin
                m_axi_bvalid <= 1'b0;
                w_got        <= 1'b0;
            end
        end
    end

    // -----------------------------------------------------------------------
    // Wait for completion + write output file
    // -----------------------------------------------------------------------
    integer    file_out;
    integer    step_i;
    reg [23:0] w1_v, w2_v, c1_v, c2_v;
    reg [7:0]  spk_v;

    initial begin
        // Wait for done_led or simulation timeout (~1.5 M cycles = 30 ms)
        fork
            begin : wait_done
                @(posedge done_led);
            end
            begin : sim_timeout
                #(CLK_PERIOD * 1_500_000);
                $display("[TB ERROR] TIMEOUT — done_led never asserted.");
                $display("          TX bytes captured: %0d / %0d", tx_cnt, TX_SIZE);
                $display("          RX bytes consumed: %0d / %0d", rx_head, rx_tail);
                $finish;
            end
        join_any
        disable fork;

        // Sanity checks
        $display("[TB] done_led asserted at %0t ns", $time/1000);
        $display("[TB] TX bytes: %0d (expected %0d)", tx_cnt, TX_SIZE);
        if (tx_cnt < TX_SIZE)
            $display("[TB WARN] Short receive — only %0d of %0d bytes", tx_cnt, TX_SIZE);
        if (tx_cnt > 0 && tx_buf[STEPS*13] !== 8'hCC)
            $display("[TB WARN] Done marker = 0x%02h (expected 0xCC)",
                     tx_buf[STEPS*13]);

        // Write results in same CSV format as top_tb.sv
        file_out = $fopen(
            "/projects/HeterosynapticDynamics/scripts/output/post_implementation_data.txt",
            "w");
        if (!file_out) begin
            $display("[TB ERROR] Cannot open output file — check path.");
            $finish;
        end

        $fwrite(file_out,
            "step, pre_in1, pre_in2, post_in, pre1_spike, pre2_spike, post_spike, w1, w2, c1, c2\n");

        for (step_i = 0; step_i < STEPS; step_i++) begin
            w1_v  = {tx_buf[step_i*13+0],  tx_buf[step_i*13+1],  tx_buf[step_i*13+2]};
            w2_v  = {tx_buf[step_i*13+3],  tx_buf[step_i*13+4],  tx_buf[step_i*13+5]};
            c1_v  = {tx_buf[step_i*13+6],  tx_buf[step_i*13+7],  tx_buf[step_i*13+8]};
            c2_v  = {tx_buf[step_i*13+9],  tx_buf[step_i*13+10], tx_buf[step_i*13+11]};
            spk_v = tx_buf[step_i*13+12];
            $fwrite(file_out,
                "%0d, %0d, %0d, %0d, %b, %b, %b, %0d, %0d, %0d, %0d\n",
                step_i + 1,
                pre_in1_arr[step_i], pre_in2_arr[step_i], post_in_arr[step_i],
                spk_v[0], spk_v[1], spk_v[2],
                w1_v, w2_v, c1_v, c2_v);
        end
        $fclose(file_out);
        $display("[TB] Results written to post_implementation_data.txt");
        $display("[TB] Simulation complete.");
        $finish;
    end

    // VCD dump — comment out to speed up long simulations
    initial begin
        $dumpfile("hd_hw_tb.vcd");
        $dumpvars(0, hd_hw_tb);
    end

endmodule
