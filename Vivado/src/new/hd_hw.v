`timescale 1ns / 1ps
// hd_hw.v  --  AXI4-Lite slave wrapper for hd_neuron.
//              Plain Verilog-2001.
//
// Register map (base addr e.g. 0x43C00000):
//   0x00  CTRL    W  [0]=START (self-clearing one-shot), [1]=RST_NN
//   0x04  STATUS  R  [0]=DONE  (sticky; cleared on next START)
//   0x08  PRE_IN1 W  [23:0]   pre-synaptic current 1 (Q8.16)
//   0x0C  PRE_IN2 W  [23:0]   pre-synaptic current 2 (Q8.16)
//   0x10  POST_IN W  [23:0]   post-synaptic current  (Q8.16)
//   0x14  W1_OUT  R  [23:0]   synaptic weight 1
//   0x18  W2_OUT  R  [23:0]   synaptic weight 2
//   0x1C  C1_OUT  R  [23:0]   calcium level 1
//   0x20  C2_OUT  R  [23:0]   calcium level 2
//   0x24  SPIKES  R  [2:0]    {post_spike, pre2_spike, pre1_spike}
//
// FSM:  IDLE -> PROC (en=1 for 1 cycle) -> LATCH (capture outputs) -> DONE (set STATUS[0]) -> IDLE
//
// All outputs of hd_neuron are registered and update one cycle after en=1, so
// they are stable when sampled in the LATCH state.

module hd_hw #(
    parameter integer C_S_AXI_DATA_WIDTH = 32,
    parameter integer C_S_AXI_ADDR_WIDTH = 7
) (
    // Clock / reset
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 S_AXI_ACLK CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXI, ASSOCIATED_RESET S_AXI_ARESETN" *)
    input  wire                               S_AXI_ACLK,

    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 S_AXI_ARESETN RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                               S_AXI_ARESETN,

    // Write address channel
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWADDR" *)
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     S_AXI_AWADDR,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWPROT" *)
    input  wire [2:0]                         S_AXI_AWPROT,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *)
    input  wire                               S_AXI_AWVALID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *)
    output reg                                S_AXI_AWREADY,

    // Write data channel
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WDATA" *)
    input  wire [C_S_AXI_DATA_WIDTH-1:0]     S_AXI_WDATA,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *)
    input  wire [(C_S_AXI_DATA_WIDTH/8)-1:0] S_AXI_WSTRB,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WVALID" *)
    input  wire                               S_AXI_WVALID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WREADY" *)
    output reg                                S_AXI_WREADY,

    // Write response channel
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BRESP" *)
    output reg  [1:0]                         S_AXI_BRESP,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BVALID" *)
    output reg                                S_AXI_BVALID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BREADY" *)
    input  wire                               S_AXI_BREADY,

    // Read address channel
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *)
    input  wire [C_S_AXI_ADDR_WIDTH-1:0]     S_AXI_ARADDR,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARPROT" *)
    input  wire [2:0]                         S_AXI_ARPROT,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *)
    input  wire                               S_AXI_ARVALID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *)
    output reg                                S_AXI_ARREADY,

    // Read data channel
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RDATA" *)
    output reg  [C_S_AXI_DATA_WIDTH-1:0]     S_AXI_RDATA,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RRESP" *)
    output reg  [1:0]                         S_AXI_RRESP,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RVALID" *)
    output reg                                S_AXI_RVALID,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RREADY" *)
    input  wire                               S_AXI_RREADY
);

    // -----------------------------------------------------------------------
    // User registers
    // -----------------------------------------------------------------------
    reg [23:0] reg_pre_in1;
    reg [23:0] reg_pre_in2;
    reg [23:0] reg_post_in;
    reg        reg_rst_nn;   // CTRL[1]: held by firmware until cleared
    reg        reg_done;     // STATUS[0]: sticky until next START

    // Latched outputs (captured in LATCH state)
    reg [23:0] reg_w1, reg_w2, reg_c1, reg_c2;
    reg [2:0]  reg_spikes;   // {post_spike, pre2_spike, pre1_spike}

    // -----------------------------------------------------------------------
    // hd_neuron wires
    // -----------------------------------------------------------------------
    wire        nn_pre1_spike, nn_pre2_spike, nn_post_spike;
    wire [23:0] nn_w1, nn_w2, nn_c1, nn_c2;
    reg         nn_en;

    hd_neuron u_nn (
        .clk        (S_AXI_ACLK),
        .rst        (reg_rst_nn),
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

    // -----------------------------------------------------------------------
    // Processing FSM
    // start_pulse is a one-cycle strobe set by the AXI write logic and
    // consumed by the FSM in the following clock cycle.
    // -----------------------------------------------------------------------
    localparam [1:0] FSM_IDLE  = 2'd0;
    localparam [1:0] FSM_PROC  = 2'd1;
    localparam [1:0] FSM_LATCH = 2'd2;
    localparam [1:0] FSM_DONE  = 2'd3;

    reg [1:0] fsm_state;
    reg       start_pulse;   // driven only by write always-block

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            fsm_state  <= FSM_IDLE;
            nn_en      <= 1'b0;
            reg_done   <= 1'b0;
            reg_w1     <= 24'h0;
            reg_w2     <= 24'h0;
            reg_c1     <= 24'h0;
            reg_c2     <= 24'h0;
            reg_spikes <= 3'h0;
        end else begin
            case (fsm_state)

                FSM_IDLE: begin
                    nn_en <= 1'b0;
                    if (start_pulse) begin
                        reg_done  <= 1'b0;   // clear sticky DONE on new START
                        fsm_state <= FSM_PROC;
                    end
                end

                FSM_PROC: begin
                    nn_en     <= 1'b1;       // assert en for exactly 1 cycle
                    fsm_state <= FSM_LATCH;
                end

                FSM_LATCH: begin
                    // en goes low; hd_neuron registers have updated.
                    // Capture outputs -- they are stable combinational wires
                    // reflecting the just-completed register update.
                    nn_en      <= 1'b0;
                    reg_w1     <= nn_w1;
                    reg_w2     <= nn_w2;
                    reg_c1     <= nn_c1;
                    reg_c2     <= nn_c2;
                    reg_spikes <= {nn_post_spike, nn_pre2_spike, nn_pre1_spike};
                    fsm_state  <= FSM_DONE;
                end

                FSM_DONE: begin
                    reg_done  <= 1'b1;       // signal completion; stays until next START
                    fsm_state <= FSM_IDLE;
                end

                default: fsm_state <= FSM_IDLE;
            endcase
        end
    end

    // -----------------------------------------------------------------------
    // AXI4-Lite write channels
    //
    // AW and W are accepted simultaneously (both valid).  B is issued once
    // both have been captured.  start_pulse defaults to 0 every cycle and is
    // overridden to 1 by the write decode; the LAST non-blocking assignment
    // in an always block wins, so the conditional override is safe.
    // -----------------------------------------------------------------------
    reg [C_S_AXI_ADDR_WIDTH-1:0] axi_awaddr;
    reg                           axi_aw_done;
    reg                           axi_w_done;

    // -- AW handshake --
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            S_AXI_AWREADY <= 1'b0;
            axi_awaddr    <= {C_S_AXI_ADDR_WIDTH{1'b0}};
            axi_aw_done   <= 1'b0;
        end else begin
            if (!S_AXI_AWREADY && S_AXI_AWVALID && S_AXI_WVALID && !axi_aw_done) begin
                S_AXI_AWREADY <= 1'b1;
                axi_awaddr    <= S_AXI_AWADDR;
                axi_aw_done   <= 1'b1;
            end else begin
                S_AXI_AWREADY <= 1'b0;
                if (S_AXI_BVALID && S_AXI_BREADY)
                    axi_aw_done <= 1'b0;
            end
        end
    end

    // -- W handshake --
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            S_AXI_WREADY <= 1'b0;
            axi_w_done   <= 1'b0;
        end else begin
            if (!S_AXI_WREADY && S_AXI_WVALID && S_AXI_AWVALID && !axi_w_done) begin
                S_AXI_WREADY <= 1'b1;
                axi_w_done   <= 1'b1;
            end else begin
                S_AXI_WREADY <= 1'b0;
                if (S_AXI_BVALID && S_AXI_BREADY)
                    axi_w_done <= 1'b0;
            end
        end
    end

    // -- B response + register write --
    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            S_AXI_BVALID <= 1'b0;
            S_AXI_BRESP  <= 2'b00;
            reg_pre_in1  <= 24'h0;
            reg_pre_in2  <= 24'h0;
            reg_post_in  <= 24'h0;
            reg_rst_nn   <= 1'b0;
            start_pulse  <= 1'b0;
        end else begin
            start_pulse <= 1'b0;            // default: clear every cycle

            if (axi_aw_done && axi_w_done && !S_AXI_BVALID) begin
                S_AXI_BVALID <= 1'b1;
                S_AXI_BRESP  <= 2'b00;     // OKAY

                // Address decode: bits[6:2] index the 10 registers
                case (axi_awaddr[6:2])
                    5'h00: begin            // CTRL @ 0x00
                        if (S_AXI_WSTRB[0]) begin
                            // START bit: set one-cycle strobe
                            if (S_AXI_WDATA[0]) start_pulse <= 1'b1;
                            // RST_NN bit: held until firmware clears it
                            reg_rst_nn <= S_AXI_WDATA[1];
                        end
                    end
                    5'h02: begin            // PRE_IN1 @ 0x08
                        if (S_AXI_WSTRB[0]) reg_pre_in1[7:0]   <= S_AXI_WDATA[7:0];
                        if (S_AXI_WSTRB[1]) reg_pre_in1[15:8]  <= S_AXI_WDATA[15:8];
                        if (S_AXI_WSTRB[2]) reg_pre_in1[23:16] <= S_AXI_WDATA[23:16];
                    end
                    5'h03: begin            // PRE_IN2 @ 0x0C
                        if (S_AXI_WSTRB[0]) reg_pre_in2[7:0]   <= S_AXI_WDATA[7:0];
                        if (S_AXI_WSTRB[1]) reg_pre_in2[15:8]  <= S_AXI_WDATA[15:8];
                        if (S_AXI_WSTRB[2]) reg_pre_in2[23:16] <= S_AXI_WDATA[23:16];
                    end
                    5'h04: begin            // POST_IN @ 0x10
                        if (S_AXI_WSTRB[0]) reg_post_in[7:0]   <= S_AXI_WDATA[7:0];
                        if (S_AXI_WSTRB[1]) reg_post_in[15:8]  <= S_AXI_WDATA[15:8];
                        if (S_AXI_WSTRB[2]) reg_post_in[23:16] <= S_AXI_WDATA[23:16];
                    end
                    default: ;              // read-only registers; silently ignore writes
                endcase

            end else if (S_AXI_BVALID && S_AXI_BREADY) begin
                S_AXI_BVALID <= 1'b0;
            end
        end
    end

    // -----------------------------------------------------------------------
    // AXI4-Lite read channel
    // -----------------------------------------------------------------------
    reg [C_S_AXI_ADDR_WIDTH-1:0] axi_araddr;

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            S_AXI_ARREADY <= 1'b0;
            axi_araddr    <= {C_S_AXI_ADDR_WIDTH{1'b0}};
        end else begin
            if (!S_AXI_ARREADY && S_AXI_ARVALID) begin
                S_AXI_ARREADY <= 1'b1;
                axi_araddr    <= S_AXI_ARADDR;
            end else begin
                S_AXI_ARREADY <= 1'b0;
            end
        end
    end

    always @(posedge S_AXI_ACLK) begin
        if (!S_AXI_ARESETN) begin
            S_AXI_RVALID <= 1'b0;
            S_AXI_RRESP  <= 2'b00;
            S_AXI_RDATA  <= {C_S_AXI_DATA_WIDTH{1'b0}};
        end else begin
            if (S_AXI_ARREADY && S_AXI_ARVALID && !S_AXI_RVALID) begin
                S_AXI_RVALID <= 1'b1;
                S_AXI_RRESP  <= 2'b00;
                case (axi_araddr[6:2])
                    5'h00: S_AXI_RDATA <= {30'h0, reg_rst_nn, 1'b0};  // CTRL readback
                    5'h01: S_AXI_RDATA <= {31'h0, reg_done};           // STATUS
                    5'h02: S_AXI_RDATA <= {8'h0,  reg_pre_in1};        // PRE_IN1
                    5'h03: S_AXI_RDATA <= {8'h0,  reg_pre_in2};        // PRE_IN2
                    5'h04: S_AXI_RDATA <= {8'h0,  reg_post_in};        // POST_IN
                    5'h05: S_AXI_RDATA <= {8'h0,  reg_w1};             // W1_OUT
                    5'h06: S_AXI_RDATA <= {8'h0,  reg_w2};             // W2_OUT
                    5'h07: S_AXI_RDATA <= {8'h0,  reg_c1};             // C1_OUT
                    5'h08: S_AXI_RDATA <= {8'h0,  reg_c2};             // C2_OUT
                    5'h09: S_AXI_RDATA <= {29'h0, reg_spikes};         // SPIKES
                    default: S_AXI_RDATA <= 32'hDEADBEEF;
                endcase
            end else if (S_AXI_RVALID && S_AXI_RREADY) begin
                S_AXI_RVALID <= 1'b0;
            end
        end
    end

endmodule
