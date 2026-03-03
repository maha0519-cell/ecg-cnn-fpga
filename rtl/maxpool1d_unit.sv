// ============================================================
// Module: maxpool1d_unit
// Description: 1D Max Pooling Unit
//
// Features:
//   - Configurable pool size
//   - Configurable number of channels
//   - Streaming input/output
//   - 1 output per pool_size input cycles per channel
// ============================================================
`timescale 1ns/1ps
module maxpool1d_unit #(
    parameter CHANNELS  = 8,      // Number of input channels
    parameter POOL_SIZE = 2,      // Pooling window size
    parameter DATA_W    = 8       // Data width (INT8 signed)
)(
    input  wire         clk,
    input  wire         rst_n,
    input  wire         enable,
    // Input
    input  wire         din_valid,
    input  wire signed [DATA_W-1:0] din [0:CHANNELS-1],  // All channels parallel
    // Output
    output reg          dout_valid,
    output reg signed [DATA_W-1:0] dout [0:CHANNELS-1]
);
    // Pool accumulator: track max across pool window
    reg signed [DATA_W-1:0] pool_max [0:CHANNELS-1];
    reg [$clog2(POOL_SIZE):0] pool_cnt;
    reg initialized;
    integer ch;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pool_cnt    <= 0;
            dout_valid  <= 0;
            initialized <= 0;
            for (ch = 0; ch < CHANNELS; ch = ch+1) begin
                pool_max[ch] <= 8'sh80; // Most negative INT8
                dout[ch]     <= 0;
            end
        end else if (enable && din_valid) begin
            if (!initialized || pool_cnt == 0) begin
                // First element in window: initialize max
                for (ch = 0; ch < CHANNELS; ch = ch+1)
                    pool_max[ch] <= din[ch];
                initialized <= 1;
                dout_valid  <= 0;
            end else begin
                // Update max
                for (ch = 0; ch < CHANNELS; ch = ch+1) begin
                    if ($signed(din[ch]) > $signed(pool_max[ch]))
                        pool_max[ch] <= din[ch];
                end
                dout_valid <= 0;
            end
            if (pool_cnt == POOL_SIZE - 1) begin
                // End of pool window → output max
                for (ch = 0; ch < CHANNELS; ch = ch+1) begin
                    if (!initialized || pool_cnt == 0)
                        dout[ch] <= din[ch];
                    else if ($signed(din[ch]) > $signed(pool_max[ch]))
                        dout[ch] <= din[ch];
                    else
                        dout[ch] <= pool_max[ch];
                end
                dout_valid <= 1;
                pool_cnt   <= 0;
            end else begin
                pool_cnt <= pool_cnt + 1;
            end
        end else begin
            dout_valid <= 0;
        end
    end
endmodule
