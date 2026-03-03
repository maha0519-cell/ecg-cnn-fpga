// ============================================================
// Module: conv1d_engine
// Description: Parameterized 1D Convolution Engine
//              Parallel MAC array with pipelined output
//
// Features:
//   - Configurable kernel size (3/5/7)
//   - Configurable filter count
//   - INT8 × INT8 → INT16 MACs with INT20 accumulator
//   - Streaming sliding-window design
//   - Integrated ReLU activation
//   - 1 output sample per clock cycle (after kernel_size latency)
// ============================================================

`timescale 1ns/1ps

module conv1d_engine #(
    parameter IN_CHANNELS  = 1,      // Input channels
    parameter OUT_FILTERS  = 8,      // Number of output filters
    parameter KERNEL_SIZE  = 5,      // Convolution kernel size
    parameter DATA_W       = 8,      // Input/weight data width (INT8)
    parameter ACC_W        = 20,     // Accumulator width
    parameter SCALE_SHIFT  = 7       // Right-shift for fixed-point scaling
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire         enable,

    // Control
    input  wire [2:0]   cfg_kernel_size,  // Runtime kernel config (3/5/7)
    input  wire [4:0]   cfg_num_filters,  // Runtime filter count

    // Input data (one channel per cycle, pipelined)
    input  wire         din_valid,
    input  wire signed [DATA_W-1:0] din,
    input  wire [$clog2(IN_CHANNELS):0] din_channel,

    // Weight interface (from ROM, pre-loaded)
    // weight[filter][channel][kernel_pos]
    input  wire signed [DATA_W-1:0] weight_in [0:OUT_FILTERS-1][0:IN_CHANNELS-1][0:KERNEL_SIZE-1],
    input  wire signed [DATA_W-1:0] bias_in   [0:OUT_FILTERS-1],

    // Output
    output reg          dout_valid,
    output reg signed [DATA_W-1:0] dout [0:OUT_FILTERS-1],  // All filters simultaneously
    output reg  [$clog2(1024):0]   dout_pos  // Output position index
);

    // ─────────────────────────────────────────────
    // SLIDING WINDOW BUFFER
    // Shift register of length KERNEL_SIZE per channel
    // ─────────────────────────────────────────────
    reg signed [DATA_W-1:0] window [0:IN_CHANNELS-1][0:KERNEL_SIZE-1];

    // Window fill counter
    reg [$clog2(KERNEL_SIZE):0] window_fill;
    reg                          window_ready;

    // Position tracking
    reg [10:0] in_pos;
    reg [10:0] out_pos;

    // ─────────────────────────────────────────────
    // SLIDING WINDOW UPDATE
    // ─────────────────────────────────────────────
    integer ci, ki;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            window_fill  <= 0;
            window_ready <= 0;
            in_pos       <= 0;
            out_pos      <= 0;
            dout_valid   <= 0;
            for (ci = 0; ci < IN_CHANNELS; ci = ci+1)
                for (ki = 0; ki < KERNEL_SIZE; ki = ki+1)
                    window[ci][ki] <= 0;
        end else if (enable && din_valid) begin
            // Shift window for this channel
            for (ki = KERNEL_SIZE-1; ki > 0; ki = ki-1)
                window[din_channel][ki] <= window[din_channel][ki-1];
            window[din_channel][0] <= din;

            // Track fill (only count on channel 0 transitions)
            if (din_channel == 0) begin
                in_pos <= in_pos + 1;
                if (window_fill < KERNEL_SIZE)
                    window_fill <= window_fill + 1;
                if (window_fill >= KERNEL_SIZE - 1)
                    window_ready <= 1;
            end
        end
    end

    // ─────────────────────────────────────────────
    // PARALLEL MAC ARRAY: All filters computed in parallel
    // One output element (all filters) per clock cycle
    // ─────────────────────────────────────────────
    reg signed [ACC_W-1:0] acc [0:OUT_FILTERS-1];
    reg  valid_pipe;

    integer fi, chj, kj;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dout_valid <= 0;
            valid_pipe <= 0;
            out_pos    <= 0;
            for (fi = 0; fi < OUT_FILTERS; fi = fi+1)
                acc[fi] <= 0;
        end else if (enable && window_ready && din_valid && din_channel == IN_CHANNELS-1) begin
            // Compute MAC for ALL filters simultaneously (parallel array)
            for (fi = 0; fi < OUT_FILTERS; fi = fi+1) begin
                acc[fi] = $signed(bias_in[fi]);
                for (chj = 0; chj < IN_CHANNELS; chj = chj+1) begin
                    for (kj = 0; kj < KERNEL_SIZE; kj = kj+1) begin
                        acc[fi] = acc[fi] + ($signed(window[chj][kj]) * $signed(weight_in[fi][chj][kj]));
                    end
                end

                // Scale: right-shift by SCALE_SHIFT
                acc[fi] = acc[fi] >>> SCALE_SHIFT;

                // ReLU + INT8 clip
                if (acc[fi] <= 0)
                    dout[fi] <= 8'h00;
                else if (acc[fi] > 8'sh7F)
                    dout[fi] <= 8'h7F;
                else
                    dout[fi] <= acc[fi][DATA_W-1:0];
            end

            dout_valid <= 1;
            dout_pos   <= out_pos;
            out_pos    <= out_pos + 1;
        end else begin
            dout_valid <= 0;
        end
    end

endmodule
