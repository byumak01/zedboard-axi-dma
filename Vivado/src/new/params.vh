// params.vh — Fixed-point parameters for heterosynaptic dynamics model.
// Format: Q8.16 unsigned (8 integer bits, 16 fractional bits, WIDTH=24).
// Include inside a module body: `include "params.vh"
// All floating-point constants are pre-evaluated (no $exp/$rtoi needed).

localparam integer WIDTH           = 24;
localparam integer INT_BITS        = 8;
localparam integer FRAC_BITS       = 16;
localparam integer DIV_SHIFT       = 16;
localparam integer MUL_RESULT_HIGH = 39;  // WIDTH + FRAC_BITS - 1
localparam integer MUL_RESULT_LOW  = 16;  // FRAC_BITS

// ---- Neuron parameters (Q8.16 unsigned 24-bit) ----
localparam [23:0] E_EXC            = 24'd4259840; // 65.0   * 65536
localparam [23:0] E_REST           = 24'd0;
localparam [23:0] V_TH             = 24'd851968;  // 13.0   * 65536
localparam [23:0] V_RESET          = 24'd0;
localparam [23:0] W_POOL_MAX       = 24'd131072;  // 2.0    * 65536
localparam [23:0] RECIP_W_POOL_MAX = 24'd32768;   // 0.5    * 65536
localparam [23:0] W_MAX            = 24'd65536;   // 1.0    * 65536
localparam [23:0] W_DEF            = 24'd0;
localparam [23:0] DECAY_LIF        = 24'd64883;   // trunc(exp(-1/100) * 65536)
localparam [23:0] DECAY_G_E        = 24'd24109;   // trunc(exp(-1/1)   * 65536)

// ---- Synapse parameters (Q8.16 unsigned 24-bit) ----
localparam [23:0] GAMMA_P = 24'd2162;   // trunc(0.033 * 65536)
localparam [23:0] GAMMA_D = 24'd2162;   // trunc(0.033 * 65536)
localparam [23:0] THETA_P = 24'd49152;  // trunc(0.75  * 65536)
localparam [23:0] THETA_D = 24'd9830;   // trunc(0.15  * 65536)
localparam [23:0] THETA_C = 24'd32768;  // trunc(0.5   * 65536)
localparam [23:0] C_PRE   = 24'd26214;  // trunc(0.4   * 65536)
localparam [23:0] C_POST  = 24'd6553;   // trunc(0.1   * 65536)
localparam [23:0] DECAY_C = 24'd62966;  // trunc(exp(-1/25)  * 65536)
